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

  it("navigates transcript cards with bracket motions", function()
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
    feed("]c")
    assert.are.equal(rows["second card"], cursor_row())
    feed("[c")
    assert.are.equal(rows["between cards"], cursor_row())
    feed("[c")
    assert.are.equal(rows["first card"], cursor_row())

    vim.api.nvim_win_set_cursor(result.transcript_win, { rows["between cards"], 0 })
    feed("2]c")
    assert.are.equal(rows["third card"], cursor_row())
    feed("3[c")
    assert.are.equal(rows["first card"], cursor_row())
    feed("[c")
    assert.are.equal(rows["first card"], cursor_row())
    vim.api.nvim_win_set_cursor(result.transcript_win, { rows["third card"], 0 })
    feed("]c")
    assert.are.equal(rows["third card"], cursor_row())
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
    local function input_focused() return vim.api.nvim_get_current_win() == result.input_win end
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
    result:set_input("current draft")
    queued = { "pending steer" }
    result:set_context({ steering = vim.deepcopy(queued) })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert.are.equal("pending steer\n\ncurrent draft", result:get_input())
    assert.are.equal(1, stops)
    result:set_context({ state = "idle", steering = {} })
    result:set_input("send me")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "x", false)
    assert.are.equal(1, thinking_cycles)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-n>", true, false, true), "x", false)
    assert.are.equal(1, agent_cycles)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>w", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == result.transcript_win end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-m>", true, false, true), "x", false)
    assert.are.equal(2, model_selections)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<A-r>", true, false, true), "x", false)
    assert.are.equal(2, session_selections)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
      "<C-w>wZ<C-\\><C-n>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return input_focused() and result:get_input() == "send meZ"
    end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<C-w>w", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == result.transcript_win end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>w", true, false, true), "x", false)
    assert(vim.wait(1000, input_focused))
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("v<C-w>w", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == result.transcript_win end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("v<C-w>w", true, false, true), "x", false)
    assert(vim.wait(1000, input_focused))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w><C-w>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == result.transcript_win end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w><C-w>", true, false, true), "x", false)
    assert(vim.wait(1000, input_focused))
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
    vim.api.nvim_feedkeys("A!", "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest!" end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Down>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "oldest!" end))
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
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<C-j>", true, false, true), "x", false)
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
