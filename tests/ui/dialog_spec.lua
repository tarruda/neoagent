local async = require("neoagent.async")
local config = require("neoagent.config")
local Applet = require("applet")
local view_handles = require("tests.helpers.view_handles")

local function transcript_dialog()
  return {
    placement = "transcript",
    title = "Choose an operation",
    body = table.concat({
      "Run this operation?",
      "",
      "Tool: shell",
      "Working directory: /workspace",
      "",
      "$ make install",
      "",
      "This operation can modify external state.",
    }, "\n"),
    actions = {
      { id = "run", label = "run once", key = "y" },
      { id = "edit", label = "edit rule", key = "e" },
      { id = "cancel", label = "cancel", key = "n" },
    },
  }
end

local function floating_dialog()
  return {
    placement = "float",
    title = "Edit command prefix",
    body = "Edit the command prefix that should be remembered.",
    input = {
      label = "Command prefix",
      value = "git status",
      multiline = false,
    },
    actions = {
      { id = "save", label = "save", key = "<CR>" },
      { id = "cancel", label = "cancel", key = "<C-c>" },
    },
  }
end

local function floating_confirm_dialog()
  return {
    placement = "float",
    title = "Approve operation",
    body = "Allow this operation?",
    actions = {
      { id = "allow", label = "allow", key = "y" },
      { id = "deny", label = "deny", key = "n" },
    },
  }
end

local function snapshot(value, id, queued)
  value = vim.deepcopy(value)
  value.id = id
  return { active = value, queue_count = queued or 0 }
end

local function buffer_text(buffer)
  return table.concat(
    vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
end

local function feed(keys)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, false, true),
    "x", false)
end

local function has_mapping(buffer, mode, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, mode)) do
    if mapping.lhs == lhs then return true end
  end
  return false
end

local function footer(window)
  local value = vim.api.nvim_win_get_config(window).footer or ""
  if type(value) == "string" then return value end
  return table.concat(vim.tbl_map(function(chunk)
    return type(chunk) == "table" and chunk[1] or chunk
  end, value))
end

local function target_is_highlighted(pane, key)
  local target = assert(pane.layout.targets[key])
  local rectangle = assert(target.rectangles[1])
  local buffer = assert(pane:native().buffer)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      buffer, pane.focus_namespace, 0, -1, { details = true })) do
    if mark[2] == rectangle.row
        and mark[4].hl_group == target.focus_style then
      return true
    end
  end
  return false
end

describe("neoagent generic dialog UI", function()
  local views, windows, agents, runs = {}, {}, {}, {}

  before_each(function()
    config._reset()
    vim.o.columns = 120
    vim.o.lines = 40
  end)

  after_each(function()
    for _, run in ipairs(runs) do
      if not run:is_done() then run:cancel() end
    end
    for _, window in ipairs(windows) do window:destroy() end
    for _, view in ipairs(views) do
      if not view.destroyed then view:destroy() end
    end
    for _, agent in ipairs(agents) do agent:destroy() end
    views, windows, agents, runs = {}, {}, {}, {}
    vim.cmd("silent! only")
  end)

  it("focuses newly shown dialog actions without discarding the draft", function()
    local chosen = {}
    local view = require("neoagent.ui").new({
      config = config.resolve({}).ui,
      on_dialog_action = function(id, action)
        chosen[#chosen + 1] = { id, action }
      end,
    })
    views[#views + 1] = view
    assert.is_true(view:open())
    view:set_input("half-typed prompt")
    assert.are.equal(view_handles.window(view, "input"), vim.api.nvim_get_current_win())

    view:set_dialog(snapshot(transcript_dialog(), "first"))
    assert.are.equal(view_handles.window(view, "transcript"),
      vim.api.nvim_get_current_win())
    assert.is_nil(view:pane("dialog"))
    assert.are.equal("neoagent-dialog",
      vim.bo[view_handles.buffer(view, "transcript")].filetype)
    local transcript = assert(view:pane("transcript"))
    local first = "dialog:first:widget:actions:item:run"
    assert.are.equal(first, assert(transcript:focused_target()).key)
    assert.is_true(target_is_highlighted(transcript, first))
    feed("<CR>")
    assert.are.same({ { "first", "run" } }, chosen)
    assert.are.equal("half-typed prompt", view:get_input())

    view:set_dialog(snapshot(floating_confirm_dialog(), "second"))
    assert.are.equal(view_handles.window(view, "dialog"),
      vim.api.nvim_get_current_win())
    assert.is_not_nil(view_handles.window(view, "dialog"))
    local dialog = assert(view:pane("dialog"))
    local allow = "dialog:second:actions:item:allow"
    assert.are.equal(allow, assert(dialog:focused_target()).key)
    assert.is_true(target_is_highlighted(dialog, allow))
    assert.are.equal("half-typed prompt", view:get_input())

    view:set_input("")
    view:focus_input()
    view:set_dialog(view.dialog)
    assert.are.equal(view_handles.window(view, "input"),
      vim.api.nvim_get_current_win())
    view:set_dialog(snapshot(transcript_dialog(), "third"))
    assert.are.equal(view_handles.window(view, "transcript"), vim.api.nvim_get_current_win())
  end)

  it("settles dialog focus after Neovim restores the cursor column", function()
    local chosen = {}
    local view = require("neoagent.ui").new({
      config = config.resolve({}).ui,
      on_dialog_action = function(id, action)
        chosen[#chosen + 1] = { id, action }
      end,
    })
    views[#views + 1] = view
    assert.is_true(view:open())
    view:set_dialog(snapshot(transcript_dialog(), "native"))

    local pane = assert(view:pane("transcript"))
    local first = "dialog:native:widget:actions:item:run"
    local target = assert(pane.layout.targets[first])
    local rectangle = assert(target.rectangles[1])
    local window = view_handles.window(view, "transcript")
    local line = vim.api.nvim_buf_get_lines(
      view_handles.buffer(view, "transcript"), rectangle.row,
      rectangle.row + 1, false)[1]
    vim.api.nvim_win_set_cursor(window, { rectangle.row + 1, #line - 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = view_handles.buffer(view, "transcript"),
    })
    assert.are.equal(first, assert(pane:focused_target()).key)
    vim.api.nvim_win_set_cursor(window, { rectangle.row + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = view_handles.buffer(view, "transcript"),
    })

    assert.are.equal(first, assert(pane:focused_target()).key)
    assert.is_true(target_is_highlighted(pane, first))
    feed("<CR>")
    assert.are.same({ { "native", "run" } }, chosen)
  end)

  it("defaults a live sandbox escalation to visible denial", function()
    local dialogs = require("neoagent.dialog").new()
    local view
    view = require("neoagent.ui").new({
      config = config.resolve({ ui = { position = "center" } }).ui,
      on_dialog_action = function(id, action)
        return dialogs:choose(id, action)
      end,
      on_dialog_dismiss = function(id)
        return dialogs:cancel(id)
      end,
    })
    views[#views + 1] = view
    assert.is_true(view:open())
    local detach = dialogs:subscribe(function(snapshot)
      view:set_dialog(snapshot.active and snapshot or nil)
    end)

    local escalation = require("neoagent.sandbox.escalation").new()
    local shell = escalation:tools({
      require("neoagent.tools.shell").new(),
    })[1]
    local elevated = false
    local execute = escalation:wrap({
      restricted = function() error("restricted executor ran") end,
      elevated = function()
        elevated = true
        return { content = { { type = "text", text = "elevated" } } }
      end,
    })
    local cwd = assert(vim.uv.cwd())
    local run = async.run(function()
      return execute(shell, {
        command = "touch ~/random && ls -la ~/random",
        options = {
          require_escalation = true,
          escalation_justification = table.concat({
            "User requested testing the escalation path for creating a file",
            "in the home directory, which is read-only inside the sandbox.",
          }, " "),
        },
      }, {
        dialog = dialogs,
        context = {
          agent = "Neo",
          session_id = {},
          workspace = require("neoagent.workspace").new({
            root = cwd,
            cwd = cwd,
          }),
        },
      })
    end)
    runs[#runs + 1] = run
    assert(vim.wait(1000, function()
      return dialogs:snapshot().active ~= nil
    end, 5))

    local request = assert(dialogs:snapshot().active)
    local pane = assert(view:pane("transcript"))
    local deny = "dialog:" .. request.id .. ":widget:actions:item:deny"
    assert(vim.wait(1000, function()
      local target = pane:focused_target()
      return target and target.key == deny
    end, 5), vim.inspect({
      expected = deny,
      focused = pane:focused_target(),
      cursor = vim.api.nvim_win_get_cursor(
        view_handles.window(view, "transcript")),
    }))
    assert.are.equal("NeoagentCardFocus",
      pane.layout.targets[deny].focus_style)
    assert.is_true(target_is_highlighted(pane, deny))

    feed("<CR>")
    assert(vim.wait(1000, function() return run:is_done() end, 5))
    assert.is_false(elevated)
    assert.is_true(run:result().details.sandbox.denied_by_user)
    detach()
  end)

  it("keeps transcript dialogs in normal mode", function()
    local view = require("neoagent.ui").new({
      config = config.resolve({}).ui,
      on_dialog_action = function() end,
    })
    views[#views + 1] = view
    assert.is_true(view:open())
    view:set_dialog(snapshot(transcript_dialog(), "normal"))
    assert.are.equal(view_handles.window(view, "transcript"), vim.api.nvim_get_current_win())
    vim.api.nvim_feedkeys("i", "x", false)
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
  end)

  it("shows every transcript dialog action in a visible vertical menu", function()
    vim.o.lines = 20
    local view = require("neoagent.ui").new({
      config = config.resolve({ ui = { position = "center", input_height = 4 } }).ui,
      on_dialog_action = function() end,
    })
    views[#views + 1] = view
    local history = {}
    for index = 1, 40 do history[index] = "history line " .. index end
    view:set_messages({ { role = "assistant", content = {
      { type = "text", text = table.concat(history, "\n") },
    } } })
    assert.is_true(view:open())
    local transcript_window = view_handles.window(view, "transcript")
    view:focus_transcript()
    vim.api.nvim_win_set_cursor(transcript_window, { 1, 0 })
    vim.api.nvim_win_call(transcript_window, function() vim.cmd("normal! zt") end)
    view:set_input("retained draft")
    view:focus_input()

    local request = transcript_dialog()
    request.body = table.concat({
      "Review the sandbox request.",
      "The complete explanation can occupy several lines.",
      "The action menu must remain visible below it.",
      "Choose one of the following options.",
    }, "\n")
    view:set_dialog(snapshot(request, "sandbox"))
    local pane = assert(view:pane("transcript"))
    assert(vim.wait(1000, function()
      return pane.layout
        and pane.layout.targets[
          "dialog:sandbox:widget:actions:item:cancel"] ~= nil
    end, 5))

    local rows = {}
    for _, action in ipairs(request.actions) do
      local target = assert(pane.layout.targets[
        "dialog:sandbox:widget:actions:item:" .. action.id])
      local rectangle = assert(target.rectangles[1])
      rows[#rows + 1] = {
        first = rectangle.row + 1,
        last = rectangle.row + rectangle.height,
      }
    end
    assert.is_true(rows[1].first < rows[2].first)
    assert.is_true(rows[2].first < rows[3].first)
    local visible = vim.api.nvim_win_call(
      transcript_window, function()
        return {
          vim.fn.line("w0"),
          vim.fn.line("w$"),
        }
      end)
    assert.is_true(rows[1].first >= visible[1], vim.inspect({
      rows = rows, visible = visible,
    }))
    assert.is_true(rows[#rows].last <= visible[2], vim.inspect({
      rows = rows, visible = visible,
    }))
    assert.are.equal(view_handles.window(view, "transcript"),
      vim.api.nvim_get_current_win())
    assert.are.equal("dialog:sandbox:widget:actions:item:run",
      assert(pane:focused_target()).key)
  end)

  it("navigates transcript dialog menus from either pane", function()
    local responses = {}
    local view = require("neoagent.ui").new({
      config = config.resolve({ ui = { position = "center" } }).ui,
      on_dialog_action = function(id, action)
        responses[#responses + 1] = { id, action }
      end,
    })
    views[#views + 1] = view
    assert.is_true(view:open())
    view:set_input("retained draft")
    view:set_dialog(snapshot(transcript_dialog(), "first"))

    local input = assert(view:pane("input"))
    local transcript = assert(view:pane("transcript"))
    local pane_input = require("applet.pane.input")
    view:focus_input()
    assert.is_true(pane_input.dispatch(input, "n", "J"))
    assert.are.equal("transcript", view.applet:focused_pane())
    assert.are.equal("dialog:first:widget:actions:item:run",
      assert(transcript:focused_target()).key)

    assert.is_true(pane_input.dispatch(transcript, "n", "J"))
    assert.are.equal("dialog:first:widget:actions:item:edit",
      assert(transcript:focused_target()).key)
    vim.api.nvim_win_call(view_handles.window(view, "transcript"),
      function() vim.cmd("normal! j") end)
    assert.are.equal("dialog:first:widget:actions:item:cancel",
      assert(transcript:focused_target()).key)
    assert.is_true(pane_input.dispatch(transcript, "n", "K"))
    assert.are.equal("dialog:first:widget:actions:item:edit",
      assert(transcript:focused_target()).key)
    assert.is_true(pane_input.dispatch(transcript, "n", "<CR>"))
    assert.are.same({ { "first", "edit" } }, responses)

    view:set_dialog(snapshot(transcript_dialog(), "second"))
    view:focus_input()
    assert.is_true(pane_input.dispatch(input, "n", "K"))
    assert.are.equal("dialog:second:widget:actions:item:run",
      assert(transcript:focused_target()).key)
    assert.is_true(pane_input.dispatch(transcript, "n", "n"))
    assert.are.same({ { "first", "edit" }, { "second", "cancel" } },
      responses)
  end)

  it("renders arbitrary transcript actions supplied by the caller", function()
    local responses = {}
    local view = require("neoagent.ui").new({
      config = config.resolve({}).ui,
      on_dialog_action = function(id, action, input)
        responses[#responses + 1] = { id, action, input }
      end,
    })
    views[#views + 1] = view
    view:set_messages({ {
      role = "user",
      content = "Existing transcript",
    } })
    assert.is_true(view:open())
    view:set_context({ steering = { "first queued message" } })
    local value = snapshot(transcript_dialog(), "first", 1)
    view:set_dialog(value)
    local buffer = assert(view_handles.buffer(view, "transcript"))
    assert.are.equal("neoagent-dialog", vim.bo[buffer].filetype)
    assert.are.equal("nofile", vim.bo[buffer].buftype)
    assert.is_false(vim.bo[buffer].modifiable)
    assert.are.equal(buffer,
      vim.api.nvim_win_get_buf(view_handles.window(view, "transcript")))
    assert.are.equal(view_handles.window(view, "transcript"),
      vim.api.nvim_get_current_win())
    local text = buffer_text(buffer)
    for _, expected in ipairs({
      "Existing transcript",
      "Choose an operation",
      "Run this operation?",
      "Tool: shell",
      "Working directory: /workspace",
      "$ make install",
      "modify external state",
      "[y] run once",
      "[e] edit rule",
      "[n] cancel",
      "1 more dialog pending",
    }) do
      assert.is_not_nil(text:find(expected, 1, true), expected)
    end
    assert.matches("Waiting for response", footer(view_handles.window(view, "transcript")))
    assert.is_nil(view.spinner_timer)
    local function status_text()
      local parts = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        buffer, view.transcript.pane.virtual_namespace, 0, -1,
        { details = true }
      )) do
        for _, line in ipairs(mark[4].virt_lines or {}) do
          parts[#parts + 1] = table.concat(vim.tbl_map(function(chunk)
            return chunk[1]
          end, line))
        end
      end
      return table.concat(parts, "\n")
    end
    assert.matches("Steering: first queued message", status_text())

    view:set_dialog(value)
    assert.are.equal(buffer, view_handles.buffer(view, "transcript"))
    feed("e")
    assert.are.same({ { "first", "edit" } }, responses)

    view:close()
    assert.is_true(vim.api.nvim_buf_is_valid(buffer))
    assert.is_table(view.dialog)
    assert.is_true(view:open())
    assert.is_true(vim.api.nvim_buf_is_valid(
      view_handles.buffer(view, "transcript")))
    assert.are.equal(buffer, view_handles.buffer(view, "transcript"))
    view:set_dialog(nil)
    assert.is_nil(view:pane("dialog"))
    assert.are.equal(view_handles.window(view, "input"), vim.api.nvim_get_current_win())
  end)

  it("applies the active Renderer theme to shared dialog components", function()
    local responses = {}
    local renderer = {
      name = "dialog-test",
      theme = Applet.Theme.new({ groups = {
        window_title = "DialogTestTitle",
        dialog_title = "DialogTestTitle",
        dialog_action = "DialogTestAction",
        dialog_background = "DialogTestBackground",
        muted = "Comment",
        selected = "Visual",
      } }),
      render_block = function(_, block)
        return Applet.Pane.nodes.text({
          key = "dialog-test:" .. block.key,
          text = block.text or block.kind,
        })
      end,
      render_details = function(_, block)
        return Applet.Pane.nodes.text({
          key = "dialog-test-details:" .. block.key,
          text = block.text or block.kind,
        })
      end,
    }
    local ui_config = config.resolve({ ui = { renderer = renderer } }).ui
    local view = require("neoagent.ui").new({
      config = ui_config,
      on_dialog_action = function(id, action, input)
        responses[#responses + 1] = { id, action, input }
      end,
    })
    views[#views + 1] = view
    assert(view:open())

    view:set_dialog(snapshot(transcript_dialog(), "transcript"))
    assert.matches("Run this operation",
      buffer_text(view_handles.buffer(view, "transcript")))
    feed("y")
    assert.are.same({ "transcript", "run" }, responses[1])

    view:set_dialog(nil)
    view:set_dialog(snapshot(floating_confirm_dialog(), "float"))
    local window = assert(view_handles.window(view, "dialog"))
    local title = vim.api.nvim_win_get_config(window).title
    if type(title) == "table" then
      title = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, title))
    end
    assert.matches("Approve operation", title)
    assert.are.equal("DialogTestTitle",
      vim.api.nvim_win_get_config(window).title[1][2])
    assert.matches("Allow this operation", buffer_text(view_handles.buffer(view, "dialog")))
    local replacement = vim.tbl_extend("force", renderer, {
      name = "replacement-dialog-test",
      theme = Applet.Theme.new({ groups = {
        window_title = "ReplacementDialogTitle",
        dialog_title = "ReplacementDialogTitle",
        dialog_action = "ReplacementDialogAction",
        dialog_background = "ReplacementDialogBackground",
        muted = "Comment",
        selected = "Visual",
      } }),
    })
    assert.are.equal(replacement, view:set_renderer(replacement))
    assert.is_false(vim.api.nvim_win_is_valid(window))
    window = assert(view_handles.window(view, "dialog"))
    title = vim.api.nvim_win_get_config(window).title
    if type(title) == "table" then
      title = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, title))
    end
    assert.matches("Approve operation", title)
    assert.are.equal("ReplacementDialogTitle",
      vim.api.nvim_win_get_config(window).title[1][2])
    assert.are.equal(window, vim.api.nvim_get_current_win())
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
    assert.is_true(has_mapping(view_handles.buffer(view, "dialog"), "n", "n"))
    feed("n")
    assert.are.same({ "float", "deny" }, responses[2])
  end)

  it("collects caller-defined text from a focused floating dialog",
    function()
      local responses, dismissed = {}, {}
      local view = require("neoagent.ui").new({
        config = config.resolve({}).ui,
        on_dialog_action = function(id, action, input)
          responses[#responses + 1] = { id, action, input }
        end,
        on_dialog_dismiss = function(id)
          dismissed[#dismissed + 1] = id
        end,
      })
      views[#views + 1] = view
      assert(view:open())
      local editable = floating_dialog()
      editable.body = string.rep("界", 100)
      view:set_dialog(snapshot(editable, "editable", 2))
      local buffer, window = assert(view_handles.buffer(view, "dialog")), assert(view_handles.window(view, "dialog"))
      assert.are.equal("neoagent-dialog-input", vim.bo[buffer].filetype)
      assert.are.equal(window, vim.api.nvim_get_current_win())
      assert.are.equal("git status", buffer_text(buffer))
      assert.is_true(vim.bo[buffer].modifiable)
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "git diff" })
      feed("<CR>")
      assert.are.same({ { "editable", "save", "git diff" } }, responses)

      view:set_dialog(nil)
      assert.is_false(vim.api.nvim_win_is_valid(window))
      view:set_dialog(snapshot(floating_dialog(), "cancelled"))
      feed("<C-c>")
      assert.are.same(
        { "cancelled", "cancel", "git status" }, responses[#responses])
      view:set_dialog(nil)
      view:set_dialog(snapshot(floating_dialog(), "dismissed"))
      window = assert(view_handles.window(view, "dialog"))
      vim.api.nvim_win_close(window, true)
      assert(vim.wait(1000, function() return #dismissed == 1 end, 5))
      assert.are.same({ "dismissed" }, dismissed)

      local informational = floating_dialog()
      informational.input = nil
      informational.actions = {
        { id = "close", label = "close", key = "q" },
      }
      view:set_dialog(snapshot(informational, "informational", 1))
      buffer = assert(view_handles.buffer(view, "dialog"))
      assert.is_false(vim.bo[buffer].modifiable)
      assert.are.equal(view_handles.window(view, "dialog"), vim.api.nvim_get_current_win())
      assert.are.equal("n", vim.api.nvim_get_mode().mode)
      assert.is_true(has_mapping(buffer, "n", "q"))
      feed("q")
      assert.are.same(
        { "informational", "close" }, responses[#responses])
    end)

  it("routes queued responses through one Agent Applet",
    function()
      local first = require("neoagent.agent").new({
        name = "first",
        default_registry = false,
        providers = {},
        persistence = {
          enabled = false,
          workspace_settings = false,
          directory = vim.fn.tempname(),
        },
        tools = {},
      })
      local second = require("neoagent.agent").new({
        name = "second",
        default_registry = false,
        providers = {},
        persistence = {
          enabled = false,
          workspace_settings = false,
          directory = vim.fn.tempname(),
        },
        tools = {},
      })
      agents = { first, second }
      local window = require("neoagent.applet")._from_agents({
        agents = agents,
        config = config.resolve({}).ui,
      })
      windows[#windows + 1] = window
      assert(window:open())
      local dialogs = first:dialogs()

      local one = dialogs:show(transcript_dialog())
      local one_id = dialogs:snapshot().active.id
      local two = dialogs:show(transcript_dialog())
      assert(vim.wait(1000, function()
        local view = window:view()
        return view and view.dialog
          and view.dialog.active.id == one_id
      end, 5))
      assert.are.equal(first, window:default_agent())
      feed("y")
      assert(vim.wait(1000, function()
        local view = window:view()
        return one:is_done() and view.dialog
          and view.dialog.active.id ~= one_id
      end, 5))
      assert.are.equal("run", one:result().action)
      feed("n")
      assert(vim.wait(1000, function() return two:is_done() end, 5))
      assert.are.equal("cancel", two:result().action)
      assert.is_nil(window:view().dialog)

      local dismissed = dialogs:show(floating_dialog())
      assert(vim.wait(1000, function()
        return view_handles.window(window:view(), "dialog") ~= nil
      end, 5))
      vim.api.nvim_win_close(view_handles.window(window:view(), "dialog"), true)
      assert(vim.wait(1000, function() return dismissed:is_done() end, 5))
      assert.is_false(dismissed:result().ok)
      assert.are.equal("dialog dismissed by user",
        dismissed:result().error.message)

      local pending = dialogs:show(transcript_dialog())
      window:destroy()
      assert.is_false(pending:is_done())
      first:destroy()
      assert(vim.wait(1000, function() return pending:is_done() end, 5))
      assert.is_false(pending:result().ok)
      assert.is_true(pending:result().presenter_unavailable)
    end)

  it("keeps each dialog source with its owning Agent Applet",
    function()
      local first = require("neoagent.agent").new({
        name = "first",
        default_registry = false,
        providers = {},
        persistence = {
          enabled = false,
          workspace_settings = false,
          directory = vim.fn.tempname(),
        },
        tools = {},
      })
      local second = require("neoagent.agent").new({
        name = "second",
        default_registry = false,
        providers = {},
        persistence = {
          enabled = false,
          workspace_settings = false,
          directory = vim.fn.tempname(),
        },
        tools = {},
      })
      agents = { first, second }
      local window = require("neoagent.applet")._from_agents({
        agents = agents,
        config = config.resolve({}).ui,
      })
      windows[#windows + 1] = window
      assert(window:open())
      local dialogs = first:dialogs()

      local request = transcript_dialog()
      local pending = dialogs:show(request)
      local id = dialogs:snapshot().active.id
      assert(vim.wait(1000, function()
        local view = window:view()
        return view and view.dialog and view.dialog.active.id == id
      end, 5))

      local first_view = window:view()
      assert(window:select(second))
      local second_view = window:view()
      assert.are_not.equal(first_view, second_view)
      assert.is_nil(second_view.dialog)
      assert.is_nil(view_handles.buffer(second_view, "dialog"))
      assert.are.equal(id, dialogs:snapshot().active.id)

      assert(window:select(first))
      assert(vim.wait(1000, function()
        return first_view.dialog and first_view.dialog.active.id == id
      end, 5))
      assert.are.equal(view_handles.window(first_view, "transcript"),
        vim.api.nvim_get_current_win())
      assert.are.equal("dialog:" .. id .. ":widget:actions:item:run",
        assert(first_view:pane("transcript"):focused_target()).key)
      feed("y")
      assert(vim.wait(1000, function() return pending:is_done() end, 5))
      assert.are.equal("run", pending:result().action)
    end)

  it("fails a dialog when a custom View cannot present it", function()
    local agent = require("neoagent.agent").new({
      name = "headless",
      default_registry = false,
      providers = {},
      persistence = {
        enabled = false,
        workspace_settings = false,
        directory = vim.fn.tempname(),
      },
      tools = {},
    })
    agents = { agent }
    local set_dialog_calls = 0
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
      set_dialog = function(_, value)
        if value then
          set_dialog_calls = set_dialog_calls + 1
          error("presentation failed")
        end
        return true
      end,
    }
    local window = require("neoagent.applet")._from_agents({
      agents = agents,
      config = config.resolve({}).ui,
      _view = function() return view end,
    })
    windows[#windows + 1] = window
    assert(window:open())
    local dialogs = agent:dialogs()
    local pending = dialogs:show(transcript_dialog())
    assert(vim.wait(1000, function() return pending:is_done() end, 5))
    assert.are.equal(1, set_dialog_calls)
    assert.is_false(pending:result().ok)
    assert.is_true(pending:result().presenter_unavailable)
  end)
end)
