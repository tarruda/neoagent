local assert = require("luassert")
local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")
local view_handles = require("tests.helpers.view_handles")
local util = require("neoagent.util")
local agent_loop = require("neoagent.agent_loop")

describe("transcript history", function()
  ---@type Neoagent.Agent[]
  local agents = {}
  local copy = util.copy
  local validate_toolset = agent_loop.validate_toolset

  after_each(function()
    util.copy = copy
    agent_loop.validate_toolset = validate_toolset
    for _, agent in ipairs(agents) do
      agent:destroy()
    end
    agents = {}
  end)

  ---@param native? boolean
  ---@return Neoagent.Session, {first: string, middle: string, latest: string}
  local function conversation(native)
    local session = assert(require("neoagent.session").new())
    local _, _, first = session:append({
      role = "user",
      content = {
        { type = "text", text = "original complete request" },
      },
    })
    assert(first)
    assert(session:append({ role = "assistant", content = { { type = "text", text = "original answer" } } }))
    ---@param summary string
    ---@return string
    local function checkpoint(summary)
      local _, _, entry = session:append_compaction({
        summary = not native and summary or nil,
        tokens_before = 100,
        first_kept_entry_id = not native and first.id or nil,
        native = native and {
          role = "nativeCompaction",
          api = "openai-codex-responses",
          provider = "fake",
          model = "test",
          encrypted_content = "synthetic-secret-checkpoint",
        } or nil,
        retained_users = native and { { entry_id = first.id, text_chars = 3 } } or nil,
      })
      return assert(entry).id
    end
    local middle = checkpoint("first summary")
    assert(session:append({ role = "user", content = "middle request" }))
    local latest = checkpoint("latest summary")
    assert(session:append({ role = "user", content = "latest request" }))
    return session, { first = first.id, middle = middle, latest = latest }
  end

  ---@param stored Neoagent.Session
  ---@return Neoagent.Session
  local function without_receipts(stored)
    local session = assert(require("neoagent.session").new({
      store = {
        load = function()
          return stored:messages()
        end,
        append = function(_, message, state)
          local accepted, err = stored:append(message, state)
          return accepted, err, nil, { type = "append", messages = { util.copy(message) } }
        end,
        path = function()
          return stored:path()
        end,
        context_messages = function()
          return stored:context_messages()
        end,
      },
    }))
    return session
  end

  ---@param session Neoagent.Session
  ---@param model? Neoagent.TestModel
  ---@param native? boolean
  ---@return Neoagent.Agent
  local function agent_for(session, model, native)
    model = model or fake_model.new({})
    local agent = require("neoagent").new({
      default_registry = false,
      default_profile = native and "codex" or "chat",
      workspace_trust = false,
      sandbox = { enabled = false },
      persistence = { enabled = false },
      recording = { enabled = false },
      tools = {},
      skills = false,
      agent_instructions = false,
      compaction = { auto = false, keep_recent_tokens = 1, reserve_tokens = 128 },
      default_model = { provider = "fake", model = "test" },
      providers = {
        fake = {
          api = native and "openai-codex-responses" or "fake-api",
          base_url = "https://example.test",
          models = { test = {} },
        },
      },
      _apis = {
        [native and "openai-codex-responses" or "fake-api"] = function(resolved)
          model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
          model.context_window = 8192
          return model
        end,
      },
      ui = { images = false, position = "center" },
    }, { session = session })
    agents[#agents + 1] = agent
    assert(agent:prepare())
    return agent
  end

  ---@param agent Neoagent.Agent
  ---@return Neoagent.AgentApplet, Neoagent.View
  local function open(agent)
    local options = agent:config()
    local applet = require("neoagent.agent_applet").new({
      config = options.ui,
      persistence = options.persistence,
      presenter = agent:presenter(),
      dialogs = agent:dialogs(),
    })
    applet:bind(agent)
    assert(applet:open())
    local view = applet:view()
    assert(view)
    return applet, view
  end

  ---@param keys string
  local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  ---@param view Neoagent.View
  ---@return string
  local function text(view)
    assert(view.transcript.pane:flush())
    return table.concat(vim.api.nvim_buf_get_lines(assert(view_handles.buffer(view, "transcript")), 0, -1, false), "\n")
  end

  it("renders tool cards from accepted presentation capabilities without validating execution schemas", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "assistant", content = { {
      type = "toolCall", id = "inspect", name = "inspect", arguments = {},
    } } }))
    assert(session:append({
      role = "toolResult", toolCallId = "inspect", toolName = "inspect",
      content = { { type = "text", text = "tool output" } },
    }))
    local agent = agent_for(session)
    assert(agent:set_toolset({ tools = { {
      name = "inspect", description = "Inspect synthetic data",
      input_schema = { type = "object", properties = {} },
      execute = function()
        return { content = {} }
      end,
      render = function()
        return { kind = "text", title = "accepted tool renderer", lines = { "accepted presentation" } }
      end,
    } } }))
    local validations = 0
    agent_loop.validate_toolset = function(...)
      validations = validations + 1
      return validate_toolset(...)
    end
    local applet, view = open(agent)
    assert.matches("accepted presentation", text(view))
    assert.are.equal(0, validations, "rendering rebuilt the accepted execution Toolset")
    agent_loop.validate_toolset = validate_toolset
    applet:destroy()
  end)

  it("reuses recently visited transcript cards and their compiled regions", function()
    local session = conversation()
    local agent = agent_for(session)
    local applet = open(agent)
    local base = require("neoagent.ui.renderers").codex
    local renderer = util.shallow_copy(base)
    local renders = 0
    function renderer:render_block(...)
      renders = renders + 1
      return base.render_block(self, ...)
    end
    assert(applet:set_renderer(renderer))
    local view = applet:view()
    assert(view)
    assert(agent:navigate_transcript("previous"))
    assert.matches("middle request", text(view))
    assert(agent:navigate_transcript("latest"))
    assert.matches("latest request", text(view))
    local before = view.transcript.pane:_stats()
    renders = 0
    assert(agent:navigate_transcript("previous"))
    assert.matches("middle request", text(view))
    local after = view.transcript.pane:_stats()
    assert.are.equal(0, renders, "returning to a committed segment rebuilt its cards")
    assert.is_true(after.region_compilations - before.region_compilations <= 1,
      "returning to a committed segment recompiled its content regions")
    applet:destroy()
  end)

  it("evicts older rendered segments after two more recent inactive segments", function()
    local session = assert(require("neoagent.session").new())
    for index = 1, 5 do
      if index > 1 then
        assert(session:append_compaction({ summary = "checkpoint " .. index, tokens_before = 10 }))
      end
      assert(session:append({ role = "user", content = "segment " .. index }))
    end
    local agent = agent_for(session)
    local applet = open(agent)
    local base = require("neoagent.ui.renderers").codex
    local renderer = util.shallow_copy(base)
    local renders = 0
    function renderer:render_block(...)
      renders = renders + 1
      return base.render_block(self, ...)
    end
    assert(applet:set_renderer(renderer))
    local view = applet:view()
    assert(view)
    for _, direction in ipairs({ "first", "next", "next" }) do
      assert(agent:navigate_transcript(direction))
      text(view)
    end
    renders = 0
    assert(agent:navigate_transcript("previous"))
    assert.matches("segment 2", text(view))
    assert.are.equal(0, renders)
    for _, direction in ipairs({ "next", "latest" }) do
      assert(agent:navigate_transcript(direction))
      text(view)
    end
    renders = 0
    assert(agent:navigate_transcript("first"))
    assert.matches("segment 1", text(view))
    assert.is_true(renders > 0, "a segment outside the retention bound remained cached")
    applet:destroy()
  end)

  it("invalidates current and inactive tool presentations after accepting a replacement Toolset", function()
    local session = assert(require("neoagent.session").new())
    local function tool_messages(id)
      assert(session:append({ role = "assistant", content = { {
        type = "toolCall", id = id, name = "inspect", arguments = {},
      } } }))
      assert(session:append({
        role = "toolResult", toolCallId = id, toolName = "inspect", content = {},
      }))
    end
    tool_messages("first")
    assert(session:append_compaction({ summary = "checkpoint", tokens_before = 10 }))
    tool_messages("latest")
    local agent = agent_for(session)
    local function toolset(label)
      return { tools = { {
        name = "inspect", description = "Inspect synthetic data",
        input_schema = { type = "object", properties = {} },
        execute = function()
          return { content = {} }
        end,
        render = function()
          return { kind = "text", lines = { label } }
        end,
      } } }
    end
    assert(agent:set_toolset(toolset("initial renderer")))
    local applet, view = open(agent)
    assert.matches("initial renderer", text(view))
    assert(agent:navigate_transcript("previous"))
    assert.matches("initial renderer", text(view))
    assert(agent:navigate_transcript("latest"))
    assert.matches("initial renderer", text(view))
    assert(agent:set_toolset(toolset("replacement renderer")))
    assert.matches("replacement renderer", text(view))
    assert.is_nil((text(view):find("initial renderer", 1, true)))
    assert(agent:navigate_transcript("previous"))
    assert.matches("replacement renderer", text(view))
    assert.is_nil((text(view):find("initial renderer", 1, true)))
    applet:destroy()
  end)

  it("navigates local and native segments without moving the branch or changing context", function()
    for _, native in ipairs({ false, true }) do
      local session, ids = conversation(native)
      local agent = agent_for(session, nil, native)
      local context, journal, leaf = session:context_messages(), session:entries(), session:leaf_id()
      local latest = agent:snapshot()
      assert.are.equal(ids.latest, latest.history.id)
      assert.are.equal(2, #latest.messages)
      assert.are.equal(native and "compactionCheckpoint" or "compactionSummary", assert(latest.messages[1]).role)
      assert.is_nil((vim.json.encode(latest):find("synthetic-secret-checkpoint", 1, true)))
      assert.is_false((agent:navigate_transcript("next")))
      assert.is_false((agent:navigate_transcript("latest")))
      assert(agent:navigate_transcript("first"))
      assert.are.equal(ids.first, agent:snapshot().history.id)
      assert.is_false((agent:navigate_transcript("first")))
      assert(agent:navigate_transcript("latest"))
      assert(agent:navigate_transcript("previous"))
      assert.are.equal(ids.middle, agent:snapshot().history.id)
      assert(agent:navigate_transcript("previous"))
      local first = agent:snapshot()
      assert.are.equal(ids.first, first.history.id)
      assert.are.equal(2, #first.messages)
      assert.are.equal("original complete request", util.text_content(assert(first.messages[1]).content))
      assert.is_false((agent:navigate_transcript("previous")))
      assert(agent:navigate_transcript("next"))
      assert(agent:navigate_transcript("latest"))
      assert.are.same(latest.messages, agent:snapshot().messages)
      assert.are.equal(leaf, session:leaf_id())
      assert.are.same(context, session:context_messages())
      assert.are.same(journal, session:entries())
      assert(agent:navigate_transcript("previous"))
      assert(agent:branch(ids.first))
      assert.is_true(agent:snapshot().history.latest)
      assert.are.equal(1, agent:snapshot().history.total)
      assert.is_false((agent:navigate_transcript("first")))
    end
  end)

  it("navigates through the history menu without changing the composer", function()
    local session, ids = conversation()
    local agent = agent_for(session)
    local applet, view = open(agent)
    view:set_input("keep this draft")
    assert(view:focus_transcript())
    local buffer = assert(view_handles.buffer(view, "transcript"))
    local window = assert(view_handles.window(view, "transcript"))
    ---@param label string
    local function choose(label)
      assert(view.transcript.pane:flush())
      local header = assert(vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1])
      local column = assert((header:find("[" .. label .. "]", 1, true)))
      vim.api.nvim_win_set_cursor(window, { 1, column - 1 })
      feed("<CR>")
    end
    assert.matches("latest request", text(view))
    assert.matches("%[First%].*%[Previous%].*%[Next%].*%[Latest%]", text(view))
    choose("First")
    assert.are.equal(ids.first, agent:snapshot().history.id)
    choose("First")
    assert.are.equal(ids.first, agent:snapshot().history.id)
    choose("Latest")
    assert.are.equal(ids.latest, agent:snapshot().history.id)
    choose("Previous")
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    assert.matches("middle request", text(view))
    assert.is_nil((text(view):find("latest request", 1, true)))
    choose("Previous")
    assert.are.equal(ids.first, agent:snapshot().history.id)
    choose("Next")
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    choose("Latest")
    assert.are.equal(ids.latest, agent:snapshot().history.id)
    assert.are.equal("keep this draft", view:get_input())
    assert.are.equal(view_handles.window(view, "transcript"), vim.api.nvim_get_current_win())
    choose("Previous")
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    applet:close()
    assert(applet:open())
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    assert.are.equal(buffer, view_handles.buffer(view, "transcript"))
    local renderers = require("neoagent.ui.renderers")
    local renderer = view.renderer == renderers.pi and renderers.codex or renderers.pi
    assert(applet:set_renderer(renderer))
    assert.are.equal(renderer, view.renderer)
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    assert.are.equal("keep this draft", view:get_input())
  end)

  for _, historical in ipairs({ false, true }) do
    it("attaches during streaming without a Store leaf ID with historical=" .. tostring(historical), function()
      local stored = conversation()
      ---@type Neoagent.SessionStorage
      local store = {
        load = function()
          return stored:messages()
        end,
        append = function(_, message, state)
          local accepted, err, entry = stored:append(message, state)
          return accepted, err, entry, { type = "append", messages = { util.copy(message) } }
        end,
        path = function()
          return stored:path()
        end,
        context_messages = function()
          return stored:context_messages()
        end,
      }
      local session = assert(require("neoagent.session").new({ store = store }))
      local model = fake_model.new({})
      ---@type (fun())?
      local complete
      ---@type Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>?
      local streaming
      function model:stream(opts)
        streaming = async.run(function(run)
          run:emit({ type = "text_delta", index = 0, text = "visible response" })
          async.await(function(done)
            complete = function()
              done.resolve(true)
            end
            return function() end
          end)
          return fake_model.assistant({ { type = "text", index = 0, text = "visible response continuation" } })
        end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
        return streaming
      end
      local agent = agent_for(session, model)
      if historical then
        assert(agent:navigate_transcript("previous"))
      end
      local deltas = 0
      local unsubscribe = agent:subscribe(function(update)
        local event = update.type == "event" and update.event or nil
        if event and event.type == "text_delta" then
          deltas = deltas + 1
        end
      end)
      local run = agent:send("continue")
      assert(run)
      assert(type(run) == "table")
      assert(vim.wait(1000, function()
        return complete ~= nil and deltas == 1
      end))
      local _, view = open(agent)
      assert.matches("visible response", text(view))
      assert(streaming):emit({ type = "text_delta", index = 0, text = " continuation" })
      assert(vim.wait(1000, function()
        return deltas == 2
      end))
      assert.matches("visible response continuation", text(view))
      assert(complete)()
      assert(vim.wait(1000, function()
        return run:is_done() and not agent:is_running()
      end))
      unsubscribe()
      assert.is_true(assert(run:result()).ok)
      assert.are.equal(1, select(2, text(view):gsub("visible response", "")))
      assert.are.same(agent:snapshot().messages, view.messages)
    end)
  end

  it("freezes historical output and restores the unfinished response on returning to Latest", function()
    local session = conversation()
    local model = fake_model.new({})
    ---@type Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>?
    local streaming
    ---@type (fun())?
    local resume
    function model:stream(opts)
      self.requests[#self.requests + 1] = require("neoagent.api.request_preparation").copy(opts)
      streaming = async.run(function(run)
        run:emit({ type = "text_delta", index = 0, text = "unfinished" })
        async.await(function(done)
          resume = function()
            done.resolve(true)
          end
          return function() end
        end)
        return fake_model.assistant({ { type = "text", index = 0, text = "unfinished continuation" } })
      end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
      return streaming
    end
    local agent = agent_for(session, model)
    local _, view = open(agent)
    local events = 0
    local unsubscribe = agent:subscribe(function(update)
      if update.type == "event" then
        events = events + 1
      end
    end)
    local run = agent:send("continue at the tip")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return resume ~= nil
    end))
    assert.matches("unfinished", text(view))
    assert(agent:navigate_transcript("previous"))
    local historical = text(view)
    local previous_events = events
    assert(streaming):emit({ type = "text_delta", index = 0, text = " continuation" })
    assert(vim.wait(1000, function()
      return events > previous_events
    end))
    assert.are.equal(historical, text(view))
    assert.are.same({}, agent:snapshot().events)
    assert.are.equal("running", view.context.state)
    assert(agent:navigate_transcript("latest"))
    local current = text(view)
    assert.matches("unfinished continuation", current)
    assert.are.equal(1, select(2, current:gsub("unfinished", "")))
    assert(agent:navigate_transcript("previous"))
    assert(agent:steer("queued follow-up"))
    assert.is_true(agent:snapshot().history.latest)
    assert.matches("unfinished continuation", text(view))
    local queued = agent:dequeue_steering()
    assert.are.same({ "queued follow-up" }, queued)
    assert(agent:navigate_transcript("previous"))
    local frozen = text(view)
    local dialog = agent:dialogs():show({
      placement = "float",
      title = "Still available",
      body = "History is open",
      actions = { { id = "done", label = "Done", key = "d" } },
    })
    assert.are.equal("Still available", assert(view.dialog).active.title)
    assert(agent:dialogs():choose(assert(view.dialog).active.id, "done"))
    assert(vim.wait(1000, function()
      return dialog:is_done()
    end))
    assert(resume)()
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(frozen, text(view))
    assert(agent:navigate_transcript("latest"))
    assert.are.equal(1, select(2, text(view):gsub("unfinished", "")))
    unsubscribe()
  end)

  it("restores retry output after browsing history while a failed response is abandoned", function()
    local session = conversation()
    local model = fake_model.new({})
    local calls, deltas = 0, 0
    ---@type (fun())?
    local complete_first
    ---@type (fun())?
    local complete_second
    function model:stream(opts)
      calls = calls + 1
      local first = calls == 1
      return async.run(function(run)
        run:emit({ type = "text_delta", index = 0, text = first and "failed partial" or "recovered output" })
        async.await(function(done)
          if first then
            complete_first = function()
              done.resolve(true)
            end
          else
            complete_second = function()
              done.resolve(true)
            end
          end
          return function() end
        end)
        if first then
          local failed = fake_model.assistant({ { type = "text", index = 0, text = "failed partial" } }, "error")
          return {
            ok = false,
            message = failed.message,
            error = { kind = "transport", message = "connection reset", retryable = true, retry_after_ms = 1 },
          }
        end
        return fake_model.assistant({ { type = "text", index = 0, text = "recovered output complete" } })
      end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
    end
    local agent = agent_for(session, model)
    local _, view = open(agent)
    local unsubscribe = agent:subscribe(function(update)
      local event = update.type == "event" and update.event or nil
      if event and event.type == "text_delta" then
        deltas = deltas + 1
      end
    end)
    local run = agent:send("continue")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return complete_first ~= nil and deltas == 1
    end))
    assert(agent:navigate_transcript("previous"))
    local historical = text(view)
    assert(complete_first)()
    assert(vim.wait(1000, function()
      return complete_second ~= nil and deltas == 2
    end))
    assert.are.equal(2, calls)
    assert.are.equal(historical, text(view))
    assert(agent:navigate_transcript("latest"))
    assert.matches("recovered output", text(view))
    assert.is_nil((text(view):find("failed partial", 1, true)))
    assert(complete_second)()
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    unsubscribe()
    assert.is_true(assert(run:result()).ok)
    assert.matches("recovered output complete", text(view))
    assert.are.equal(1, select(2, text(view):gsub("recovered output", "")))
    assert.are.same(agent:snapshot().messages, view.messages)
  end)

  for _, streamed in ipairs({ false, true }) do
    it("returns to Latest between response commit and event delivery with streaming=" .. tostring(streamed), function()
      local session = conversation()
      local model = fake_model.new({})
      ---@type (fun())?
      local resume
      function model:stream(opts)
        return async.run(function(run)
          if streamed then
            run:emit({ type = "text_delta", index = 0, text = "completed response" })
          end
          async.await(function(done)
            resume = function()
              done.resolve(true)
            end
            return function() end
          end)
          return fake_model.assistant({ { type = "text", index = 0, text = "completed response" } })
        end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
      end
      local agent = agent_for(session, model)
      local applet, view = open(agent)
      local run = agent:send("continue")
      assert(run)
      assert(type(run) == "table")
      assert(vim.wait(1000, function()
        return resume ~= nil and (not streamed or #agent:snapshot().events > 0)
      end))
      assert(agent:navigate_transcript("previous"))
      local append = session.append
      local navigated, navigation_error
      ---@type string?
      local returned
      function session:append(message, state)
        local accepted, err, entry = append(self, message, state)
        if accepted and type(message) == "table" and message.role == "assistant" then
          vim.schedule(function()
            navigated, navigation_error = agent:navigate_transcript("latest")
            if streamed then
              view:destroy()
              assert(applet:open())
              view = assert(applet:view())
            end
            returned = text(view)
          end)
        end
        return accepted, err, entry
      end
      assert(resume)()
      local completed = vim.wait(1000, function()
        return run:is_done() and not agent:is_running()
      end)
      session.append = append
      assert(completed)
      assert(navigated, vim.inspect(navigation_error))
      assert.is_true(assert(run:result()).ok)
      assert(returned)
      assert.are.equal(1, select(2, returned:gsub("completed response", "")))
      assert.are.equal(1, select(2, text(view):gsub("completed response", "")))
      assert.are.same(agent:snapshot().messages, view.messages)
    end)
  end

  it("restores active Tools and later output when Store append omits journal receipts", function()
    local session = without_receipts(conversation())
    local model = fake_model.new({})
    local calls = 0
    ---@type (fun())?
    local complete_tool
    ---@type (fun())?
    local complete_response
    function model:stream(opts)
      calls = calls + 1
      local first = calls == 1
      return async.run(function(run)
        if first then
          return fake_model.assistant({
            { type = "toolCall", id = "inspect", name = "inspect", arguments = {} },
          }, "toolUse")
        end
        run:emit({ type = "text_delta", index = 0, text = "later output" })
        async.await(function(done)
          complete_response = function()
            done.resolve(true)
          end
          return function() end
        end)
        return fake_model.assistant({ { type = "text", index = 0, text = "later output" } })
      end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
    end
    local agent = agent_for(session, model)
    local toolset = agent:get_toolset()
    toolset.tools = {
      {
        name = "inspect",
        description = "Inspect synthetic data",
        input_schema = { type = "object", properties = {} },
        execute = function()
          async.await(function(done)
            complete_tool = function()
              done.resolve(true)
            end
            return function() end
          end)
          return { content = { { type = "text", text = "completed Tool result" } } }
        end,
      },
    }
    assert(agent:set_toolset(toolset))
    local applet, view = open(agent)
    local tool_starts, tool_ends, deltas = 0, 0, 0
    local unsubscribe = agent:subscribe(function(update)
      local event = update.type == "event" and update.event or nil
      if event then
        if event.type == "tool_start" then
          tool_starts = tool_starts + 1
        elseif event.type == "tool_end" then
          tool_ends = tool_ends + 1
        elseif event.type == "text_delta" then
          deltas = deltas + 1
        end
      end
    end)
    local run = agent:send("inspect")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return complete_tool ~= nil and tool_starts == 1
    end))
    assert.are.equal("running", assert(view.blocks[#view.blocks]).state)
    assert(agent:navigate_transcript("previous"))
    assert(agent:navigate_transcript("latest"))
    assert.are.equal("running", assert(view.blocks[#view.blocks]).state)
    view:destroy()
    assert(applet:open())
    view = assert(applet:view())
    assert.are.equal("running", assert(view.blocks[#view.blocks]).state)
    assert(complete_tool)()
    assert(vim.wait(1000, function()
      return complete_response ~= nil and tool_ends == 1 and deltas == 1
    end))
    assert.matches("completed Tool result", text(view))
    assert.matches("later output", text(view))
    assert(complete_response)()
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    unsubscribe()
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(1, select(2, text(view):gsub("later output", "")))
    assert.are.equal(#agent:snapshot().messages, #view.messages)
    assert.are.equal("toolResult", assert(view.messages[#view.messages - 1]).role)
    assert.are.equal("assistant", assert(view.messages[#view.messages]).role)
  end)

  it("skips multiple queued message endings without journal receipts when returning to Latest", function()
    local session = without_receipts(conversation())
    local model = fake_model.new({})
    local calls = 0
    ---@type (fun())?
    local complete_first
    function model:stream(opts)
      calls = calls + 1
      local first = calls == 1
      return async.run(function()
        if first then
          async.await(function(done)
            complete_first = function()
              done.resolve(true)
            end
            return function() end
          end)
          return fake_model.assistant({
            { type = "toolCall", id = "inspect", name = "inspect", arguments = {} },
          }, "toolUse")
        end
        return fake_model.assistant({ { type = "text", text = "completed response" } })
      end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
    end
    local agent = agent_for(session, model)
    local toolset = agent:get_toolset()
    toolset.tools = {
      {
        name = "inspect",
        description = "Inspect synthetic data",
        input_schema = { type = "object", properties = {} },
        execute = function()
          return { content = { { type = "text", text = "completed Tool result" } } }
        end,
      },
    }
    assert(agent:set_toolset(toolset))
    local applet, view = open(agent)
    local append = session.append
    local navigated, navigation_error
    local queued
    ---@type string?
    local returned
    function session:append(message, state)
      local accepted, err, entry = append(self, message, state)
      if accepted and type(message) == "table" and message.role == "assistant" and message.stopReason == "toolUse" then
        vim.schedule(function()
          navigated, navigation_error = agent:navigate_transcript("latest")
          queued = agent:snapshot().pending_message_ends
          view:destroy()
          assert(applet:open())
          view = assert(applet:view())
          returned = text(view)
        end)
      end
      return accepted, err, entry
    end
    local run = agent:send("inspect")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return complete_first ~= nil
    end))
    assert(agent:navigate_transcript("previous"))
    assert(complete_first)()
    local completed = vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end)
    session.append = append
    assert(completed)
    assert(navigated, vim.inspect(navigation_error))
    assert.are.equal(2, queued)
    assert.is_true(assert(run:result()).ok)
    assert(returned)
    assert.are.equal(1, select(2, returned:gsub("completed Tool result", "")))
    assert.are.equal(1, select(2, text(view):gsub("completed response", "")))
    assert.matches("completed Tool result", text(view))
    assert.are.equal(#agent:snapshot().messages, #view.messages)
  end)

  it("restores committed Tool results before their events and resumes later streaming", function()
    local session = conversation()
    local model = fake_model.new({})
    local calls = 0
    ---@type (fun())?
    local complete_tool
    ---@type (fun())?
    local complete_response
    function model:stream(opts)
      calls = calls + 1
      local first = calls == 1
      return async.run(function(run)
        if first then
          return fake_model.assistant({
            {
              type = "toolCall",
              id = "inspect",
              name = "inspect",
              arguments = {},
            },
          }, "toolUse")
        end
        run:emit({ type = "text_delta", index = 0, text = "later output" })
        async.await(function(done)
          complete_response = function()
            done.resolve(true)
          end
          return function() end
        end)
        return fake_model.assistant({ { type = "text", index = 0, text = "later output" } })
      end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
    end
    local agent = agent_for(session, model)
    local toolset = agent:get_toolset()
    toolset.tools = {
      {
        name = "inspect",
        description = "Inspect synthetic data",
        input_schema = { type = "object", properties = {} },
        execute = function()
          async.await(function(done)
            complete_tool = function()
              done.resolve(true)
            end
            return function() end
          end)
          return { content = { { type = "text", text = "completed Tool result" } } }
        end,
      },
    }
    agent:set_toolset(toolset)
    local _, view = open(agent)
    local tool_ends, deltas = 0, 0
    local unsubscribe = agent:subscribe(function(update)
      local event = update.type == "event" and update.event or nil
      if event then
        if event.type == "tool_end" then
          tool_ends = tool_ends + 1
        elseif event.type == "text_delta" then
          deltas = deltas + 1
        end
      end
    end)
    local run = agent:send("inspect")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return complete_tool ~= nil
    end))
    assert(agent:navigate_transcript("previous"))
    local append = session.append
    local navigated, navigation_error
    function session:append(message, state)
      local accepted, err, entry = append(self, message, state)
      if accepted and type(message) == "table" and message.role == "toolResult" then
        vim.schedule(function()
          navigated, navigation_error = agent:navigate_transcript("latest")
        end)
      end
      return accepted, err, entry
    end
    assert(complete_tool)()
    local resumed = vim.wait(1000, function()
      return complete_response ~= nil and deltas == 1 and tool_ends == 1
    end)
    session.append = append
    assert(resumed)
    assert(navigated, vim.inspect(navigation_error))
    assert.matches("completed Tool result", text(view))
    assert.matches("later output", text(view))
    assert.are.same(agent:snapshot().messages, view.messages)
    assert(complete_response)()
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    unsubscribe()
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(1, select(2, text(view):gsub("later output", "")))
    assert.are.same(agent:snapshot().messages, view.messages)
  end)

  it("preserves Tool-card identity and observer history when provider call IDs are reused", function()
    local session = assert(require("neoagent.session").new())
    local function exchange(label)
      local _, _, call = session:append({
        role = "assistant",
        content = {
          { type = "toolCall", id = "reused", name = "inspect", arguments = {} },
        },
      })
      assert(call)
      assert(session:append({
        role = "toolResult",
        toolName = "inspect",
        toolCallId = "reused",
        content = { { type = "text", text = label } },
      }))
      return call.id
    end
    local first = exchange("earlier result")
    assert(session:append_compaction({ summary = "summary", tokens_before = 10 }))
    local latest = exchange("latest result")
    local agent = agent_for(session)
    local observed = {}
    local toolset = agent:get_toolset()
    toolset.tools = {
      {
        name = "inspect",
        description = "Inspect synthetic data",
        input_schema = { type = "object", properties = {} },
        execute = function()
          return { content = {} }
        end,
        on_messages = function(messages)
          observed[#observed + 1] = messages
        end,
      },
    }
    agent:set_toolset(toolset)
    local _, view = open(agent)
    local latest_key = "message:" .. latest .. ":tool:1"
    assert.are.equal(latest_key, assert(view.blocks[2]).key)
    assert(agent:navigate_transcript("previous"))
    assert.matches("earlier result", text(view))
    assert.are.equal("message:" .. first .. ":tool:1", assert(view.blocks[1]).key)
    assert(agent:navigate_transcript("latest"))
    assert.are.equal(latest_key, assert(view.blocks[2]).key)
    assert.matches("latest result", text(view))
    assert.are.equal(1, #observed)
    assert.are.same(session:messages(), observed[1])
  end)

  it("preserves accepted history when navigation projection fails and rejects destroyed Agents", function()
    local session, ids = conversation()
    local agent = agent_for(session)
    assert(agent:navigate_transcript("previous"))
    local _, view = open(agent)
    local before, leaf = text(view), session:leaf_id()
    local projection = session.transcript_entries
    function session:transcript_entries(segment_id, direction)
      if direction == "previous" then
        return nil, util.error("storage", "history unavailable")
      end
      return projection(self, segment_id, direction)
    end
    local changed, err = agent:navigate_transcript("previous")
    assert.is_nil(changed)
    assert.are.equal("history unavailable", assert(err).message)
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    assert.are.equal(before, text(view))
    assert.are.equal(leaf, session:leaf_id())
    session.transcript_entries = function()
      return nil, util.error("storage", "source unavailable")
    end
    changed, err = agent:navigate_transcript("latest")
    assert.is_nil(changed)
    assert.are.equal("source unavailable", assert(err).message)
    session.transcript_entries = projection
    agent:destroy()
    changed, err = agent:navigate_transcript("previous")
    assert.is_nil(changed)
    assert.are.equal("Agent is destroyed", assert(err).message)
  end)

  it("returns accepted submissions to Latest and preserves selection on rejection", function()
    local session, ids = conversation()
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "new answer" } }) } })
    local agent = agent_for(session, model)
    local _, view = open(agent)
    assert(agent:navigate_transcript("previous"))
    view:set_input("draft")
    assert.is_nil((agent:send("")))
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    assert.are.equal("draft", view:get_input())
    local run = agent:send("new request")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done()
    end))
    assert.is_true(assert(run:result()).ok)
    assert.is_true(agent:snapshot().history.latest)
    assert.are.equal(ids.latest, agent:snapshot().history.id)
    assert.matches("new answer", text(view))
  end)

  it("preserves steering acceptance when returning to Latest fails", function()
    local session, ids = conversation()
    local model = fake_model.new({})
    local calls = 0
    ---@type (fun())?
    local resume
    function model:stream(opts)
      calls = calls + 1
      local first = calls == 1
      return async.run(function(run)
        run:emit({ type = "text_delta", index = 0, text = "response" })
        if first then
          async.await(function(done)
            resume = function()
              done.resolve(true)
            end
            return function() end
          end)
        end
        return fake_model.assistant({ { type = "text", index = 0, text = "response" } })
      end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
    end
    local agent = agent_for(session, model)
    local applet, view = open(agent)
    local run = agent:send("continue")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return resume ~= nil and #agent:snapshot().events > 0
    end))
    assert(agent:navigate_transcript("previous"))
    local historical = text(view)
    local prompt = "queued follow-up"
    view:set_input(prompt)
    local projection, notify = session.transcript_entries, view.notify
    ---@type {message: string, level?: integer}[]
    local notifications = {}
    function session:transcript_entries(segment_id, direction)
      if segment_id == nil then
        return nil, util.error("storage", "latest projection unavailable")
      end
      return projection(self, segment_id, direction)
    end
    function view:notify(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local submitted, accepted, err = pcall(applet.send, applet, prompt)
    session.transcript_entries, view.notify = projection, notify
    assert(submitted, vim.inspect(accepted))
    assert.is_true(accepted)
    assert.is_nil(err)
    assert.are.equal("", view:get_input())
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    assert.are.equal(historical, text(view))
    assert.are.same({ prompt }, agent:snapshot().context.steering)
    assert.are.equal(1, #notifications)
    assert.matches("latest projection unavailable", assert(notifications[1]).message)
    assert.are.equal(vim.log.levels.ERROR, assert(notifications[1]).level)
    assert.is_nil((applet:send(view:get_input())))
    assert.are.same({ prompt }, agent:snapshot().context.steering)
    assert(resume)()
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(2, calls)
    assert.are.same({ prompt }, applet:input_history())
    local committed = vim.tbl_filter(function(message)
      return message.role == "user" and message.content == prompt
    end, session:messages())
    assert.are.equal(1, #committed)
  end)

  it("stays pinned during compaction and advances when following the latest segment", function()
    local session, ids = conversation()
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "first new summary" } }) },
      { result = fake_model.assistant({ { type = "text", text = "second new summary" } }) },
    })
    local agent = agent_for(session, model)
    local _, view = open(agent)
    assert(agent:navigate_transcript("previous"))
    local historical = text(view)
    local run = agent:compact()
    assert(run)
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(ids.middle, agent:snapshot().history.id)
    assert.are.equal(4, agent:snapshot().history.total)
    assert.are.equal(historical, text(view))
    assert(agent:navigate_transcript("latest"))
    assert.matches("first new summary", text(view))
    local previous = agent:snapshot().history.id
    assert(session:append({ role = "user", content = "more work" }))
    run = agent:compact()
    assert(run)
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.is_true(assert(run:result()).ok)
    assert.are_not.equal(previous, agent:snapshot().history.id)
    assert.is_true(agent:snapshot().history.latest)
    assert.are.equal(5, agent:snapshot().history.total)
    assert.matches("second new summary", text(view))
  end)

  it("avoids excluded body copies in Agent snapshots and navigation, including context display", function()
    local session, ids = conversation()
    local agent = agent_for(session)
    assert(session:append_compaction({ summary = "small current context", tokens_before = 100 }))
    assert(session:append({ role = "user", content = "new tip" }))
    local excluded = assert(assert(session._by_id[ids.first]).message).content
    util.copy = function(value, seen)
      assert.are_not.equal(excluded, value, "Agent copied an excluded historical message body")
      return copy(value, seen)
    end
    local current = agent:snapshot()
    assert.are.equal(2, #current.messages)
    assert.is_table(current.context.context_usage)
    assert(agent:navigate_transcript("previous"))
    assert.are.equal(ids.latest, agent:snapshot().history.id)
    assert(agent:navigate_transcript("latest"))
    util.copy = copy
    assert(agent:navigate_transcript("previous"))
    assert(agent:navigate_transcript("previous"))
    assert(agent:navigate_transcript("previous"))
    assert.are.equal(ids.first, agent:snapshot().history.id)
    util.copy = function(value, seen)
      if value == excluded then
        error("Navigation copied the segment being left", 0)
      end
      return copy(value, seen)
    end
    local advanced, err = agent:navigate_transcript("next")
    assert(advanced, vim.inspect(err))
    assert(agent:navigate_transcript("latest"))
  end)
end)
