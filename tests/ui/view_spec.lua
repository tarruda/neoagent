local config = require("neoagent.config")
local ui = require("neoagent.ui")

local function text(view)
  return table.concat(vim.api.nvim_buf_get_lines(view.transcript_buf, 0, -1, false), "\n")
end

describe("neoagent.ui", function()
  local views = {}
  before_each(function()
    config._reset()
    vim.o.columns = 120
    vim.o.lines = 40
  end)
  after_each(function()
    for _, view in ipairs(views) do view:destroy() end
    views = {}
    vim.cmd("silent! only")
  end)

  local function view(overrides)
    local ui_config = config.setup({ ui = overrides or {} }).ui
    local result = ui.new({ config = ui_config })
    views[#views + 1] = result
    return result
  end

  it("calculates docked and centered sibling geometry", function()
    local right = assert(ui.layout({ columns = 100, lines = 40, position = "right", margin = 1, input_height = 5, border = "rounded" }))
    assert.are.equal(43, right.transcript.width)
    assert.are.equal(54, right.transcript.col)
    assert.are.equal(right.transcript.row + right.transcript.height + 2, right.input.row)
    local top = assert(ui.layout({
      columns = 100, lines = 40, position = "top", width = 0.5, height = 20,
      margin = 1, input_height = 5, border = "rounded",
    }))
    assert.are.equal(48, top.transcript.width)
    assert.are.equal(1, top.transcript.row)
    local bottom = assert(ui.layout({
      columns = 100, lines = 40, position = "bottom", width = 60, height = 20,
      margin = 1, input_height = 5, border = "rounded",
    }))
    assert.are.equal(58, bottom.transcript.width)
    assert.is_true(bottom.transcript.row > top.transcript.row)
    local center = assert(ui.layout({ columns = 100, lines = 40, position = "center", margin = 1, input_height = 5, border = "rounded" }))
    assert.is_true(center.transcript.col > 1)
    assert.is_true(center.transcript.row > 1)
    local too_small, err = ui.layout({ columns = 4, lines = 4, position = "right", margin = 1, input_height = 5, border = "rounded" })
    assert.is_nil(too_small)
    assert.matches("does not fit", err)
  end)

  it("opens ordinary focusable buffers and preserves the draft across close", function()
    local origin = vim.api.nvim_get_current_win()
    local result = view({ position = "center" })
    assert(result:open())
    assert.is_true(result:is_open())
    assert.are.equal(result.input_win, vim.api.nvim_get_current_win())
    assert.are.equal("nofile", vim.bo[result.transcript_buf].buftype)
    assert.is_false(vim.bo[result.transcript_buf].modifiable)
    result:set_input("one\ntwo")
    result:focus_transcript()
    assert.are.equal(result.transcript_win, vim.api.nvim_get_current_win())
    result:focus_input()
    assert.are.equal(result.input_win, vim.api.nvim_get_current_win())
    result:close()
    assert.are.equal(origin, vim.api.nvim_get_current_win())
    assert.are.equal("one\ntwo", result:get_input())
    assert(result:open())
    assert.are.equal("one\ntwo", result:get_input())
  end)

  it("renders partial tools and execution state dynamically without duplicate results", function()
    local result = view({ position = "center" })
    assert(result:open())
    result:apply({ type = "thinking_delta", text = "considering" })
    result:apply({ type = "text_delta", text = "I'll edit." })
    result:apply({ type = "tool_call_delta", index = 0, name = "write", arguments_delta = '{"path":"a' })
    assert(vim.wait(1000, function() return text(result):match("receiving") ~= nil end))
    assert.matches('"path":"a', text(result))
    result:apply({ type = "tool_call_delta", index = 0, id = "c1", name = "write_file", arguments_delta = '.txt"}' })
    result:apply({ type = "message_end", message = {
      role = "assistant",
      content = { { type = "thinking", thinking = "considering" }, { type = "text", text = "I'll edit." }, {
        type = "toolCall", id = "c1", name = "write_file", arguments = { path = "a.txt" },
      } },
    } })
    result:apply({ type = "tool_start", call = { id = "c1", name = "write_file", arguments = { path = "a.txt" } } })
    result:apply({ type = "tool_update", call = { id = "c1", name = "write_file" }, result = { content = { { type = "text", text = "working" } } } })
    result:apply({ type = "tool_end", call = { id = "c1", name = "write_file" }, message = {
      role = "toolResult", toolCallId = "c1", toolName = "write_file",
      content = { { type = "text", text = "written" } }, isError = false,
    } })
    result:apply({ type = "message_end", message = {
      role = "toolResult", toolCallId = "c1", toolName = "write_file",
      content = { { type = "text", text = "written" } }, isError = false,
    } })
    assert(vim.wait(1000, function() return text(result):match("✓ write_file") ~= nil end))
    local transcript = text(result)
    assert.matches("Thinking\nconsidering", transcript)
    assert.matches("Assistant\nI'll edit", transcript)
    assert.matches('"path": "a.txt"', transcript)
    assert.are.equal(1, select(2, transcript:gsub("✓ write_file", "")))
    local marks = vim.api.nvim_buf_get_extmarks(result.transcript_buf, result.namespace, 0, -1, {})
    assert.is_true(#marks >= 3)
  end)

  it("renders attachments, structured arguments, and unannounced tool events", function()
    local result = view({ position = "center" })
    result:set_messages({
      { role = "user", content = {
        { type = "text", text = "look" },
        { type = "image", mimeType = "image/png", data = "AAAA" },
      } },
      { role = "assistant", content = {
        { type = "thinking", thinking = "inspect it" },
        { type = "toolCall", id = "history", name = "inspect", arguments = { "one", "two" } },
      } },
      { role = "toolResult", toolCallId = "history", toolName = "inspect", content = {
        { type = "image", mimeType = "image/jpeg", data = "BBBB" },
      } },
    })
    assert(result:open())
    result:apply({ type = "message_end", message = {
      role = "assistant",
      content = { { type = "toolCall", id = "complete", name = "replace", arguments = {
        values = { "first", string.rep("x", 5000) },
      } } },
    } })
    result:apply({ type = "tool_start", call = { id = "start-only", name = "read", arguments = { path = "x" } } })
    result:apply({ type = "tool_end", call = { id = "end-only", name = "write" }, message = {
      role = "toolResult", toolCallId = "end-only", toolName = "write",
      content = { { type = "text", text = "done" } }, isError = false,
    } })
    assert(vim.wait(1000, function()
      local rendered = text(result)
      return rendered:match("approximately 3 bytes") ~= nil and rendered:match("%[omitted%]") ~= nil
    end))
    local transcript = text(result)
    assert.matches("Thinking\ninspect it", transcript)
    assert.matches("image attachment: image/png", transcript)
    assert.matches("image attachment: image/jpeg", transcript)
    assert.matches("%[\n%s+\"one\"", transcript)
    assert.matches("%[omitted%]", transcript)
    assert.matches("● read  running", transcript)
    assert.matches("✓ write", transcript)
  end)

  it("reconstructs history, reports failures, and docks in place", function()
    local result = view({ position = "right" })
    result:set_messages({
      { role = "user", content = "hello" },
      { role = "assistant", content = { { type = "text", text = "hi" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function() return text(result):match("hello") ~= nil end))
    local right = vim.api.nvim_win_get_config(result.transcript_win)
    result:set_position("left")
    local left = vim.api.nvim_win_get_config(result.transcript_win)
    assert.is_true(left.col < right.col)
    result:finish({ ok = false, error = { kind = "model", message = "broken" } })
    assert(vim.wait(1000, function() return text(result):match("Failed") ~= nil end))
    assert.matches("broken", text(result))
  end)

  it("places auto UI over another editor window", function()
    local origin = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(origin)
    local result = view({ position = "auto", margin = 1 })
    assert(result:open(origin))
    local other_pos = vim.api.nvim_win_get_position(other)
    local cfg = vim.api.nvim_win_get_config(result.transcript_win)
    assert.is_true(cfg.col >= other_pos[2])
    assert.is_true(cfg.width <= vim.api.nvim_win_get_width(other))
  end)

  it("preserves transcript selection while appending and responds to resize", function()
    local result = view({ position = "center" })
    result:set_messages({
      { role = "user", content = "select this\nsecond line" },
      { role = "assistant", content = { { type = "text", text = "existing" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function() return text(result):match("second line") ~= nil end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 2, 0 })
    vim.cmd("normal! Vj")
    local mode = vim.api.nvim_get_mode().mode
    local cursor = vim.api.nvim_win_get_cursor(result.transcript_win)
    local anchor = vim.fn.getpos("v")
    result:apply({ type = "text_delta", text = "streamed later" })
    assert(vim.wait(1000, function() return text(result):match("streamed later") ~= nil end))
    assert.are.equal(mode, vim.api.nvim_get_mode().mode)
    assert.are.same(cursor, vim.api.nvim_win_get_cursor(result.transcript_win))
    assert.are.same(anchor, vim.fn.getpos("v"))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    local old_width = vim.api.nvim_win_get_width(result.transcript_win)
    vim.o.columns = 90
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(vim.wait(1000, function()
      return vim.api.nvim_win_get_width(result.transcript_win) ~= old_width
    end))
  end)

end)
