describe("neoagent commands", function()
  it("installs the documented commands without global mappings", function()
    vim.g.loaded_neoagent = nil
    vim.cmd("runtime plugin/neoagent.lua")
    for _, name in ipairs({ "Neoagent", "NeoagentNew", "NeoagentResume", "NeoagentStop", "NeoagentModel" }) do
      assert.are.equal(2, vim.fn.exists(":" .. name))
    end
    assert.are.equal("", vim.fn.maparg("<leader>a", "n"))
    assert.is_false(pcall(vim.cmd, "NeoagentModel invalid"))
  end)
end)
