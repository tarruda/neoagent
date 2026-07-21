local config = require("neoagent.config")
local ui = require("neoagent.ui")

describe("neoagent UI mappings", function()
  it("uses real encoded input for submit, cancellation, focus, and docking", function()
    local submitted
    local thinking_cycles = 0
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_submit = function(value) submitted = value end,
      on_cycle_thinking = function() thinking_cycles = thinking_cycles + 1 end,
    })
    assert(result:open())
    result:set_input("send me")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc><C-s>", true, false, true), "x", false)
    assert.is_not_nil(submitted)
    assert.are.equal("send me", submitted)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "x", false)
    assert.are.equal(1, thinking_cycles)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>H", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_win_get_config(result.transcript_win).col < 5 end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>w", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == result.transcript_win end))
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
    result:destroy()
  end)
end)
