local fake_model = require("tests.helpers.fake_model")
local presentation = require("tests.helpers.presentation")
local view_handles = require("tests.helpers.view_handles")

describe("neoagent default agent", function()
  local neoagent
  local original_cwd
  local paths = {}

  before_each(function()
    original_cwd = vim.fn.getcwd()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
  end)

  after_each(function()
    local window = neoagent.applet()
    for _, agent in ipairs(window:agents()) do agent:destroy() end
    window:destroy()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  local function current_view()
    return neoagent.applet():view()
  end

  local function snapshot()
    return neoagent.default():snapshot()
  end

  local function is_idle()
    return snapshot().context.state == "idle"
  end

  local function feed(keys)
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  local function window_title(window)
    local value = vim.api.nvim_win_get_config(window).title or ""
    if type(value) == "string" then return value end
    return table.concat(vim.tbl_map(function(chunk)
      return type(chunk) == "table" and chunk[1] or chunk
    end, value))
  end

  local function model_options(model, extra)
    local options = {
      name = "Neo",
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      _apis = { ["fake-api"] = function() return model end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    }
    for key, value in pairs(extra or {}) do options[key] = value end
    return options
  end

  local function provider_runtime(provider_id, definition, service)
    definition = vim.deepcopy(definition)
    definition.catalog = definition.catalog or {}
    definition.models = definition.models or {}
    local catalog = require("neoagent.model_catalog").new({
      provider_id = provider_id,
      provider = definition,
      definition = definition.catalog,
      models = definition.models,
    })
    return {
      id = provider_id,
      definition = definition,
      catalog = catalog,
      service = service or {
        id = provider_id,
        name = provider_id,
        state = function() return false end,
        operations = {},
      },
    }
  end

  local function take_runtime(options, runtime)
    runtime = vim.tbl_extend("force", {}, runtime or {})
    runtime.interaction = options._interaction or runtime.interaction
    runtime.compaction_run = options._compaction_run
      or runtime.compaction_run
    options._interaction = nil
    options._compaction_run = nil
    return runtime
  end

  local function setup_model(model, extra)
    local options = model_options(model, extra)
    local agent = neoagent.new(options, take_runtime(options))
    neoagent._set_default(agent)
    return agent
  end

  local function setup_session(model, store, extra)
    local options = model_options(model, extra)
    local session = assert(require("neoagent.session").new({ store = store }))
    local runtime = take_runtime(options, {
      session = session,
      workspace = store:metadata().cwd,
      restore_session_selection = true,
    })
    local agent = neoagent.new(options, runtime)
    neoagent._set_default(agent)
    return agent
  end

  local function profile_store(directory, extra)
    local options = vim.tbl_extend("force", {
      directory = directory,
      cwd = vim.fn.getcwd(),
      metadata = { neoagent = { profileId = "neo" } },
      index_attributes = { profileId = "neo" },
    }, extra or {})
    return require("neoagent.storage").new(options)
  end

  local function setup_bundled_model(model, extra)
    local options = model_options(model, extra)
    return neoagent._setup(options, take_runtime(options))
  end

  it("composes a model, session, interaction, and passive UI", function()
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "hello" } }) } })
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("hi"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.are.equal(2, #neoagent.get_session():messages())
    local lines = table.concat(vim.api.nvim_buf_get_lines(view_handles.buffer(current_view(), "transcript"), 0, -1, false), "\n")
    assert.matches(" hi ", lines)
    assert.matches(" hello ", lines)
  end)

  it("identifies the Agent and active Session in executor context", function()
    local model = fake_model.new({
      { result = fake_model.assistant({
        { type = "toolCall", id = "c1", name = "inspect", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
      { result = fake_model.assistant({
        { type = "toolCall", id = "c2", name = "inspect", arguments = {} },
      }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local captured = {}
    local synced = {}
    local tool = {
      name = "inspect",
      description = "",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
      execute = function()
        return { content = { { type = "text", text = "inspected" } } }
      end,
      on_messages = function(messages, ctx)
        synced[ctx.session_id] = #messages
      end,
    }
    setup_model(model, {
      tools = { tool },
      execute_tool = function(selected, arguments, ctx)
        captured[#captured + 1] = ctx.context
        return selected.execute(arguments, ctx)
      end,
    })
    local run = assert(neoagent.send("inspect"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.equal("Neo", captured[1].agent)
    assert.are.equal(vim.fn.getcwd(), captured[1].workspace.cwd)
    assert.is_table(captured[1].session_id)
    assert.are.equal(4, synced[captured[1].session_id])

    local first_session_id = captured[1].session_id
    setup_model(model, {
      tools = { tool },
      execute_tool = function(selected, arguments, ctx)
        captured[#captured + 1] = ctx.context
        return selected.execute(arguments, ctx)
      end,
    })
    run = assert(neoagent.send("inspect again"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_table(captured[2].session_id)
    assert.are_not.equal(first_session_id, captured[2].session_id)
    assert.are.equal(4, synced[captured[2].session_id])
  end)

  it("isolates tool session hook failures", function()
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    setup_model(fake_model.new({}), { tools = { {
      name = "broken_sync",
      description = "",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
      execute = function()
        return { content = { { type = "text", text = "unused" } } }
      end,
      on_messages = function() error("cannot sync") end,
    } } })
    local ok = pcall(function() neoagent.default():snapshot() end)
    vim.notify = original_notify

    assert.is_true(ok)
    assert.is_true(#notifications > 0)
    assert.matches("tool broken_sync failed to read the session: .*cannot sync",
      notifications[1].message)
    assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
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

  it("tracks model context usage, provider status, and inference speed", function()
    local assistant = fake_model.assistant({ { type = "text", text = "done" } })
    assistant.message.usage.totalTokens = nil
    assistant.message.usage.input = 200
    assistant.message.usage.output = 50
    local model = fake_model.new({ {
      events = {
        { type = "usage", usage = { totalTokens = 250 } },
        { type = "provider_status", text = "quota 70% left" },
        {
          type = "inference_stats",
          prompt_tokens_per_second = 75,
        },
        {
          type = "inference_stats",
          generation_tokens_per_second = 40,
        },
      },
      result = assistant,
    } })
    model.context_window = 1000
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("measure"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.are.same({ used = 250, total = 1000, percent = 25 },
      current_view().context.context_usage)
    assert.are.equal("quota 70% left", current_view().context.provider_status)
    assert.are.same({
      generation_tokens_per_second = 40,
    }, current_view().context.inference_stats)
  end)

  it("delays prompt speed and publishes every streamed generation rate", function()
    local model = fake_model.new({ {
      events = {
        {
          type = "inference_stats",
          elapsed_ms = 20,
          prompt_tokens_per_second = 1000000,
        },
        {
          type = "inference_stats",
          elapsed_ms = 1999,
          prompt_tokens_per_second = 80,
        },
        {
          type = "inference_stats",
          elapsed_ms = 2000,
          prompt_tokens_per_second = 75,
        },
        { type = "inference_stats", generation_tokens_per_second = 40 },
        { type = "inference_stats", generation_tokens_per_second = 45 },
        { type = "inference_stats", generation_tokens_per_second = 50 },
      },
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } })
    local agent = setup_model(model)
    local observed = {}
    agent:subscribe(function(update)
      local stats = update.type == "context"
        and update.context.state == "running"
        and update.context.inference_stats or nil
      if type(stats) == "table"
          and not vim.deep_equal(observed[#observed], stats) then
        observed[#observed + 1] = vim.deepcopy(stats)
      end
    end)

    local run = assert(neoagent.send("measure"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.are.same({
      { prompt_tokens_per_second = 75 },
      { generation_tokens_per_second = 40 },
      { generation_tokens_per_second = 45 },
      { generation_tokens_per_second = 50 },
    }, observed)
  end)

  it("clears prompt processing speed when inference ends without generation timing", function()
    local model = fake_model.new({ {
      events = { {
        type = "inference_stats",
        prompt_tokens_per_second = 75,
      } },
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } })
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("measure"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.is_false(current_view().context.inference_stats)
  end)

  it("estimates context when a provider omits streamed usage", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } })
    model.context_window = 1000
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("measure"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))

    local messages = assert(neoagent.get_session():context_messages())
    local estimated = 0
    for _, message in ipairs(messages) do
      estimated = estimated + require("neoagent.compaction").estimate_tokens(message)
    end
    assert.are.equal(estimated, current_view().context.context_usage.used)
    assert.is_true(estimated > 0)
  end)

  it("automatically compacts large contexts and persists the checkpoint", function()
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
      return run:is_done() and is_idle() and #model.requests == 2
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
      view_handles.buffer(current_view(), "transcript"), 0, -1, false), "\n")
    assert.matches("Compacted from 900 tokens", transcript)
    assert.matches("Continue the work", transcript)
    local retained = assert(transcript:find("work work work", 1, true))
    local compaction_card = assert(transcript:find("Compacted from 900 tokens", 1, true))
    assert.is_true(compaction_card < retained)
    assert.are.equal("perform the large task", neoagent.get_session():messages()[1].content)
    assert.not_matches("perform the large task", transcript)
    assert.are.equal("summary quota", current_view().context.provider_status)
  end)

  it("continues a length-limited turn after automatic compaction", function()
    local truncated = fake_model.assistant({ {
      type = "thinking", thinking = "Updating review status for SSE progress",
    } }, "length")
    truncated.message.usage.totalTokens = 900
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "inspect-1", name = "inspect", arguments = {},
      } }, "toolUse") },
      { result = truncated },
      { result = fake_model.assistant({ {
        type = "text", text = "## Goal\nContinue the interrupted work",
      } }) },
      { result = fake_model.assistant({ {
        type = "text", text = "Finished after compaction",
      } }) },
    })
    model.context_window = 1000
    setup_model(model, {
      tools = { {
        name = "inspect",
        description = "Inspect state",
        input_schema = {
          type = "object", properties = {}, additionalProperties = false,
        },
        execute = function()
          return { content = { { type = "text", text = "inspected" } } }
        end,
      } },
      compaction = {
        auto = true, reserve_tokens = 200, keep_recent_tokens = 10,
      },
    })

    local run = assert(neoagent.send("perform the large task"))
    assert(vim.wait(2000, function()
      return run:is_done() and is_idle() and #model.requests == 4
    end))
    local messages = neoagent.get_session():messages()
    local length_messages = vim.tbl_filter(function(message)
      return message.role == "assistant" and message.stopReason == "length"
    end, messages)
    assert.are.equal(1, #length_messages)
    assert.are.equal("Finished after compaction",
      messages[#messages].content[1].text)
    local entries = neoagent.get_session():entries()
    assert.are.equal("compaction", entries[#entries - 1].type)
    assert.matches("context summarization assistant",
      model.requests[3].system_prompt)
    assert.are.equal(1, vim.tbl_count(vim.tbl_filter(function(message)
      return message.role == "user"
    end, messages)))
  end)

  it("bounds length continuation to one attempt", function()
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "text", text = "partial one",
      } }, "length") },
      { result = fake_model.assistant({ {
        type = "text", text = "partial two",
      } }, "length") },
    })
    setup_model(model, { compaction = false })

    local run = assert(neoagent.send("write a long answer"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))
    assert.is_true(snapshot().result.ok)
    assert.are.equal("length", snapshot().result.message.stopReason)
    assert.are.equal(3, #neoagent.get_session():messages())
  end)

  it("compacts an already-large resumed context before sending the next prompt", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append({
      role = "user", content = string.rep("old ", 30), timestamp = 1,
    }, { model = { provider = "fake", model = "test" } }))
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
    setup_session(model, store, {
      persistence = { enabled = true, directory = directory },
      compaction = { auto = true, reserve_tokens = 20, keep_recent_tokens = 10 },
    })
    local run = assert(neoagent.send("new question"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))
    assert.matches("context summarization assistant", model.requests[1].system_prompt)
    assert.are.equal("new question", model.requests[2].messages[#model.requests[2].messages].content)
    assert.are.equal("compaction", neoagent.get_session():entries()[#neoagent.get_session():entries() - 2].type)
  end)

  it("compacts and retries a context overflow once on the active branch", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append({
      role = "user", content = string.rep("old ", 30), timestamp = 1,
    }, { model = { provider = "fake", model = "test" } }))
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
    setup_session(model, store, {
      persistence = { enabled = true, directory = directory },
      compaction = { auto = false, reserve_tokens = 20, keep_recent_tokens = 10 },
    })
    local run = assert(neoagent.send("continue"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 3
    end))
    local messages = neoagent.get_session():messages()
    assert.are.equal("recovered", messages[#messages].content[1].text)
    assert.are.equal(2, vim.tbl_count(vim.tbl_filter(function(message)
      return message.role == "user"
    end, messages)))
    assert.are.equal("compaction", neoagent.get_session():entries()[#neoagent.get_session():entries() - 1].type)
  end)

  it("cleans up when overflow recovery cannot reset the failed branch", function()
    local overflow = fake_model.assistant({ {
      type = "thinking", thinking = "partial overflow",
    } }, "error")
    overflow.ok = false
    overflow.error = {
      kind = "model",
      message = "request failed",
      detail = { message = "the request exceeds the available context size" },
    }
    local model = fake_model.new({
      { result = overflow },
      { result = fake_model.assistant({ { type = "text", text = "next answer" } }) },
    })
    model.context_window = 100
    setup_model(model, {
      compaction = { auto = false, reserve_tokens = 20, keep_recent_tokens = 10 },
    })
    local session = assert(neoagent.get_session())
    assert(session:append({ role = "user", content = string.rep("old ", 30) }))
    assert(session:append({
      role = "assistant",
      content = { { type = "text", text = string.rep("work ", 30) } },
      stopReason = "stop",
    }))
    session.move_to = function()
      return nil, require("neoagent.util").error("storage", "leaf unavailable")
    end

    local run = assert(neoagent.send("overflow"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    local result = snapshot().result
    assert.is_false(result.ok)
    assert.are.equal("agent", result.error.kind)
    assert.matches("completion", result.error.message)
    assert.are.equal("leaf unavailable", result.error.detail)

    local next_run = assert(neoagent.send("try a new turn"))
    assert(vim.wait(1000, function() return next_run:is_done() and is_idle() end))
    assert.are.equal("next answer",
      neoagent.get_session():messages()[#neoagent.get_session():messages()].content[1].text)
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
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    local messages = neoagent.get_session():messages()
    assert.are.equal(2, #messages)
    assert.are.equal("retry this", messages[1].content)
    assert.are.equal("recovered", messages[2].content[1].text)
    assert.is_true(snapshot().result.ok)
    assert.is_false(snapshot().context.provider_status)
  end)

  it("cleans up when retry replay cannot reset the failed branch", function()
    local failed = fake_model.assistant({ {
      type = "thinking", thinking = "partial retry",
    } }, "error")
    failed.ok = false
    failed.error = {
      kind = "transport",
      message = "upstream disconnected",
      retryable = true,
      retry_after_ms = 1,
    }
    local model = fake_model.new({
      { result = failed },
      { result = fake_model.assistant({ { type = "text", text = "next answer" } }) },
    })
    setup_model(model)
    local session = assert(neoagent.get_session())
    session.move_to = function()
      return nil, require("neoagent.util").error("storage", "journal unavailable")
    end

    local run = assert(neoagent.send("retry this"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    local result = snapshot().result
    assert.is_false(result.ok)
    assert.are.equal("agent", result.error.kind)
    assert.are.equal("journal unavailable", result.error.detail)

    local next_run = assert(neoagent.send("try a new turn"))
    assert(vim.wait(1000, function() return next_run:is_done() and is_idle() end))
    assert.are.equal("next answer",
      neoagent.get_session():messages()[#neoagent.get_session():messages()].content[1].text)
  end)

  it("retries interrupted transports without provider-specific error metadata", function()
    local failed = fake_model.assistant({ { type = "text", text = "partial" } }, "error")
    failed.ok = false
    failed.error = {
      kind = "transport",
      message = "curl exited with status 18: curl: (18) transfer closed with outstanding read data remaining",
      exit_code = 18,
    }
    local model = fake_model.new({
      { events = { { type = "text_delta", text = "partial" } }, result = failed },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    setup_model(model, {
      retry = { enabled = true, max_retries = 3, base_delay_ms = 1 },
    })
    assert(neoagent.open())
    local run = assert(neoagent.send("retry this"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    local messages = neoagent.get_session():messages()
    assert.are.equal(2, #messages)
    assert.are.equal("retry this", messages[1].content)
    assert.are.equal("recovered", messages[2].content[1].text)
    assert.is_true(snapshot().result.ok)
  end)

  it("retries premature protocol stream endings", function()
    local failed = fake_model.assistant({}, "error")
    failed.ok = false
    failed.error = {
      kind = "protocol",
      message = "Request failed",
      detail = { reason = "stream ended before the terminal event" },
    }
    local model = fake_model.new({
      { result = failed },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    setup_model(model, {
      retry = { enabled = true, max_retries = 1, base_delay_ms = 1 },
    })
    local run = assert(neoagent.send("retry truncated stream"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    assert.is_true(snapshot().result.ok)
  end)

  it("bounds automatic retries with the configured retry budget", function()
    local function interrupted()
      local failed = fake_model.assistant({}, "error")
      failed.ok = false
      failed.error = { kind = "transport", message = "connection refused" }
      return failed
    end
    local model = fake_model.new({
      { result = interrupted() },
      { result = interrupted() },
      { result = fake_model.assistant({ { type = "text", text = "too late" } }) },
    })
    setup_model(model, {
      retry = { enabled = true, max_retries = 1, base_delay_ms = 1 },
    })
    local run = assert(neoagent.send("bounded retry"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    assert.are.equal(2, #model.requests)
    assert.is_false(snapshot().result.ok)
  end)

  it("does not retry terminal HTTP transport failures", function()
    local failed = fake_model.assistant({}, "error")
    failed.ok = false
    failed.error = {
      kind = "transport",
      message = "HTTP 401: invalid API key",
      response = { status = 401 },
    }
    local model = fake_model.new({
      { result = failed },
      { result = fake_model.assistant({ { type = "text", text = "unexpected" } }) },
    })
    setup_model(model, {
      retry = { enabled = true, max_retries = 3, base_delay_ms = 1 },
    })
    local run = assert(neoagent.send("do not retry"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle()
    end))

    assert.are.equal(1, #model.requests)
    assert.is_false(snapshot().result.ok)
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
      return snapshot().context.provider_status == "Reconnecting… 1/3"
    end))
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, function() return is_idle() end))

    assert.are.equal(1, #model.requests)
    assert.are.equal("cancelled", snapshot().result.error.kind)
    assert.is_false(snapshot().context.provider_status)
  end)

  it("reports manual compaction model resolution failures", function()
    local options = model_options(fake_model.new({}))
    options.default_model = nil
    options.providers = {}
    local value = neoagent.new(options)
    neoagent._set_default(value)

    local run, err = value:compact("summarize")

    assert.is_nil(run)
    assert.matches("No models are configured", err.message)
  end)

  it("passes manual instructions through the internal compaction runtime", function()
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
      },
      _compaction_run = function(options)
        captured = options
        return require("neoagent.async").run(function()
          return {
            ok = true,
            summary = "custom checkpoint",
            first_kept_entry_id = options.preparation.first_kept_entry_id,
            tokens_before = options.preparation.tokens_before,
          }
        end, { on_event = options.on_event, on_done = options.on_done })
      end,
    })
    assert(neoagent.open())
    assert.is_nil(neoagent.compact())
    local interaction = assert(neoagent.send("manual compact"))
    assert(vim.wait(1000, function() return interaction:is_done() and is_idle() end))
    local run = assert(neoagent.compact("focus on tests"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.are.equal("focus on tests", captured.instructions)
    local entries = neoagent.get_session():entries()
    local checkpoint = entries[#entries]
    assert.are.equal("compaction", checkpoint.type)
  end)

  it("recovers when a custom compaction runner cannot start", function()
    local assistant = fake_model.assistant({ {
      type = "text", text = string.rep("answer ", 20),
    } })
    assistant.message.usage.totalTokens = 90
    local attempts = 0
    local failed_options
    local model = fake_model.new({ { result = assistant } })
    model.context_window = 100
    setup_model(model, {
      compaction = {
        auto = true,
        reserve_tokens = 20,
        keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        attempts = attempts + 1
        if attempts == 1 then
          failed_options = options
          options.on_event({ type = "provider_status", text = "discarded" })
          options.on_done({
            ok = true,
            summary = "discarded summary",
            first_kept_entry_id = options.preparation.first_kept_entry_id,
            tokens_before = options.preparation.tokens_before,
          })
          error("compactor exploded")
        elseif attempts == 2 then
          return {}
        end
        local run = { cancel = function() end }
        options.on_event({ type = "provider_status", text = "synchronous" })
        options.on_done({
          ok = true,
          summary = "synchronous summary",
          first_kept_entry_id = options.preparation.first_kept_entry_id,
          tokens_before = options.preparation.tokens_before,
        })
        return run
      end,
    })

    local interaction = assert(neoagent.send("trigger compaction"))
    assert(vim.wait(1000, function()
      return interaction:is_done() and is_idle()
    end))
    assert.are.equal(1, attempts)
    assert.are.equal(0, #vim.tbl_filter(function(entry)
      return entry.type == "compaction"
    end, neoagent.get_session():entries()))
    failed_options.on_event({ type = "provider_status", text = "late" })
    failed_options.on_done({ ok = false, error = {
      kind = "compaction", message = "late failure",
    } })

    local run, err = neoagent.compact()
    assert.is_nil(run)
    assert.are.equal("compaction", err.kind)
    assert.matches("compaction.run must return a Run", err.message)
    assert.is_true(is_idle())
    assert.are.equal(2, attempts)

    assert(neoagent.compact())
    assert.is_true(is_idle())
    assert.are.equal(3, attempts)
    local entries = neoagent.get_session():entries()
    assert.are.equal("compaction", entries[#entries].type)
    assert.are.equal("synchronous summary", entries[#entries].summary)
  end)

  it("reports manual compaction preconditions and failed summaries", function()
    setup_model(fake_model.new({}), { compaction = false })
    assert.is_nil(neoagent.compact())
    assert.is_nil(neoagent.compact())

    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = string.rep("answer ", 20) } }) },
    })
    setup_model(model, {
      compaction = {
        auto = false, reserve_tokens = 20, keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        return require("neoagent.async").run(function()
          return { ok = false, error = {
            kind = "compaction", message = "summary failed",
          } }
        end, { on_event = options.on_event, on_done = options.on_done })
      end,
    })
    assert(neoagent.open())
    local interaction = assert(neoagent.send("manual compact"))
    assert(vim.wait(1000, function() return interaction:is_done() and is_idle() end))
    local run = assert(neoagent.compact())
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    local transcript = table.concat(vim.api.nvim_buf_get_lines(view_handles.buffer(current_view(), "transcript"), 0, -1, false), "\n")
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

  it("returns provider lease conflicts from manual compaction", function()
    local async = require("neoagent.async")
    local pending
    local service = {
      id = "fake",
      name = "Fake",
      state = function() return false end,
      operations = {
        mutate = {
          label = "Mutate",
          mutating = true,
          run = function()
            return async.run(function()
              return async.await(function(done)
                pending = done
                return function() end
              end)
            end)
          end,
        },
      },
    }
    local compactions = 0
    setup_model(fake_model.new({ {
      result = fake_model.assistant({
        { type = "text", text = string.rep("answer ", 20) },
      }),
    } }), {
      providers = {
        fake = {
          api = "fake-api",
          models = { test = {} },
          service = function() return service end,
        },
      },
      compaction = {
        auto = false,
        reserve_tokens = 20,
        keep_recent_tokens = 5,
      },
      _compaction_run = function()
        compactions = compactions + 1
        return async.run(function() return { ok = true } end)
      end,
    })
    local interaction = assert(neoagent.send("create a session"))
    assert(vim.wait(1000, function() return interaction:is_done() end))
    local operation = assert(require("neoagent.provider_service").run(
      service, "mutate"))
    assert(vim.wait(1000, function() return pending ~= nil end))

    local called, run, err = pcall(neoagent.compact)
    assert.is_true(called)
    assert.is_nil(run)
    assert.are.equal("provider", err.kind)
    assert.matches("mutating provider operation", err.message)
    assert.are.equal(0, compactions)
    assert.is_false(neoagent.default():is_running())

    operation:cancel()
    assert(vim.wait(1000, function() return operation:is_done() end))
    local release = assert(require("neoagent.provider_service").acquire(service))
    assert.is_true(release())
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

  it("resets thinking to the configured default when switching models", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local models = {
      deep = fake_model.new({}),
      gpt = fake_model.new({}),
    }
    setup_model(models.deep, {
      persistence = { enabled = true, workspace_settings = true, directory = directory },
      default_model = { provider = "fake", model = "deep" },
      default_thinking_level = "medium",
      providers = { fake = { api = "fake-api", models = {
        deep = { thinking = { medium = {}, max = {} } },
        gpt = { thinking = { medium = {}, xhigh = {} } },
      } } },
      _apis = { ["fake-api"] = function(resolved) return models[resolved.model_id] end },
    })
    assert(neoagent.open())
    assert.are.equal("max", neoagent.set_thinking_level("max"))

    assert(neoagent.set_model("fake", "gpt"))
    assert.are.equal("medium", neoagent.get_thinking_level())
    assert.is_nil(neoagent.get_session():state().thinking_level)
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert.are.same({}, settings:load())
  end)

  it("constructs Neo and Chat Agents from their Profiles", function()
    local captured
    local model = fake_model.new({})
    local configured = {
      workspace_trust = false,
      default_registry = false,
      shell_timeout = 42,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      _apis = { ["fake-api"] = function() return model end },
      agent_instructions = false,
      skills = false,
      _interaction = function(options)
        captured = options
        return { cancel = function()
          options.on_done({ ok = false, error = { kind = "cancelled", message = "cancelled" } })
        end }
      end,
    }
    neoagent._setup(configured, take_runtime(configured))
    assert(neoagent.open())
    assert.matches("^ Neo ·", window_title(view_handles.window(current_view(), "transcript")))
    assert(neoagent.send("inspect"))
    assert.are.same({ "read_file", "write_file", "edit_file", "shell", "read_agent_documentation" },
      vim.tbl_map(function(tool) return tool.name end, captured.tools))
    local shell = assert(vim.iter(captured.tools):find(function(tool)
      return tool.name == "shell"
    end))
    assert.matches("Defaults to 42", shell.input_schema.properties.timeout.description)
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

    local applet = neoagent.applet()
    assert(applet:new("chat"))
    assert(vim.wait(1000, function()
      return window_title(view_handles.window(current_view(), "transcript")):match("^ Chat ·") ~= nil
    end))
    assert.is_nil(neoagent.get_session())
    assert(neoagent.send("hello"))
    assert.are.equal(2, #applet:agents())
    assert.are.equal("Chat", applet:active_agent():config().name)
    assert.are.same({}, captured.tools)
    assert.are.equal("", captured.system_prompt)
    assert.has_error(function() neoagent.setup({}) end)
    assert.is_true(neoagent.stop())
    assert.are.equal("Neo", assert(applet:select(
      applet:agents()[1]:id())):config().name)
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
    local configured = {
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      _apis = { ["fake-api"] = function() return model end },
      agent_instructions = false,
      skills = false,
      tools = tools,
      _interaction = function(options)
        captured = options
        return { cancel = function()
          options.on_done({ ok = false, error = { kind = "cancelled", message = "cancelled" } })
        end }
      end,
    }
    neoagent._setup(configured, take_runtime(configured))
    assert(neoagent.send("chat"))
    assert.matches("You are Neo", captured.system_prompt)
    assert.are.same({ "read_file", "write_file", "edit_file", "shell" },
      vim.tbl_map(function(tool) return tool.name end, captured.tools))
    assert.is_nil(captured.system_prompt:find("read_agent_documentation", 1, true))
    assert.is_true(neoagent.stop())
  end)

  it("replaces the active toolset atomically between Runs", function()
    local calls = {}
    local host_execute = function() end
    local sandbox_execute = function() end
    local host = {
      name = "host_tool",
      description = "Host tool",
      input_schema = { type = "object", properties = {} },
    }
    local sandboxed = {
      name = "sandbox_tool",
      description = "Sandbox tool",
      input_schema = { type = "object", properties = {} },
    }
    setup_model(fake_model.new({}), {
      tools = { host },
      execute_tool = host_execute,
      _interaction = function(options)
        calls[#calls + 1] = options
        return { cancel = function()
          options.on_done({
            ok = false,
            error = { kind = "cancelled", message = "cancelled" },
          })
        end }
      end,
    })
    local agent = neoagent.default()
    local initial = agent:get_toolset()
    initial.tools[1].name = "changed copy"
    assert.are.equal("host_tool", agent:get_toolset().tools[1].name)

    local previous = agent:set_toolset({
      tools = { sandboxed },
      execute_tool = sandbox_execute,
    })
    assert.are.equal("host_tool", previous.tools[1].name)
    assert.are.equal(initial.execute_tool, previous.execute_tool)
    assert.are.equal("host_tool", agent:config().tools[1].name)
    assert.are.equal(host_execute, agent:config().execute_tool)

    assert(neoagent.send("use sandbox tools"))
    assert.are.equal("sandbox_tool", calls[1].tools[1].name)
    assert.are.equal(sandbox_execute, calls[1].execute_tool)
    local changed, err = agent:set_toolset(previous)
    assert.is_nil(changed)
    assert.are.equal("agent", err.kind)
    assert.are.equal("sandbox_tool", agent:get_toolset().tools[1].name)
    assert.is_true(neoagent.stop())

    assert(agent:set_toolset(previous))
    assert(neoagent.send("use host tools"))
    assert.are.equal("host_tool", calls[2].tools[1].name)
    assert.are.equal(initial.execute_tool, calls[2].execute_tool)
    assert.is_true(neoagent.stop())
    assert.has_error(function() agent:set_toolset({ tools = "invalid" }) end,
      "toolset.tools must be a list")
  end)

  it("toggles built-in sandbox execution while Chat or Neo is active", function()
    local interactions = {}
    local tool = {
      name = "inspect",
      description = "Inspect the workspace",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
      execute = function(_, ctx)
        return { content = { {
          type = "text",
          text = ctx.process and "sandbox" or "host",
        } } }
      end,
    }
    local host_execute = function(selected, arguments, ctx)
      return selected.execute(arguments, ctx)
    end
    setup_bundled_model(fake_model.new({}), {
      tools = { tool },
      execute_tool = host_execute,
      _interaction = function(options)
        interactions[#interactions + 1] = options
        return { cancel = function()
          options.on_done({
            ok = false,
            error = { kind = "cancelled", message = "cancelled" },
          })
        end }
      end,
    })
    local dispatch = require("neoagent.sandbox.platform")
    local original_select = dispatch.select
    dispatch.select = function()
      return {
        name = "test",
        exec = function() error("must not execute") end,
        fs = function() error("must not access files") end,
      }, {
        ok = true,
        platform = "test",
        capabilities = {},
      }
    end
    local ok, err = pcall(function()
      local window = neoagent.applet()
      assert(neoagent.open())
      assert(neoagent.send("switch execution without changing tools"))
      local neo = window:agents()[1]
      local stable = neo:get_toolset()
      assert.is_table(stable.tools[1].input_schema.properties.options)
      local running = interactions[1]
      local ctx = { context = running.context }
      local function execute()
        local value = running.execute_tool(running.tools[1], {}, ctx)
        return value.content[1].text
      end
      assert.are.equal("host", execute())
      local status = assert(neoagent.toggle_sandbox())
      assert.is_true(status.active)
      assert.are.equal("sandbox", execute())
      local unchanged = assert(neoagent.set_sandbox_enabled(true))
      assert.is_true(unchanged.active)
      status = assert(neoagent.toggle_sandbox())
      assert.is_false(status.enabled)
      assert.are.equal("host", execute())
      assert.are.same(stable.tools, neo:get_toolset().tools)
      assert.are.equal(stable.execute_tool,
        neo:get_toolset().execute_tool)
      assert.is_true(neoagent.stop())

      assert(window:new("chat"))
      assert(neoagent.send("chat stays tool-free"))
      local chat = window:active_agent()
      assert.are.equal("Chat", chat:config().name)
      assert.are.same({}, chat:get_toolset().tools)
      local toggled, toggle_err = neoagent.toggle_sandbox()
      assert.is_nil(toggled)
      assert.are.equal("sandbox", toggle_err.kind)
      assert.is_true(neoagent.stop())

      assert.are.equal(neo, window:select(neo))
      assert.is_true(neoagent.toggle_sandbox().active)
      assert.are.same(stable.tools, neo:get_toolset().tools)
    end)
    dispatch.select = original_select
    assert(ok, err)
  end)

  it("keeps sandbox guidance stable across runtime toggles", function()
    local captured
    setup_bundled_model(fake_model.new({}), {
      tools = { {
        name = "inspect",
        description = "Inspect",
        input_schema = {
          type = "object",
          properties = {},
          additionalProperties = false,
        },
      } },
      _interaction = function(options)
        captured = options
        return { cancel = function()
          options.on_done({
            ok = false,
            error = { kind = "cancelled", message = "cancelled" },
          })
        end }
      end,
    })
    local dispatch = require("neoagent.sandbox.platform")
    local original_select = dispatch.select
    dispatch.select = function()
      return {
        name = "test",
        exec = function() error("must not execute") end,
        fs = function() error("must not access files") end,
      }, { ok = true, platform = "test", capabilities = {} }
    end
    local ok, err = pcall(function()
      assert(neoagent.send("inspect"))
      local stable_prompt = captured.system_prompt
      assert.matches("Sandbox controls", stable_prompt)
      assert.matches("require_escalation", captured.system_prompt)
      assert.is_true(neoagent.stop())

      assert(neoagent.toggle_sandbox())
      assert(neoagent.send("inspect"))
      assert.are.equal(stable_prompt, captured.system_prompt)
      assert.is_true(neoagent.stop())
    end)
    dispatch.select = original_select
    assert(ok, err)
  end)

  it("keeps host tools when runtime sandbox activation is unavailable", function()
    local tool = {
      name = "inspect",
      description = "Inspect",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
    }
    setup_bundled_model(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "ready" } }),
    } }), { tools = { tool } })
    local dispatch = require("neoagent.sandbox.platform")
    local original_select = dispatch.select
    dispatch.select = function()
      return nil, {
        ok = false,
        stage = "probe",
        message = "native isolation unavailable",
      }
    end
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local ok, err = pcall(function()
      assert(neoagent.open())
      local run = assert(neoagent.send("initialize sandbox controls"))
      assert(vim.wait(1000, function() return run:is_done() end))
      local status = assert(neoagent.toggle_sandbox())
      assert.is_true(status.enabled)
      assert.is_false(status.active)
      assert.are.equal("inspect",
        neoagent.default():get_toolset().tools[1].name)
      assert.matches("tools will run without a sandbox",
        notifications[#notifications][1])
      assert.are.equal(vim.log.levels.WARN,
        notifications[#notifications][2])
      status = assert(neoagent.toggle_sandbox())
      assert.is_false(status.enabled)
      dispatch.select = function() error("sandbox probe exploded") end
      local failed, failure = neoagent.toggle_sandbox()
      assert.is_nil(failed)
      assert.are.equal("sandbox", failure.kind)
      assert.matches("sandbox probe exploded", failure.message)
    end)
    vim.notify = original_notify
    dispatch.select = original_select
    assert(ok, err)
  end)

  it("composes AGENTS.md and skill metadata into the agent prompt", function()
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
      agent_instructions = {
        global_files = { agents_path }, project_filenames = {},
      },
      skills = { global_dirs = { skill_root }, project_dirs = {} },
      tools = { {
        name = "inspect_files",
        description = "Read a file",
        input_schema = { type = "object", properties = {} },
        capabilities = { read_files = true },
      } },
      system_prompt = function(context)
        assert.are.equal(1, #context.agent_instructions)
        assert.are.equal(1, #context.skills)
        return "Custom base for " .. context.prompt
      end,
      _interaction = function(options)
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
      agent_instructions = false,
      skills = { global_dirs = { skill_root }, project_dirs = {} },
      tools = {},
      system_prompt = "Tool-free chat",
      _interaction = function(options)
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
    setup_model(fake_model.new({}), { _interaction = function() error("cannot start") end })
    assert(neoagent.open())
    local view = current_view()
    view:set_input("draft")
    local run = neoagent.send("draft")
    assert.is_nil(run)
    assert.are.equal("draft", view:get_input())
    assert.are.equal(0, #neoagent.get_session():messages())
  end)

  it("continues queued steering after an injected interaction settles", function()
    local calls = {}
    setup_model(fake_model.new({}), {
      _interaction = function(options)
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

  it("restores queued steering when a scheduled submission cannot start", function()
    local calls = {}
    setup_model(fake_model.new({}), {
      _interaction = function(options)
        calls[#calls + 1] = options
        if #calls > 1 then error("queued interaction failed") end
        return { cancel = function() end }
      end,
    })
    assert(neoagent.send("begin"))
    assert.is_true(neoagent.send("queued"))
    calls[1].on_done({ ok = true })
    assert(vim.wait(1000, function()
      return #calls == 2 and is_idle()
        and vim.deep_equal(neoagent.default():snapshot().context.steering, { "queued" })
    end))
    assert.are.equal(2, #calls)
  end)

  it("creates no persistent file merely by constructing or opening an Agent", function()
    local directory = vim.fn.tempname()
    local model = fake_model.new({})
    setup_model(model, { persistence = { enabled = true, directory = directory } })
    assert(neoagent.open())
    assert.are.equal(model, neoagent.get_model())
    assert.are.equal("fake/test", current_view().context.model)
    assert.is_nil(vim.uv.fs_stat(directory))
    assert.is_nil(vim.uv.fs_stat(directory))
    assert.is_nil(neoagent.fork())
  end)

  it("resolves the configured model when constructing an Agent", function()
    local model = fake_model.new({})
    setup_model(model)
    assert(neoagent.open())

    assert.are.equal(model, neoagent.get_model())
    assert.are.equal("fake/test", current_view().context.model)
  end)

  it("falls back from an unavailable workspace model at startup", function()
    local directory = vim.fn.tempname()
    local workspace = vim.fn.tempname()
    paths[#paths + 1], paths[#paths + 2] = directory, workspace
    vim.fn.mkdir(workspace, "p")
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = workspace,
    })
    assert(settings:write({
      agents = {
        Neo = {
          default_model = { provider = "dynamic", model = "remote" },
        },
      },
    }))
    local model = fake_model.new({})
    local options = {
      name = "Neo",
      workspace_trust = false,
      default_registry = false,
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = directory,
      },
      providers = {
        fake = { api = "fake-api", models = { test = {} } },
        dynamic = {
          api = "fake-api",
          models = {},
        },
      },
      _apis = { ["fake-api"] = function() return model end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    }
    vim.cmd("cd " .. vim.fn.fnameescape(workspace))
    local pending_agent = neoagent.new(options)
    neoagent._set_default(pending_agent)

    assert(neoagent.open())
    assert.are.equal(model, neoagent.get_model())
    assert.are.equal("fake/test", current_view().context.model)

    options.default_model = { provider = "fake", model = "test" }
    local resolved_agent = neoagent.new(options)
    local previous = neoagent._set_default(resolved_agent)
    previous:destroy()
    assert(neoagent.open())
    assert.are.equal(model, neoagent.get_model())
    assert.are.equal("fake/test", current_view().context.model)
  end)

  it("reports an unavailable workspace model when no fallback exists", function()
    local directory = vim.fn.tempname()
    local workspace = vim.fn.tempname()
    paths[#paths + 1], paths[#paths + 2] = directory, workspace
    vim.fn.mkdir(workspace, "p")
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = workspace,
    })
    assert(settings:write({
      agents = {
        Neo = {
          default_model = { provider = "dynamic", model = "missing" },
        },
      },
    }))
    local options = model_options(fake_model.new({}), {
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = directory,
      },
      providers = {
        dynamic = {
          api = "fake-api",
          models = {},
        },
      },
    })
    options.default_model = nil
    vim.cmd("cd " .. vim.fn.fnameescape(workspace))
    local value = neoagent.new(options)
    neoagent._set_default(value)

    local prepared, err = value:prepare()

    assert.is_nil(prepared)
    assert.matches("No models are configured", err.message)
    assert.is_nil(value:get_model())
  end)

  it("resolves dynamic catalogs and contains Provider Service failures", function()
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local provider_events = {}
    local failed = fake_model.assistant({}, "error")
    failed.ok = false
    failed.error = {
      kind = "model",
      message = "provider limited",
      provider_status = "limited",
      provider_status_details = { scope = "dynamic" },
    }
    local model = fake_model.new({ {
      events = { { type = "provider_status", text = "ready" } },
      result = failed,
    } })
    local service = {
      id = "dynamic",
      name = "Dynamic",
      state = function() return false end,
      operations = {},
      subscribe = function()
        return function() error("unsubscribe failed") end
      end,
      on_event = function(_, event)
        provider_events[#provider_events + 1] = event
      end,
    }
    local options = model_options(model, {
      default_model = { provider = "dynamic", model = "remote" },
      providers = {
        dynamic = {
          api = "fake-api",
          models = {},
          catalog = { discover = function() error("not started") end },
        },
      },
      _apis = { ["fake-api"] = function(resolved)
        assert.are.equal("remote", resolved.model_id)
        return model
      end },
    })
    local runtime = provider_runtime("dynamic", options.providers.dynamic,
      service)
    local value = neoagent.new(options, {
      runtimes = { dynamic = runtime },
    })
    neoagent._set_default(value)
    assert(value:prepare())
    assert(runtime.catalog:publish_discoveries({ { id = "remote" } }))
    assert(vim.wait(1000, function()
      return value:get_model() == model
    end, 5))
    local run = assert(value:send("use the discovered model"))
    assert(vim.wait(1000, function() return run:is_done() end, 5))
    assert.is_true(#provider_events > 0)
    value:destroy()
    assert(vim.wait(1000, function()
      return vim.iter(notifications):any(function(notification)
        return notification.message:match("provider unsubscribe failed")
          ~= nil
      end)
    end, 5))

    local invalid_options = model_options(model)
    local invalid = neoagent.new(invalid_options, { runtimes = {
      fake = provider_runtime(
        "fake", invalid_options.providers.fake, {}),
    } })
    neoagent._set_default(invalid)
    assert(invalid:prepare())
    assert(vim.iter(notifications):any(function(notification)
      return notification.message:match("provider service for fake is invalid")
        ~= nil
    end))

    local subscription = {
      id = "fake",
      name = "Fake",
      state = function() return false end,
      operations = {},
      subscribe = function() error("subscription failed") end,
    }
    local rejected_options = model_options(model)
    local rejected = neoagent.new(rejected_options, { runtimes = {
      fake = provider_runtime(
        "fake", rejected_options.providers.fake, subscription),
    } })
    neoagent._set_default(rejected)
    assert(rejected:prepare())

    local catalog_options = model_options(model)
    local catalog_runtime = provider_runtime(
      "fake", catalog_options.providers.fake, {
        id = "fake",
        name = "Fake",
        state = function() return false end,
        operations = {},
      })
    catalog_runtime.catalog.subscribe = function()
      error("catalog subscription failed")
    end
    local catalog_rejected = neoagent.new(catalog_options, { runtimes = {
      fake = catalog_runtime,
    } })
    neoagent._set_default(catalog_rejected)
    assert(catalog_rejected:prepare())
    assert(catalog_rejected:prepare())

    vim.notify = original_notify
    assert(vim.iter(notifications):any(function(notification)
      return notification.message:match("provider subscription failed")
        ~= nil
    end))
    assert(vim.iter(notifications):any(function(notification)
      return notification.message:match("catalog subscription failed")
        ~= nil
    end))
  end)

  it("updates an open model selector from live catalog publications", function()
    local model = fake_model.new({})
    local options = model_options(model, {
      default_model = { provider = "dynamic", model = "seed" },
      providers = {
        dynamic = {
          api = "fake-api",
          models = {},
          catalog = { seed = { { id = "seed" } } },
        },
      },
    })
    local runtime = provider_runtime(
      "dynamic", options.providers.dynamic)
    local value = neoagent.new(options, {
      runtimes = { dynamic = runtime },
    })
    neoagent._set_default(value)
    assert(value:prepare())
    assert(neoagent.open())
    assert.is_true(value:select_model())
    local view, request = presentation.active(neoagent.applet())
    local component = view.presentation_component
    assert.are.equal("dynamic/seed", component.selected)
    assert.are.equal("presentation-filter", view.applet:focused_pane())

    assert(runtime.catalog:publish_discoveries({
      { id = "remote" }, { id = "seed" },
    }))
    assert(vim.wait(1000, function()
      local target = "presentation:" .. request.id
        .. ":item:dynamic/remote"
      return view.presentation_component == component
        and #view.presentation.active.items == 2
        and component.results.layout.targets[target] ~= nil
    end, 5))
    assert.are.equal(request.id, view.presentation.active.id)
    assert.are.equal("dynamic/seed", component.selected)
    assert.are.equal("presentation-filter", view.applet:focused_pane())

    presentation.choose(neoagent.applet(), "dynamic/remote")
    assert(vim.wait(1000, function()
      local selected = value:get_model_selection()
      return selected and selected.model == "remote"
    end, 5))
    assert.are.same({ provider = "dynamic", model = "remote" },
      value:get_model_selection())
    runtime.catalog:destroy()
  end)

  it("contains model resolution failures from dynamic catalog updates", function()
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local service = {
      id = "dynamic",
      name = "Dynamic",
      state = function() return false end,
      operations = {},
    }
    local options = model_options(fake_model.new({}), {
      default_model = { provider = "dynamic", model = "remote" },
      providers = {
        dynamic = {
          api = "fake-api",
          models = {},
          catalog = { discover = function() error("not started") end },
        },
      },
      _apis = {
        ["fake-api"] = function()
          error("model constructor failed")
        end,
      },
    })
    local runtime = provider_runtime("dynamic", options.providers.dynamic,
      service)
    local value = neoagent.new(options, {
      runtimes = { dynamic = runtime },
    })
    neoagent._set_default(value)
    assert(value:prepare())
    assert(runtime.catalog:publish_discoveries({ { id = "remote" } }))

    assert(vim.wait(1000, function()
      return vim.iter(notifications):any(function(notification)
        return notification.message:match("could not resolve dynamic/remote")
          and notification.message:match("model constructor failed")
      end)
    end, 5))
    vim.notify = original_notify
    assert.is_nil(value:get_model())
  end)

  it("reports models that do not expose thinking levels", function()
    setup_model(fake_model.new({}), {
      providers = {
        fake = { api = "fake-api", models = { test = {} } },
      },
    })
    assert(neoagent.open())

    local level, err = neoagent.cycle_thinking_level()

    assert.is_nil(level)
    assert.matches("does not support thinking", err.message)
  end)

  it("restores a workspace model when constructing an Agent there", function()
    local directory = vim.fn.tempname()
    local workspace = vim.fn.tempname()
    paths[#paths + 1], paths[#paths + 2] = directory, workspace
    vim.fn.mkdir(workspace, "p")
    local models = {
      test = fake_model.new({}),
      selected = fake_model.new({ {
        result = fake_model.assistant({ { type = "text", text = "saved" } }),
      } }),
    }
    models.selected.responses[1].result.message.model = "selected"
    local extra = {
      persistence = { enabled = true, workspace_settings = true, directory = directory },
      providers = { fake = { api = "fake-api", models = {
        test = {},
        selected = {},
      } } },
      _apis = { ["fake-api"] = function(resolved) return models[resolved.model_id] end },
    }
    vim.cmd("cd " .. vim.fn.fnameescape(workspace))
    setup_model(models.test, extra)
    assert(neoagent.open())

    assert(neoagent.set_model("fake", "selected"))
    local saved = assert(neoagent.send("remember this workspace model"))
    assert(vim.wait(1000, function() return saved:is_done() end, 5))
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
    setup_model(models.test, extra)
    assert(neoagent.open())
    assert.are.equal(models.test, neoagent.get_model())
    vim.cmd("cd " .. vim.fn.fnameescape(workspace))

    setup_model(models.test, extra)
    assert(neoagent.open())
    assert.are.equal(models.selected, neoagent.get_model())
    assert.are.equal("fake/selected", current_view().context.model)
  end)

  it("commits model choices only with the messages that use them", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local models = {
      test = fake_model.new({ {
        result = fake_model.assistant({ { type = "text", text = "first" } }),
      } }),
      alpha = fake_model.new({ {
        result = fake_model.assistant({ { type = "text", text = "second" } }),
      } }),
    }
    for id, model in pairs(models) do
      model.provider, model.id = "fake", id
      model.responses[1].result.message.model = id
    end
    setup_model(models.test, {
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = directory,
      },
      providers = { fake = { api = "fake-api", models = {
        test = {},
        alpha = {},
      } } },
      _apis = {
        ["fake-api"] = function(resolved) return models[resolved.model_id] end,
      },
    })
    assert(neoagent.open())
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })

    local first = assert(neoagent.send("use the default"))
    assert(vim.wait(1000, function() return first:is_done() end, 5))
    local path = neoagent.get_session():metadata().path
    assert.are.same({ provider = "fake", model = "test" },
      assert(settings:load()).agents.Neo.default_model)
    assert.are.same({ provider = "fake", model = "test" },
      assert(require("neoagent.storage").open(path)):state().model)

    assert.are.equal(models.alpha, neoagent.set_model("fake", "alpha"))
    assert.are.same({ provider = "fake", model = "test" },
      assert(settings:load()).agents.Neo.default_model)
    assert.are.same({ provider = "fake", model = "test" },
      assert(require("neoagent.storage").open(path)):state().model)

    local second = assert(neoagent.send("use alpha"))
    assert(vim.wait(1000, function() return second:is_done() end, 5))
    assert.are.same({ provider = "fake", model = "test" },
      assert(settings:load()).agents.Neo.default_model)
    assert.are.same({ provider = "fake", model = "alpha" },
      assert(require("neoagent.storage").open(path)):state().model)

    assert.are.equal(models.alpha, neoagent.get_model())
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
      name = "Neo",
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = true, workspace_settings = true, directory = directory },
      default_model = { provider = "fake", model = "test" },
      default_thinking_level = "low",
      providers = { fake = { api = "fake-api", models = {
        test = { thinking = { off = {}, low = {}, high = {} } },
        alpha = { thinking = { off = {}, low = {}, high = {} } },
      } } },
      _apis = { ["fake-api"] = function(resolved) return models[resolved.model_id] end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    }
    local neo = neoagent.new(options)
    neoagent._set_default(neo)
    assert(neoagent.open())
    assert.are.equal("left", neoagent.set_position("left"))
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
    assert.is_nil(saved.agents)
    assert.are.equal("left", saved.ui_position)

    local chat_options = vim.deepcopy(options)
    chat_options.name = "Chat"
    local chat = neoagent.new(chat_options)
    assert.are.equal(neo, neoagent._set_default(chat))
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert.are.equal("low", neoagent.get_thinking_level())
    assert.are.equal("off", neoagent.set_thinking_level("off"))
    saved = assert(settings:load())
    assert.is_nil(saved.agents)
    assert.are.equal(chat, neoagent._set_default(neo))
    assert.are.equal("alpha", neoagent.get_model().id)
    assert.are.equal("high", neoagent.get_thinking_level())
    assert.are.same({}, require("neoagent.storage").list(directory, vim.fn.getcwd()))
    local run = assert(neoagent.send("remember this"))
    local session_path = neoagent.get_session():metadata().path
    assert(vim.wait(1000, function() return run:is_done() end))
    local stored = assert(require("neoagent.storage").open(session_path)):state()
    assert.are.same({ provider = "fake", model = "alpha" }, stored.model)
    assert.are.equal("high", stored.thinking_level)
    saved = assert(settings:load())
    assert.are.same({ provider = "fake", model = "alpha" },
      saved.agents.Neo.default_model)
    assert.are.equal("high", saved.agents.Neo.default_thinking_level)

    local replacement = neoagent.new(options)
    assert.are.equal(neo, neoagent._set_default(replacement))
    neo:destroy()
    chat:destroy()
    assert(neoagent.open())
    assert.are.equal("left", current_view().position)
    assert.are.equal("fake/alpha", current_view().context.model)
    assert.are.same({ "off", "low", "high" }, assert(neoagent.available_thinking_levels()))
    assert.are.equal("alpha", neoagent.get_model().id)
    assert.are.equal("high", neoagent.get_thinking_level())

    setup_session(models.test,
      assert(require("neoagent.storage").open(session_path)), options)
    assert.are.equal("alpha", neoagent.get_model().id)
    assert.are.equal("high", neoagent.get_thinking_level())
  end)

  it("keeps live choices and accepted messages consistent across persistence failures", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local function response(text)
      local value = fake_model.assistant({ { type = "text", text = text } })
      value.message.model = "test"
      return value
    end
    local model = fake_model.new({
      { result = response("saved once") },
      { result = response("saved twice") },
    })
    local save_error = { kind = "storage", message = "settings unavailable" }
    local journal_error = { kind = "storage", message = "journal unavailable" }
    local workspace_settings = require("neoagent.workspace_settings")
    local storage = require("neoagent.storage")
    local original_settings_new = workspace_settings.new
    local original_storage_new = storage.new
    local captured_store
    local fail_settings = true
    workspace_settings.new = function(opts)
      local settings = original_settings_new(opts)
      local update = settings.update
      settings.update = function(self, values)
        if fail_settings then return nil, save_error end
        return update(self, values)
      end
      return settings
    end
    storage.new = function(opts)
      captured_store = original_storage_new(opts)
      return captured_store
    end

    local ok, test_err = pcall(function()
      local extra = {
        persistence = { enabled = true, workspace_settings = true, directory = directory },
        default_thinking_level = "low",
        providers = { fake = { api = "fake-api", models = { test = { thinking = {
          off = {}, low = {}, high = {},
        } } } } },
      }
      setup_model(model, extra)
      local agent = neoagent.default()
      assert(agent:prepare())

      local selected, err = agent:set_model("fake", "test")
      assert.are.equal(model, selected)
      assert.is_nil(err)

      local level
      level, err = agent:set_thinking_level("high")
      assert.are.equal("high", level)
      assert.is_nil(err)
      assert.are.equal("high", agent:get_thinking_level())

      local append = captured_store.append
      local run = assert(agent:send("accepted without settings"))
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.is_true(run:result().ok)
      assert.are.same({ provider = "fake", model = "test" },
        agent:get_session():state().model)

      fail_settings = false
      captured_store.append = function() return nil, journal_error end
      selected, err = agent:set_model("fake", "test")
      assert.are.equal(model, selected)
      assert.is_nil(err)
      run, err = agent:send("rejected")
      assert.is_nil(run)
      assert.are.equal(journal_error, err)
      assert.are.same({ provider = "fake", model = "test" },
        agent:get_session():state().model)

      captured_store.append = append
      run = assert(agent:send("accepted"))
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.are.same({ provider = "fake", model = "test" },
        agent:get_session():state().model)
    end)
    workspace_settings.new = original_settings_new
    storage.new = original_storage_new
    assert(ok, test_err)
  end)
  it("cancels an active interaction Run when destroyed", function()
    local cancelled = {}
    setup_model(fake_model.new({}), {
      _interaction = function()
        return { cancel = function() cancelled.run = true end }
      end,
    })
    local agent = neoagent.default()
    assert(agent:send("wait"))
    assert.is_true(agent:is_running())

    agent:destroy()

    assert.are.same({ run = true }, cancelled)
    assert.is_false(agent:is_running())
  end)

  it("reports model catalog enumeration failures", function()
    setup_model(fake_model.new({}))
    local models = require("neoagent.models")
    local util = require("neoagent.util")
    local original_available = models.available
    local original_notify = vim.notify
    local notification
    models.available = function()
      return nil, util.error("model", "catalog unavailable", "invalid catalog")
    end
    vim.notify = function(message, level)
      notification = { message, level }
    end

    local ok, selected = pcall(neoagent.select_model)

    vim.notify = original_notify
    models.available = original_available
    assert.is_true(ok)
    assert.is_nil(selected)
    assert.matches("catalog unavailable: invalid catalog", notification[1])
    assert.are.equal(vim.log.levels.ERROR, notification[2])
  end)

  it("falls back from invalid workspace and session preferences", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({
      agents = { Neo = {
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

    assert(settings:write({ agents = "invalid" }))
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)
    assert(settings:write({ agents = { Neo = "invalid" } }))
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)

    vim.fn.writefile({ "{" }, settings.settings_path)
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", neoagent.get_model().id)

    assert(settings:write({}))
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append({ role = "user", content = "fallback", timestamp = 1 }, {
      model = { provider = "missing", model = "gone" },
    }))
    setup_session(model, store, extra)
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

  it("refreshes buffers from semantic custom tool results", function()
    local root = vim.fn.tempname()
    paths[#paths + 1] = root
    vim.fn.mkdir(root, "p")
    local path = root .. "/file.txt"
    vim.fn.writefile({ "old" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buffer = vim.api.nvim_get_current_buf()
    local tool = {
      name = "replace_disk_file",
      description = "Replace a file on disk",
      input_schema = { type = "object", properties = {}, additionalProperties = false },
      execute = function()
        vim.fn.writefile({ "new" }, path)
        return {
          content = { { type = "text", text = "replaced" } },
          details = { changed_paths = { path } },
        }
      end,
    }
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "replace", name = tool.name, arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    setup_model(model, { tools = { tool } })
    assert(neoagent.open())

    local run = assert(neoagent.send("change it"))

    assert(vim.wait(1500, function() return run:is_done() end))
    assert(vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1] == "new"
    end))
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

  it("rebuilds tool state from a resumed Session conversation", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({
      directory = directory,
      cwd = vim.fn.getcwd(),
    })
    local plan = { explanation = "Restored from history", plan = {
      { step = "Resume the plan", status = "in_progress" },
    } }
    assert(store:append({ role = "user", content = "continue", timestamp = 1 }))
    assert(store:append({
      role = "assistant",
      content = { {
        type = "toolCall", id = "plan", name = "update_plan",
        arguments = plan,
      } },
      timestamp = 2,
    }))
    assert(store:append({
      role = "toolResult", toolCallId = "plan", toolName = "update_plan",
      content = { { type = "text", text = "Plan updated" } },
      details = plan, timestamp = 3,
    }))

    local tool = require("neoagent.tools.update_plan").new()
    local session_ids = {}
    local on_messages = tool.on_messages
    tool.on_messages = function(messages, ctx)
      session_ids[#session_ids + 1] = ctx.session_id
      return on_messages(messages, ctx)
    end
    setup_session(fake_model.new({}), store, {
      persistence = { enabled = true, directory = directory },
      tools = { tool },
      ui = { style = "codex" },
    })
    neoagent.default():snapshot()
    local resumed_id = session_ids[#session_ids]
    assert.are.same(plan, tool.current({ session_id = resumed_id }))
    assert(neoagent.open())
    assert(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(
        view_handles.buffer(current_view(), "transcript"), 0, -1, false)
      return table.concat(lines, "\n"):find("Updated Plan", 1, true) ~= nil
    end))

    setup_model(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
      tools = { tool },
      ui = { style = "codex" },
    })
    neoagent.default():snapshot()
    local fresh_id = session_ids[#session_ids]
    assert.are_not.equal(resumed_id, fresh_id)
    assert.is_nil(tool.current({ session_id = fresh_id }))
    assert.are.same(plan, tool.current({ session_id = resumed_id }))
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
    local cancelled = false
    local interaction_options
    setup_session(fake_model.new({}), store, {
      persistence = { enabled = true, directory = directory },
      system_prompt = function(context)
        assert.are.same({}, context.tools)
        return table.concat({
          require("neoagent.system_prompt").default(context),
          "prompt: " .. context.prompt,
        }, "\n\n")
      end,
      _interaction = function(options)
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
    assert.are.equal("before", neoagent.get_session():messages()[1].content)
    assert(neoagent.send("continue"))
    local messages = neoagent.get_session():messages()
    assert.are.equal(5, #messages)
    assert.are.equal("toolResult", messages[5].role)
    assert.are.equal("pending", messages[5].toolCallId)
    assert.is_true(messages[5].isError)
    assert.matches("Available tools:\n%(none%)", interaction_options.system_prompt)
    assert.matches("prompt: continue$", interaction_options.system_prompt)
    assert.is_nil(neoagent.fork())
    assert.is_nil(neoagent.select_model())
    assert.is_nil(neoagent.set_model("fake", "test"))
    assert.is_nil(neoagent.cycle_thinking_level())
    assert.is_nil(neoagent.set_thinking_level("high"))
    assert.has_error(function() neoagent.setup({}) end)
    local view = current_view()
    view:set_input("steer from the window")
    view:focus_input()
    feed("<CR>")
    assert(vim.wait(1000, function()
      return view:get_input() == ""
        and vim.deep_equal(snapshot().context.steering, { "steer from the window" })
    end))
    assert.is_true(neoagent.steer("second steer"))
    assert.are.same({ "steer from the window", "second steer" },
      snapshot().context.steering)
    view:set_input("current draft")
    view:focus_input()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view:get_input() == "" and not cancelled and not is_idle()
    end))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return cancelled and is_idle() end))
    assert.are.equal("steer from the window\n\nsecond steer", view:get_input())
    assert.is_true(cancelled)
    assert.are.equal("idle", snapshot().context.state)
    assert.is_false(neoagent.stop())
  end)

  it("selects forked sessions by recent tree activity", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local storage = require("neoagent.storage")
    local now = require("neoagent.util").now_ms()
    local parent = profile_store(directory)
    assert(parent:append({
      role = "user", content = "parent preview", timestamp = now - 3 * 86400000,
    }))
    local child = assert(storage.fork(parent, { directory = directory }))
    assert(child:append({
      role = "user", content = "child work", timestamp = now - 65 * 60000,
    }))
    local grandchild = assert(storage.fork(child, { directory = directory }))
    assert(grandchild:append({
      role = "user", content = "deep work", timestamp = now - 10 * 60000,
    }))
    local sibling = assert(storage.fork(parent, { directory = directory }))
    assert(sibling:append({
      role = "user", content = "sibling work", timestamp = now - 30 * 60000,
    }))
    local other = profile_store(directory)
    assert(other:append({
      role = "user", content = "Recent\nroot", timestamp = now - 130 * 60000,
    }))
    local weekly = profile_store(directory)
    assert(weekly:append({
      role = "user", content = "Weekly root", timestamp = now - 8 * 86400000,
    }))
    local monthly = profile_store(directory)
    assert(monthly:append({
      role = "user", content = "Monthly root", timestamp = now - 60 * 86400000,
    }))
    local yearly = profile_store(directory)
    assert(yearly:append({
      role = "user", content = "Yearly root", timestamp = now - 800 * 86400000,
    }))
    local function set_activity(store, age)
      local seconds = (now - age) / 1000
      assert(vim.uv.fs_utime(store:metadata().path, seconds, seconds))
    end
    set_activity(parent, 3 * 86400000)
    set_activity(child, 65 * 60000)
    set_activity(grandchild, 10 * 60000)
    set_activity(sibling, 30 * 60000)
    set_activity(other, 130 * 60000)
    set_activity(weekly, 8 * 86400000)
    set_activity(monthly, 60 * 86400000)
    set_activity(yearly, 800 * 86400000)
    setup_bundled_model(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
    })
    assert(neoagent.resume(parent:metadata().path))
    assert(neoagent.open())

    assert.is_false(neoagent.toggle())
    assert(neoagent.resume())
    assert.is_true(current_view():is_open())
    local _, request = presentation.active(neoagent.applet())
    assert.are.equal(8, #request.items)
    assert.matches("^● parent preview%s+3d.*Neo$", request.items[1].label)
    assert.matches("^  ├─ parent preview%s+1h.*Neo$", request.items[2].label)
    assert.matches("^  │  └─ parent preview%s+10m.*Neo$", request.items[3].label)
    assert.matches("^  └─ parent preview%s+30m.*Neo$", request.items[4].label)
    assert.matches("^  Recent root%s+2h.*Neo$", request.items[5].label)
    assert.matches("^  Weekly root%s+1w.*Neo$", request.items[6].label)
    assert.matches("^  Monthly root%s+2mo.*Neo$", request.items[7].label)
    assert.matches("^  Yearly root%s+2y.*Neo$", request.items[8].label)
    presentation.choose(neoagent.applet(), "session-2")
    assert(vim.wait(1000, function()
      return neoagent.get_session():metadata().path == child:metadata().path
    end, 5))
    assert.are.equal(child:metadata().path, neoagent.get_session():metadata().path)
    assert.are.equal("child work", neoagent.get_session():messages()[2].content)
    assert.is_true(current_view():is_open())

    local empty = vim.fn.tempname()
    paths[#paths + 1] = empty
    setup_bundled_model(fake_model.new({}), {
      persistence = { enabled = true, directory = empty },
    })
    assert.is_nil(neoagent.resume())
    assert.is_true(neoagent.applet():view():is_open())
  end)

  it("presents complete session text in the resume selector", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local text = "resume:" .. string.rep(" complete-session-text", 12)
    local store = profile_store(directory)
    assert(store:append({ role = "user", content = text, timestamp = 1 }))
    setup_bundled_model(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
    })

    assert(neoagent.open())
    assert(neoagent.resume())
    local _, request = presentation.active(neoagent.applet())
    assert.are.equal(1, #request.items)
    assert.is_truthy(request.items[1].label:find(text, 1, true))
    assert.is_nil(request.items[1].label:find("…", 1, true))
    presentation.cancel(neoagent.applet())
  end)

  it("navigates session branches and creates linked forks", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = profile_store(directory)
    local _, _, first = store:append({
      role = "user", content = "question", timestamp = 1,
    }, {
      model = { provider = "fake", model = "test" },
      thinking_level = "high",
    })
    local _, _, left = store:append({
      role = "assistant", content = { { type = "text", text = "left" } },
      provider = "fake", model = "test", timestamp = 2,
    })
    assert(store:set_leaf(first.id))
    local _, _, right = store:append({
      role = "assistant", content = { { type = "text", text = "right" } },
      provider = "fake", model = "test", timestamp = 3,
    })
    setup_bundled_model(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
      providers = { fake = { api = "fake-api", models = { test = { thinking = {
        off = {}, high = {},
      } } } } },
    })
    assert(neoagent.resume(store:metadata().path))
    assert(neoagent.open())
    assert.are.equal("right", neoagent.get_session():messages()[2].content[1].text)
    assert.is_false(neoagent.toggle())
    assert(neoagent.select_branch())
    assert.is_true(current_view():is_open())
    local _, request = presentation.active(neoagent.applet())
    assert.is_true(#request.items >= 3)
    local choice
    for _, item in ipairs(request.items) do
      if item.id == left.id then choice = item break end
    end
    assert.matches("assistant · left", choice.label)
    presentation.choose(neoagent.applet(), left.id)
    assert(vim.wait(1000, function()
      return neoagent.get_session():messages()[2].content[1].text == "left"
    end, 5))
    assert.are.equal("left", neoagent.get_session():messages()[2].content[1].text)
    assert.are.equal("high", neoagent.get_thinking_level())

    local source_path = neoagent.get_session():metadata().path
    assert.is_false(neoagent.toggle())
    assert(neoagent.select_fork())
    assert.is_true(current_view():is_open())
    _, request = presentation.active(neoagent.applet())
    assert.matches("user · question", request.items[1].label)
    presentation.choose(neoagent.applet(), first.id)
    assert(vim.wait(1000, function()
      local session = neoagent.get_session()
      return session and session:metadata().parent_session == source_path
    end, 5))
    local forked = neoagent.get_session()
    assert.are.equal(source_path, forked:metadata().parent_session)
    assert.are.same({}, forked:messages())
    assert.are.equal("question", current_view():get_input())
    assert.are.equal(2, #require("neoagent.storage").list(directory, vim.fn.getcwd()))
    assert.are.equal(2, #neoagent.applet():agents())
  end)

  it("reports branch and fork selection preconditions", function()
    setup_model(fake_model.new({}))
    assert.is_nil(neoagent.steer("idle steering"))
    assert.is_nil(neoagent.branch("missing"))
    assert.is_nil(neoagent.select_branch())
    assert.is_nil(neoagent.fork())
    assert.is_nil(neoagent.select_fork())
    assert.is_nil(neoagent.select_branch())
    assert.is_nil(neoagent.select_fork())
    assert.is_nil(neoagent.fork())
    local _, _, entry = neoagent.get_session():append({ role = "user", content = "memory" })
    local ok, err = neoagent.branch("missing")
    assert.is_nil(ok)
    assert.matches("Entry not found", err.message)
    assert(neoagent.branch(entry.id))
    assert.are.equal(1, #neoagent.get_session():messages())
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
    local ok, err = pcall(neoagent.select_model)
    assert(ok, err)
    local window = neoagent.applet()
    local _, model_request = presentation.active(window)
    assert.are.same({ "fake/alpha", "fake/test" },
      vim.tbl_map(function(item) return item.label end, model_request.items))
    presentation.choose(window, "fake/alpha")
    assert(vim.wait(1000, function()
      return neoagent.get_model() == model and current_view():is_open()
    end, 5))
    assert.are.equal(model, neoagent.get_model())
    assert.is_true(current_view():is_open())

    neoagent.close()
    assert(neoagent.select_model())
    presentation.cancel(window)
    assert(vim.wait(1000, function() return current_view():is_open() end, 5))
    assert.are.equal(model, neoagent.get_model())
    assert.is_true(current_view():is_open())

    neoagent.setup({ default_registry = false, workspace_trust = false,
      persistence = { enabled = false }, providers = {}, tools = {} })
    assert.is_nil(neoagent.select_model())
  end)
end)
