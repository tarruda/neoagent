local config = require("neoagent.config")
local ui = require("neoagent.ui")

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
      local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
      return vim.iter(lines):any(function(line) return line:find("5 more lines", 1, true) ~= nil end)
    end))
    result:focus_transcript()

    local transcript = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    local prose_row, shell_row
    for row, line in ipairs(transcript) do
      if line:find("outside card", 1, true) then prose_row = row end
      if line:find("$ printf", 1, true) then shell_row = row end
    end
    assert.is_not_nil(prose_row)
    assert.is_not_nil(shell_row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { prose_row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return result.details_win and vim.api.nvim_win_is_valid(result.details_win)
    end))
    assert.matches("Text", vim.api.nvim_win_get_config(result.details_win).title[1][1])
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result.details_win == nil end))

    vim.api.nvim_win_set_cursor(result.transcript_win, { shell_row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return result.details_win and vim.api.nvim_win_is_valid(result.details_win)
    end))
    assert.are.equal(result.details_win, vim.api.nvim_get_current_win())
    assert.is_false(vim.bo[result.details_buf].modifiable)
    assert.is_true(vim.bo[result.details_buf].readonly)
    local details = table.concat(
      vim.api.nvim_buf_get_lines(result.details_buf, 0, -1, false), "\n")
    assert.is_not_nil(details:find(command, 1, true))
    assert.is_not_nil(details:find("shell line 1", 1, true))
    assert.is_not_nil(details:find("shell line 15", 1, true))
    local unchanged = table.concat(
      vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false), "\n")
    assert.is_not_nil(unchanged:find("5 more lines", 1, true))
    assert.is_nil(unchanged:find("command-end", 1, true))
    assert.is_nil(unchanged:find("shell line 1\n", 1, true))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return result.details_win == nil
        and vim.api.nvim_get_current_win() == result.transcript_win
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
        result.transcript_buf, 0, -1, false)):any(function(line)
          return line:find("card 30", 1, true) ~= nil
        end)
    end))
    result:focus_transcript()

    local target
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("card 8", 1, true) then target = row break end
    end
    assert.is_not_nil(target)
    vim.api.nvim_win_set_cursor(result.transcript_win, { target, 0 })
    vim.api.nvim_win_call(result.transcript_win, function()
      vim.cmd("normal! zt")
    end)
    local cursor = vim.api.nvim_win_get_cursor(result.transcript_win)
    local view = vim.api.nvim_win_call(
      result.transcript_win, function() return vim.fn.winsaveview() end)

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return result.details_win and vim.api.nvim_win_is_valid(result.details_win)
    end))
    local opened_view = vim.api.nvim_win_call(
      result.transcript_win, function() return vim.fn.winsaveview() end)
    assert.are.same(cursor, vim.api.nvim_win_get_cursor(result.transcript_win))
    assert.are.equal(view.topline, opened_view.topline)
    result:destroy()
  end)

  it("toggles raw Markdown for text and thinking details only", function()
    local result = ui.new({
      config = config.setup({ ui = {
        position = "center",
        mappings = { card_raw = { "R", "r" } },
      } }).ui,
    })
    local thinking = "# Trace\n\n*reason*"
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
    assert(vim.wait(1000, function() return not result.flush_pending end))
    result:focus_transcript()

    local rows = {}
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
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
        vim.api.nvim_buf_get_lines(result.details_buf, 0, -1, false), "\n")
    end
    local function title()
      local chunks = vim.api.nvim_win_get_config(result.details_win).title or {}
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))
    end
    local function check_toggle(row, raw)
      vim.api.nvim_win_set_cursor(result.transcript_win, { row, 0 })
      feed("<CR>")
      assert(vim.wait(1000, function()
        return result.details_win and vim.api.nvim_win_is_valid(result.details_win)
      end))
      assert.are_not.equal(raw, details())
      assert.matches("R raw", title())
      feed("R")
      assert(vim.wait(1000, function() return details() == raw end))
      assert.matches("R rendered", title())
      feed("R")
      assert(vim.wait(1000, function() return details() ~= raw end))
      feed("<C-c>")
      assert(vim.wait(1000, function() return result.details_win == nil end))
    end
    check_toggle(rows.thinking, thinking)
    check_toggle(rows.text, response)

    vim.api.nvim_win_set_cursor(result.transcript_win, { rows.tool, 0 })
    feed("<CR>")
    assert(vim.wait(1000, function()
      return result.details_win and vim.api.nvim_win_is_valid(result.details_win)
    end))
    vim.api.nvim_buf_call(result.details_buf, function()
      assert.are.equal("", vim.fn.maparg("R", "n"))
      assert.are.equal("", vim.fn.maparg("r", "n"))
    end)
    assert.is_nil(title():find("r raw", 1, true))
    result:_close_card_details(true)
    result:destroy()
  end)

  it("navigates vertically between transcript cards and input", function()
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
        result.transcript_buf, 0, -1, false)):any(function(line)
          return line:find("third card", 1, true) ~= nil
        end)
    end))
    result:focus_transcript()

    local rows = {}
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      for _, label in ipairs({ "first card", "between cards", "second card", "third card" }) do
        if line:find(label, 1, true) then rows[label] = row end
      end
    end
    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function cursor_row()
      return vim.api.nvim_win_get_cursor(result.transcript_win)[1]
    end

    vim.api.nvim_win_set_cursor(result.transcript_win, { rows["between cards"], 0 })
    feed("<A-j>")
    assert.are.equal(rows["second card"], cursor_row())
    feed("<A-k>")
    assert.are.equal(rows["between cards"], cursor_row())
    feed("<A-k>")
    assert.are.equal(rows["first card"], cursor_row())

    vim.api.nvim_win_set_cursor(result.transcript_win, { rows["between cards"], 0 })
    feed("2<A-j>")
    assert.are.equal(rows["third card"], cursor_row())
    feed("3<A-k>")
    assert.are.equal(rows["first card"], cursor_row())
    feed("<A-k>")
    assert.are.equal(rows["first card"], cursor_row())
    vim.api.nvim_win_set_cursor(result.transcript_win, { rows["third card"], 0 })
    feed("<A-j>")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == result.input_win
    end))
    vim.cmd("stopinsert")
    feed("i<C-Up>")
    assert.are.equal(result.transcript_win, vim.api.nvim_get_current_win())
    assert.are.equal(rows["third card"], cursor_row())
    feed("<C-Down>")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == result.input_win
    end))
    vim.cmd("stopinsert")
    feed("<A-k>")
    assert.are.equal(result.transcript_win, vim.api.nvim_get_current_win())
    assert.are.equal(rows["third card"], cursor_row())

    for _, buffer in ipairs({ result.input_buf, result.transcript_buf }) do
      vim.api.nvim_buf_call(buffer, function()
        assert.are.equal("", vim.fn.maparg("[c", "n"))
        assert.are.equal("", vim.fn.maparg("]c", "n"))
      end)
    end
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
      return vim.api.nvim_get_current_win() == result.input_win
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
    assert.are.equal(result.transcript_win, vim.api.nvim_get_current_win())
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
    assert.are.equal(result.dialog_win, vim.api.nvim_get_current_win())
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
    assert.are.equal(result.dialog_win, vim.api.nvim_get_current_win())
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
        result.transcript_buf, 0, -1, false)):any(function(line)
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
      return vim.api.nvim_get_current_win() == result.input_win
    end))
    feed("i<C-w>k")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == result.transcript_win
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
        result.transcript_buf, 0, -1, false)):any(function(line)
          return line:find("third card", 1, true) ~= nil
        end)
    end))
    result:focus_transcript()

    local second_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false)) do
      if line:find("second card", 1, true) then second_row = row break end
    end
    assert.is_not_nil(second_row)
    vim.api.nvim_win_set_cursor(result.transcript_win, { second_row, 0 })
    local function feed(keys)
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function details_contain(value)
      if not result.details_buf or not vim.api.nvim_buf_is_valid(result.details_buf) then
        return false
      end
      return table.concat(vim.api.nvim_buf_get_lines(
        result.details_buf, 0, -1, false), "\n"):find(value, 1, true) ~= nil
    end

    feed("<CR>")
    assert(vim.wait(1000, function() return details_contain("second card") end))
    feed("<A-k>")
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == result.details_win
        and details_contain("first card")
    end))
    feed("<A-j>")
    assert(vim.wait(1000, function() return details_contain("second card") end))
    feed("<A-j>")
    assert(vim.wait(1000, function() return details_contain("third card") end))
    feed("<A-j>")
    assert(vim.wait(1000, function()
      return result.details_win == nil
        and vim.api.nvim_get_current_win() == result.input_win
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
    vim.api.nvim_buf_call(result.input_buf, function()
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
    local agent_cycles = 0
    local model_selections = 0
    local session_selections = 0
    local stops = 0
    local queued = {}
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_submit = function(value) submitted = value end,
      on_cycle_thinking = function() thinking_cycles = thinking_cycles + 1 end,
      on_cycle_agent = function() agent_cycles = agent_cycles + 1 end,
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
    assert.are.equal(1, agent_cycles)
    result:focus_transcript()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-m>", true, false, true), "x", false)
    assert.are.equal(2, model_selections)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-r>", true, false, true), "x", false)
    assert.are.equal(2, session_selections)
    result:focus_input()
    result:set_input("discard")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "" end))
    local origin = result.origin_win
    vim.keymap.set({ "n", "i" }, "<C-a>", function() result:close() end, { buffer = result.input_buf })
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
      return result:get_input() == "" and vim.api.nvim_get_current_win() == result.input_win
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
      return result:get_input() == "" and vim.api.nvim_get_current_win() == result.input_win
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
      return vim.api.nvim_get_current_win() == result.input_win
        and result:get_input() == "first w"
    end))
    for _, buffer in ipairs({ result.input_buf, result.transcript_buf }) do
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
    for _, buffer in ipairs({ result.input_buf, result.transcript_buf }) do
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
      local value = vim.api.nvim_win_get_config(result.transcript_win).footer
      if type(value) == "table" then
        value = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, value))
      end
      return value
    end
    assert(vim.wait(1000, function() return footer() and footer():match("Working%.%.%.") end))
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    local changedtick = vim.api.nvim_buf_get_changedtick(result.transcript_buf)
    local first = footer()
    assert(vim.wait(1000, function() return footer() ~= first end))
    assert.are.same(lines, vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false))
    assert.are.equal(changedtick, vim.api.nvim_buf_get_changedtick(result.transcript_buf))

    result:focus_transcript()
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
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
    vim.api.nvim_win_set_cursor(result.transcript_win, { 1, 0 })
    vim.fn.setreg("a", "sentinel")

    vim.api.nvim_feedkeys('"a', "x", false)
    assert.matches("o", vim.fn.state("oS"))
    assert.are.equal("a", vim.v.register)
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    local changedtick = vim.api.nvim_buf_get_changedtick(result.transcript_buf)

    result:apply({ type = "text_delta", text = "streamed response" })
    local next_tick = false
    vim.schedule(function() next_tick = true end)
    assert(vim.wait(1000, function() return next_tick end))
    assert.are.same(lines, vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false))
    assert.are.equal(changedtick, vim.api.nvim_buf_get_changedtick(result.transcript_buf))
    assert.are.equal("sentinel", vim.fn.getreg("a"))
    assert.matches("o", vim.fn.state("oS"))
    assert.are.equal("a", vim.v.register)

    result:focus_input()
    vim.api.nvim_exec_autocmds("SafeState", {})
    assert(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(
        result.transcript_buf, 0, -1, false
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
    vim.api.nvim_win_set_cursor(result.input_win, { 1, 0 })
    vim.fn.setreg("+", "sentinel")
    vim.cmd("normal! v8l")
    local mode = vim.api.nvim_get_mode().mode
    local cursor = vim.api.nvim_win_get_cursor(result.input_win)
    local anchor = vim.fn.getpos("v")
    local lines = vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false)
    local changedtick = vim.api.nvim_buf_get_changedtick(result.transcript_buf)
    local footer = vim.deepcopy(vim.api.nvim_win_get_config(result.transcript_win).footer)

    result:apply({ type = "text_delta", text = "streamed response" })
    result:set_context({ provider_status = "updated" })
    local next_tick = false
    vim.schedule(function() next_tick = true end)
    assert(vim.wait(1000, function() return next_tick end))
    assert.are.equal(mode, vim.api.nvim_get_mode().mode)
    assert.are.same(cursor, vim.api.nvim_win_get_cursor(result.input_win))
    assert.are.same(anchor, vim.fn.getpos("v"))
    assert.are.same(lines, vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false))
    assert.are.equal(changedtick, vim.api.nvim_buf_get_changedtick(result.transcript_buf))
    assert.are.same(footer, vim.api.nvim_win_get_config(result.transcript_win).footer)

    vim.api.nvim_feedkeys('"+y', "x", false)
    local yanked = vim.fn.getreg("+")
    result:close()
    assert(result:open())
    assert.matches("streamed response", table.concat(vim.api.nvim_buf_get_lines(
      result.transcript_buf, 0, -1, false
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
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == result.input_win end))

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
      buffer = result.input_buf,
      callback = function()
        popup_seen = vim.fn.pumvisible() == 1
        candidates = vim.deepcopy(vim.fn.complete_info({ "items" }).items)
      end,
    })
    vim.api.nvim_create_autocmd("CompleteDone", {
      group = result.augroup,
      buffer = result.input_buf,
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
    assert.are.equal("lua/neoagent/agents.lua", completed.word)
    assert.are.equal("inspect lua/neoagent/agents.lua", result:get_input())
    assert.are.equal(0, #submissions)

    result:focus_input()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.are.same({ "inspect lua/neoagent/agents.lua" }, submissions)
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
    vim.api.nvim_win_set_cursor(result.input_win, { 1, 5 })

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local cursor = vim.api.nvim_win_get_cursor(result.input_win)
      return result:get_input() == "draft" and cursor[1] == 1 and cursor[2] == 0
    end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "newest\ncontinued" end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest" end))
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_text(result.input_buf, 0, 6, 0, 6, { "!" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = result.input_buf })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest!" end))
    vim.cmd("stopinsert")
    result:set_input("draft")
    vim.api.nvim_win_set_cursor(result.input_win, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up><Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest" end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local cursor = vim.api.nvim_win_get_cursor(result.input_win)
      return result:get_input() == "newest\ncontinued" and cursor[1] == 2 and cursor[2] == 9
    end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local cursor = vim.api.nvim_win_get_cursor(result.input_win)
      return result:get_input() == "draft" and cursor[1] == 1 and cursor[2] == 0
    end))

    result:set_input("")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<C-k>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "newest\ncontinued" end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "" end))

    result:set_input("first\nsecond")
    vim.api.nvim_win_set_cursor(result.input_win, { 2, 3 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Up>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return vim.api.nvim_win_get_cursor(result.input_win)[1] == 1
        and result:get_input() == "first\nsecond"
    end))
    vim.api.nvim_win_set_cursor(result.input_win, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      local cursor = vim.api.nvim_win_get_cursor(result.input_win)
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
