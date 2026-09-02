local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")
local view_handles = require("tests.helpers.view_handles")

describe("neoagent direct Agent Applets", function()
  local neoagent
  local agents
  local applets
  local paths

  before_each(function()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
    agents, applets, paths = {}, {}, {}
  end)

  after_each(function()
    for _, applet in ipairs(applets) do applet:destroy() end
    for _, agent in ipairs(agents) do agent:destroy() end
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
  end)

  local function options(name, model, extra)
    local result = {
      name = name,
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = name },
      providers = { fake = { api = "fake", models = { [name] = {} } } },
      _apis = { fake = function(resolved)
        model.api = model.api or resolved.api
        model.provider = model.provider or resolved.provider_id
        model.id = model.id or resolved.model_id
        model.input = model.input or resolved.model.input or { "text" }
        return model
      end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    }
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
  end

  local function make(name, model, extra, runtime)
    local agent = neoagent.new(options(name, model, extra), runtime)
    agents[#agents + 1] = agent
    return agent
  end

  local function window(values, opts)
    opts = opts or {}
    opts.agents = values
    local applet = neoagent._new_applet(opts)
    applets[#applets + 1] = applet
    return applet
  end

  local function feed(keys)
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  local function submit(view, value)
    view:set_input(value)
    view:focus_input()
    local mapping = view.config.mappings.submit
    feed(type(mapping) == "table" and mapping[1] or mapping)
  end

  local function transcript(view)
    return table.concat(vim.api.nvim_buf_get_lines(
      view_handles.buffer(view, "transcript"), 0, -1, false), "\n")
  end

  it("uses opaque identity and one retained Applet per Agent", function()
    local first = make("same", fake_model.new({}))
    local second = make("same", fake_model.new({}))
    local owner = window({ first, second })

    assert.are_not.equal(first:id(), second:id())
    assert.are.equal("same", first:label())
    assert.are.equal("same", second:label())
    assert.are_not.equal(first:applet(), second:applet())
    assert(owner:open())

    local first_applet = first:applet()
    local first_view = owner:view()
    first_view:set_input("first draft")
    assert.are.equal(second, owner:select(second:id()))
    local second_view = owner:view()
    assert.are_not.equal(first_view, second_view)
    assert.is_false(first_applet:is_open())
    assert.is_true(second:applet():is_open())
    assert.are.equal("", second_view:get_input())

    second_view:set_input("second draft")
    assert.are.equal(first, owner:select(first:id()))
    assert.are.equal(first_view, owner:view())
    assert.are.equal("first draft", owner:get_input())
    assert.are.equal(second, owner:select(second:id()))
    assert.are.equal("second draft", owner:get_input())
  end)

  it("restores the foreground Applet when selection preparation fails", function()
    local first = make("first", fake_model.new({}))
    local broken = make("broken", fake_model.new({}), {
      default_model = { provider = "absent", model = "missing" },
    })
    local owner = window({ first, broken })
    assert(owner:open())
    local first_view = owner:view()
    first_view:set_input("retained")

    local selected, err = owner:select(broken)

    assert.is_nil(selected)
    assert.are.equal("model", err.kind)
    assert.are.equal(first, owner:active_agent())
    assert.is_true(first:applet():is_open())
    assert.is_false(broken:applet():is_open())
    assert.are.equal(first_view, owner:view())
    assert.are.equal("retained", first_view:get_input())
  end)

  it("drives an injected View through the Agent Applet", function()
    local created
    local function view_factory(opts)
      local view = {
        input = "",
        messages = {},
        message_updates = 0,
        context = {},
        events = {},
        opened = false,
        on_submit = opts.on_submit,
      }
      function view:open() self.opened = true return true end
      function view:close() self.opened = false end
      function view:is_open() return self.opened end
      function view:destroy() self:close() self.destroyed = true end
      function view:get_input() return self.input end
      function view:set_input(value) self.input = value return value end
      function view:set_messages(value)
        self.messages = value
        self.message_updates = self.message_updates + 1
      end
      function view:set_context(value) self.context = value end
      function view:apply(value) self.events[#self.events + 1] = value end
      function view:finish(value) self.result = value end
      function view:focus_input() return self.opened end
      created = view
      return view
    end
    local model = fake_model.new({ {
      events = { { type = "text_delta", text = "custom" } },
      result = fake_model.assistant({ { type = "text", text = "custom" } }),
    } })
    local agent = make("custom", model, { _view = view_factory })
    local owner = window({ agent })

    assert(owner:open())
    assert.are.equal(agent:applet(), owner:foreground_applet())
    local renderer, renderer_err = owner:set_renderer(
      require("neoagent.ui.renderers").pi)
    assert.is_nil(renderer)
    assert.matches("does not support Renderers", renderer_err.message)

    local run = assert(created.on_submit("question"))
    assert(vim.wait(1000, function() return run:is_done() and created.result end))
    assert.are.equal("question", created.messages[1].content)
    assert.are.equal("text_delta", created.events[1].type)
    assert.is_true(created.result.ok)

    local message_updates = created.message_updates
    local event_updates = #created.events
    owner:close()
    assert(owner:open())
    assert.are.equal(message_updates, created.message_updates)
    assert.are.equal(event_updates, #created.events)
  end)

  it("keeps background streaming bound to its own retained View", function()
    local pending = {}
    local function delayed(name)
      local model = { api = "fake", provider = "fake", id = name }
      function model:stream(opts)
        return async.run(function(run)
          run:emit({ type = "text_delta", text = name .. " partial" })
          local reply = async.await(function(done)
            pending[name] = done
            return function() end
          end)
          return fake_model.assistant({ { type = "text", text = reply } })
        end, {
          on_event = opts.on_event,
          on_done = opts.on_done,
          error_kind = "model",
        })
      end
      return model
    end
    local first = make("first", delayed("first"))
    local second = make("second", delayed("second"))
    local owner = window({ first, second })
    assert(owner:open())
    local first_view = owner:view()
    submit(first_view, "for first")
    assert(vim.wait(1000, function() return pending.first ~= nil end))

    assert.are.equal(second, owner:select(second))
    local second_view = owner:view()
    submit(second_view, "for second")
    assert(vim.wait(1000, function() return pending.second ~= nil end))
    assert.is_true(first:is_running())
    assert.is_true(second:is_running())

    pending.first.resolve("first reply")
    assert(vim.wait(1000, function() return not first:is_running() end))
    assert.is_nil(transcript(second_view):find("first reply", 1, true))
    assert.are.equal(first, owner:select(first))
    assert(vim.wait(1000, function()
      return transcript(first_view):find("first reply", 1, true) ~= nil
    end))

    pending.second.resolve("second reply")
    assert(vim.wait(1000, function() return not second:is_running() end))
    assert.are.equal("for first", first:get_session():messages()[1].content)
    assert.are.equal("for second", second:get_session():messages()[1].content)
  end)

  it("keeps one explicit Provider Shell open across Agent selection", function()
    local shell = { opened = false }
    function shell:open() self.opened = true return true end
    function shell:close() self.opened = false return true end
    function shell:is_open() return self.opened end
    function shell:toggle()
      if self.opened then self:close() return false end
      return self:open()
    end
    function shell:is_active() return false end
    local first = make("first", fake_model.new({}))
    local second = make("second", fake_model.new({}))
    local owner = window({ first, second }, { provider_shell = shell })
    assert(owner:open())
    assert(owner:set_provider_shell(true))
    local first_view = owner:view()
    assert.is_true(owner:provider_shell_open())

    assert.are.equal(second, owner:select(second))
    local second_view = owner:view()
    assert.are_not.equal(first_view, second_view)
    assert.is_true(owner:provider_shell_open())
    assert.is_false(first:applet():is_open())

    assert.are.equal(first, owner:select(first))
    assert.are.equal(first_view, owner:view())
    assert.is_true(owner:provider_shell_open())
  end)

  it("does not infer a Provider Shell from an Agent's model services", function()
    local service = {
      id = "fake",
      name = "Fake",
      operations = {},
      state = function() return false end,
    }
    local first = make("first", fake_model.new({}), nil, {
      providers = { fake = service },
    })
    local second = make("second", fake_model.new({}))
    local owner = window({ first, second })
    assert(owner:open())

    local opened, err = owner:set_provider_shell(true)
    assert.is_nil(opened)
    assert.matches("no Provider Shell", err.message)
    assert.is_false(owner:provider_shell_open())
  end)

  it("retains focus, scrolling, and dialogs in their Agent Applet", function()
    local lines = {}
    for index = 1, 40 do lines[index] = "line " .. index end
    local first = make("first", fake_model.new({ {
      result = fake_model.assistant({ {
        type = "text", text = table.concat(lines, "\n"),
      } }),
    } }), { ui = { position = "center", card_max_lines = 100 } })
    local second = make("second", fake_model.new({}))
    local owner = window({ first, second })
    assert(owner:open())
    local first_view = owner:view()
    submit(first_view, "fill transcript")
    assert(vim.wait(1000, function()
      return not first:is_running()
        and vim.api.nvim_buf_line_count(view_handles.buffer(first_view, "transcript")) >= 30
    end))
    vim.api.nvim_win_call(view_handles.window(first_view, "transcript"), function()
      vim.fn.winrestview({ lnum = 24, col = 0, topline = 18, leftcol = 0 })
    end)
    local before = vim.api.nvim_win_call(
      view_handles.window(first_view, "transcript"), function() return vim.fn.winsaveview() end)
    local dialog = first:dialogs():show({
      placement = "float",
      title = "First Agent decision",
      body = "Keep this request with the first Agent.",
      actions = {
        { id = "continue", label = "continue", key = "<CR>" },
        { id = "cancel", label = "cancel", key = "<C-c>" },
      },
    })
    assert(vim.wait(1000, function()
      return first:dialogs():snapshot().active ~= nil
    end))
    assert(vim.wait(1000, function() return first_view.dialog ~= nil end))
    assert(vim.wait(1000, function()
      return view_handles.window(first_view, "dialog")
        and vim.api.nvim_win_is_valid(view_handles.window(first_view, "dialog"))
    end))

    assert.are.equal(second, owner:select(second))
    local second_view = owner:view()
    assert.are_not.equal(first_view, second_view)
    assert.is_nil(second_view.dialog)
    assert.are.equal(view_handles.window(second_view, "input"), vim.api.nvim_get_current_win())

    assert.are.equal(first, owner:select(first))
    assert(vim.wait(1000, function()
      return view_handles.window(first_view, "dialog")
        and vim.api.nvim_win_is_valid(view_handles.window(first_view, "dialog"))
        and vim.api.nvim_get_current_win() == view_handles.window(first_view, "dialog")
    end))
    local after = vim.api.nvim_win_call(
      view_handles.window(first_view, "transcript"), function() return vim.fn.winsaveview() end)
    assert.are.equal(before.lnum, after.lnum)
    assert.are.equal(before.topline, after.topline)
    local request = first:dialogs():snapshot().active
    assert(first:dialogs():choose(request.id, "continue"))
    assert(vim.wait(1000, function() return dialog:is_done() end))
  end)

  it("persists workspace history without sharing mutable View state", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local extra = { persistence = { enabled = true, directory = directory } }
    local first = make("first", fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "one" } }),
    } }), extra)
    local second = make("second", fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "two" } }),
    } }), extra)
    local owner = window({ first, second })
    assert(owner:open())
    local first_view = owner:view()
    submit(first_view, "first question")
    assert(vim.wait(1000, function()
      return first:get_session() and not first:is_running()
    end))

    assert.are.equal(second, owner:select(second))
    local second_view = owner:view()
    assert.are.same({ "first question" }, owner:input_history())
    submit(second_view, "second question")
    assert(vim.wait(1000, function()
      return second:get_session() and not second:is_running()
    end))
    assert.are.same({ "second question", "first question" },
      owner:input_history())
    assert.are.equal("", first_view:get_input())
    assert.are.equal("", second_view:get_input())

    assert.are.equal(first, owner:select(first))
    assert.are.same({ "second question", "first question" },
      owner:input_history())

    local replacement = make("replacement", fake_model.new({}), extra)
    local replacement_owner = window({ replacement })
    assert(replacement_owner:open())
    assert.are.same({ "second question", "first question" },
      replacement_owner:input_history())
  end)

  it("routes the facade through an injected top-level Applet", function()
    local first = make("first", fake_model.new({}))
    local first_owner = window({ first })
    local previous = neoagent._set_default_applet(first_owner)
    applets[#applets + 1] = previous
    assert.are.equal(first, neoagent.default())
    assert(neoagent.open())
    assert.is_true(first_owner:is_open())

    local second = make("second", fake_model.new({}))
    local second_owner = window({ second })
    assert.are.equal(first_owner, neoagent._set_default_applet(second_owner))
    assert.are.equal(second, neoagent.default())
    assert(neoagent.open())
    assert.is_true(second_owner:is_open())
    assert.is_true(first_owner:is_open())

    assert.has_error(function() neoagent._set_default(first) end,
      "Agent Applet already has an owner")
    first_owner:destroy()
    assert.are.equal(second, neoagent._set_default(first))
    applets[#applets + 1] = neoagent.applet()
    assert.are.equal(first, neoagent.default())
    assert.has_error(function() neoagent._set_default({}) end)
    assert.has_error(function() neoagent._set_default_applet({}) end)
  end)
end)
