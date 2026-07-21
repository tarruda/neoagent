describe("neoagent commands", function()
  it("installs documented commands and opens successfully selected resources", function()
    vim.g.loaded_neoagent = nil
    vim.cmd("runtime plugin/neoagent.lua")
    for _, name in ipairs({
      "Neoagent", "NeoagentNew", "NeoagentResume", "NeoagentStop", "NeoagentModel", "NeoagentLogin",
    }) do
      assert.are.equal(2, vim.fn.exists(":" .. name))
    end
    assert.are.equal("", vim.fn.maparg("<leader>a", "n"))
    assert.is_false(pcall(vim.cmd, "NeoagentModel invalid"))

    local model = { provider = "fake", id = "test", stream = function() end }
    require("neoagent").setup({
      default_registry = false,
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
      default_registry = false,
      persistence = { enabled = true, directory = directory },
      providers = { fake = { api = "fake", models = { test = {} } } },
      apis = { fake = function() return model end },
    })
    vim.cmd("NeoagentResume " .. vim.fn.fnameescape(store:metadata().path))
    assert.is_true(require("neoagent")._state().view:is_open())
    assert.are.equal("stored", require("neoagent").get_session():messages()[1].content)

    local auth_path = vim.fn.tempname() .. "/auth.json"
    local logins = 0
    local async = require("neoagent.async")
    local login_method = {
      name = "Test subscription",
      login = function(interaction)
        return async.run(function()
          logins = logins + 1
          local kind = async.await(function(done)
            return interaction.prompt({
              type = "select",
              message = "Login kind",
              options = { { id = "test", label = "Test login" } },
            }, done)
          end)
          local token = async.await(function(done)
            return interaction.prompt({ type = "manual_code", message = "Token" }, done)
          end)
          interaction.notify({ type = "auth_url", url = "https://login.test", instructions = "Login" })
          interaction.notify({
            type = "device_code", verificationUri = "https://device.test", userCode = "CODE",
          })
          assert.are.equal("test", kind)
          return { ok = true, credential = { access = token, refresh = "r", expires = 9999999999999 } }
        end)
      end,
      refresh = function() end,
      request_opts = function() return {} end,
    }
    local cancelled_login = false
    local waiting_method = {
      name = "Waiting subscription",
      login = function()
        return async.run(function()
          async.await(function()
            return function() cancelled_login = true end
          end)
        end)
      end,
      refresh = function() end,
      request_opts = function() return {} end,
    }
    require("neoagent").setup({
      persistence = { enabled = false },
      auth = { path = auth_path, methods = {
        ["openai-codex"] = login_method,
        waiting = waiting_method,
      } },
    })
    local original_input = vim.ui.input
    local original_open = vim.ui.open
    local opened = {}
    vim.ui.input = function(options, callback)
      assert.are.equal("Token ", options.prompt)
      callback("token")
    end
    vim.ui.open = function(url) opened[#opened + 1] = url end
    vim.ui.select = function(items, options, callback)
      if options.prompt == "Login kind" then
        assert.are.equal("Test login", options.format_item(items[1]))
        callback(items[1])
        return
      end
      assert.are.equal("Select Neoagent login:", options.prompt)
      for _, item in ipairs(items) do
        if item.id == "openai-codex" then
          assert.are.equal("Test subscription", options.format_item(item))
          callback(item)
          return
        end
      end
      error("OpenAI Codex login method was not offered")
    end
    vim.cmd("NeoagentLogin")
    assert(vim.wait(1000, function() return require("neoagent")._state().login_run == nil end))
    assert.are.equal(1, logins)
    assert.are.equal("token", require("neoagent.auth.store").new(auth_path):read("openai-codex").access)
    assert.are.same({ "https://login.test", "https://device.test" }, opened)
    vim.ui.select = function(items, options, callback)
      assert.are.equal("Select Neoagent model:", options.prompt)
      assert.is_true(vim.tbl_contains(items, "openai-codex/gpt-5.5"))
      callback(nil)
    end
    vim.cmd("NeoagentModel")
    vim.cmd("NeoagentLogin waiting")
    assert.is_truthy(require("neoagent")._state().login_run)
    vim.cmd("NeoagentLogin!")
    assert(vim.wait(1000, function() return require("neoagent")._state().login_run == nil end))
    assert.is_true(cancelled_login)
    vim.ui.select = original_select
    vim.ui.input = original_input
    vim.ui.open = original_open
    if require("neoagent")._state().view then require("neoagent")._state().view:destroy() end
    vim.fn.delete(directory, "rf")
    vim.fn.delete(vim.fs.dirname(auth_path), "rf")
  end)
end)
