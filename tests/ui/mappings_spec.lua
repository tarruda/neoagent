local config = require("neoagent.config")
local ui = require("neoagent.ui")

describe("neoagent UI mappings", function()
  it("uses real encoded input for submit, cancellation, focus, and docking", function()
    local submitted
    local result = ui.new({
      config = config.setup({ ui = { position = "center" } }).ui,
      on_submit = function(value) submitted = value end,
    })
    assert(result:open())
    result:set_input("send me")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc><C-s>", true, false, true), "x", false)
    assert.is_not_nil(submitted)
    assert.are.equal("send me", submitted)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>H", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_win_get_config(result.transcript_win).col < 5 end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>w", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == result.transcript_win end))
    result:focus_input()
    result:set_input("discard")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return result:get_input() == "" end))
    result:destroy()
  end)
end)
