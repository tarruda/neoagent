local AgentApplet = require("neoagent.agent_applet")
local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")
local util = require("neoagent.util")

describe("Agent Applet boundaries", function()
  local applets
  local agents

  before_each(function()
    applets = {}
    agents = {}
  end)

  after_each(function()
    for _, applet in ipairs(applets) do
      if not applet:is_destroyed() then applet:destroy() end
    end
    for _, agent in ipairs(agents) do
      if not agent:is_destroyed() then agent:destroy() end
    end
  end)

  local function view_factory(record, features)
    features = features or {}
    return function(opts)
      local view = {
        callbacks = opts,
        input = "",
        messages = {},
        context = {},
        events = {},
        opened = false,
        notify = features.notify,
        open_uri = features.open_uri,
      }
      function view:open()
        self.opened = true
        return true
      end
      function view:close() self.opened = false end
      function view:is_open() return self.opened end
      function view:destroy()
        self:close()
        self.destroyed = true
      end
      function view:get_input() return self.input end
      function view:set_input(value)
        self.input = value
        return value
      end
      function view:set_messages(value) self.messages = value end
      function view:set_context(value) self.context = value end
      function view:apply(value) self.events[#self.events + 1] = value end
      function view:finish(value) self.result = value end
      function view:focus_input()
        self.focused = (self.focused or 0) + 1
        return self.opened
      end
      function view:set_position(value) self.position = value end
      if not features.omit_presentation then
        function view:set_presentation(value)
          if features.presentation_error then
            return nil, util.error("ui", "presentation rejected")
          end
          self.presentation = value
          return true
        end
      end
      if not features.omit_dialog then
        function view:set_dialog(value)
          if features.dialog_error then
            return nil, util.error("ui", "dialog rejected")
          end
          self.dialog = value
          return true
        end
      end
      record.view = view
      return view
    end
  end

  local function applet(opts)
    opts = vim.tbl_extend("force", {
      config = { style = "codex", position = "center" },
      persistence = { enabled = false },
      profile_id = "neo",
      label = "Draft",
    }, opts or {})
    local owner = opts.owner
    local callbacks = opts.callbacks
    opts.owner = nil
    opts.callbacks = nil
    local value = AgentApplet.new(opts)
    if callbacks then value:claim(owner or {}, callbacks) end
    applets[#applets + 1] = value
    return value
  end

  local function agent(runtime)
    local value = require("neoagent").new({
      name = "boundary",
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = {
        fake = { api = "fake-api", models = { test = {} } },
      },
      _apis = { ["fake-api"] = function() return fake_model.new({}) end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    }, runtime)
    agents[#agents + 1] = value
    return value
  end

  it("routes draft View actions and URI effects through one owner", function()
    local record = {}
    local opened_uri
    local effects = {
      notify = function(_, message, level)
        record.notification = { message, level }
        return true
      end,
      open_uri = function(_, uri)
        opened_uri = uri
        return true
      end,
    }
    local value = applet({
      context = { workspace = "workspace" },
      view = view_factory(record, effects),
      callbacks = {
        on_agents = function() return "agents" end,
        on_cycle_thinking = function() return "thought" end,
        on_select_model = function() return "model" end,
        on_resume_session = function() return "session" end,
        on_provider_shell = function() return "provider-shell" end,
      },
    })

    local run, bind_err = value:send("unbound")
    assert.is_nil(run)
    assert.matches("No Agent is bound", bind_err.message)
    assert(value:open())
    assert.is_true(value:focus_input())
    assert.are.equal("thought", record.view.callbacks.on_cycle_thinking())
    assert.are.equal("agents", record.view.callbacks.on_agents())
    assert.are.equal("model", record.view.callbacks.on_select_model())
    assert.are.equal("session", record.view.callbacks.on_resume_session())
    assert(value:presenter():notify({ message = "notice" }))
    assert.are.same({ "notice", nil }, record.notification)
    assert(value:presenter():open_uri("https://example.test/view"))
    assert.are.equal("https://example.test/view", opened_uri)
    assert.is_false(value:toggle())
    assert(value:toggle())
    assert.is_nil(value:set_position("diagonal"))
    assert.are.equal("provider-shell",
      record.view.callbacks.on_provider_shell())
    assert.is_nil(value.ensure_agent)
    assert.is_nil(value:select_input_history())

    local unbound = applet({
      view = view_factory({}),
      callbacks = { on_bind = function() return {} end },
    })
    local missing, missing_err = unbound:send("not attached")
    assert.is_nil(missing)
    assert.matches("did not bind", missing_err.message)

    local original_open = vim.ui.open
    vim.ui.open = function(uri)
      opened_uri = uri
      return true
    end
    local fallback = applet({})
    local ok, err = pcall(function()
      assert(fallback:presenter():open_uri("https://example.test/fallback"))
    end)
    vim.ui.open = original_open
    assert(ok, err)
    assert.are.equal("https://example.test/fallback", opened_uri)

    value:destroy()
    assert.is_nil(value:open())
  end)

  it("contains history storage failures and restores a selected entry", function()
    local record = {}
    local fake_destroyed = false
    local fake_agent = {
      is_destroyed = function() return fake_destroyed end,
      destroy = function() fake_destroyed = true end,
      set_attention = function() end,
      prepare = function() return true end,
      send = function() return { id = "run" }, nil, 1, "turn" end,
      snapshot = function()
        return {
          revision = 0,
          messages = {},
          context = { workspace = "root" },
          events = {},
          result = nil,
        }
      end,
    }
    local value
    value = applet({
      context = { workspace = "root" },
      persistence = { enabled = true, directory = "unused" },
      view = view_factory(record),
      callbacks = {
        on_bind = function()
          value.agent_value = fake_agent
          return fake_agent
        end,
      },
    })
    local store = {
      load = function()
        return nil, util.error("history", "load failed", "corrupt")
      end,
      add = function()
        return nil, util.error("history", "save failed")
      end,
    }
    value.history_stores.root = store

    assert.are.same({}, value:input_history())
    assert(value:send("remember this"))
    store.load = function() return { "first", "second" } end
    assert(value:open())
    assert(value:select_input_history())
    local request = assert(value:presenter():snapshot().active)
    assert(value:presenter():resolve(request.id, "history-2"))
    assert(vim.wait(1000, function()
      return record.view:get_input() == "second"
        and (record.view.focused or 0) > 0
    end, 5))
  end)

  it("contains unsupported semantic surfaces and hydration failures", function()
    local rejected_record = {}
    local rejected = applet({
      view = view_factory(rejected_record, { presentation_error = true }),
    })
    local selection = rejected:presenter():select({ items = { "choice" } })
    local opened, open_err = rejected:open()
    assert.is_nil(opened)
    assert.matches("presentation rejected", open_err.message)
    assert.is_true(rejected_record.view.destroyed)
    assert.is_nil(rejected:view())
    assert.is_false(selection:is_done())
    rejected.view_factory = view_factory(rejected_record)
    assert(rejected:open())
    local active = assert(rejected:presenter():snapshot().active)
    assert(rejected:presenter():cancel(active.id, "test complete"))
    assert(vim.wait(1000, function() return selection:is_done() end, 5))

    local dialog_record = {}
    local unsupported = applet({
      view = view_factory(dialog_record, { omit_dialog = true }),
    })
    assert(unsupported:open())
    local dialog = unsupported:dialogs():show({
      placement = "float",
      title = "Unsupported dialog",
      body = "body",
      actions = { { id = "close", label = "Close", key = "<CR>" } },
    })
    assert(vim.wait(1000, function() return dialog:is_done() end, 5))
    assert.is_false(dialog:result().ok)

    local rejected_dialog_record = {}
    local rejected_dialog = applet({
      view = view_factory(rejected_dialog_record, { dialog_error = true }),
    })
    assert(rejected_dialog:open())
    local rejected_run = rejected_dialog:dialogs():show({
      placement = "float",
      title = "Rejected dialog",
      body = "body",
      actions = { { id = "close", label = "Close", key = "<CR>" } },
    })
    assert(vim.wait(1000, function() return rejected_run:is_done() end, 5))
    assert.is_false(rejected_run:result().ok)

    local hydration_record = {}
    local hydration = applet({ view = view_factory(hydration_record) })
    hydration.agent_value = {
      is_destroyed = function() return false end,
      destroy = function() end,
      set_attention = function() end,
      prepare = function() return true end,
      snapshot = function() error("snapshot failed") end,
    }
    local opened, open_err = hydration:open()
    assert.is_nil(opened)
    assert.matches("snapshot failed", open_err.message)
    assert.is_true(hydration_record.view.destroyed)
  end)

  it("reports Dialog subscriber failures through the default Presenter", function()
    local value = applet({})
    local detach = value:dialogs():subscribe(function(snapshot)
      if snapshot.active then error("dialog subscriber failed") end
    end)
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local ok, err = pcall(function()
      local run = value:dialogs():show({
        placement = "float",
        title = "Subscriber failure",
        body = "body",
        actions = { { id = "close", label = "Close", key = "<CR>" } },
      })
      assert(vim.wait(1000, function()
        return notifications[1] ~= nil
      end, 5))
      assert.matches("dialog subscriber failed", notifications[1][1])
      value:dialogs():cancel_pending("test complete")
      assert(vim.wait(1000, function() return run:is_done() end, 5))
    end)
    vim.notify = original_notify
    detach()
    assert(ok, err)
  end)

  it("rolls back attachment failure and preserves retry semantics", function()
    local owned_agent = agent()
    local record = {}
    local value = applet({
      presenter = owned_agent:presenter(),
      dialogs = owned_agent:dialogs(),
      view = view_factory(record),
    })
    local attach = owned_agent.attach_applet
    owned_agent.attach_applet = function()
      error("attachment failed")
    end
    assert.has_error(function() value:bind(owned_agent) end,
      "attachment failed")
    assert.is_nil(value:agent())

    owned_agent.attach_applet = attach
    assert.are.equal(owned_agent, value:bind(owned_agent))
    local context, context_err = value:set_draft_context({ model = "other" })
    assert.is_nil(context)
    assert.matches("bound Agent", context_err.message)
    assert(value:open())
    assert.is_false(record.view.callbacks.on_resume_session())

    local original_prepare = owned_agent.prepare
    local original_send = owned_agent.send
    owned_agent.prepare = function() return true end
    value.pending_submission = "retry"
    owned_agent.send = function()
      return nil, util.error("model", "retry failed")
    end
    local failed, failed_err = value:retry_submission()
    assert.is_nil(failed)
    assert.matches("retry failed", failed_err.message)
    assert.is_nil(value:pending_message())

    value.pending_submission = "retry"
    record.view:set_input("retry")
    owned_agent.send = function()
      return { id = "retry-run" }, nil, 1, "turn"
    end
    assert(value:retry_submission())
    assert.are.equal("retry", record.view:get_input())
    value:_apply({
      revision = value.agent_snapshot.revision + 1,
      type = "submission_accepted",
      submission_id = 1,
      prompt = "retry",
      entry_id = "entry",
    })
    assert.are.equal("", record.view:get_input())

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    owned_agent.set_ui_position = function()
      return nil, util.error("settings", "save failed")
    end
    local positioned, position_err = value:set_position("left")
    vim.notify = original_notify
    assert.are.equal("left", positioned)
    assert.matches("save failed", position_err.message)
    assert.matches("settings were not saved", notifications[#notifications][1])
    owned_agent.prepare = original_prepare
    owned_agent.send = original_send
  end)

  it("destroys an unbound Applet without consuming borrowed semantic sources", function()
    local owned_agent = agent()
    local value = applet({
      presenter = owned_agent:presenter(),
      dialogs = owned_agent:dialogs(),
    })
    assert.are.equal(owned_agent, value:bind(owned_agent))
    assert.are.equal(owned_agent, value:unbind(owned_agent))

    value:destroy()

    assert.is_false(owned_agent:is_destroyed())
    assert.is_nil(owned_agent:applet())
    assert.is_false(owned_agent:presenter().destroyed)
    local presented
    local detach_presenter = owned_agent:presenter():attach({
      present = function(snapshot)
        presented = snapshot
        return true
      end,
    })
    local presentation = owned_agent:presenter():notice({
      prompt = "Borrowed Presenter",
      body = "ready",
    })
    assert.is_table(presented.active)
    assert(owned_agent:presenter():resolve(presented.active.id))
    assert(vim.wait(1000, function() return presentation:is_done() end, 5))
    assert.is_true(presentation:result().ok)
    detach_presenter()

    local dialog_snapshot
    local detach_dialog = owned_agent:dialogs():subscribe(function(snapshot)
      dialog_snapshot = snapshot
    end)
    local dialog = owned_agent:dialogs():show({
      placement = "float",
      title = "Borrowed Dialogs",
      body = "ready",
      actions = { { id = "done", label = "Done", key = "<CR>" } },
    })
    assert.is_table(dialog_snapshot.active)
    assert(owned_agent:dialogs():choose(dialog_snapshot.active.id, "done"))
    assert(vim.wait(1000, function() return dialog:is_done() end, 5))
    assert.is_true(dialog:result().ok)
    detach_dialog()
  end)

  it("rolls back every View hydration failure and preserves input", function()
    for _, method in ipairs({
      "set_position", "set_messages", "set_context", "apply", "finish",
    }) do
      for _, returned in ipairs({ false, true }) do
        local owned_agent = agent()
        local record = {}
        local value = applet({
          presenter = owned_agent:presenter(),
          dialogs = owned_agent:dialogs(),
          view = view_factory(record),
        })
        assert(value:open())
        assert.are.equal("retained draft", value:set_input("retained draft"))
        local failed_view = record.view
        failed_view[method] = function()
          if returned then
            return nil, util.error("ui", method .. " rejected")
          end
          error(method .. " exploded")
        end
        owned_agent.snapshot = function()
          return {
            revision = 1,
            messages = { { role = "user", content = "message" } },
            context = {
              workspace = owned_agent:get_workspace().root,
              model = "fake/test",
              position = "left",
            },
            events = { { type = "text_delta", text = "event" } },
            result = { ok = true },
          }
        end

        local expected = method .. (returned and " rejected" or " exploded")
        assert.has_error(function() value:bind(owned_agent) end, expected)
        assert.is_nil(value:agent())
        assert.is_nil(value:view())
        assert.is_true(failed_view.destroyed)
        assert.are.equal("retained draft", value:get_input())

        assert.are.equal(owned_agent, value:bind(owned_agent))
        assert(value:open())
        assert.are.equal("retained draft", value:get_input())
      end
    end
  end)

  it("destroys every failed View candidate before publication", function()
    for _, method in ipairs({
      "set_input", "set_context", "set_dialog", "set_presentation",
    }) do
      for _, returned in ipairs({ false, true }) do
        local record = {}
        local created = 0
        local base = view_factory(record)
        local value = applet({
          view = function(opts)
            created = created + 1
            local view = base(opts)
            if created == 1 then
              view[method] = function()
                if returned then
                  return nil, util.error("ui", method .. " rejected")
                end
                error(method .. " exploded")
              end
            end
            return view
          end,
        })
        value.input_value = "retained candidate input"
        local pending
        if method == "set_dialog" then
          pending = value:dialogs():show({
            placement = "float",
            title = "Candidate dialog",
            body = "body",
            actions = { {
              id = "close", label = "Close", key = "<CR>",
            } },
          })
        elseif method == "set_presentation" then
          pending = value:presenter():select({ items = { "one" } })
        end

        local opened, err = value:open()
        assert.is_nil(opened)
        assert.matches(method, err.message)
        assert.is_true(record.view.destroyed)
        assert.is_nil(value:view())
        assert.are.equal("retained candidate input", value:get_input())

        assert(value:open())
        assert.are.equal(2, created)
        assert.are.equal("retained candidate input", value:get_input())
        if pending then
          if method == "set_dialog" then
            value:dialogs():cancel_pending("test complete")
          else
            local active = assert(value:presenter():snapshot().active)
            value:presenter():cancel(active.id, "test complete")
          end
          assert(vim.wait(1000, function() return pending:is_done() end))
        end
      end
    end
  end)

  it("rolls back subscription and returned attachment failures", function()
    local owned_agent = agent()
    local record = {}
    local value = applet({
      presenter = owned_agent:presenter(),
      dialogs = owned_agent:dialogs(),
      view = view_factory(record),
    })
    assert(value:open())
    local first_view = record.view
    local subscribe = owned_agent.subscribe
    owned_agent.subscribe = function() error("subscription exploded") end
    assert.has_error(function() value:bind(owned_agent) end,
      "subscription exploded")
    assert.is_nil(value:agent())
    assert.are.equal(first_view, value:view())
    assert.is_false(first_view.destroyed == true)

    owned_agent.subscribe = subscribe
    local attach = owned_agent.attach_applet
    owned_agent.attach_applet = function()
      return nil, util.error("agent", "attachment rejected")
    end
    assert.has_error(function() value:bind(owned_agent) end,
      "attachment rejected")
    assert.is_nil(value:agent())
    assert.is_nil(value:view())
    assert.is_true(first_view.destroyed)

    owned_agent.attach_applet = attach
    assert.are.equal(owned_agent, value:bind(owned_agent))
    assert(value:open())
  end)

  it("validates Agent Applets and contains activity listeners", function()
    assert.has_error(function()
      agent({ applet = {} })
    end, "agent Applet is invalid")
    local workspace = vim.fn.tempname()
    local session = assert(require("neoagent.session").new({
      workspace = workspace,
    }))
    assert.has_error(function()
      agent({ session = session, workspace = workspace .. "-other" })
    end, "agent Workspace must match the Session Workspace")

    local value = agent()
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local calls = 0
    local unsubscribe = value:subscribe_activity(function()
      calls = calls + 1
      if calls > 1 then error("activity failed") end
    end)
    local ok, err = pcall(function()
      value:set_attention("dialog", { kind = "dialog", label = "Waiting" })
      assert.are.equal(2, calls)
      assert.matches("activity listener failed", notifications[#notifications][1])
      assert.has_error(function()
        value:subscribe_activity(function() error("initial activity failed") end)
      end, "initial activity failed")
      value:set_attention("dialog", nil)
    end)
    unsubscribe()
    vim.notify = original_notify
    assert(ok, err)

    local requests = 0
    local unavailable = agent({ workspace_trust = {
      is_trusted = function()
        return nil, util.error("workspace_trust", "trust store unreadable")
      end,
      check = function()
        return nil, util.error("workspace_trust", "trust store unreadable")
      end,
      request = function() requests = requests + 1 end,
    } })
    local prepared, prepare_err = unavailable:prepare()
    assert.is_nil(prepared)
    assert.matches("trust store unreadable", prepare_err.message)
    assert.are.equal(0, requests)
  end)

  it("publishes independent semantic updates to each Agent listener", function()
    local value = agent()
    local observed, revisions = nil, {}
    local first = value:subscribe(function(update)
      if update.context then update.context.model = "mutated" end
    end)
    local second = value:subscribe(function(update)
      revisions[#revisions + 1] = update.revision
      if update.context then observed = update.context.model end
    end)

    assert(value:prepare())
    first()
    second()
    assert.are.equal("fake/test", observed)
    local snapshot = value:snapshot()
    assert.are.equal("fake/test", snapshot.context.model)
    assert.are.equal(revisions[#revisions], snapshot.revision)
    for index = 2, #revisions do
      assert.is_true(revisions[index] > revisions[index - 1])
    end
  end)

  it("rejects stale Agent publications and hydration snapshots", function()
    local record = {}
    local owned_agent = agent()
    local value = applet({
      presenter = owned_agent:presenter(),
      dialogs = owned_agent:dialogs(),
      view = view_factory(record),
    })
    value:bind(owned_agent)
    assert(value:open())

    local revision = owned_agent:snapshot().revision + 1
    value:_apply({
      revision = revision,
      type = "context",
      context = { workspace = owned_agent:get_workspace(), model = "new" },
    })
    value:_apply({
      revision = revision - 1,
      type = "context",
      context = { workspace = owned_agent:get_workspace(), model = "stale" },
    })
    assert.are.equal("new", record.view.context.model)

    assert(value:_hydrate({
      revision = 0,
      messages = {},
      context = { workspace = owned_agent:get_workspace(), model = "old" },
      events = {},
      result = nil,
    }))
    assert.are.equal("new", record.view.context.model)
  end)

  it("selects models and reports workspace trust failures", function()
    local selected = agent()
    local presenter = selected:presenter()
    local detach = presenter:attach({ present = function() return true end })
    local callback_model
    assert.is_true(selected:select_model(function(model)
      callback_model = model
    end))
    local request = assert(presenter:snapshot().active)
    assert(presenter:resolve(request.id, request.items[1].id))
    assert(vim.wait(1000, function() return callback_model ~= nil end, 5))
    assert.are.equal(callback_model, selected:get_model())
    detach()

    local trust = {
      is_trusted = function() return false end,
      check = function()
        return nil, util.error("workspace_trust", "workspace rejected")
      end,
    }
    local rejected = agent({ workspace_trust = trust })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local ok, err = pcall(function()
      local model, select_err = rejected:select_model()
      assert.is_nil(model)
      assert.matches("workspace rejected", select_err.message)
      model, select_err = rejected:set_model("fake", "test")
      assert.is_nil(model)
      assert.matches("workspace rejected", select_err.message)
      assert.matches("workspace rejected", notifications[#notifications][1])
    end)
    vim.notify = original_notify
    assert(ok, err)
  end)

  it("owns headless presentation and dialog sources", function()
    local value = agent()
    local original = value:presenter()
    local detach_original = original:attach({
      present = function() return true end,
    })
    assert.is_true(value:select_model())
    assert(original:snapshot().active)

    local presentation = assert(original:snapshot().active)
    assert(original:cancel(
      presentation.id, "test cancellation"))
    assert(vim.wait(1000, function()
      return original:snapshot().active == nil
    end, 5))

    local detach_dialogs = value:dialogs():subscribe(function() end)
    local dialog = value:dialogs():show({
      placement = "float",
      title = "Cancelable",
      body = "body",
      actions = { { id = "close", label = "Close", key = "<CR>" } },
    })
    local dialog_id = assert(value:dialogs():snapshot().active).id
    assert(value:dialogs():cancel(dialog_id, "test cancellation"))
    assert(vim.wait(1000, function() return dialog:is_done() end, 5))
    assert.is_false(dialog:result().ok)
    detach_dialogs()
    detach_original()
  end)

  it("contains immediately rejected branch presentations", function()
    local notifications = {}
    local presenter = {
      select = function()
        return async.run(function()
          error(util.error("presentation", "branch selector failed"), 0)
        end)
      end,
      input = function() end,
      confirm = function() end,
      notify = function(_, request)
        notifications[#notifications + 1] = request
        return true
      end,
      open_uri = function() return true end,
    }
    local value = agent({ presenter = presenter })
    assert(value:prepare())
    assert(value:get_session():append({ role = "user", content = "question" }))

    assert.is_true(value:select_branch())
    assert.matches("branch selector failed", notifications[#notifications].message)
  end)

  it("contains every live model-selector update failure", function()
    local notifications = {}
    local pending
    local update_mode = "ok"
    local presenter = {
      select = function()
        local run = async.run(function()
          return async.await(function(done) pending = done end)
        end)
        local function update()
          if update_mode == "throw" then error("update exploded") end
          if update_mode == "reject" then
            return nil, util.error("presentation", "update rejected")
          end
          return true
        end
        return run, update
      end,
      input = function() end,
      confirm = function() end,
      notify = function(_, request)
        notifications[#notifications + 1] = request
        return true
      end,
      open_uri = function() return true end,
    }
    local models = require("neoagent.models")
    local subscribe_available = models.subscribe_available
    local subscriber
    models.subscribe_available = function(_, _, _, callback)
      subscriber = callback
      return function() end
    end
    local ok, err = pcall(function()
      local value = agent({ presenter = presenter })
      assert(value:prepare())
      assert.is_true(value:select_model())
      assert.is_function(subscriber)

      subscriber(nil, util.error("model", "catalog update failed"))
      update_mode = "throw"
      subscriber({ "fake/test" })
      update_mode = "reject"
      subscriber({ "fake/test" })
      assert.matches("catalog update failed", notifications[1].message)
      assert.matches("update exploded", notifications[2].message)
      assert.matches("update rejected", notifications[3].message)
      pending.reject(async.cancelled_error)
    end)
    models.subscribe_available = subscribe_available
    assert(ok, err)
  end)
end)
