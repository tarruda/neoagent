local fake_model = require("tests.helpers.fake_model")

describe("neoagent default controller", function()
  local neoagent
  local paths = {}

  before_each(function()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
  end)

  after_each(function()
    local state = neoagent._state()
    if state.run then state.run:cancel() end
    neoagent.default():destroy()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  local function setup_model(model, extra)
    local options = {
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      apis = { ["fake-api"] = function() return model end },
      tools = {},
      agents = false,
      skills = false,
      ui = { position = "center" },
    }
    for key, value in pairs(extra or {}) do options[key] = value end
    neoagent.setup(options)
  end

  it("composes a model, session, interaction, and passive UI", function()
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "hello" } }) } })
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("hi"))
    assert(vim.wait(1000, function() return run:is_done() and neoagent._state().status == "idle" end))
    assert.are.equal(2, #neoagent.get_session():messages())
    local lines = table.concat(vim.api.nvim_buf_get_lines(neoagent._state().view.transcript_buf, 0, -1, false), "\n")
    assert.matches(" hi ", lines)
    assert.matches(" hello", lines)
  end)

  it("cycles model thinking profiles and applies them at request time", function()
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "done" } }) } })
    setup_model(model, {
      default_thinking_level = "medium",
      providers = { fake = { api = "fake-api", models = { test = { thinking = {
        off = {},
        low = { body = { reasoning_effort = "low" } },
        medium = { body = { reasoning_effort = "medium" } },
        high = function() return { body = { reasoning_effort = "high" } } end,
      } } } } },
    })
    assert.are.same({ "off", "low", "medium", "high" }, assert(neoagent.available_thinking_levels()))
    assert.are.equal("medium", neoagent.get_thinking_level())
    assert.are.equal("high", neoagent.cycle_thinking_level())
    assert.are.equal("high", neoagent.get_thinking_level())
    assert.are.equal("off", neoagent.cycle_thinking_level())
    assert.are.equal("low", neoagent.set_thinking_level("low"))
    assert.is_nil(neoagent.set_thinking_level("minimal"))
    assert.is_nil(neoagent.set_thinking_level("unknown"))
    local run = assert(neoagent.send("think"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.equal("low", model.requests[1].request_opts.body.reasoning_effort)
  end)

  it("uses the coding preset only when tools are not supplied", function()
    local captured
    local model = fake_model.new({})
    neoagent.setup({
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      apis = { ["fake-api"] = function() return model end },
      agents = false,
      skills = false,
      interaction = function(options)
        captured = options
        return { cancel = function()
          options.on_done({ ok = false, error = { kind = "cancelled", message = "cancelled" } })
        end }
      end,
    })
    assert(neoagent.send("inspect"))
    assert.are.same({ "read_file", "write_file", "edit_file", "shell" },
      vim.tbl_map(function(tool) return tool.name end, captured.tools))
    assert.matches("Available tools:", captured.system_prompt)
    for _, name in ipairs({ "read_file", "write_file", "edit_file", "shell" }) do
      assert.is_truthy(captured.system_prompt:find("- " .. name .. ":", 1, true))
    end
    assert.is_nil(captured.system_prompt:find("- grep:", 1, true))
    assert.is_nil(captured.system_prompt:find("- find:", 1, true))
    assert.is_truthy(captured.system_prompt:find("Current working directory: " .. vim.fn.getcwd(), 1, true))
    assert.is_true(neoagent.stop())
  end)

  it("composes AGENTS.md and skill metadata into the controller prompt", function()
    local root = vim.fn.tempname()
    local skill_root = root .. "/skills"
    local agents_path = root .. "/AGENTS.md"
    local skill_path = skill_root .. "/review/SKILL.md"
    paths[#paths + 1] = root
    vim.fn.mkdir(vim.fs.dirname(skill_path), "p")
    vim.fn.writefile({ "Always run the focused tests." }, agents_path)
    vim.fn.writefile({
      "---", "name: review", "description: Review Lua changes", "---",
      "PRIVATE SKILL BODY", "",
    }, skill_path)
    local invalid_path = skill_root .. "/invalid/SKILL.md"
    vim.fn.mkdir(vim.fs.dirname(invalid_path), "p")
    vim.fn.writefile({ "missing frontmatter" }, invalid_path)
    local captured
    setup_model(fake_model.new({}), {
      agents = { global_files = { agents_path }, project_filenames = {} },
      skills = { global_dirs = { skill_root }, project_dirs = {} },
      tools = { { name = "read_file", description = "Read a file" } },
      system_prompt = function(context)
        assert.are.equal(1, #context.agents)
        assert.are.equal(1, #context.skills)
        return "Custom base for " .. context.prompt
      end,
      interaction = function(options)
        captured = options
        return { cancel = function()
          options.on_done({ ok = false, error = { kind = "cancelled", message = "cancelled" } })
        end }
      end,
    })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local ok, run = pcall(neoagent.send, "inspect")
    vim.notify = original_notify
    assert(ok)
    assert(run)
    assert.matches("missing YAML frontmatter", notifications[1].message)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.matches("^Custom base for inspect", captured.system_prompt)
    assert.matches("Always run the focused tests", captured.system_prompt)
    assert.matches("<name>review</name>", captured.system_prompt)
    assert.matches("Review Lua changes", captured.system_prompt)
    assert.matches(vim.pesc(vim.uv.fs_realpath(skill_path)), captured.system_prompt)
    assert.is_nil(captured.system_prompt:find("PRIVATE SKILL BODY", 1, true))
    assert.is_true(neoagent.stop())

    setup_model(fake_model.new({}), {
      agents = false,
      skills = { global_dirs = { skill_root }, project_dirs = {} },
      tools = {},
      system_prompt = "Tool-free chat",
      interaction = function(options)
        captured = options
        return { cancel = function()
          options.on_done({ ok = false, error = { kind = "cancelled", message = "cancelled" } })
        end }
      end,
    })
    assert(neoagent.send("chat"))
    assert.are.equal("Tool-free chat", captured.system_prompt)
    assert.is_true(neoagent.stop())
  end)

  it("keeps the draft when an interaction rejects setup", function()
    setup_model(fake_model.new({}), { interaction = function() error("cannot start") end })
    assert(neoagent.open())
    local view = neoagent._state().view
    view:set_input("draft")
    local run = neoagent.send("draft")
    assert.is_nil(run)
    assert.are.equal("draft", view:get_input())
    assert.are.equal(0, #neoagent.get_session():messages())
  end)

  it("creates no persistent file merely by opening or starting a new session", function()
    local directory = vim.fn.tempname()
    local model = fake_model.new({})
    setup_model(model, { persistence = { enabled = true, directory = directory } })
    assert(neoagent.open())
    assert.are.equal(model, neoagent.get_model())
    assert.are.equal("fake/test", neoagent._state().view.context.model)
    assert.is_nil(vim.uv.fs_stat(directory))
    assert(neoagent.new_session())
    assert.is_nil(vim.uv.fs_stat(directory))
  end)

  it("persists workspace preferences and restores session-local model state", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local models = {}
    for _, id in ipairs({ "test", "alpha" }) do
      models[id] = fake_model.new(id == "alpha" and {
        { result = fake_model.assistant({ { type = "text", text = "saved" } }) },
      } or {})
      models[id].provider, models[id].id = "fake", id
    end
    local options = {
      default_registry = false,
      persistence = { enabled = true, workspace_settings = true, directory = directory },
      default_model = { provider = "fake", model = "test" },
      default_thinking_level = "low",
      providers = { fake = { api = "fake-api", models = {
        test = { thinking = { off = {}, low = {}, high = {} } },
        alpha = { thinking = { off = {}, low = {}, high = {} } },
      } } },
      apis = { ["fake-api"] = function(resolved) return models[resolved.model_id] end },
      tools = {},
      ui = { position = "center" },
    }
    neoagent.setup(options)
    assert(neoagent.open())
    assert(neoagent.set_model("fake", "alpha"))
    assert.are.equal("high", neoagent.set_thinking_level("high"))
    local session_path = neoagent.get_session():metadata().path
    assert.is_nil(vim.uv.fs_stat(session_path))
    local run = assert(neoagent.send("remember this"))
    assert(vim.wait(1000, function() return run:is_done() end))
    local stored = assert(require("neoagent.storage").open(session_path)):state()
    assert.are.same({ provider = "fake", model = "alpha" }, stored.model)
    assert.are.equal("high", stored.thinking_level)

    neoagent.setup(options)
    assert(neoagent.open())
    assert.are.equal("fake/alpha", neoagent._state().view.context.model)
    assert.are.same({ "off", "low", "high" }, assert(neoagent.available_thinking_levels()))
    assert.are.equal("alpha", neoagent.get_model().id)
    assert.are.equal("high", neoagent.get_thinking_level())

    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({
      default_model = { provider = "fake", model = "test" },
      default_thinking_level = "off",
    }))
    neoagent.setup(options)
    assert(neoagent.resume(session_path))
    assert.are.equal("alpha", neoagent.get_model().id)
    assert.are.equal("high", neoagent.get_thinking_level())
    assert(neoagent.new_session())
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert.are.equal("off", neoagent.get_thinking_level())
    neoagent.setup(options)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert.are.equal("off", neoagent.get_thinking_level())

    assert(settings:write({
      default_model = { provider = "fake", model = "alpha" },
      default_thinking_level = "high",
    }))
    options.persistence.workspace_settings = false
    neoagent.setup(options)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert.are.equal("low", neoagent.get_thinking_level())
    assert(neoagent.set_model("fake", "test"))
    assert.are.equal("alpha", assert(settings:load()).default_model.model)
  end)

  it("falls back from invalid workspace and session preferences", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({ default_model = "invalid", default_thinking_level = "extreme" }))
    local model = fake_model.new({})
    model.provider, model.id = "fake", "test"
    local extra = {
      persistence = { enabled = true, directory = directory },
      default_thinking_level = "low",
      providers = { fake = { api = "fake-api", models = { test = { thinking = {
        off = {}, low = {}, high = {},
      } } } } },
    }
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert.are.equal("low", neoagent.get_thinking_level())

    vim.fn.writefile({ "{" }, settings.settings_path)
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)

    assert(settings:write({}))
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append_model_change("missing", "gone"))
    assert(store:append({ role = "user", content = "fallback", timestamp = 1 }))
    setup_model(model, extra)
    assert(neoagent.resume(store:metadata().path))
    assert.are.equal("test", neoagent.get_model().id)
  end)

  it("reloads unmodified buffers after successful disk mutations", function()
    local root = vim.fn.tempname()
    paths[#paths + 1] = root
    vim.fn.mkdir(root, "p")
    local path = root .. "/file.txt"
    vim.fn.writefile({ "old" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buffer = vim.api.nvim_get_current_buf()
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "write", name = "write_file",
        arguments = { path = path, content = "new" },
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    setup_model(model, { tools = require("neoagent.tools").coding() })
    assert(neoagent.open())
    local run = assert(neoagent.send("change it"))
    assert(vim.wait(1500, function() return run:is_done() end))
    assert(vim.wait(1000, function() return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1] == "new" end))
  end)

  it("never discards a modified buffer after an agent disk edit", function()
    local root = vim.fn.tempname()
    paths[#paths + 1] = root
    vim.fn.mkdir(root, "p")
    local path = root .. "/file.txt"
    vim.fn.writefile({ "disk" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buffer = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local unsaved" })
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "write", name = "write_file",
        arguments = { path = path, content = "agent disk" },
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    setup_model(model, { tools = require("neoagent.tools").coding() })
    assert(neoagent.open())
    local run = assert(neoagent.send("change it"))
    assert(vim.wait(1500, function() return run:is_done() end))
    assert.are.equal("local unsaved", vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1])
    assert.is_true(vim.bo[buffer].modified)
  end)

  it("resumes sessions, closes interrupted tool calls, and controls an active interaction", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    vim.fn.mkdir(directory, "p")
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append({ role = "user", content = "before", timestamp = 1 }))
    assert(store:append({
      role = "assistant",
      content = { { type = "toolCall", id = "complete", name = "shell", arguments = { command = "true" } } },
      timestamp = 2,
    }))
    assert(store:append({
      role = "toolResult", toolCallId = "complete", toolName = "shell",
      content = { { type = "text", text = "done" } }, timestamp = 3,
    }))
    assert(store:append({
      role = "assistant",
      content = { { type = "toolCall", id = "pending", name = "shell", arguments = { command = "true" } } },
      timestamp = 4,
    }))
    local path = store:metadata().path
    local cancelled = false
    local interaction_options
    setup_model(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
      system_prompt = function(context)
        assert.are.same({}, context.tools)
        return table.concat({
          require("neoagent.system_prompt").default(context),
          "prompt: " .. context.prompt,
        }, "\n\n")
      end,
      interaction = function(options)
        interaction_options = options
        return {
          cancel = function()
            cancelled = true
            options.on_done({ ok = false, error = { kind = "cancelled", message = "cancelled" } })
          end,
        }
      end,
    })
    assert(neoagent.open())
    assert(neoagent.resume(path))
    assert.are.equal("before", neoagent.get_session():messages()[1].content)
    assert(neoagent.send("continue"))
    local messages = neoagent.get_session():messages()
    assert.are.equal(5, #messages)
    assert.are.equal("toolResult", messages[5].role)
    assert.are.equal("pending", messages[5].toolCallId)
    assert.is_true(messages[5].isError)
    assert.matches("Available tools:\n%(none%)", interaction_options.system_prompt)
    assert.matches("prompt: continue$", interaction_options.system_prompt)
    assert.is_nil(neoagent.new_session())
    assert.is_nil(neoagent.resume(path))
    assert.is_nil(neoagent.select_model())
    assert.is_nil(neoagent.set_model("fake", "test"))
    assert.is_nil(neoagent.cycle_thinking_level())
    assert.is_nil(neoagent.set_thinking_level("high"))
    assert.is_true(neoagent.stop())
    assert.is_true(cancelled)
    assert.are.equal("idle", neoagent._state().status)
    assert.is_false(neoagent.stop())
  end)

  it("selects persisted sessions when no resume path is supplied", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append({ role = "user", content = "resumed", timestamp = 1 }))
    setup_model(fake_model.new({}), { persistence = { enabled = true, directory = directory } })
    assert(neoagent.resume(store:metadata().path))

    local original_select = vim.ui.select
    vim.ui.select = function(items, options, callback)
      assert.are.equal("Resume Neoagent session:", options.prompt)
      assert.are.same({ store:metadata().path }, items)
      assert.matches("^● %d%d%d%d%-%d%d%-%d%d", options.format_item(items[1]))
      assert.matches(" — resumed$", options.format_item(items[1]))
      callback(items[1])
    end
    local ok, err = pcall(neoagent.resume)
    vim.ui.select = original_select
    assert(ok, err)
    assert.are.equal("resumed", neoagent.get_session():messages()[1].content)
    assert.is_true(neoagent._state().view:is_open())

    local empty = vim.fn.tempname()
    paths[#paths + 1] = empty
    setup_model(fake_model.new({}), { persistence = { enabled = true, directory = empty } })
    assert.is_nil(neoagent.resume())
    assert.is_nil(neoagent._state().view)
  end)

  it("toggles the view and changes configured models", function()
    setup_model(fake_model.new({}))
    assert(neoagent.open())
    assert.is_true(neoagent._state().view:is_open())
    neoagent.toggle()
    assert.is_false(neoagent._state().view:is_open())
    neoagent.toggle()
    assert.is_true(neoagent._state().view:is_open())
    local model = assert(neoagent.set_model("fake", "test"))
    assert.are.equal("fake", model.id)
    assert.is_nil(neoagent.get_thinking_level())
    assert.is_nil(neoagent.set_model("missing", "missing"))

    setup_model(model, {
      providers = { fake = { api = "fake-api", models = { test = {}, alpha = {} } } },
    })
    local original_select = vim.ui.select
    vim.ui.select = function(items, options, callback)
      assert.are.equal("Select Neoagent model:", options.prompt)
      assert.are.same({ "fake/alpha", "fake/test" }, items)
      callback(items[1])
    end
    local ok, err = pcall(neoagent.select_model)
    vim.ui.select = original_select
    assert(ok, err)
    assert.are.equal(model, neoagent.get_model())
    assert.is_true(neoagent._state().view:is_open())

    neoagent.close()
    vim.ui.select = function(_, _, callback) callback(nil) end
    assert(neoagent.select_model())
    vim.ui.select = original_select
    assert.are.equal(model, neoagent.get_model())
    assert.is_false(neoagent._state().view:is_open())

    neoagent.setup({ default_registry = false, persistence = { enabled = false }, providers = {}, tools = {} })
    assert.is_nil(neoagent.select_model())
  end)
end)
