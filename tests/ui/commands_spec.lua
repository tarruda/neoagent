describe("neoagent commands", function()
  it("installs documented commands and opens successfully selected resources", function()
    vim.g.loaded_neoagent = nil
    vim.cmd("runtime plugin/neoagent.lua")
    for _, name in ipairs({ "Neoagent", "NeoagentNew", "NeoagentResume", "NeoagentStop", "NeoagentModel" }) do
      assert.are.equal(2, vim.fn.exists(":" .. name))
    end
    assert.are.equal("", vim.fn.maparg("<leader>a", "n"))
    assert.is_false(pcall(vim.cmd, "NeoagentModel invalid"))

    local model = { provider = "fake", id = "test", stream = function() end }
    require("neoagent").setup({
      persistence = { enabled = false },
      providers = { fake = { api = "fake", models = { test = {} } } },
      apis = { fake = function() return model end },
    })
    local original_select = vim.ui.select
    vim.ui.select = function(items, options, callback)
      assert.are.same({ "fake/test" }, items)
      assert.are.equal("Select Neoagent model:", options.prompt)
      callback(items[1])
    end
    vim.cmd("NeoagentModel")
    vim.ui.select = original_select
    assert.are.equal(model, require("neoagent").get_model())
    assert.is_true(require("neoagent")._state().view:is_open())
    require("neoagent").close()
    vim.cmd("NeoagentModel fake/test")
    assert.are.equal(model, require("neoagent").get_model())
    assert.is_true(require("neoagent")._state().view:is_open())

    local directory = vim.fn.tempname()
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append({ role = "user", content = "stored", timestamp = 1 }))
    require("neoagent").setup({
      persistence = { enabled = true, directory = directory },
      providers = { fake = { api = "fake", models = { test = {} } } },
      apis = { fake = function() return model end },
    })
    vim.cmd("NeoagentResume " .. vim.fn.fnameescape(store:metadata().path))
    assert.is_true(require("neoagent")._state().view:is_open())
    assert.are.equal("stored", require("neoagent").get_session():messages()[1].content)
    require("neoagent")._state().view:destroy()
    vim.fn.delete(directory, "rf")
  end)
end)
