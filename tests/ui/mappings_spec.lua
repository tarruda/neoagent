local config = require("neoagent.config")
local ui = require("neoagent.ui")
local view_handles = require("tests.helpers.view_handles")

describe("neoagent UI mappings", function()
  it("opens full details for the transcript card under the cursor", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    local command = "printf " .. string.rep("x", 90) .. " command-end"
    local output = {}
    for index = 1, 15 do output[index] = "shell line " .. index end
    local shell_output = table.concat(output, "\n")
    result:set_messages({
      { role = "assistant", content = { { type = "text", text = "outside card" }, {
        type = "toolCall", id = "shell", name = "shell", arguments = { command = command },
      } } },
      { role = "toolResult", toolCallId = "shell", toolName = "shell", isError = false,
        content = { { type = "text", text = shell_output } },
        details = { ansi = shell_output } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false)
      return vim.iter(lines):any(function(line) return line:find("5 more lines", 1, true) ~= nil end)
    end))
    result:focus_transcript()

    local transcript = vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false)
    local prose_row, shell_row
    for row, line in ipairs(transcript) do
      if line:find("outside card", 1, true) then prose_row = row end
      if line:find("$ printf", 1, true) then shell_row = row end
    end
    assert.is_not_nil(prose_row)
    assert.is_not_nil(shell_row)
    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { prose_row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view_handles.window(result, "details") and vim.api.nvim_win_is_valid(view_handles.window(result, "details"))
    end))
    assert.matches("Text", vim.api.nvim_win_get_config(view_handles.window(result, "details")).title[1][1])
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return view_handles.window(result, "details") == nil end))

    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { shell_row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view_handles.window(result, "details") and vim.api.nvim_win_is_valid(view_handles.window(result, "details"))
    end))
    assert.are.equal(view_handles.window(result, "details"), vim.api.nvim_get_current_win())
    assert.is_false(vim.bo[view_handles.buffer(result, "details")].modifiable)
    assert.is_true(vim.bo[view_handles.buffer(result, "details")].readonly)
    local details = table.concat(
      vim.api.nvim_buf_get_lines(view_handles.buffer(result, "details"), 0, -1, false), "\n")
    assert.is_not_nil(details:find(command, 1, true))
    assert.is_not_nil(details:find("shell line 1", 1, true))
    assert.is_not_nil(details:find("shell line 15", 1, true))
    local unchanged = table.concat(
      vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false), "\n")
    assert.is_not_nil(unchanged:find("5 more lines", 1, true))
    assert.is_nil(unchanged:find("command-end", 1, true))
    assert.is_nil(unchanged:find("shell line 1\n", 1, true))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view_handles.window(result, "details") == nil
        and vim.api.nvim_get_current_win() == view_handles.window(result, "transcript")
    end))
    result:destroy()
  end)

  it("preserves the transcript view while card details are open", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    local messages = {}
    for index = 1, 30 do
      messages[index] = { role = "user", content = "card " .. index }
    end
    result:set_messages(messages)
    assert(result:open())
    assert(vim.wait(1000, function()
      return vim.iter(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false)):any(function(line)
          return line:find("card 30", 1, true) ~= nil
        end)
    end))
    result:focus_transcript()

    local target
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      view_handles.buffer(result, "transcript"), 0, -1, false)) do
      if line:find("card 8", 1, true) then target = row break end
    end
    assert.is_not_nil(target)
    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { target, 0 })
    vim.api.nvim_win_call(view_handles.window(result, "transcript"), function()
      vim.cmd("normal! zt")
    end)
    local cursor = vim.api.nvim_win_get_cursor(view_handles.window(result, "transcript"))
    local view = vim.api.nvim_win_call(
      view_handles.window(result, "transcript"), function() return vim.fn.winsaveview() end)

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view_handles.window(result, "details") and vim.api.nvim_win_is_valid(view_handles.window(result, "details"))
    end))
    local opened_view = vim.api.nvim_win_call(
      view_handles.window(result, "transcript"), function() return vim.fn.winsaveview() end)
    assert.are.same(cursor, vim.api.nvim_win_get_cursor(view_handles.window(result, "transcript")))
    assert.are.equal(view.topline, opened_view.topline)
    result:destroy()
  end)

  it("centers the expanded card in the transcript without moving focus", function()
    local result = ui.new({
      config = config.setup({ ui = {
        position = "center",
        height = 16,
        input_height = 3,
      } }).ui,
    })
    local messages = {}
    for index = 1, 30 do
      messages[index] = { role = "user", content = "card " .. index }
    end
    result:set_messages(messages)
    assert(result:open())
    assert(vim.wait(1000, function()
      return vim.iter(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false)):any(
          function(line) return line:find("card 30", 1, true) ~= nil end)
    end))
    result:focus_transcript()

    local card_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      view_handles.buffer(result, "transcript"), 0, -1, false)) do
      if line:find("card 12", 1, true) then card_row = row break end
    end
    assert.is_not_nil(card_row)
    local transcript_window = view_handles.window(result, "transcript")
    vim.api.nvim_win_set_cursor(transcript_window, { card_row, 0 })
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view_handles.window(result, "details")
        and vim.api.nvim_win_is_valid(view_handles.window(result, "details"))
    end))
    local details_window = view_handles.window(result, "details")
    vim.api.nvim_win_call(transcript_window, function()
      vim.cmd("normal! Gzt")
    end)
    local before = vim.api.nvim_win_call(transcript_window, function()
      return vim.fn.line("w0")
    end)
    assert.is_true(before > card_row)

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("zz", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local block = result.details and result.details.block
      local target = block and result.transcript.pane.layout.targets[
        "card:" .. block.key]
      return target and vim.api.nvim_win_get_cursor(transcript_window)[1]
        == target.point.row + 1
    end))
    assert.are.equal(details_window, vim.api.nvim_get_current_win())
    local cursor = vim.api.nvim_win_get_cursor(transcript_window)[1]
    local visible = vim.api.nvim_win_call(transcript_window, function()
      return { vim.fn.line("w0"), vim.fn.line("w$") }
    end)
    assert.is_true(math.abs(cursor - (visible[1] + visible[2]) / 2) <= 1)
    result:destroy()
  end)

  it("toggles raw Markdown for text and thinking details only", function()
    local result = ui.new({
      config = config.setup({ ui = {
        position = "center",
      } }).ui,
    })
    local thinking = "# Trace\n\n"
      .. string.rep("exact-streamed-thinking ", 40)
      .. "stream-end"
    local response = "**Answer**\n\n- item"
    result:set_messages({
      { role = "assistant", content = {
        { type = "thinking", thinking = thinking },
        { type = "text", text = response },
        { type = "toolCall", id = "read", name = "read_file",
          arguments = { path = "notes.md" } },
      } },
      { role = "toolResult", toolCallId = "read", toolName = "read_file",
        isError = false, content = { { type = "text", text = "contents" } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      local rendered = table.concat(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false), "\n")
      return rendered:find("Trace", 1, true) ~= nil
        and rendered:find("Answer", 1, true) ~= nil
        and rendered:find("read notes.md", 1, true) ~= nil
    end))
    result:focus_transcript()

    local rows = {}
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      view_handles.buffer(result, "transcript"), 0, -1, false)) do
      if line:find("Trace", 1, true) then rows.thinking = row end
      if line:find("Answer", 1, true) then rows.text = row end
      if line:find("read notes.md", 1, true) then rows.tool = row end
    end
    assert.is_not_nil(rows.thinking)
    assert.is_not_nil(rows.text)
    assert.is_not_nil(rows.tool)

    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function details()
      return table.concat(
        vim.api.nvim_buf_get_lines(view_handles.buffer(result, "details"), 0, -1, false), "\n")
    end
    local function title()
      local chunks = vim.api.nvim_win_get_config(view_handles.window(result, "details")).title or {}
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))
    end
    local function check_toggle(row, raw)
      vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { row, 0 })
      feed("<CR>")
      assert(vim.wait(1000, function()
        return view_handles.window(result, "details") and vim.api.nvim_win_is_valid(view_handles.window(result, "details"))
      end))
      assert.are_not.equal(raw, details())
      assert.matches("r raw", title())
      feed("r")
      assert(vim.wait(1000, function() return result.details.raw end))
      assert(result.details.pane:flush())
      assert.are.equal(raw, details())
      assert.is_true(vim.wo[view_handles.window(result, "details")].wrap)
      assert.matches("r rendered", title())
      feed("r")
      assert(vim.wait(1000, function() return details() ~= raw end))
      feed("<C-c>")
      assert(vim.wait(1000, function() return view_handles.window(result, "details") == nil end))
    end
    check_toggle(rows.thinking, thinking)
    check_toggle(rows.text, response)

    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { rows.tool, 0 })
    feed("<CR>")
    assert(vim.wait(1000, function()
      return view_handles.window(result, "details") and vim.api.nvim_win_is_valid(view_handles.window(result, "details"))
    end))
    vim.api.nvim_buf_call(view_handles.buffer(result, "details"), function()
      assert.are.equal("", vim.fn.maparg("R", "n"))
      assert.are.equal("", vim.fn.maparg("r", "n"))
    end)
    assert.is_nil(title():find("r raw", 1, true))
    feed("<C-c>")
    assert(vim.wait(1000, function() return view_handles.window(result, "details") == nil end))
    result:destroy()
  end)

  it("toggles periodic following for expanded transcript cards", function()
    local result = ui.new({
      config = config.setup({ ui = {
        position = "center",
      } }).ui,
    })
    local thinking = {}
    for index = 1, 80 do
      thinking[index] = "streamed thought " .. index
    end
    local source = table.concat(thinking, "\n")
    result:set_context({ state = "running" })
    result:apply({ type = "thinking_delta", text = source })
    assert(result:open())
    assert(result.transcript.pane:flush())
    local block
    for _, candidate in ipairs(result.blocks) do
      if candidate.kind == "thinking" then block = candidate break end
    end
    assert.is_not_nil(block)
    assert.is_true(result:show_card_details(block.key))

    local window = view_handles.window(result, "details")
    local buffer = view_handles.buffer(result, "details")
    local function title()
      local chunks = vim.api.nvim_win_get_config(window).title or {}
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end,
        chunks))
    end
    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function scroll_to_start()
      vim.api.nvim_win_call(window, function()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("normal! zt")
      end)
    end
    local function at_end()
      local last = vim.api.nvim_buf_line_count(buffer)
      return vim.api.nvim_win_get_cursor(window)[1] == last
        and vim.api.nvim_win_call(window,
          function() return vim.fn.line("w$") end) == last
    end

    assert.is_true(vim.api.nvim_buf_line_count(buffer)
      > vim.api.nvim_win_get_height(window))
    assert.matches("<A%-f> follow", title())
    scroll_to_start()
    feed("<A-f>")
    assert(vim.wait(1000, at_end))
    assert(vim.wait(1000, function()
      return title():match("following.*<A%-f> toggle") ~= nil
    end))

    scroll_to_start()
    assert(vim.wait(1000, at_end))
    feed("<A-f>")
    assert(vim.wait(1000, function()
      return title():match("<A%-f> follow") ~= nil
    end))
    scroll_to_start()
    local elapsed = false
    vim.defer_fn(function() elapsed = true end, 350)
    assert(vim.wait(1000, function() return elapsed end))
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(window))
    assert.are.equal(1, vim.api.nvim_win_call(
      window, function() return vim.fn.line("w0") end))

    feed("<A-f>")
    assert(vim.wait(1000, at_end))
    result:apply({
      type = "message_end",
      message = { role = "assistant", content = { {
        type = "thinking", thinking = source,
      } } },
    })
    assert(vim.wait(1000, function()
      local mapped = vim.api.nvim_buf_call(
        buffer, function() return vim.fn.maparg("<A-f>", "n") end)
      return mapped == "" and not title():find("following", 1, true)
        and not title():find("<A-f>", 1, true)
    end))
    scroll_to_start()
    elapsed = false
    vim.defer_fn(function() elapsed = true end, 350)
    assert(vim.wait(1000, function() return elapsed end))
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(window))
    result:destroy()
  end)

  it("navigates vertically between transcript cards and input across modes", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    result:set_messages({
      { role = "user", content = "first card" },
      { role = "assistant", content = { { type = "text", text = "between cards" } } },
      { role = "user", content = "second card" },
      { role = "user", content = "third card" },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return vim.iter(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false)):any(function(line)
          return line:find("third card", 1, true) ~= nil
        end)
    end))
    result:focus_transcript()

    local rows = {}
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      view_handles.buffer(result, "transcript"), 0, -1, false)) do
      for _, label in ipairs({ "first card", "between cards", "second card", "third card" }) do
        if line:find(label, 1, true) then rows[label] = row end
      end
    end
    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function cursor_row()
      return vim.api.nvim_win_get_cursor(view_handles.window(result, "transcript"))[1]
    end

    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { rows["between cards"], 0 })
    feed("<A-j>")
    assert.are.equal(rows["second card"], cursor_row())
    feed("<A-k>")
    assert.are.equal(rows["between cards"], cursor_row())
    feed("<A-k>")
    assert.are.equal(rows["first card"], cursor_row())

    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { rows["between cards"], 0 })
    feed("2<A-j>")
    assert.are.equal(rows["third card"], cursor_row())
    feed("3<A-k>")
    assert.are.equal(rows["first card"], cursor_row())
    feed("<A-k>")
    assert.are.equal(rows["first card"], cursor_row())
    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { rows["third card"], 0 })
    feed("<A-j>")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end))
    vim.cmd("stopinsert")
    feed("i<C-Up>")
    assert.are.equal(view_handles.window(result, "transcript"), vim.api.nvim_get_current_win())
    assert.are.equal(rows["third card"], cursor_row())
    feed("<C-Down>")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end))
    vim.cmd("stopinsert")
    feed("2<A-k>")
    assert.are.equal(view_handles.window(result, "transcript"), vim.api.nvim_get_current_win())
    assert.are.equal(rows["second card"], cursor_row())
    result:focus_input()
    vim.cmd("stopinsert")
    feed("<A-k>")
    assert.are.equal(rows["third card"], cursor_row())

    feed("<A-j>")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end))
    vim.cmd("stopinsert")
    feed("i<A-k>k")
    assert.are.equal(view_handles.window(result, "transcript"), vim.api.nvim_get_current_win())
    assert.are.equal(rows["third card"] - 1, cursor_row())
    assert.are.equal("n", vim.api.nvim_get_mode().mode)

    for _, buffer in ipairs({ view_handles.buffer(result, "input"), view_handles.buffer(result, "transcript") }) do
      vim.api.nvim_buf_call(buffer, function()
        assert.are.equal("", vim.fn.maparg("[c", "n"))
        assert.are.equal("", vim.fn.maparg("]c", "n"))
      end)
    end
    result:destroy()
  end)

  it("reveals the complete last card after leaving a scrolled transcript", function()
    local function exercise(scroll_on_transcript_leave)
      local result = ui.new({
        config = config.setup({ ui = {
          position = "center",
          height = 12,
          input_height = 3,
          scroll_on_transcript_leave = scroll_on_transcript_leave,
        } }).ui,
      })
      local messages = {}
      for index = 1, 10 do
        messages[#messages + 1] = {
          role = "user",
          content = "earlier card " .. index,
        }
      end
      messages[#messages + 1] = {
        role = "assistant",
        content = { {
          type = "text",
          text = "last card one\nlast card two\nlast card three",
        } },
      }
      result:set_messages(messages)
      assert(result:open())
      assert(vim.wait(1000, function()
        return vim.iter(vim.api.nvim_buf_get_lines(
          view_handles.buffer(result, "transcript"), 0, -1, false)):any(
            function(line) return line:find("last card three", 1, true) ~= nil end)
      end))

      local transcript = result.transcript.pane
      local targets = transcript:targets({ group = "transcript.cards" })
      local last = assert(targets[#targets])
      local target_row = last.point.row + 1
      local first_row, last_row = math.huge, 0
      for _, rectangle in ipairs(last.rectangles) do
        first_row = math.min(first_row, rectangle.row + 1)
        last_row = math.max(last_row, rectangle.row + rectangle.height)
      end
      local window = view_handles.window(result, "transcript")
      local function visible_rows()
        return vim.api.nvim_win_call(window, function()
          return { vim.fn.line("w0"), vim.fn.line("w$") }
        end)
      end
      local function feed(keys)
        vim.cmd("stopinsert")
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
      end

      feed("<A-k>")
      local initial = visible_rows()
      assert.is_true(last_row <= initial[2])

      feed("<A-k>")
      assert.is_true(vim.api.nvim_win_get_cursor(window)[1] < first_row)
      result:focus_input()
      if scroll_on_transcript_leave then
        local while_input = visible_rows()
        assert.is_true(last_row <= while_input[2])
      end
      feed("<A-k>")

      assert.are.equal(target_row,
        vim.api.nvim_win_get_cursor(window)[1])
      local restored = visible_rows()
      assert.is_true(last_row <= restored[2])
      result:destroy()
    end

    exercise(true)
    exercise(false)
  end)

  it("moves from the transcript document bottom into the input", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    result:set_messages({
      { role = "user", content = "first card" },
      { role = "assistant", content = { {
        type = "text", text = "last card",
      } } },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return vim.iter(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false)):any(function(line)
          return line:find("last card", 1, true) ~= nil
        end)
    end))
    result:focus_transcript()

    vim.api.nvim_feedkeys("G", "x", false)
    assert.are.equal(vim.api.nvim_buf_line_count(
      view_handles.buffer(result, "transcript")),
      vim.api.nvim_win_get_cursor(view_handles.window(result, "transcript"))[1])
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
      "<A-j>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end))
    result:destroy()
  end)

  it("moves focus to the input window from an open dialog", function()
    local responses = {}
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_dialog_action = function(id, action)
        responses[#responses + 1] = action
        return true
      end,
    })
    assert(result:open())
    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true),
        "x", false)
    end
    local function focused_input()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end

    result:set_dialog({
      active = {
        id = "approval",
        placement = "transcript",
        title = "Approval required",
        body = "Allow this operation?",
        actions = {
          { id = "approve", label = "approve", key = "y" },
          { id = "deny", label = "deny", key = "n" },
        },
      },
      queue_count = 0,
    })
    assert.are.equal(view_handles.window(result, "transcript"), vim.api.nvim_get_current_win())
    feed("<A-j>")
    assert(vim.wait(1000, focused_input))
    assert.are.same({}, responses)
    result:focus_transcript()
    feed("<C-w>j")
    assert(vim.wait(1000, focused_input))
    assert.are.same({}, responses)

    result:focus_transcript()
    feed("y")
    assert(vim.wait(1000, function() return responses[1] == "approve" end))
    assert.are.equal(1, #responses)

    result:set_dialog({
      active = {
        id = "confirm",
        placement = "float",
        title = "Approve operation",
        body = "Allow this operation?",
        actions = {
          { id = "allow", label = "allow", key = "y" },
          { id = "deny", label = "deny", key = "n" },
        },
      },
      queue_count = 0,
    })
    assert.are.equal(view_handles.window(result, "dialog"), vim.api.nvim_get_current_win())
    feed("<A-j>")
    assert(vim.wait(1000, focused_input))
    assert.are.same({ "approve" }, responses)

    result:set_dialog({
      active = {
        id = "prefix",
        placement = "float",
        title = "Remember command prefix",
        body = "Edit the command prefix.",
        input = {
          label = "Command prefix",
          value = "make",
          multiline = false,
        },
        actions = {
          { id = "accept", label = "accept", key = "<CR>" },
          { id = "cancel", label = "cancel", key = "<C-c>" },
        },
      },
      queue_count = 0,
    })
    assert.are.equal(view_handles.window(result, "dialog"), vim.api.nvim_get_current_win())
    feed("<A-j>")
    assert(vim.wait(1000, focused_input))
    assert.are.same({ "approve" }, responses)
    result:destroy()
  end)

  it("moves directly between the transcript and input windows", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    result:set_messages({ { role = "user", content = "transcript card" } })
    assert(result:open())
    assert(vim.wait(1000, function()
      return vim.iter(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false)):any(function(line)
          return line:find("transcript card", 1, true) ~= nil
        end)
    end))
    result:set_input("untouched draft")
    result:focus_transcript()

    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    feed("<C-w>j")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end))
    feed("i<C-w>k")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "transcript")
        and vim.api.nvim_get_mode().mode:sub(1, 1) == "n"
    end))
    assert.are.equal("untouched draft", result:get_input())
    result:destroy()
  end)

  it("navigates between cards while their details own focus", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    result:set_messages({
      { role = "user", content = "first card" },
      { role = "user", content = "second card" },
      { role = "user", content = "third card" },
    })
    assert(result:open())
    assert(vim.wait(1000, function()
      return vim.iter(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false)):any(function(line)
          return line:find("third card", 1, true) ~= nil
        end)
    end))
    result:focus_transcript()

    local second_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      view_handles.buffer(result, "transcript"), 0, -1, false)) do
      if line:find("second card", 1, true) then second_row = row break end
    end
    assert.is_not_nil(second_row)
    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { second_row, 0 })
    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function details_contain(value)
      if not view_handles.buffer(result, "details") or not vim.api.nvim_buf_is_valid(view_handles.buffer(result, "details")) then
        return false
      end
      return table.concat(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "details"), 0, -1, false), "\n"):find(value, 1, true) ~= nil
    end

    feed("<CR>")
    assert(vim.wait(1000, function() return details_contain("second card") end))
    feed("<A-k>")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "details")
        and details_contain("first card")
    end))
    feed("<A-j>")
    assert(vim.wait(1000, function() return details_contain("second card") end))
    feed("<A-j>")
    assert(vim.wait(1000, function() return details_contain("third card") end))
    feed("<A-j>")
    assert(vim.wait(1000, function()
      return view_handles.window(result, "details") == nil
        and vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end))
    result:destroy()
  end)

  it("uses native Ctrl-J for newlines without submitting", function()
    local submissions = {}
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_submit = function(value)
        submissions[#submissions + 1] = value
        return true
      end,
    })
    assert(result:open())
    vim.api.nvim_buf_call(view_handles.buffer(result, "input"), function()
      assert.are.equal("", vim.fn.maparg("<C-j>", "i"))
    end)
    result:set_input("first")
    result:focus_input()
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
      "A<C-j>second", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return result:get_input() == "first\nsecond"
    end))
    assert.are.same({}, submissions)
    result:destroy()
  end)

  it("uses real encoded input for submit, cancellation, focus, and close", function()
    local submitted
    local thinking_cycles = 0
    local agent_switchers = 0
    local model_selections = 0
    local session_selections = 0
    local stops = 0
    local queued = {}
    local origin = vim.api.nvim_get_current_win()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_submit = function(value) submitted = value end,
      on_cycle_thinking = function() thinking_cycles = thinking_cycles + 1 end,
      on_agents = function()
        agent_switchers = agent_switchers + 1
      end,
      on_select_model = function() model_selections = model_selections + 1 end,
      on_resume_session = function() session_selections = session_selections + 1 end,
      on_stop = function() stops = stops + 1 return true end,
      on_dequeue_steering = function()
        local messages = queued
        queued = {}
        return messages
      end,
    })
    assert(result:open())
    result:set_input("send me")
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
      "i<A-m><A-r>", true, false, true), "x", false)
    assert.are.equal(1, model_selections)
    assert.are.equal(1, session_selections)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc><CR>", true, false, true), "x", false)
    assert.is_not_nil(submitted)
    assert.are.equal("send me", submitted)
    result:set_input("current draft")
    queued = { "first steer", "second steer" }
    result:set_context({ state = "running", steering = vim.deepcopy(queued) })
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<A-Up>", true, false, true), "x", false)
    assert.are.equal("first steer\n\nsecond steer\n\ncurrent draft", result:get_input())
    assert.are.equal(0, stops)
    result:set_context({ state = "idle", steering = {} })
    result:set_input("send me")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "x", false)
    assert.are.equal(1, thinking_cycles)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-n>", true, false, true), "x", false)
    assert.are.equal(1, agent_switchers)
    result:focus_transcript()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-m>", true, false, true), "x", false)
    assert.are.equal(2, model_selections)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-r>", true, false, true), "x", false)
    assert.are.equal(2, session_selections)
    result:focus_input()
    result:set_input("discard")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "" end))
    vim.keymap.set({ "n", "i" }, "<C-a>", function() result:close() end, { buffer = view_handles.buffer(result, "input") })
    result:focus_input()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>i<C-a>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return not result:is_open() and vim.api.nvim_get_current_win() == origin
        and vim.api.nvim_get_mode().mode:sub(1, 1) == "n"
    end))
    result:destroy()
  end)

  it("clears a nonempty draft before interrupting", function()
    local stops = 0
    local dequeues = 0
    local queued = { "pending steer" }
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_stop = function() stops = stops + 1 return true end,
      on_dequeue_steering = function()
        dequeues = dequeues + 1
        local messages = queued
        queued = {}
        return messages
      end,
    })
    assert(result:open())
    result:set_context({ state = "running", steering = vim.deepcopy(queued) })
    result:set_input("current draft")
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("i<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return result:get_input() == "" and vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end))
    assert.are.equal(0, stops)
    assert.are.equal(0, dequeues)
    assert.are.same({ "pending steer" }, queued)

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert.are.equal(1, stops)
    assert.are.equal(1, dequeues)
    assert.are.equal("pending steer", result:get_input())

    result:set_context({ state = "running", steering = {} })
    result:set_input("transcript draft")
    result:focus_transcript()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return result:get_input() == "" and vim.api.nvim_get_current_win() == view_handles.window(result, "input")
    end))
    assert.are.equal(1, stops)
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert.are.equal(2, stops)

    result:set_context({ state = "idle", steering = {} })
    result:set_input("")
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert.are.equal(2, stops)
    assert.is_true(result:is_open())
    result:destroy()
  end)

  it("leaves Ctrl-W input editing to Neovim", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    assert(result:open())
    result:set_input("first second")
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("A<C-w>w", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == view_handles.window(result, "input")
        and result:get_input() == "first w"
    end))
    for _, buffer in ipairs({ view_handles.buffer(result, "input"), view_handles.buffer(result, "transcript") }) do
      vim.api.nvim_buf_call(buffer, function()
        for _, mode in ipairs({ "n", "i", "x" }) do
          assert.are.equal("", vim.fn.maparg("<C-w>w", mode))
          assert.are.equal("", vim.fn.maparg("<C-w><C-w>", mode))
        end
      end)
    end
    result:destroy()
  end)

  it("replays the selected list-valued close-empty mapping", function()
    local result = ui.new({
      config = config.setup({ ui = {
        position = "center",
        mappings = { close_empty = { "<C-d>", "<BS>" } },
      } }).ui,
    })
    assert(result:open())
    result:set_input("draft")
    result:focus_input()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<BS>", true, false, true),
      "x", false)
    assert.are.equal("draf", result:get_input())
    assert.is_true(result:is_open())
    result:set_input("")
    result:focus_input()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-d>", true, false, true),
      "x", false)
    assert(vim.wait(1000, function() return not result:is_open() end))
    result:destroy()
  end)

  it("leaves window-management chords available to Neovim", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    assert(result:open())
    vim.cmd("stopinsert")
    for _, buffer in ipairs({ view_handles.buffer(result, "input"), view_handles.buffer(result, "transcript") }) do
      vim.api.nvim_buf_call(buffer, function()
        for _, key in ipairs({ "<C-w>H", "<C-w>J", "<C-w>K", "<C-w>L", "<C-w>=" }) do
          assert.are.equal("", vim.fn.maparg(key, "n"))
        end
      end)
    end
    result:destroy()
  end)

  it("animates the transcript footer without mutating yankable text", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    result:set_messages({ {
      role = "assistant",
      content = { { type = "text", text = "yank target" } },
    } })
    assert(result:open())
    result:set_context({ state = "running" })
    local function footer()
      local value = vim.api.nvim_win_get_config(view_handles.window(result, "transcript")).footer
      if type(value) == "table" then
        value = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, value))
      end
      return value
    end
    assert(vim.wait(1000, function() return footer() and footer():match("Working%.%.%.") end))
    local lines = vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false)
    local changedtick = vim.api.nvim_buf_get_changedtick(view_handles.buffer(result, "transcript"))
    local first = footer()
    assert(vim.wait(1000, function() return footer() ~= first end))
    assert.are.same(lines, vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false))
    assert.are.equal(changedtick, vim.api.nvim_buf_get_changedtick(view_handles.buffer(result, "transcript")))

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { 1, 0 })
    vim.fn.setreg("+", "sentinel")
    vim.api.nvim_feedkeys('"+yy', "x", false)
    local yanked = vim.fn.getreg("+")
    result:destroy()
    assert.matches("yank target", yanked)
  end)

  it("preserves a selected yank register while transcript text streams", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    result:set_messages({ {
      role = "assistant",
      content = { { type = "text", text = "streaming yank target" } },
    } })
    assert(result:open())
    result:set_context({ state = "running" })
    result:focus_transcript()
    vim.api.nvim_win_set_cursor(view_handles.window(result, "transcript"), { 1, 0 })
    vim.fn.setreg("a", "sentinel")

    vim.api.nvim_feedkeys('"a', "x", false)
    assert.matches("o", vim.fn.state("oS"))
    assert.are.equal("a", vim.v.register)
    local lines = vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false)
    local changedtick = vim.api.nvim_buf_get_changedtick(view_handles.buffer(result, "transcript"))

    result:apply({ type = "text_delta", text = "streamed response" })
    local next_tick = false
    vim.schedule(function() next_tick = true end)
    assert(vim.wait(1000, function() return next_tick end))
    assert.are.same(lines, vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false))
    assert.are.equal(changedtick, vim.api.nvim_buf_get_changedtick(view_handles.buffer(result, "transcript")))
    assert.are.equal("sentinel", vim.fn.getreg("a"))
    assert.matches("o", vim.fn.state("oS"))
    assert.are.equal("a", vim.v.register)

    result:focus_input()
    vim.api.nvim_exec_autocmds("SafeState", {})
    assert(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false
      ), "\n"):match("streamed response") ~= nil
    end))
    result:destroy()
  end)

  it("defers streaming while an input yank is operator-pending", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    result:set_messages({ {
      role = "assistant",
      content = { { type = "text", text = "existing response" } },
    } })
    assert(result:open())
    result:set_context({ state = "running" })
    result:set_input("clipboard input target")
    result:focus_input()
    local focus_settled = false
    vim.schedule(function() focus_settled = true end)
    assert(vim.wait(1000, function() return focus_settled end))
    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(view_handles.window(result, "input"), { 1, 0 })
    vim.fn.setreg("+", "sentinel")

    vim.api.nvim_feedkeys('"+y', "x", false)
    assert.matches("o", vim.fn.state("oS"))
    assert.are.equal("+", vim.v.register)
    assert.are.equal("y", vim.v.operator)
    local lines = vim.api.nvim_buf_get_lines(
      view_handles.buffer(result, "transcript"), 0, -1, false)
    local changedtick = vim.api.nvim_buf_get_changedtick(view_handles.buffer(result, "transcript"))

    result:apply({ type = "text_delta", text = "streamed response" })
    local next_tick = false
    vim.schedule(function() next_tick = true end)
    assert(vim.wait(1000, function() return next_tick end))
    assert.are.same(lines,
      vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false))
    assert.are.equal(changedtick,
      vim.api.nvim_buf_get_changedtick(view_handles.buffer(result, "transcript")))
    assert.matches("o", vim.fn.state("oS"))
    assert.are.equal("+", vim.v.register)
    assert.are.equal("y", vim.v.operator)

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    vim.api.nvim_exec_autocmds("SafeState", {})
    assert(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(
        view_handles.buffer(result, "transcript"), 0, -1, false
      ), "\n"):match("streamed response") ~= nil
    end))
    result:destroy()
  end)

  it("yanks an input Visual selection to the clipboard while streaming", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    result:set_messages({ {
      role = "assistant",
      content = { { type = "text", text = "existing response" } },
    } })
    assert(result:open())
    result:set_context({ state = "running" })
    result:set_input("clipboard target")
    result:focus_input()
    local focus_settled = false
    vim.schedule(function() focus_settled = true end)
    assert(vim.wait(1000, function() return focus_settled end))
    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(view_handles.window(result, "input"), { 1, 0 })
    vim.fn.setreg("+", "sentinel")
    vim.cmd("normal! v8l")
    local mode = vim.api.nvim_get_mode().mode
    local cursor = vim.api.nvim_win_get_cursor(view_handles.window(result, "input"))
    local anchor = vim.fn.getpos("v")
    local lines = vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false)
    local changedtick = vim.api.nvim_buf_get_changedtick(view_handles.buffer(result, "transcript"))
    local footer = vim.deepcopy(vim.api.nvim_win_get_config(view_handles.window(result, "transcript")).footer)

    result:apply({ type = "text_delta", text = "streamed response" })
    result:set_context({ provider_status = "updated" })
    local next_tick = false
    vim.schedule(function() next_tick = true end)
    assert(vim.wait(1000, function() return next_tick end))
    assert.are.equal(mode, vim.api.nvim_get_mode().mode)
    assert.are.same(cursor, vim.api.nvim_win_get_cursor(view_handles.window(result, "input")))
    assert.are.same(anchor, vim.fn.getpos("v"))
    assert.are.same(lines, vim.api.nvim_buf_get_lines(view_handles.buffer(result, "transcript"), 0, -1, false))
    assert.are.equal(changedtick, vim.api.nvim_buf_get_changedtick(view_handles.buffer(result, "transcript")))
    assert.are.same(footer, vim.api.nvim_win_get_config(view_handles.window(result, "transcript")).footer)

    vim.api.nvim_feedkeys('"+y', "x", false)
    local yanked = vim.fn.getreg("+")
    result:close()
    assert(result:open())
    assert.matches("streamed response", table.concat(vim.api.nvim_buf_get_lines(
      view_handles.buffer(result, "transcript"), 0, -1, false
    ), "\n"))
    result:destroy()
    assert.are.equal("clipboard", yanked)
  end)

  it("closes the paired windows from input Normal mode and an empty draft", function()
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
    })
    local origin = vim.api.nvim_get_current_win()
    assert(result:open())
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == view_handles.window(result, "input") end))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return result:is_open() and vim.api.nvim_get_mode().mode:sub(1, 1) == "n"
    end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc><Esc>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return not result:is_open() and vim.api.nvim_get_current_win() == origin
    end))

    assert(result:open())
    result:set_input("keep")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:is_open() end))
    assert.are.equal("keep", result:get_input())
    result:set_input("")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return not result:is_open() and vim.api.nvim_get_current_win() == origin
    end))
    result:destroy()
  end)

  it("completes filenames through the input popup menu", function()
    local submissions = {}
    local popup_seen = false
    local candidates = {}
    local completed
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_submit = function(value)
        submissions[#submissions + 1] = value
        return true
      end,
    })
    assert(result:open())
    vim.api.nvim_create_autocmd("CompleteChanged", {
      group = result.augroup,
      buffer = view_handles.buffer(result, "input"),
      callback = function()
        popup_seen = vim.fn.pumvisible() == 1
        candidates = vim.deepcopy(vim.fn.complete_info({ "items" }).items)
      end,
    })
    vim.api.nvim_create_autocmd("CompleteDone", {
      group = result.augroup,
      buffer = view_handles.buffer(result, "input"),
      callback = function() completed = vim.deepcopy(vim.v.completed_item) end,
    })

    local prompt = "inspect lua/neoagent/a"
    result:set_input(prompt)
    result:focus_input()
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
      "A<Tab><Tab><Up><Down><CR>", true, false, true), "x", false)

    assert.is_true(popup_seen)
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(item) return item.word end, candidates),
      "lua/neoagent/agent.lua"))
    assert.are.equal("lua/neoagent/agent.lua", completed.word)
    assert.are.equal("inspect lua/neoagent/agent.lua", result:get_input())
    assert.are.equal(0, #submissions)

    result:focus_input()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.are.same({ "inspect lua/neoagent/agent.lua" }, submissions)
    result:destroy()

    local disabled = ui.new({
      config = config.setup({ ui = { position = "center", completion = false } }).ui,
    })
    assert(disabled:open())
    disabled:set_input(prompt)
    disabled:focus_input()
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A<Tab>", true, false, true), "x", false)
    assert.are.equal(prompt .. "\t", disabled:get_input())
    disabled:destroy()
  end)

  it("browses multiline input history and opens history selection", function()
    local selections = 0
    local history = { "newest\ncontinued", "oldest" }
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_input_history = function() return vim.deepcopy(history) end,
      on_select_history = function() selections = selections + 1 end,
    })
    assert(result:open())
    vim.cmd("stopinsert")
    result:set_input("draft")
    vim.api.nvim_win_set_cursor(view_handles.window(result, "input"), { 1, 5 })

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local cursor = vim.api.nvim_win_get_cursor(view_handles.window(result, "input"))
      return result:get_input() == "draft" and cursor[1] == 1 and cursor[2] == 0
    end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "newest\ncontinued" end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest" end))
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_text(view_handles.buffer(result, "input"), 0, 6, 0, 6, { "!" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = view_handles.buffer(result, "input") })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest!" end))
    vim.cmd("stopinsert")
    result:set_input("draft")
    vim.api.nvim_win_set_cursor(view_handles.window(result, "input"), { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up><Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest" end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local cursor = vim.api.nvim_win_get_cursor(view_handles.window(result, "input"))
      return result:get_input() == "newest\ncontinued" and cursor[1] == 2 and cursor[2] == 9
    end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local cursor = vim.api.nvim_win_get_cursor(view_handles.window(result, "input"))
      return result:get_input() == "draft" and cursor[1] == 1 and cursor[2] == 0
    end))

    result:set_input("")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<C-k>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "newest\ncontinued" end))
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = view_handles.buffer(result, "input") })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<C-k>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest" end))
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = view_handles.buffer(result, "input") })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "newest\ncontinued" end))
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = view_handles.buffer(result, "input") })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "" end))

    result:set_input("first\nsecond")
    vim.api.nvim_win_set_cursor(view_handles.window(result, "input"), { 2, 3 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return vim.api.nvim_win_get_cursor(view_handles.window(result, "input"))[1] == 1
        and result:get_input() == "first\nsecond"
    end))
    vim.api.nvim_win_set_cursor(view_handles.window(result, "input"), { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local cursor = vim.api.nvim_win_get_cursor(view_handles.window(result, "input"))
      return cursor[1] == 2 and cursor[2] >= 5
    end))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<C-r>", true, false, true), "x", false)
    assert.are.equal(1, selections)
    result:focus_transcript()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-r>", true, false, true), "x", false)
    assert.are.equal(2, selections)
    result:destroy()
  end)
end)
