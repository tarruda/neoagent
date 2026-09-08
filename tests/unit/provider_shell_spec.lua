local assert = require("luassert")
local async = require("neoagent.async")
local Applet = require("applet")
local ProviderShell = require("neoagent.provider_shell")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

describe("neoagent Provider Shell", function()
  ---@type Neoagent.ProviderShell[]
  local shells
  local original_ui_select = vim.ui.select
  local owned_presenters = {}
  local owned_views = {}
  local owned_catalogs = {}

  before_each(function()
    shells = {}
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    for _, shell in ipairs(shells) do shell:destroy() end
    vim.ui.select = original_ui_select
    for _, value in ipairs(owned_presenters) do value:destroy() end
    for _, value in ipairs(owned_views) do value:destroy() end
    for _, value in ipairs(owned_catalogs) do value:destroy() end
    owned_presenters, owned_views, owned_catalogs = {}, {}, {}
  end)

  ---@generic T, E
  ---@param run Neoagent.Run<T, E>
  ---@return T
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end, 5))
    return (assert(run:result()))
  end

  local function presenter()
    ---@class Neoagent.TestShellPresenter: Neoagent.Presenter
    ---@field notifications Neoagent.NotificationRequest[]
    ---@field requests {kind: string, request: Neoagent.SelectRequest|Neoagent.InputRequest|Neoagent.ConfirmRequest|Neoagent.NoticeRequest}[]
    ---@field uris string[]
    ---@field confirm_value boolean
    ---@field confirm_error? Neoagent.Error
    local value = require("neoagent.presenter").new()
    value.notifications, value.requests, value.uris = {}, {}, {}
    value.confirm_value = true
    owned_presenters[#owned_presenters + 1] = value
    ---@param result unknown
    ---@return Neoagent.PresentationRun
    local function resolved(result)
      return async.run(function() return { ok = true, value = result } end)
    end
    function value:select(request)
      self.requests[#self.requests + 1] = { kind = "select", request = request }
      local item = request.items[1]
      return resolved(type(item) == "table" and item.id or item), function() return true end
    end
    function value:input(request)
      self.requests[#self.requests + 1] = { kind = "input", request = request }
      return resolved(request.default or "")
    end
    function value:confirm(request)
      request = request or {}
      self.requests[#self.requests + 1] = { kind = "confirm", request = request }
      if self.confirm_error then
        return async.run(function() error(self.confirm_error, 0) end)
      end
      return resolved(self.confirm_value)
    end
    function value:notice(request)
      self.requests[#self.requests + 1] = { kind = "notice", request = request }
      return resolved(true)
    end
    function value:notify(request)
      if type(request) == "string" then request = { message = request } end
      self.notifications[#self.notifications + 1] = util.copy(request)
      return true
    end
    function value:open_uri(request)
      self.uris[#self.uris + 1] = request.uri
      return true
    end
    return value
  end

  ---@param initial? table<string, "api_key"|"oauth"|"invalid">
  local function authentication(initial)
    local credentials = util.copy(initial or {})
    ---@class Neoagent.TestShellAuth: Neoagent.AuthManager
    ---@field credentials table<string, "api_key"|"oauth"|"invalid">
    local value = require("tests.helpers.auth_manager").new()
    value.credentials = credentials
    value.has_credentials = function(self, id)
      return self.credentials[id] ~= nil
    end
    function value:list_credentials()
      local result = {}
      for id, kind in pairs(self.credentials) do
        result[#result + 1] = {
          id = id,
          name = id == "key" and "API key" or id,
          type = kind,
        }
      end
      table.sort(result, function(left, right) return left.id < right.id end)
      return result
    end
    value.login = function(self, id, opts)
      return async.run(function()
        self.credentials[id] = "api_key"
        return { ok = true, method = id, revision = 1 }
      end, { on_done = opts and opts.on_done, error_kind = "auth" })
    end
    value.logout = function(self, id, opts)
      return async.run(function()
        self.credentials[id] = nil
        return { ok = true, method = id, revision = 1 }
      end, { on_done = opts and opts.on_done, error_kind = "auth" })
    end
    function value:resolve(id)
      return async.run(function()
        if self.credentials[id] then
          return { ok = true, method = id, configured = true,
            credential_type = "api_key", request_opts = {} }
        end
        return { ok = true, method = id, configured = false }
      end, { error_kind = "auth" })
    end
    return value
  end

  local function view()
    ---@class Neoagent.TestShellView: Neoagent.ProviderShellView
    ---@field opened boolean
    ---@field origin? integer
    ---@field snapshot? Neoagent.ProviderPanelSnapshot
    ---@field snapshots Neoagent.ProviderPanelSnapshot[]
    ---@field entries Neoagent.ProviderListEntry[]
    ---@field notifications [string, integer?][]
    ---@field uris string[]
    local value = require("neoagent.ui.provider_shell").new({ config = { style = "pi" } })
    value.opened, value.snapshots, value.notifications, value.uris, value.entries = false, {}, {}, {}, {}
    owned_views[#owned_views + 1] = value
    rawset(value, "set_presentation", false)
    local destroy = value.destroy
    function value:set(snapshot, providers)
      self.snapshot = util.copy(snapshot)
      self.entries = util.copy(providers)
      self.snapshots[#self.snapshots + 1] = self.snapshot
      return true
    end
    value.open = function(self, origin)
      self.origin = origin
      self.opened = true
      return true
    end
    function value:close()
      local changed = self.opened
      self.opened = false
      return changed
    end
    function value:is_open() return self.opened end
    function value:notify(message, level)
      self.notifications[#self.notifications + 1] = { message, level }
    end
    function value:open_uri(uri)
      self.uris[#self.uris + 1] = uri
      local process = {}
      ---@cast process vim.SystemObj
      return process
    end
    function value:destroy()
      destroy(self)
      self.opened = false
    end
    return value
  end

  ---@param label string
  ---@param run? fun(ctx: Neoagent.ProviderOperationContext): Neoagent.ProviderOperationRun
  ---@param mutating? boolean
  ---@return Neoagent.ProviderOperation
  local function operation(label, run, mutating)
    return {
      label = label,
      mutating = mutating == true,
      run = run or function()
        return async.run(function() return { ok = true } end)
      end,
    }
  end

  ---@param id string
  ---@param name string
  ---@param operations? table<string, Neoagent.ProviderOperation>
  ---@param state? fun(): Neoagent.ProviderState|false
  ---@return Neoagent.ProviderService
  local function service(id, name, operations, state)
    return {
      id = id,
      name = name,
      state = state or function()
        return { blocks = { { type = "status", level = "info", text = "Ready" } } }
      end,
      operations = operations or {
        inspect = operation("Inspect"),
      },
    }
  end

  ---@param models? table<string, Neoagent.ModelConfigInput|false>
  ---@param overrides? Partial<Neoagent.CatalogSnapshot>
  local function catalog(models, overrides)
    ---@class Neoagent.TestShellCatalog: Neoagent.ModelCatalog
    ---@field refreshes integer
    local value = require("neoagent.model_catalog").new({ provider_id = "test", models = models })
    value.refreshes = 0
    owned_catalogs[#owned_catalogs + 1] = value
    ---@type table<fun(snapshot: Neoagent.CatalogSnapshot), true>
    local listeners = {}
    ---@type Neoagent.CatalogSnapshot
    local snapshot = {
      revision = 0,
      persistence = { configured = false, enabled = false },
      models = value:snapshot().models,
      validated_at = 1,
      stale = false,
      source = "packaged",
      refresh = { state = "idle" },
    }
    if overrides then
      if overrides.revision ~= nil then snapshot.revision = overrides.revision end
      if overrides.models then snapshot.models = util.copy(overrides.models) end
      if overrides.validated_at then snapshot.validated_at = overrides.validated_at end
      if overrides.source then snapshot.source = overrides.source end
      if overrides.stale ~= nil then snapshot.stale = overrides.stale end
      if overrides.refresh then snapshot.refresh = util.copy(overrides.refresh) end
      if overrides.persistence then snapshot.persistence = util.copy(overrides.persistence) end
    end
    function value:snapshot() return util.copy(snapshot) end
    function value:subscribe(callback)
      listeners[callback] = true
      callback(self:snapshot())
      return function()
        listeners[callback] = nil
        return true
      end
    end
    value.refresh = function(self, opts)
      assert.are.same({ force = true }, opts)
      self.refreshes = self.refreshes + 1
      snapshot.revision = assert(snapshot.revision) + 1
      snapshot.source = "source"
      snapshot.stale = false
      snapshot.refresh = { state = "idle" }
      for callback in pairs(listeners) do callback(self:snapshot()) end
      return async.run(function()
        return { ok = true, changed = true, snapshot = self:snapshot() }
      end)
    end
    return value
  end

  ---@param selected Neoagent.ProviderService
  ---@param definition? Neoagent.ProviderOptions
  ---@param selected_catalog? Neoagent.ModelCatalog
  ---@return Neoagent.ProviderRuntime
  local function runtime(selected, definition, selected_catalog)
    definition = util.copy(definition or {
      api = "fake",
      catalog = {},
      models = {},
    })
    definition.catalog = definition.catalog or {}
    definition.models = definition.models or {}
    return {
      id = selected.id,
      definition = definition --[[@as Neoagent.ProviderDefinition]],
      credentials = require("neoagent.provider_credentials").new({ provider_id = selected.id, provider = definition }),
      auth_services = {},
      catalog = selected_catalog or catalog(definition.models),
      service = selected,
    }
  end

  ---@param providers table<string, Neoagent.ProviderOptions>
  ---@param default_provider? string
  ---@return Neoagent.Config<Neoagent.AgentToolEnvironment>
  local function config(providers, default_provider)
    providers = util.copy(providers)
    for _, definition in pairs(providers) do
      if definition.catalog and definition.catalog.discover then
        definition.catalog.source_id = definition.catalog.source_id or "test"
        definition.catalog.source_revision = definition.catalog.source_revision or 1
      end
    end
    return require("neoagent.config").resolve({
      default_registry = false, persistence = { enabled = false },
      default_model = default_provider and {
        provider = default_provider,
        model = "model",
      } or nil,
      providers = providers,
      auth = {
        path = "/tmp/neoagent-provider-shell-credentials.json",
        methods = {
          key = require("neoagent.auth.api_key").new({ name = "API key" }),
          ["beta-key"] = require("neoagent.auth.api_key").new({ name = "Beta key" }),
          dashboard = require("neoagent.auth.api_key").new({ name = "Dashboard authorization" }),
        },
      },
      ui = { style = "pi" },
    })
  end

  ---@class Neoagent.TestShellRuntime
  ---@field id string
  ---@field definition Neoagent.ProviderOptions
  ---@field catalog Neoagent.ModelCatalog
  ---@field service Neoagent.ProviderService

  ---@class Neoagent.TestShellOptions: Neoagent.ProviderShellOptions
  ---@field runtimes table<string, Neoagent.TestShellRuntime|Neoagent.ProviderService>

  ---@param opts Neoagent.TestShellOptions
  local function shell(opts)
    opts.auth.methods = opts.config.auth.methods
    ---@type Neoagent.ProviderShellOptions
    local selected = { config = opts.config, auth = opts.auth, presenter = opts.presenter, view = opts.view, host = opts.host, host_effects = opts.host_effects, runtimes = {} }
    selected.runtimes = {}
    for id, value in pairs(opts.runtimes or {}) do
      if rawget(value, "service") then
        ---@cast value Neoagent.TestShellRuntime
        selected.runtimes[id] = runtime(value.service, value.definition, value.catalog)
      else
        selected.runtimes[id] = runtime(value --[[@as Neoagent.ProviderService]], opts.config.providers[id])
      end
    end
    for id, value in pairs(selected.runtimes) do
      local definition = opts.config.providers[id]
      value.credentials = require("neoagent.provider_credentials").new({
        provider_id = id, provider = definition, authentication = opts.auth,
        method = opts.config.auth.methods[definition.auth],
      })
    end
    local value = ProviderShell.new(selected)
    shells[#shells + 1] = value
    return value
  end

  ---@param operations Neoagent.ProviderShellOperation[]
  local function ids(operations)
    return vim.tbl_map(function(item) return item.id end, operations)
  end

  ---@param operations Neoagent.ProviderShellOperation[]
  local function labels(operations)
    return vim.tbl_map(function(item) return item.label end, operations)
  end

  ---@generic T
  ---@param values T[]
  ---@param predicate fun(value: T): boolean
  local function any(values, predicate)
    for _, value in ipairs(values) do if predicate(value) then return true end end
    return false
  end

  ---@param surface Neoagent.TestShellView
  ---@param id string
  ---@return Neoagent.ProviderListEntry
  local function provider(surface, id)
    for _, entry in ipairs(surface.entries or {}) do
      if entry.id == id then return entry end
    end
    error("provider is missing from the shell surface: " .. id)
  end

  it("owns provider selection independently from Agents", function()
    local surface = view()
    local value = shell({
      config = config({
        alpha = { api = "fake", models = {} },
        beta = { api = "fake", models = {} },
      }, "beta"),
      auth = authentication(),
      runtimes = {
        alpha = service("alpha", "Alpha"),
        beta = service("beta", "Beta"),
      },
      presenter = presenter(),
      view = function() return surface end,
    })

    assert.are.equal("beta", assert(value:info()).id)
    assert.are.same({ "alpha", "beta" },
      vim.tbl_map(function(item) return item.id end, value:providers()))
    assert(value:open(17))
    assert.are.equal(17, surface.origin)
    assert.is_true(value:is_open())
    assert.are.equal("alpha", value:select("alpha"))
    assert.are.equal("alpha", assert(value:info()).id)
    assert.is_false((value:toggle()))
    assert.is_false(value:is_open())
    assert(value:toggle())
  end)

  it("cycles providers by cancelling passive refreshes only", function()
    local refresh_cancelled = false
    local mutation_cancelled = false
    local function pending(cancelled)
      return function()
        return async.run(function()
          return async.await(function(done)
            return function()
              cancelled()
              done.reject(async.cancelled_error)
            end
          end)
        end)
      end
    end
    local alpha = service("alpha", "Alpha")
    local beta = service("beta", "Beta", {
      inspect = operation("Inspect"),
      mutate = operation("Mutate", pending(function()
        mutation_cancelled = true
      end), true),
      refresh = operation("Refresh", pending(function()
        refresh_cancelled = true
      end)),
    })
    local surface = view()
    local value = shell({
      config = config({
        alpha = { api = "fake", models = {} },
        beta = { api = "fake", models = {} },
      }, "beta"),
      auth = authentication(),
      runtimes = { alpha = alpha, beta = beta },
      presenter = presenter(),
      view = function() return surface end,
    })

    assert(value:open())
    assert.is_true(value:is_active())
    assert.is_true(assert(surface.entries[1]).enabled)
    assert.is_true(assert(surface.entries[2]).enabled)
    assert.are.equal("alpha", value:cycle(-1))
    assert(vim.wait(1000, function()
      return assert(value:info()).id == "alpha" and not value:is_active()
    end, 5))
    assert.is_true(refresh_cancelled)

    assert.are.equal("beta", value:cycle(1))
    assert.is_true(value:is_active())
    assert.is_true(value:cancel())
    assert(vim.wait(1000, function() return not value:is_active() end, 5))
    local mutation = assert(value:run("mutate"))
    assert(type(mutation) == "table")
    local selected, err = value:select("alpha")
    assert.is_nil(selected)
    assert.matches("active provider action", assert(err).message)
    assert.are.equal("beta", assert(value:info()).id)
    assert(value:cancel())
    assert.is_false(wait(mutation).ok)
    assert.is_true(mutation_cancelled)
  end)

  it("orders provider selection before deferred authentication actions", function()
    local refresh_cancellations = 0
    local alpha = service("alpha", "Alpha", {
      refresh = operation("Refresh", function()
        return async.run(function()
          return async.await(function(done)
            return function()
              refresh_cancellations = refresh_cancellations + 1
              done.reject(async.cancelled_error)
            end
          end)
        end)
      end),
    })
    local beta = service("beta", "Beta")
    local configured = config({
      alpha = { api = "fake", models = {} },
      beta = { api = "fake", models = {}, auth = "beta-key" },
    }, "alpha")
    configured.auth.methods["beta-key"] = require("neoagent.auth.api_key").new({ name = "Beta key" })
    local auth = authentication()
    local value = shell({
      config = configured,
      auth = auth,
      runtimes = { alpha = alpha, beta = beta },
      presenter = presenter(),
      view = function() return view() end,
    })

    assert(value:open())
    assert.is_true(value:is_active())
    assert.is_true((value:login("beta")))
    assert(vim.wait(1000, function()
      return assert(value:info()).id == "beta"
        and auth.credentials["beta-key"] == "api_key"
        and not value:is_active()
    end, 5))
    assert.are.equal(1, refresh_cancellations)

    assert.are.equal("alpha", value:select("alpha"))
    assert.is_true(value:is_active())
    assert.is_true((value:logout("beta")))
    assert(vim.wait(1000, function()
      return assert(value:info()).id == "beta"
        and auth.credentials["beta-key"] == nil
        and not value:is_active()
    end, 5))
    assert.are.equal(2, refresh_cancellations)
  end)

  it("shows only valid login and logout actions for current auth state", function()
    local auth = authentication()
    local surface = view()
    local value = shell({
      config = config({
        fake = {
          api = "fake",
          catalog = { discover = function() error("unexpected catalog discovery") end },
          models = {},
          auth = "key",
        },
      }, "fake"),
      auth = auth,
      runtimes = { fake = service("fake", "Fake") },
      presenter = presenter(),
      view = function() return surface end,
    })
    assert.are.same({
      connected = false,
      error = false,
    }, provider(surface, "fake").authentication)
    assert.are.same({ "Log in" }, labels(assert(value:info()).operations))
    assert.are.same({}, value:operations())
    assert.are.equal("Logged out", assert(assert(assert(assert(value:info()).state).blocks)[1]).value)
    local blocked, blocked_err = value:run("inspect")
    assert.is_nil(blocked)
    assert.matches("Log in", assert(blocked_err).message)
    local logout, logout_err = value:logout()
    assert.is_nil(logout)
    assert.matches("unavailable", assert(logout_err).message)

    assert.is_true(wait(assert(value:login())).ok)
    assert.are.same({
      connected = true,
      source = "stored",
      error = false,
    }, provider(surface, "fake").authentication)
    assert.are.same({ "Refresh model catalog", "Inspect", "Log out" },
      labels(assert(value:info()).operations))
    assert.are.same({ "neoagent.catalog.refresh", "inspect" },
      ids(value:operations()))
    assert.are.equal("API key", assert(assert(assert(assert(value:info()).state).blocks)[1]).value)
    local duplicate, duplicate_err = value:login()
    assert.is_nil(duplicate)
    assert.matches("unavailable", assert(duplicate_err).message)

    assert.is_true(wait(assert(value:logout())).ok)
    assert.are.same({ "Log in" }, labels(assert(value:info()).operations))
    assert.is_false(value:cancel_login())
  end)

  it("presents login choices in the open provider menu", function()
    local auth = authentication()
    auth.login = function(self, id, opts)
      return async.run(function()
        self.login_choice = async.await(function(done)
          return opts.prompt({
            type = "select",
            message = "Select OpenAI Codex login method:",
            options = {
              { id = "browser", label = "Browser login (default)" },
              { id = "device_code", label = "Device code login (headless)" },
            },
          }, done)
        end)
        return { ok = true, method = id, revision = 1 }
      end, { on_done = opts and opts.on_done, error_kind = "auth" })
    end
    local fallback_select = false
    vim.ui.select = function()
      fallback_select = true
    end
    local surface = view()
    surface.set_presentation = function(self, snapshot)
      self.presentation = util.copy(snapshot)
      return true
    end
    local value = shell({
      config = config({
        fake = { api = "fake", models = {}, auth = "key" },
      }, "fake"),
      auth = auth,
      runtimes = { fake = service("fake", "Fake") },
      view = function() return surface end,
    })
    assert(value:open())

    local login = assert(value:login())
    assert(type(login) == "table")
    local info = value:info()

    assert.is_false(fallback_select)
    assert.are.same({
      "Browser login (default)",
      "Device code login (headless)",
      "Cancel login",
    }, labels(assert(info).operations))
    assert.are.equal("Select OpenAI Codex login method:",
      assert(info).operation_prompt)
    assert(value:run(assert(assert(info).operations[1]).id))
    assert.is_true(wait(login).ok)
    assert.are.equal("browser", auth.login_choice)
  end)

  it("keeps owned authentication feedback in the provider shell", function()
    local surface = view()
    surface.set_presentation = function(self, snapshot)
      self.presentation = util.copy(snapshot)
      return true
    end
    local value = shell({
      config = config({
        fake = { api = "fake", models = {}, auth = "key" },
      }, "fake"),
      auth = authentication(),
      runtimes = { fake = service("fake", "Fake") },
      view = function() return surface end,
    })
    assert(value:open())

    assert.is_true(wait(assert(value:login())).ok)
    assert(vim.wait(1000, function()
      return #surface.notifications > 0
        or any(assert(assert(assert(value:info()).state).blocks), function(block)
          return block.type == "status"
            and block.text:find("logged in with API key", 1, true) ~= nil
        end)
    end, 5))
    assert.are.same({}, surface.notifications)
    assert(any(assert(assert(assert(value:info()).state).blocks), function(block)
      return block.type == "status"
        and block.text:find("logged in with API key", 1, true) ~= nil
    end))
  end)

  it("projects authentication failures as disconnected errors", function()
    local auth = authentication()
    auth.has_credentials = function(self)
      return nil, util.error("auth", "credential store failed")
    end
    local surface = view()
    local value = shell({
      config = config({
        fake = { api = "fake", models = {}, auth = "key" },
      }, "fake"),
      auth = auth,
      runtimes = { fake = service("fake", "Fake") },
      presenter = presenter(),
      view = function() return surface end,
    })

    assert.are.same({
      connected = false,
      error = true,
    }, provider(surface, "fake").authentication)
    assert.are.equal("credential store failed",
      assert(assert(assert(assert(value:info()).state).blocks)[1]).value)
    assert.are.same({ "Log in" }, labels(assert(value:info()).operations))
  end)

  it("projects usable optional, configured, and environment credentials", function()
    local surface = view()
    local value = shell({
      config = config({
        configured = {
          api = "fake",
          catalog = { discover = function() error("unexpected catalog discovery") end },
          models = {},
          auth = "key",
          api_key = "literal",
        },
        environment = {
          api = "fake",
          catalog = { discover = function() error("unexpected catalog discovery") end },
          models = {},
          auth = "key",
          api_key = function() return "ambient" end,
        },
        optional = {
          api = "fake",
          catalog = { discover = function() error("unexpected catalog discovery") end },
          models = {},
          auth = "key",
          auth_optional = true,
        },
      }, "optional"),
      auth = authentication(),
      runtimes = {
        configured = service("configured", "Configured"),
        environment = service("environment", "Environment"),
        optional = service("optional", "Optional"),
      },
      presenter = presenter(),
      view = function() return surface end,
    })
    assert.are.same({
      connected = true,
      source = "configured",
      error = false,
    }, provider(surface, "configured").authentication)
    assert.are.same({
      connected = true,
      source = "environment",
      error = false,
    }, provider(surface, "environment").authentication)
    assert.are.same({
      connected = true,
      error = false,
    }, provider(surface, "optional").authentication)
    assert.are.same({ "Log in", "Refresh model catalog", "Inspect" },
      labels(assert(value:info()).operations))
    assert.are.same({ "neoagent.catalog.refresh", "inspect" },
      ids(value:operations()))
    assert.are.equal("Optional", assert(assert(assert(assert(value:info()).state).blocks)[1]).value)
    assert.are.equal("environment", value:select("environment"))
    assert.are.same({ "neoagent.catalog.refresh", "inspect" },
      ids(assert(value:info()).operations))
    assert.are.equal("Environment credential",
      assert(assert(assert(assert(value:info()).state).blocks)[1]).value)
    local logout, err = value:logout()
    assert.is_nil(logout)
    assert.matches("unavailable", assert(err).message)
    assert.are.equal("configured", value:select("configured"))
    assert.are.same({ "Refresh model catalog", "Inspect" },
      labels(assert(value:info()).operations))
    assert.are.equal("Configured credential",
      assert(assert(assert(assert(value:info()).state).blocks)[1]).value)
  end)

  it("allows a login method to augment an ambient credential", function()
    local configured = config({ fake = {
      api = "fake",
      models = {},
      auth = "key",
      api_key = function() return "ambient" end,
    } }, "fake")
    configured.auth.methods.key.login_with_ambient = true
    local value = shell({
      config = configured,
      auth = authentication(),
      runtimes = { fake = service("fake", "Fake") },
      presenter = presenter(),
      view = function() return view() end,
    })

    assert.are.same({ "Log in", "Inspect" },
      labels(assert(value:info()).operations))
    assert.is_true(wait(assert(value:login())).ok)
    assert.are.same({ "Inspect", "Log out" },
      labels(assert(value:info()).operations))
  end)

  it("keeps primary and scoped authentication actions independent", function()
    local configured = config({ fake = {
      api = "fake",
      models = {},
      auth = "key",
      auth_scopes = { dashboard = "dashboard" },
    } }, "fake")
    configured.auth.methods.key.login_label = "Login"
    configured.auth.methods.key.logout_label = "Logout"
    configured.auth.methods.dashboard = require("neoagent.auth.api_key").new({ name = "Dashboard authorization" })
    configured.auth.methods.dashboard.login_label = "Login to dashboard (optional to see quotas)"
    configured.auth.methods.dashboard.logout_label = "Logout from dashboard"

    local auth = authentication()
    local value = shell({
      config = configured,
      auth = auth,
      runtimes = { fake = service("fake", "Fake") },
      presenter = presenter(),
      view = function() return view() end,
    })

    assert.are.same({
      "Login",
      "Login to dashboard (optional to see quotas)",
    },
      labels(assert(value:info()).operations))
    assert.is_true(wait(assert(value:run(
      "neoagent.auth.login:dashboard"))).ok)
    assert.is_nil(auth.credentials.key)
    assert.are.equal("api_key", auth.credentials.dashboard)
    assert.are.same({ "Login", "Logout from dashboard" },
      labels(assert(value:info()).operations))
    assert.are.equal("Logged out", assert(assert(assert(assert(value:info()).state).blocks)[1]).value)
    assert.are.equal("Dashboard authorization",
      assert(assert(assert(assert(value:info()).state).blocks)[2]).label)
    assert.are.equal("Logged in", assert(assert(assert(assert(value:info()).state).blocks)[2]).value)

    assert.is_true(wait(assert(value:login())).ok)
    assert.are.equal("api_key", auth.credentials.key)
    assert.are.same({ "Inspect", "Logout", "Logout from dashboard" },
      labels(assert(value:info()).operations))

    assert.is_true(wait(assert(value:run(
      "neoagent.auth.logout:dashboard"))).ok)
    assert.are.equal("api_key", auth.credentials.key)
    assert.is_nil(auth.credentials.dashboard)
    assert.are.same({
      "Login to dashboard (optional to see quotas)",
      "Inspect",
      "Logout",
    }, labels(assert(value:info()).operations))
  end)

  it("gates Provider Service operations by their authentication scope", function()
    local resolved_method
    local managed = service("fake", "Fake", {
      hidden = {
        label = "Hidden management action",
        auth_scope = "unconfigured",
        run = function() error("must not run") end,
      },
      inspect = operation("Inspect"),
      quotas = {
        label = "Show quotas",
        auth_scope = "dashboard",
        run = function(ctx)
          return async.run(function()
            local resolved = ctx.resolve_auth("dashboard"):await()
            resolved_method = resolved.method
            return { ok = true }
          end)
        end,
      },
    })
    local configured = config({ fake = {
      api = "fake",
      models = {},
      auth = "key",
      auth_scopes = { dashboard = "dashboard" },
    } }, "fake")
    configured.auth.methods.dashboard = require("neoagent.auth.api_key").new({ name = "Dashboard authorization" })
    configured.auth.methods.dashboard.login_label = "Log in to dashboard"
    configured.auth.methods.dashboard.logout_label = "Log out from dashboard"

    local value = shell({
      config = configured,
      auth = authentication({ dashboard = "api_key" }),
      runtimes = { fake = managed },
      presenter = presenter(),
      view = function() return view() end,
    })

    assert.are.same({ "Log in", "Show quotas", "Log out from dashboard" },
      labels(assert(value:info()).operations))
    assert.are.same({ "quotas" }, ids(value:operations()))
    assert.is_true(wait(assert(value:run("quotas"))).ok)
    assert.are.equal("dashboard", resolved_method)
    local unavailable, err = value:run("inspect")
    assert.is_nil(unavailable)
    assert.matches("Log in", assert(err).message)
    unavailable, err = value:run("hidden")
    assert.is_nil(unavailable)
    assert.matches("scope is unavailable", assert(err).message)
  end)

  it("confirms logout before removing stored credentials", function()
    local auth = authentication({ key = "api_key" })
    local presented = presenter()
    presented.confirm_value = false
    local value = shell({
      config = config({ fake = {
        api = "fake",
        models = {},
        auth = "key",
      } }, "fake"),
      auth = auth,
      runtimes = { fake = service("fake", "Fake") },
      presenter = presented,
      view = function() return view() end,
    })

    local rejected = wait(assert(value:logout()))
    assert.is_false(rejected.ok)
    assert.are.equal("cancelled", assert(rejected.error).kind)
    assert.are.equal("api_key", auth.credentials.key)
    assert.are.same({
      prompt = "Log out of API key?",
      accept_label = "Log out",
      reject_label = "Cancel",
    }, assert(presented.requests[1]).request)

    presented.confirm_error = util.error(
      "presentation", "confirmation unavailable")
    local unavailable = wait(assert(value:logout()))
    assert.is_false(unavailable.ok)
    assert.matches("confirmation unavailable", assert(unavailable.error).message)
    assert.are.equal("api_key", auth.credentials.key)

    presented.confirm_error = nil
    presented.confirm_value = true
    local logout = value.authentication.logout
    value.authentication.logout = function()
      return nil, util.error("auth", "logout unavailable")
    end
    unavailable = wait(assert(value:logout()))
    assert.is_false(unavailable.ok)
    assert.matches("logout unavailable", assert(unavailable.error).message)
    assert.are.equal("api_key", auth.credentials.key)

    value.authentication.logout = logout
    assert.is_true(wait(assert(value:logout())).ok)
    assert.is_nil(auth.credentials.key)
  end)

  it("forces catalog refreshes and projects catalog status", function()
    local selected_catalog = catalog({ one = {}, two = {} }, {
      source = "cache",
      stale = true,
      refresh = {
        state = "failed",
        error = { kind = "transport", message = "catalog offline" },
      },
    })
    local managed = service("fake", "Fake")
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = {
        id = "fake",
        definition = {
          api = "fake",
          catalog = { discover = function() error("unexpected catalog discovery") end },
          models = {},
        },
        catalog = selected_catalog,
        service = managed,
      } },
      presenter = presenter(),
      view = function() return view() end,
    })
    local info = value:info()
    assert.are.equal("2 available", assert(assert(assert(assert(info).state).blocks)[2]).value)
    assert.are.equal("cache · stale", assert(assert(assert(assert(info).state).blocks)[3]).value)
    assert.are.equal("error", assert(assert(assert(assert(info).state).blocks)[3]).level)
    assert.are.equal("catalog offline", assert(assert(assert(assert(info).state).blocks)[4]).text)

    assert.is_true(wait(assert(value:run(
      "neoagent.catalog.refresh"))).ok)
    assert.are.equal(1, selected_catalog.refreshes)
    info = value:info()
    assert.are.equal("source · fresh", assert(assert(assert(assert(info).state).blocks)[3]).value)
    assert.are.equal("success", assert(assert(assert(assert(info).state).blocks)[3]).level)
    assert.are.equal("succeeded", assert(assert(assert(info).state).operation).state)
  end)

  it("omits catalog refresh for static catalogs", function()
    local value = shell({
      config = config({ fake = {
        api = "fake",
        catalog = { seed = { { id = "model" } } },
        models = {},
      } }, "fake"),
      auth = authentication(),
      runtimes = { fake = service("fake", "Fake") },
      presenter = presenter(),
      view = function() return view() end,
    })

    assert.are.same({ "Inspect" }, labels(assert(value:info()).operations))
    local run, err = value:run("neoagent.catalog.refresh")
    assert.is_nil(run)
    assert.matches("Unknown provider operation", assert(err).message)
  end)

  it("reports disabled persistence for a usable catalog", function()
    local value = shell({
      config = config({ fake = {
        api = "fake", models = {}, auth = "key", auth_optional = true,
      } }, "fake"),
      auth = authentication(),
      runtimes = { fake = {
        id = "fake",
        definition = {
          api = "fake", models = {}, auth = "key", auth_optional = true,
        },
        catalog = catalog({}, { persistence = {
          configured = true,
          enabled = false,
          error = { kind = "auth", message = "identity unavailable" },
        } }),
        service = service("fake", "Fake"),
      } },
      presenter = presenter(),
      view = function() return view() end,
    })

    local blocks = assert(assert(value:info()).state).blocks
    assert.are.equal("warn", assert(assert(blocks)[#blocks]).level)
    assert.matches("identity unavailable", (assert(assert(assert(blocks)[#blocks]).text)))
  end)

  it("shares model leases with shell operations and handles synchronous runs", function()
    local pending
    local managed = service("fake", "Fake", {
      inspect = operation("Inspect"),
      mutate = operation("Mutate", function()
        return async.run(function()
          return async.await(function(done)
            pending = done
            return function() done.reject(async.cancelled_error) end
          end)
        end)
      end, true),
    })
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = managed },
      presenter = presenter(),
      view = function() return view() end,
    })

    local active = assert(value:run("mutate"))
    assert(type(active) == "table")
    assert.is_true(value:is_active())
    local acquired, acquire_err = provider_service.acquire(managed)
    assert.is_nil(acquired)
    assert.matches("mutating provider operation", assert(acquire_err).message)
    assert.is_true(value:cancel())
    assert.is_false(wait(assert(active)).ok)
    assert.are.equal("cancelled", assert(assert(assert(value:info()).state).operation).state)

    local release = assert(provider_service.acquire(managed))
    local available = {}
    for _, descriptor in ipairs(value:operations()) do
      available[descriptor.id] = descriptor.enabled
    end
    assert.is_true(available.inspect)
    assert.is_false(available.mutate)
    local blocked, blocked_err = value:run("mutate")
    assert.is_nil(blocked)
    assert.matches("active provider use", assert(blocked_err).message)
    local inspect = assert(value:run("inspect"))
    assert(type(inspect) == "table")
    assert.is_true(wait(inspect).ok)
    assert.is_false(value:is_active())
    release()
    assert.is_table(pending)
  end)

  it("coordinates authentication across every Service sharing its method", function()
    local alpha = service("alpha", "Alpha")
    local beta = service("beta", "Beta")
    local group = { alpha, beta }
    local auth = authentication()
    local value = shell({
      config = config({
        alpha = { api = "fake", models = {}, auth = "key" },
        beta = { api = "fake", models = {}, auth = "key" },
      }, "alpha"),
      auth = auth,
      runtimes = {
        alpha = {
          id = "alpha",
          definition = { api = "fake", models = {}, auth = "key" },
          catalog = catalog(),
          service = alpha,
          auth_method = "key",
          auth_services = group,
        },
        beta = {
          id = "beta",
          definition = { api = "fake", models = {}, auth = "key" },
          catalog = catalog(),
          service = beta,
          auth_method = "key",
          auth_services = group,
        },
      },
      presenter = presenter(),
      view = function() return view() end,
    })
    local use = assert(provider_service.acquire_use(beta))

    local run, err = value:login()
    assert.is_nil(run)
    assert.matches("active provider use", assert(err).message)
    assert.is_nil(auth.credentials.key)
    assert.is_false(assert(assert(value:info()).operations[1]).enabled)
    local alpha_use = assert(provider_service.acquire_use(alpha))
    assert.is_true(alpha_use:release())

    assert.is_true(use:release())
    assert.is_true(wait(assert(value:login())).ok)
    local second_use = assert(provider_service.acquire_use(beta))
    run, err = value:logout()
    assert.is_nil(run)
    assert.matches("active provider use", assert(err).message)
    assert.are.equal("api_key", auth.credentials.key)
    assert.is_true(second_use:release())
    assert.is_true(wait(assert(value:logout())).ok)
  end)

  it("refreshes an ambient catalog after releasing logout coordination", function()
    local auth = authentication({ key = "api_key" })
    local managed = service("fake", "Fake")
    local selected_catalog = catalog()
    local refresh = selected_catalog.refresh
    selected_catalog.refresh = function(self, opts)
      local lease, err = provider_service.acquire_use(managed)
      assert(lease, err and err.message)
      assert.is_true(lease:release())
      return refresh(self, opts)
    end
    local value = shell({
      config = config({ fake = {
        api = "fake",
        models = {},
        auth = "key",
        api_key = function() return "ambient-secret" end,
      } }, "fake"),
      auth = auth,
      runtimes = { fake = {
        id = "fake",
        definition = {
          api = "fake",
          models = {},
          auth = "key",
          api_key = function() return "ambient-secret" end,
        },
        catalog = selected_catalog,
        service = managed,
        auth_services = { managed },
      } },
      presenter = presenter(),
      view = function() return view() end,
    })

    assert.is_true(wait(assert(value:logout())).ok)
    assert.are.equal(1, selected_catalog.refreshes)
    assert.are.equal("environment",
      assert(provider(value.view_value, "fake").authentication).source)
  end)

  it("cancels logout through the Shell action owner", function()
    local auth = authentication({ key = "api_key" })
    local started, cancelled = false, false
    auth.logout = function(self, _, opts)
      started = true
      return async.run(function()
        return async.await(function(done)
          return function()
            cancelled = true
            done.reject(async.cancelled_error)
          end
        end)
      end, { on_done = opts and opts.on_done, error_kind = "auth" })
    end
    local managed = service("fake", "Fake")
    local value = shell({
      config = config({
        fake = { api = "fake", models = {}, auth = "key" },
      }, "fake"),
      auth = auth,
      runtimes = { fake = {
        id = "fake",
        definition = { api = "fake", models = {}, auth = "key" },
        catalog = catalog(),
        service = managed,
        auth_method = "key",
        auth_services = { managed },
      } },
      presenter = presenter(),
      view = function() return view() end,
    })

    local run = assert(value:logout())
    assert(type(run) == "table")
    assert.is_true(value:is_active())
    assert(vim.wait(1000, function() return started end, 5))
    assert.is_true(value:cancel())
    assert.is_false(wait(run).ok)
    assert.is_true(cancelled)
    assert.is_false(value:is_active())
  end)

  it("contains malformed authentication action constructors", function()
    local auth = authentication()
    local managed = service("fake", "Fake")
    local value = shell({
      config = config({
        fake = { api = "fake", models = {}, auth = "key" },
      }, "fake"),
      auth = auth,
      runtimes = { fake = {
        id = "fake",
        definition = { api = "fake", models = {}, auth = "key" },
        catalog = catalog(),
        service = managed,
        auth_method = "key",
        auth_services = { managed },
      } },
      presenter = presenter(),
      view = function() return view() end,
    })

    auth.login = function() error("login construction failed") end
    local thrown = assert(value:login())
    assert(type(thrown) == "table")
    assert.is_false(wait(thrown).ok)
    assert.matches("login construction failed", assert(assert(thrown:result()).error).message)
    assert.is_false(value:is_active())
    local use = assert(provider_service.acquire_use(managed))
    assert.is_true(use:release())

    auth.login = function() return {} end
    local malformed = assert(value:login())
    assert(type(malformed) == "table")
    assert.is_false(wait(malformed).ok)
    assert.matches("must return a Run", assert(assert(malformed:result()).error).message)
    assert.is_false(value:is_active())
    use = assert(provider_service.acquire_use(managed))
    assert.is_true(use:release())
  end)

  it("projects progress and opens bounded operation artifacts", function()
    local opened
    local managed = service("fake", "Fake", {
      report = operation("Report", function(ctx)
        ctx.interact.progress({
          id = "report",
          label = "Report",
          state = "running",
          message = "Loading",
          current = 1,
          total = 2,
        })
        return async.run(function()
          return {
            ok = true,
            artifact = {
              kind = "document",
              name = "usage.md",
              filetype = "markdown",
              content = "# Usage\n",
            },
          }
        end)
      end),
    })
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = managed },
      presenter = presenter(),
      host_effects = {
        on_exit = Applet.host_effects.on_exit,
        refresh_file = Applet.host_effects.refresh_file,
        open_document = function(document)
          opened = util.copy(document)
          return true
        end,
      },
      view = function() return view() end,
    })

    assert.is_true(wait(assert(value:run("report"))).ok)
    assert.are.equal("succeeded", assert(assert(assert(value:info()).state).operation).state)
    assert.are.same({
      name = "usage.md",
      filetype = "markdown",
      content = "# Usage\n",
    }, opened)
  end)

  it("routes provider interactions through the shell Presenter", function()
    local answers
    local presented = presenter()
    local managed = service("fake", "Fake", {
      interactive = operation("Interactive", function(ctx)
        return async.run(function()
          local selected = async.await(function(done)
            return ctx.interact.select({
              prompt = "Choose workspace",
              items = { { id = "alpha", label = "Alpha" } },
            }, done)
          end)
          local input = async.await(function(done)
            return ctx.interact.input({
              prompt = "Name preset",
              default = "coding",
            }, done)
          end)
          local secret = async.await(function(done)
            return ctx.interact.input({
              prompt = "API key",
              secret = true,
            }, done)
          end)
          local confirmed = async.await(function(done)
            return ctx.interact.confirm({ prompt = "Apply preset?" }, done)
          end)
          ctx.interact.notify("Preset ready")
          answers = { selected, input, secret, confirmed }
          return { ok = true }
        end)
      end),
    })
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = managed },
      presenter = presented,
      view = function() return view() end,
    })

    assert.is_true(wait(assert(value:run("interactive"))).ok)
    assert.are.same({ "alpha", "coding", "", true }, answers)
    assert.are.same({ "select", "input", "input", "confirm" },
      vim.tbl_map(function(entry) return entry.kind end, presented.requests))
    assert.are.equal("Choose workspace", assert(presented.requests[1]).request.prompt)
    assert.are.equal("Name preset", assert(presented.requests[2]).request.prompt)
    assert.are.equal("API key", assert(presented.requests[3]).request.prompt)
    assert.is_true(assert(presented.requests[3]).request.secret)
    assert.are.equal("Apply preset?", assert(presented.requests[4]).request.prompt)
    assert.matches("Preset ready", assert(presented.notifications[1]).message)
    assert.are.equal(presented, value:presenter())
  end)

  it("rejects invalid and failed provider selections", function()
    local presented = presenter()
    local managed = service("fake", "Fake", {
      invalid = operation("Invalid selection", function(ctx)
        return async.run(function()
          async.await(function(done)
            local malformed = {}
        ---@cast malformed Neoagent.SelectRequest
        return ctx.interact.select(malformed, done)
          end)
          return { ok = true }
        end)
      end),
      rejected = operation("Rejected selection", function(ctx)
        return async.run(function()
          async.await(function(done)
            return ctx.interact.select({ items = { "alpha" } }, done)
          end)
          return { ok = true }
        end)
      end),
    })
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = managed },
      presenter = presented,
      view = function() return view() end,
    })

    local invalid = wait(assert(value:run("invalid")))

    assert.is_false(invalid.ok)
    assert.matches("Select requires items", assert(invalid.error).message)

    presented.select = function()
      return async.run(function()
        error(util.error("presentation", "selection closed"), 0)
      end, { error_kind = "presentation" })
    end
    local rejected = wait(assert(value:run("rejected")))

    assert.is_false(rejected.ok)
    assert.matches("selection closed", assert(rejected.error).message)
  end)

  it("runs each service refresh operation whenever its shell is focused", function()
    local calls = { alpha = 0, beta = 0 }
    ---@type Neoagent.AwaitCallbacks<Neoagent.ProviderOperationResult>?
    local inspect_done
    local services = {}
    for _, id in ipairs({ "alpha", "beta" }) do
      services[id] = service(id, id, {
        refresh = operation("Refresh", function()
          calls[id] = calls[id] + 1
          return async.run(function() return { ok = true } end)
        end),
        inspect = operation("Inspect", function()
          return async.run(function()
            return async.await(function(done)
              inspect_done = done
              return function() done.reject(async.cancelled_error) end
            end)
          end)
        end),
      })
    end
    local value = shell({
      config = config({
        alpha = { api = "fake", models = {} },
        beta = { api = "fake", models = {} },
      }, "alpha"),
      auth = authentication(),
      runtimes = services,
      presenter = presenter(),
      view = function() return view() end,
    })

    assert(value:open())
    assert.are.equal(1, calls.alpha)
    assert(vim.wait(1000, function() return not value:is_active() end, 5))

    local inspect = assert(value:run("inspect"))
    assert(type(inspect) == "table")
    assert(vim.wait(1000, function() return inspect_done ~= nil end, 5))
    assert(value:open())
    assert.are.equal(1, calls.alpha)
    assert(inspect_done).resolve({ ok = true })
    assert(vim.wait(1000, function()
      return inspect:is_done() and calls.alpha == 2 and not value:is_active()
    end, 5))

    assert(value:open())
    assert.are.equal(3, calls.alpha)
    assert(vim.wait(1000, function() return not value:is_active() end, 5))
    value:close()
    assert(value:open())
    assert.are.equal(4, calls.alpha)
    assert(vim.wait(1000, function() return not value:is_active() end, 5))
    assert.are.equal("beta", value:select("beta"))
    assert.are.equal(1, calls.beta)
  end)

  it("bounds completion, subscriptions, failures, and active actions", function()
    ---@type fun()?
    local provider_callback
    local cancelled = false
    local managed = service("fake", "Fake", {
      complete = {
        label = "Complete",
        mutating = false,
        complete = function(lead, args)
          assert.are.equal("a", lead)
          assert.are.equal("context", args)
          local malformed = { "azure", "alpha", "beta", "", "bad\nvalue", 42 }
          ---@cast malformed string[]
          return malformed
        end,
        run = function()
          return async.run(function() return { ok = true } end)
        end,
      },
      fail = operation("Fail", function()
        return async.run(function()
          error(util.error("provider", "operation failed"), 0)
        end)
      end),
      pending = operation("Pending", function()
        return async.run(function()
          return async.await(function(done)
            return function()
              cancelled = true
              done.reject(async.cancelled_error)
            end
          end)
        end)
      end),
      report = operation("Report", function()
        return async.run(function()
          return { ok = true, artifact = {
            kind = "document",
            name = "report.md",
            filetype = "markdown",
            content = "report",
          } }
        end)
      end),
    }, function() error("state failed") end)
    managed.subscribe = function(_, callback)
      provider_callback = callback
      return function() end
    end
    local surface = view()
    local presented = presenter()
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = managed },
      presenter = presented,
      host_effects = {
        on_exit = Applet.host_effects.on_exit,
        refresh_file = Applet.host_effects.refresh_file,
        open_document = function()
          return nil, util.error("ui", "document failed")
        end,
      },
      view = function() return surface end,
    })

    assert.are.equal("Provider state is unavailable",
      assert(assert(assert(assert(value:info()).state).blocks)[1]).text)
    assert.is_function(provider_callback)
    assert(provider_callback)()
    assert(vim.wait(1000, function()
      return value.refresh_scheduled == false
    end, 5))
    assert.are.same({ "alpha", "azure" },
      value:completion("complete", "a", "context"))
    assert.are.same({}, value:completion("missing", "", ""))
    managed.operations.complete.complete = function() error("completion failed") end
    assert.are.same({}, value:completion("complete", "", ""))
    assert.are.equal("fake", value:select("fake"))
    local cycled, cycle_err = value:cycle(0)
    assert.is_nil(cycled)
    assert.matches("step must be", assert(cycle_err).message)

    local pending = assert(value:run("pending"))
    assert(type(pending) == "table")
    local blocked, blocked_err = value:run("complete")
    assert.is_nil(blocked)
    assert.matches("already active", assert(blocked_err).message)
    assert.is_true(value:cancel())
    assert.is_false(wait(pending).ok)
    assert.is_true(cancelled)

    local failed = assert(value:run("fail"))
    assert(type(failed) == "table")
    assert.is_false(wait(failed).ok)
    assert.are.equal("failed", assert(assert(assert(value:info()).state).operation).state)
    assert.are.equal("operation failed", assert(assert(assert(value:info()).state).operation).detail)
    assert.is_true(wait(assert(value:run("report"))).ok)
    assert.is_true(any(presented.notifications, function(notification)
      return notification.message:match("failed to open provider document")
        ~= nil
    end))

    surface.set = function() return nil, util.error("ui", "surface failed") end
    assert.is_nil(value:_refresh())
    assert.matches("surface failed",
      presented.notifications[#presented.notifications].message)
    surface.set = function() error("surface exploded") end
    assert.is_nil(value:_refresh())
    assert.matches("surface exploded",
      presented.notifications[#presented.notifications].message)
  end)

  it("cancels login actions and reports provider adapter failures", function()
    local auth = authentication()
    auth.login = function(self, _, opts)
      return async.run(function()
        return async.await(function(done)
          return function() done.reject(async.cancelled_error) end
        end)
      end, { on_done = opts and opts.on_done, error_kind = "auth" })
    end
    local managed = service("fake", "Fake")
    managed.subscribe = function() error("subscription failed") end
    local surface = view()
    local value = shell({
      config = config({ fake = {
        api = "fake",
        models = {},
        auth = "key",
      }, other = { api = "fake", models = {} } }, "fake"),
      auth = auth,
      runtimes = { fake = managed, other = service("other", "Other") },
      view = function() return surface end,
    })

    assert.matches("subscription failed", assert(surface.notifications[1])[1])
    value:presenter():notify({ message = "notice" })
    assert.are.equal("notice", assert(surface.notifications[#surface.notifications])[1])
    value:presenter():open_uri({ uri = "https://example.test" })
    assert.are.equal("https://example.test", surface.uris[1])
    local login = assert(value:login("fake"))
    assert(type(login) == "table")
    assert.is_true(value:is_authenticating())
    assert.are.same({ "Cancel login" }, labels(assert(value:info()).operations))
    local changed, changed_err = value:select("other")
    assert.is_nil(changed)
    assert.matches("Finish the active provider action", assert(changed_err).message)
    assert.is_true((value:run(assert(assert(value:info()).operations[1]).id)))
    assert.is_false(wait(login).ok)
    assert.is_false(value:cancel_login())

    local selected, select_err = value:login("missing")
    assert.is_nil(selected)
    assert.matches("Unknown provider", assert(select_err).message)
    selected, select_err = value:logout("missing")
    assert.is_nil(selected)
    assert.matches("Unknown provider", assert(select_err).message)

    local broken = shell({
      config = config({ broken = {
        api = "fake",
        models = {},
        auth = "key",
        api_key = function() error("environment failed") end,
      } }, "broken"),
      auth = authentication(),
      runtimes = { broken = service("broken", "Broken") },
      presenter = presenter(),
      view = function() return view() end,
    })
    assert.is_true(assert(assert(broken:info()).operations[1]).label == "Log in")
    local credential_text = assert(assert(assert(assert(broken:info()).state).blocks)[1]).value
    assert(type(credential_text) == "string")
    assert.matches("environment credential", credential_text)
  end)

  it("bounds service, selection, and lifecycle failures", function()
    local presented = presenter()
    local managed = service("broken", "Broken", {
      bad = operation("Bad", function(ctx)
        local malformed = { state = "invalid" }
        ---@cast malformed Neoagent.ProviderOperationStatus
        ctx.interact.progress(malformed)
        return async.run(function()
          return {
            ok = true,
            artifact = { kind = "document", name = "bad", content = 1 },
          }
        end)
      end),
    }, function() return { blocks = "invalid" } end)
    local value = shell({
      config = config({ broken = { api = "fake", models = {} } }, "broken"),
      auth = authentication(),
      runtimes = { broken = managed },
      presenter = presented,
      view = function() return view() end,
    })

    assert.are.equal("Provider state is unavailable",
      assert(assert(assert(assert(value:info()).state).blocks)[1]).text)
    assert.is_true(wait(assert(value:run("bad"))).ok)
    assert.is_true(#presented.notifications >= 3)
    assert.is_nil((value:select("missing")))
    assert.is_nil((value:run("missing")))
    value:destroy()
    assert.is_nil((value:open()))
    assert.is_nil((value:select("broken")))
    assert.is_nil((value:run("bad")))

    local empty_presenter = presenter()
    local empty = shell({
      config = config({}),
      auth = authentication(),
      runtimes = {},
      presenter = empty_presenter,
      view = function() return view() end,
    })
    local opened, err = empty:open()
    assert.is_nil(opened)
    assert.matches("No Provider Shell", assert(err).message)
    assert.matches("No Provider Shell", assert(empty_presenter.notifications[1]).message)
    local cycled, cycle_err = empty:cycle(1)
    assert.is_nil(cycled)
    assert.matches("No Provider Shell", assert(cycle_err).message)
    local run, run_err = empty:run("missing")
    assert.is_nil(run)
    assert.matches("No provider is selected", assert(run_err).message)
    assert.is_false(empty:cancel())

    local fallback_notifications, fallback_uris = {}, {}
    local original_notify = Applet.Presenter.notify
    local original_open_uri = Applet.Presenter.open_uri
    Applet.Presenter.notify = function(message, level)
      fallback_notifications[#fallback_notifications + 1] = { message, level }
      return true
    end
    Applet.Presenter.open_uri = function(uri)
      fallback_uris[#fallback_uris + 1] = uri
      return true
    end
    local fallback_view = view()
    rawset(fallback_view, "notify", false)
    rawset(fallback_view, "open_uri", false)
    local fallback_shell = shell({
      config = config({ fallback = { api = "fake", models = {} } },
        "fallback"),
      auth = authentication(),
      runtimes = { fallback = service("fallback", "Fallback") },
      view = function() return fallback_view end,
    })
    assert.is_true(fallback_shell:presenter():notify({ message = "notice" }))
    assert.is_true(fallback_shell:presenter():open_uri({
      uri = "https://example.test/fallback",
    }))
    Applet.Presenter.notify = original_notify
    Applet.Presenter.open_uri = original_open_uri
    assert.are.equal("notice", fallback_notifications[1][1])
    assert.are.equal("https://example.test/fallback", fallback_uris[1])
  end)

  it("routes owned selection resolution and cancellation from its surface", function()
    ---@type Neoagent.ProviderShellViewOptions?
    local callbacks
    local surface = view()
    surface.set_presentation = function(self, snapshot)
      self.presentation = util.copy(snapshot)
      return true
    end
    local managed = service("fake", "Fake", {
      choose = operation("Choose", function(ctx)
        return async.run(function()
          local selected = async.await(function(done)
            return ctx.interact.select({
              prompt = "Choose a value",
              items = {
                { id = "one", label = "One" },
                { id = "two", label = "Two" },
              },
            }, done)
          end)
          return { ok = true, selected = selected }
        end)
      end),
    })
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = managed },
      view = function(opts)
        callbacks = opts
        return surface
      end,
    })

    local function active_selection()
      assert(vim.wait(1000, function()
        return value.presentation and value.presentation.active
      end, 5))
      return assert(value.presentation).active
    end

    local resolved = assert(value:run("choose"))
    assert(type(resolved) == "table")
    local request = active_selection()
    assert.is_true(assert(assert(callbacks).on_presentation_resolve)(assert(request).id, "two"))
    assert.is_true(wait(resolved).ok)

    local surface_cancelled = assert(value:run("choose"))
    assert(type(surface_cancelled) == "table")
    request = active_selection()
    assert.is_true(assert(assert(callbacks).on_presentation_cancel)(assert(request).id))
    assert.is_false(wait(surface_cancelled).ok)

    local menu_cancelled = assert(value:run("choose"))
    assert(type(menu_cancelled) == "table")
    active_selection()
    local operations = assert(value:info()).operations
    assert.are.equal("Cancel", operations[#operations].label)
    assert.is_true((value:run(operations[#operations].id)))
    assert.is_false(wait(menu_cancelled).ok)
  end)

  it("contains provider presentation and presentation-open failures", function()
    local surface = view()
    surface.set_presentation = function(self, snapshot)
      if snapshot and snapshot.active then return false end
      return true
    end
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = service("fake", "Fake") },
      view = function() return surface end,
    })

    local rejected = wait(value:presenter():input({ prompt = "Code" }))
    assert.is_false(rejected.ok)
    assert.matches("presentation failed", assert(rejected.error).message)

    local unopened_surface = view()
    unopened_surface.set_presentation = function(self) return true end
    unopened_surface.open = function(self)
      return nil, util.error("ui", "surface cannot open")
    end
    local unopened_value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = service("fake", "Fake") },
      view = function() return unopened_surface end,
    })
    local unopened = wait(unopened_value:presenter():input({ prompt = "Code" }))
    assert.is_false(unopened.ok)
    assert.matches("surface cannot open", assert(unopened.error).message)
  end)

  it("bounds multibyte feedback and deduplicates an active focus refresh", function()
    ---@type Neoagent.AwaitCallbacks<Neoagent.ProviderOperationResult>?
    local finish
    local refreshes = 0
    local managed = service("fake", "Fake", {
      refresh = operation("Refresh", function()
        refreshes = refreshes + 1
        return async.run(function()
          return async.await(function(done) finish = done end)
        end)
      end),
    })
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = managed },
      view = function()
        local surface = view()
        surface.set_presentation = function(self) return true end
        return surface
      end,
    })

    assert.is_true(value:presenter():notify({ message = string.rep("é", 300) }))
    assert.is_true(util.is_valid_utf8(assert(value.feedback).text))
    assert.matches("…$", assert(value.feedback).text)
    assert(value:open())
    assert.are.equal(1, refreshes)
    assert(value:open())
    assert.are.equal(1, refreshes)
    assert.is_nil(value.pending_focus_provider_id)
    assert(finish).resolve({ ok = true })
    assert(vim.wait(1000, function() return not value:is_active() end, 5))
  end)

  it("contains malformed provider action contracts", function()
    local value = shell({
      config = config({ fake = { api = "fake", models = {} } }, "fake"),
      auth = authentication(),
      runtimes = { fake = service("fake", "Fake") },
      presenter = presenter(),
      view = function() return view() end,
    })
    local first = value:_start_action({
      kind = "logout",
      provider_id = "fake",
      start = function()
        return async.run(function() return async.await(function() end) end)
      end,
    })
    assert.is_true(value:is_authenticating())
    local coordination = { active = true, finished = false }
    function coordination:finish() self.finished = true return true end
    local duplicate, duplicate_err = value:_start_action({
      kind = "service", provider_id = "fake", coordination = coordination,
      start = function() error("unused") end,
    })
    assert.is_nil(duplicate)
    assert.matches("already active", assert(duplicate_err).message)
    assert.is_true(coordination.finished)
    assert(first):cancel()
    assert.is_false(wait(assert(first)).ok)

    local cases = {
      {
        start = function()
          return nil, util.error("provider", "action did not start")
        end,
        message = "action did not start",
      },
      {
        start = function() return {} end,
        message = "must return a Run",
      },
      {
        start = function()
          return async.run(function() return "invalid result" end)
        end,
        message = "invalid result",
      },
    }
    for _, case in ipairs(cases) do
      local result = wait(value:_start_action({
        kind = "service", provider_id = "fake", start = case.start,
      }))
      assert.is_false(result.ok)
      assert.matches(case.message, assert(result.error).message)
    end
  end)

  it("contains credential, snapshot, and runtime coordination failures", function()
    local presented = presenter()
    local managed = service("fake", "Fake")
    local selected_catalog = catalog({}, {
      persistence = {
        configured = true,
        enabled = false,
        error = { kind = "auth", message = "identity unavailable" },
      },
    })
    local selected_runtime = {
      id = "fake",
      definition = {
        api = "fake",
        catalog = { discover = function() error("unexpected catalog discovery") end },
        models = {},
      },
      catalog = selected_catalog,
      service = managed,
    }
    local value = shell({
      config = config({
        fake = { api = "fake", models = {} },
        other = { api = "fake", models = {} },
      }, "fake"),
      auth = authentication(),
      runtimes = {
        fake = selected_runtime,
        other = service("other", "Other"),
      },
      presenter = presented,
      view = function() return view() end,
    })
    assert.is_false(value:_auth_state("missing").usable)
    assert(any(assert(assert(assert(value:info()).state).blocks), function(block)
      return block.type == "status"
        and block.text:match("identity unavailable") ~= nil
    end))

    local is_active = value.authentication.is_active
    value.authentication.is_active = function() return true end
    local selected, select_err = value:select("other")
    value.authentication.is_active = is_active
    assert.is_nil(selected)
    assert.matches("Finish the active provider action", assert(select_err).message)

    local token = assert(provider_service.begin_operation(managed, {
      mutating = true,
    }))
    local refreshed, refresh_err = value:run("neoagent.catalog.refresh")
    assert.is_nil(refreshed)
    assert.matches("mutating provider operation", assert(refresh_err).message)
    assert.is_true(token:finish())

    local schedule_refresh = value._schedule_refresh
    value._schedule_refresh = function() error("runtime refresh failed") end
    token = assert(provider_service.begin_operation(managed, {
      mutating = false,
    }))
    assert(vim.wait(1000, function()
      return any(presented.notifications, function(notification)
        return notification.message:match("runtime subscriber failed") ~= nil
      end)
    end, 5))
    assert.is_true(token:finish())
    value._schedule_refresh = schedule_refresh

    selected_catalog.snapshot = function() error("snapshot failed") end
    assert.is_nil(value:_refresh())
    assert(any(presented.notifications, function(notification)
      return notification.message:match("snapshot failed") ~= nil
    end))

    value:destroy()
    local login, login_err = value:login()
    assert.is_nil(login)
    assert.matches("destroyed", assert(login_err).message)
    local logout, logout_err = value:logout()
    assert.is_nil(logout)
    assert.matches("destroyed", assert(logout_err).message)
  end)

  it("reports a deferred authentication action that becomes unavailable", function()
    local surface = view()
    local presented = presenter()
    local refresh = operation("Refresh", function()
      return async.run(function()
        return async.await(function(done)
          return function() done.reject(async.cancelled_error) end
        end)
      end)
    end)
    local value = shell({
      config = config({
        alpha = { api = "fake", models = {} },
        beta = { api = "fake", models = {} },
      }, "alpha"),
      auth = authentication(),
      runtimes = {
        alpha = service("alpha", "Alpha", { refresh = refresh }),
        beta = service("beta", "Beta"),
      },
      presenter = presented,
      view = function() return surface end,
    })

    assert(value:open())
    assert.is_true(value:is_active())
    assert.is_true((value:login("beta")))
    assert(vim.wait(1000, function()
      return assert(value:info()).id == "beta" and not value:is_active()
    end, 5))
    assert(any(presented.notifications, function(notification)
      return notification.message:match("Login is unavailable") ~= nil
    end))
  end)

  it("propagates provider selection failures from logout", function()
    ---@type Neoagent.AwaitCallbacks<Neoagent.ProviderOperationResult>?
    local finish
    local value = shell({
      config = config({
        alpha = { api = "fake", models = {} },
        beta = { api = "fake", models = {} },
      }, "alpha"),
      auth = authentication(),
      runtimes = {
        alpha = service("alpha", "Alpha"),
        beta = service("beta", "Beta"),
      },
      presenter = presenter(),
      view = function() return view() end,
    })
    local active = value:_start_action({
      kind = "logout", provider_id = "alpha",
      start = function()
        return async.run(function()
          return async.await(function(done) finish = done end)
        end)
      end,
    })
    assert.is_true(value:is_authenticating())
    local logged_out, err = value:logout("beta")
    assert.is_nil(logged_out)
    assert.matches("active provider action", assert(err).message)
    assert(finish).resolve({ ok = true })
    assert.is_true(wait(assert(active)).ok)
  end)
end)
