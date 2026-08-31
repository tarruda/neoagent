local async = require("neoagent.async")
local model_catalog = require("neoagent.model_catalog")
local util = require("neoagent.util")

describe("neoagent ModelCatalog", function()
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

  local function store(value)
    local state = { value = util.copy(value), writes = {} }
    function state:read() return util.copy(self.value) end
    function state:write(_, next_value)
      self.value = util.copy(next_value)
      self.writes[#self.writes + 1] = util.copy(next_value)
      return true
    end
    return state
  end

  local function timers()
    local values = {}
    local function new_timer()
      local timer = { stopped = false, closed = false }
      function timer:start(timeout, repeat_ms, callback)
        self.timeout = timeout
        self.repeat_ms = repeat_ms
        self.callback = callback
      end
      function timer:stop() self.stopped = true end
      function timer:close() self.closed = true end
      function timer:is_closing() return self.closed end
      values[#values + 1] = timer
      return timer
    end
    return values, new_timer
  end

  it("restores and transforms its cache during construction", function()
    local calls = 0
    local state = store({
      version = 1,
      validated_at = 1000,
      validator = { etag = "catalog-1" },
      models = { { id = "ox-alpha-free" } },
    })
    local catalog = model_catalog.new({
      provider_id = "opencode-go",
      provider = {},
      store = state,
      now = function() return 1100 end,
      new_timer = function()
        return {
          start = function() end,
          stop = function() end,
          close = function() end,
          is_closing = function() return false end,
        }
      end,
      definition = {
        ttl_ms = 1000,
        discover = function()
          calls = calls + 1
          return async.run(function() return { ok = true, models = {} } end)
        end,
        transform_model = function(model)
          model.input = { "text" }
          model.name = "Alpha"
          return model
        end,
      },
    })
    local snapshot = catalog:snapshot()
    assert.are.equal("Alpha", snapshot.models["ox-alpha-free"].name)
    assert.are.same({ "text" }, snapshot.models["ox-alpha-free"].input)
    assert.are.equal("cache", snapshot.source)
    assert.is_false(snapshot.stale)
    assert.is_true(catalog:start())
    assert.are.equal(0, calls)
    catalog:destroy()
  end)

  it("rejects empty discovery caches during construction", function()
    local reports = {}
    local state = store({
      version = 1,
      validated_at = 1000,
      models = {},
    })
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = state,
      now = function() return 1100 end,
      report = function(message) reports[#reports + 1] = message end,
      definition = {
        seed = { { id = "packaged" } },
        discover = function()
          return async.run(function()
            return {
              ok = true,
              models = { { id = "discovered" } },
            }
          end)
        end,
      },
    })

    local snapshot = catalog:snapshot()
    assert.are.equal("packaged", snapshot.models.packaged.id)
    assert.are.equal("packaged", snapshot.source)
    assert.is_true(snapshot.stale)
    assert.matches("empty model catalog cache", reports[1])
    assert.are.same({}, state.writes)
  end)

  it("applies its transform and exact configuration last", function()
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      definition = {
        seed = {
          { id = "family-one", nested = { source = true } },
          { id = "removed" },
        },
        transform_model = function(model)
          model.input = { "text", "image" }
          model.nested = model.nested or {}
          model.nested.transformed = true
          return model
        end,
      },
      models = {
        ["family-one"] = { nested = { final = true }, context_window = 32000 },
        added = { input = { "text" } },
        removed = false,
      },
    })
    local models = catalog:snapshot().models
    assert.are.same({ "text", "image" }, models["family-one"].input)
    assert.are.same({ source = true, transformed = true, final = true },
      models["family-one"].nested)
    assert.are.equal(32000, models["family-one"].context_window)
    assert.are.same({ "text" }, models.added.input)
    assert.is_nil(models.removed)
  end)

  it("runs transforms before applying exact removals", function()
    local transformed = {}
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      definition = {
        seed = { { id = "keep" }, { id = "remove" } },
        transform_model = function(model)
          transformed[#transformed + 1] = model.id
          return model
        end,
      },
      models = { remove = false },
    })
    assert.are.same({ "keep", "remove" }, transformed)
    assert.is_nil(catalog:snapshot().models.remove)
  end)

  it("excludes one transformed model without truncating the catalog", function()
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      definition = {
        seed = { { id = "excluded" }, { id = "later" } },
        transform_model = function(model)
          if model.id == "excluded" then return false end
          return model
        end,
      },
    })
    assert.is_nil(catalog:snapshot().models.excluded)
    assert.are.equal("later", catalog:snapshot().models.later.id)
  end)

  it("publishes validated discovery even when persistence fails", function()
    local state = store()
    function state:write()
      return nil, util.error("state_store", "read-only state")
    end
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = state,
      definition = {
        discover = function()
          return async.run(function()
            return { ok = true, models = { { id = "new" } } }
          end)
        end,
      },
    })
    local result = wait(catalog:refresh())
    assert.is_true(result.ok)
    assert.are.equal("new", catalog:snapshot().models.new.id)
    assert.are.equal("state_store", result.persistence_error.kind)
    assert.are.equal("idle", catalog:snapshot().refresh.state)
    assert.is_nil(catalog:snapshot().refresh.error)
  end)

  it("contains thrown persistence failures after publication", function()
    local state = store()
    function state:write() error("write exploded") end
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = state,
      definition = {
        discover = function()
          return async.run(function()
            return { ok = true, models = { { id = "published" } } }
          end)
        end,
      },
    })

    local result = wait(catalog:refresh())
    assert.is_true(result.ok)
    assert.are.equal("published", catalog:snapshot().models.published.id)
    assert.matches("write exploded", result.persistence_error.message)
  end)

  it("retains the published snapshot across source and transform failures", function()
    local mode = "source"
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      definition = {
        seed = { { id = "stable" } },
        discover = function()
          return async.run(function()
            if mode == "source" then error("network failed") end
            return { ok = true, models = { { id = "bad" } } }
          end)
        end,
        transform_model = function(model)
          if model.id == "bad" then error("transform failed") end
          return model
        end,
      },
    })
    local result = wait(catalog:refresh())
    assert.is_false(result.ok)
    assert.are.equal("stable", catalog:snapshot().models.stable.id)
    mode = "transform"
    result = wait(catalog:refresh())
    assert.is_false(result.ok)
    assert.matches("transform failed", result.error.detail)
    assert.are.equal("stable", catalog:snapshot().models.stable.id)
  end)

  it("rejects automatic discovery with an empty effective inventory", function()
    local cases = {
      {
        transform_model = function(model)
          if model.id == "candidate" then return false end
          return model
        end,
      },
      { models = { candidate = false } },
    }
    for _, case in ipairs(cases) do
      local state = store()
      local catalog = model_catalog.new({
        provider_id = "example",
        provider = {},
        store = state,
        models = case.models,
        definition = {
          seed = { { id = "stable" } },
          transform_model = case.transform_model,
          discover = function()
            return async.run(function()
              return { ok = true, models = { { id = "candidate" } } }
            end)
          end,
        },
      })

      local result = wait(catalog:refresh())

      assert.is_false(result.ok)
      assert.matches("empty effective inventory", result.error.message)
      assert.are.equal("stable", catalog:snapshot().models.stable.id)
      assert.are.equal("packaged", catalog:snapshot().source)
      assert.are.same({ { id = "stable" } }, catalog:discoveries())
      assert.are.same({}, state.writes)
      catalog:destroy()
    end
  end)

  it("allows provider operations to clear discoveries explicitly", function()
    local catalog = model_catalog.new({
      provider_id = "example",
      definition = { seed = { { id = "stable" } } },
    })

    assert(catalog:publish_discoveries({}))

    assert.are.same({}, catalog:snapshot().models)
    assert.are.same({}, catalog:discoveries())
    assert.are.equal("provider operation", catalog:snapshot().source)
  end)

  it("supersedes active discovery and ignores its late completion", function()
    local pending = {}
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      definition = {
        seed = { { id = "seed" } },
        discover = function()
          return async.run(function()
            return async.await(function(done)
              pending[#pending + 1] = done
            end)
          end)
        end,
      },
    })
    local first_done
    local first = catalog:refresh({
      on_done = function(result) first_done = result end,
    })
    local second = catalog:refresh()
    assert.is_true(first:is_cancelled())
    assert(vim.wait(1000, function() return first_done ~= nil end))
    assert.are.equal("cancelled", first_done.error.kind)
    pending[1].resolve({ ok = true, models = { { id = "old" } } })
    pending[2].resolve({ ok = true, models = { { id = "new" } } })
    assert.is_true(wait(second).ok)
    assert.are.equal("new", catalog:snapshot().models.new.id)
    assert.is_nil(catalog:snapshot().models.old)
  end)

  it("advances unchanged caches with validators", function()
    local now = 5000
    local seen
    local changed = false
    local state = store({
      version = 1,
      validated_at = 1000,
      validator = { etag = "first" },
      models = { { id = "cached" } },
    })
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = state,
      now = function() return now end,
      definition = {
        ttl_ms = 1000,
        discover = function(ctx)
          seen = ctx.validator
          return async.run(function()
            if changed then
              return { ok = true, models = { { id = "changed" } } }
            end
            return {
              ok = true,
              unchanged = true,
              validator = { etag = "second" },
            }
          end)
        end,
      },
    })
    assert.is_true(wait(catalog:refresh()).ok)
    assert.are.same({ etag = "first" }, seen)
    assert.are.equal(5000, state.value.validated_at)
    assert.are.same({ etag = "second" }, state.value.validator)
    assert.are.equal("cached", state.value.models[1].id)
    assert.is_nil(state.value.ttl_ms)
    assert.is_nil(state.value.cache_enabled)

    changed = true
    now = 6000
    assert.is_true(wait(catalog:refresh()).ok)
    assert.is_nil(state.value.validator)
    assert.are.equal("changed", state.value.models[1].id)
  end)

  it("accepts only its single cache schema", function()
    local reports = {}
    local state = store({
      version = 99,
      validated_at = 1000,
      models = { { id = "foreign" } },
    })
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = state,
      report = function(message) reports[#reports + 1] = message end,
      definition = { seed = { { id = "packaged" } } },
    })
    local snapshot = catalog:snapshot()
    assert.is_nil(snapshot.models.foreign)
    assert.are.equal("packaged", snapshot.models.packaged.id)
    assert.matches("invalid model catalog cache", reports[1])

    local policy_state = store({
      version = 1,
      validated_at = 1000,
      models = { { id = "foreign" } },
      cache_enabled = true,
    })
    local policy_catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = policy_state,
      definition = { seed = { { id = "packaged" } } },
    })
    local policy_snapshot = policy_catalog:snapshot()
    assert.is_nil(policy_snapshot.models.foreign)
    assert.are.equal("packaged", policy_snapshot.models.packaged.id)
  end)

  it("publishes refresh status and makes failed validation stale", function()
    local pending = {}
    local states = {}
    local state = store({
      version = 1,
      validated_at = 1000,
      models = { { id = "cached" } },
    })
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = state,
      now = function() return 1100 end,
      definition = {
        ttl_ms = 1000,
        discover = function()
          return async.run(function()
            return async.await(function(done)
              pending[#pending + 1] = done
            end)
          end)
        end,
      },
    })
    catalog:subscribe(function(snapshot)
      states[#states + 1] = snapshot.refresh.state
    end)

    local succeeded = catalog:refresh({ force = true })
    assert.are.equal("refreshing", states[#states])
    pending[1].resolve({ ok = true, models = { { id = "remote" } } })
    assert.is_true(wait(succeeded).ok)
    assert.are.equal("idle", states[#states])
    assert.is_false(catalog:snapshot().stale)

    local failed = catalog:refresh({ force = true })
    assert.are.equal("refreshing", states[#states])
    pending[2].reject(util.error("transport", "network failed"))
    assert.is_false(wait(failed).ok)
    assert.are.equal("failed", states[#states])
    assert.is_true(catalog:snapshot().stale)
    assert.are.equal("remote", catalog:snapshot().models.remote.id)
    catalog:destroy()
  end)

  it("bounds subscriber diagnostics without changing catalog status", function()
    local reports = {}
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      report = function(message) reports[#reports + 1] = message end,
      definition = { seed = { { id = "stable" } } },
    })

    catalog:subscribe(function()
      error("subscriber failed " .. string.rep("x", 4096))
    end)

    assert.are.equal(1, #reports)
    assert.is_true(vim.fn.strchars(reports[1]) < 1200)
    assert.matches("model catalog subscriber failed for example", reports[1])
    assert.are.equal("idle", catalog:snapshot().refresh.state)
    assert.is_nil(catalog:snapshot().refresh.error)
    catalog:destroy()
  end)

  it("restores stale data before starting an automatic refresh", function()
    local pending
    local state = store({
      version = 1,
      validated_at = 1000,
      models = { { id = "cached" } },
    })
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = state,
      now = function() return 5000 end,
      definition = {
        ttl_ms = 1000,
        discover = function()
          return async.run(function()
            return async.await(function(done) pending = done end)
          end)
        end,
      },
    })
    assert.are.equal("cached", catalog:snapshot().models.cached.id)
    assert.is_true(catalog:snapshot().stale)
    assert.is_nil(pending)
    assert.is_true(catalog:start())
    assert.is_table(pending)
    assert.are.equal("cached", catalog:snapshot().models.cached.id)
    pending.resolve({ ok = true, models = { { id = "remote" } } })
    assert(vim.wait(1000, function()
      return catalog:snapshot().models.remote ~= nil
    end))
    catalog:destroy()
  end)

  it("schedules fresh validation at expiry and forwards force refresh", function()
    local now = 1500
    local force_values = {}
    local scheduled, new_timer = timers()
    local state = store({
      version = 1,
      validated_at = 1000,
      models = { { id = "cached" } },
    })
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = state,
      now = function() return now end,
      new_timer = new_timer,
      definition = {
        ttl_ms = 1000,
        discover = function(ctx)
          force_values[#force_values + 1] = ctx.force
          return async.run(function()
            return { ok = true, models = { { id = "remote" } } }
          end)
        end,
      },
    })
    assert.is_true(catalog:start())
    assert.are.equal(500, scheduled[1].timeout)
    assert.are.equal(0, #force_values)
    now = 2000
    scheduled[1].callback()
    assert(vim.wait(1000, function() return #force_values == 1 end))
    assert.is_false(force_values[1])
    assert.are.equal("remote", catalog:snapshot().models.remote.id)
    assert.are.equal(1000, scheduled[2].timeout)
    assert.is_true(wait(catalog:refresh({ force = true })).ok)
    assert.is_true(force_values[2])
    catalog:destroy()
  end)

  it("schedules validation through Neovim timer handles", function()
    local reports = {}
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      store = store({
        version = 1,
        validated_at = 1000,
        models = { { id = "cached" } },
      }),
      now = function() return 1000 end,
      report = function(message) reports[#reports + 1] = message end,
      definition = {
        ttl_ms = 60000,
        discover = function()
          return async.run(function()
            return { ok = true, models = { { id = "remote" } } }
          end)
        end,
      },
    })

    assert.is_true(catalog:start())
    assert.are.same({}, reports)
    assert.is_true(catalog:destroy())
  end)

  it("retries transient failures exponentially and suspends auth failures", function()
    local kind = "transport"
    local calls = 0
    local reports = {}
    local scheduled, new_timer = timers()
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      new_timer = new_timer,
      report = function(message) reports[#reports + 1] = message end,
      definition = {
        seed = { { id = "stable" } },
        ttl_ms = 1000,
        discover = function()
          calls = calls + 1
          return async.run(function()
            local message = kind == "auth" and string.rep("x", 2000)
              or kind .. " failed"
            error(util.error(kind, message), 0)
          end)
        end,
      },
    })
    assert.is_true(catalog:start())
    assert(vim.wait(1000, function() return #scheduled == 1 end))
    assert.are.equal(30000, scheduled[1].timeout)
    scheduled[1].callback()
    assert(vim.wait(1000, function() return #scheduled == 2 end))
    assert.are.equal(60000, scheduled[2].timeout)
    kind = "auth"
    scheduled[2].callback()
    assert(vim.wait(1000, function() return calls == 3 end))
    assert.are.equal(2, #scheduled)
    assert.are.equal("stable", catalog:snapshot().models.stable.id)
    assert.are.equal("failed", catalog:snapshot().refresh.state)
    assert.are.equal("auth", catalog:snapshot().refresh.error.kind)
    assert.is_true(vim.fn.strchars(
      catalog:snapshot().refresh.error.message) <= 1025)
    assert.are.equal(2, #reports)
    catalog:destroy()
  end)

  it("treats source-free configured catalogs as current", function()
    local catalog = model_catalog.new({
      provider_id = "static",
      provider = {},
      models = { configured = { input = { "text" } } },
    })
    local snapshot = catalog:snapshot()
    assert.are.equal("configured", snapshot.source)
    assert.is_false(snapshot.stale)
    assert.are.equal("configured", snapshot.models.configured.id)
  end)

  it("rejects catalog policy outside its current definition", function()
    assert.has_error(function()
      model_catalog.new({
        provider_id = "example",
        definition = { cache_enabled = true },
      })
    end)
  end)

  it("rejects empty discovery inventories and cancels owned work", function()
    local pending
    local scheduled, new_timer = timers()
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {},
      new_timer = new_timer,
      definition = {
        seed = { { id = "seed" } },
        ttl_ms = 1000,
        discover = function()
          if pending then
            return async.run(function()
              return { ok = true, models = {} }
            end)
          end
          return async.run(function()
            return async.await(function(done) pending = done end)
          end)
        end,
      },
    })
    assert.is_true(catalog:start())
    local active = catalog._active
    assert.is_table(active)
    assert.is_true(catalog:destroy())
    assert.is_true(active:is_cancelled())
    pending.resolve({ ok = true, models = { { id = "late" } } })
    assert.is_nil(catalog:snapshot().models.late)

    local empty = model_catalog.new({
      provider_id = "example",
      provider = {},
      new_timer = new_timer,
      definition = {
        seed = { { id = "seed" } },
        discover = function()
          return async.run(function() return { ok = true, models = {} } end)
        end,
      },
    })
    assert.is_true(empty:start())
    assert(vim.wait(1000, function()
      return #scheduled > 0
        and empty:snapshot().refresh.state == "failed"
    end))
    assert.are.equal("seed", empty:snapshot().models.seed.id)
    assert.matches("empty effective inventory",
      empty:snapshot().refresh.error.message)
    assert.is_true(empty:destroy())
    assert.is_true(scheduled[#scheduled].closed)
    assert.is_false(empty:destroy())
  end)

  it("rejects malformed transform and discovery results", function()
    assert.has_error(function()
      model_catalog.new({
        provider_id = "example",
        definition = {
          seed = { { id = "bad" } },
          transform_model = function() return "not a model" end,
        },
      })
    end)

    local cases = {
      {
        value = function() return {} end,
        message = "must return a Run",
      },
      {
        value = function()
          return async.run(function() return "not a result" end)
        end,
        message = "invalid result",
      },
      {
        value = function()
          return async.run(function()
            return { ok = true, unchanged = "yes" }
          end)
        end,
        message = "invalid result",
      },
      {
        value = function()
          return async.run(function()
            return {
              ok = true,
              unchanged = true,
              models = { { id = "bad" } },
            }
          end)
        end,
        message = "must not return models",
      },
      {
        value = function()
          return async.run(function()
            return { ok = true, unchanged = true }
          end)
        end,
        message = "without prior discoveries",
      },
      {
        value = function()
          return async.run(function()
            return {
              ok = true,
              models = { { id = "bad-validator" } },
              validator = { etag = "" },
            }
          end)
        end,
        message = "invalid validator",
      },
    }
    for _, case in ipairs(cases) do
      local catalog = model_catalog.new({
        provider_id = "example",
        definition = { discover = case.value },
      })
      local result = wait(catalog:refresh())
      assert.is_false(result.ok)
      assert.matches(case.message, result.error.message)
      catalog:destroy()
    end
  end)

  it("rejects malformed remote model inventories without replacing state", function()
    local inventories = {
      { named = { id = "named" } },
      { 42 },
      { { id = "" } },
      { { id = "duplicate" }, { id = "duplicate" } },
      { { id = "bad-api", api = "" } },
      { { id = "bad-name", name = string.rep("x", 257) } },
      { { id = "bad-hidden", hidden = "yes" } },
      { { id = "bad-options", request_opts = "invalid" } },
    }
    for _, inventory in ipairs(inventories) do
      local catalog = model_catalog.new({
        provider_id = "example",
        definition = {
          seed = { { id = "stable" } },
          discover = function()
            return async.run(function()
              return { ok = true, models = inventory }
            end)
          end,
        },
      })
      local result = wait(catalog:refresh())
      assert.is_false(result.ok)
      assert.are.equal("stable", catalog:snapshot().models.stable.id)
      catalog:destroy()
    end
  end)

  it("passes source credentials through the discovery boundary", function()
    local seen = {}
    local catalog = model_catalog.new({
      provider_id = "example",
      provider = {
        api_key = function() return "ambient-key" end,
      },
      definition = {
        discover = function(ctx)
          return async.run(function()
            seen.auth = ctx.resolve_auth():await()
            seen.api_key = ctx.resolve_api_key()
            return { ok = true, models = { { id = "remote" } } }
          end)
        end,
      },
    })

    assert.is_true(wait(catalog:refresh()).ok)
    assert.is_false(seen.auth.configured)
    assert.are.equal("ambient-key", seen.api_key)
    catalog:destroy()

    local configured = model_catalog.new({
      provider_id = "configured",
      provider = {
        api_key = "configured-key",
        auth = "plan",
      },
      definition = {
        discover = function(ctx)
          return async.run(function()
            seen.configured_auth = ctx.resolve_auth():await()
            seen.configured_key = ctx.resolve_api_key()
            return { ok = true, models = { { id = "configured" } } }
          end)
        end,
      },
    })
    assert.is_true(wait(configured:refresh()).ok)
    assert.is_false(seen.configured_auth.configured)
    assert.are.equal("configured-key", seen.configured_key)
    configured:destroy()
  end)

  it("retains a cached validator across an unchanged response", function()
    local state = store({
      version = 1,
      validated_at = 1000,
      validator = { etag = "cached" },
      models = { { id = "cached" } },
    })
    local catalog = model_catalog.new({
      provider_id = "example",
      store = state,
      now = function() return 2000 end,
      definition = {
        discover = function()
          return async.run(function()
            return { ok = true, unchanged = true }
          end)
        end,
      },
    })

    assert.is_true(wait(catalog:refresh()).ok)
    assert.are.same({ etag = "cached" }, state.value.validator)
    catalog:destroy()
  end)

  it("contains timer allocation and startup failures", function()
    local reports = {}
    local function configured(new_timer)
      return model_catalog.new({
        provider_id = "example",
        store = store({
          version = 1,
          validated_at = 1000,
          models = { { id = "cached" } },
        }),
        now = function() return 1000 end,
        new_timer = new_timer,
        report = function(message) reports[#reports + 1] = message end,
        definition = {
          ttl_ms = 1000,
          discover = function()
            return async.run(function()
              return { ok = true, models = { { id = "remote" } } }
            end)
          end,
        },
      })
    end

    local missing = configured(function() return nil end)
    assert.is_true(missing:start())
    assert.matches("failed to create", reports[#reports])

    local thrown = configured(function() error("allocation exploded") end)
    assert.is_true(thrown:start())
    assert.matches("allocation exploded", reports[#reports])

    local closed = false
    local failed = configured(function()
      return {
        start = function() error("start exploded") end,
        stop = function() end,
        close = function() closed = true end,
        is_closing = function() return false end,
      }
    end)
    assert.is_true(failed:start())
    assert.is_true(closed)
    assert.matches("start exploded", reports[#reports])
    missing:destroy()
    thrown:destroy()
    failed:destroy()
  end)

  it("reports listener and unclassified persistence failures", function()
    local reports = {}
    local state = store()
    function state:write() return false end
    local catalog = model_catalog.new({
      provider_id = "example",
      store = state,
      report = function(message) reports[#reports + 1] = message end,
      definition = { seed = { { id = "seed" } } },
    })
    local notifications = 0
    catalog:subscribe(function()
      notifications = notifications + 1
      if notifications > 1 then error("listener exploded") end
    end)

    local published, persistence_error = catalog:publish_discoveries({
      { id = "published" },
    })
    assert.is_true(published)
    assert.are.equal("state store write failed", persistence_error.message)
    assert.matches("subscriber failed", reports[1])
    catalog:destroy()
  end)

  it("reports cache read failures and falls back from unusable caches", function()
    local reports = {}
    local thrown = store()
    function thrown:read() error("read exploded") end
    local first = model_catalog.new({
      provider_id = "example",
      store = thrown,
      report = function(message) reports[#reports + 1] = message end,
    })
    assert.matches("read exploded", reports[#reports])
    first:destroy()

    local rejected = store({
      version = 1,
      validated_at = 1000,
      validator = { etag = "" },
      models = { { id = "cached" } },
    })
    local second = model_catalog.new({
      provider_id = "example",
      store = rejected,
      report = function(message) reports[#reports + 1] = message end,
      definition = { seed = { { id = "seed" } } },
    })
    assert.are.equal("seed", second:snapshot().models.seed.id)
    assert.matches("invalid model catalog cache", reports[#reports])
    second:destroy()

    local unusable = store({
      version = 1,
      validated_at = 1000,
      models = { { id = "cached" } },
    })
    local third = model_catalog.new({
      provider_id = "example",
      store = unusable,
      report = function(message) reports[#reports + 1] = message end,
      definition = {
        seed = { { id = "seed" } },
        transform_model = function(model)
          if model.id == "cached" then model.id = "different" end
          return model
        end,
      },
    })
    assert.are.equal("seed", third:snapshot().models.seed.id)
    assert.matches("unusable model catalog cache", reports[#reports])
    third:destroy()
  end)

  it("returns terminal results after destruction and without discovery", function()
    local static = model_catalog.new({
      provider_id = "static",
      models = { configured = {} },
    })
    local unchanged = wait(static:refresh())
    assert.is_true(unchanged.ok)
    assert.is_false(unchanged.changed)
    assert.is_true(static:destroy())
    local destroyed = wait(static:refresh())
    assert.is_false(destroyed.ok)
    assert.matches("destroyed", destroyed.error.message)
    local published, err = static:publish_discoveries({ { id = "late" } })
    assert.is_nil(published)
    assert.matches("destroyed", err.message)
  end)
end)
