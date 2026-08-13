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
  local normal_highlight
  before_each(function()
    normal_highlight = vim.api.nvim_get_hl(0, {
      name = "Normal", link = true,
    })
    config._reset()
    vim.o.columns = 120
    vim.o.lines = 40
  end)
  after_each(function()
    for _, view in ipairs(views) do view:destroy() end
    views = {}
    vim.cmd("silent! only")
    vim.api.nvim_set_hl(0, "Normal", normal_highlight)
  end)

  local function view(overrides, tools)
    local ui_config = config.setup({
      ui = vim.tbl_extend("force", { style = "pi" }, overrides or {}),
    }).ui
    local lookup = {}
    for _, tool in ipairs(tools or {}) do lookup[tool.name] = tool end
    local result = ui.new({
      config = ui_config,
      resolve_tool = function(name) return lookup[name] end,
    })
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

  it("uses configured border characters in the transcript footer", function()
    local cases = {
      { border = { "a", "b", "c", "d", "e", { "B", "NeoagentBorder" } }, expected = "B" },
      { border = "double", expected = "═" },
      { border = "solid", expected = " " },
    }
    for _, case in ipairs(cases) do
      local result = view({ border = case.border })
      local border = {}
      for _, chunk in ipairs(result:_transcript_footer(20)) do
        if chunk[2] == "NeoagentBorder" then border[#border + 1] = chunk[1] end
      end
      local rendered = table.concat(border)
      assert.is_true(#rendered > 0)
      assert.are.equal(case.expected, vim.fn.strcharpart(rendered, 0, 1))
    end
  end)

  it("builds a bounded input footer from configured mappings", function()
    local result = view({ mappings = {
      select_history = { "<C-r>", "<C-s>" },
      resume_session = "<A-r>",
      select_model = "<A-m>",
      interrupt = false,
    } })
    assert.are.equal(" <C-r> history · <A-r> resume · <A-m> select model ",
      result:_input_footer(80))
    local narrow = result:_input_footer(18)
    assert.is_true(vim.fn.strdisplaywidth(narrow) <= 18)
    assert.matches("^ <C%-r>", narrow)
    assert.is_not_nil(narrow:find("<C%-r> history"))
    assert.is_nil(narrow:find("select model", 1, true))
  end)

  it("updates input mapping hints for the focused surface", function()
    local result = view({ position = "center" })
    result:set_messages({
      { role = "user", content = "first" },
      { role = "assistant", content = {
        { type = "text", text = "latest" },
      } },
    })
    assert(result:open())
    local function footer()
      local value = vim.api.nvim_win_get_config(result.input_win).footer
      if type(value) == "table" then
        value = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, value))
      end
      return value
    end
    assert(vim.wait(1000, function()
      return footer()
        == " <C-r> history · <A-r> resume · <A-m> select model · <C-c> clear/cancel "
    end))

    vim.cmd("stopinsert")
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = result.input_buf })
    assert(vim.wait(1000, function()
      return footer()
        == " <C-r> history · <A-r> resume · <A-m> select model · <C-c> clear/cancel "
    end))

    result:focus_transcript()
    local row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("first", 1, true) then row = index break end
    end
    vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = result.transcript_buf,
    })
    assert(vim.wait(1000, function()
      return footer()
        == " <CR> details · <A-r> resume · <A-m> select model · <C-c> clear/cancel "
    end))
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

  it("reconciles finalized reasoning blocks with streamed thinking", function()
    local result = view({ position = "center" })
    assert(result:open())
    result:apply({ type = "thinking_delta", index = 0, text = "first" })
    result:apply({ type = "thinking_delta", index = 1, text = "second" })
    result:apply({ type = "message_end", message = {
      role = "assistant",
      content = {
        { type = "thinking", index = 0, thinking = "first summary" },
        { type = "thinking", index = 1, thinking = "second summary" },
      },
    } })

    assert(vim.wait(1000, function()
      return text(result):find("second summary", 1, true) ~= nil
    end))
    local transcript = text(result)
    assert.matches("first summary", transcript)
    assert.matches("second summary", transcript)
    assert.matches("first summary.-" .. "\n" .. ".-second summary", transcript)
  end)

  it("can hide historical and streaming thinking from the transcript", function()
    local result = view({ position = "center", show_thinking = false })
    result:set_messages({ {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "historical private trace" },
        { type = "text", text = "historical visible answer" },
      },
    } })
    assert(result:open())
    result:apply({ type = "thinking_delta", text = "streaming private trace" })
    result:apply({ type = "message_end", message = {
      role = "assistant",
      content = { { type = "thinking", thinking = "final private trace" } },
    } })

    assert(vim.wait(1000, function() return not result.flush_pending end))
    local transcript = text(result)
    assert.matches("historical visible answer", transcript)
    assert.not_matches("historical private trace", transcript)
    assert.not_matches("streaming private trace", transcript)
    assert.not_matches("final private trace", transcript)
    assert.are.equal("final private trace",
      result.messages[2].content[1].thinking)
  end)

  it("uses structural spacing for provider prose ending in linefeeds", function()
    local result = view({ position = "center" })
    assert(result:open())
    result:set_messages({ {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "considering\n" },
        { type = "text", text = "done\n\n" },
      },
    } })

    assert(vim.wait(1000, function() return not result.flush_pending end))
    assert.are.same({ " considering ", "", " done ", "" },
      vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false))
  end)

  it("omits whitespace-only prose between thinking and tools", function()
    local result = view({ position = "center" })
    assert(result:open())
    result:set_messages({ {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "considering" },
        { type = "text", text = "\n\n" },
        { type = "toolCall", id = "c1", name = "read_file", arguments = { path = "x" } },
      },
    } })

    assert(vim.wait(1000, function() return not result.flush_pending end))
    assert.are.same({ " considering ", "", "", "", " read x ", "", "" },
      vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false))
  end)

  it("clips thinking cards to the latest lines and reveals full traces", function()
    local result = view({ position = "center" })
    local trace = {}
    for index = 1, 14 do trace[index] = "trace " .. index end
    result:set_messages({ {
      role = "assistant",
      content = { { type = "thinking", thinking = table.concat(trace, "\n") } },
    } })
    assert(result:open())
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return transcript:find(" trace 14 ", 1, true) ~= nil
        and transcript:find(" trace 1 ", 1, true) == nil
    end))
    local collapsed = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(collapsed, " trace 14 "))
    assert.is_false(vim.tbl_contains(collapsed, " trace 1 "))
    assert.is_false(has_line_group(result, "NeoagentUserBackground"))
    assert.is_false(has_line_group(result, "NeoagentToolPendingBackground"))

    result:focus_transcript()
    local row
    for index, line in ipairs(collapsed) do
      if line:find("trace 14", 1, true) then row = index break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local badge
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then badge = chunk[1] end
      end
    end
    assert.are.equal("[thinking: 28 words, 4 lines above..., <CR> to expand]", badge)
    assert.is_true(result:show_card_details())
    local details = vim.api.nvim_buf_get_lines(result.details_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(details, "trace 1"))
    assert.is_true(vim.tbl_contains(details, "trace 14"))
    result:_close_card_details(true)
  end)

  it("shows the thinking badge only while hovered", function()
    local result = view({ position = "center" })
    local trace = {}
    for index = 1, 14 do trace[index] = "trace " .. index end
    result:set_messages({ { role = "assistant", content = {
      { type = "thinking", thinking = table.concat(trace, "\n") },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    local function buffer_text()
      return table.concat(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false), "\n")
    end
    assert.is_nil(buffer_text():find("thinking:", 1, true))
    result:focus_transcript()
    local row
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    for index, line in ipairs(lines) do
      if line:find("trace 14", 1, true) then row = index break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local badge, badge_col
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then
          badge = chunk[1]
          badge_col = mark[4].virt_text_win_col
        end
      end
    end
    assert.are.equal("[thinking: 28 words, 4 lines above..., <CR> to expand]", badge)
    local width = vim.api.nvim_win_get_width(result.transcript_win)
    assert.are.equal(width - 1 - #badge, badge_col)
    assert.is_nil(buffer_text():find("thinking:", 1, true))
    local count = vim.api.nvim_buf_line_count(result.transcript_buf)
    vim.api.nvim_win_set_cursor(result.transcript_win, { count, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        assert.is_nil(chunk[1]:find("[thinking:", 1, true))
      end
    end
  end)

  it("scrolls thinking cards to the latest streamed lines", function()
    local result = view({ position = "center" })
    assert(result:open())
    for index = 1, 25 do
      result:apply({ type = "thinking_delta", text = "line " .. index .. "\n" })
    end
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return transcript:find("line 25", 1, true) ~= nil
        and transcript:find("line 15", 1, true) == nil
    end))
  end)

  it("keeps long text card lines intact for soft wrapping", function()
    local result = view({ position = "center" })
    local long = "soft wrap " .. string.rep("segment ", 30)
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = long },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("segment segment segment", 1, true) ~= nil
    end))
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " " .. long .. " "))
    assert.is_true(vim.wo[result.transcript_win].wrap)
  end)

  it("soft-wraps long user card lines", function()
    local result = view({ position = "center" })
    local long = "user wrap " .. string.rep("segment ", 30)
    result:set_messages({ { role = "user", content = long } })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("segment segment segment", 1, true) ~= nil
    end))
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " " .. long .. " "))
  end)

  it("places the bottom rule below a wrapped text card last line", function()
    local result = view({ position = "center" })
    local long = "ending " .. string.rep("word ", 60)
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = "short\n" .. long },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local bottom
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("╰", 1, true) then bottom = chunk[1] end
      end
    end
    assert.is_not_nil(bottom)
    assert.matches("╯$", bottom)
  end)

  it("keeps highlighted assistant content across the complete card", function()
    local result = view({ position = "center" })
    local response = {}
    for index = 1, 105 do response[index] = "line " .. index end
    response[#response + 1] = "**bold end**"
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = table.concat(response, "\n") },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return transcript:find("bold end", 1, true) ~= nil
        and transcript:find(" line 1 ", 1, true) ~= nil
    end))
  end)

  it("never enters insert mode in the transcript or card details", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = "content" },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    vim.api.nvim_feedkeys("i", "x", false)
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    assert.is_true(result:show_card_details())
    assert.are.equal(result.details_win, vim.api.nvim_get_current_win())
    vim.api.nvim_feedkeys("i", "x", false)
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
    result:_close_card_details(true)
  end)

  it("badges complete text cards with word counts on hover", function()
    local result = view({ position = "center" })
    local response = {}
    for index = 1, 60 do response[index] = "response line " .. index end
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = table.concat(response, "\n") },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local badge_text
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[text:", 1, true) then badge_text = chunk[1] end
      end
    end
    assert.are.equal(
      "[text: 180 words, <CR> to expand]", badge_text)
  end)

  it("shows complete assistant cards and expands to unpadded text", function()
    local result = view({ position = "center" })
    local response = {}
    for index = 1, 105 do response[index] = "response line " .. index end
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = table.concat(response, "\n") },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return transcript:find(" response line 105 ", 1, true) ~= nil
        and transcript:find(" response line 1 ", 1, true) ~= nil
    end))
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, " response line 105 "))
    assert.is_true(vim.tbl_contains(lines, " response line 1 "))
    result:focus_transcript()
    local row
    for index, line in ipairs(lines) do
      if line:find("response line 105", 1, true) then row = index break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
    assert.is_true(result:show_card_details())
    local details = vim.api.nvim_buf_get_lines(result.details_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(details, "response line 1"))
    assert.is_false(vim.tbl_contains(details, " response line 1 "))
    result:_close_card_details(true)
  end)

  it("keeps complete assistant cards after a height change", function()
    local result = view({ position = "center" })
    local response = {}
    for index = 1, 60 do response[index] = "response line " .. index end
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = table.concat(response, "\n") },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return transcript:find(" response line 1 ", 1, true) ~= nil
        and transcript:find(" response line 60 ", 1, true) ~= nil
    end))
    vim.o.lines = 60
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return vim.api.nvim_win_get_height(result.transcript_win) > 40
        and transcript:find(" response line 1 ", 1, true) ~= nil
        and transcript:find(" response line 60 ", 1, true) ~= nil
    end))
  end)

  it("uses singular labels for a single clipped thinking or tool line", function()
    local result = view({ position = "center" })
    local lines = {}
    for index = 1, 11 do lines[index] = "trace " .. index end
    result:set_messages({
      { role = "assistant", content = {
        { type = "thinking", thinking = table.concat(lines, "\n") },
        { type = "toolCall", id = "w", name = "write_file",
          arguments = { path = "x", content = table.concat(lines, "\n") } },
      } },
      { role = "toolResult", toolCallId = "w", toolName = "write_file",
        isError = false, content = { { type = "text", text = "ok" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return transcript:find("[... 1 more line]", 1, true) ~= nil
        and transcript:find("trace 2", 1, true) ~= nil
    end))
    result:focus_transcript()
    local row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("trace 2", 1, true) then row = index break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local badge
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then badge = chunk[1] end
      end
    end
    assert.are.equal("[thinking: 22 words, 1 line above..., <CR> to expand]", badge)
  end)

  it("rests a borderless overflow banner on width-clipped thinking cards", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "assistant", content = {
      { type = "thinking", thinking = string.rep("x", 300) .. "\nshort" },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    local function buffer_text()
      return table.concat(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false), "\n")
    end
    local function outline_marks()
      return vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.card_namespace, 0, -1, { details = true })
    end
    assert.is_true(buffer_text():find("short", 1, true) ~= nil)
    assert.is_nil(buffer_text():find("thinking:", 1, true))
    local badge, ellipsis, badge_col, ellipsis_col
    for _, mark in ipairs(outline_marks()) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then
          badge = chunk[1]
          badge_col = mark[4].virt_text_win_col or 0
        elseif chunk[1] == "..." then
          ellipsis = chunk[1]
          ellipsis_col = mark[4].virt_text_win_col or 0
        end
      end
      assert.is_nil(mark[4].virt_lines)
    end
    assert.are.equal("[thinking: 2 words]", badge)
    assert.are.equal("...", ellipsis)
    assert.are.equal(badge_col, ellipsis_col)
    local width = vim.api.nvim_win_get_width(result.transcript_win)
    assert.are.equal(width - 1 - #badge, badge_col + 3)
    local borders = table.concat(vim.tbl_map(function(mark)
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end,
        mark[4].virt_text or {}))
    end, outline_marks()))
    assert.is_nil(borders:find("╭", 1, true))
    assert.is_nil(borders:find("╰", 1, true))

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local hover_badge, hover_border
    for _, mark in ipairs(outline_marks()) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then hover_badge = chunk[1] end
        if chunk[1]:find("╭", 1, true) then hover_border = chunk[1] end
      end
    end
    assert.are.equal("[thinking: 2 words, <CR> to expand]", hover_badge)
    assert.are.equal("╭", hover_border)
    result:focus_input()
    local resting_badge, resting_border
    for _, mark in ipairs(outline_marks()) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then resting_badge = chunk[1] end
        if chunk[1]:find("╭", 1, true) then resting_border = chunk[1] end
      end
    end
    assert.are.equal("[thinking: 2 words]", resting_badge)
    assert.is_nil(resting_border)
  end)

  it("keeps clipped thinking badges hover-only when every line fits", function()
    local result = view({ position = "center" })
    local trace = {}
    for index = 1, 14 do trace[index] = "trace " .. index end
    result:set_messages({ { role = "assistant", content = {
      { type = "thinking", thinking = table.concat(trace, "\n") },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    local marks = vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true })
    assert.are.same({}, marks)
    result:focus_transcript()
    local row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("trace 14", 1, true) then row = index break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local badge
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then badge = chunk[1] end
      end
    end
    assert.are.equal("[thinking: 28 words, 4 lines above..., <CR> to expand]", badge)
  end)

  it("badges long thinking traces on hover", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "assistant", content = {
      { type = "thinking", thinking = string.rep("x", 300) .. "\nshort" },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return transcript:find("short", 1, true) ~= nil
        and transcript:find("thinking:", 1, true) == nil
    end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local badge, ellipsis
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then badge = chunk[1] end
        if chunk[1] == "..." then ellipsis = chunk[1] end
      end
    end
    assert.are.equal("[thinking: 2 words, <CR> to expand]", badge)
    assert.are.equal("...", ellipsis)
  end)

  it("truncates long traces for the right-aligned thinking badge on hover", function()
    local result = view({ position = "center" })
    local trace = "Let me read the README and key source files to understand the project"
      .. " structure and how they fit"
    result:set_messages({ { role = "assistant", content = {
      { type = "thinking", thinking = trace .. "\nline two" },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    local function buffer_lines()
      return vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    end
    local function outline_marks()
      return vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.card_namespace, 0, -1, { details = true })
    end
    result:focus_transcript()
    local first_row
    local lines = buffer_lines()
    for row, line in ipairs(lines) do
      if line:find("Let me read", 1, true) then first_row = row - 1 break end
    end
    assert.is_not_nil(first_row)
    for _, line in ipairs(buffer_lines()) do
      assert.is_nil(line:find("thinking:", 1, true))
    end
    vim.api.nvim_win_set_cursor(result.transcript_win, { first_row + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local header, header_col, ellipsis, ellipsis_col
    for _, mark in ipairs(outline_marks()) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then
          header = chunk[1]
          header_col = mark[4].virt_text_win_col or 0
        elseif chunk[1] == "..." then
          ellipsis = chunk[1]
          ellipsis_col = mark[4].virt_text_win_col or 0
        end
      end
    end
    assert.are.equal("[thinking: 20 words, <CR> to expand]", header)
    local width = vim.api.nvim_win_get_width(result.transcript_win)
    assert.are.equal(width - 1 - #header, header_col)
    assert.are.equal("...", ellipsis)
    assert.are.equal(header_col - 3, ellipsis_col)
    local borders = table.concat(vim.tbl_map(function(mark)
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end,
        mark[4].virt_text or {}))
    end, outline_marks()))
    for _, mark in ipairs(outline_marks()) do
      assert.is_nil(mark[4].virt_lines)
    end
    assert.matches("╭", borders)
    assert.matches("╰", borders)
    assert.is_nil(borders:find("│", 1, true))
    for _, line in ipairs(buffer_lines()) do
      assert.is_nil(line:find("thinking:", 1, true))
    end
    local count = vim.api.nvim_buf_line_count(result.transcript_buf)
    vim.api.nvim_win_set_cursor(result.transcript_win, { count, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    for _, mark in ipairs(outline_marks()) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        assert.is_nil(chunk[1]:find("thinking:", 1, true))
      end
    end
  end)

  it("keeps short traces intact with the thinking badge on hover", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "assistant", content = {
      { type = "thinking", thinking = "line one\nline two" },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    local first_row
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    for row, line in ipairs(lines) do
      if line:find("line one", 1, true) then first_row = row - 1 break end
    end
    assert.is_not_nil(first_row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { first_row + 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local header, ellipsis
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("[thinking:", 1, true) then header = chunk[1] end
        if chunk[1] == "..." then ellipsis = chunk[1] end
      end
    end
    assert.are.equal("[thinking: 4 words, <CR> to expand]", header)
    assert.is_nil(ellipsis)
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
      content = {
        { type = "thinking", thinking = "considering" },
        { type = "thinking", index = 1, thinking = "unstreamed reasoning" },
        { type = "text", text = "I'll edit." },
        { type = "toolCall", id = "c1", name = "write_file", arguments = { path = "a.txt" } },
      },
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
    assert.matches("unstreamed reasoning", transcript)
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

  it("switches live between Pi and grouped Codex transcript styles", function()
    local result = view({ position = "center", width = 52 })
    result:set_messages({
      {
        role = "compactionSummary",
        summary = "Earlier work",
        tokensBefore = 100,
      },
      { role = "assistant", content = {
        { type = "thinking", thinking = "I will inspect the files." },
        { type = "text", text = "Starting the inspection." },
        { type = "toolCall", id = "read-style", name = "read_file",
          arguments = { path = "README.md" } },
        { type = "toolCall", id = "grep-style", name = "grep",
          arguments = { pattern = "Neoagent", path = "." } },
      } },
      { role = "toolResult", toolCallId = "read-style",
        toolName = "read_file", isError = false,
        content = { { type = "text", text = "contents" } } },
      { role = "toolResult", toolCallId = "grep-style",
        toolName = "grep", isError = false,
        content = { { type = "text", text = "README.md:1:Neoagent" } } },
      { role = "assistant", content = {
        { type = "text", text = "The inspection is complete." },
      } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("The inspection is complete.", 1, true) ~= nil
    end))

    local function separator_count()
      local count = 0
      for _, line in ipairs(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false)) do
        if line:find("────", 1, true) then count = count + 1 end
      end
      return count
    end

    assert.are.equal("pi", result.config.style)
    assert.are.equal(0, separator_count())
    assert.not_matches("• read README%.md", text(result))
    assert.is_true(has_line_group(result, "NeoagentUserBackground"))
    assert.is_true(has_line_group(result, "NeoagentToolSuccessBackground"))

    assert.are.equal("codex", result:set_style("codex"))
    assert(vim.wait(1000, function()
      return text(result):find("• read README.md", 1, true) ~= nil
    end))
    assert.are.equal(2, separator_count())
    assert.matches("• grep Neoagent in %.", text(result))
    assert.is_false(has_line_group(result, "NeoagentUserBackground"))
    assert.is_false(has_line_group(result, "NeoagentToolSuccessBackground"))

    assert.are.equal("pi", result:set_style("pi"))
    assert(vim.wait(1000, function()
      return text(result):find("• read README.md", 1, true) == nil
    end))
    assert.are.equal(0, separator_count())
    assert.is_true(has_line_group(result, "NeoagentUserBackground"))
    assert.is_true(has_line_group(result, "NeoagentToolSuccessBackground"))
    local selected, err = result:set_style("other")
    assert.is_nil(selected)
    assert.are.equal("transcript style must be pi or codex", err.message)
  end)

  it("places Codex separators against tools with prose-side spacing", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.update_plan").new(),
      require("neoagent.tools.shell").new(),
    })
    local plan = {
      { step = "Item 1", status = "pending" },
      { step = "Item 2", status = "pending" },
      { step = "Item 3", status = "pending" },
      { step = "Item 4", status = "pending" },
    }
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "plan-boundary", name = "update_plan",
        arguments = { plan = plan },
      } } },
      { role = "toolResult", toolCallId = "plan-boundary",
        toolName = "update_plan", isError = false,
        content = { { type = "text", text = "Plan updated" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("Item 4", 1, true) ~= nil
    end))
    result:apply({ type = "message_end", message = {
      role = "assistant", content = {
        { type = "thinking", thinking = "Let me start by looking ..." },
        { type = "toolCall", id = "shell-boundary", name = "shell",
          arguments = { command = "rg -n needle" } },
      },
    } })
    result:apply({ type = "tool_end", call = {
      id = "shell-boundary", name = "shell",
      arguments = { command = "rg -n needle" },
    }, message = {
      role = "toolResult", toolCallId = "shell-boundary",
      toolName = "shell", isError = false,
      content = { { type = "text", text = "match" } },
    } })
    assert(vim.wait(1000, function()
      return text(result):find("• Ran rg -n needle", 1, true) ~= nil
    end))

    local lines = vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)
    local item, thinking, shell
    for index, line in ipairs(lines) do
      if line:find("Item 4", 1, true) then item = index end
      if line:find("Let me start", 1, true) then thinking = index end
      if line:find("• Ran rg -n needle", 1, true) then shell = index end
    end
    assert.is_not_nil(item)
    assert.is_not_nil(thinking)
    assert.is_not_nil(shell)
    assert.matches("────", lines[item + 1])
    assert.are.equal("", lines[item + 2])
    assert.are.equal(thinking, item + 3)
    assert.are.equal("", lines[thinking + 1])
    assert.matches("────", lines[thinking + 2])
    assert.are.equal(shell, thinking + 3)
  end)

  it("keeps streamed parallel Codex tools on separate card rows", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.shell").new(),
    })
    assert(result:open())
    result:apply({
      type = "tool_call_delta", index = 0, id = "parallel-one",
      name = "shell", arguments_delta = '{"command":"printf one"}',
    })
    assert(vim.wait(1000, function()
      return text(result):find("• Running printf one", 1, true) ~= nil
    end))
    result:apply({
      type = "tool_call_delta", index = 1, id = "parallel-two",
      name = "shell", arguments_delta = '{"command":"printf two"}',
    })
    assert(vim.wait(1000, function()
      return text(result):find("• Running printf two", 1, true) ~= nil
    end))

    local function assert_separate(first_label, second_label)
      local lines = vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false)
      local first, second
      for row, line in ipairs(lines) do
        if line:find(first_label, 1, true) then first = row end
        if line:find(second_label, 1, true) then second = row end
      end
      assert.is_not_nil(first)
      assert.is_not_nil(second)
      assert.is_true(first < second)
      assert.are.equal("", lines[second - 1])
    end
    assert_separate("• Running printf one", "• Running printf two")

    local calls = {
      { type = "toolCall", id = "parallel-one", name = "shell",
        arguments = { command = "printf one" } },
      { type = "toolCall", id = "parallel-two", name = "shell",
        arguments = { command = "printf two" } },
    }
    result:apply({ type = "message_end", message = {
      role = "assistant", content = calls,
    } })
    assert(vim.wait(1000, function()
      return not result.flush_pending
    end))
    assert_separate("• Running printf one", "• Running printf two")

    for _, call in ipairs(calls) do
      result:apply({ type = "tool_end", call = call, message = {
        role = "toolResult", toolCallId = call.id, toolName = "shell",
        isError = false, content = { { type = "text", text = "ok" } },
      } })
    end
    assert(vim.wait(1000, function()
      return text(result):find("• Ran printf two", 1, true) ~= nil
    end))
    assert_separate("• Ran printf one", "• Ran printf two")
  end)

  it("keeps prose before parallel Codex tools as siblings finish", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.shell").new(),
    })
    assert(result:open())
    result:apply({
      type = "text_delta", index = 0,
      text = "Let me start by exploring the server flags.",
    })
    assert(vim.wait(1000, function()
      return text(result):find("Let me start by exploring", 1, true) ~= nil
    end))
    result:apply({
      type = "tool_call_delta", index = 1, id = "ordered-one",
      name = "shell", arguments_delta = '{"command":"rg -n cram"}',
    })
    assert(vim.wait(1000, function()
      return text(result):find("• Running rg -n cram", 1, true) ~= nil
    end))
    result:apply({
      type = "tool_call_delta", index = 2, id = "ordered-two",
      name = "shell", arguments_delta = '{"command":"rg -n swa"}',
    })
    assert(vim.wait(1000, function()
      return text(result):find("• Running rg -n swa", 1, true) ~= nil
    end))

    local calls = {
      { type = "toolCall", id = "ordered-one", name = "shell",
        arguments = { command = "rg -n cram" } },
      { type = "toolCall", id = "ordered-two", name = "shell",
        arguments = { command = "rg -n swa" } },
    }
    result:apply({ type = "message_end", message = {
      role = "assistant", content = {
        { type = "text", index = 0,
          text = "Let me start by exploring the server flags." },
        calls[1], calls[2],
      },
    } })
    assert(vim.wait(1000, function()
      return not result.flush_pending
    end))
    result:apply({ type = "tool_end", call = calls[2], message = {
      role = "toolResult", toolCallId = calls[2].id,
      toolName = "shell", isError = false,
      content = { { type = "text", text = "ok" } },
    } })
    assert(vim.wait(1000, function()
      return text(result):find("• Ran rg -n swa", 1, true) ~= nil
    end))

    local function assert_order(first_label)
      local lines = vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false)
      local prose, first, second, prose_count = nil, nil, nil, 0
      for row, line in ipairs(lines) do
        if line:find("Let me start by exploring", 1, true) then
          prose, prose_count = row, prose_count + 1
        end
        if line:find(first_label, 1, true) then first = row end
        if line:find("• Ran rg -n swa", 1, true) then second = row end
      end
      assert.are.equal(1, prose_count)
      assert.is_not_nil(first)
      assert.is_not_nil(second)
      assert.is_true(prose < first)
      assert.is_true(first < second)
      assert.are.equal("", lines[second - 1])
    end
    assert_order("• Running rg -n cram")

    result:apply({ type = "tool_end", call = calls[1], message = {
      role = "toolResult", toolCallId = calls[1].id,
      toolName = "shell", isError = false,
      content = { { type = "text", text = "ok" } },
    } })
    assert(vim.wait(1000, function()
      return text(result):find("• Ran rg -n cram", 1, true) ~= nil
    end))
    assert_order("• Ran rg -n cram")
  end)

  it("replaces completed parallel Pi tool cards in place", function()
    local result = view({ position = "center", style = "pi" }, {
      require("neoagent.tools.shell").new(),
    })
    assert(result:open())
    result:apply({
      type = "text_delta", index = 0, text = "Inspect both caches.",
    })
    assert(vim.wait(1000, function()
      return text(result):find("Inspect both caches", 1, true) ~= nil
    end))
    local calls = {
      { type = "toolCall", id = "pi-one", name = "shell",
        arguments = { command = "printf pi-one" } },
      { type = "toolCall", id = "pi-two", name = "shell",
        arguments = { command = "printf pi-two" } },
    }
    for index, call in ipairs(calls) do
      result:apply({
        type = "tool_call_delta", index = index, id = call.id,
        name = call.name,
        arguments_delta = vim.json.encode(call.arguments),
      })
      assert(vim.wait(1000, function()
        return text(result):find("$ " .. call.arguments.command, 1, true)
          ~= nil
      end))
    end
    result:apply({ type = "message_end", message = {
      role = "assistant", content = {
        { type = "text", index = 0, text = "Inspect both caches." },
        calls[1], calls[2],
      },
    } })
    assert(vim.wait(1000, function() return not result.flush_pending end))

    for index = #calls, 1, -1 do
      local call = calls[index]
      result:apply({ type = "tool_end", call = call, message = {
        role = "toolResult", toolCallId = call.id,
        toolName = "shell", isError = false,
        content = { { type = "text", text = "result " .. index } },
      } })
      assert(vim.wait(1000, function()
        return text(result):find("result " .. index, 1, true) ~= nil
      end))
    end

    local rendered = text(result)
    for _, call in ipairs(calls) do
      local _, count = rendered:gsub(
        "$ " .. vim.pesc(call.arguments.command), "")
      assert.are.equal(1, count)
    end
    local prose = assert(rendered:find("Inspect both caches", 1, true))
    local first = assert(rendered:find("$ printf pi-one", 1, true))
    local second = assert(rendered:find("$ printf pi-two", 1, true))
    assert.is_true(prose < first and first < second)
  end)

  it("renders semantic presentations supplied by active tools", function()
    local tool = {
      name = "present",
      render = function(opts)
        assert.are.equal("value", opts.arguments.label)
        assert.are.equal("success", opts.state)
        assert.are.equal("pi", opts.style)
        assert.is_false(opts.full)
        return {
          card = false,
          lines = {
            {
              { text = " • ", style = "muted" },
              { text = "Custom presentation", style = "bold" },
            },
            {
              { text = "   └ ", style = "muted" },
              { text = "complete", style = { "accent", "italic" } },
            },
          },
        }
      end,
    }
    local result = view({ position = "center" }, { tool })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "present", name = "present",
        arguments = { label = "value" },
      } } },
      { role = "toolResult", toolCallId = "present", toolName = "present",
        isError = false, content = { { type = "text", text = "hidden" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("Custom presentation", 1, true) ~= nil
    end))
    assert.not_matches("hidden", text(result))
    assert.not_matches("label=value", text(result))
    assert.is_false(has_line_group(result, "NeoagentToolSuccessBackground"))
  end)

  it("composes semantic tool titles with the default output", function()
    local tool = {
      name = "present_default",
      render = function()
        return {
          default = true,
          title = {
            { text = "Presented", style = "bold" },
            { text = " operation", style = "accent" },
          },
        }
      end,
    }
    local result = view({ position = "center" }, { tool })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "present-default",
        name = "present_default", arguments = {},
      } } },
      { role = "toolResult", toolCallId = "present-default",
        toolName = "present_default", isError = false,
        content = { { type = "text", text = "retained output" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("retained output", 1, true) ~= nil
    end))
    assert.matches("Presented operation", text(result))
    assert.not_matches("present_default", text(result))
    assert.is_true(has_line_group(result, "NeoagentToolSuccessBackground"))
  end)

  it("applies semantic tool status to Codex-colored title markers", function()
    local tool = {
      name = "present_status",
      render = function()
        return {
          title = { { text = "Presented status", style = "bold" } },
          status = true,
        }
      end,
    }
    local result = view(
      { position = "center", style = "codex" }, { tool })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "present-status",
        name = "present_status", arguments = {},
      } } },
      { role = "toolResult", toolCallId = "present-status",
        toolName = "present_status", isError = false,
        content = { { type = "text", text = "hidden" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("• Presented status", 1, true) ~= nil
    end))

    local row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("• Presented status", 1, true) then
        row = index - 1
        break
      end
    end
    assert.is_not_nil(row)
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.namespace,
      { row, 0 }, { row, -1 }, { details = true, hl_name = true }
    )) do
      if mark[4].hl_group then groups[mark[4].hl_group] = true end
    end
    assert.is_true(groups.NeoagentCodexToolSuccess)
    assert.not_matches("hidden", text(result))
  end)

  it("falls back safely from malformed semantic presentations", function()
    local specifications = {
      { name = "invalid-lines", render = function()
        return { lines = "invalid" }
      end },
      { name = "invalid-line", render = function()
        return { lines = { "invalid" } }
      end },
      { name = "invalid-segment", render = function()
        return { lines = { { "invalid" } } }
      end },
      { name = "invalid-style", render = function()
        return { lines = { { { text = "invalid", style = 1 } } } }
      end },
      { name = "unknown-style", render = function()
        return { lines = { { { text = "invalid", style = "unknown" } } } }
      end },
      { name = "default-with-lines", render = function()
        return { default = true, lines = {} }
      end },
      { name = "invalid-title", render = function()
        return { default = true, title = "invalid" }
      end },
      { name = "newline-title", render = function()
        return { title = { { text = "invalid\ntitle" } } }
      end },
      { name = "newline-line", render = function()
        return { lines = { { { text = "invalid\nline" } } } }
      end },
      { name = "invalid-status", render = function()
        return { title = true, status = "success" }
      end },
      { name = "invalid-command", render = function()
        return { title = { { text = "invalid" } }, command = {} }
      end },
      { name = "command-with-lines", render = function()
        return {
          title = { { text = "invalid" } }, command = "true", lines = {},
        }
      end },
      { name = "command-with-default", render = function()
        return { default = true, title = true, command = "true" }
      end },
      { name = "unstyled", render = function()
        return { card = false, lines = { { { text = "unstyled presentation" } } } }
      end },
    }
    local tools, calls, messages = {}, {}, {}
    for _, specification in ipairs(specifications) do
      tools[#tools + 1] = specification
      calls[#calls + 1] = {
        type = "toolCall",
        id = specification.name,
        name = specification.name,
        arguments = {},
      }
      messages[#messages + 1] = {
        role = "toolResult",
        toolCallId = specification.name,
        toolName = specification.name,
        isError = false,
        content = { { type = "text", text = "fallback " .. specification.name } },
      }
    end
    table.insert(messages, 1, { role = "assistant", content = calls })

    local result = view({ position = "center" }, tools)
    result:set_messages(messages)
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("fallback unknown-style", 1, true) ~= nil
    end))
    local transcript = text(result)
    for _, specification in ipairs(specifications) do
      if specification.name ~= "unstyled" then
        assert.is_not_nil(transcript:find(
          "fallback " .. specification.name, 1, true))
      end
    end
    assert.matches("unstyled presentation", transcript)
    assert.not_matches("fallback unstyled", transcript)
  end)

  it("renders streamed update_plan calls as transparent spinner cards", function()
    local result = view(
      { position = "center", width = 44, style = "codex" },
      { require("neoagent.tools.update_plan").new() })
    assert(result:open())
    result:set_context({ state = "running" })
    result:apply({
      type = "tool_call_delta", index = 0, id = "plan",
      name = "update_plan", arguments_delta = '{"plan":[',
    })

    local function updating_line()
      for _, line in ipairs(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false)) do
        if line:find("Updating plan", 1, true) then return line end
      end
    end
    assert(vim.wait(1000, function() return updating_line() ~= nil end))
    local initial = updating_line()
    assert.is_false(has_line_group(result, "NeoagentToolPendingBackground"))
    assert.is_table(result.blocks[1].card)
    assert(vim.wait(1000, function()
      local current = updating_line()
      return current ~= nil and current ~= initial
    end))

    local arguments = {
      plan = { { step = "Implement the UI", status = "in_progress" } },
    }
    result:apply({ type = "message_end", message = {
      role = "assistant", content = { {
        type = "toolCall", id = "plan", name = "update_plan",
        arguments = arguments,
      } },
    } })
    result:apply({ type = "tool_start", call = {
      id = "plan", name = "update_plan", arguments = arguments,
    } })
    assert(vim.wait(1000, function() return updating_line() ~= nil end))
    result:apply({
      type = "tool_end",
      call = { id = "plan", name = "update_plan", arguments = arguments },
      message = {
        role = "toolResult", toolCallId = "plan", toolName = "update_plan",
        isError = false, content = { { type = "text", text = "Plan updated" } },
      },
    })
    assert(vim.wait(1000, function()
      return text(result):find("Updated Plan", 1, true) ~= nil
    end))
    assert.is_nil(updating_line())
  end)

  it("renders successful update_plan calls like Codex todo lists", function()
    local result = view(
      { position = "center", width = 44, style = "codex" },
      { require("neoagent.tools.update_plan").new() })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "plan", name = "update_plan", arguments = {
          explanation = "Implement in three focused phases.",
          plan = {
            { step = "Inspect Codex behavior", status = "completed" },
            { step = "Add the optional tool", status = "in_progress" },
            { step = "Verify the UI", status = "pending" },
          },
        },
      } } },
      { role = "toolResult", toolCallId = "plan", toolName = "update_plan",
        isError = false, content = { { type = "text", text = "Plan updated" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("Updated Plan", 1, true) ~= nil
    end))

    local lines = vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)
    assert.are.same({
      " • Updated Plan ",
      "    └ Implement in three focused phases. ",
      "      ✔ Inspect Codex behavior ",
      "      □ Add the optional tool ",
      "      □ Verify the UI ",
      "",
    }, lines)
    assert.not_matches("Plan updated", text(result))
    assert.not_matches("update_plan", text(result))
    assert.is_false(has_line_group(result, "NeoagentToolSuccessBackground"))

    local function groups(row)
      local found = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.namespace, { row, 0 }, { row, -1 },
        { details = true, hl_name = true }
      )) do
        if mark[4].hl_group then found[mark[4].hl_group] = true end
      end
      return found
    end
    assert.is_true(groups(0).NeoagentMarkdownBold)
    assert.is_true(groups(2).NeoagentMarkdownStrike)
    assert.is_true(groups(3).NeoagentCyan)
    assert.are.equal(6, vim.api.nvim_get_hl(0, {
      name = "NeoagentCyan", link = false,
    }).ctermfg)
    assert.is_true(groups(3).NeoagentMarkdownBold)
    assert.is_true(groups(4).NeoagentMuted)
  end)

  it("keeps multiline Codex tool headers visible while hovered", function()
    local tool = require("neoagent.tools.update_plan").new()
    local plan = {
      explanation = "Workspace inspection is complete.",
      plan = {
        { step = "Inspect workspace", status = "completed" },
        { step = "Create the app", status = "completed" },
        { step = "Run local checks", status = "in_progress" },
      },
    }
    local result = view(
      { position = "center", width = 72, style = "codex" }, { tool })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "plan-hover", name = "update_plan",
        arguments = plan,
      } } },
      { role = "toolResult", toolCallId = "plan-hover",
        toolName = "update_plan", isError = false,
        content = { { type = "text", text = "Plan updated" } },
        details = plan,
      },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("Run local checks", 1, true) ~= nil
    end))
    local header_row, last_row, header_line
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("• Updated Plan", 1, true) then
        header_row, header_line = index - 1, line
      elseif line:find("Run local checks", 1, true) then
        last_row = index - 1
      end
    end
    assert.is_not_nil(header_row)
    assert.is_not_nil(last_row)
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(
      result.transcript_win, { header_row + 1, 0 })
    vim.api.nvim_exec_autocmds(
      "CursorMoved", { buffer = result.transcript_buf })

    local top, top_col, bottom, bottom_row, virtual_bottom
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace,
      0, -1, { details = true }
    )) do
      local details = mark[4]
      if mark[2] == header_row then
        for _, chunk in ipairs(details.virt_text or {}) do
          if chunk[1]:find("╮", 1, true) then
            top, top_col = chunk[1], details.virt_text_win_col
          end
          assert.is_nil(chunk[1]:find("╭", 1, true))
        end
      end
      for _, line in ipairs(details.virt_lines or {}) do
        for _, chunk in ipairs(line) do
          if chunk[1]:find("╰", 1, true) then
            virtual_bottom = chunk[1]
          end
        end
      end
      for _, chunk in ipairs(details.virt_text or {}) do
        if chunk[1]:find("╰", 1, true) then
          bottom, bottom_row = chunk[1], mark[2]
        end
      end
    end
    assert.are.equal(vim.fn.strdisplaywidth(header_line), top_col)
    assert.is_true(vim.fn.strchars(top) > 1)
    assert.are.equal("╮", vim.fn.strcharpart(
      top, vim.fn.strchars(top) - 1, 1))
    assert.are.equal("╰", vim.fn.strcharpart(bottom, 0, 1))
    assert.are.equal("╯", vim.fn.strcharpart(
      bottom, vim.fn.strchars(bottom) - 1, 1))
    assert.is_not_nil(bottom:find("<CR> to expand", 1, true))
    assert.is_nil(virtual_bottom)
    assert.are.equal(last_row + 1, bottom_row)
    assert.are.equal("", vim.api.nvim_buf_get_lines(
      result.transcript_buf, bottom_row, bottom_row + 1, false)[1])
    assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(
      result.transcript_buf, header_row, last_row + 1, false),
      "      □ Run local checks "))
  end)

  it("replaces adjacent Codex separators with tool hover outlines", function()
    local plan = {
      explanation = "Keep the boundary stable.",
      plan = {
        { step = "Inspect the plan", status = "completed" },
        { step = "Verify the hover", status = "in_progress" },
      },
    }
    local result = view(
      { position = "center", width = 72, style = "codex" }, {
        require("neoagent.tools.update_plan").new(),
        require("neoagent.tools.shell").new(),
      })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "hover-plan", name = "update_plan",
        arguments = plan,
      } } },
      { role = "toolResult", toolCallId = "hover-plan",
        toolName = "update_plan", isError = false,
        content = { { type = "text", text = "Plan updated" } },
        details = plan,
      },
      { role = "assistant", content = {
        { type = "text", text = "Run the follow-up command." },
      } },
      { role = "assistant", content = { {
        type = "toolCall", id = "hover-shell", name = "shell",
        arguments = { command = "printf 'one\\ntwo\\n'" },
      } } },
      { role = "toolResult", toolCallId = "hover-shell",
        toolName = "shell", isError = false,
        content = { { type = "text", text = "one\ntwo" } },
      },
      { role = "assistant", content = {
        { type = "text", text = "The command is complete." },
      } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("The command is complete.", 1, true) ~= nil
    end))

    local function card_rows(id)
      local block
      for _, candidate in ipairs(result.blocks) do
        if candidate.call and candidate.call.id == id then
          block = candidate
          break
        end
      end
      assert.is_not_nil(block)
      local position = vim.api.nvim_buf_get_extmark_by_id(
        result.transcript_buf, result.namespace, block.mark,
        { details = true })
      local first = position[1] + block.card.first
      local last = position[1] + block.card.last
      local separator = last + 1
      assert.matches("────", vim.api.nvim_buf_get_lines(
        result.transcript_buf, separator, separator + 1, false)[1])
      return first, separator
    end

    local function assert_hover_replaces_separator(id)
      local first, separator = card_rows(id)
      result:focus_transcript()
      vim.api.nvim_win_set_cursor(result.transcript_win, { first + 1, 0 })
      vim.api.nvim_exec_autocmds(
        "CursorMoved", { buffer = result.transcript_buf })

      local virtual_bottom, overlay_row, overlay_text
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.card_namespace, 0, -1,
        { details = true }
      )) do
        for _, line in ipairs(mark[4].virt_lines or {}) do
          for _, chunk in ipairs(line) do
            if chunk[1]:find("<CR> to expand", 1, true) then
              virtual_bottom = chunk[1]
            end
          end
        end
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          if chunk[1]:find("<CR> to expand", 1, true) then
            overlay_row, overlay_text = mark[2], chunk[1]
          end
        end
      end
      assert.is_nil(virtual_bottom)
      assert.are.equal(separator, overlay_row)
      assert.are.equal(
        vim.api.nvim_win_get_width(result.transcript_win),
        vim.fn.strdisplaywidth(overlay_text))
    end

    assert_hover_replaces_separator("hover-plan")
    assert_hover_replaces_separator("hover-shell")

    local _, shell_separator = card_rows("hover-shell")
    vim.api.nvim_win_set_cursor(
      result.transcript_win, { shell_separator + 3, 0 })
    vim.api.nvim_exec_autocmds(
      "CursorMoved", { buffer = result.transcript_buf })
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1,
      { details = true }
    )) do
      if mark[2] == shell_separator then
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          assert.is_nil(chunk[1]:find("<CR> to expand", 1, true))
        end
      end
    end
    assert.matches("────", vim.api.nvim_buf_get_lines(
      result.transcript_buf, shell_separator,
      shell_separator + 1, false)[1])
  end)

  it("reuses Codex card spacing for hover outlines in tool groups", function()
    local plan = {
      plan = {
        { step = "Inspect the workspace", status = "pending" },
        { step = "Implement the app", status = "pending" },
        { step = "Run a smoke check", status = "pending" },
      },
    }
    local result = view(
      { position = "center", width = 72, style = "codex" }, {
        require("neoagent.tools.update_plan").new(),
        require("neoagent.tools.shell").new(),
      })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "group-plan", name = "update_plan",
        arguments = plan,
      } } },
      { role = "toolResult", toolCallId = "group-plan",
        toolName = "update_plan", isError = false,
        content = { { type = "text", text = "Plan updated" } },
        details = plan,
      },
      { role = "assistant", content = { {
        type = "toolCall", id = "group-shell", name = "shell",
        arguments = { command = "printf 'one\\ntwo\\n'" },
      } } },
      { role = "toolResult", toolCallId = "group-shell",
        toolName = "shell", isError = false,
        content = { { type = "text", text = "one\ntwo" } },
      },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("• Ran printf", 1, true) ~= nil
    end))

    local block = assert(vim.tbl_filter(function(candidate)
      return candidate.call and candidate.call.id == "group-plan"
    end, result.blocks)[1])
    local position = vim.api.nvim_buf_get_extmark_by_id(
      result.transcript_buf, result.namespace, block.mark,
      { details = true })
    local first = position[1] + block.card.first
    local spacer = position[1] + block.card.last + 1
    assert.are.equal("", vim.api.nvim_buf_get_lines(
      result.transcript_buf, spacer, spacer + 1, false)[1])

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { first + 1, 0 })
    vim.api.nvim_exec_autocmds(
      "CursorMoved", { buffer = result.transcript_buf })

    local virtual_bottom, overlay_row
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1,
      { details = true }
    )) do
      for _, line in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(line) do
          if chunk[1]:find("<CR> to expand", 1, true) then
            virtual_bottom = chunk[1]
          end
        end
      end
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("<CR> to expand", 1, true) then
          overlay_row = mark[2]
        end
      end
    end
    assert.is_nil(virtual_bottom)
    assert.are.equal(spacer, overlay_row)
  end)

  it("renders update_plan checklists inside ordinary Pi tool cards", function()
    local result = view(
      { position = "center", width = 44 },
      { require("neoagent.tools.update_plan").new() })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "plan-pi", name = "update_plan",
        arguments = {
          explanation = "Keep Pi presentation.",
          plan = {
            { step = "Keep card chrome", status = "completed" },
            { step = "Use one card", status = "in_progress" },
            { step = "Verify the result", status = "pending" },
          },
        },
      } } },
      { role = "toolResult", toolCallId = "plan-pi",
        toolName = "update_plan", isError = false,
        content = { { type = "text", text = "Plan updated" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("[ ] Use one card", 1, true) ~= nil
    end))
    assert.matches("update_plan", text(result))
    assert.not_matches("Updated Plan", text(result))
    assert.matches("Keep Pi presentation", text(result))
    assert.matches("%[x%] Keep card chrome", text(result))
    assert.matches("%[ %] Verify the result", text(result))
    assert.not_matches("Plan updated", text(result))
    assert.is_true(has_line_group(result, "NeoagentToolSuccessBackground"))

    local active_row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false)) do
      if line:find("[ ] Use one card", 1, true) then active_row = index - 1 end
    end
    assert.is_not_nil(active_row)
    local active_groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.namespace,
      { active_row, 0 }, { active_row, -1 },
      { details = true, hl_name = true }
    )) do
      if mark[4].hl_group then active_groups[mark[4].hl_group] = true end
    end
    assert.is_true(active_groups.NeoagentMarkdownBold)
    assert.is_nil(active_groups.NeoagentCyan)
    assert.is_nil(active_groups.NeoagentMarkdownItalic)

    assert.are.equal("codex", result:set_style("codex"))
    assert(vim.wait(1000, function()
      return text(result):find("Updated Plan", 1, true) ~= nil
    end))
    assert.not_matches("Plan updated", text(result))
    assert.is_false(has_line_group(result, "NeoagentToolSuccessBackground"))
  end)

  it("uses compact Codex activity cards while retaining mutation bodies", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.read_file").new(),
      require("neoagent.tools.shell").new(),
      require("neoagent.tools.write_file").new(),
      require("neoagent.tools.edit_file").new(),
    })
    result:set_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "read-activity", name = "read_file",
          arguments = { path = "README.md" } },
        { type = "toolCall", id = "shell-activity", name = "shell",
          arguments = { command = "printf output" } },
        { type = "toolCall", id = "write-running", name = "write_file",
          arguments = { path = "pending.lua", content = "return false" } },
        { type = "toolCall", id = "write-body", name = "write_file",
          arguments = { path = "new.lua", content = "return true" } },
        { type = "toolCall", id = "edit-body", name = "edit_file",
          arguments = { path = "existing.lua", edits = {} } },
      } },
      { role = "toolResult", toolCallId = "read-activity",
        toolName = "read_file", isError = false,
        content = { { type = "text", text = "file contents" } } },
      { role = "toolResult", toolCallId = "shell-activity",
        toolName = "shell", isError = false,
        content = { { type = "text", text = "command output" } } },
      { role = "toolResult", toolCallId = "write-body",
        toolName = "write_file", isError = false,
        content = { { type = "text", text = "Successfully wrote new.lua" } } },
      { role = "toolResult", toolCallId = "edit-body",
        toolName = "edit_file", isError = false,
        content = { { type = "text", text = "Successfully edited existing.lua" } },
        details = { diff = " context\n-old\n+new" } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("+new", 1, true) ~= nil
    end))
    assert.matches("• Read README%.md", text(result))
    assert.matches("• Ran printf output", text(result))
    assert.not_matches("file contents", text(result))
    assert.matches("└ command output", text(result))
    assert.matches("• Writing pending%.lua", text(result))
    assert.matches("return false", text(result))
    assert.matches("• Written new%.lua", text(result))
    assert.matches("return true", text(result))
    assert.matches("• Edited existing%.lua", text(result))
    assert.matches("%-old", text(result))
    assert.matches("%+new", text(result))
    assert.not_matches("• Added", text(result))
    assert.is_false(has_line_group(result, "NeoagentToolSuccessBackground"))

    local successful = {}
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("• Read README.md", 1, true)
          or line:find("• Written new.lua", 1, true)
          or line:find("• Edited existing.lua", 1, true) then
        successful[#successful + 1] = index - 1
      end
    end
    assert.are.equal(3, #successful)
    for _, row in ipairs(successful) do
      local groups = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.namespace,
        { row, 0 }, { row, -1 }, { details = true, hl_name = true }
      )) do
        if mark[4].hl_group then groups[mark[4].hl_group] = true end
      end
      assert.is_true(groups.NeoagentCodexToolSuccess)
    end
  end)

  it("renders successful Codex edits as numbered patch previews", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.edit_file").new(),
    })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "patch-edit", name = "edit_file",
        arguments = { path = "existing.lua", edits = {} },
      } } },
      { role = "toolResult", toolCallId = "patch-edit",
        toolName = "edit_file", isError = false,
        content = { {
          type = "text", text = "Successfully edited existing.lua",
        } },
        details = {
          patch = table.concat({
            "@@ -1,3 +1,3 @@",
            " line one",
            "-line two",
            "+line two changed",
            " line three",
          }, "\n"),
          diff = "-line two\n+line two changed",
          firstChangedLine = 2,
        },
      },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("Edited existing.lua", 1, true) ~= nil
    end))

    local lines = vim.tbl_map(function(line)
      return (line:gsub("%s+$", ""))
    end, vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false))
    assert.are.same({
      " • Edited existing.lua (+1 -1)",
      "    1  line one",
      "    2 -line two",
      "    2 +line two changed",
      "    3  line three",
      "",
    }, lines)

    local function groups(row)
      local found = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.namespace,
        { row, 0 }, { row, -1 }, { details = true, hl_name = true }
      )) do
        if mark[4].hl_group then found[mark[4].hl_group] = true end
      end
      return found
    end
    assert.is_true(groups(0).NeoagentCodexToolSuccess)
    assert.is_true(groups(0).NeoagentMarkdownBold)
    assert.is_true(groups(0).NeoagentGreen)
    assert.is_true(groups(0).NeoagentRed)
    assert.is_true(groups(2).NeoagentRed)
    assert.is_true(groups(3).NeoagentGreen)
    assert.are.equal(2, vim.api.nvim_get_hl(0, {
      name = "NeoagentGreen", link = false,
    }).ctermfg)
    assert.are.equal(1, vim.api.nvim_get_hl(0, {
      name = "NeoagentRed", link = false,
    }).ctermfg)
  end)

  it("renders Codex write source without default output styling", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.write_file").new(),
    })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "plain-write", name = "write_file",
        arguments = {
          path = "demo.lua",
          content = "local value = true\nreturn value",
        },
      } } },
      { role = "toolResult", toolCallId = "plain-write",
        toolName = "write_file", isError = false,
        content = { { type = "text", text = "Successfully wrote demo.lua" } },
      },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("local value = true", 1, true) ~= nil
    end))

    local function source_groups()
      local source_row
      for index, line in ipairs(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false)) do
        if line:find("local value = true", 1, true) then
          source_row = index - 1
        end
      end
      assert.is_not_nil(source_row)
      local groups = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.namespace,
        { source_row, 0 }, { source_row, -1 },
        { details = true, hl_name = true }
      )) do
        if mark[4].hl_group then groups[mark[4].hl_group] = true end
      end
      return groups
    end
    local groups = source_groups()
    assert.is_nil(groups.NeoagentToolOutput)

    assert.are.equal("pi", result:set_style("pi"))
    assert(vim.wait(1000, function()
      return has_line_group(result, "NeoagentToolSuccessBackground")
    end))
    groups = source_groups()
    assert.is_true(groups.NeoagentToolOutput)
  end)

  it("limits and highlights streamed Codex write previews", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.write_file").new(),
    })
    assert(result:open())
    result:apply({
      type = "tool_call_delta", index = 0, name = "write_file",
      arguments_delta = '{"path":"/tmp/demo.lua"',
    })
    assert(vim.wait(1000, function()
      return text(result):find(
        "• Writing /tmp/demo.lua", 1, true) ~= nil
    end))
    result:apply({
      type = "tool_call_delta", index = 0,
      arguments_delta = ',"content":"local one = 1\\nlocal two = 2\\n'
        .. 'local three = 3\\nlocal four = 4\\nreturn four"}',
    })
    assert(vim.wait(1000, function()
      return text(result):find("local three = 3", 1, true) ~= nil
    end))

    local transcript = text(result)
    assert.matches("• Writing /tmp/demo%.lua", transcript)
    assert.matches("local one = 1", transcript)
    assert.matches("local two = 2", transcript)
    assert.matches("local three = 3", transcript)
    assert.not_matches("local four = 4", transcript)
    assert.not_matches("return four", transcript)
    assert.matches("%[%.%.%. 2 more lines%]", transcript)

    local header_row, source_row, omitted_row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false
    )) do
      if line:find("• Writing /tmp/demo.lua", 1, true) then
        header_row = index - 1
      elseif line:find("local one = 1", 1, true) then
        source_row = index
      elseif line:find("[... 2 more lines]", 1, true) then
        omitted_row = index
      end
    end
    assert.is_not_nil(header_row)
    assert.is_not_nil(source_row)
    assert.is_not_nil(omitted_row)
    vim.api.nvim_win_call(result.transcript_win, function()
      assert.are.equal("", vim.fn.synIDattr(
        vim.fn.synID(header_row + 1, 3, true), "name"))
      assert.are.equal("luaStatement", vim.fn.synIDattr(
        vim.fn.synID(source_row, 2, true), "name"))
      assert.are.equal("", vim.fn.synIDattr(
        vim.fn.synID(omitted_row, 2, true), "name"))
    end)

    result:apply({
      type = "tool_call_delta", index = 1, name = "write_file",
      arguments_delta = '{"path":"/tmp/demo.py",'
        .. '"content":"def greet():\\n    return True"}',
    })
    assert(vim.wait(1000, function()
      return text(result):find("def greet():", 1, true) ~= nil
    end))
    local python_row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false
    )) do
      if line:find("def greet():", 1, true) then python_row = index end
    end
    assert.is_not_nil(python_row)
    vim.api.nvim_win_call(result.transcript_win, function()
      assert.are.equal("luaStatement", vim.fn.synIDattr(
        vim.fn.synID(source_row, 2, true), "name"))
      assert.are.equal("pythonStatement", vim.fn.synIDattr(
        vim.fn.synID(python_row, 2, true), "name"))
    end)

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { header_row + 1, 0 })
    assert.is_true(result:show_card_details())
    local details = table.concat(vim.api.nvim_buf_get_lines(
      result.details_buf, 0, -1, false), "\n")
    assert.matches("local four = 4", details)
    assert.matches("return four", details)
    result:_close_card_details(true)
  end)

  it("scopes Codex write detail syntax to the file contents", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.write_file").new(),
    })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "syntax-write", name = "write_file",
        arguments = {
          path = "demo.lua",
          content = "local value = true\nreturn value",
        },
      } } },
      { role = "toolResult", toolCallId = "syntax-write",
        toolName = "write_file", isError = false,
        content = { { type = "text", text = "Successfully wrote demo.lua" } },
      },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("• Written demo.lua", 1, true) ~= nil
    end))

    local header_row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("• Written demo.lua", 1, true) then
        header_row = index - 1
      end
    end
    assert.is_not_nil(header_row)
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(
      result.transcript_win, { header_row + 1, 0 })
    assert.is_true(result:show_card_details())
    assert.are.equal("neoagent", vim.bo[result.details_buf].filetype)

    local lines = vim.api.nvim_buf_get_lines(
      result.details_buf, 0, -1, false)
    local detail_header, source_row
    for index, line in ipairs(lines) do
      if line:find("• Written demo.lua", 1, true) then
        detail_header = index
      elseif line == "local value = true" then
        source_row = index
      end
    end
    assert.is_not_nil(detail_header)
    assert.is_not_nil(source_row)
    vim.api.nvim_win_call(result.details_win, function()
      local header = vim.fn.synIDattr(
        vim.fn.synID(detail_header, 3, true), "name")
      local source = vim.fn.synIDattr(
        vim.fn.synID(source_row, 1, true), "name")
      assert.are.equal("", header)
      assert.are.equal("luaStatement", source)
    end)
    result:_close_card_details(true)
  end)

  it("keeps source syntax from spilling comment styles across later cards", function()
    local result = view({ position = "center", style = "codex" })
    local filler = {}
    for index = 1, 60 do filler[index] = "filler " .. index end
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "js-write", name = "write_file",
        arguments = {
          path = "app.js",
          content = "// entry\nfunction main() {\n  return 1\n}\n",
        },
      } } },
      { role = "toolResult", toolCallId = "js-write", toolName = "write_file",
        isError = false, content = { { type = "text", text = "wrote app.js" } } },
      { role = "assistant", content = { {
        type = "toolCall", id = "html-write", name = "write_file",
        arguments = {
          path = "app.html",
          content = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>app</title>\n<style>body{margin:0}</style>\n",
        },
      } } },
      { role = "toolResult", toolCallId = "html-write", toolName = "write_file",
        isError = false, content = { { type = "text", text = "wrote app.html" } } },
      { role = "assistant", content = { {
        type = "toolCall", id = "snippet", name = "shell",
        arguments = { command = "printf '/**'" },
      } } },
      { role = "toolResult", toolCallId = "snippet", toolName = "shell",
        isError = false, content = { { type = "text", text = "/**" } } },
      { role = "assistant", content = { {
        type = "text", text = table.concat(filler, "\n"),
      } } },
      { role = "assistant", content = { {
        type = "text", text = "Done! plain text after the preview.",
      } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("Done! plain text", 1, true) ~= nil
    end))

    local done_row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("Done! plain text", 1, true) then done_row = index end
    end
    assert.is_not_nil(done_row)
    vim.api.nvim_win_call(result.transcript_win, function()
      assert.are.equal("", vim.fn.synIDattr(
        vim.fn.synID(done_row, 2, true), "name"))
    end)
  end)

  it("renders multiline Codex shell commands as continuation rows", function()
    local result = view({ position = "center", width = 64, style = "codex" }, {
      require("neoagent.tools.shell").new(),
    })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "multiline-shell", name = "shell",
        arguments = { command = "set -eu\nprintf '%s\\n' done" },
      } } },
    })
    assert(result:open())

    local lines = vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)
    local activity
    for index, line in ipairs(lines) do
      if line:find("• Running", 1, true) then activity = index break end
    end
    assert.is_not_nil(activity)
    assert.are.same({
      " • Running set -eu ",
      "   │ printf '%s\\n' done ",
    }, vim.list_slice(lines, activity, activity + 1))
  end)

  it("clips long Codex shell command lines without wrapping", function()
    local result = view({ position = "center", width = 52, style = "codex" }, {
      require("neoagent.tools.shell").new(),
    })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "long-shell", name = "shell",
        arguments = {
          command = "printf one two three four five six seven eight nine ten",
        },
      } } },
    })
    assert(result:open())

    local lines = vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)
    local activity
    for index, line in ipairs(lines) do
      if line:find("• Running printf", 1, true) then activity = index break end
    end
    assert.is_not_nil(activity)
    assert.matches("%.%.%. $", lines[activity])
    assert.are.equal("", lines[activity + 1])
  end)

  it("summarizes Codex shell commands and output with official gutters", function()
    local result = view({ position = "center", width = 72, style = "codex" }, {
      require("neoagent.tools.shell").new(),
    })
    local output = table.concat(vim.tbl_map(tostring, vim.fn.range(1, 10)), "\n")
    local ansi = "\27[31m1\27[0m\n"
      .. table.concat(vim.tbl_map(tostring, vim.fn.range(2, 10)), "\n")
    result:set_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "summary-output", name = "shell",
          arguments = { command = table.concat({
            "git status --short &&",
            "git log -1 --format='%h %s%n%n%b' &&",
            "printf done",
            "printf hidden",
          }, "\n") } },
        { type = "toolCall", id = "summary-empty", name = "shell",
          arguments = { command = "true" } },
        { type = "toolCall", id = "summary-long", name = "shell",
          arguments = { command = table.concat({
            "printf one two three four five six seven eight nine ten",
            string.rep("x", 200),
          }, " ") } },
      } },
      { role = "toolResult", toolCallId = "summary-output",
        toolName = "shell", isError = false,
        content = { { type = "text", text = output } },
        details = { ansi = ansi } },
      { role = "toolResult", toolCallId = "summary-empty",
        toolName = "shell", isError = false,
        content = { { type = "text", text = "" } } },
    })
    assert(result:open())

    local lines = vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)
    local first
    for index, line in ipairs(lines) do
      if line:find("• Ran git status", 1, true) then first = index break end
    end
    assert.is_not_nil(first)
    assert.are.same({
      " • Ran git status --short && ",
      "   │ git log -1 --format='%h %s%n%n%b' && ",
      "   │ printf done ",
      "   │ … +1 lines ",
      "   └ 1 ",
      "     2 ",
      "     … +6 lines ",
      "     9 ",
      "     10 ",
    }, vim.list_slice(lines, first, first + 8))
    assert.not_matches("ctrl %+ t", text(result))

    local empty
    for index, line in ipairs(lines) do
      if line:find("• Ran true", 1, true) then empty = index break end
    end
    assert.is_not_nil(empty)
    assert.are.same({
      " • Ran true ",
      "   └ (no output) ",
    }, vim.list_slice(lines, empty, empty + 1))

    local long
    for index, line in ipairs(lines) do
      if line:find("• Running printf one", 1, true) then
        long = index
        break
      end
    end
    assert.is_not_nil(long)
    assert.matches("%.%.%. $", lines[long])
    assert.are.equal("", lines[long + 1])
    assert.is_true(vim.fn.strdisplaywidth(lines[long]) <= 72)

    local plain_index = first + 5
    local plain_row = plain_index - 1
    local plain_col = assert(lines[plain_index]:find("2", 1, true)) - 1
    local groups, normal_start, ansi_group = {}, nil, nil
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.namespace,
      { first + 3, 0 }, { plain_row, -1 },
      { details = true, hl_name = true }
    )) do
      local group = mark[4].hl_group
      if group then
        groups[group] = true
        if mark[2] == plain_row and group == "Normal" then
          normal_start = mark[3]
        end
        if tostring(group):match("^NeoagentAnsi") then
          ansi_group = group
        end
      end
    end
    assert.are.equal(plain_col, normal_start)
    assert.is_nil(groups.NeoagentToolOutput)
    assert.is_nil(groups.NeoagentMarkdownItalic)
    assert.is_not_nil(ansi_group)
    assert.are.equal(0xcd0000, vim.api.nvim_get_hl(0, {
      name = ansi_group, link = false,
    }).fg)

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { first, 0 })
    assert.is_true(result:show_card_details())
    local details = table.concat(vim.api.nvim_buf_get_lines(
      result.details_buf, 0, -1, false), "\n")
    assert.matches("1\n2\n3\n4\n5\n6\n7\n8\n9\n10", details)
    assert.not_matches("… %+6 lines", details)
    result:_close_card_details(true)
  end)

  it("collapses Codex search cards and expands their results", function()
    local result = view({ position = "center", width = 64, style = "codex" }, {
      require("neoagent.tools.grep").new(),
      require("neoagent.tools.find").new(),
    })
    result:set_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "grep-compact", name = "grep",
          arguments = { pattern = "needle", path = "lua", glob = "*.lua" } },
        { type = "toolCall", id = "find-compact", name = "find",
          arguments = { pattern = "*.lua", path = "src" } },
      } },
      { role = "toolResult", toolCallId = "grep-compact",
        toolName = "grep", isError = false,
        content = { { type = "text",
          text = "lua/a.lua:1:needle\nlua/b.lua:2:needle" } } },
      { role = "toolResult", toolCallId = "find-compact",
        toolName = "find", isError = false,
        content = { { type = "text", text = "src/a.lua\nsrc/b.lua" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("• Found *.lua in src", 1, true) ~= nil
    end))
    assert.matches("• Searched needle in lua %(%*%.lua%)", text(result))
    assert.not_matches("lua/a%.lua:1:needle", text(result))
    assert.not_matches("src/a%.lua", text(result))

    local function expand(label, expected)
      local row
      for index, line in ipairs(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false)) do
        if line:find(label, 1, true) then row = index - 1 break end
      end
      assert.is_not_nil(row)
      local title_groups = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.namespace,
        { row, 0 }, { row, -1 }, { details = true, hl_name = true }
      )) do
        if mark[4].hl_group then
          title_groups[mark[4].hl_group] = true
        end
      end
      assert.is_true(title_groups.NeoagentCodexToolSuccess)
      result:focus_transcript()
      vim.api.nvim_win_set_cursor(result.transcript_win, { row + 1, 0 })
      vim.api.nvim_exec_autocmds(
        "CursorMoved", { buffer = result.transcript_buf })
      local hint
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.card_namespace,
        { row, 0 }, { row, -1 }, { details = true }
      )) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          if chunk[1] == "[<CR> to expand]" then hint = chunk[1] end
        end
      end
      assert.are.equal("[<CR> to expand]", hint)
      assert.is_true(result:show_card_details())
      local details = table.concat(vim.api.nvim_buf_get_lines(
        result.details_buf, 0, -1, false), "\n")
      assert.matches(expected, details)
      local groups = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.details_buf, result.namespace, 0, -1,
        { details = true, hl_name = true }
      )) do
        if mark[4].hl_group then groups[mark[4].hl_group] = true end
      end
      assert.is_true(groups.Normal)
      assert.is_nil(groups.NeoagentToolOutput)
      result:_close_card_details(true)
    end

    expand("• Searched needle", "lua/a%.lua:1:needle")
    expand("• Found *.lua", "src/a%.lua")
  end)

  it("expands one-line Codex read cards with source syntax", function()
    local path = "src/" .. string.rep("nested/", 8) .. "file.lua"
    local result = view(
      { position = "center", width = 52, style = "codex" },
      { require("neoagent.tools.read_file").new() })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "read-compact", name = "read_file",
        arguments = { path = path },
      } } },
      { role = "toolResult", toolCallId = "read-compact",
        toolName = "read_file", isError = false,
        content = { { type = "text", text =
          "local value = true\nreturn value\n\n"
            .. "[602 more lines in file. Use offset=1904 to continue.]" } },
        details = { truncation = { outputLines = 2 } },
      },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("• Read src/", 1, true) ~= nil
    end))
    assert.not_matches("local value", text(result))

    local row, line
    for index, candidate in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if candidate:find("• Read src/", 1, true) then
        row, line = index - 1, candidate
        break
      end
    end
    assert.is_not_nil(row)
    assert.matches("%.%.%. $", line)
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { row + 1, 0 })
    vim.api.nvim_exec_autocmds(
      "CursorMoved", { buffer = result.transcript_buf })

    local badge = "[<CR> to expand]"
    local badge_col = vim.api.nvim_win_get_width(result.transcript_win)
      - 1 - vim.fn.strdisplaywidth(badge)
    local overlays = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace,
      { row, 0 }, { row, -1 }, { details = true }
    )) do
      local col = mark[4].virt_text_win_col
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        overlays[chunk[1]] = col
      end
    end
    assert.are.equal(badge_col, overlays[badge])
    assert.are.equal(badge_col - 4, overlays[" ..."])

    assert.is_true(result:show_card_details())
    local details = vim.api.nvim_buf_get_lines(
      result.details_buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(details, "local value = true"))
    assert.is_true(vim.tbl_contains(details, "return value"))
    local detail_header, source_row, continuation_row
    for index, candidate in ipairs(details) do
      if candidate:find("• Read src/", 1, true) then
        detail_header = index
      elseif candidate == "local value = true" then
        source_row = index
      elseif candidate:find("602 more lines", 1, true) then
        continuation_row = index
      end
    end
    assert.is_not_nil(detail_header)
    assert.is_not_nil(source_row)
    assert.is_not_nil(continuation_row)
    vim.api.nvim_win_call(result.details_win, function()
      assert.are.equal("", vim.fn.synIDattr(
        vim.fn.synID(detail_header, 3, true), "name"))
      assert.are.equal("luaStatement", vim.fn.synIDattr(
        vim.fn.synID(source_row, 1, true), "name"))
      assert.are.equal("", vim.fn.synIDattr(
        vim.fn.synID(continuation_row, 2, true), "name"))
    end)
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.details_buf, result.namespace, 0, -1,
      { details = true, hl_name = true }
    )) do
      if mark[4].hl_group then groups[mark[4].hl_group] = true end
    end
    assert.is_nil(groups.Normal)
    assert.is_nil(groups.NeoagentToolOutput)
    result:_close_card_details(true)
  end)

  it("shows Codex shell previews with state-colored bullets", function()
    local result = view({ position = "center", style = "codex" }, {
      require("neoagent.tools.shell").new(),
    })
    result:set_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "shell-pending", name = "shell",
          arguments = { command = "printf pending" } },
        { type = "toolCall", id = "shell-success", name = "shell",
          arguments = { command = "printf success" } },
        { type = "toolCall", id = "shell-error", name = "shell",
          arguments = { command = "false" } },
      } },
      { role = "toolResult", toolCallId = "shell-success",
        toolName = "shell", isError = false,
        content = { { type = "text", text = "plain red output" } },
        details = { ansi = "plain \27[31mred\27[0m output" } },
      { role = "toolResult", toolCallId = "shell-error",
        toolName = "shell", isError = true,
        content = { { type = "text", text = "failed output" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("• Ran false", 1, true) ~= nil
    end))

    local lines = vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)
    local rows = {}
    for index, line in ipairs(lines) do
      if line:find("• Running printf pending", 1, true) then
        rows.pending = index - 1
      elseif line:find("• Ran printf success", 1, true) then
        rows.success = index - 1
      elseif line:find("• Ran false", 1, true) then
        rows.error = index - 1
      end
    end
    assert.is_not_nil(rows.pending)
    assert.is_not_nil(rows.success)
    assert.is_not_nil(rows.error)
    assert.matches("└ plain red output", text(result))
    assert.matches("└ failed output", text(result))

    local function groups(row)
      local found = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.namespace,
        { row, 0 }, { row, -1 }, { details = true, hl_name = true }
      )) do
        if mark[4].hl_group then found[mark[4].hl_group] = true end
      end
      return found
    end
    assert.is_true(groups(rows.pending).NeoagentMuted)
    assert.is_true(groups(rows.success).NeoagentCodexToolSuccess)
    assert.is_true(groups(rows.error).NeoagentCodexToolError)
    local success = vim.api.nvim_get_hl(0, {
      name = "NeoagentCodexToolSuccess", link = false,
    })
    local failure = vim.api.nvim_get_hl(0, {
      name = "NeoagentCodexToolError", link = false,
    })
    assert.are.equal(2, success.ctermfg)
    assert.are.equal(0x00cd00, success.fg)
    assert.is_true(success.bold)
    assert.are.equal(1, failure.ctermfg)
    assert.are.equal(0xcd0000, failure.fg)
    assert.is_true(failure.bold)

    local cards = 0
    for _, block in ipairs(result.blocks) do
      if block.kind == "tool" then
        cards = cards + 1
        assert.is_table(block.card)
      end
    end
    assert.are.equal(3, cards)

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, {
      rows.success + 1, 0,
    })
    assert.is_true(result:show_card_details())
    assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(
      result.details_buf, 0, -1, false), "plain red output"))
    local detail_groups, ansi_group = {}, nil
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.details_buf, result.namespace, 0, -1,
      { details = true, hl_name = true }
    )) do
      local group = mark[4].hl_group
      if group then
        detail_groups[group] = true
        if tostring(group):match("^NeoagentAnsi") then
          ansi_group = group
        end
      end
    end
    assert.is_true(detail_groups.Normal)
    assert.is_nil(detail_groups.NeoagentToolOutput)
    assert.is_not_nil(ansi_group)
    assert.are.equal(0xcd0000, vim.api.nvim_get_hl(0, {
      name = ansi_group, link = false,
    }).fg)
    result:_close_card_details(true)
  end)

  it("shows inline expand hints for one-line pending Codex tools", function()
    local result = view(
      { position = "center", width = 52, style = "codex" },
      { require("neoagent.tools.shell").new() })
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "pending-short", name = "shell",
        arguments = { command = "true" },
      } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("• Running true", 1, true) ~= nil
    end))
    result:focus_transcript()

    local lines = vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)
    local row
    for index, line in ipairs(lines) do
      if line:find("• Running true", 1, true) then
        row = index - 1
        break
      end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { row + 1, 0 })
    vim.api.nvim_exec_autocmds(
      "CursorMoved", { buffer = result.transcript_buf })

    local badge = "[<CR> to expand]"
    local width = vim.api.nvim_win_get_width(result.transcript_win)
    local badge_col = width - 1 - vim.fn.strdisplaywidth(badge)
    local overlays, decoration = {}, {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace,
      { row, 0 }, { row, -1 }, { details = true }
    )) do
      local col = mark[4].virt_text_win_col
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        overlays[chunk[1]] = col
        decoration[#decoration + 1] = chunk[1]
      end
    end
    assert.is_true(vim.fn.strdisplaywidth(lines[row + 1]) <= badge_col)
    assert.are.equal(badge_col, overlays[badge])
    assert.is_nil(overlays[" ..."])
    local joined = table.concat(decoration)
    assert.is_nil(joined:find("╭", 1, true))
    assert.is_nil(joined:find("╰", 1, true))
  end)

  it("renders shell ANSI colors and leaves other escapes visible", function()
    local terminal_red = vim.g.terminal_color_1
    vim.g.terminal_color_1 = "#123456"
    local result = view({ position = "center" })
    result:set_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "shell-ansi", name = "shell",
          arguments = { command = "printf colors" } },
      } },
      { role = "toolResult", toolCallId = "shell-ansi", toolName = "shell",
        isError = false,
        content = { { type = "text", text =
          "[Non-text output escaped]\nplain \\x1B[1;31mred\\x1B[0m \\x1B]0;title\\x07tail" } },
        details = { ansi = table.concat({
          "plain \27[1;31mred\27[0m \27]0;title\\x07tail\n",
          "\27[1;3;4;7;9;31;44mattributes\ncontinued",
          "\27[22;23;24;27;29;39;49m plain\n",
          "\27[91;104mbright\27[0m ",
          "\27[38;5;196;48;5;244mindexed\27[0m ",
          "\27[38;2;1;2;3;48;2;4;5;6mtruecolor\27[m ",
          "\27[?25l \27[31ma\27]ignoredb\27[0m",
        }) },
      },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("plain red", 1, true) ~= nil
    end))

    local transcript = text(result)
    assert.not_matches("Non%-text output escaped", transcript)
    assert.not_matches("\\x1B%[1;31m", transcript)
    assert.matches("plain red \\x1B%]0;title\\x07tail", transcript)
    assert.matches("attributes", transcript)
    assert.matches("continued plain", transcript)
    assert.matches("bright indexed truecolor \\x1B%[%?25l", transcript)
    assert.matches("a\\x1B%]ignoredb", transcript)

    local colored
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.namespace, 0, -1,
      { details = true, hl_name = true }
    )) do
      if mark[4].hl_group and tostring(mark[4].hl_group):match("^NeoagentAnsi") then
        colored = mark
        break
      end
    end
    assert.is_not_nil(colored)
    assert.are.equal(7, colored[3])
    assert.are.equal(10, colored[4].end_col)
    local highlight = vim.api.nvim_get_hl(0, {
      name = colored[4].hl_group,
      link = false,
    })
    vim.g.terminal_color_1 = terminal_red
    assert.is_true(highlight.bold)
    assert.are.equal(0x123456, highlight.fg)
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

    local invalid = [=[$ bad\q1234567]=]
    result:apply({
      type = "tool_call_delta", index = 3, name = "shell",
      arguments_delta = [=[{"command":"bad\q1234567]=],
    })
    assert(vim.wait(1000, function()
      return text(result):find(invalid, 1, true) ~= nil
    end))
  end)

  it("reconstructs history, reports failures, and docks in place", function()
    local result = view({ position = "right" })
    assert.are.equal(vim.o.columns - 2, result:_content_width())
    result:set_messages({
      { role = "user", content = "hello" },
      { role = "assistant", content = { { type = "text", text = "hi" } } },
      { role = "branchSummary", summary = "returned branch context" },
      { role = "custom", display = true, content = "visible checkpoint" },
      { role = "custom", display = false, content = "hidden checkpoint" },
      { role = "bashExecution", command = "make test", output = "failed", exitCode = 2 },
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
    assert.matches("Branch context", text(result))
    assert.matches("returned branch context", text(result))
    assert.matches("visible checkpoint", text(result))
    assert.not_matches("hidden checkpoint", text(result))
    assert.matches("%$ make test", text(result))
    assert.matches("failed", text(result))
  end)

  it("truncates card lines by default and recomputes them after resize", function()
    local result = view({ position = "center" })
    local long = "card content " .. string.rep("segment-", 30) .. "界"
    result:set_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "w", name = "write_file",
          arguments = { path = "x", content = long } },
      } },
      { role = "toolResult", toolCallId = "w", toolName = "write_file",
        isError = false, content = { { type = "text", text = "ok" } } },
    })
    assert(result:open())

    local function card_line()
      for _, line in ipairs(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false)) do
        if line:find("card content", 1, true) then return line end
      end
    end

    assert(vim.wait(1000, function()
      local line = card_line()
      return line and line:find("... ", 1, true) ~= nil
    end))
    local initial_line = card_line()
    local initial_width = vim.api.nvim_win_get_width(result.transcript_win)
    assert.are.equal(initial_width, vim.fn.strdisplaywidth(initial_line))
    assert.matches("%.%.%. $", initial_line)

    vim.o.columns = 90
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(vim.wait(1000, function()
      return vim.api.nvim_win_get_width(result.transcript_win) ~= initial_width
        and card_line() ~= initial_line
    end))
    local resized_line = card_line()
    local resized_width = vim.api.nvim_win_get_width(result.transcript_win)
    assert.is_true(resized_width < initial_width)
    assert.are.equal(resized_width, vim.fn.strdisplaywidth(resized_line))
    assert.matches("%.%.%. $", resized_line)

    result:focus_transcript()
    local card_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line == resized_line then card_row = row break end
    end
    assert.is_not_nil(card_row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { card_row, 0 })
    assert.is_true(result:show_card_details())
    assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(
      result.details_buf, 0, -1, false), long))
    result:_close_card_details(true)
  end)

  it("allows configured card wrapping", function()
    local result = view({ position = "center", wrap_cards = true })
    local long = "wrapped card " .. string.rep("content-", 30)
    result:set_messages({ { role = "user", content = long } })
    assert(result:open())
    assert(vim.wait(1000, function()
      return vim.tbl_contains(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false), " " .. long .. " ")
    end))
    assert.is_true(vim.fn.strdisplaywidth(" " .. long .. " ")
      > vim.api.nvim_win_get_width(result.transcript_win))
    assert.is_true(vim.wo[result.transcript_win].wrap)
  end)

  it("keeps read output compact while details show every returned line", function()
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
    result:focus_transcript()
    local title_row
    for row, line in ipairs(collapsed) do
      if line:find("read README.md", 1, true) then title_row = row break end
    end
    assert.is_not_nil(title_row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { title_row, 0 })
    assert.is_true(result:show_card_details())
    assert.is_true(vim.tbl_contains(
      vim.api.nvim_buf_get_lines(result.details_buf, 0, -1, false), "line 15"))
    assert.matches("5 more lines", text(result))
    result:_close_card_details(true)
  end)

  it("shows bounded no-wrap compaction summaries and expands full details", function()
    local summary = {}
    for index = 1, 24 do
      summary[index] = "summary line " .. index
    end
    summary[1] = summary[1] .. " " .. string.rep("wide-content-", 30)
    local result = view({ position = "center", wrap_cards = true })
    result:set_messages({ {
      role = "compactionSummary",
      summary = table.concat(summary, "\n"),
      tokensBefore = 12345,
    }, {
      role = "assistant",
      content = { { type = "text", text = "retained suffix" } },
    } })
    assert(result:open())
    assert(vim.wait(1000, function()
      local transcript = text(result)
      return transcript:find("Compacted from 12,345 tokens", 1, true) ~= nil
        and transcript:find("summary line 1", 1, true) ~= nil
    end))
    assert.matches("%[compaction%]", text(result))
    assert.matches("%[%.%.%. %d+ more lines%]", text(result))
    assert.not_matches("summary line 24", text(result))
    assert.matches("retained suffix", text(result))
    assert.is_true(has_line_group(result, "NeoagentUserBackground"))

    local block = assert(vim.tbl_filter(function(candidate)
      return candidate.kind == "compaction"
    end, result.blocks)[1])
    local position = vim.api.nvim_buf_get_extmark_by_id(
      result.transcript_buf, result.namespace, block.mark, { details = true })
    local first = position[1] + block.card.first
    local last = position[1] + block.card.last
    assert.are.equal(20, last - first + 1)
    local width = vim.api.nvim_win_get_width(result.transcript_win)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, first, last + 1, false)) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= width)
    end
    assert.are.equal(20, vim.api.nvim_win_text_height(result.transcript_win, {
      start_row = first, end_row = last,
    }).all)

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { first + 1, 0 })
    assert.is_true(result:show_card_details())
    local details = table.concat(
      vim.api.nvim_buf_get_lines(result.details_buf, 0, -1, false), "\n")
    assert.matches("summary line 1", details)
    assert.matches("summary line 24", details)
    assert.not_matches("summary line 24", text(result))
    result:_close_card_details(true)
  end)

  it("outlines only the card beneath the focused transcript cursor", function()
    local result = view({ position = "center" })
    result:set_messages({
      { role = "user", content = "outlined card" },
      { role = "assistant", content = { { type = "text", text =
        "plain prose\nsecond line\nthird line" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("plain prose", 1, true) ~= nil
    end))
    result:focus_transcript()
    local card_row, prose_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("outlined card", 1, true) then card_row = row end
      if line:find("plain prose", 1, true) then prose_row = row end
    end
    assert.is_not_nil(card_row)
    assert.is_not_nil(prose_row)
    local function outline()
      local parts = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.card_namespace, 0, -1, { details = true }
      )) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          parts[#parts + 1] = chunk[1]
        end
      end
      return table.concat(parts, "\n")
    end

    vim.api.nvim_win_set_cursor(result.transcript_win, { card_row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    assert.matches("╭", outline())
    assert.matches("╯", outline())
    assert.is_nil(outline():find("│", 1, true))

    vim.api.nvim_win_set_cursor(result.transcript_win, { prose_row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    assert.matches("╭", outline())
    assert.matches("╯", outline())
    assert.is_nil(outline():find("│", 1, true))

    vim.api.nvim_win_set_cursor(result.transcript_win, { prose_row + 3, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    assert.are.equal("", outline())
    vim.api.nvim_win_set_cursor(result.transcript_win, { card_row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    result:focus_input()
    assert(vim.wait(1000, function() return outline() == "" end))
  end)

  it("shows the expand hint in the tool bottom border while hovered", function()
    local result = view({ position = "center" })
    result:set_messages({
      { role = "assistant", content = {
        { type = "toolCall", id = "c1", name = "read_file", arguments = { path = "x" } },
      } },
      { role = "toolResult", toolCallId = "c1", toolName = "read_file", isError = false,
        content = { { type = "text", text = "content" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    local row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("read x", 1, true) then row = index break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    local function expand_hints()
      local found = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.card_namespace, 0, -1, { details = true }
      )) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          if chunk[1]:find("<CR> to expand", 1, true) then
            found[#found + 1] = chunk[1]
          end
        end
      end
      return found
    end
    local bottom = expand_hints()
    assert.are.equal(1, #bottom)
    assert.matches("^╰", bottom[1])
    assert.matches("╯$", bottom[1])
    local count = vim.api.nvim_buf_line_count(result.transcript_buf)
    vim.api.nvim_win_set_cursor(result.transcript_win, { count, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = result.transcript_buf })
    assert.are.equal(0, #expand_hints())
  end)

  it("omits expand hints when card details are disabled", function()
    local result = view({
      position = "center",
      mappings = { card_details = false },
    })
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = "response" },
      { type = "toolCall", id = "c1", name = "read_file",
        arguments = { path = "x" } },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    local function overlay_text()
      local chunks = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        result.transcript_buf, result.card_namespace, 0, -1,
        { details = true }
      )) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          chunks[#chunks + 1] = chunk[1]
        end
      end
      return table.concat(chunks, "\n")
    end
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = result.transcript_buf,
    })
    assert.is_nil(overlay_text():find("to expand", 1, true))
    local tool_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false
    )) do
      if line:find("read x", 1, true) then tool_row = row break end
    end
    assert.is_not_nil(tool_row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { tool_row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = result.transcript_buf,
    })
    assert.is_nil(overlay_text():find("to expand", 1, true))
  end)

  it("shows the first configured card-details mapping in expand hints", function()
    local result = view({
      position = "center",
      mappings = { card_details = { "g?", "<CR>" } },
    })
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = "response" },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = result.transcript_buf,
    })
    local overlay = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1,
      { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        overlay[#overlay + 1] = chunk[1]
      end
    end
    local value = table.concat(overlay, "\n")
    assert.is_not_nil(value:find("g? to expand", 1, true))
    assert.is_nil(value:find("<CR> to expand", 1, true))
  end)

  it("uses singular word labels in response badges", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = "response" },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = result.transcript_buf,
    })
    local overlay = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1,
      { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        overlay[#overlay + 1] = chunk[1]
      end
    end
    assert.is_not_nil(table.concat(overlay, "\n"):find(
      "[text: 1 word, <CR> to expand]", 1, true))
  end)

  it("keeps response badges visible in narrow transcript windows", function()
    local result = view({ position = "center", width = 24 })
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = "response" },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = result.transcript_buf,
    })
    local badge
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      result.transcript_buf, result.card_namespace, 0, -1,
      { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("expand]", 1, true) then badge = chunk[1] end
      end
    end
    assert.is_not_nil(badge)
    assert.is_true(vim.fn.strdisplaywidth(badge)
      <= vim.api.nvim_win_get_width(result.transcript_win) - 1)
    assert.matches("to expand%]$", badge)
  end)

  it("titles expanded cards by kind and wraps their content", function()
    local result = view({ position = "center" })
    result:set_messages({
      { role = "assistant", content = {
        { type = "thinking", thinking = "trace" },
        { type = "toolCall", id = "c1", name = "read_file", arguments = { path = "x" } },
      } },
      { role = "toolResult", toolCallId = "c1", toolName = "read_file", isError = false,
        content = { { type = "text", text = "content" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    local function open_details(row)
      vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
      assert.is_true(result:show_card_details())
      return result.details_win
    end
    local function window_title(win)
      local chunks = vim.api.nvim_win_get_config(win).title or {}
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))
    end
    local thinking_row, tool_row
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    for index, line in ipairs(lines) do
      if line:find("trace", 1, true) then thinking_row = index end
      if line:find("read x", 1, true) then tool_row = index end
    end
    assert.is_not_nil(thinking_row)
    assert.is_not_nil(tool_row)
    local thinking_win = open_details(thinking_row)
    assert.matches("Thinking", window_title(thinking_win))
    assert.is_true(vim.wo[thinking_win].wrap)
    result:_close_card_details(true)
    local tool_win = open_details(tool_row)
    assert.matches("Tool call", window_title(tool_win))
    assert.is_true(vim.wo[tool_win].wrap)
    result:_close_card_details(true)
  end)

  it("sizes card details to wrapped screen lines", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = string.rep("wrapped content ", 40) },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    assert.is_true(result:show_card_details())
    local text_height = vim.api.nvim_win_text_height(
      result.details_win, {}).all
    local available = math.max(1,
      vim.o.lines - vim.o.cmdheight - 4)
    assert.is_true(text_height > 1)
    assert.are.equal(math.min(available, text_height),
      vim.api.nvim_win_get_height(result.details_win))
    result:_close_card_details(true)
  end)

  it("reflows open card details after an editor resize", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "assistant", content = {
      { type = "text", text = string.rep("resized content ", 40) },
    } } })
    assert(result:open())
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    assert.is_true(result:show_card_details())
    local initial_width = vim.api.nvim_win_get_width(result.details_win)
    vim.o.columns = 70
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(vim.wait(1000, function()
      if not result.details_win
          or not vim.api.nvim_win_is_valid(result.details_win) then
        return false
      end
      local current = vim.api.nvim_win_get_config(result.details_win)
      return current.width < initial_width
        and current.col == math.max(0,
          math.floor((vim.o.columns - current.width) / 2))
    end))
    local config = vim.api.nvim_win_get_config(result.details_win)
    assert.are.equal(math.max(0,
      math.floor((vim.o.columns - config.width) / 2)), config.col)
    local text_height = vim.api.nvim_win_text_height(
      result.details_win, {}).all
    assert.are.equal(math.min(
      vim.o.lines - vim.o.cmdheight - 4, text_height), config.height)
    result:_close_card_details(true)
  end)

  it("refreshes streaming card details and cleans up an externally closed float", function()
    local result = view({ position = "center" })
    result:set_messages({ { role = "assistant", content = { {
      type = "toolCall", id = "streaming-shell", name = "shell",
      arguments = { command = "long-running-command" },
    } } } })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("$ long-running-command", 1, true) ~= nil
    end))
    result:focus_transcript()
    local row
    for index, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("$ long-running-command", 1, true) then row = index break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
    assert.is_true(result:show_card_details())
    local window, buffer = result.details_win, result.details_buf
    local output = {}
    for index = 1, 15 do output[index] = "streamed line " .. index end
    result:apply({
      type = "tool_update",
      call = { id = "streaming-shell", name = "shell" },
      result = { content = { { type = "text", text = table.concat(output, "\n") } } },
    })
    assert(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
        :find("streamed line 15", 1, true) ~= nil
    end))
    assert.is_true(vim.api.nvim_win_get_height(window) > 1)
    assert.are.equal(window, result.details_win)
    assert.are.equal(buffer, result.details_buf)
    vim.api.nvim_win_set_cursor(window, { 8, 0 })
    output[#output + 1] = "streamed line 16"
    result:apply({
      type = "tool_update",
      call = { id = "streaming-shell", name = "shell" },
      result = { content = { { type = "text", text = table.concat(output, "\n") } } },
    })
    assert(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
        :find("streamed line 16", 1, true) ~= nil
    end))
    assert.are.equal(8, vim.api.nvim_win_get_cursor(window)[1])

    vim.api.nvim_win_close(window, true)
    assert(vim.wait(1000, function()
      return result.details_win == nil and result.details_buf == nil
        and not vim.api.nvim_buf_is_valid(buffer)
    end))
  end)

  it("centers idle status before context information is available", function()
    local result = view({ position = "center" })
    assert(result:open())
    local footer = vim.api.nvim_win_get_config(result.transcript_win).footer
    local offset = 0
    local idle_offset
    for _, chunk in ipairs(footer) do
      if chunk[1] == " Idle " then
        idle_offset = offset
        break
      end
      offset = offset + vim.fn.strdisplaywidth(chunk[1])
    end
    local width = vim.api.nvim_win_get_width(result.transcript_win)
    assert.are.equal(math.floor((width - vim.fn.strdisplaywidth(" Idle ")) / 2), idle_offset)
  end)

  it("matches Codex user cards to its adaptive terminal background", function()
    vim.api.nvim_set_hl(0, "Normal", { bg = 0x202020 })
    vim.api.nvim_set_hl(0, "NeoagentCodexUserBackground", {})
    local result = view({ position = "center", style = "codex" })
    result:set_messages({ { role = "user", content = "Codex prompt" } })
    assert(result:open())
    assert(vim.wait(1000, function()
      return text(result):find("Codex prompt", 1, true) ~= nil
    end))
    assert.is_true(has_line_group(result, "NeoagentCodexUserBackground"))
    assert.is_false(has_line_group(result, "NeoagentUserBackground"))
    assert.are.equal(0x3a3a3a, vim.api.nvim_get_hl(0, {
      name = "NeoagentCodexUserBackground", link = false,
    }).bg)

    vim.api.nvim_set_hl(0, "Normal", { bg = 0xf0f0f0 })
    vim.api.nvim_set_hl(0, "NeoagentCodexUserBackground", {})
    require("neoagent.ui.render").define_highlights()
    assert.are.equal(0xe6e6e6, vim.api.nvim_get_hl(0, {
      name = "NeoagentCodexUserBackground", link = false,
    }).bg)

    vim.api.nvim_set_hl(0, "Normal", {})
    vim.api.nvim_set_hl(0, "NeoagentCodexUserBackground", {})
    require("neoagent.ui.render").define_highlights()
    assert.is_nil(vim.api.nvim_get_hl(0, {
      name = "NeoagentCodexUserBackground", link = false,
    }).bg)
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
    assert.are.equal(" no model · think: high ", title)
    assert.matches("think: high", title)
    assert.is_nil(title:find("ctx ", 1, true))
    assert.is_nil(title:find("Neoagent", 1, true))
    assert.is_nil(title:find("compacting", 1, true))
    local function transcript_footer()
      local value = vim.api.nvim_win_get_config(result.transcript_win).footer
      if type(value) == "table" then
        value = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, value))
      end
      return value
    end
    local function input_footer()
      local value = vim.api.nvim_win_get_config(result.input_win).footer
      if type(value) == "table" then
        value = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, value))
      end
      return value
    end
    local transcript_config = vim.api.nvim_win_get_config(result.transcript_win)
    assert.are.equal("left", transcript_config.footer_pos)
    local activity_border = transcript_config.footer[1][1]
    local accent_chunks = vim.tbl_filter(function(chunk)
      return chunk[2] == "NeoagentAccent"
    end, transcript_config.footer)
    assert.are.equal(1, #accent_chunks)
    assert.are.equal(result.spinner_frames[result.spinner_frame], accent_chunks[1][1])
    local footer_offset = 0
    local context_start
    local before_context = {}
    for _, chunk in ipairs(transcript_config.footer) do
      if chunk[1]:find("ctx ", 1, true) then
        context_start = footer_offset
        break
      end
      before_context[#before_context + 1] = chunk[1]
      footer_offset = footer_offset + vim.fn.strdisplaywidth(chunk[1])
    end
    assert.are.equal(math.floor(vim.api.nvim_win_get_width(result.transcript_win) / 2), context_start)
    assert.matches("Compacting%.%.%. $", table.concat(before_context))
    local narrow_footer = result:_transcript_footer(24)
    local narrow_text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, narrow_footer))
    assert.are.equal(24, vim.fn.strdisplaywidth(narrow_text))
    assert.matches("^…", narrow_text)
    assert.matches("…$", narrow_text)
    local near_footer = result:_transcript_footer(32)
    local near_text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, near_footer))
    assert.are.equal(32, vim.fn.strdisplaywidth(near_text))
    assert.matches("Compacting%.%.%.", near_text)
    local tiny_footer = result:_transcript_footer(1)
    assert.are.equal("…", table.concat(vim.tbl_map(function(chunk) return chunk[1] end, tiny_footer)))
    assert.matches("Compacting%.%.%.", transcript_footer())
    assert.is_nil(transcript_footer():find("think:", 1, true))
    assert.is_not_nil(transcript_footer():find(
      "ctx 250/1k (25.0%) (5h 80% left · weekly 60% left)", 1, true
    ))
    assert.are.equal(vim.api.nvim_win_get_width(result.transcript_win),
      vim.fn.strdisplaywidth(transcript_footer()))
    local input_config = vim.api.nvim_win_get_config(result.input_win)
    assert.is_nil(input_config.title)
    assert.are.equal("center", input_config.footer_pos)
    assert.are.equal(
      " <C-r> history · <A-r> resume · <A-m> select model · <C-c> clear/cancel ",
      input_footer())
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
    assert.are.equal(
      " <C-r> history · <A-r> resume · <A-m> select model · <C-c> clear/cancel ",
      input_footer())
    assert.is_nil(transcript_footer():find("5h 80% left", 1, true))
    assert.is_not_nil(transcript_footer():find("ctx 250/1k (25.0%)", 1, true))
    assert.matches("Compacting%.%.%.", transcript_footer())
    assert.is_nil(text(result):match("Compacting%.%.%."))
    local first = transcript_footer()
    assert(vim.wait(1000, function()
      local current = transcript_footer()
      return current and current ~= first
    end))
    result:set_context({ state = "running" })
    assert.matches("Working%.%.%.", transcript_footer())
    assert.are.equal(activity_border, vim.api.nvim_win_get_config(result.transcript_win).footer[1][1])
    assert.is_nil(text(result):match("Working%.%.%."))
    result:set_context({ state = "idle", steering = {} })
    assert(vim.wait(1000, function()
      local footer_text = transcript_footer()
      return footer_text and footer_text:find("Working", 1, true) == nil
        and footer_text:find("Idle", 1, true) ~= nil
        and footer_text:find("think:", 1, true) == nil
        and footer_text:find("ctx 250/1k (25.0%)", 1, true) ~= nil
        and text(result):find("Steering:", 1, true) == nil
    end))
    assert.are.equal(activity_border, vim.api.nvim_win_get_config(result.transcript_win).footer[1][1])
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
        return text(result):find("line 40", 1, true) ~= nil
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
        return text(result):find("line 40", 1, true) ~= nil
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
      return text(result):find(" checking \n\n done ", 1, true) ~= nil
    end))
  end)

  it("defers transcript updates during Visual selection and responds to resize", function()
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
    local next_tick = false
    vim.schedule(function() next_tick = true end)
    assert(vim.wait(1000, function() return next_tick end))
    assert.is_nil(text(result):match("streamed later"))
    assert.are.equal(mode, vim.api.nvim_get_mode().mode)
    assert.are.same(cursor, vim.api.nvim_win_get_cursor(result.transcript_win))
    assert.are.same(anchor, vim.fn.getpos("v"))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    result:focus_input()
    vim.api.nvim_exec_autocmds("SafeState", {})
    assert(vim.wait(1000, function() return text(result):match("streamed later") ~= nil end))
    local old_width = vim.api.nvim_win_get_width(result.transcript_win)
    vim.o.columns = 90
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(vim.wait(1000, function()
      return vim.api.nvim_win_get_width(result.transcript_win) ~= old_width
    end))
  end)

end)
