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
    local window = neoagent.default_window()
    for _, controller in ipairs(window:controllers()) do controller:destroy() end
    window:destroy()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  local function current_view()
    return neoagent.default_window():_state().view
  end

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
    local lines = table.concat(vim.api.nvim_buf_get_lines(current_view().transcript_buf, 0, -1, false), "\n")
    assert.matches(" hi ", lines)
    assert.matches(" hello", lines)
  end)

  it("queues steering submissions one at a time during an active Run", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "first" } }) },
      { result = fake_model.assistant({ { type = "text", text = "second" } }) },
      { result = fake_model.assistant({ { type = "text", text = "third" } }) },
    })
    setup_model(model)
    local run = assert(neoagent.send("begin"))
    assert.is_true(neoagent.send("steer one"))
    assert.is_true(neoagent.steer("steer two"))
    assert.are.same({ "steer one", "steer two" },
      neoagent.default():snapshot().context.steering)
    assert(vim.wait(1000, function() return run:is_done() end))
    local messages = neoagent.get_session():messages()
    assert.are.same({ "user", "assistant", "user", "assistant", "user", "assistant" },
      vim.tbl_map(function(message) return message.role end, messages))
    assert.are.equal("steer one", model.requests[2].messages[3].content)
    assert.are.equal("steer two", model.requests[3].messages[5].content)
  end)

  it("tracks model context usage and provider status", function()
    local assistant = fake_model.assistant({ { type = "text", text = "done" } })
    assistant.message.usage.totalTokens = nil
    assistant.message.usage.input = 200
    assistant.message.usage.output = 50
    local model = fake_model.new({ {
      events = {
        { type = "usage", usage = { totalTokens = 250 } },
        { type = "provider_status", text = "quota 70% left" },
      },
      result = assistant,
    } })
    model.context_window = 1000
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("measure"))
    assert(vim.wait(1000, function() return run:is_done() and neoagent._state().status == "idle" end))
    assert.are.same({ used = 250, total = 1000, percent = 25 },
      current_view().context.context_usage)
    assert.are.equal("quota 70% left", current_view().context.provider_status)
  end)

  it("automatically compacts large contexts and persists the Pi checkpoint", function()
    local assistant = fake_model.assistant({ { type = "text", text = string.rep("work ", 30) } })
    assistant.message.usage.totalTokens = 900
    local model = fake_model.new({
      { result = assistant },
      {
        events = { { type = "provider_status", text = "summary quota" }, { type = "text_delta", text = "## Goal" } },
        result = fake_model.assistant({ { type = "text", text = "## Goal\nContinue the work" } }),
      },
    })
    model.context_window = 1000
    setup_model(model, {
      compaction = { auto = true, reserve_tokens = 200, keep_recent_tokens = 10 },
    })
    assert(neoagent.open())
    local run = assert(neoagent.send("perform the large task"))
    assert(vim.wait(1000, function()
      return run:is_done() and neoagent._state().status == "idle" and #model.requests == 2
    end))
    local entries = neoagent.get_session():entries()
    assert.are.equal("compaction", entries[#entries].type)
    assert.matches("Turn Context %(split turn%):.-## Goal\nContinue the work", entries[#entries].summary)
    assert.are.equal(900, entries[#entries].tokensBefore)
    assert.matches("context summarization assistant", model.requests[2].system_prompt)
    local context = assert(neoagent.get_session():context_messages())
    assert.matches("Continue the work", context[1].content[1].text)
    local estimated = 0
    for _, message in ipairs(context) do
      estimated = estimated + require("neoagent.compaction").estimate_tokens(message)
    end
    assert.are.equal(estimated, current_view().context.context_usage.used)
    assert.is_true(estimated < entries[#entries].tokensBefore)
    local transcript = table.concat(vim.api.nvim_buf_get_lines(
      current_view().transcript_buf, 0, -1, false), "\n")
    assert.matches("Compacted from 900 tokens", transcript)
    assert.are.equal("perform the large task", neoagent.get_session():messages()[1].content)
    assert.not_matches("perform the large task", transcript)
    assert.are.equal("summary quota", current_view().context.provider_status)
  end)

  it("compacts an already-large resumed context before sending the next prompt", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append_model_change("fake", "test"))
    assert(store:append({ role = "user", content = string.rep("old ", 30), timestamp = 1 }))
    assert(store:append({
      role = "assistant", content = { { type = "text", text = string.rep("work ", 30) } },
      provider = "fake", model = "test", stopReason = "stop", timestamp = 2,
      usage = { input = 80, output = 10, cacheRead = 0, cacheWrite = 0, totalTokens = 90 },
    }))
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "checkpoint" } }) },
      { result = fake_model.assistant({ { type = "text", text = "answer" } }) },
    })
    model.context_window = 100
    setup_model(model, {
      persistence = { enabled = true, directory = directory },
      compaction = { auto = true, reserve_tokens = 20, keep_recent_tokens = 10 },
    })
    assert(neoagent.resume(store:metadata().path))
    local run = assert(neoagent.send("new question"))
    assert(vim.wait(1000, function()
      return run:is_done() and neoagent._state().status == "idle" and #model.requests == 2
    end))
    assert.matches("context summarization assistant", model.requests[1].system_prompt)
    assert.are.equal("new question", model.requests[2].messages[#model.requests[2].messages].content)
    assert.are.equal("compaction", neoagent.get_session():entries()[#neoagent.get_session():entries() - 2].type)
  end)

  it("compacts and retries a context overflow once on the active branch", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append_model_change("fake", "test"))
    assert(store:append({ role = "user", content = string.rep("old ", 30), timestamp = 1 }))
    assert(store:append({
      role = "assistant", content = { { type = "text", text = string.rep("work ", 30) } },
      provider = "fake", model = "test", stopReason = "stop", timestamp = 2,
    }))
    local overflow = fake_model.assistant({}, "error")
    overflow.ok = false
    overflow.error = {
      kind = "model",
      message = "request failed",
      detail = { message = "the request exceeds the available context size" },
    }
    local model = fake_model.new({
      { result = overflow },
      { result = fake_model.assistant({ { type = "text", text = "checkpoint" } }) },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    model.context_window = 100
    setup_model(model, {
      persistence = { enabled = true, directory = directory },
      compaction = { auto = false, reserve_tokens = 20, keep_recent_tokens = 10 },
    })
    assert(neoagent.resume(store:metadata().path))
    local run = assert(neoagent.send("continue"))
    assert(vim.wait(1000, function()
      return run:is_done() and neoagent._state().status == "idle" and #model.requests == 3
    end))
    local messages = neoagent.get_session():messages()
    assert.are.equal("recovered", messages[#messages].content[1].text)
    assert.are.equal(2, vim.tbl_count(vim.tbl_filter(function(message)
      return message.role == "user"
    end, messages)))
    assert.are.equal("compaction", neoagent.get_session():entries()[#neoagent.get_session():entries() - 1].type)
  end)

  it("replays retryable partial turns without retaining the failed branch", function()
    local failed = fake_model.assistant({ { type = "thinking", thinking = "partial" } }, "error")
    failed.ok = false
    failed.error = {
      kind = "model",
      message = "upstream disconnected",
      retryable = true,
      stream_max_retries = 5,
      retry_after_ms = 1,
    }
    local model = fake_model.new({
      { events = { { type = "thinking_delta", text = "partial" } }, result = failed },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("retry this"))
    assert(vim.wait(1000, function()
      return run:is_done() and neoagent._state().status == "idle" and #model.requests == 2
    end))

    local messages = neoagent.get_session():messages()
    assert.are.equal(2, #messages)
    assert.are.equal("retry this", messages[1].content)
    assert.are.equal("recovered", messages[2].content[1].text)
    assert.is_true(neoagent._state().last_result.ok)
    assert.is_nil(neoagent._state().provider_status)
  end)

  it("cancels a pending retry without launching another turn", function()
    local failed = fake_model.assistant({}, "error")
    failed.ok = false
    failed.error = {
      kind = "transport",
      message = "HTTP 503: overloaded",
      retryable = true,
      stream_max_retries = 5,
      retry_after_ms = 10000,
    }
    local model = fake_model.new({ { result = failed } })
    setup_model(model)
    assert(neoagent.send("stop retrying"))
    assert(vim.wait(1000, function()
      return neoagent._state().provider_status == "Reconnecting… 1/5"
    end))
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, function() return neoagent._state().status == "idle" end))

    assert.are.equal(1, #model.requests)
    assert.are.equal("cancelled", neoagent._state().last_result.error.kind)
    assert.is_nil(neoagent._state().provider_status)
  end)

  it("runs a replaceable manual compactor with custom instructions", function()
    local captured
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = string.rep("answer ", 20) } }) },
    })
    model.context_window = 100
    setup_model(model, {
      compaction = {
        auto = false,
        reserve_tokens = 20,
        keep_recent_tokens = 5,
        run = function(options)
          captured = options
          return require("neoagent.async").run(function()
            return {
              ok = true,
              summary = "custom checkpoint",
              first_kept_entry_id = options.preparation.first_kept_entry_id,
              tokens_before = options.preparation.tokens_before,
              details = { format = "custom" },
            }
          end, { on_event = options.on_event, on_done = options.on_done })
        end,
      },
    })
    assert(neoagent.open())
    assert.is_nil(neoagent.compact())
    local interaction = assert(neoagent.send("manual compact"))
    assert(vim.wait(1000, function() return interaction:is_done() and neoagent._state().status == "idle" end))
    local run = assert(neoagent.compact("focus on tests"))
    assert(vim.wait(1000, function() return run:is_done() and neoagent._state().status == "idle" end))
    assert.are.equal("focus on tests", captured.instructions)
    local entries = neoagent.get_session():entries()
    local checkpoint = entries[#entries]
    assert.are.equal("compaction", checkpoint.type)
    assert.is_true(checkpoint.fromHook)
    assert.are.same({ format = "custom" }, checkpoint.details)
  end)

  it("reports manual compaction preconditions and failed summaries", function()
    setup_model(fake_model.new({}), { compaction = false })
    assert.is_nil(neoagent.compact())
    assert(neoagent.new_session())
    assert.is_nil(neoagent.compact())

    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = string.rep("answer ", 20) } }) },
    })
    setup_model(model, {
      compaction = {
        auto = false, reserve_tokens = 20, keep_recent_tokens = 5,
        run = function(options)
          return require("neoagent.async").run(function()
            return { ok = false, error = { kind = "compaction", message = "summary failed" } }
          end, { on_event = options.on_event, on_done = options.on_done })
        end,
      },
    })
    assert(neoagent.open())
    local interaction = assert(neoagent.send("manual compact"))
    assert(vim.wait(1000, function() return interaction:is_done() and neoagent._state().status == "idle" end))
    local run = assert(neoagent.compact())
    assert(vim.wait(1000, function() return run:is_done() and neoagent._state().status == "idle" end))
    local transcript = table.concat(vim.api.nvim_buf_get_lines(current_view().transcript_buf, 0, -1, false), "\n")
    assert.matches("summary failed", transcript)

    setup_model(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "brief" } }),
    } }), {
      compaction = { auto = false, reserve_tokens = 20, keep_recent_tokens = 100 },
    })
    local short = assert(neoagent.send("short"))
    assert(vim.wait(1000, function() return short:is_done() end))
    local compacted, err = neoagent.compact()
    assert.is_nil(compacted)
    assert.matches("Nothing can be compacted", err.message)
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

  it("composes the default Neo and Chat Controllers", function()
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
    assert(neoagent.open())
    assert.matches("^Neo ·", current_view():_title())
    assert(neoagent.send("inspect"))
    assert.are.same({ "read_file", "write_file", "edit_file", "shell", "read_agent_documentation" },
      vim.tbl_map(function(tool) return tool.name end, captured.tools))
    assert.matches("Available tools:", captured.system_prompt)
    for _, name in ipairs({ "read_file", "write_file", "edit_file", "shell" }) do
      assert.is_truthy(captured.system_prompt:find("- " .. name .. ":", 1, true))
    end
    assert.is_nil(captured.system_prompt:find("- grep:", 1, true))
    assert.is_nil(captured.system_prompt:find("- find:", 1, true))
    assert.matches("read_agent_documentation", captured.system_prompt)
    assert.matches("Use this only when the user asks about Neoagent", captured.system_prompt)
    assert.is_nil(captured.system_prompt:find("Main documentation:", 1, true))
    assert.is_truthy(captured.system_prompt:find("Current working directory: " .. vim.fn.getcwd(), 1, true))
    assert.is_true(neoagent.stop())

    assert.are.equal("Chat", neoagent.cycle_agent():config().name)
    assert.matches("^Chat ·", current_view():_title())
    assert.is_nil(neoagent.get_session())
    assert(neoagent.send("hello"))
    assert.are.same({}, captured.tools)
    assert.are.equal("", captured.system_prompt)
    assert.has_error(function() neoagent.setup({}) end)
    assert.is_true(neoagent.stop())
  end)

  it("honors an explicit tool list exactly", function()
    local captured
    local model = fake_model.new({})
    local tools = {
      require("neoagent.tools.read_file").new(),
      require("neoagent.tools.write_file").new(),
      require("neoagent.tools.edit_file").new(),
      require("neoagent.tools.shell").new(),
    }
    neoagent.setup({
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      apis = { ["fake-api"] = function() return model end },
      agents = false,
      skills = false,
      tools = tools,
      interaction = function(options)
        captured = options
        return { cancel = function()
          options.on_done({ ok = false, error = { kind = "cancelled", message = "cancelled" } })
        end }
      end,
    })
    assert(neoagent.send("chat"))
    assert.matches("You are Neo", captured.system_prompt)
    assert.are.same({ "read_file", "write_file", "edit_file", "shell" },
      vim.tbl_map(function(tool) return tool.name end, captured.tools))
    assert.is_nil(captured.system_prompt:find("read_agent_documentation", 1, true))
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
    local view = current_view()
    view:set_input("draft")
    local run = neoagent.send("draft")
    assert.is_nil(run)
    assert.are.equal("draft", view:get_input())
    assert.are.equal(0, #neoagent.get_session():messages())
  end)

  it("continues queued steering after a replaceable interaction settles", function()
    local calls = {}
    setup_model(fake_model.new({}), {
      interaction = function(options)
        calls[#calls + 1] = options
        return { cancel = function() end }
      end,
    })
    assert(neoagent.send("begin"))
    assert.is_true(neoagent.send("queued"))
    calls[1].on_done({ ok = true })
    assert(vim.wait(1000, function() return #calls == 2 end))
    assert.are.equal("queued", calls[2].prompt)
    calls[2].on_done({ ok = false, error = { kind = "cancelled", message = "done" } })
  end)

  it("creates no persistent file merely by opening or starting a new session", function()
    local directory = vim.fn.tempname()
    local model = fake_model.new({})
    setup_model(model, { persistence = { enabled = true, directory = directory } })
    assert(neoagent.open())
    assert.are.equal(model, neoagent.get_model())
    assert.are.equal("fake/test", current_view().context.model)
    assert.is_nil(vim.uv.fs_stat(directory))
    assert(neoagent.new_session())
    assert.is_nil(vim.uv.fs_stat(directory))
    assert.is_nil(neoagent.fork())
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
      if id == "alpha" then models[id].responses[1].result.message.model = id end
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
    local view = current_view()
    assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == view.input_win end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return vim.api.nvim_get_mode().mode:sub(1, 1) == "n" end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>H", true, false, true), "x", false)
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(vim.wait(1000, function()
      local saved = settings:load()
      return saved and saved.ui_position == "left"
    end))
    assert(neoagent.set_model("fake", "alpha"))
    assert.are.equal("high", neoagent.set_thinking_level("high"))
    local saved = assert(settings:load())
    assert.are.same({ provider = "fake", model = "alpha" },
      saved.controllers.Neo.default_model)
    assert.are.equal("high", saved.controllers.Neo.default_thinking_level)
    assert.are.equal("left", saved.ui_position)

    local chat = neoagent.cycle_agent()
    assert.are.equal("Chat", chat:config().name)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert.are.equal("low", neoagent.get_thinking_level())
    assert.are.equal("off", neoagent.set_thinking_level("off"))
    saved = assert(settings:load())
    assert.are.equal("high", saved.controllers.Neo.default_thinking_level)
    assert.are.equal("off", saved.controllers.Chat.default_thinking_level)
    assert.are.equal("Neo", neoagent.cycle_agent():config().name)
    assert.are.equal("alpha", neoagent.get_model().id)
    assert.are.equal("high", neoagent.get_thinking_level())
    assert.are.same({}, require("neoagent.storage").list(directory, vim.fn.getcwd()))
    local run = assert(neoagent.send("remember this"))
    local session_path = neoagent.get_session():metadata().path
    assert(vim.wait(1000, function() return run:is_done() end))
    local stored = assert(require("neoagent.storage").open(session_path)):state()
    assert.are.same({ provider = "fake", model = "alpha" }, stored.model)
    assert.are.equal("high", stored.thinking_level)

    neoagent.setup(options)
    assert(neoagent.toggle())
    assert.are.equal("left", current_view().position)
    assert.are.equal("fake/alpha", current_view().context.model)
    assert.are.same({ "off", "low", "high" }, assert(neoagent.available_thinking_levels()))
    assert.are.equal("alpha", neoagent.get_model().id)
    assert.are.equal("high", neoagent.get_thinking_level())

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
      controllers = { Neo = {
        default_model = { provider = "fake", model = "alpha" },
        default_thinking_level = "high",
      } },
    }))
    options.persistence.workspace_settings = false
    neoagent.setup(options)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert.are.equal("low", neoagent.get_thinking_level())
    assert(neoagent.set_model("fake", "test"))
    assert.are.equal("alpha", assert(settings:load()).controllers.Neo.default_model.model)
  end)

  it("falls back from invalid workspace and session preferences", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({
      controllers = { Neo = {
        default_model = "invalid",
        default_thinking_level = "extreme",
      } },
      ui_position = "corner",
    }))
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
    assert(neoagent.open())
    assert.are.equal("center", current_view().position)

    assert(settings:write({ controllers = "invalid" }))
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert(settings:write({ controllers = { Neo = "invalid" } }))
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)

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
    assert.has_error(function() neoagent.setup({}) end)
    local view = current_view()
    view:set_input("steer from the window")
    assert.is_true(view.on_submit(view:get_input()))
    assert.are.equal("", view:get_input())
    assert.is_true(neoagent.steer("second steer"))
    assert.are.same({ "steer from the window", "second steer" },
      vim.tbl_map(function(message) return message.text end, neoagent._state().steering))
    view:set_input("current draft")
    view:focus_input()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return cancelled and neoagent._state().status == "idle" end))
    assert.are.equal("steer from the window\n\nsecond steer\n\ncurrent draft", view:get_input())
    assert.is_true(cancelled)
    assert.are.equal("idle", neoagent._state().status)
    assert.is_false(neoagent.stop())
  end)

  it("selects named and forked sessions by recent tree activity", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local storage = require("neoagent.storage")
    local now = require("neoagent.util").now_ms()
    local parent = storage.new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(parent:append({
      role = "user", content = "parent preview", timestamp = now - 3 * 86400000,
    }))
    assert(parent:append_entry("session_info", { name = "Parent" }))
    local child = assert(storage.fork(parent, { directory = directory }))
    assert(child:append({
      role = "user", content = "child work", timestamp = now - 65 * 60000,
    }))
    assert(child:append_entry("session_info", { name = "Child" }))
    local grandchild = assert(storage.fork(child, { directory = directory }))
    assert(grandchild:append({
      role = "user", content = "deep work", timestamp = now - 10 * 60000,
    }))
    assert(grandchild:append_entry("session_info", { name = "Grandchild" }))
    local sibling = assert(storage.fork(parent, { directory = directory }))
    assert(sibling:append({
      role = "user", content = "sibling work", timestamp = now - 30 * 60000,
    }))
    assert(sibling:append_entry("session_info", { name = "Sibling" }))
    local other = storage.new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(other:append({
      role = "user", content = "Recent\nroot", timestamp = now - 130 * 60000,
    }))
    setup_model(fake_model.new({}), { persistence = { enabled = true, directory = directory } })
    assert(neoagent.resume(parent:metadata().path))

    local original_select = vim.ui.select
    vim.ui.select = function(items, options, callback)
      assert.are.equal("Resume Neoagent session:", options.prompt)
      assert.are.equal(5, #items)
      assert.are.equal(parent:metadata().path, items[1].path)
      assert.are.equal(child:metadata().path, items[2].path)
      assert.are.equal(parent:metadata().path, items[2].parent_session)
      assert.are.equal(grandchild:metadata().path, items[3].path)
      assert.are.equal(sibling:metadata().path, items[4].path)
      assert.are.equal(other:metadata().path, items[5].path)
      assert.matches("^● Parent%s+1%s+3d$", options.format_item(items[1]))
      assert.matches("^  ├─ Child%s+2%s+1h$", options.format_item(items[2]))
      assert.matches("^  │  └─ Grandchild%s+3%s+10m$", options.format_item(items[3]))
      assert.matches("^  └─ Sibling%s+2%s+30m$", options.format_item(items[4]))
      assert.matches("^  Recent root%s+1%s+2h$", options.format_item(items[5]))
      callback(items[2])
    end
    local ok, err = pcall(neoagent.resume)
    vim.ui.select = original_select
    assert(ok, err)
    assert.are.equal(child:metadata().path, neoagent.get_session():metadata().path)
    assert.are.equal("child work", neoagent.get_session():messages()[2].content)
    assert.is_true(current_view():is_open())

    local empty = vim.fn.tempname()
    paths[#paths + 1] = empty
    setup_model(fake_model.new({}), { persistence = { enabled = true, directory = empty } })
    assert.is_nil(neoagent.resume())
    assert.is_nil(neoagent.default_window():_state().view)
  end)

  it("navigates Pi session branches and creates linked forks", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append_model_change("fake", "test"))
    assert(store:append_thinking_level_change("high"))
    local _, _, first = store:append({ role = "user", content = "question", timestamp = 1 })
    local _, _, left = store:append({
      role = "assistant", content = { { type = "text", text = "left" } },
      provider = "fake", model = "test", timestamp = 2,
    })
    assert(store:set_leaf(first.id))
    local _, _, right = store:append({
      role = "assistant", content = { { type = "text", text = "right" } },
      provider = "fake", model = "test", timestamp = 3,
    })
    setup_model(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
      providers = { fake = { api = "fake-api", models = { test = { thinking = {
        off = {}, high = {},
      } } } } },
    })
    assert(neoagent.resume(store:metadata().path))
    assert.are.equal("right", neoagent.get_session():messages()[2].content[1].text)
    local original_select = vim.ui.select
    local selected
    vim.ui.select = function(items, options, callback)
      assert.are.equal("Neoagent branch", options.prompt)
      assert.is_true(#items >= 3)
      local choice
      for _, item in ipairs(items) do
        if item.id == left.id then choice = item break end
      end
      assert.matches("assistant · left", options.format_item(choice))
      callback(choice)
    end
    assert(neoagent.select_branch())
    vim.ui.select = original_select
    assert.are.equal("left", neoagent.get_session():messages()[2].content[1].text)
    assert.are.equal("high", neoagent.get_thinking_level())

    local source_path = neoagent.get_session():metadata().path
    vim.ui.select = function(items, options, callback)
      assert.are.equal("Fork Neoagent session from", options.prompt)
      assert.matches("user · question", options.format_item(items[1]))
      callback(items[1])
    end
    assert(neoagent.select_fork())
    vim.ui.select = original_select
    local forked = neoagent.get_session()
    selected = forked
    assert.are.equal(source_path, forked:metadata().parent_session)
    assert.are.same({}, forked:messages())
    assert.are.equal("question", current_view():get_input())
    assert.are.equal(2, #require("neoagent.storage").list(directory, vim.fn.getcwd()))
    assert.is_not_nil(selected)
  end)

  it("reports branch and fork selection preconditions", function()
    setup_model(fake_model.new({}))
    assert.is_nil(neoagent.branch("missing"))
    assert.is_nil(neoagent.select_branch())
    assert.is_nil(neoagent.fork())
    assert.is_nil(neoagent.select_fork())
    assert(neoagent.new_session())
    assert.is_nil(neoagent.select_branch())
    assert.is_nil(neoagent.select_fork())
    assert.is_nil(neoagent.fork())
    local _, _, entry = neoagent.get_session():append({ role = "user", content = "memory" })
    local ok, err = neoagent.branch("missing")
    assert.is_nil(ok)
    assert.matches("Entry not found", err.message)
    assert(neoagent.branch(entry.id, { summary = "return here" }))
    assert.are.equal("branchSummary", neoagent.get_session():messages()[2].role)
  end)

  it("toggles the view and changes configured models", function()
    setup_model(fake_model.new({}))
    assert(neoagent.open())
    assert.is_true(current_view():is_open())
    neoagent.toggle()
    assert.is_false(current_view():is_open())
    neoagent.toggle()
    assert.is_true(current_view():is_open())
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
    assert.is_true(current_view():is_open())

    neoagent.close()
    vim.ui.select = function(_, _, callback) callback(nil) end
    assert(neoagent.select_model())
    vim.ui.select = original_select
    assert.are.equal(model, neoagent.get_model())
    assert.is_false(current_view():is_open())

    neoagent.setup({ default_registry = false, persistence = { enabled = false }, providers = {}, tools = {} })
    assert.is_nil(neoagent.select_model())
  end)
end)
