local config = require("neoagent.config")
local ui = require("neoagent.ui")

describe("neoagent UI mappings", function()
  it("uses real encoded input for submit, cancellation, focus, docking, and close", function()
    local submitted
    local thinking_cycles = 0
    local agent_cycles = 0
    local model_selections = 0
    local session_selections = 0
    local stops = 0
    local queued = {}
    local positions = {}
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
      on_position_change = function(position) positions[#positions + 1] = position end,
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
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>H", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_win_get_config(result.transcript_win).col < 5 end))
    assert.are.same({ "left" }, positions)
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
    local output = {}
    for index = 1, 11 do output[index] = "result " .. index end
    result:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "read", name = "read_file", arguments = { path = "file.txt" },
      } } },
      { role = "toolResult", toolCallId = "read", toolName = "read_file", isError = false,
        content = { { type = "text", text = table.concat(output, "\n") } } },
    })
    assert(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false), "\n"):match("1 more lines") ~= nil
    end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(result.transcript_buf, 0, -1, false), "\n"):match("result 11") ~= nil
    end))
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
