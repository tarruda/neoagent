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

  local function view(overrides, tools)
    local ui_config = config.setup({ ui = overrides or {} }).ui
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
      submit = { "<C-s>", "<CR>" },
      newline = false,
      card_previous = "g[",
      interrupt = false,
    } })
    assert.are.equal(" <C-s> send · g[ transcript ",
      result:_input_footer(80))
    local narrow = result:_input_footer(18)
    assert.is_true(vim.fn.strdisplaywidth(narrow) <= 18)
    assert.matches("^ <C%-s>", narrow)
    assert.is_not_nil(narrow:find("<C%-s> send"))
    assert.is_nil(narrow:find("transcript", 1, true))
  end)

  it("updates input mapping hints for focus, mode, and card position", function()
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
        == " <CR> send · <C-j> newline · <A-k> transcript · <C-c> clear/cancel "
    end))

    vim.cmd("stopinsert")
    vim.api.nvim_exec_autocmds("InsertLeave", { buffer = result.input_buf })
    assert(vim.wait(1000, function()
      return footer() == " <CR> send · <A-k> transcript · <C-c> clear/cancel "
    end))

    result:focus_transcript()
    local rows = {}
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("first", 1, true) then rows.first = row end
      if line:find("latest", 1, true) then rows.latest = row end
    end
    vim.api.nvim_win_set_cursor(result.transcript_win, { rows.first, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = result.transcript_buf,
    })
    assert(vim.wait(1000, function()
      return footer()
        == " <CR> details · <A-k> previous · <A-j> next · <C-c> clear/cancel "
    end))

    vim.api.nvim_win_set_cursor(result.transcript_win, { rows.latest, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = result.transcript_buf,
    })
    assert(vim.wait(1000, function()
      return footer()
        == " <CR> details · <A-k> previous · <A-j> input · <C-c> clear/cancel "
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

  it("renders semantic presentations supplied by active tools", function()
    local tool = {
      name = "present",
      render = function(opts)
        assert.are.equal("value", opts.arguments.label)
        assert.are.equal("success", opts.state)
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
      { position = "center", width = 44 },
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
      { position = "center", width = 44 },
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
      " • Updated Plan",
      "   └ Implement in three focused phases.",
      "     ✔ Inspect Codex behavior",
      "     □ Add the optional tool",
      "     □ Verify the UI",
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
      " <CR> send · <C-j> newline · <A-k> transcript · <C-c> clear/cancel ",
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
      " <CR> send · <C-j> newline · <A-k> transcript · <C-c> clear/cancel ",
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
