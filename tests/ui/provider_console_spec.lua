local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")
local util = require("neoagent.util")

describe("neoagent provider console", function()
  local neoagent
  local controllers
  local windows

  before_each(function()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
    controllers, windows = {}, {}
  end)

  after_each(function()
    for _, window in ipairs(windows) do window:destroy() end
    for _, controller in ipairs(controllers) do controller:destroy() end
  end)

  local function options(name, model)
    return {
      name = name,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = name },
      providers = { fake = { api = "fake", models = { [name] = {} } } },
      apis = { fake = function() return model end },
      tools = {},
      agents = false,
      skills = false,
      ui = { position = "center" },
    }
  end

  local function service(operations)
    local listeners = {}
    local events = {}
    local value = {
      id = "fake",
      name = "Fake service",
      _state = {
        blocks = {
          { type = "status", text = "ready", level = "success" },
        },
      },
      operations = operations or {},
      seen_events = events,
    }
    function value:state()
      return util.copy(self._state)
    end
    function value:subscribe(listener)
      listeners[#listeners + 1] = listener
      local active = true
      return function()
        if not active then return end
        active = false
        for index, candidate in ipairs(listeners) do
          if candidate == listener then table.remove(listeners, index) return end
        end
      end
    end
    function value:on_event(event)
      events[#events + 1] = util.copy(event)
      if type(event) == "table" and event.type == "provider_status"
          and type(event.text) == "string" then
        self._state.blocks[1].text = event.text
      end
      local snapshot = util.copy(self._state)
      for _, listener in ipairs(listeners) do
        listener(snapshot)
      end
    end
    return value
  end

  local function wait(run, timeout)
    assert(vim.wait(timeout or 3000, function() return run:is_done() end))
    return run:result()
  end

  it("binds the active provider into Controller context and forwards events", function()
    local value = service({
      ping = {
        label = "Ping service",
        description = "Send one ping",
        run = function()
          return async.run(function() return { ok = true } end)
        end,
      },
    })
    local model = fake_model.new({ {
      events = { { type = "provider_status", text = "weekly 84% left" } },
      result = fake_model.assistant({ { type = "text", text = "ok" } }),
    } })
    local controller = neoagent.new(options("provider", model), {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())

    local context = controller:snapshot().context.provider
    assert.are.equal("fake", context.id)
    assert.are.equal("Fake service", context.name)
    assert.are.equal("ready", context.state.blocks[1].text)
    assert.are.same({ "ping" },
      vim.tbl_map(function(operation) return operation.id end, context.operations))
    assert.is_true(context.operations[1].enabled)
    assert.is_nil(context.operations[1].run)

    local run = controller:send("hello")
    wait(run)
    assert(vim.wait(1000, function()
      return controller:snapshot().context.provider.state.blocks[1].text
        == "weekly 84% left"
    end))
    assert.are.equal("provider_status", value.seen_events[1].type)
    assert.are.equal("weekly 84% left", value.seen_events[1].text)

    controller:destroy()
    controllers = {}
  end)

  it("updates provider state when the selected model changes", function()
    local value = service({})
    value.seen_models = {}
    function value:state(ctx)
      local selection = ctx and ctx.model
      self.seen_models[#self.seen_models + 1] = util.copy(selection)
      return { blocks = { {
        type = "field",
        label = "Selected model",
        value = selection and selection.model or "none",
      } } }
    end
    local opts = options("first", fake_model.new({}))
    opts.providers.fake.models.second = {}
    local controller = neoagent.new(opts, { providers = { fake = value } })
    controllers = { controller }

    assert(controller:prepare())
    assert.are.equal("first", controller:snapshot().context.provider
      .state.blocks[1].value)
    assert(controller:set_model("fake", "second"))
    assert.are.equal("second", controller:snapshot().context.provider
      .state.blocks[1].value)
    assert.are.same({ provider = "fake", model = "second" },
      value.seen_models[#value.seen_models])
  end)

  it("owns provider operation lifecycle and cancellation", function()
    local pending = {}
    local value = service({
      work = {
        label = "Work",
        run = function(ctx)
          return async.run(function()
            ctx.interact.progress({
              id = "work", label = "Work", state = "running", message = "Working",
            })
            return async.await(function(done)
              pending.resolve = done.resolve
              pending.reject = done.reject
              return function() end
            end)
          end)
        end,
      },
    })
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())

    local run = controller:provider_operation("work")
    assert(run)
    assert.is_false(controller:provider_operations()[1].enabled)
    assert.is_nil(controller:provider_operation("work"))
    assert.are.equal("running", controller:provider_info().state.operation.state)

    assert.is_true(controller:cancel_provider())
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.are.equal("cancelled", controller:provider_info().state.operation.state)
    assert.is_true(controller:provider_operations()[1].enabled)

    local failed = controller:provider_operation("work")
    pending.reject(util.error("provider", "work failed"))
    result = wait(failed)
    assert.is_false(result.ok)
    assert.are.equal("failed", controller:provider_info().state.operation.state)
    assert.are.equal("work failed", controller:provider_info().state.operation.detail)

    local invalid, invalid_err = controller:provider_operation("work", {})
    assert.is_nil(invalid)
    assert.matches("args must be a string", invalid_err.message)
    assert.is_nil(controller:provider_info().state.operation)
  end)

  it("opens provider document artifacts in the command adapter", function()
    local value = service({
      document = {
        label = "Document",
        run = function()
          return async.run(function()
            return {
              ok = true,
              artifact = {
                kind = "document",
                name = "provider output",
                filetype = "dosini",
                content = "version = 1\n\n[model]\nc = 8192\n",
              },
            }
          end)
        end,
      },
      invalid_document = {
        label = "Invalid document",
        run = function()
          return async.run(function()
            return {
              ok = true,
              artifact = {
                kind = "document",
                name = "",
                filetype = "text",
                content = "invalid",
              },
            }
          end)
        end,
      },
    })
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())
    local before = vim.fn.tabpagenr("$")
    local result = wait(controller:provider_operation("document"))
    assert(result.ok, vim.inspect(result.error))
    assert(vim.wait(1000, function() return vim.fn.tabpagenr("$") == before + 1 end))
    assert.are.equal("dosini", vim.bo.filetype)
    assert.are.same({ "version = 1", "", "[model]", "c = 8192" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("tabclose")

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message) notifications[#notifications + 1] = message end
    result = wait(controller:provider_operation("invalid_document"))
    vim.notify = original_notify
    assert.is_true(result.ok)
    assert.are.equal(before, vim.fn.tabpagenr("$"))
    assert.matches("invalid document artifact", notifications[1])
  end)

  it("refreshes matching dynamic catalogs after login", function()
    local refreshed = 0
    local value = service()
    value.refresh_catalog = function()
      return async.run(function()
        refreshed = refreshed + 1
        return { ok = true }
      end)
    end
    local invalid = service()
    invalid.id = "invalid"
    invalid.refresh_catalog = function() return {} end
    local failed = service()
    failed.id = "failed"
    failed.refresh_catalog = function()
      return async.run(function()
        error(util.error("provider", "catalog refresh failed"), 0)
      end)
    end
    local opts = options("provider", fake_model.new({}))
    opts.providers.fake.auth = "dynamic-login"
    opts.providers.invalid = {
      api = "fake", auth = "dynamic-login", models = {},
    }
    opts.providers.failed = {
      api = "fake", auth = "dynamic-login", models = {},
    }
    opts.auth = {
      path = vim.fn.tempname() .. "/auth.json",
      methods = {
        ["dynamic-login"] = {
          name = "Dynamic login",
          type = "api_key",
          login = function()
            return async.run(function()
              return {
                ok = true,
                credential = { type = "api_key", key = "key" },
              }
            end)
          end,
          request_opts = function() return {} end,
        },
      },
    }
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local controller = neoagent.new(opts, {
      providers = { fake = value, invalid = invalid, failed = failed },
    })
    controllers = { controller }
    assert(controller:prepare())
    assert(wait(controller:login("dynamic-login")).ok)
    assert(vim.wait(1000, function()
      local text = table.concat(vim.tbl_map(function(entry) return entry[1] end,
        notifications), "\n")
      return refreshed == 1
        and text:find("failed to refresh invalid catalog after login", 1, true)
        and text:find("catalog refresh failed", 1, true)
    end))
    vim.notify = original_notify
    vim.fn.delete(vim.fs.dirname(opts.auth.path), "rf")
  end)

  it("cancels a provider operation when the provider binding is replaced", function()
    local pending = {}
    local value = service({
      work = {
        label = "Work",
        run = function()
          return async.run(function()
            return async.await(function(done)
              pending.resolve = done.resolve
              pending.reject = done.reject
              return function() end
            end)
          end)
        end,
      },
    })
    local opts = options("fake", fake_model.new({}))
    opts.providers = {
      fake = { api = "fake", models = { fake = {} } },
      other = { api = "fake", models = { other = {} } },
    }
    local controller = neoagent.new(opts, {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())

    local run = controller:provider_operation("work")
    assert(run)
    assert.are.equal("running", controller:provider_info().state.operation.state)

    assert(controller:set_model("other", "other"))
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.is_false(controller:provider_info().state)

    assert(controller:set_model("fake", "fake"))
    local rerun = controller:provider_operation("work")
    assert(rerun)
    pending.reject(util.error("provider", "work failed"))
    result = wait(rerun)
    assert.is_false(result.ok)
    assert.are.equal("failed", controller:provider_info().state.operation.state)
  end)

  it("renders the read-only console and routes arrow selections", function()
    local calls = 0
    local value = service({
      ping = {
        label = "Ping service",
        run = function()
          calls = calls + 1
          return async.run(function() return { ok = true } end)
        end,
      },
    })
    local first = neoagent.new(options("first", fake_model.new({})), {
      providers = { fake = value },
    })
    local second = neoagent.new(options("second", fake_model.new({})))
    controllers = { first, second }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }

    assert(window:open())
    local view = window:view()
    assert.is_true(window:set_provider_console(true))
    assert.is_true(view.provider_open)
    assert(vim.api.nvim_win_is_valid(view.provider_win))
    local lines = table.concat(vim.api.nvim_buf_get_lines(view.provider_buf, 0, -1, false), "\n")
    assert.matches("ready", lines)
    assert.matches("Ping service", lines)

    vim.api.nvim_set_current_win(view.provider_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return calls == 1 end))
    assert.are.equal(1, calls)

    assert.is_true(window:toggle_provider_console())
    assert.is_false(view.provider_open)

    assert.is_true(window:set_provider_console(true))
    assert(window:select(second))
    assert.is_true(view.provider_open)
    assert.are.equal(second, window:active())
    assert.is_true(window:provider_console_open())
    local empty_lines = table.concat(
      vim.api.nvim_buf_get_lines(view.provider_buf, 0, -1, false), "\n")
    assert.matches("No provider information", empty_lines)

    assert.are.equal(first, window:select(first))
    assert(vim.wait(1000, function() return view.provider_open == true end))
    assert(vim.api.nvim_win_is_valid(view.provider_win))
    local restored_lines = table.concat(
      vim.api.nvim_buf_get_lines(view.provider_buf, 0, -1, false), "\n")
    assert.matches("ready", restored_lines)
  end)

  it("runs a service's initial operation when its console first opens", function()
    local calls = 0
    local value = service({
      refresh = {
        label = "Refresh",
        run = function()
          calls = calls + 1
          return async.run(function() return { ok = true } end)
        end,
      },
    })
    value.open_operation = "refresh"
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }

    assert(window:set_provider_console(true))
    assert(vim.wait(1000, function() return calls == 1 end))
    assert(window:set_provider_console(false))
    assert(window:set_provider_console(true))
    vim.wait(20)
    assert.are.equal(1, calls)
  end)

  it("preserves provider operation selection across status updates", function()
    local function operation(label)
      return {
        label = label,
        run = function()
          return async.run(function() return { ok = true } end)
        end,
      }
    end
    local value = service({ first = operation("First"), second = operation("Second") })
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    assert(window:set_provider_console(true))
    local view = window:view()
    assert(view:_move_provider(1, 1))
    local row = vim.api.nvim_win_get_cursor(view.provider_win)[1]
    assert.are.equal("second", view.provider_targets[row - 1].id)
    value:on_event({ type = "provider_status", text = "updated" })
    assert(vim.wait(1000, function()
      return vim.api.nvim_win_get_cursor(view.provider_win)[1] == row
    end))
    assert.are.equal("second", view.provider_targets[row - 1].id)
  end)

  it("opens a bound service whose state is empty without retrying selection", function()
    local value = service({})
    local state_calls = 0
    value.state = function()
      state_calls = state_calls + 1
      return false
    end
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    local scheduled = {}
    local original_schedule = util.schedule
    util.schedule = function(callback) scheduled[#scheduled + 1] = callback end

    local opened = window:set_provider_console(true)
    util.schedule = original_schedule

    assert.is_true(opened)
    assert.is_true(window:provider_console_open())
    assert.are.equal(0, #scheduled)
    assert.is_true(state_calls <= 3)
    local view = window:view()
    assert.matches("No provider information", table.concat(
      vim.api.nvim_buf_get_lines(view.provider_buf, 0, -1, false), "\n"))
  end)

  it("invalidates pending provider opens when their owner is destroyed", function()
    local function pending_open(destroy)
      local first = service({})
      local second = service({})
      first.id = "first"
      second.id = "second"
      local opts = options("plain", fake_model.new({}))
      opts.providers.fake.models.plain = nil
      opts.default_model = nil
      local controller = neoagent.new(opts, {
        providers = { first = first, second = second },
      })
      local window = neoagent.new_window({ controllers = { controller } })
      local scheduled = {}
      local original_schedule = util.schedule
      local original_select = vim.ui.select
      local select_callback
      vim.ui.select = function(items, _, callback)
        select_callback = function() callback(items[1]) end
      end
      util.schedule = function(callback) scheduled[#scheduled + 1] = callback end
      assert.is_true(window:set_provider_console(true))
      assert(select_callback)
      select_callback()
      util.schedule = original_schedule
      vim.ui.select = original_select
      assert.are.equal(1, #scheduled)

      destroy(window, controller)
      scheduled[1]()
      vim.wait(20, function() return false end)
      return window, controller
    end

    local destroyed_window, first = pending_open(function(window)
      window:destroy()
    end)
    first:destroy()
    assert.is_nil(destroyed_window:view())

    local active_window, second = pending_open(function(_, controller)
      controller:destroy()
    end)
    assert.is_false(active_window:provider_console_open())
    assert.is_nil(active_window:view())
    active_window:destroy()
    second:destroy()
  end)

  it("keeps provider focus in Normal mode across its complete lifecycle", function()
    local first = neoagent.new(options("first", fake_model.new({})), {
      providers = { fake = service({}) },
    })
    local second = neoagent.new(options("second", fake_model.new({})), {
      providers = { fake = service({}) },
    })
    controllers = { first, second }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    local view = window:view()
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("i<A-p>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view.provider_open
        and vim.api.nvim_get_current_win() == view.provider_win
    end))
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
    local original_lines = vim.api.nvim_buf_get_lines(
      view.provider_buf, 0, -1, false)
    vim.v.errmsg = ""
    for _, command in ipairs({ "i", "a", "o" }) do
      vim.api.nvim_feedkeys(command, "x", false)
      assert(vim.wait(1000, function()
        return vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i"
      end))
    end
    assert.is_false(vim.bo[view.provider_buf].modifiable)
    assert.are.same(original_lines,
      vim.api.nvim_buf_get_lines(view.provider_buf, 0, -1, false))
    assert.is_nil(vim.v.errmsg:match("E21"))

    view:focus_input()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<A-l>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view.provider_win
        and vim.api.nvim_get_mode().mode == "n"
    end))
    assert.are.equal(second, window:select(second))
    assert.are.equal(view.provider_win, vim.api.nvim_get_current_win())
    assert.are.equal("n", vim.api.nvim_get_mode().mode)

    local closed = view.provider_win
    vim.api.nvim_win_close(closed, true)
    assert(vim.wait(1000, function() return view.provider_win == nil end))
    view:focus_input()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<A-p>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view.provider_win ~= nil
        and vim.api.nvim_win_is_valid(view.provider_win)
        and vim.api.nvim_get_current_win() == view.provider_win
    end))
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
  end)

  it("preserves provider view while coalescing operation progress pushes", function()
    local pending = {}
    local value = service({
      work = {
        label = "Work",
        run = function(ctx)
          return async.run(function()
            pending.progress = ctx.interact.progress
            pending.progress({
              id = "work", label = "Work", state = "running",
              message = "Starting", ratio = 0,
            })
            return async.await(function(done)
              pending.resolve = done.resolve
              return function() end
            end)
          end)
        end,
      },
    })
    local items = {}
    for index = 1, 30 do
      items[index] = { label = "Model " .. index, detail = "available" }
    end
    value._state.blocks[#value._state.blocks + 1] = {
      type = "list", title = "Models", items = items,
    }
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    assert(window:set_provider_console(true))
    local view = window:view()
    local run = assert(controller:provider_operation("work"))
    assert(vim.wait(1000, function()
      return pending.progress ~= nil and view.provider_targets == nil
    end))
    vim.api.nvim_win_call(view.provider_win, function()
      vim.fn.winrestview({ lnum = 14, col = 4, topline = 9, leftcol = 0 })
    end)
    local before = vim.api.nvim_win_call(
      view.provider_win, function() return vim.fn.winsaveview() end)
    local refreshes = 0
    local original_refresh = view._refresh_provider
    view._refresh_provider = function(...)
      refreshes = refreshes + 1
      return original_refresh(...)
    end

    for index = 1, 8 do
      pending.progress({
        id = "work", label = "Work", state = "running",
        message = "Loading " .. index, ratio = index / 10,
      })
    end
    assert(vim.wait(1000, function() return refreshes > 0 end))
    assert.are.equal(1, refreshes)
    local after = vim.api.nvim_win_call(
      view.provider_win, function() return vim.fn.winsaveview() end)
    assert.are.equal(before.lnum, after.lnum)
    assert.are.equal(before.col, after.col)
    assert.are.equal(before.topline, after.topline)
    assert.are.equal(view.provider_win, vim.api.nvim_get_current_win())
    pending.resolve({ ok = true })
    assert(wait(run).ok)
  end)

  it("opens an empty console for providers without services", function()
    local controller = neoagent.new(options("plain", fake_model.new({})))
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end

    local opened = window:set_provider_console(true)
    vim.notify = original_notify

    assert.is_true(opened)
    assert.is_true(window:provider_console_open())
    assert.are.equal(0, #notifications)
    local view = window:view()
    assert.matches("No provider information",
      table.concat(vim.api.nvim_buf_get_lines(view.provider_buf, 0, -1, false), "\n"))
    assert.are.same({}, controller:provider_operations())
    assert.is_nil(controller:provider_operation("ping"))
  end)

  it("binds the single available provider service when the active provider has none", function()
    local value = service({
      ping = {
        label = "Ping service",
        run = function()
          return async.run(function() return { ok = true } end)
        end,
      },
    })
    value.id = "managed"
    local controller = neoagent.new(options("plain", fake_model.new({})), {
      providers = { managed = value },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(controller:prepare())
    assert.is_false(controller:snapshot().context.provider.state)

    assert(window:open())
    assert.is_true(window:set_provider_console(true))
    assert(vim.wait(1000, function() return window:provider_console_open() end))
    assert.are.equal("managed", controller:snapshot().context.provider.id)
    local view = window:view()
    assert.matches("ready",
      table.concat(vim.api.nvim_buf_get_lines(view.provider_buf, 0, -1, false), "\n"))
    assert.are.same({ "ping" },
      vim.tbl_map(function(operation) return operation.id end,
        controller:provider_operations()))
  end)

  it("opens a service console before any model is selected", function()
    local opts = options("plain", fake_model.new({}))
    opts.default_model = nil
    opts.providers.fake.models = {}
    local managed = service({})
    managed.id = "managed"
    local controller = neoagent.new(opts, { providers = { managed = managed } })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }

    assert(window:open())
    assert.is_true(window:set_provider_console(true))
    assert.are.equal("managed", controller:provider_info().id)
    assert.is_true(window:provider_console_open())
  end)

  it("resolves a pending dynamic default when its catalog arrives", function()
    local value = service()
    local discovered = {}
    local subscriber
    value.get_models = function() return vim.deepcopy(discovered) end
    value.subscribe = function(_, listener)
      subscriber = listener
      return function() end
    end
    value.refresh_catalog = function()
      return async.run(function()
        return async.await(function() return function() end end)
      end)
    end
    local opts = options("pending", fake_model.new({}))
    opts.default_model = { provider = "fake", model = "discovered-later" }
    opts.providers.fake.models = {}
    local controller = neoagent.new(opts, { providers = { fake = value } })
    controllers = { controller }
    assert(controller:prepare())
    assert.is_nil(controller:get_model())
    assert.are.equal("fake", controller:provider_info().id)
    assert.are.equal("fake/discovered-later",
      controller:snapshot().context.model)

    discovered = { { id = "discovered-later", context_window = 4096 } }
    subscriber()
    assert(vim.wait(1000, function()
      return controller:get_model() ~= nil
    end))
    assert.are.equal("fake/discovered-later",
      controller:snapshot().context.model)
  end)

  it("resolves a dynamic default already present in the service catalog", function()
    local value = service()
    value.get_models = function()
      return { { id = "discovered", context_window = 4096 } }
    end
    value.refresh_catalog = function()
      return async.run(function() return { ok = true } end)
    end
    local opts = options("pending", fake_model.new({}))
    opts.default_model = { provider = "fake", model = "discovered" }
    opts.providers.fake.models = {}
    local controller = neoagent.new(opts, { providers = { fake = value } })
    controllers = { controller }
    assert(controller:prepare())
    assert.is_not_nil(controller:get_model())
    assert.are.equal("fake/discovered", controller:snapshot().context.model)
  end)

  it("keeps model events bound to the model provider while inspecting another service", function()
    local model_service = service({})
    local inspected = service({})
    inspected.id = "inspected"
    local controller = neoagent.new(options("provider", fake_model.new({ {
      events = { { type = "provider_status", text = "model event" } },
      result = fake_model.assistant({ { type = "text", text = "ok" } }),
    } })), {
      providers = { fake = model_service, inspected = inspected },
    })
    controllers = { controller }
    assert(controller:prepare())
    assert(controller:bind_provider("inspected"))
    assert(wait(controller:send("hello")).ok)
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(event) return event.type end,
      model_service.seen_events), "provider_status"))
    assert.are.equal(0, #inspected.seen_events)
    assert.are.equal("inspected", controller:provider_info().id)
  end)

  it("offers a provider picker when several services exist", function()
    local first = service({})
    local second = service({})
    first.id = "one"
    second.id = "two"
    local controller = neoagent.new(options("plain", fake_model.new({})), {
      providers = { one = first, two = second },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(controller:prepare())
    assert(window:open())

    local original_select = vim.ui.select
    local prompt
    vim.ui.select = function(items, options, callback)
      prompt = options.prompt
      assert.are.same({ "one", "two" },
        vim.tbl_map(function(item) return item.id end, items))
      callback(items[2])
    end
    assert.is_true(window:set_provider_console(true))
    assert.are.equal("Select provider console:", prompt)
    assert(vim.wait(1000, function() return window:provider_console_open() end))
    assert.are.equal("two", controller:snapshot().context.provider.id)

    assert(window:set_provider_console(false))
    assert(controller:set_model("fake", "plain"))
    local cancelled = {}
    vim.ui.select = function(_, _, callback)
      cancelled[1] = true
      callback(nil)
    end
    assert.is_true(window:set_provider_console(true))
    assert.are.equal(1, #cancelled)
    assert.is_false(window:provider_console_open())
    vim.ui.select = original_select
  end)

  it("accepts providers with empty initial summaries", function()
    local value = service({})
    value._state.blocks = {}
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())
    vim.notify = original_notify
    assert.are.same({}, controller:snapshot().context.provider.state.blocks)
    assert.are.equal(0, #notifications)
  end)

  it("unbinds a provider when the selected provider has no service", function()
    local model = fake_model.new({})
    local value = service({})
    local controller_options = options("provider", model)
    controller_options.default_model = { provider = "fake", model = "provider" }
    controller_options.providers = {
      fake = { api = "fake", models = { provider = {} } },
      other = { api = "fake", models = { other = {} } },
    }
    local controller = neoagent.new(controller_options, {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())
    assert.are.equal("fake", controller:snapshot().context.provider.id)
    assert(controller:set_model("other", "other"))
    assert.are.equal("other", controller:snapshot().context.provider.id)
    assert.is_false(controller:snapshot().context.provider.state)
    assert.are.same({}, controller:snapshot().context.provider.operations)
  end)

  it("cancels provider operations on destruction", function()
    local pending = {}
    local value = service({
      wait = {
        label = "Wait",
        run = function()
          return async.run(function()
            return async.await(function(done)
              pending.resolve = done.resolve
              pending.reject = done.reject
              return function() end
            end)
          end)
        end,
      },
    })
    local destroyed = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { destroyed }
    assert(destroyed:prepare())
    local run = destroyed:provider_operation("wait")
    assert(run)
    destroyed:destroy()
    assert(vim.wait(3000, function() return run:is_done() end))
    assert.are.equal("cancelled", run:result().error.kind)
  end)

  it("handles Windows whose View cannot present the provider console", function()
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = service({}) },
    })
    controllers = { controller }
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end

    local window = neoagent.new_window({
      controllers = controllers,
      view = function(opts)
        local view = require("neoagent.ui").new(opts)
        view.set_provider = false
        view.set_provider_open = false
        return view
      end,
    })
    windows = { window }
    assert(window:open())
    assert.is_nil(window:set_provider_console(true))
    assert(vim.tbl_contains(vim.tbl_map(function(entry) return entry[1] end, notifications),
      "neoagent: the active View does not support the provider console"))

    local view = window:view()
    view.set_provider = function() end
    view.set_provider_open = function()
      return nil, util.error("ui", "console boom")
    end
    local opened, err = window:set_provider_console(true)
    assert.is_nil(opened)
    assert.are.equal("ui", err.kind)
    assert.matches("console boom", err.message)
    vim.notify = original_notify

    local style, style_err = window:set_transcript_style("invalid")
    assert.is_nil(style)
    assert.matches("invalid transcript style", style_err.message)
  end)

  it("routes provider interactions through vim.ui adapters", function()
    local captured = {}
    local value = service({
      choose = {
        label = "Choose",
        run = function(ctx)
          return async.run(function()
            captured.choice = async.await(function(done)
              return ctx.interact.select({
                prompt = "Pick",
                items = {
                  { id = "one", label = "One", description = "Described" },
                  { id = "two", label = "Two" },
                },
              }, done)
            end)
            return { ok = true }
          end)
        end,
      },
      type = {
        label = "Type",
        run = function(ctx)
          return async.run(function()
            captured.text = async.await(function(done)
              return ctx.interact.input({ prompt = "Value" }, done)
            end)
            return { ok = true }
          end)
        end,
      },
      yes = {
        label = "Confirm",
        run = function(ctx)
          return async.run(function()
            captured.confirmed = async.await(function(done)
              return ctx.interact.confirm({ prompt = "Sure?" }, done)
            end)
            return { ok = true }
          end)
        end,
      },
    })
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())

    local original_select, original_input = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, opts, on_choice)
      captured.prompt = opts.prompt
      captured.formatted = {}
      for _, item in ipairs(items) do
        captured.formatted[#captured.formatted + 1] = opts.format_item(item)
      end
      on_choice(items[1])
    end
    vim.ui.input = function(opts, on_choice)
      captured.input_prompt = opts.prompt
      on_choice("typed")
    end

    assert(wait(controller:provider_operation("choose")))
    assert.are.equal("one", captured.choice)
    assert.are.equal("Pick", captured.prompt)
    assert.are.same({ "One · Described", "Two" }, captured.formatted)
    assert.are.equal("succeeded", controller:provider_info().state.operation.state)

    assert(wait(controller:provider_operation("type")))
    assert.are.equal("typed", captured.text)
    assert.are.equal("Value ", captured.input_prompt)

    assert(wait(controller:provider_operation("yes")))
    assert.is_true(captured.confirmed)

    vim.ui.select = function() error("select boom") end
    vim.ui.input = function() error("input boom") end
    local failed = controller:provider_operation("choose")
    assert(vim.wait(3000, function() return failed:is_done() end))
    assert.is_false(failed:result().ok)
    assert.matches("select boom", failed:result().error.message)

    vim.ui.select, vim.ui.input = original_select, original_input
  end)

  it("installs the provider command with completion and cancellation", function()
    local pending = {}
    local calls = 0
    local captured_args
    local value = service({
      ping = {
        label = "Ping service",
        complete = function(arg_lead, args)
          assert.are.equal("a", arg_lead)
          assert.are.equal("a", args)
          return { "alpha", "other" }
        end,
        run = function(ctx)
          calls = calls + 1
          captured_args = ctx.args
          return async.run(function() return { ok = true } end)
        end,
      },
      wait = {
        label = "Wait",
        run = function()
          return async.run(function()
            return async.await(function(done)
              pending.resolve = done.resolve
              pending.reject = done.reject
              return function() end
            end)
          end)
        end,
      },
    })
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    neoagent.set_default_window(window)
    vim.g.loaded_neoagent = nil
    vim.cmd("runtime plugin/neoagent.lua")

    assert.are.same({ "ping", "wait" },
      vim.tbl_map(function(operation) return operation.id end,
        neoagent.provider_operations()))
    assert.are.same({ "ping" },
      vim.fn.getcompletion("NeoagentProvider p", "cmdline"))
    assert.are.same({ "wait" },
      vim.fn.getcompletion("NeoagentProvider w", "cmdline"))
    assert.are.same({ "alpha" },
      vim.fn.getcompletion("NeoagentProvider ping a", "cmdline"))

    vim.cmd("NeoagentProvider ping")
    assert(vim.wait(1000, function()
      return calls == 1
        and controller:provider_info().state.operation.state == "succeeded"
    end))
    assert.are.equal("succeeded", controller:provider_info().state.operation.state)
    assert.are.equal("", captured_args)

    vim.cmd("NeoagentProvider ping extra args")
    assert(vim.wait(1000, function()
      return calls == 2
        and controller:provider_info().state.operation.state == "succeeded"
    end))
    assert.are.equal("extra args", captured_args)

    vim.cmd("NeoagentProvider")
    assert.is_true(window:provider_console_open())
    vim.cmd("NeoagentProvider")
    assert.is_false(window:provider_console_open())

    local run = controller:provider_operation("wait")
    assert(run)
    vim.cmd("NeoagentProvider!")
    assert(vim.wait(3000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
  end)

  it("isolates provider service and console failures", function()
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end

    local broken = {
      id = "fake",
      name = "Broken",
      operations = {
        invalid = { label = "Invalid", run = function() return {} end },
      },
    }
    function broken:state() error("state boom") end
    function broken:subscribe()
      return function() error("unsubscribe boom") end
    end
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = broken },
    })
    controllers = { controller }
    assert(controller:prepare())
    assert.are.equal("Provider state is unavailable",
      controller:snapshot().context.provider.state.blocks[1].text)

    local result, err = controller:provider_operation("missing")
    assert.is_nil(result)
    assert.are.equal("provider", err.kind)

    result = controller:provider_operation("invalid")
    assert(result)
    assert(vim.wait(3000, function() return result:is_done() end))
    assert.is_false(result:result().ok)
    assert.matches("must return a Run", result:result().error.message)

    local invalid = {
      id = "fake",
      name = "Invalid",
      operations = {},
      state = function() return { summary = "ok" } end,
    }
    local invalid_controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = invalid },
    })
    table.insert(controllers, invalid_controller)
    invalid_controller:prepare()
    local bound, bind_err = invalid_controller:bind_provider("absent")
    assert.is_nil(bound)
    assert.matches("provider service for absent is invalid", bind_err.message)

    local invalid_state = {
      id = "fake",
      name = "Invalid state",
      operations = {},
      state = function() return { fields = { { label = "x" } } } end,
    }
    local state_controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = invalid_state },
    })
    table.insert(controllers, state_controller)
    state_controller:prepare()

    local invalid_subscribe = {
      id = "fake",
      name = "Subscribe failure",
      operations = {},
      state = function() return false end,
      subscribe = function() error("subscribe boom") end,
    }
    local subscribe_controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = invalid_subscribe },
    })
    table.insert(controllers, subscribe_controller)
    subscribe_controller:prepare()

    local missing_state = {
      id = "fake",
      name = "Missing state",
      operations = {},
    }
    local missing_controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = missing_state },
    })
    table.insert(controllers, missing_controller)
    missing_controller:prepare()

    controller:destroy()
    for index = #controllers, 1, -1 do
      if controllers[index] == controller then table.remove(controllers, index) end
    end
    vim.notify = original_notify
    local text = table.concat(vim.tbl_map(function(entry) return entry[1] end, notifications), "\n")
    assert.matches("provider service for fake is invalid", text)
    assert.matches("requires a state function", text)
    assert.matches("field value must be a string", text)
    assert.matches("subscribe boom", text)
    assert.matches("unsubscribe boom", text)
  end)

  it("rejects invalid and cancelled provider interactions safely", function()
    local captured = {}
    local value = service({
      no_items = {
        label = "No items",
        run = function(ctx)
          return async.run(function()
            return async.await(function(done)
              return ctx.interact.select({}, done)
            end)
          end)
        end,
      },
      bad_item = {
        label = "Bad item",
        run = function(ctx)
          return async.run(function()
            return async.await(function(done)
              return ctx.interact.select({ items = { { label = "missing" } } }, done)
            end)
          end)
        end,
      },
      cancel_select = {
        label = "Cancel select",
        run = function(ctx)
          return async.run(function()
            return async.await(function(done)
              return ctx.interact.select({ items = { { id = "one", label = "One" } } }, done)
            end)
          end)
        end,
      },
      cancel_input = {
        label = "Cancel input",
        run = function(ctx)
          return async.run(function()
            return async.await(function(done)
              return ctx.interact.input({ prompt = "Value" }, done)
            end)
          end)
        end,
      },
      cancel_confirm = {
        label = "Cancel confirm",
        run = function(ctx)
          return async.run(function()
            return async.await(function(done)
              return ctx.interact.confirm({ prompt = "Sure?" }, done)
            end)
          end)
        end,
      },
      bad_progress = {
        label = "Bad progress",
        run = function(ctx)
          return async.run(function()
            ctx.interact.progress({})
            ctx.interact.notify("worked", vim.log.levels.INFO)
            captured.notified = true
            return { ok = true }
          end)
        end,
      },
    })
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    assert(controller:prepare())

    local original_select, original_input = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, opts, on_choice) on_choice(items[1]) end
    vim.ui.input = function(opts, on_choice) on_choice("value") end

    for _, id in ipairs({ "no_items", "bad_item" }) do
      local run = controller:provider_operation(id)
      assert(vim.wait(3000, function() return run:is_done() end))
      assert.is_false(run:result().ok)
    end

    vim.ui.select = function(_, _, on_choice) on_choice(nil) end
    vim.ui.input = function(_, on_choice) on_choice(nil) end
    for _, id in ipairs({ "cancel_select", "cancel_input", "cancel_confirm" }) do
      local run = controller:provider_operation(id)
      assert(vim.wait(3000, function() return run:is_done() end))
      assert.is_false(run:result().ok)
      assert.are.equal("cancelled", run:result().error.kind)
    end

    vim.ui.select = function() error("confirm boom") end
    vim.ui.input = function() error("input boom") end
    for _, id in ipairs({ "cancel_input", "cancel_confirm" }) do
      local run = controller:provider_operation(id)
      assert(vim.wait(3000, function() return run:is_done() end))
      assert.is_false(run:result().ok)
    end
    vim.ui.select, vim.ui.input = original_select, original_input

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local run = controller:provider_operation("bad_progress")
    assert(vim.wait(3000, function() return run:is_done() end))
    vim.notify = original_notify
    assert.is_true(run:result().ok)
    assert.is_true(captured.notified)
    assert.matches("provider progress is invalid", notifications[1][1])
  end)

  it("derives Codex console state from real provider_status events", function()
    local codex = require("neoagent.providers.codex")
    local model = fake_model.new({ {
      events = { { type = "provider_status", text = "weekly 84% left · 5h 60% left" } },
      result = fake_model.assistant({ { type = "text", text = "ok" } }),
    } })
    local controller_options = options("codex", model)
    controller_options.default_model = { provider = "openai-codex", model = "codex" }
    controller_options.providers = {
      ["openai-codex"] = { api = "fake", models = { codex = {} } },
    }
    local codex_service = codex.new()
    codex_service.open_operation = nil
    local controller = neoagent.new(controller_options, {
      providers = { ["openai-codex"] = codex_service },
    })
    controllers = { controller }
    assert(controller:prepare())
    assert.are.equal("Usage loads when this console opens",
      controller:snapshot().context.provider.state.blocks[1].text)

    local window = neoagent.new_window({ controllers = { controller } })
    windows = { window }
    assert(window:open())
    assert(window:set_provider_console(true))

    local run = controller:send("hello")
    wait(run)
    assert(vim.wait(1000, function()
      local state = controller:snapshot().context.provider.state
      return state.blocks[1] and state.blocks[1].label == "Weekly limit"
        and state.blocks[1].remaining == 0.84
    end))
    local state = controller:snapshot().context.provider.state
    assert.are.same({
      { type = "limit", label = "Weekly limit", remaining = 0.84,
        level = "success" },
      { type = "limit", label = "5h limit", remaining = 0.6,
        level = "success" },
    }, { state.blocks[1], state.blocks[2] })
    local console = table.concat(vim.api.nvim_buf_get_lines(
      window:view().provider_buf, 0, -1, false), "\n")
    assert.matches("Weekly limit  .*84%% left", console)
    assert.matches("84%%", console)
    assert.matches("5h limit  .*60%% left", console)
  end)

  it("derives Codex console state from rate-limit errors", function()
    local codex = require("neoagent.providers.codex")
    local model = fake_model.new({ {
      result = {
        ok = false,
        error = {
          kind = "model",
          message = "HTTP 429: The usage limit has been reached",
          provider_status = "weekly 0% left",
        },
      },
    } })
    local controller_options = options("codex", model)
    controller_options.default_model = { provider = "openai-codex", model = "codex" }
    controller_options.providers = {
      ["openai-codex"] = { api = "fake", models = { codex = {} } },
    }
    local controller = neoagent.new(controller_options, {
      providers = { ["openai-codex"] = codex.new() },
    })
    controllers = { controller }
    assert(controller:prepare())
    local run = controller:send("hello")
    wait(run)
    assert(vim.wait(1000, function()
      local state = controller:snapshot().context.provider.state
      return state.blocks[1] and state.blocks[1].label == "Weekly limit"
        and state.blocks[1].remaining == 0
    end))
    local block = controller:snapshot().context.provider.state.blocks[1]
    assert.are.equal("error", block.level)
    assert.are.equal(0, block.remaining)
  end)

  it("focuses the provider console with Alt-l and returns with Alt-h", function()
    local value = service({})
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    assert(window:set_provider_console(true))
    local view = window:view()

    view:focus_transcript()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-l>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view.provider_win
    end))
    assert.are.equal(view.provider_win, vim.api.nvim_get_current_win())

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-h>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view.transcript_win
    end))
    assert.are.equal(view.transcript_win, vim.api.nvim_get_current_win())

    view:focus_provider()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-j>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view.input_win
    end))
    assert.are.equal(view.input_win, vim.api.nvim_get_current_win())

    view:set_provider_open(false)
    view:focus_transcript()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-l>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view.provider_open
        and vim.api.nvim_get_current_win() == view.provider_win
    end))
  end)

  it("moves above the first transcript card into the visible provider", function()
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = service({}) },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    assert(window:set_provider_console(true))
    local view = window:view()

    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function focused(target)
      return vim.wait(1000, function()
        return vim.api.nvim_get_current_win() == target
      end)
    end

    view:focus_transcript()
    vim.api.nvim_win_set_cursor(view.transcript_win, { 1, 0 })
    feed("<A-k>")
    assert(focused(view.provider_win))
  end)

  it("applies and restores the complete provider panel layout", function()
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = service({}) },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    local view = window:view()
    local original = vim.api.nvim_win_get_config(view.transcript_win)

    assert(window:set_provider_console(true))
    local configs = assert(view:_configs())
    local split = vim.api.nvim_win_get_config(view.transcript_win)
    local provider = vim.api.nvim_win_get_config(view.provider_win)
    local input = vim.api.nvim_win_get_config(view.input_win)
    assert.are.equal(configs.transcript.width, split.width)
    assert.are.equal(split.width, provider.width)
    assert.are.equal(configs.input.width, input.width)
    assert.is_true(provider.row < split.row)
    assert.are.equal(provider.row + provider.height + 2, split.row)

    assert(window:set_provider_console(false))
    local restored = vim.api.nvim_win_get_config(view.transcript_win)
    assert.are.equal(original.width, restored.width)
    assert.is_false(window:provider_console_open())

    assert(window:set_provider_console(true))
    view:set_provider_open(false)
    assert.is_false(window:provider_console_open())
  end)

  it("covers provider console internals and mapping toggles", function()
    local value = service({
      one = { label = "One", description = "First operation", run = function() return async.run(function() return { ok = true } end) end },
      two = { label = "Two", run = function() return async.run(function() return { ok = true } end) end },
    })
    local controller = neoagent.new(options("provider", fake_model.new({})), {
      providers = { fake = value },
    })
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    local view = window:view()
    view.provider_snapshot = nil
    assert.is_nil(view:_provider_content())
    assert.is_nil(view:_provider_row())
    assert.are.same({}, view:_provider_rows())
    assert.are.equal(math.max(1, vim.o.columns - 4), view:_provider_width())
    assert.is_false(view:_move_provider(1))
    assert.is_false(view:_select_provider())
    assert.is_false(view:_refresh_provider())

    local missing, missing_err = view:set_provider_open(true)
    assert.is_nil(missing)
    assert.matches("No provider console state", missing_err.message)

    view:set_provider(controller:snapshot().context.provider)
    assert.is_nil(window:close())
    local opened, err = view:set_provider_open(true)
    assert.is_nil(opened)
    assert.matches("requires the Neoagent window", err.message)
    assert(window:open())
    opened, err = view:set_provider_open(true)
    assert(opened, err and err.message)
    assert.is_true(view:_open_provider(true))
    local rows = view:_provider_rows()
    vim.api.nvim_win_set_cursor(view.provider_win, { 1, 0 })
    assert.is_true(view:_move_provider(1, 2))
    assert.are.equal(rows[2] + 1,
      vim.api.nvim_win_get_cursor(view.provider_win)[1])
    vim.api.nvim_win_set_cursor(view.provider_win, { rows[#rows] + 1, 0 })
    assert.is_true(view:_move_provider(-1, 1))
    vim.api.nvim_win_set_cursor(view.provider_win, { rows[1] + 1, 0 })
    assert.is_true(view:_move_provider(-1, 1))
    vim.api.nvim_win_set_cursor(view.provider_win, { rows[#rows] + 1, 0 })
    assert.is_true(view:_move_provider(1, 1))
    view:set_position("center")
    local original_columns, original_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 14, 10
    view:_layout_provider()
    assert.is_false(view.provider_open)
    vim.o.columns, vim.o.lines = original_columns, original_lines
    assert(window:set_provider_console(true))
    vim.api.nvim_win_set_cursor(view.provider_win, { 1, 0 })
    assert.is_false(view:_select_provider())
    vim.api.nvim_win_close(view.provider_win, true)
    assert(vim.wait(1000, function()
      return view.provider_win == nil
        or not vim.api.nvim_win_is_valid(view.provider_win)
    end))

    assert(window:set_provider_console(true))
    view:set_provider_open(false)
    value:on_event({ type = "provider_status", text = "updated" })
    assert.is_false(view.provider_open)
    assert.is_false(window:provider_console_open())
    assert(window:set_provider_console(true))
    view:focus_input()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-p>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return view.provider_open == false end))
    view:focus_input()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-p>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view.provider_open == true
        and vim.api.nvim_get_current_win() == view.provider_win
    end))
    assert.is_true(window:provider_console_open())
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-p>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return view.provider_open == false end))
    assert.is_false(window:provider_console_open())

    view:set_provider_open(false)
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local plain = {
      name = "plain",
      render_block = function() return { lines = { "x" }, highlights = {}, line_groups = {} } end,
      render_details = function() return nil end,
      render_dialog = function() return { content = { lines = { "x" }, highlights = {}, line_groups = {} } } end,
    }
    view.renderer = plain
    assert.is_nil(view:set_provider_open(true))
    view:_close_provider(false)
    view:_toggle_provider()
    assert.are.equal(3, #notifications)
    vim.notify = original_notify
    local text = table.concat(vim.tbl_map(function(entry) return entry[1] end, notifications), "\n")
    assert.matches("Renderer does not support the provider console", text)
  end)
end)
