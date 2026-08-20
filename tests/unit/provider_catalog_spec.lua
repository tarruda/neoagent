local async = require("neoagent.async")
local provider_catalog = require("neoagent.provider_catalog")
local util = require("neoagent.util")

describe("neoagent provider catalog", function()
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

  it("restores stored catalogs and publishes refreshed entries", function()
    local stored = { read = nil, write = nil, delete = nil }
    local store = {
      read = function(id) return stored.read end,
      write = function(id, entry) stored.write = util.copy(entry) return true end,
      delete = function(id) stored.delete = id return true end,
    }
    local models = {}
    local seen
    local service = {
      id = "dynamic",
      get_models = function() return util.copy(models) end,
      refresh_models = function(self, ctx)
        seen = ctx
        ctx.publish({
          update = function() models = { { id = "discovered" } } end,
        })
        return async.run(function() return { ok = true } end)
      end,
    }
    stored.read = { models = { { id = "cached" } } }
    local catalog = provider_catalog.new({ service = service, store = store })
    local result = wait(catalog:refresh())
    assert.is_true(result.ok)
    assert.are.same({ { id = "discovered" } }, models)
    assert.are.same({ { id = "discovered" } }, result.models)
    assert.is_true(seen.stored.models[1].id == "cached")
    assert.is_true(seen.allow_network)
    assert.is_false(seen.force)
    assert.is_function(seen.publish)
  end)

  it("reports refresh failures without replacing the catalog", function()
    local service = {
      id = "dynamic",
      get_models = function() return {} end,
      refresh_models = function()
        return async.run(function()
          error(util.error("provider", "refresh boom"))
        end)
      end,
    }
    local catalog = provider_catalog.new({ service = service })
    local result = wait(catalog:refresh())
    assert.is_false(result.ok)
    assert.matches("refresh boom", result.error.message)
  end)

  it("rejects invalid publications and requires refresh_models", function()
    local service = {
      id = "dynamic",
      get_models = function() return {} end,
      refresh_models = function(self, ctx)
        local ok, err = pcall(ctx.publish, {})
        assert.is_false(ok)
        assert.are.equal("provider", err.kind)
        assert.matches("update function", err.message)
        local persisted, persist_err = pcall(ctx.publish, {
          update = function() end,
          persist = { "list" },
        })
        assert.is_false(persisted)
        assert.are.equal("provider", persist_err.kind)
        assert.matches("object or false", persist_err.message)
        return async.run(function() return { ok = true } end)
      end,
    }
    assert(wait(provider_catalog.new({ service = service }):refresh()).ok)

    local published, publish_err = provider_catalog.new({
      service = service,
    }):publish({})
    assert.is_nil(published)
    assert.matches("update function", publish_err.message)

    local static = { id = "static", get_models = function() return {} end }
    local catalog, err = provider_catalog.new({ service = static }):refresh()
    assert.is_nil(catalog)
    assert.are.equal("provider", err.kind)
  end)

  it("writes persistence before applying updates", function()
    local models = {}
    local failed = false
    local store = {
      read = function() return nil end,
      write = function() failed = true return nil, util.error("state_store", "disk full") end,
      delete = function() return true end,
    }
    local service = {
      id = "dynamic",
      get_models = function() return util.copy(models) end,
      refresh_models = function(self, ctx)
        local published, err = ctx.publish({
          update = function() models = { { id = "new" } } end,
          persist = { models = { { id = "new" } } },
        })
        if not published then error(err, 0) end
        return async.run(function() return { ok = true } end)
      end,
    }
    local result = wait(provider_catalog.new({ service = service, store = store }):refresh())
    assert.is_false(result.ok)
    assert.is_true(failed)
    assert.are.same({}, models)
  end)

  it("reports stored catalog read failures before network refresh", function()
    local models = {}
    local seen
    local service = {
      id = "dynamic",
      get_models = function() return util.copy(models) end,
      refresh_models = function(self, ctx)
        seen = ctx
        ctx.publish({ update = function() models = { { id = "networked" } } end })
        return async.run(function() return { ok = true } end)
      end,
    }
    local store = {
      read = function() error("read boom") end,
      write = function() return true end,
      delete = function() return true end,
    }
    local result = wait(provider_catalog.new({ service = service, store = store }):refresh())
    assert.is_false(result.ok)
    assert.matches("read boom", result.error.detail)
    assert.is_nil(seen)
    assert.are.same({}, models)

    result = wait(provider_catalog.new({ service = service, store = store }):refresh({
      force = true,
    }))
    assert.is_true(result.ok)
    assert.is_true(seen.allow_network)
    assert.are.same({ { id = "networked" } }, models)
  end)

  it("handles update errors, deletions, and invalid runs", function()
    local service = {
      id = "dynamic",
      get_models = function() return {} end,
      refresh_models = function(self, ctx)
        ctx.publish({ update = function() error(util.error("provider", "update boom")) end })
        return async.run(function() return { ok = true } end)
      end,
    }
    local store = {
      read = function() return nil end,
      write = function() return true end,
      delete = function() return true end,
    }
    local result = wait(provider_catalog.new({ service = service, store = store }):refresh())
    assert.is_false(result.ok)
    assert.matches("update boom", result.error.message)

    local deleted
    store = {
      read = function() return nil end,
      write = function() return true end,
      delete = function(self, id) deleted = id return true end,
    }
    local service_delete = {
      id = "dynamic",
      get_models = function() return {} end,
      refresh_models = function(self, ctx)
        ctx.publish({ update = function() end, persist = false })
        return async.run(function() return { ok = true } end)
      end,
    }
    assert(wait(provider_catalog.new({ service = service_delete, store = store }):refresh()).ok)
    assert.are.equal("dynamic", deleted)

    local service_invalid = {
      id = "dynamic",
      get_models = function() return {} end,
      refresh_models = function() return {} end,
    }
    result = wait(provider_catalog.new({ service = service_invalid }):refresh())
    assert.is_false(result.ok)
    assert.matches("must return a Run", result.error.message)
  end)

  it("falls back when a service model getter fails", function()
    local service = {
      id = "dynamic",
      get_models = function() error("models boom") end,
    }
    assert.are.same({}, provider_catalog.new({ service = service }):models())
    assert.is_nil(provider_catalog.new({ service = service }):refresh())
  end)

  it("serves fresh cached catalogs without network requests", function()
    local fetched = 0
    local models = {}
    local store = {
      read = function()
        return { models = { { id = "cached" } }, checked_at = 1000 }
      end,
      write = function() return true end,
      delete = function() return true end,
    }
    local seen
    local service = {
      id = "dynamic",
      get_models = function() return util.copy(models) end,
      refresh_models = function(self, ctx)
        seen = ctx
        if type(ctx.stored) == "table" then
          models = util.copy(ctx.stored.models)
        end
        if not ctx.allow_network then
          return async.run(function() return { ok = true } end)
        end
        fetched = fetched + 1
        models = { { id = "fresh" } }
        ctx.publish({
          update = function() end,
          persist = { models = models, checked_at = 2000 },
        })
        return async.run(function() return { ok = true } end)
      end,
    }
    local ttl_ms = 7 * 24 * 60 * 60 * 1000
    local catalog = provider_catalog.new({
      service = service,
      store = store,
      ttl_ms = ttl_ms,
      now = function() return 5000 end,
    })
    local result = wait(catalog:refresh())
    assert.is_true(result.ok)
    assert.are.same({ { id = "cached" } }, result.models)
    assert.is_false(seen.allow_network)
    assert.are.equal(0, fetched)

    catalog = provider_catalog.new({
      service = service,
      store = store,
      ttl_ms = ttl_ms,
      now = function() return 5000 + ttl_ms + 1 end,
    })
    result = wait(catalog:refresh())
    assert.is_true(result.ok)
    assert.are.same({ { id = "fresh" } }, result.models)
    assert.is_true(seen.allow_network)
    assert.are.equal(1, fetched)

    catalog = provider_catalog.new({
      service = service,
      store = store,
      ttl_ms = ttl_ms,
      now = function() return 5000 end,
    })
    result = wait(catalog:refresh({ force = true }))
    assert.is_true(result.ok)
    assert.is_true(seen.allow_network)
    assert.are.equal(2, fetched)
  end)

  it("rejects invalid catalog cache windows", function()
    local service = { id = "dynamic" }
    assert.has_error(function()
      provider_catalog.new({ service = service, ttl_ms = -1 })
    end, "provider catalog ttl_ms must be a non-negative integer")
    assert.has_error(function()
      provider_catalog.new({ service = service, now = "clock" })
    end, "provider catalog now must be a function")
  end)
end)
