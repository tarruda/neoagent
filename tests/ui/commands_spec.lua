describe("neoagent commands", function()
  it("installs documented commands and opens successfully selected resources", function()
    vim.g.loaded_neoagent = nil
    vim.cmd("runtime plugin/neoagent.lua")
    for _, name in ipairs({
      "Neoagent", "NeoagentCycle", "NeoagentNew", "NeoagentResume", "NeoagentStop",
      "NeoagentModel", "NeoagentThinking", "NeoagentLogin", "NeoagentLogout", "NeoagentCompact",
      "NeoagentBranch", "NeoagentFork",
    }) do
      assert.are.equal(2, vim.fn.exists(":" .. name))
    end
    assert.are.equal("", vim.fn.maparg("<leader>a", "n"))
    assert.is_false(pcall(vim.cmd, "NeoagentModel invalid"))

    local model = { provider = "fake", id = "test", stream = function() end }
    require("neoagent").setup({
      default_registry = false,
      persistence = { enabled = false },
      providers = { fake = { api = "fake", models = { test = { thinking = {
        off = {}, high = { body = { reasoning_effort = "high" } },
      } } } } },
      apis = { fake = function() return model end },
    })
    vim.cmd("NeoagentCycle")
    assert.are.equal("Chat", require("neoagent").default():config().name)
    assert.is_false(require("neoagent").default_window():is_open())
    vim.cmd("Neoagent")
    assert.is_true(require("neoagent").default_window():is_open())
    vim.cmd("Neoagent")
    assert.is_false(require("neoagent").default_window():is_open())
    vim.cmd("NeoagentCycle")
    assert.are.equal("Neo", require("neoagent").default():config().name)
    assert.is_false(require("neoagent").default_window():is_open())
    local original_select = vim.ui.select
    vim.ui.select = function(items, options, callback)
      assert.are.same({ "fake/test" }, items)
      assert.are.equal("Select Neoagent model:", options.prompt)
      callback(items[1])
    end
    vim.cmd("NeoagentModel")
    vim.ui.select = original_select
    assert.are.equal(model, require("neoagent").get_model())
    assert.is_true(require("neoagent").default_window():_state().view:is_open())
    vim.cmd("NeoagentThinking high")
    assert.are.equal("high", require("neoagent").get_thinking_level())
    vim.cmd("NeoagentThinking")
    assert.are.equal("off", require("neoagent").get_thinking_level())
    require("neoagent").close()
    vim.cmd("NeoagentModel fake/test")
    assert.are.equal(model, require("neoagent").get_model())
    assert.is_true(require("neoagent").default_window():_state().view:is_open())

    local directory = vim.fn.tempname()
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append({ role = "user", content = "stored", timestamp = 1 }))
    require("neoagent").setup({
      default_registry = false,
      persistence = { enabled = true, directory = directory },
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake", models = { test = {} } } },
      apis = { fake = function() return model end },
    })
    vim.cmd("NeoagentResume " .. vim.fn.fnameescape(store:metadata().path))
    assert.is_true(require("neoagent").default_window():_state().view:is_open())
    assert.are.equal("stored", require("neoagent").get_session():messages()[1].content)
    local entry_id = require("neoagent").get_session():leaf_id()
    vim.cmd("NeoagentBranch " .. entry_id)
    assert.are.equal(entry_id, require("neoagent").get_session():leaf_id())
    local parent_path = require("neoagent").get_session():metadata().path
    vim.cmd("NeoagentFork " .. entry_id)
    assert.are.equal(parent_path, require("neoagent").get_session():metadata().parent_session)
    assert.are.same({}, require("neoagent").get_session():messages())
    assert.are.equal("stored", require("neoagent").default_window():_state().view:get_input())
    assert(require("neoagent").resume(parent_path))
    vim.ui.select = function(items, options, callback)
      assert.is_true(options.prompt == "Neoagent branch" or options.prompt == "Fork Neoagent session from")
      callback(items[1])
    end
    vim.cmd("NeoagentBranch")
    vim.cmd("NeoagentFork")
    vim.ui.select = original_select
    vim.cmd("NeoagentCompact focus on current work")

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
    local original_inputsecret = vim.fn.inputsecret
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
    local credential_store = require("neoagent.auth.store").new(auth_path)
    assert.are.equal("token", credential_store:read("openai-codex").access)
    assert.are.same({ "https://login.test", "https://device.test" }, opened)

    vim.fn.inputsecret = function(prompt)
      assert.are.equal("Enter OpenAI API key: ", prompt)
      return "stored-openai-key"
    end
    vim.cmd("NeoagentLogin openai")
    assert(vim.wait(1000, function() return require("neoagent")._state().login_run == nil end))
    assert.are.same({ type = "api_key", key = "stored-openai-key" }, credential_store:read("openai"))
    vim.cmd("NeoagentLogout openai")
    assert(vim.wait(1000, function() return require("neoagent")._state().logout_run == nil end))
    assert.is_nil(credential_store:read("openai"))
    vim.fn.inputsecret = function() return "" end
    vim.cmd("NeoagentLogin openai")
    assert(vim.wait(1000, function() return require("neoagent")._state().login_run == nil end))
    assert.is_nil(credential_store:read("openai"))
    local cancelled_secret_prompts = 0
    vim.fn.inputsecret = function()
      cancelled_secret_prompts = cancelled_secret_prompts + 1
      return "should-not-be-read"
    end
    vim.cmd("NeoagentLogin openai")
    vim.cmd("NeoagentLogin!")
    assert(vim.wait(1000, function() return require("neoagent")._state().login_run == nil end))
    assert.are.equal(0, cancelled_secret_prompts)
    assert.is_nil(credential_store:read("openai"))
    vim.ui.select = function(items, options, callback)
      assert.are.equal("Select Neoagent model:", options.prompt)
      assert.is_true(vim.tbl_contains(items, "openai-codex/gpt-5.5"))
      callback(nil)
    end
    vim.cmd("NeoagentModel")
    vim.cmd("NeoagentLogin waiting")
    assert.is_truthy(require("neoagent")._state().login_run)
    assert.is_nil(require("neoagent").login("openai"))
    assert.is_nil(require("neoagent").logout("openai-codex"))
    vim.cmd("NeoagentLogin!")
    assert(vim.wait(1000, function() return require("neoagent")._state().login_run == nil end))
    assert.is_true(cancelled_login)
    local completions = vim.fn.getcompletion("NeoagentLogin ", "cmdline")
    assert.is_true(vim.tbl_contains(completions, "openai-codex"))
    assert.is_true(vim.tbl_contains(completions, "waiting"))
    completions = vim.fn.getcompletion("NeoagentLogout ", "cmdline")
    assert.is_true(vim.tbl_contains(completions, "openai"))
    assert.is_true(vim.tbl_contains(completions, "deepseek"))
    vim.ui.select = function(items, options, callback)
      assert.are.equal("Select Neoagent credential to remove:", options.prompt)
      for _, item in ipairs(items) do
        if item.id == "openai-codex" then
          assert.are.equal("Test subscription (OAuth)", options.format_item(item))
          callback(item)
          return
        end
      end
      error("stored OpenAI Codex credential was not offered")
    end
    vim.cmd("NeoagentLogout")
    assert(vim.wait(1000, function() return require("neoagent")._state().logout_run == nil end))
    assert.is_nil(credential_store:read("openai-codex"))
    assert.is_nil(require("neoagent").logout("openai-codex"))
    assert.is_nil(require("neoagent").logout())
    vim.ui.select = original_select
    vim.ui.input = original_input
    vim.fn.inputsecret = original_inputsecret
    vim.ui.open = original_open
    local window = require("neoagent").default_window()
    for _, controller in ipairs(window:controllers()) do controller:destroy() end
    window:destroy()
    vim.fn.delete(directory, "rf")
    vim.fn.delete(vim.fs.dirname(auth_path), "rf")
  end)
end)
