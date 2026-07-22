local config = require("neoagent.config")
local ui = require("neoagent.ui")

local function text(view)
  local lines = vim.api.nvim_buf_get_lines(view.transcript_buf, 0, -1, false)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    view.transcript_buf, view.namespace, 0, -1, { details = true }
  )) do
    for _, virtual in ipairs(mark[4].virt_lines or {}) do
      lines[#lines + 1] = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, virtual))
    end
  end
  return table.concat(lines, "\n")
end

local function has_line_group(view, name)
  local id = vim.api.nvim_get_hl_id_by_name(name)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.transcript_buf, view.namespace, 0, -1, { details = true })) do
    local group = mark[4].line_hl_group
    if group == name or group == id then return true end
  end
  return false
end

local function line_has_background(view, row)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.transcript_buf, view.namespace, 0, -1, { details = true })) do
    if mark[2] == row and mark[4].line_hl_group then return true end
  end
  return false
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
    local center = assert(ui.layout({
      columns = 100, lines = 40, position = "center", margin = 1,
      input_height = 7, border = "rounded",
    }))
    assert.are.equal(93, center.transcript.width)
    assert.are.equal(2, center.transcript.col)
    assert.are.equal(1, center.transcript.row)
    assert.are.equal(7, center.input.height)
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

  it("closes both windows when either one is closed externally", function()
    local result = view({ position = "center" })
    assert(result:open())
    local transcript, input = result.transcript_win, result.input_win
    vim.api.nvim_win_close(input, true)
    assert(vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(transcript) and not vim.api.nvim_win_is_valid(input)
    end))
    assert.is_false(result:is_open())

    assert(result:open())
    transcript, input = result.transcript_win, result.input_win
    vim.api.nvim_win_close(transcript, true)
    assert(vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(transcript) and not vim.api.nvim_win_is_valid(input)
    end))
    assert.is_false(result:is_open())
  end)

  it("reconciles provider-indexed partial tools without duplicate execution cards", function()
    local result = view({ position = "center" })
    assert(result:open())
    result:apply({ type = "thinking_delta", text = "considering" })
    result:apply({ type = "text_delta", text = "I'll edit." })
    result:apply({ type = "tool_call_delta", index = 2, name = "write", arguments_delta = '{"path":"a' })
    assert(vim.wait(1000, function() return text(result):match("write a") ~= nil end))
    assert.not_matches('"path"', text(result))
    assert.is_true(has_line_group(result, "NeoagentToolPendingBackground"))
    result:apply({ type = "tool_call_delta", index = 2, id = "c1", name = "write_file", arguments_delta = '.txt"}' })
    result:apply({ type = "message_end", message = {
      role = "assistant",
      content = { { type = "thinking", thinking = "considering" }, { type = "text", text = "I'll edit." }, {
        type = "toolCall", id = "c1", name = "write_file", arguments = { path = "a.txt" },
      } },
    } })
    result:apply({ type = "tool_start", call = { id = "c1", name = "write_file", arguments = { path = "a.txt" } } })
    result:apply({ type = "tool_update", call = { id = "c1", name = "write_file" }, result = { content = { { type = "text", text = "working" } } } })
    result:apply({
      type = "tool_end",
      call = { id = "c1", name = "write_file", arguments = { path = "a.txt" } },
      message = {
        role = "toolResult", toolCallId = "c1", toolName = "write_file",
        content = { { type = "text", text = "written" } }, isError = false,
      },
    })
    result:apply({ type = "message_end", message = {
      role = "toolResult", toolCallId = "c1", toolName = "write_file",
      content = { { type = "text", text = "written" } }, isError = false,
    } })
    assert(vim.wait(1000, function() return text(result):match("write a.txt") ~= nil end))
    local transcript = text(result)
    assert.matches("considering", transcript)
    assert.matches("I'll edit", transcript)
    assert.not_matches("written", transcript)
    assert.are.equal(1, select(2, transcript:gsub("write a.txt", "")))
    assert.is_true(has_line_group(result, "NeoagentToolSuccessBackground"))
    assert.is_false(has_line_group(result, "NeoagentToolPendingBackground"))
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
      return rendered:match("approximately 3 bytes") ~= nil and rendered:match("values=%[2 items%]") ~= nil
    end))
    local transcript = text(result)
    assert.matches("inspect it", transcript)
    assert.matches("image attachment: image/png", transcript)
    assert.matches("image attachment: image/jpeg", transcript)
    assert.matches("1=one", transcript)
    assert.not_matches('"values"', transcript)
    assert.matches("read x", transcript)
    assert.matches("write …", transcript)
  end)

  it("renders bundled tools semantically, including output, diffs, and errors", function()
    local result = view({ position = "center" })
    local shell_output = {}
    for index = 1, 12 do shell_output[index] = "shell " .. index end
    result:set_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "read", name = "read_file", arguments = { path = "file.lua", offset = "2", limit = "3" } },
        { type = "toolCall", id = "read-invalid", name = "read_file",
          arguments = { path = { "file.lua" }, offset = 2, limit = { 3 } } },
        { type = "toolCall", id = "shell", name = "shell", arguments = { command = "seq 12" } },
        { type = "toolCall", id = "grep", name = "grep", arguments = { pattern = "needle", path = "lua", glob = "*.lua" } },
        { type = "toolCall", id = "find", name = "find", arguments = { pattern = "*.lua", path = "src" } },
        { type = "toolCall", id = "edit", name = "edit_file", arguments = { path = "file.lua", edits = {} } },
        { type = "toolCall", id = "edit-plain", name = "edit_file", arguments = { path = "plain.lua", edits = {} } },
        { type = "toolCall", id = "edit-error", name = "edit_file", arguments = { path = "bad.lua", edits = {} } },
        { type = "toolCall", id = "custom", name = "custom", arguments = { enabled = true, nested = { value = 1 } } },
      } },
      { role = "toolResult", toolCallId = "read", toolName = "read_file", isError = false,
        content = { { type = "text", text = "two\nthree\nfour" } } },
      { role = "toolResult", toolCallId = "read-invalid", toolName = "read_file", isError = true,
        content = { { type = "text", text = "limit must be a positive integer" } } },
      { role = "toolResult", toolCallId = "shell", toolName = "shell", isError = false,
        content = { { type = "text", text = table.concat(shell_output, "\n") } } },
      { role = "toolResult", toolCallId = "grep", toolName = "grep", isError = false,
        content = { { type = "text", text = "lua/a.lua:1:needle" } } },
      { role = "toolResult", toolCallId = "find", toolName = "find", isError = false,
        content = { { type = "text", text = "src/a.lua" } } },
      { role = "toolResult", toolCallId = "edit", toolName = "edit_file", isError = false,
        content = { { type = "text", text = "edited" } }, details = { diff = " context\n-old\n+new" } },
      { role = "toolResult", toolCallId = "edit-plain", toolName = "edit_file", isError = false,
        content = { { type = "text", text = "edited" } } },
      { role = "toolResult", toolCallId = "edit-error", toolName = "edit_file", isError = true,
        content = { { type = "text", text = "could not edit" } } },
      { role = "toolResult", toolCallId = "custom", toolName = "custom", isError = true,
        content = { { type = "text", text = "custom failed" } } },
      { role = "toolResult", toolCallId = "orphan", toolName = "orphan", isError = false,
        content = { { type = "text", text = "orphan result" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function() return text(result):match("orphan result") ~= nil end))
    local transcript = text(result)
    for _, expected in ipairs({
      "read file%.lua:2%-4", "read %[%d items%] %(offset=2 limit=%[%d items%]%)",
      "limit must be a positive integer", "%$ seq 12", "grep needle in lua %(%*%.lua%)", "find %*%.lua in src",
      "shell 12", "2 more lines", "%-old", "%+new", "could not edit", "custom failed",
      "enabled=true", "nested={…}", "orphan result",
    }) do assert.matches(expected, transcript, expected) end
    assert.is_true(has_line_group(result, "NeoagentToolErrorBackground"))
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    local read_row, next_read_row
    for index, line in ipairs(lines) do
      if line:match("read file%.lua") then read_row = index - 1 end
      if line:match("read %[%d items%]") then next_read_row = index - 1 break end
    end
    local separators = 0
    for row = read_row + 1, next_read_row - 1 do
      if lines[row + 1] == "" and not line_has_background(result, row) then separators = separators + 1 end
    end
    assert.are.equal(1, separators)
  end)

  it("shows escaped partial arguments before tool execution starts", function()
    local result = view({ position = "center" })
    assert(result:open())
    result:apply({
      type = "tool_call_delta", index = 0, name = "shell",
      arguments_delta = '{"command":"printf \\"ok\\"", "other":',
    })
    assert(vim.wait(1000, function() return text(result):match('printf "ok"', 1, true) ~= nil end))
    assert.not_matches("command", text(result))

    local escaped = "$ pwd && printf '\\nTop-level files:\\n' && find ."
    result:apply({
      type = "tool_call_delta", index = 1, name = "shell",
      arguments_delta = [=[{"command":"pwd && printf '\\nTop-level files:\\n' && find .]=],
    })
    assert(vim.wait(1000, function() return text(result):find(escaped, 1, true) ~= nil end))
    result:apply({ type = "tool_call_delta", index = 1, arguments_delta = [["}]] })
    assert(vim.wait(1000, function() return text(result):find(escaped, 1, true) ~= nil end))

    result:apply({
      type = "tool_call_delta", index = 2, name = "shell",
      arguments_delta = [=[{"command":"printf 'one\ntwo'"}]=],
    })
    assert(vim.wait(1000, function() return text(result):find("$ printf 'one\\ntwo'", 1, true) ~= nil end))
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
    assert(vim.wait(1000, function() return text(result):match("broken") ~= nil end))
    assert.matches("broken", text(result))
  end)

  it("collapses read output and expands all returned lines", function()
    local result = view({ position = "center" })
    local lines = {}
    for index = 1, 15 do lines[index] = "line " .. index end
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "read", name = "read_file", arguments = { path = "README.md" },
      } } },
      { role = "toolResult", toolCallId = "read", toolName = "read_file", isError = false,
        content = { { type = "text", text = table.concat(lines, "\n") } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function() return text(result):match("5 more lines") ~= nil end))
    local collapsed = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(collapsed, " line 10 "))
    assert.is_false(vim.tbl_contains(collapsed, " line 11 "))
    result:toggle_tools()
    assert(vim.wait(1000, function()
      return vim.tbl_contains(vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false), " line 15 ")
    end))
    assert.not_matches("more lines", text(result))
  end)

  it("renders compaction summaries as expandable cards", function()
    local result = view({ position = "center" })
    result:set_messages({ {
      role = "compactionSummary",
      summary = "## Goal\nKeep the summary visible",
      tokensBefore = 12345,
    }, {
      role = "assistant",
      content = { { type = "text", text = "retained suffix" } },
    } })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("Compacted from 12,345 tokens (<C-o> to expand)", 1, true) ~= nil
    end))
    assert.matches("%[compaction%]", text(result))
    assert.not_matches("Keep the summary visible", text(result))
    assert.matches("retained suffix", text(result))
    assert.is_true(has_line_group(result, "NeoagentUserBackground"))

    result:toggle_tools()
    assert(vim.wait(1000, function()
      return text(result):find("Keep the summary visible", 1, true) ~= nil
    end))
    assert.not_matches("to expand", text(result))
  end)

  it("uses card backgrounds, inherits the editor background, and animates active states", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "user", content = "hello" } })
    assert(result:open())
    assert.matches("NormalFloat:Normal", vim.wo[result.transcript_win].winhl)
    assert.matches("NormalFloat:Normal", vim.wo[result.input_win].winhl)
    assert.is_not_nil(vim.api.nvim_get_hl(0, { name = "NeoagentUserBackground", link = false }).bg)
    result:set_context({
      state = "compacting",
      thinking = "high",
      context_usage = { used = 250, total = 1000, percent = 25 },
      provider_status = "5h 80% left · weekly 60% left",
      steering = { "check the tests" },
    })
    local title = vim.api.nvim_win_get_config(result.transcript_win).title
    if type(title) == "table" then
      title = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, title))
    end
    assert.matches("think: high", title)
    assert.matches("ctx 250/1k %(25.0%%%)", title)
    assert.is_nil(title:find("Neoagent", 1, true))
    local footer = vim.api.nvim_win_get_config(result.input_win).footer
    if type(footer) == "table" then
      footer = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, footer))
    end
    assert.are.equal(" 5h 80% left · weekly 60% left ", footer)
    assert(vim.wait(1000, function()
      return text(result):find("Steering: check the tests", 1, true) ~= nil
        and text(result):find("<A-Up> to edit queued messages", 1, true) ~= nil
    end))
    result:apply({
      type = "message_end",
      message = { role = "user", content = "check the tests" },
    })
    result:set_context({ steering = {} })
    assert(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
      return vim.tbl_contains(lines, " check the tests ")
        and text(result):find("Steering:", 1, true) == nil
    end))
    result:set_context({ provider_status = false })
    assert.is_nil(vim.api.nvim_win_get_config(result.input_win).footer)
    assert(vim.wait(1000, function() return text(result):match("Compacting%.%.%.") ~= nil end))
    local first = text(result):match("([^\n]+ Compacting%.%.%.)")
    assert(vim.wait(1000, function()
      local current = text(result):match("([^\n]+ Compacting%.%.%.)")
      return current and current ~= first
    end))
    result:set_context({ state = "running" })
    assert(vim.wait(1000, function() return text(result):match("Working%.%.%.") ~= nil end))
    result:set_context({ state = "idle", steering = {} })
    assert(vim.wait(1000, function()
      return text(result):match("Working%.%.%.") == nil
        and text(result):find("Steering:", 1, true) == nil
    end))
  end)

  it("scrolls the transcript after submit and when leaving it", function()
    local function scrolling_view(overrides)
      local submissions = 0
      local result = ui.new({
        config = config.setup({ ui = vim.tbl_extend("force", { position = "center" }, overrides or {}) }).ui,
        on_submit = function()
          submissions = submissions + 1
          return true
        end,
      })
      views[#views + 1] = result
      local lines = {}
      for index = 1, 40 do lines[index] = "line " .. index end
      result:set_messages({ {
        role = "assistant",
        content = { { type = "text", text = table.concat(lines, "\n") } },
      } })
      assert(result:open())
      assert(vim.wait(1000, function()
        return vim.api.nvim_buf_line_count(result.transcript_buf) >= 40
      end))
      return result, function() return submissions end
    end

    local function submit(result)
      result:set_input("send")
      result:focus_input()
      vim.cmd("stopinsert")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    end

    local result, submissions = scrolling_view()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 2, 0 })
    submit(result)
    assert(vim.wait(1000, function() return submissions() == 1 end))
    assert.are.equal(vim.api.nvim_buf_line_count(result.transcript_buf),
      vim.api.nvim_win_get_cursor(result.transcript_win)[1])

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 3, 0 })
    result:focus_input()
    assert.are.equal(vim.api.nvim_buf_line_count(result.transcript_buf),
      vim.api.nvim_win_get_cursor(result.transcript_win)[1])
    result:close()

    local fixed, fixed_submissions = scrolling_view({
      scroll_on_submit = false,
      scroll_on_transcript_leave = false,
    })
    vim.api.nvim_win_set_cursor(fixed.transcript_win, { 2, 0 })
    submit(fixed)
    assert(vim.wait(1000, function() return fixed_submissions() == 1 end))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(fixed.transcript_win)[1])

    fixed:focus_transcript()
    vim.api.nvim_win_set_cursor(fixed.transcript_win, { 3, 0 })
    fixed:focus_input()
    assert.are.equal(3, vim.api.nvim_win_get_cursor(fixed.transcript_win)[1])
  end)

  it("scrolls the transcript after it is hidden and shown again", function()
    local lines = {}
    for index = 1, 40 do lines[index] = "line " .. index end
    local messages = { {
      role = "assistant",
      content = { { type = "text", text = table.concat(lines, "\n") } },
    } }
    local function open_at_line(overrides, line)
      local result = view(vim.tbl_extend("force", { position = "center" }, overrides or {}))
      result:set_messages(messages)
      assert(result:open())
      assert(vim.wait(1000, function()
        return vim.api.nvim_buf_line_count(result.transcript_buf) >= 40
      end))
      vim.api.nvim_win_set_cursor(result.transcript_win, { line, 0 })
      result:close()
      assert(result:open())
      return result
    end

    local result = open_at_line(nil, 2)
    assert.are.equal(vim.api.nvim_buf_line_count(result.transcript_buf),
      vim.api.nvim_win_get_cursor(result.transcript_win)[1])

    local fixed = open_at_line({ scroll_on_reopen = false }, 3)
    assert.are.equal(3, vim.api.nvim_win_get_cursor(fixed.transcript_win)[1])
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

  it("keeps indexed assistant text deltas in separate live blocks", function()
    local result = view({ position = "center" })
    assert(result:open())
    result:apply({ type = "text_delta", index = 0, phase = "commentary", text = "checking" })
    result:apply({ type = "text_delta", index = 1, phase = "final_answer", text = "done" })
    result:apply({ type = "message_end", message = {
      role = "assistant",
      content = {
        { type = "text", index = 0, phase = "commentary", text = "checking" },
        { type = "text", index = 1, phase = "final_answer", text = "done" },
      },
    } })
    assert(vim.wait(1000, function()
      return text(result):find(" checking\n\n done", 1, true) ~= nil
    end))
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
