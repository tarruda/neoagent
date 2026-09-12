local assert = require("luassert")
local async = require("neoagent.async")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

describe("neoagent provider service", function()
  ---@generic T, E
  ---@param run Neoagent.Run<T, E>?
  ---@return Neoagent.RunResult<T>
  local function wait(run)
    assert(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return (assert(run:result()))
  end

  ---@param operations? table<string, Neoagent.ProviderOperation>
  ---@return Neoagent.ProviderService
  local function service(operations)
    return {
      id = "fake",
      name = "Fake provider",
      state = function()
        return { blocks = { { type = "status", text = "ready" } } }
      end,
      operations = operations or {},
      subscribe = function() return function() end end,
      on_event = function() end,
      destroy = function() end,
    }
  end

  ---@param operations? table<string, unknown>
  ---@return {operations: table<string, unknown>, subscribe?: unknown}
  local function invalid_service(operations)
    local value = service()
    rawset(value, "operations", operations or {})
    return value
  end

  it("validates Provider Service values and operation descriptors", function()
    local value = service({
      first = { label = "First", run = function() return async.run(function() return { ok = true } end) end },
      second = { label = "Second", mutating = true, run = function() error("unexpected operation execution") end },
    })
    assert.are.equal(value, provider_service.validate(value))
    assert.are.same({}, provider_service.operations(service({})))

    local invalid_method = invalid_service({})
    invalid_method.subscribe = true
    local validated, err = provider_service.validate(nil)
    assert.is_nil(validated)
    assert.are.equal("provider", assert(err).kind)

    ---@type unknown[]
    local invalid_values = {
      true, {}, invalid_service({ missing = { run = function() error("unexpected operation execution") end } }),
      invalid_service({ ["bad\nid"] = { label = "x", run = function() error("unexpected operation execution") end } }),
      invalid_service({ bad = { label = "", run = function() error("unexpected operation execution") end } }),
      invalid_service({ bad = { label = "x", run = true } }),
      invalid_service({ bad = { label = "forged\nlabel", run = function() error("unexpected operation execution") end } }),
      invalid_method,
    }
    for _, invalid in ipairs(invalid_values) do
      validated, err = provider_service.validate(invalid)
      assert.is_nil(validated)
      assert.are.equal("provider", assert(err).kind)
    end

    assert.has_error(function() provider_service.assert({ id = "x" }) end)
  end)

  it("returns sorted operation metadata without functions", function()
    local operations = {
      zeta = { label = "Zeta", run = function() error("unexpected operation execution") end },
      alpha = { label = "Alpha", description = "first", mutating = true,
        auth_scope = "dashboard", run = function() error("unexpected operation execution") end },
    }
    local metadata = provider_service.operations(service(operations))
    assert.are.same({ "alpha", "zeta" },
      vim.tbl_map(function(item) return item.id end, metadata))
    assert.are.equal("first", assert(metadata[1]).description)
    assert.is_true(assert(metadata[1]).mutating)
    assert.are.equal("dashboard", assert(metadata[1]).auth_scope)
    assert.is_nil((rawget(assert(metadata[1]), "run")))
  end)

  it("builds operation contexts and completes exactly once", function()
    ---@type Neoagent.ProviderOperationContext?
    local seen
    ---@type table<string, Neoagent.ProviderOperation>
    local operations = {
      run = {
        label = "Run",
        run = function(ctx)
          seen = ctx
          return async.run(function()
            ctx.interact.progress({
              id = "run", label = "Run", state = "running", message = "Working",
            })
            return { ok = true, value = 7 }
          end)
        end,
      },
    }
    local value = service(operations)
    local completed
    local run = provider_service.run(value, "run", {
      args = "tail",
      on_done = function(result) completed = result end,
      provider = {
        api = "fake",
        base_url = "http://localhost/v1",
        api_key = "secret",
        service_opts = { tenant = "local" },
      },
    })
    local result = wait(run)
    assert(result.ok)
    assert.are.equal(result, completed)
    assert.are.equal(7, result.value)
    assert.are.equal("tail", assert(seen).args)
    assert.are.equal("http://localhost/v1", assert(seen).provider.config.base_url)
    assert.is_nil((rawget(assert(seen).provider.config, "api_key")))
    assert.are.same({ tenant = "local" }, assert(seen).provider.config.service_opts)
    assert.is_nil((rawget(assert(seen), "model")))
    assert.is_nil((rawget(assert(seen), "agent_running")))
    assert.is_function(assert(seen).resolve_auth)
  end)

  it("normalizes operation failures and invalid Run returns", function()
    local value = service({
      fail = {
        label = "Fail",
        run = function()
          error(util.error("provider", "boom"))
        end,
      },
      invalid = {
        label = "Invalid",
        run = (function() return {} end) --[[@as fun(ctx: Neoagent.ProviderOperationContext): Neoagent.ProviderOperationRun]],
      },
    })
    local result = wait(provider_service.run(value, "fail"))
    assert.is_false(result.ok)
    assert.are.equal("provider", assert(result.error).kind)
    assert.matches("boom", assert(result.error).message)

    result = wait(provider_service.run(value, "invalid"))
    assert.is_false(result.ok)
    assert.matches("must return a Run", assert(result.error).message)
  end)

  it("cancels an operation through the outer Run", function()
    local cancelled
    local started = false
    local value = service({
      work = {
        label = "Work",
        run = function()
          return async.run(function(run)
            started = true
            run:on_cancel(function() cancelled = true end)
            return async.await(function(done)
              run:on_cancel(function() done.reject(async.cancelled_error) end)
              return function() end
            end)
          end)
        end,
      },
    })
    local run = assert(provider_service.run(value, "work"))
    assert(vim.wait(1000, function() return started end))
    run:cancel()
    assert(vim.wait(3000, function() return run:is_done() end))
    local result = assert(run:result())
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.is_true(cancelled)
  end)

  it("serializes operations on a shared service and protects active model use", function()
    ---@type Neoagent.AwaitCallbacks<Neoagent.ProviderOperationResult>?
    local pending
    local value = service({
      inspect = {
        label = "Inspect",
        run = function()
          return async.run(function() return { ok = true } end)
        end,
      },
      mutate = {
        label = "Mutate",
        mutating = true,
        run = function()
          return async.run(function()
            return async.await(function(done)
              pending = done
              return function() end
            end)
          end)
        end,
      },
    })

    local first = assert(provider_service.run(value, "mutate"))
    local second, busy_err = provider_service.run(value, "inspect")
    assert.is_nil(second)
    assert.matches("already active", assert(busy_err).message)
    local unavailable, operation_err = provider_service.acquire(value)
    assert.is_nil(unavailable)
    assert.matches("mutating provider operation", assert(operation_err).message)
    assert(pending).resolve({ ok = true })
    assert.is_true(wait(first).ok)
    assert.is_true(wait(assert(provider_service.run(value, "inspect"))).ok)

    local release = assert(provider_service.acquire(value))
    local blocked, active_err = provider_service.run(value, "mutate")
    assert.is_nil(blocked)
    assert.matches("active provider use", assert(active_err).message)
    assert.is_true(wait(assert(provider_service.run(value, "inspect"))).ok)
    release()
    assert(provider_service.acquire(value))()
  end)

  it("owns use and operation leases through idempotent values", function()
    local value = service({})
    local use = assert(provider_service.acquire_use(value))
    local inspect = assert(provider_service.begin_operation(value, {
      mutating = false,
    }))
    local second = assert(provider_service.begin_operation(value, {
      mutating = false,
    }))
    local blocked, err = provider_service.begin_operation(value, {
      mutating = true,
    })
    assert.is_nil(blocked)
    assert.matches("active provider use", assert(err).message)

    assert.is_true(inspect:finish())
    assert.is_false(inspect:finish())
    assert.is_true(second:finish())
    assert.is_true(use:release())
    assert.is_false(use:release())

    local exclusive = assert(provider_service.begin_operation(value, {
      mutating = true,
    }))
    local concurrent, concurrent_err = provider_service.begin_operation(value, {
      mutating = true,
    })
    assert.is_nil(concurrent)
    assert.matches("already active", assert(concurrent_err).message)
    local unavailable, unavailable_err = provider_service.acquire_use(value)
    assert.is_nil(unavailable)
    assert.matches("mutating provider operation", assert(unavailable_err).message)
    assert.is_true(exclusive:finish())
  end)

  it("rejects forged operation tokens and releases startup failures", function()
    local value = service({
      work = {
        label = "Work",
        run = function()
          return async.run(function() return { ok = true } end)
        end,
      },
    })
    local coordination = assert(provider_service.begin_operation(value, {
      mutating = false,
    }))
    local forged = {}
    for key, item in pairs(coordination) do forged[key] = item end
    assert.is_false(forged:finish())
    local run, err = provider_service.run(value, "work", {
      coordination = forged --[[@as Neoagent.ProviderOperationToken]],
    })
    assert.is_nil(run)
    assert.matches("coordination token is invalid", assert(err).message)
    assert.is_true(coordination:finish())

    local original_run = async.run
    async.run = function() error("outer Run construction failed") end
    run, err = provider_service.run(value, "work")
    async.run = original_run
    assert.is_nil(run)
    assert.matches("Failed to construct provider operation Run", assert(err).message)
    assert.matches("outer Run construction failed", assert(err).message)
    assert.is_false(provider_service.busy(value))
  end)

  it("lets one Run consume an operation token", function()
    for _, mutating in ipairs({ false, true }) do
      ---@type Neoagent.AwaitCallbacks<Neoagent.ProviderOperationResult>?
    local pending
      local calls = 0
      local value = service({
        work = {
          label = "Work",
          mutating = mutating,
          run = function()
            calls = calls + 1
            return async.run(function()
              return async.await(function(done)
                pending = done
                return function() end
              end)
            end)
          end,
        },
      })
      local coordination = assert(provider_service.begin_operation(value, {
        mutating = mutating,
      }))
      local first = assert(provider_service.run(value, "work", {
        coordination = coordination,
      }))
      local second, err = provider_service.run(value, "work", {
        coordination = coordination,
      })
      assert.is_nil(second)
      assert.matches("coordination token is invalid", assert(err).message)
      assert.are.equal(1, calls)

      if mutating then
        assert.is_nil((provider_service.acquire_use(value)))
        assert.is_nil((provider_service.begin_operation(value, {
          mutating = false,
        })))
      end
      assert(pending).resolve({ ok = true })
      assert.is_true(wait(first).ok)
      assert.is_false(coordination:finish())
      assert.is_false(provider_service.busy(value))
    end
  end)

  it("defers concrete Service destruction until every lease settles", function()
    local value = service({})
    local use = assert(provider_service.acquire_use(value))
    local destroyed = 0

    assert.is_true(provider_service.retire(value, function()
      destroyed = destroyed + 1
    end))
    assert.are.equal(0, destroyed)
    assert.is_false(provider_service.operation_enabled(value, {}))
    local operation, operation_err = provider_service.begin_operation(value)
    assert.is_nil(operation)
    assert.matches("retiring", assert(operation_err).message)
    local unavailable, err = provider_service.acquire_use(value)
    assert.is_nil(unavailable)
    assert.matches("retiring", assert(err).message)
    assert.is_true(use:release())
    assert.are.equal(1, destroyed)
    assert.is_false(provider_service.retire(value, function() end))
  end)

  it("publishes shared service lease and operation changes", function()
    local snapshots = {}
    local reports = {}
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    ---@type Neoagent.AwaitCallbacks<Neoagent.ProviderOperationResult>?
    local pending
    local value = service({
      inspect = {
        label = "Inspect",
        run = function()
          return async.run(function()
            return async.await(function(done)
              pending = done
              return function() end
            end)
          end)
        end,
      },
    })
    local unsubscribe = provider_service.subscribe(value, function(snapshot)
      snapshots[#snapshots + 1] = snapshot
    end)
    local unsubscribe_broken = provider_service.subscribe(value, function()
      error("runtime listener failed " .. string.rep("x", 1024))
    end, {
      report = function(message, level)
        reports[#reports + 1] = { message, level }
      end,
    })
    local release = assert(provider_service.acquire(value))
    assert.are.same({
      users = 1, operations = 0, busy = false, mutating = false,
    }, snapshots[1])
    release()
    assert.are.same({
      users = 0, operations = 0, busy = false, mutating = false,
    }, snapshots[2])
    local run = assert(provider_service.run(value, "inspect"))
    assert.are.same({
      users = 0, operations = 1, busy = true, mutating = false,
    }, snapshots[3])
    assert(pending).resolve({ ok = true })
    assert.is_true(wait(run).ok)
    assert.are.same({
      users = 0, operations = 0, busy = false, mutating = false,
    }, snapshots[4])
    assert.is_true(unsubscribe())
    assert.is_false(unsubscribe())
    assert.is_true(unsubscribe_broken())
    assert(vim.wait(1000, function()
      return #reports > 0 or #notifications > 0
    end, 5))
    vim.notify = original_notify
    assert.matches("runtime subscriber failed", reports[1][1])
    assert.are.equal(vim.log.levels.ERROR, reports[1][2])
    assert.is_true(vim.fn.strchars(reports[1][1]) <= 570)
    assert.are.same({}, notifications)
  end)

  it("resolves provider auth through the supplied manager", function()
    local value = service({})
    local resolved_scope
    local manager = require("tests.helpers.auth_manager").new()
    function manager:resolve(method, opts)
        resolved_scope = assert(opts).scope
        return async.run(function()
          return {
            ok = true,
            method = method,
            configured = true,
            credential_type = "api_key",
            request_opts = { headers = { Authorization = "Bearer token" } },
            metadata = { server_url = "http://localhost" },
          }
        end)
    end
    ---@type Neoagent.AuthResolution?
    local seen
    ---@type table<string, Neoagent.ProviderOperation>
    local operations = {
      auth = {
        label = "Auth",
        run = function(ctx)
          return async.run(function()
            seen = ctx.resolve_auth("dashboard"):await()
            return { ok = true }
          end)
        end,
      },
    }
    local result = wait(provider_service.run(service(operations), "auth", {
      auth = manager,
      auth_method = "fake",
    }))
    assert(result.ok)
    assert(seen and seen.ok and seen.configured)
    assert.are.equal("fake", seen.method)
    assert.are.equal("dashboard", resolved_scope)
    assert.are.equal("http://localhost", assert(seen.metadata).server_url)
  end)

  it("resolves absent auth methods without credentials", function()
    local run = provider_service.resolve_auth({})
    local result = wait(run)
    assert(result.ok)
    assert.is_false(result.configured)
  end)

  it("rejects interactions when no adapter is supplied", function()
    local selected = false
    local ok, err = pcall(function()
      provider_service.no_interact().select({ items = {} }, {
        resolve = function() selected = true end,
        reject = function(value) error(value, 0) end,
      })
    end)
    assert.is_false(ok)
    assert.are.equal("provider", rawget(err, "kind"))
    assert.matches("unavailable", rawget(err, "message"))
    assert.is_false(selected)
  end)

  it("rejects invalid text, services, and operation metadata", function()
    for _, value in ipairs({
      { id = "", name = "x", state = function() return false end, operations = {} },
      { id = "bad\tid", name = "x", state = function() return false end, operations = {} },
      { id = "x", name = "", state = function() return false end, operations = {} },
      { id = "x", name = string.rep("n", 129), state = function() return false end, operations = {} },
      { id = "x", name = "x", operations = {} },
      { id = "x", name = "x", state = function() return false end, operations = { {} } },
      { id = "x", name = "x", state = function() return false end, operations = {}, catalog = {} },
    }) do
      local validated, err = provider_service.validate(value)
      assert.is_nil(validated)
      assert.are.equal("provider", assert(err).kind)
    end

    local value = invalid_service({})
    value.operations = {
      bad = { label = "", run = function() error("unexpected operation execution") end },
    }
    assert.is_nil((provider_service.validate(value)))
    value.operations = {
      bad = { label = string.rep("x", 129), run = function() error("unexpected operation execution") end },
    }
    assert.is_nil((provider_service.validate(value)))
    value.operations = {
      bad = { label = "x", description = string.rep("d", 513), run = function() error("unexpected operation execution") end },
    }
    assert.is_nil((provider_service.validate(value)))
    value.operations = {
      bad = { label = "x", mutating = "yes", run = function() error("unexpected operation execution") end },
    }
    assert.is_nil((provider_service.validate(value)))
    for _, scope in ipairs({ "", "unsafe/scope", "bad\nscope",
      string.rep("s", 129) }) do
      value.operations = {
        bad = { label = "x", auth_scope = scope, run = function() error("unexpected operation execution") end },
      }
      assert.is_nil((provider_service.validate(value)))
    end
    value.operations = {
      bad = { label = "x", complete = true, run = function() error("unexpected operation execution") end },
    }
    assert.is_nil((provider_service.validate(value)))
    value.operations = {
      bad = { label = "x" },
    }
    assert.is_nil((provider_service.validate(value)))

    value = invalid_service({
      bad = { label = "\255", run = function() error("unexpected operation execution") end },
    })
    assert.is_nil((provider_service.validate(value)))
    value = invalid_service({})
    value.operations = { bad = true }
    assert.is_nil((provider_service.validate(value)))
  end)

  it("validates operation Run inputs and unknown operations", function()
    ---@param value Neoagent.ProviderService
    ---@param id string
    ---@param options? table<string, unknown>
    local function run(value, id, options)
      return provider_service.run(value, id, options --[[@as Neoagent.ProviderOperationOptions?]])
    end
    local value = service({
      work = { label = "Work", run = function() return async.run(function() return { ok = true } end) end },
    })
    assert.is_nil((run(value, "missing")))
    assert.is_nil((run(value, "work", { args = 1 })))
    assert.is_nil((run(value, "work", {
      args = string.rep("x", 16385),
    })))
    assert.is_nil((run(value, "work", { args = "bad\nargs" })))
    assert.is_true(wait(assert(run(value, "work"))).ok)
    assert.is_nil((run(value, "work", { interact = {} })))
    assert.is_nil((run(value, "work", { interact = "bad" })))
    assert.is_nil((run(value, "work", {
      interact = { select = function() end },
    })))
    local other = service(value.operations)
    local coordination = assert(provider_service.begin_operation(value, {
      mutating = false,
    }))
    assert.is_nil((run(other, "work", {
      coordination = coordination,
    })))
    assert.is_true(coordination:finish())
    assert.is_nil((run(value, "work", {
      coordination = coordination,
    })))
    assert.are.same({}, provider_service.public_config(nil))
    assert.are.same({
      api = "fake",
      base_url = "http://localhost/v1",
      service_opts = { tenant = "local" },
      auth_optional = true,
    }, provider_service.public_config({
      api = "fake",
      base_url = "http://localhost/v1",
      service_opts = { tenant = "local" },
      auth_optional = true,
      api_key = "secret",
    }))
  end)
end)
