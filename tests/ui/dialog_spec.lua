local config = require("neoagent.config")

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

local function footer(window)
  local value = vim.api.nvim_win_get_config(window).footer or ""
  if type(value) == "string" then return value end
  return table.concat(vim.tbl_map(function(chunk)
    return type(chunk) == "table" and chunk[1] or chunk
  end, value))
end

describe("neoagent generic dialog UI", function()
  local views, windows, controllers = {}, {}, {}

  before_each(function()
    config._reset()
    vim.o.columns = 120
    vim.o.lines = 40
  end)

  after_each(function()
    for _, window in ipairs(windows) do window:destroy() end
    for _, view in ipairs(views) do
      if not view.destroyed then view:destroy() end
    end
    for _, controller in ipairs(controllers) do controller:destroy() end
    views, windows, controllers = {}, {}, {}
    vim.cmd("silent! only")
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
    local buffer = assert(view.dialog_buf)
    assert.are.equal("neoagent-dialog", vim.bo[buffer].filetype)
    assert.are.equal("nofile", vim.bo[buffer].buftype)
    assert.is_false(vim.bo[buffer].modifiable)
    assert.are.equal(buffer,
      vim.api.nvim_win_get_buf(view.transcript_win))
    assert.are.equal(view.transcript_win,
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
    assert.matches("Waiting for response", footer(view.transcript_win))
    assert.is_nil(view.spinner_timer)
    local function status_text()
      local parts = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        buffer, view.namespace, 0, -1, { details = true }
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
    view:_show_dialog()
    assert.are.equal(buffer, view.dialog_buf)
    feed("e")
    assert.are.same({ { "first", "edit" } }, responses)

    view:close()
    assert.is_false(vim.api.nvim_buf_is_valid(buffer))
    assert.is_table(view.dialog)
    assert.is_true(view:open())
    assert.is_true(vim.api.nvim_buf_is_valid(view.dialog_buf))
    assert.are_not.equal(buffer, view.dialog_buf)
    view:set_dialog(nil)
    assert.is_nil(view.dialog_buf)
    assert.are.equal(view.input_win, vim.api.nvim_get_current_win())
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
      local buffer, window = assert(view.dialog_buf), assert(view.dialog_win)
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
      window = assert(view.dialog_win)
      vim.api.nvim_win_close(window, true)
      assert(vim.wait(1000, function() return #dismissed == 1 end, 5))
      assert.are.same({ "dismissed" }, dismissed)

      local informational = floating_dialog()
      informational.input = nil
      informational.actions = {
        { id = "close", label = "close", key = "q" },
      }
      view:set_dialog(snapshot(informational, "informational", 1))
      buffer = assert(view.dialog_buf)
      assert.is_false(vim.bo[buffer].modifiable)
      feed("q")
      assert.are.same(
        { "informational", "close" }, responses[#responses])
    end)

  it("routes queued dialog responses through Window without switching Controllers",
    function()
      local dialogs = require("neoagent.dialog").new()
      local first = require("neoagent.controller").new({
        name = "first",
        persistence = {
          enabled = false,
          workspace_settings = false,
          directory = vim.fn.tempname(),
        },
        tools = {},
      })
      local second = require("neoagent.controller").new({
        name = "second",
        persistence = {
          enabled = false,
          workspace_settings = false,
          directory = vim.fn.tempname(),
        },
        tools = {},
      })
      controllers = { first, second }
      local window = require("neoagent.window").new({
        controllers = controllers,
        config = config.resolve({}).ui,
        dialogs = dialogs,
      })
      windows[#windows + 1] = window

      local one = dialogs:show(transcript_dialog())
      local one_id = dialogs:snapshot().active.id
      local two = dialogs:show(transcript_dialog())
      assert(vim.wait(1000, function()
        local view = window:_state().view
        return view and view.dialog
          and view.dialog.active.id == one_id
      end, 5))
      assert.are.equal(first, window:active())
      feed("y")
      assert(vim.wait(1000, function()
        local view = window:_state().view
        return one:is_done() and view.dialog
          and view.dialog.active.id ~= one_id
      end, 5))
      assert.are.equal("run", one:result().action)
      feed("n")
      assert(vim.wait(1000, function() return two:is_done() end, 5))
      assert.are.equal("cancel", two:result().action)
      assert.is_nil(window:_state().view.dialog)

      local dismissed = dialogs:show(floating_dialog())
      assert(vim.wait(1000, function()
        return window:_state().view.dialog_win ~= nil
      end, 5))
      vim.api.nvim_win_close(window:_state().view.dialog_win, true)
      assert(vim.wait(1000, function() return dismissed:is_done() end, 5))
      assert.is_false(dismissed:result().ok)
      assert.are.equal("dialog dismissed by user",
        dismissed:result().error.message)

      local pending = dialogs:show(transcript_dialog())
      window:destroy()
      assert(vim.wait(1000, function() return pending:is_done() end, 5))
      assert.is_false(pending:result().ok)
      assert.is_true(pending:result().presenter_unavailable)
    end)

  it("shows Controller-scoped dialogs only with their owning Controller",
    function()
      local dialogs = require("neoagent.dialog").new()
      local first = require("neoagent.controller").new({
        name = "first",
        persistence = {
          enabled = false,
          workspace_settings = false,
          directory = vim.fn.tempname(),
        },
        tools = {},
      })
      local second = require("neoagent.controller").new({
        name = "second",
        persistence = {
          enabled = false,
          workspace_settings = false,
          directory = vim.fn.tempname(),
        },
        tools = {},
      })
      controllers = { first, second }
      local window = require("neoagent.window").new({
        controllers = controllers,
        config = config.resolve({}).ui,
        dialogs = dialogs,
      })
      windows[#windows + 1] = window

      local request = transcript_dialog()
      request.controller = "first"
      local pending = dialogs:show(request)
      local id = dialogs:snapshot().active.id
      assert(vim.wait(1000, function()
        local view = window:_state().view
        return view and view.dialog_buf ~= nil
          and view.dialog.active.id == id
      end, 5))

      assert(window:select(second))
      local view = window:_state().view
      assert.is_nil(view.dialog)
      assert.is_nil(view.dialog_buf)
      assert.are.equal(id, dialogs:snapshot().active.id)

      assert(window:select(first))
      assert(vim.wait(1000, function()
        return view.dialog_buf ~= nil and view.dialog.active.id == id
      end, 5))
      feed("y")
      assert(vim.wait(1000, function() return pending:is_done() end, 5))
      assert.are.equal("run", pending:result().action)
    end)

  it("fails a dialog when a custom View cannot present it", function()
    local dialogs = require("neoagent.dialog").new()
    local controller = require("neoagent.controller").new({
      name = "headless",
      persistence = {
        enabled = false,
        workspace_settings = false,
        directory = vim.fn.tempname(),
      },
      tools = {},
    })
    controllers = { controller }
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
          if set_dialog_calls > 1 then error("presentation failed") end
        end
      end,
    }
    local window = require("neoagent.window").new({
      controllers = controllers,
      config = config.resolve({}).ui,
      dialogs = dialogs,
      view = function() return view end,
    })
    windows[#windows + 1] = window
    local pending = dialogs:show(transcript_dialog())
    assert(vim.wait(1000, function() return pending:is_done() end, 5))
    assert.are.equal(2, set_dialog_calls)
    assert.is_false(pending:result().ok)
    assert.is_true(pending:result().presenter_unavailable)
  end)
end)
