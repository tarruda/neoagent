local config = require("neoagent.config")
local ui = require("neoagent.ui")

describe("neoagent UI mappings", function()
  it("uses real encoded input for submit, cancellation, focus, docking, and close", function()
    local submitted
    local thinking_cycles = 0
    local agent_cycles = 0
    local model_selections = 0
    local session_selections = 0
    local positions = {}
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_submit = function(value) submitted = value end,
      on_cycle_thinking = function() thinking_cycles = thinking_cycles + 1 end,
      on_cycle_agent = function() agent_cycles = agent_cycles + 1 end,
      on_select_model = function() model_selections = model_selections + 1 end,
      on_resume_session = function() session_selections = session_selections + 1 end,
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

  it("closes the paired windows from the input escape and empty-draft mappings", function()
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
end)
