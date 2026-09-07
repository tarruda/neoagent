local async = require("neoagent.async")
local Applet = require("applet")
local ProviderShell = require("neoagent.provider_shell")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

describe("neoagent Provider Shell", function()
  local shells
  local original_ui_select

  before_each(function()
    shells = {}
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    for _, shell in ipairs(shells) do shell:destroy() end
    vim.ui.select = original_ui_select
  end)

  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end, 5))
    return run:result()
  end

  local function presenter()
    local value = {
      notifications = {},
      requests = {},
      uris = {},
      confirm_value = true,
    }
    local function resolved(result)
      return async.run(function() return { ok = true, value = result } end)
    end
    function value:select(request)
      self.requests[#self.requests + 1] = { kind = "select", request = request }
      local item = request.items[1]
      return resolved(type(item) == "table" and item.id or item)
    end
    function value:input(request)
      self.requests[#self.requests + 1] = { kind = "input", request = request }
      return resolved(request.default or "")
    end
    function value:confirm(request)
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
      self.notifications[#self.notifications + 1] = util.copy(request)
      return true
    end
    function value:open_uri(request)
      self.uris[#self.uris + 1] = request.uri
      return true
    end
    return value
  end

  local function authentication(initial)
    local credentials = util.copy(initial or {})
    local value = { credentials = credentials }
    function value:has_credentials(id)
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
    function value:login(id, opts)
      return async.run(function()
        self.credentials[id] = "api_key"
        return { ok = true, method = id }
      end, { on_done = opts.on_done, error_kind = "auth" })
    end
    function value:logout(id, opts)
      return async.run(function()
        self.credentials[id] = nil
        return { ok = true, method = id }
      end, { on_done = opts.on_done, error_kind = "auth" })
    end
    function value:resolve(id)
      return async.run(function()
        return {
          ok = true,
          method = id,
          configured = self.credentials[id] ~= nil,
        }
      end, { error_kind = "auth" })
    end
    return value
  end

  local function view()
    local value = {
      opened = false,
      snapshots = {},
      notifications = {},
      uris = {},
    }
    function value:set(snapshot, providers)
      self.snapshot = util.copy(snapshot)
      self.providers = util.copy(providers)
      self.snapshots[#self.snapshots + 1] = self.snapshot
      return true
    end
    function value:open(origin)
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
      return true
    end
    function value:open_uri(uri)
      self.uris[#self.uris + 1] = uri
      return true
    end
    function value:destroy()
      self.destroyed = true
      self.opened = false
    end
    return value
  end

  local function operation(label, run, mutating)
    return {
      label = label,
      mutating = mutating == true,
      run = run or function()
        return async.run(function() return { ok = true } end)
      end,
    }
  end

  local function service(id, name, operations, state)
    return {
      id = id,
      name = name,
      state = state or function()
        return { blocks = { { type = "status", text = "Ready" } } }
      end,
      operations = operations or {
        inspect = operation("Inspect"),
      },
    }
  end

  local function catalog(models, overrides)
    local listeners = {}
    local snapshot = util.deep_merge({
      revision = 0,
      models = util.copy(models or {}),
      validated_at = 1,
      stale = false,
      source = "packaged",
      refresh = { state = "idle" },
    }, overrides or {})
    local value = { refreshes = 0 }
    function value:snapshot() return util.copy(snapshot) end
    function value:subscribe(callback)
      listeners[callback] = true
      callback(self:snapshot())
      return function()
        listeners[callback] = nil
        return true
      end
    end
    function value:refresh(opts)
      assert.are.same({ force = true }, opts)
      self.refreshes = self.refreshes + 1
      snapshot.revision = snapshot.revision + 1
      snapshot.source = "source"
      snapshot.stale = false
      snapshot.refresh = { state = "idle" }
      for callback in pairs(listeners) do callback(self:snapshot()) end
      return async.run(function()
        return { ok = true, snapshot = self:snapshot() }
      end)
    end
    return value
  end

  local function runtime(selected, definition)
    definition = util.copy(definition or {
      api = "fake",
      catalog = {},
      models = {},
    })
    definition.catalog = definition.catalog or {}
    definition.models = definition.models or {}
    return {
      id = selected.id,
      definition = definition,
      catalog = catalog(definition.models),
      service = selected,
    }
  end

  local function config(providers, default_provider)
    return {
      default_model = default_provider and {
        provider = default_provider,
        model = "model",
      } or nil,
      providers = providers,
      auth = {
        path = "/tmp/neoagent-provider-shell-credentials.json",
        methods = {
          key = { name = "API key", type = "api_key" },
        },
      },
      ui = { renderer = {} },
    }
  end

  local function shell(opts)
    local selected = {}
    for key, value in pairs(opts) do selected[key] = value end
    selected.runtimes = {}
    for id, value in pairs(opts.runtimes or {}) do
      selected.runtimes[id] = value.service and value
        or runtime(value, opts.config.providers[id])
    end
    local value = ProviderShell.new(selected)
    shells[#shells + 1] = value
    return value
  end

  local function ids(operations)
    return vim.tbl_map(function(item) return item.id end, operations)
  end

  local function labels(operations)
    return vim.tbl_map(function(item) return item.label end, operations)
  end

  local function provider(surface, id)
    for _, entry in ipairs(surface.providers or {}) do
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

    assert.are.equal("beta", value:info().id)
    assert.are.same({ "alpha", "beta" },
      vim.tbl_map(function(item) return item.id end, value:providers()))
    assert(value:open(17))
    assert.are.equal(17, surface.origin)
    assert.is_true(value:is_open())
    assert.are.equal("alpha", value:select("alpha"))
    assert.are.equal("alpha", value:info().id)
    assert.is_false(value:toggle())
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
    assert.is_true(surface.providers[1].enabled)
    assert.is_true(surface.providers[2].enabled)
    assert.are.equal("alpha", value:cycle(-1))
    assert(vim.wait(1000, function()
      return value:info().id == "alpha" and not value:is_active()
    end, 5))
    assert.is_true(refresh_cancelled)

    assert.are.equal("beta", value:cycle(1))
    assert.is_true(value:is_active())
    assert.is_true(value:cancel())
    assert(vim.wait(1000, function() return not value:is_active() end, 5))
    local mutation = assert(value:run("mutate"))
    local selected, err = value:select("alpha")
    assert.is_nil(selected)
    assert.matches("active provider action", err.message)
    assert.are.equal("beta", value:info().id)
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
    configured.auth.methods["beta-key"] = {
      name = "Beta key", type = "api_key",
    }
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
    assert.is_true(value:login("beta"))
    assert(vim.wait(1000, function()
      return value:info().id == "beta"
        and auth.credentials["beta-key"] == "api_key"
        and not value:is_active()
    end, 5))
    assert.are.equal(1, refresh_cancellations)

    assert.are.equal("alpha", value:select("alpha"))
    assert.is_true(value:is_active())
    assert.is_true(value:logout("beta"))
    assert(vim.wait(1000, function()
      return value:info().id == "beta"
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
          catalog = { discover = function() end },
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
    assert.are.same({ "Log in" }, labels(value:info().operations))
    assert.are.same({}, value:operations())
    assert.are.equal("Logged out", value:info().state.blocks[1].value)
    local blocked, blocked_err = value:run("inspect")
    assert.is_nil(blocked)
    assert.matches("Log in", blocked_err.message)
    local logout, logout_err = value:logout()
    assert.is_nil(logout)
    assert.matches("unavailable", logout_err.message)

    assert.is_true(wait(assert(value:login())).ok)
    assert.are.same({
      connected = true,
      source = "stored",
      error = false,
    }, provider(surface, "fake").authentication)
    assert.are.same({ "Refresh model catalog", "Inspect", "Log out" },
      labels(value:info().operations))
    assert.are.same({ "neoagent.catalog.refresh", "inspect" },
      ids(value:operations()))
    assert.are.equal("API key", value:info().state.blocks[1].value)
    local duplicate, duplicate_err = value:login()
    assert.is_nil(duplicate)
    assert.matches("unavailable", duplicate_err.message)

    assert.is_true(wait(assert(value:logout())).ok)
    assert.are.same({ "Log in" }, labels(value:info().operations))
    assert.is_false(value:cancel_login())
  end)

  it("presents login choices in the open provider menu", function()
    local auth = authentication()
    function auth:login(id, opts)
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
        return { ok = true, method = id }
      end, { on_done = opts.on_done, error_kind = "auth" })
    end
    local fallback_select = false
    vim.ui.select = function()
      fallback_select = true
    end
    local surface = view()
    function surface:set_presentation(snapshot)
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
    local info = value:info()

    assert.is_false(fallback_select)
    assert.are.same({
      "Browser login (default)",
      "Device code login (headless)",
      "Cancel login",
    }, labels(info.operations))
    assert.are.equal("Select OpenAI Codex login method:",
      info.operation_prompt)
    assert(value:run(info.operations[1].id))
    assert.is_true(wait(login).ok)
    assert.are.equal("browser", auth.login_choice)
  end)

  it("keeps owned authentication feedback in the provider shell", function()
    local surface = view()
    function surface:set_presentation(snapshot)
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
        or vim.iter(value:info().state.blocks):any(function(block)
          return block.type == "status"
            and block.text:find("logged in with API key", 1, true) ~= nil
        end)
    end, 5))
    assert.are.same({}, surface.notifications)
    assert(vim.iter(value:info().state.blocks):any(function(block)
      return block.type == "status"
        and block.text:find("logged in with API key", 1, true) ~= nil
    end))
  end)

  it("projects authentication failures as disconnected errors", function()
    local auth = authentication()
    function auth:has_credentials()
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
      value:info().state.blocks[1].value)
    assert.are.same({ "Log in" }, labels(value:info().operations))
  end)

  it("projects usable optional, configured, and environment credentials", function()
    local surface = view()
    local value = shell({
      config = config({
        configured = {
          api = "fake",
          catalog = { discover = function() end },
          models = {},
          auth = "key",
          api_key = "literal",
        },
        environment = {
          api = "fake",
          catalog = { discover = function() end },
          models = {},
          auth = "key",
          api_key = function() return "ambient" end,
        },
        optional = {
          api = "fake",
          catalog = { discover = function() end },
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
      labels(value:info().operations))
    assert.are.same({ "neoagent.catalog.refresh", "inspect" },
      ids(value:operations()))
    assert.are.equal("Optional", value:info().state.blocks[1].value)
    assert.are.equal("environment", value:select("environment"))
    assert.are.same({ "neoagent.catalog.refresh", "inspect" },
      ids(value:info().operations))
    assert.are.equal("Environment credential",
      value:info().state.blocks[1].value)
    local logout, err = value:logout()
    assert.is_nil(logout)
    assert.matches("unavailable", err.message)
    assert.are.equal("configured", value:select("configured"))
    assert.are.same({ "Refresh model catalog", "Inspect" },
      labels(value:info().operations))
    assert.are.equal("Configured credential",
      value:info().state.blocks[1].value)
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
      labels(value:info().operations))
    assert.is_true(wait(assert(value:login())).ok)
    assert.are.same({ "Inspect", "Log out" },
      labels(value:info().operations))
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
    configured.auth.methods.dashboard = {
      name = "Dashboard authorization",
      type = "api_key",
      login_label = "Login to dashboard (optional to see quotas)",
      logout_label = "Logout from dashboard",
    }
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
      labels(value:info().operations))
    assert.is_true(wait(assert(value:run(
      "neoagent.auth.login:dashboard"))).ok)
    assert.is_nil(auth.credentials.key)
    assert.are.equal("api_key", auth.credentials.dashboard)
    assert.are.same({ "Login", "Logout from dashboard" },
      labels(value:info().operations))
    assert.are.equal("Logged out", value:info().state.blocks[1].value)
    assert.are.equal("Dashboard authorization",
      value:info().state.blocks[2].label)
    assert.are.equal("Logged in", value:info().state.blocks[2].value)

    assert.is_true(wait(assert(value:login())).ok)
    assert.are.equal("api_key", auth.credentials.key)
    assert.are.same({ "Inspect", "Logout", "Logout from dashboard" },
      labels(value:info().operations))

    assert.is_true(wait(assert(value:run(
      "neoagent.auth.logout:dashboard"))).ok)
    assert.are.equal("api_key", auth.credentials.key)
    assert.is_nil(auth.credentials.dashboard)
    assert.are.same({
      "Login to dashboard (optional to see quotas)",
      "Inspect",
      "Logout",
    }, labels(value:info().operations))
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
    configured.auth.methods.dashboard = {
      name = "Dashboard authorization",
      type = "api_key",
      login_label = "Log in to dashboard",
      logout_label = "Log out from dashboard",
    }
    local value = shell({
      config = configured,
      auth = authentication({ dashboard = "api_key" }),
      runtimes = { fake = managed },
      presenter = presenter(),
      view = function() return view() end,
    })

    assert.are.same({ "Log in", "Show quotas", "Log out from dashboard" },
      labels(value:info().operations))
    assert.are.same({ "quotas" }, ids(value:operations()))
    assert.is_true(wait(assert(value:run("quotas"))).ok)
    assert.are.equal("dashboard", resolved_method)
    local unavailable, err = value:run("inspect")
    assert.is_nil(unavailable)
    assert.matches("Log in", err.message)
    unavailable, err = value:run("hidden")
    assert.is_nil(unavailable)
    assert.matches("scope is unavailable", err.message)
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
    assert.are.equal("cancelled", rejected.error.kind)
    assert.are.equal("api_key", auth.credentials.key)
    assert.are.same({
      prompt = "Log out of API key?",
      accept_label = "Log out",
      reject_label = "Cancel",
    }, presented.requests[1].request)

    presented.confirm_error = util.error(
      "presentation", "confirmation unavailable")
    local unavailable = wait(assert(value:logout()))
    assert.is_false(unavailable.ok)
    assert.matches("confirmation unavailable", unavailable.error.message)
    assert.are.equal("api_key", auth.credentials.key)

    presented.confirm_error = nil
    presented.confirm_value = true
    local logout = value.authentication.logout
    value.authentication.logout = function()
      return nil, util.error("auth", "logout unavailable")
    end
    unavailable = wait(assert(value:logout()))
    assert.is_false(unavailable.ok)
    assert.matches("logout unavailable", unavailable.error.message)
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
          catalog = { discover = function() end },
          models = {},
        },
        catalog = selected_catalog,
        service = managed,
      } },
      presenter = presenter(),
      view = function() return view() end,
    })
    local info = value:info()
    assert.are.equal("2 available", info.state.blocks[2].value)
    assert.are.equal("cache · stale", info.state.blocks[3].value)
    assert.are.equal("error", info.state.blocks[3].level)
    assert.are.equal("catalog offline", info.state.blocks[4].text)

    assert.is_true(wait(assert(value:run(
      "neoagent.catalog.refresh"))).ok)
    assert.are.equal(1, selected_catalog.refreshes)
    info = value:info()
    assert.are.equal("source · fresh", info.state.blocks[3].value)
    assert.are.equal("success", info.state.blocks[3].level)
    assert.are.equal("succeeded", info.state.operation.state)
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

    assert.are.same({ "Inspect" }, labels(value:info().operations))
    local run, err = value:run("neoagent.catalog.refresh")
    assert.is_nil(run)
    assert.matches("Unknown provider operation", err.message)
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

    local blocks = value:info().state.blocks
    assert.are.equal("warn", blocks[#blocks].level)
    assert.matches("identity unavailable", blocks[#blocks].text)
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
    assert.is_true(value:is_active())
    local acquired, acquire_err = provider_service.acquire(managed)
    assert.is_nil(acquired)
    assert.matches("mutating provider operation", acquire_err.message)
    assert.is_true(value:cancel())
    assert.is_false(wait(active).ok)
    assert.are.equal("cancelled", value:info().state.operation.state)

    local release = assert(provider_service.acquire(managed))
    local available = {}
    for _, descriptor in ipairs(value:operations()) do
      available[descriptor.id] = descriptor.enabled
    end
    assert.is_true(available.inspect)
    assert.is_false(available.mutate)
    local blocked, blocked_err = value:run("mutate")
    assert.is_nil(blocked)
    assert.matches("active provider use", blocked_err.message)
    local inspect = assert(value:run("inspect"))
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
    assert.matches("active provider use", err.message)
    assert.is_nil(auth.credentials.key)
    assert.is_false(value:info().operations[1].enabled)
    local alpha_use = assert(provider_service.acquire_use(alpha))
    assert.is_true(alpha_use:release())

    assert.is_true(use:release())
    assert.is_true(wait(assert(value:login())).ok)
    local second_use = assert(provider_service.acquire_use(beta))
    run, err = value:logout()
    assert.is_nil(run)
    assert.matches("active provider use", err.message)
    assert.are.equal("api_key", auth.credentials.key)
    assert.is_true(second_use:release())
    assert.is_true(wait(assert(value:logout())).ok)
  end)

  it("refreshes an ambient catalog after releasing logout coordination", function()
    local auth = authentication({ key = "api_key" })
    local managed = service("fake", "Fake")
    local selected_catalog = catalog()
    local refresh = selected_catalog.refresh
    function selected_catalog:refresh(opts)
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
      provider(value.view_value, "fake").authentication.source)
  end)

  it("cancels logout through the Shell action owner", function()
    local auth = authentication({ key = "api_key" })
    local started, cancelled = false, false
    function auth:logout(_, opts)
      started = true
      return async.run(function()
        return async.await(function(done)
          return function()
            cancelled = true
            done.reject(async.cancelled_error)
          end
        end)
      end, { on_done = opts.on_done, error_kind = "auth" })
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
    assert.is_false(wait(thrown).ok)
    assert.matches("login construction failed", thrown:result().error.message)
    assert.is_false(value:is_active())
    local use = assert(provider_service.acquire_use(managed))
    assert.is_true(use:release())

    auth.login = function() return {} end
    local malformed = assert(value:login())
    assert.is_false(wait(malformed).ok)
    assert.matches("must return a Run", malformed:result().error.message)
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
        open_document = function(document)
          opened = util.copy(document)
          return true
        end,
      },
      view = function() return view() end,
    })

    assert.is_true(wait(assert(value:run("report"))).ok)
    assert.are.equal("succeeded", value:info().state.operation.state)
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
    assert.are.equal("Choose workspace", presented.requests[1].request.prompt)
    assert.are.equal("Name preset", presented.requests[2].request.prompt)
    assert.are.equal("API key", presented.requests[3].request.prompt)
    assert.is_true(presented.requests[3].request.secret)
    assert.are.equal("Apply preset?", presented.requests[4].request.prompt)
    assert.matches("Preset ready", presented.notifications[1].message)
    assert.are.equal(presented, value:presenter())
  end)

  it("rejects invalid and failed provider selections", function()
    local presented = presenter()
    local managed = service("fake", "Fake", {
      invalid = operation("Invalid selection", function(ctx)
        return async.run(function()
          async.await(function(done)
            return ctx.interact.select({}, done)
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
    assert.matches("Select requires items", invalid.error.message)

    presented.select = function()
      return async.run(function()
        error(util.error("presentation", "selection closed"), 0)
      end, { error_kind = "presentation" })
    end
    local rejected = wait(assert(value:run("rejected")))

    assert.is_false(rejected.ok)
    assert.matches("selection closed", rejected.error.message)
  end)

  it("runs each service refresh operation whenever its shell is focused", function()
    local calls = { alpha = 0, beta = 0 }
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
    assert(vim.wait(1000, function() return inspect_done ~= nil end, 5))
    assert(value:open())
    assert.are.equal(1, calls.alpha)
    inspect_done.resolve({ ok = true })
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
    local provider_callback
    local cancelled = false
    local managed = service("fake", "Fake", {
      complete = {
        label = "Complete",
        mutating = false,
        complete = function(lead, args)
          assert.are.equal("a", lead)
          assert.are.equal("context", args)
          return { "azure", "alpha", "beta", "", "bad\nvalue", 42 }
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
        open_document = function()
          return nil, util.error("ui", "document failed")
        end,
      },
      view = function() return surface end,
    })

    assert.are.equal("Provider state is unavailable",
      value:info().state.blocks[1].text)
    assert.is_function(provider_callback)
    provider_callback()
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
    assert.matches("step must be", cycle_err.message)

    local pending = assert(value:run("pending"))
    local blocked, blocked_err = value:run("complete")
    assert.is_nil(blocked)
    assert.matches("already active", blocked_err.message)
    assert.is_true(value:cancel())
    assert.is_false(wait(pending).ok)
    assert.is_true(cancelled)

    local failed = assert(value:run("fail"))
    assert.is_false(wait(failed).ok)
    assert.are.equal("failed", value:info().state.operation.state)
    assert.are.equal("operation failed", value:info().state.operation.detail)
    assert.is_true(wait(assert(value:run("report"))).ok)
    assert.is_true(vim.iter(presented.notifications):any(function(notification)
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
    function auth:login(_, opts)
      return async.run(function()
        return async.await(function(done)
          return function() done.reject(async.cancelled_error) end
        end)
      end, { on_done = opts.on_done, error_kind = "auth" })
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

    assert.matches("subscription failed", surface.notifications[1][1])
    assert.is_true(value:presenter():notify({ message = "notice" }))
    assert.is_true(value:presenter():open_uri({ uri = "https://example.test" }))
    assert.are.equal("https://example.test", surface.uris[1])
    local login = assert(value:login("fake"))
    assert.is_true(value:is_authenticating())
    assert.are.same({ "Cancel login" }, labels(value:info().operations))
    local changed, changed_err = value:select("other")
    assert.is_nil(changed)
    assert.matches("Finish the active provider action", changed_err.message)
    assert.is_true(value:run(value:info().operations[1].id))
    assert.is_false(wait(login).ok)
    assert.is_false(value:cancel_login())

    local selected, select_err = value:login("missing")
    assert.is_nil(selected)
    assert.matches("Unknown provider", select_err.message)
    selected, select_err = value:logout("missing")
    assert.is_nil(selected)
    assert.matches("Unknown provider", select_err.message)

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
    assert.is_true(broken:info().operations[1].label == "Log in")
    assert.matches("environment credential",
      broken:info().state.blocks[1].value)
  end)

  it("bounds service, selection, and lifecycle failures", function()
    local presented = presenter()
    local managed = service("broken", "Broken", {
      bad = operation("Bad", function(ctx)
        ctx.interact.progress({ state = "invalid" })
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
      value:info().state.blocks[1].text)
    assert.is_true(wait(assert(value:run("bad"))).ok)
    assert.is_true(#presented.notifications >= 3)
    assert.is_nil(value:select("missing"))
    assert.is_nil(value:run("missing"))
    value:destroy()
    assert.is_nil(value:open())
    assert.is_nil(value:select("broken"))
    assert.is_nil(value:run("bad"))

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
    assert.matches("No Provider Shell", err.message)
    assert.matches("No Provider Shell", empty_presenter.notifications[1].message)
    local cycled, cycle_err = empty:cycle(1)
    assert.is_nil(cycled)
    assert.matches("No Provider Shell", cycle_err.message)
    local run, run_err = empty:run("missing")
    assert.is_nil(run)
    assert.matches("No provider is selected", run_err.message)
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
    fallback_view.notify = nil
    fallback_view.open_uri = nil
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
    local callbacks
    local surface = view()
    function surface:set_presentation(snapshot)
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
      return value.presentation.active
    end

    local resolved = assert(value:run("choose"))
    local request = active_selection()
    assert.is_true(callbacks.on_presentation_resolve(request.id, "two"))
    assert.is_true(wait(resolved).ok)

    local surface_cancelled = assert(value:run("choose"))
    request = active_selection()
    assert.is_true(callbacks.on_presentation_cancel(request.id))
    assert.is_false(wait(surface_cancelled).ok)

    local menu_cancelled = assert(value:run("choose"))
    active_selection()
    local operations = value:info().operations
    assert.are.equal("Cancel", operations[#operations].label)
    assert.is_true(value:run(operations[#operations].id))
    assert.is_false(wait(menu_cancelled).ok)
  end)

  it("contains provider presentation and presentation-open failures", function()
    local surface = view()
    function surface:set_presentation(snapshot)
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
    assert.matches("presentation failed", rejected.error.message)

    local unopened_surface = view()
    function unopened_surface:set_presentation() return true end
    function unopened_surface:open()
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
    assert.matches("surface cannot open", unopened.error.message)
  end)

  it("bounds multibyte feedback and deduplicates an active focus refresh", function()
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
        function surface:set_presentation() return true end
        return surface
      end,
    })

    assert.is_true(value:presenter():notify({ message = string.rep("é", 300) }))
    assert.is_true(util.is_valid_utf8(value.feedback.text))
    assert.matches("…$", value.feedback.text)
    assert(value:open())
    assert.are.equal(1, refreshes)
    assert(value:open())
    assert.are.equal(1, refreshes)
    assert.is_nil(value.pending_focus_provider_id)
    finish.resolve({ ok = true })
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
    local coordination = { finished = false }
    function coordination:finish() self.finished = true return true end
    local duplicate, duplicate_err = value:_start_action({
      kind = "service", provider_id = "fake", coordination = coordination,
      start = function() error("unused") end,
    })
    assert.is_nil(duplicate)
    assert.matches("already active", duplicate_err.message)
    assert.is_true(coordination.finished)
    first:cancel()
    assert.is_false(wait(first).ok)

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
      assert.matches(case.message, result.error.message)
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
        catalog = { discover = function() end },
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
    assert(vim.iter(value:info().state.blocks):any(function(block)
      return block.type == "status"
        and block.text:match("identity unavailable") ~= nil
    end))

    local is_active = value.authentication.is_active
    value.authentication.is_active = function() return true end
    local selected, select_err = value:select("other")
    value.authentication.is_active = is_active
    assert.is_nil(selected)
    assert.matches("Finish the active provider action", select_err.message)

    local token = assert(provider_service.begin_operation(managed, {
      mutating = true,
    }))
    local refreshed, refresh_err = value:run("neoagent.catalog.refresh")
    assert.is_nil(refreshed)
    assert.matches("mutating provider operation", refresh_err.message)
    assert.is_true(token:finish())

    local schedule_refresh = value._schedule_refresh
    value._schedule_refresh = function() error("runtime refresh failed") end
    token = assert(provider_service.begin_operation(managed, {
      mutating = false,
    }))
    assert(vim.wait(1000, function()
      return vim.iter(presented.notifications):any(function(notification)
        return notification.message:match("runtime subscriber failed") ~= nil
      end)
    end, 5))
    assert.is_true(token:finish())
    value._schedule_refresh = schedule_refresh

    selected_catalog.snapshot = function() error("snapshot failed") end
    assert.is_nil(value:_refresh())
    assert(vim.iter(presented.notifications):any(function(notification)
      return notification.message:match("snapshot failed") ~= nil
    end))

    value:destroy()
    local login, login_err = value:login()
    assert.is_nil(login)
    assert.matches("destroyed", login_err.message)
    local logout, logout_err = value:logout()
    assert.is_nil(logout)
    assert.matches("destroyed", logout_err.message)
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
    assert.is_true(value:login("beta"))
    assert(vim.wait(1000, function()
      return value:info().id == "beta" and not value:is_active()
    end, 5))
    assert(vim.iter(presented.notifications):any(function(notification)
      return notification.message:match("Login is unavailable") ~= nil
    end))
  end)

  it("propagates provider selection failures from logout", function()
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
    assert.matches("active provider action", err.message)
    finish.resolve({ ok = true })
    assert.is_true(wait(active).ok)
  end)
end)
