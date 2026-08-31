local Applet = require("applet")
local async = require("neoagent.async")
local Agent = require("neoagent.agent")
local NeoagentApplet = require("neoagent.applet")
local fake_model = require("tests.helpers.fake_model")
local renderers = require("neoagent.ui.renderers")
local util = require("neoagent.util")
local view_handles = require("tests.helpers.view_handles")

local function options(name)
  return {
    name = name,
    default_registry = false,
    workspace_trust = false,
    persistence = { enabled = false },
    default_model = { provider = "fake", model = "test" },
    providers = { fake = { api = "fake", models = { test = {} } } },
    _apis = { fake = function() return fake_model.new({}) end },
    tools = {},
    agent_instructions = false,
    skills = false,
    ui = { position = "center", style = "pi" },
  }
end

describe("neoagent Applet Presenter", function()
  local agents = {}
  local windows = {}

  before_each(function()
    vim.o.columns = 110
    vim.o.lines = 36
  end)

  after_each(function()
    for _, window in ipairs(windows) do window:destroy() end
    for _, agent in ipairs(agents) do agent:destroy() end
    windows, agents = {}, {}
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
  end)

  local function composition(name, host)
    local agent = Agent.new(options(name))
    agents[#agents + 1] = agent
    local view_factory
    if host then
      view_factory = function(opts)
        opts.host_factory = host
        return require("neoagent.ui.applet_view").new(opts)
      end
    end
    local window = NeoagentApplet._from_agents({
      agents = { agent },
      config = agent:config().ui,
      _view = view_factory,
    })
    windows[#windows + 1] = window
    return agent:presenter(), window
  end

  local function feed(keys)
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  local function selection(presenter, window)
    local run = presenter:select({
      prompt = "Choose a value",
      items = {
        { id = "alpha", label = "Alpha" },
        { id = "beta", label = "Beta", detail = "second value" },
      },
    })
    local view, _, pane = require("tests.helpers.presentation").active(window)
    return run, view, pane
  end

  local function choose_second(presenter, window)
    assert(window:open())
    local run = presenter:select({
      prompt = "Choose a value",
      items = {
        { id = "alpha", label = "Alpha" },
        { id = "beta", label = "Beta", detail = "second value" },
      },
    })
    local view, _, pane = require("tests.helpers.presentation").active(window)
    assert.are.equal("presentation-filter", view.applet:focused_pane())
    assert.is_true(require("applet.pane.input").dispatch(
      view.presentation_component.pane, "n", "j"))
    assert.is_true(require("applet.pane.input").dispatch(
      view.presentation_component.pane, "n", "<CR>"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(run:result().ok)
    assert.are.equal("beta", run:result().value)
    assert.is_true(window:is_open())
    assert.is_false(pane:is_mounted())
  end

  it("projects the same semantic menu through floating and tab Hosts", function()
    local presenter, window = composition("Floating presenter")
    choose_second(presenter, window)
    window:destroy()

    presenter, window = composition("Tab presenter",
      Applet.host.tab({ label = "Presenter test" }))
    choose_second(presenter, window)
  end)

  it("selects the initial menu item when Enter is pressed immediately", function()
    local presenter, window = composition("Initial selection")
    assert(window:open())
    local run, view, pane = selection(presenter, window)
    local request = view.presentation.active

    local target = pane:focused_target()
    assert.is_table(target)
    assert.are.equal("presentation:" .. request.id .. ":item:alpha", target.key)
    feed("<CR>")

    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(run:result().ok)
    assert.are.equal("alpha", run:result().value)
  end)

  it("retains the initial selection after a tall menu settles", function()
    local presenter, window = composition("Settled initial selection")
    assert(window:open())
    local items = {}
    for index = 1, 40 do
      items[#items + 1] = {
        id = "item-" .. index,
        label = ("Item %02d %s"):format(index, string.rep("complete label ", 8)),
      }
    end
    local run = presenter:select({ prompt = "Choose a tall value", items = items })
    local view, request, pane = require("tests.helpers.presentation").active(window)

    local target = pane:focused_target()
    assert.is_table(target)
    assert.are.equal("presentation:" .. request.id .. ":item:item-1", target.key)
    feed("<CR>")

    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(run:result().ok)
    assert.are.equal("item-1", run:result().value)
  end)

  it("filters a content-sized two-pane picker while its prompt stays editable", function()
    local presenter, window = composition("Filtered selection")
    assert(window:open())
    local run = presenter:select({
      prompt = "Choose a filtered value",
      items = {
        { id = "alpha", label = "Alpha" },
        { id = "beta", label = "Beta", detail = "second value" },
        { id = "gamma", label = "Gamma" },
      },
    })
    assert(vim.wait(1000, function()
      local view = window:view()
      return view and view:pane("presentation-filter")
        and view:pane("presentation-filter"):is_mounted()
        and view:pane("presentation-results")
        and view:pane("presentation-results"):is_mounted()
    end))
    local view = window:view()
    local filter = view:pane("presentation-filter")
    local results = view:pane("presentation-results")
    local filter_native = filter:native()
    local result_native = results:native()

    assert.are.equal("presentation-filter", view.applet:focused_pane())
    assert.are.equal("insert", filter:mode())
    assert.are.same({ "● Alpha", "  Beta · second value", "  Gamma" },
      vim.api.nvim_buf_get_lines(result_native.buffer, 0, -1, false))
    assert.are.equal(3, vim.api.nvim_win_get_height(result_native.window))
    assert.is_false(vim.api.nvim_get_option_value(
      "wrap", { win = result_native.window }))

    vim.api.nvim_buf_set_text(filter_native.buffer, 0, 0, 0, 0, { "bt" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = filter_native.buffer })
    assert(vim.wait(1000, function()
      return vim.deep_equal({ "● Beta · second value" },
        vim.api.nvim_buf_get_lines(result_native.buffer, 0, -1, false))
    end))
    assert.are.equal(1, vim.api.nvim_win_get_height(result_native.window))

    vim.api.nvim_buf_set_lines(filter_native.buffer, 0, -1, false, { "" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = filter_native.buffer })
    assert(vim.wait(1000, function()
      return #vim.api.nvim_buf_get_lines(result_native.buffer, 0, -1, false) == 3
    end))
    assert(require("applet.pane.input").dispatch(
      view.presentation_component.filter, "i", "<C-j>"))
    assert(require("applet.pane.input").dispatch(
      view.presentation_component.filter, "i", "<CR>"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(run:result().ok)
    assert.are.equal("gamma", run:result().value)
    assert.is_false(filter:is_mounted())
    assert.is_false(results:is_mounted())
  end)

  it("updates picker items in place while preserving query, selection, and focus", function()
    local presenter, window = composition("Live selection")
    assert(window:open())
    local run, update = presenter:select({
      prompt = "Choose a live value",
      items = {
        { id = "alpha", label = "Alpha" },
        { id = "beta", label = "Beta" },
      },
    })
    local view, request = require("tests.helpers.presentation").active(window)
    local component = view.presentation_component
    assert(component:set_text("a"))
    assert(require("applet.pane.input").dispatch(
      component.filter, "i", "<C-j>"))
    assert.are.equal("beta", component.selected)
    assert.are.equal("presentation-filter", view.applet:focused_pane())

    assert.is_true(update({
      { id = "aardvark", label = "Aardvark" },
      { id = "alpha", label = "Alpha updated" },
      { id = "beta", label = "Beta updated" },
    }))
    local expected = {
      "  Aardvark",
      "  Alpha updated",
      "● Beta updated",
    }
    assert(vim.wait(1000, function()
      return view.presentation_component == component
        and component:text() == "a"
        and component.selected == "beta"
        and vim.deep_equal(expected, vim.api.nvim_buf_get_lines(
          component.results:native().buffer, 0, -1, false))
    end))
    assert.are.equal(request.id, view.presentation.active.id)
    assert.are.equal("presentation-filter", view.applet:focused_pane())
    assert.are.same(expected, vim.api.nvim_buf_get_lines(
      component.results:native().buffer, 0, -1, false))

    assert(require("applet.pane.input").dispatch(
      component.filter, "i", "<CR>"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.equal("beta", run:result().value)
  end)

  it("ranks fuzzy matches and rejects stale choices when no result matches", function()
    local presenter, window = composition("Ranked selection")
    assert(window:open())
    local run = presenter:select({
      prompt = "Choose a ranked value",
      items = {
        { id = "beta", label = "Beta" },
        { id = "alpha-one", label = "Alpha" },
        { id = "gamma", label = "Gamma" },
        { id = "alpha-two", label = "Alpha" },
      },
    })
    local view, request, pane = require("tests.helpers.presentation").active(window)
    local native = pane:native()

    assert(view.presentation_component:set_text("a"))
    assert(vim.wait(1000, function()
      return vim.deep_equal({ "  Alpha", "  Alpha", "  Gamma", "● Beta" },
        vim.api.nvim_buf_get_lines(native.buffer, 0, -1, false))
    end))
    assert(view.presentation_component:set_text("al"))
    assert(vim.wait(1000, function()
      return vim.deep_equal({ "● Alpha", "  Alpha" },
        vim.api.nvim_buf_get_lines(native.buffer, 0, -1, false))
    end))
    assert(view.presentation_component:set_text("zzz"))
    assert(vim.wait(1000, function()
      return vim.deep_equal({ "  No matches" },
        vim.api.nvim_buf_get_lines(native.buffer, 0, -1, false))
    end))
    assert.is_nil(pane:focused_target())
    assert.is_false(require("applet.pane.input").dispatch_action(
      view.presentation_component.results,
      Applet.Pane.nodes.action("presentation.choose_item", { id = "alpha-one" }),
      nil, 1, "n", 0, 0))
    assert.is_false(run:is_done())

    assert(presenter:cancel(request.id))
    assert(vim.wait(1000, function() return run:is_done() end))
  end)

  it("uses nowrap and the default background for selection menus", function()
    local presenter, window = composition("Selection appearance")
    assert(window:open())
    local run, view, pane = selection(presenter, window)
    local native = pane:native()

    assert.is_false(vim.api.nvim_get_option_value(
      "wrap", { win = native.window }))
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      native.buffer, view.presentation_component.pane.namespace,
      0, -1, { details = true })) do
      assert.are_not.equal("NeoagentDialogBackground",
        mark[4].line_hl_group or mark[4].hl_group)
    end

    assert(presenter:cancel(view.presentation.active.id))
    assert(vim.wait(1000, function() return run:is_done() end))
  end)

  it("updates both picker Panes when the Renderer changes", function()
    local presenter, window = composition("Selection theme")
    assert(window:open())
    local run, view = selection(presenter, window)
    local filter_generation = view.presentation_component.filter.theme_generation
    local results_generation = view.presentation_component.results.theme_generation

    assert.are.equal(renderers.codex, view:set_renderer(renderers.codex))
    assert.are.equal(filter_generation + 1,
      view.presentation_component.filter.theme_generation)
    assert.are.equal(results_generation + 1,
      view.presentation_component.results.theme_generation)

    assert(presenter:cancel(view.presentation.active.id))
    assert(vim.wait(1000, function() return run:is_done() end))
  end)

  it("keeps selection labels and details on complete physical lines", function()
    local presenter, window = composition("Complete selection text")
    assert(window:open())
    local label = "label:" .. string.rep(" complete-selection-label", 12)
    local detail = "detail:" .. string.rep(" complete-selection-detail", 12)
    local run = presenter:select({
      prompt = "Choose a complete value",
      items = { { id = "complete", label = label, detail = detail } },
    })
    local view, _, pane = require("tests.helpers.presentation").active(window)
    local native = pane:native()
    assert.is_true(vim.fn.strdisplaywidth(label)
      > vim.api.nvim_win_get_width(native.window))

    local lines = vim.api.nvim_buf_get_lines(native.buffer, 0, -1, false)
    assert.are.equal(1, #vim.tbl_filter(function(line)
      return line:find(label, 1, true) ~= nil
    end, lines))
    assert.are.equal(1, #vim.tbl_filter(function(line)
      return line:find(detail, 1, true) ~= nil
    end, lines))
    assert.is_false(vim.api.nvim_get_option_value(
      "wrap", { win = native.window }))

    assert(presenter:cancel(view.presentation.active.id))
    assert(vim.wait(1000, function() return run:is_done() end))
  end)

  it("cancels selection menus with Ctrl-C", function()
    local presenter, window = composition("Selection cancellation")
    assert(window:open())
    local run = selection(presenter, window)

    feed("<C-c>")

    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
    assert.are.equal("cancelled", run:result().error.kind)
  end)

  it("cancels a natively closed menu and restores transcript interaction", function()
    local presenter, window = composition("Native selection close")
    assert(window:open())
    local view = window:view()
    view:set_messages({ {
      role = "assistant",
      content = { { type = "text", text = "selectable answer" } },
    } })
    view.transcript.pane:flush()
    local run, _, pane = selection(presenter, window)

    vim.api.nvim_set_current_win(pane:native().window)
    vim.cmd("q")

    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
    assert.are.equal("cancelled", run:result().error.kind)
    assert.is_nil(presenter:snapshot().active)
    assert.is_nil(view.presentation)

    assert(view:focus_transcript())
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      view_handles.buffer(view, "transcript"), 0, -1, false)) do
      if line:find("selectable answer", 1, true) then
        vim.api.nvim_win_set_cursor(view_handles.window(view, "transcript"), { row, 0 })
        break
      end
    end
    feed("<CR>")
    assert(vim.wait(1000, function()
      return view_handles.window(view, "details") and vim.api.nvim_win_is_valid(view_handles.window(view, "details"))
    end))
  end)

  it("shows persistent notices that Ctrl-C closes", function()
    local presenter, window = composition("Device login notice")
    assert(window:open())
    local run = presenter:notice({
      prompt = "OpenAI device login · <C-c> close",
      body = table.concat({
        "Open this page:",
        "https://device.example",
        "",
        "Enter this code:",
        "ABCD-EFGH",
      }, "\n"),
    })
    local view, request, pane = require("tests.helpers.presentation").active(window)
    local native = pane:native()

    assert.are.equal("notice", request.kind)
    assert.are.equal("presentation", view.applet:focused_pane())
    assert.are.equal("neoagent-notice", vim.bo[native.buffer].filetype)
    assert.is_false(vim.bo[native.buffer].modifiable)
    assert.is_true(vim.api.nvim_get_option_value(
      "wrap", { win = native.window }))
    assert.are.same({
      "Open this page:",
      "https://device.example",
      "",
      "Enter this code:",
      "ABCD-EFGH",
    }, vim.api.nvim_buf_get_lines(native.buffer, 0, -1, false))
    assert.matches("<C%-c> close",
      vim.api.nvim_win_get_config(native.window).title[1][1])
    assert.is_false(run:is_done())

    require("tests.helpers.presentation").cancel(window)

    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
    assert.are.equal("cancelled", run:result().error.kind)
    assert.is_nil(presenter:snapshot().active)
    assert.is_nil(view.presentation)
    assert.is_false(pane:is_mounted())
  end)

  it("opens grouped mapping help from input and closes it with q", function()
    local presenter, window = composition("Mapping help")
    assert(window:open())
    local view = assert(window:view())

    feed("<C-g>?")

    local _, request, pane = require("tests.helpers.presentation").active(window)
    local native = pane:native()
    local body = table.concat(vim.api.nvim_buf_get_lines(
      native.buffer, 0, -1, false), "\n")
    assert.are.equal("notice", request.kind)
    assert.are.equal("Neoagent mappings · <C-c>/q close", request.prompt)
    assert.matches("^Input window\n", body)
    assert.is_not_nil(body:find("<CR>  Submit input", 1, true))
    assert.is_not_nil(body:find("<C-g>?  Show mapping help", 1, true))
    assert.is_not_nil(body:find(
      "<A-n>  Create or select Agent", 1, true))
    assert.is_not_nil(body:find("\n\nTranscript window\n", 1, true))
    assert.is_not_nil(body:find("<CR>  Open card details", 1, true))
    assert.is_not_nil(body:find("<C-w>j  Focus input", 1, true))

    feed("q")

    assert(vim.wait(1000, function()
      return presenter:snapshot().active == nil
        and view.presentation == nil
        and vim.api.nvim_get_current_win() == view_handles.window(view, "input")
    end))
  end)

  it("masks secret input and wipes its transient buffer", function()
    local presenter, window = composition("Secret presenter")
    assert(window:open())
    local run = presenter:input({
      prompt = "API key",
      secret = true,
    })
    assert(vim.wait(1000, function()
      local view = window:view()
      return view and view:pane("presentation")
        and view:pane("presentation"):is_mounted()
    end))
    local view = window:view()
    local pane = view:pane("presentation")
    local native = pane:native()
    assert.are.equal("neoagent-secret", vim.bo[native.buffer].filetype)
    assert.is_false(vim.bo[native.buffer].swapfile)
    assert.is_false(vim.bo[native.buffer].undofile)
    pane:replace_text("s3cr3t", { line = 1, column = 6 }, 1)
    local marks = vim.api.nvim_buf_get_extmarks(native.buffer,
      view.presentation_component.pane.mask_namespace, 0, -1, { details = true })
    assert.are.equal(6, #marks)
    for _, mark in ipairs(marks) do assert.are.equal("•", mark[4].conceal) end
    assert.is_true(require("applet.pane.input").dispatch(
      view.presentation_component.pane, "i", "<CR>"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.equal("s3cr3t", run:result().value)
    assert(vim.wait(1000, function()
      return not vim.api.nvim_buf_is_valid(native.buffer)
    end))
    assert.is_nil(presenter:snapshot().active)
  end)

  it("fails a semantic request when a custom View cannot present it", function()
    local agent = Agent.new(options("Unsupported presenter"))
    agents[#agents + 1] = agent
    local view = {
      destroyed = false,
      open = function() return true end,
      close = function() end,
      is_open = function() return true end,
      destroy = function(self) self.destroyed = true end,
      get_input = function() return "" end,
      set_input = function() end,
      set_messages = function() end,
      set_context = function() end,
      apply = function() end,
      finish = function() end,
    }
    local window = NeoagentApplet._from_agents({
      agents = { agent },
      config = agent:config().ui,
      _view = function() return view end,
    })
    windows[#windows + 1] = window
    assert(window:open())

    local pending = agent:presenter():select({ items = { "value" } })

    assert(vim.wait(1000, function() return pending:is_done() end, 5))
    assert.is_false(pending:result().ok)
    assert.matches("does not support semantic presentations",
      pending:result().error.message)
    assert.is_nil(agent:presenter():snapshot().active)
    assert.are.equal("idle", agent:activity().state)
  end)

  it("validates the complete Agent host-effects boundary", function()
    assert.has_error(function()
      Agent.new(options("Invalid host effects"), {
        host_effects = {},
      })
    end, "agent host effects are invalid")
  end)

  it("reports immediate model selection presentation failures", function()
    local notifications = {}
    local presenter = {
      select = function(_, request)
        return async.run(function()
          error(util.error("presentation", "selection surface failed"), 0)
        end, { error_kind = "presentation" })
      end,
      input = function()
        return async.run(function()
          return { ok = true, value = "input" }
        end, { error_kind = "presentation" })
      end,
      confirm = function()
        return async.run(function()
          return { ok = true, value = true }
        end, { error_kind = "presentation" })
      end,
      notify = function(_, value)
        notifications[#notifications + 1] = value.message
      end,
      open_uri = function() return true end,
    }
    local opts = options("Immediate presenter")
    opts.providers.fake.models.alternate = {}
    local agent = Agent.new(opts, {
      presenter = presenter,
      host_effects = {
        refresh_file = function() return {} end,
        open_document = function() return true end,
        on_exit = function() return function() end end,
      },
    })
    agents[#agents + 1] = agent
    assert(agent:prepare())

    assert.is_true(agent:select_model())
    assert.are.same({ "neoagent: selection surface failed" }, notifications)
  end)

  it("contains file-refresh host failures after semantic tool results", function()
    local notifications = {}
    local presenter = {
      select = function() error("unused") end,
      input = function() error("unused") end,
      confirm = function() error("unused") end,
      notify = function(_, value)
        notifications[#notifications + 1] = value.message
      end,
      open_uri = function() return true end,
    }
    local tool = {
      name = "change_files",
      description = "Report changed files",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
      execute = function()
        return {
          content = { { type = "text", text = "changed" } },
          details = { changed_paths = { "throw.txt", "report.txt" } },
        }
      end,
    }
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall",
        id = "change",
        name = tool.name,
        arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local opts = options("Refresh boundary")
    opts.tools = { tool }
    opts._apis.fake = function() return model end
    local agent = Agent.new(opts, {
      presenter = presenter,
      host_effects = {
        refresh_file = function(path)
          if vim.endswith(path, "throw.txt") then error("refresh exploded") end
          return {
            modified = { "modified.txt" },
            failures = { "reload exploded" },
          }
        end,
        open_document = function() return true end,
        on_exit = function() return function() end end,
      },
    })
    agents[#agents + 1] = agent

    local run = assert(agent:send("change files"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(run:result().ok)
    assert.matches("failed to refresh changed file: .*refresh exploded",
      notifications[1])
    assert.matches("did not reload modified buffer modified.txt",
      notifications[2])
    assert.matches("failed to reload changed buffer: reload exploded",
      notifications[3])
  end)
end)
