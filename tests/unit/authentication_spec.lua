local async = require("neoagent.async")
local Authentication = require("neoagent.authentication")
local Presenter = require("neoagent.presenter")
local util = require("neoagent.util")

local function host(overrides)
  local value = {
    select = function(request, done) done.resolve(request.items[1].id) end,
    input = function(request, done) done.resolve(request.default) end,
    notice = function(_, done) done.resolve(true) end,
    notify = function() end,
    open_uri = function() end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function manager(overrides)
  local value = {
    credentials = {},
    login = function(self, id, opts)
      self.login_id = id
      return async.run(function()
        return { ok = true }
      end, { on_done = opts.on_done, error_kind = "auth" })
    end,
    logout = function(self, id, opts)
      self.logout_id = id
      return async.run(function()
        return { ok = true }
      end, { on_done = opts.on_done, error_kind = "auth" })
    end,
    list_credentials = function(self)
      return vim.deepcopy(self.credentials)
    end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function config(methods, providers)
  return {
    auth = {
      path = "/test/credentials.json",
      methods = methods or {
        test = { name = "Test login" },
      },
    },
    providers = providers or {},
  }
end

describe("neoagent Authentication coordinator", function()
  local values = {}
  local presenters = {}

  after_each(function()
    for _, value in ipairs(values) do value:destroy() end
    for _, value in ipairs(presenters) do value:destroy() end
    values, presenters = {}, {}
  end)

  local function presenter(value)
    value = Presenter.new({ host = value or host() })
    presenters[#presenters + 1] = value
    return value
  end

  local function authentication(opts)
    opts = opts or {}
    local value = Authentication.new({
      config = opts.config or config(),
      auth = opts.auth or manager(),
      presenter = opts.presenter or presenter(),
      runtimes = opts.runtimes,
      report = opts.report,
      on_activity = opts.on_activity,
    })
    values[#values + 1] = value
    return value
  end

  it("owns and cancels pending credential choosers as authentication activity", function()
    local pending, cancelled
    local states = {}
    local selected = presenter(host({
      select = function(_, done)
        pending = done
        return function()
          pending = nil
          cancelled = true
        end
      end,
    }))
    local value = authentication({
      presenter = selected,
      on_activity = function(active) states[#states + 1] = active end,
    })

    assert.is_true(value:login())
    assert.is_table(pending)
    assert.is_true(value:is_active())
    assert.are.same({ true }, states)

    assert.is_true(value:cancel())
    assert(vim.wait(1000, function()
      return cancelled and not value:is_active()
    end, 5))
    assert.is_false(value:cancel())
  end)

  it("validates composition and reports empty or unknown methods", function()
    local valid_presenter = presenter()
    local valid_auth = manager()
    local function create(overrides)
      local opts = {
        config = config(),
        auth = valid_auth,
        presenter = valid_presenter,
      }
      for key, item in pairs(overrides) do opts[key] = item end
      return Authentication.new(opts)
    end
    assert.has_error(function() create({ config = false }) end,
      "authentication config is required")
    assert.has_error(function() create({ auth = {} }) end,
      "authentication manager is invalid")
    assert.has_error(function() create({ presenter = {} }) end,
      "authentication Presenter is invalid")
    assert.has_error(function() create({ runtimes = false }) end,
      "authentication provider runtimes must be a table")
    assert.has_error(function() create({ on_activity = true }) end,
      "authentication on_activity must be a function")
    assert.has_error(function() create({ report = true }) end,
      "authentication report must be a function")

    local notifications = {}
    local value = authentication({
      config = config({}),
      presenter = presenter(host({
        notify = function(message, level)
          notifications[#notifications + 1] = { message, level }
        end,
      })),
    })
    assert.is_nil(value:login())
    assert.matches("no login methods configured", notifications[1][1])
    assert.is_nil(value:login("missing"))
    assert.matches("unknown login method", notifications[2][1])
    assert.are.equal(vim.log.levels.ERROR, notifications[2][2])
    assert.has_error(function() value:set_activity_callback(true) end)
    assert.is_function(value:set_activity_callback(function() end))

    value:destroy()
    value:destroy()
    local run, err = value:login("missing")
    assert.is_nil(run)
    assert.are.equal("Authentication is destroyed", err.message)
    run, err = value:logout("missing")
    assert.is_nil(run)
    assert.are.equal("Authentication is destroyed", err.message)

    local rejected_notifications = {}
    local rejected = authentication({
      config = config({
        first = { name = "First" },
        second = { name = "Second" },
      }),
      presenter = presenter(host({
        select = function(_, done)
          done.reject(util.error("presentation", "chooser rejected"))
        end,
        notify = function(message, level)
          rejected_notifications[#rejected_notifications + 1] = {
            message, level,
          }
        end,
      })),
    })
    assert.is_true(rejected:login())
    assert(vim.wait(1000, function()
      return #rejected_notifications == 1
    end, 5))
    assert.matches("chooser rejected", rejected_notifications[1][1])
    assert.are.equal(vim.log.levels.ERROR, rejected_notifications[1][2])
  end)

  it("maps providers, refreshes matching catalogs, and bounds failures", function()
    local notifications = {}
    local selected_items
    local activity = {}
    local selected_manager = manager()
    local runtimes = {
      ready = { catalog = {
        refresh = function(_, opts)
          assert.are.same({ force = true }, opts)
          return async.run(function() return { ok = true, models = {} } end)
        end,
      } },
      rejected = { catalog = {
        refresh = function()
          return async.run(function()
            return { ok = false, error = util.error("provider", "refresh rejected") }
          end)
        end,
      } },
      invalid = { catalog = { refresh = function() return false end } },
      crashed = { catalog = { refresh = function() error("refresh crashed") end } },
      unrelated = { catalog = { refresh = function() error("must not run") end } },
    }
    local value = authentication({
      auth = selected_manager,
      config = config({
        alpha = { name = "Alpha login" },
        zulu = { name = "Zulu login" },
      }, {
        alias = { auth = "alpha" },
        ready = { auth = "alpha" },
        rejected = { auth = "alpha" },
        invalid = { auth = "alpha" },
        crashed = { auth = "alpha" },
        unrelated = { auth = "zulu" },
      }),
      runtimes = runtimes,
      presenter = presenter(host({
        select = function(request, done)
          selected_items = vim.deepcopy(request.items)
          done.resolve(request.items[1].id)
        end,
        notify = function(message, level)
          notifications[#notifications + 1] = { message, level }
        end,
      })),
      on_activity = function(active) activity[#activity + 1] = active end,
    })

    assert.is_true(value:login())
    assert(vim.wait(1000, function()
      return selected_manager.login_id == "alpha"
        and #notifications >= 4 and not value:is_active()
    end, 5))
    assert.are.same({ "alpha", "zulu" }, vim.tbl_map(function(item)
      return item.id
    end, selected_items))
    local text = table.concat(vim.tbl_map(function(item) return item[1] end,
      notifications), "\n")
    assert.matches("logged in with Alpha login", text)
    assert.matches("failed to refresh invalid catalog after login", text)
    assert.matches("failed to refresh crashed catalog after login", text)
    assert.matches("failed to refresh rejected catalog: refresh rejected", text)
    assert.is_true(vim.tbl_contains(activity, true))
    assert.is_true(vim.tbl_contains(activity, false))

    local alias_run = assert(value:login("alias"))
    assert(vim.wait(1000, function() return alias_run:is_done() end, 5))
    assert.are.equal("alpha", selected_manager.login_id)
  end)

  it("translates login prompts and bounded authentication events", function()
    local notifications, opened, inputs, notices = {}, {}, {}, {}
    local selected_manager = manager({
      login = function(self, id, opts)
        self.login_id = id
        return async.run(function()
          opts.notify({ type = "auth_url", url = "https://login.example",
            instructions = "Authenticate in a browser:" })
          opts.notify({ type = "device_code", verificationUri = "https://device.example",
            userCode = "ABCD-EFGH" })
          opts.notify({ type = "progress", message = "Waiting for login" })
          local answers = {}
          for _, prompt in ipairs({
            { type = "select", message = "Flow", options = {
              { id = "browser", label = "Browser" },
            } },
            { type = "secret", message = "Secret" },
            { type = "text", message = "Text" },
            { type = "manual_code", message = "Manual" },
          }) do
            answers[#answers + 1] = async.await(function(done)
              return opts.prompt(prompt, done)
            end)
          end
          return { ok = true, answers = answers }
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local value = authentication({
      auth = selected_manager,
      presenter = presenter(host({
        select = function(request, done)
          done.resolve(request.items[1].id)
        end,
        input = function(request, done)
          inputs[#inputs + 1] = vim.deepcopy(request)
          done.resolve(request.secret and "hidden" or "")
        end,
        notice = function(request, done)
          notices[#notices + 1] = vim.deepcopy(request)
          done.resolve(true)
        end,
        notify = function(message, level)
          notifications[#notifications + 1] = { message, level }
        end,
        open_uri = function(uri) opened[#opened + 1] = uri end,
      })),
    })
    local run = assert(value:login("test"))
    assert(vim.wait(1000, function()
      return run:is_done() and not value:is_active() and #notifications >= 2
    end, 5))
    assert.are.same({ "browser", "hidden", "", "" }, run:result().answers)
    assert.are.same({ "https://login.example" }, opened)
    assert.are.equal(2, #notices)
    assert.are.equal("Browser login · <C-c> close", notices[1].prompt)
    assert.matches("Authenticate in a browser", notices[1].body)
    assert.are.equal("OpenAI device login · <C-c> close", notices[2].prompt)
    assert.matches("https://device.example", notices[2].body)
    assert.matches("ABCD%-EFGH", notices[2].body)
    assert.is_true(inputs[1].secret)
    assert.is_false(inputs[1].allow_empty)
    assert.is_true(inputs[2].allow_empty)
    assert.is_true(inputs[3].allow_empty)
    local text = table.concat(vim.tbl_map(function(item) return item[1] end,
      notifications), "\n")
    assert.matches("Waiting for login", text)

    local rejected_manager = manager({
      login = function(_, _, opts)
        return async.run(function()
          return async.await(function(done)
            return opts.prompt({ type = "unsupported", message = "Broken" }, done)
          end)
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local reports = {}
    local rejected = authentication({
      auth = rejected_manager,
      report = function(message, level)
        reports[#reports + 1] = { message, level }
      end,
    })
    run = assert(rejected:login("test"))
    assert(vim.wait(1000, function()
      return run:is_done() and #reports == 1
    end, 5))
    assert.is_false(run:result().ok)
    assert.matches("Unsupported login prompt", reports[1][1])
    assert.are.equal(vim.log.levels.ERROR, reports[1][2])
  end)

  it("falls back when persistent login notices are unavailable", function()
    local notifications, opened = {}, {}
    local selected_manager = manager({
      login = function(_, _, opts)
        return async.run(function()
          opts.notify({
            type = "auth_url",
            url = "https://login.example",
            instructions = "Authenticate in a browser:",
          })
          opts.notify({
            type = "device_code",
            verificationUri = "https://device.example",
            userCode = "ABCD-EFGH",
          })
          return { ok = true }
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local fallback_presenter = {
      select = function() error("selection is unused") end,
      input = function() error("input is unused") end,
      notify = function(_, request)
        notifications[#notifications + 1] = request
      end,
      open_uri = function(_, request)
        opened[#opened + 1] = request.uri
      end,
    }
    local value = authentication({
      auth = selected_manager,
      presenter = fallback_presenter,
    })

    local run = assert(value:login("test"))
    assert(vim.wait(1000, function()
      return run:is_done() and #notifications >= 3
    end, 5))
    local messages = table.concat(vim.tbl_map(function(request)
      return request.message
    end, notifications), "\n")
    assert.matches("Authenticate in a browser", messages)
    assert.matches("https://login.example", messages)
    assert.matches("https://device.example", messages)
    assert.matches("ABCD%-EFGH", messages)
    assert.are.same({ "https://login.example" }, opened)
  end)

  it("presents browser authorization as a persistent login notice", function()
    local finish
    local notices, notifications, opened = {}, {}, {}
    local notice_run
    local selected_manager = manager({
      login = function(_, _, opts)
        return async.run(function()
          opts.notify({
            type = "auth_url",
            url = "https://login.example",
            instructions = "Complete login in your browser to finish.",
          })
          async.await(function(done)
            finish = done
            return function() finish = nil end
          end)
          return { ok = true }
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local persistent_presenter = {
      select = function() error("selection is unused") end,
      input = function() error("input is unused") end,
      notify = function(_, request)
        notifications[#notifications + 1] = request
      end,
      open_uri = function(_, request)
        opened[#opened + 1] = request
      end,
      notice = function(_, request)
        notices[#notices + 1] = vim.deepcopy(request)
        notice_run = async.run(function()
          return async.await(function() return function() end end)
        end, { error_kind = "presentation" })
        return notice_run
      end,
    }
    local value = authentication({
      auth = selected_manager,
      presenter = persistent_presenter,
    })

    local run = assert(value:login("test"))
    assert(vim.wait(1000, function()
      return #notices > 0 or #notifications > 0
    end, 5))

    assert.are.equal(1, #notices)
    assert.are.equal("Browser login · <C-c> close", notices[1].prompt)
    assert.matches("Complete login in your browser", notices[1].body)
    assert.matches("https://login.example", notices[1].body)
    assert.matches("waiting for authorization", notices[1].body)
    assert.are.equal("https://login.example", opened[1].uri)
    assert.are.same({}, notifications)
    assert.is_false(notice_run:is_done())

    finish.resolve(true)
    assert(vim.wait(1000, function()
      return run:is_done() and notice_run:is_done()
    end, 5))
  end)

  it("presents device codes persistently without opening their URI", function()
    local finish
    local notices, notifications, opened = {}, {}, {}
    local notice_run
    local selected_manager = manager({
      login = function(_, _, opts)
        return async.run(function()
          opts.notify({
            type = "device_code",
            verificationUri = "https://device.example",
            userCode = "ABCD-EFGH",
          })
          async.await(function(done)
            finish = done
            return function() finish = nil end
          end)
          return { ok = true }
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local persistent_presenter = {
      select = function() error("selection is unused") end,
      input = function() error("input is unused") end,
      notify = function(_, request)
        notifications[#notifications + 1] = request
      end,
      open_uri = function(_, request)
        opened[#opened + 1] = request
      end,
      notice = function(_, request)
        notices[#notices + 1] = vim.deepcopy(request)
        notice_run = async.run(function()
          return async.await(function() return function() end end)
        end, { error_kind = "presentation" })
        return notice_run
      end,
    }
    local value = authentication({
      auth = selected_manager,
      presenter = persistent_presenter,
    })

    local run = assert(value:login("test"))
    assert(vim.wait(1000, function()
      return #notices > 0 or #opened > 0
    end, 5))

    assert.are.equal(1, #notices)
    assert.are.equal("OpenAI device login · <C-c> close", notices[1].prompt)
    assert.matches("https://device.example", notices[1].body)
    assert.matches("ABCD%-EFGH", notices[1].body)
    assert.are.same({}, opened)
    assert.are.same({}, notifications)
    assert.is_false(notice_run:is_done())

    finish.resolve(true)
    assert(vim.wait(1000, function()
      return run:is_done() and notice_run:is_done()
    end, 5))
  end)

  it("serializes authentication operations and propagates cancellation", function()
    local cancelled = 0
    local notifications = {}
    local selected_manager = manager({
      login = function(_, _, opts)
        return async.run(function()
          return async.await(function(done)
            return opts.prompt({ type = "text", message = "Wait" }, done)
          end)
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local value = authentication({
      auth = selected_manager,
      presenter = presenter(host({
        input = function()
          return function() cancelled = cancelled + 1 end
        end,
        notify = function(message, level)
          notifications[#notifications + 1] = { message, level }
        end,
      })),
    })
    local run = assert(value:login("test"))
    assert.is_true(value:is_active())
    assert.is_nil(value:login("test"))
    assert.is_nil(value:logout("test"))
    assert.are.equal(2, #notifications)
    assert.are.equal(vim.log.levels.WARN, notifications[1][2])
    assert.is_true(value:cancel())
    assert(vim.wait(1000, function()
      return run:is_done() and not value:is_active()
    end, 5))
    assert.are.equal(1, cancelled)
    assert.is_false(value:cancel())

    selected_manager.login = function() error("login construction failed") end
    local ok, err = pcall(value.login, value, "test")
    assert.is_false(ok)
    assert.matches("login construction failed", err)
    assert.is_false(value:is_active())
  end)

  it("selects and removes stored credential kinds", function()
    local notifications, choices = {}, {}
    local selected_manager = manager()
    selected_manager.credentials = {
      { id = "key", name = "Stored key", type = "api_key" },
      { id = "oauth", name = "Plan login", type = "oauth" },
      { id = "invalid", name = "Invalid", type = "invalid" },
    }
    local value = authentication({
      auth = selected_manager,
      presenter = presenter(host({
        select = function(request, done)
          choices = vim.deepcopy(request.items)
          done.resolve("oauth")
        end,
        notify = function(message, level)
          notifications[#notifications + 1] = { message, level }
        end,
      })),
    })
    assert.is_true(value:logout())
    assert(vim.wait(1000, function()
      return selected_manager.logout_id == "oauth" and not value:is_active()
        and #notifications >= 1
    end, 5))
    assert.are.same({
      "Stored key (API key)", "Plan login (OAuth)", "Invalid (invalid)",
    }, vim.tbl_map(function(item) return item.label end, choices))
    assert.matches("logged out of Plan login", notifications[#notifications][1])

    local run = assert(value:logout("key"))
    assert(vim.wait(1000, function() return run:is_done() end, 5))
    assert(vim.wait(1000, function()
      return notifications[#notifications][1]:find("environment API keys", 1, true)
    end, 5))
    assert.is_nil(value:logout("missing"))
    assert.matches("no stored credential", notifications[#notifications][1])

    selected_manager.credentials = {}
    assert.is_nil(value:logout())
    assert.matches("no stored credentials", notifications[#notifications][1])

    local list_error = util.error("auth", "credential list failed")
    selected_manager.list_credentials = function() return nil, list_error end
    local missing, err = value:logout()
    assert.is_nil(missing)
    assert.are.equal(list_error, err)
    assert.matches("credential list failed", notifications[#notifications][1])
  end)

  it("publishes completion of an asynchronously settled logout", function()
    local finish
    local selected_manager = manager({
      credentials = {
        { id = "test", name = "Test login", type = "oauth" },
      },
      logout = function(_, _, opts)
        return async.run(function()
          return async.await(function(done)
            finish = done
            return function() finish = nil end
          end)
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local activity = {}
    local value = authentication({
      auth = selected_manager,
      on_activity = function(active) activity[#activity + 1] = active end,
    })

    local run = assert(value:logout("test"))
    assert.is_true(value:is_active())
    finish.resolve({ ok = true })
    assert(vim.wait(1000, function()
      return run:is_done() and not value:is_active()
    end, 5))
    assert.are.same({ true, false }, activity)
  end)

  it("reports logout failures and cancels all owned work on destruction", function()
    local notifications, activity = {}, {}
    local catalog_cancelled, logout_cancelled = false, false
    local selected_manager = manager({
      credentials = {
        { id = "test", name = "Test login", type = "oauth" },
      },
      logout = function(_, _, opts)
        return async.run(function()
          async.await(function()
            return function() logout_cancelled = true end
          end)
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local value = authentication({
      auth = selected_manager,
      config = config(nil, { dynamic = { auth = "test" } }),
      runtimes = { dynamic = { catalog = {
        refresh = function()
          return async.run(function()
            async.await(function()
              return function() catalog_cancelled = true end
            end)
          end)
        end,
      } } },
      presenter = presenter(host({
        notify = function(message, level)
          notifications[#notifications + 1] = { message, level }
        end,
      })),
      on_activity = function(active) activity[#activity + 1] = active end,
    })

    local login = assert(value:login("test"))
    assert(vim.wait(1000, function()
      return login:is_done() and value:is_active()
    end, 5))
    value:destroy()
    assert(vim.wait(1000, function() return catalog_cancelled end, 5))
    assert.is_false(value:is_active())

    local failing_manager = manager({
      credentials = {
        { id = "test", name = "Test login", type = "oauth" },
      },
      logout = function(_, _, opts)
        return async.run(function()
          error(util.error("auth", "logout rejected"), 0)
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local failed = authentication({
      auth = failing_manager,
      presenter = presenter(host({
        notify = function(message, level)
          notifications[#notifications + 1] = { message, level }
        end,
      })),
    })
    local logout = assert(failed:logout("test"))
    assert(vim.wait(1000, function()
      return logout:is_done()
        and notifications[#notifications][1]:find("logout rejected", 1, true)
    end, 5))
    assert.are.equal(vim.log.levels.ERROR, notifications[#notifications][2])

    failing_manager.logout = function()
      error("logout construction failed")
    end
    local ok, err = pcall(failed.logout, failed, "test")
    assert.is_false(ok)
    assert.matches("logout construction failed", err)
    assert.is_false(failed:is_active())

    local pending = authentication({
      auth = selected_manager,
      presenter = presenter(host()),
    })
    local logout_run = assert(pending:logout("test"))
    assert.is_true(pending:is_active())
    pending:destroy()
    assert(vim.wait(1000, function()
      return logout_run:is_done() and logout_cancelled
    end, 5))
    assert.is_true(vim.tbl_contains(activity, false))

    local login_cancelled = false
    local login_manager = manager({
      login = function(_, _, opts)
        return async.run(function()
          async.await(function()
            return function() login_cancelled = true end
          end)
        end, { on_done = opts.on_done, error_kind = "auth" })
      end,
    })
    local logging_in = authentication({ auth = login_manager })
    assert(logging_in:login("test"))
    logging_in:destroy()
    assert(vim.wait(1000, function() return login_cancelled end, 5))
  end)
end)
