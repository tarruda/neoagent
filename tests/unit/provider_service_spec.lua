local async = require("neoagent.async")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

describe("neoagent provider service", function()
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

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

  it("validates Provider Service values and operation descriptors", function()
    local value = service({
      first = { label = "First", run = function() return async.run(function() return { ok = true } end) end },
      second = { label = "Second", mutating = true, run = function() end },
    })
    assert.are.equal(value, provider_service.validate(value))
    assert.are.same({}, provider_service.operations(service({})))

    local invalid_method = service({})
    invalid_method.subscribe = true
    local validated, err = provider_service.validate(nil)
    assert.is_nil(validated)
    assert.are.equal("provider", err.kind)

    for _, invalid in ipairs({
      true, {}, service({ missing = { run = function() end } }),
      service({ bad = { label = "", run = function() end } }),
      service({ bad = { label = "x", run = true } }),
      service({ bad = { label = "forged\nlabel", run = function() end } }),
      invalid_method,
    }) do
      validated, err = provider_service.validate(invalid)
      assert.is_nil(validated)
      assert.are.equal("provider", err.kind)
    end

    assert.has_error(function() provider_service.assert({ id = "x" }) end)
  end)

  it("returns sorted operation metadata without functions", function()
    local operations = {
      zeta = { label = "Zeta", run = function() end },
      alpha = { label = "Alpha", description = "first", mutating = true, run = function() end },
    }
    local metadata = provider_service.operations(service(operations))
    assert.are.same({ "alpha", "zeta" },
      vim.tbl_map(function(item) return item.id end, metadata))
    assert.are.equal("first", metadata[1].description)
    assert.is_true(metadata[1].mutating)
    assert.is_nil(metadata[1].run)
  end)

  it("builds operation contexts and completes exactly once", function()
    local seen
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
    local run = provider_service.run(value, "run", {
      args = "tail",
      provider = {
        api = "fake",
        base_url = "http://localhost/v1",
        api_key = "secret",
        service_opts = { tenant = "local" },
      },
    })
    local result = wait(run)
    assert.is_true(result.ok)
    assert.are.equal(7, result.value)
    assert.are.equal("tail", seen.args)
    assert.are.equal("http://localhost/v1", seen.provider.config.base_url)
    assert.is_nil(seen.provider.config.api_key)
    assert.are.same({ tenant = "local" }, seen.provider.config.service_opts)
    assert.is_nil(seen.model)
    assert.is_nil(seen.agent_running)
    assert.is_function(seen.resolve_auth)
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
        run = function() return {} end,
      },
    })
    local result = wait(provider_service.run(value, "fail"))
    assert.is_false(result.ok)
    assert.are.equal("provider", result.error.kind)
    assert.matches("boom", result.error.message)

    result = wait(provider_service.run(value, "invalid"))
    assert.is_false(result.ok)
    assert.matches("must return a Run", result.error.message)
  end)

  it("cancels an operation through the outer Run", function()
    local cancelled
    local value = service({
      work = {
        label = "Work",
        run = function()
          return async.run(function(run)
            run:on_cancel(function() cancelled = true end)
            return async.await(function(done)
              run:on_cancel(function() done.reject(async.cancelled_error) end)
              return function() end
            end)
          end)
        end,
      },
    })
    local run = provider_service.run(value, "work")
    vim.wait(50)
    run:cancel()
    assert(vim.wait(3000, function() return run:is_done() end))
    local result = run:result()
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.is_true(cancelled)
  end)

  it("serializes operations on a shared service and protects active model use", function()
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
    assert.matches("already active", busy_err.message)
    local unavailable, operation_err = provider_service.acquire(value)
    assert.is_nil(unavailable)
    assert.matches("mutating provider operation", operation_err.message)
    pending.resolve({ ok = true })
    assert.is_true(wait(first).ok)
    assert.is_true(wait(assert(provider_service.run(value, "inspect"))).ok)

    local release = provider_service.acquire(value)
    local blocked, active_err = provider_service.run(value, "mutate")
    assert.is_nil(blocked)
    assert.matches("active model run", active_err.message)
    assert.is_true(wait(assert(provider_service.run(value, "inspect"))).ok)
    release()
    provider_service.acquire(value)()
  end)

  it("publishes shared service lease and operation changes", function()
    local snapshots = {}
    local reports = {}
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
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
    assert.are.same({ users = 1, busy = false, mutating = false }, snapshots[1])
    release()
    assert.are.same({ users = 0, busy = false, mutating = false }, snapshots[2])
    local run = assert(provider_service.run(value, "inspect"))
    assert.are.same({ users = 0, busy = true, mutating = false }, snapshots[3])
    pending.resolve({ ok = true })
    assert.is_true(wait(run).ok)
    assert.are.same({ users = 0, busy = false, mutating = false }, snapshots[4])
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
    local manager = {
      resolve = function(method, opts)
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
      end,
    }
    local seen
    local operations = {
      auth = {
        label = "Auth",
        run = function(ctx)
          local resolved = ctx.resolve_auth():await()
          seen = resolved
          return async.run(function() return { ok = true } end)
        end,
      },
    }
    local result = wait(provider_service.run(service(operations), "auth", {
      auth = manager,
      auth_method = "fake",
    }))
    assert.is_true(result.ok)
    assert.is_true(seen.configured)
    assert.are.equal("http://localhost", seen.metadata.server_url)
  end)

  it("resolves absent auth methods without credentials", function()
    local run = provider_service.resolve_auth({})
    local result = wait(run)
    assert.is_true(result.ok)
    assert.is_false(result.configured)
  end)

  it("rejects interactions when no adapter is supplied", function()
    local selected = false
    local ok, err = pcall(function()
      provider_service.no_interact().select({}, {
        resolve = function() selected = true end,
        reject = function(value) error(value, 0) end,
      })
    end)
    assert.is_false(ok)
    assert.are.equal("provider", err.kind)
    assert.matches("unavailable", err.message)
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
      assert.are.equal("provider", err.kind)
    end

    local value = service({})
    value.operations = {
      bad = { label = "", run = function() end },
    }
    assert.is_nil(provider_service.validate(value))
    value.operations = {
      bad = { label = string.rep("x", 129), run = function() end },
    }
    assert.is_nil(provider_service.validate(value))
    value.operations = {
      bad = { label = "x", description = string.rep("d", 513), run = function() end },
    }
    assert.is_nil(provider_service.validate(value))
    value.operations = {
      bad = { label = "x", mutating = "yes", run = function() end },
    }
    assert.is_nil(provider_service.validate(value))
    value.operations = {
      bad = { label = "x", complete = true, run = function() end },
    }
    assert.is_nil(provider_service.validate(value))
    value.operations = {
      bad = { label = "x" },
    }
    assert.is_nil(provider_service.validate(value))

    value = service({
      bad = { label = "\255", run = function() end },
    })
    assert.is_nil(provider_service.validate(value))
    value = service({})
    value.operations = { bad = true }
    assert.is_nil(provider_service.validate(value))
  end)

  it("validates operation Run inputs and unknown operations", function()
    local value = service({
      work = { label = "Work", run = function() return async.run(function() return { ok = true } end) end },
    })
    assert.is_nil(provider_service.run(value, "missing"))
    assert.is_nil(provider_service.run(value, "work", { args = 1 }))
    assert.is_nil(provider_service.run(value, "work", {
      args = string.rep("x", 16385),
    }))
    assert.is_nil(provider_service.run(value, "work", { args = "bad\nargs" }))
    assert.is_true(wait(assert(provider_service.run(value, "work"))).ok)
    assert.is_nil(provider_service.run(value, "work", { interact = {} }))
    assert.is_nil(provider_service.run(value, "work", { interact = "bad" }))
    assert.is_nil(provider_service.run(value, "work", {
      interact = { select = function() end },
    }))
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
