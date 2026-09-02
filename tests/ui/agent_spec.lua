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
      _apis = { ["fake-api"] = function(resolved)
        model.api = model.api or resolved.api
        model.provider = model.provider or resolved.provider_id
        model.id = model.id or resolved.model_id
        model.input = model.input or resolved.model.input or { "text" }
        return model
      end },
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

  local function controlled_run(options, on_cancel)
    local pending
    local run = require("neoagent.async").run(function()
      return require("neoagent.async").await(function(done)
        pending = done
        return function()
          if on_cancel then on_cancel() end
        end
      end)
    end, {
      on_event = options.on_event,
      on_done = options.on_done,
      error_kind = "interaction",
    })
    options.complete = function(result) return pending.resolve(result) end
    return run
  end

  local function completed_run(options, result)
    return require("neoagent.async").run(function()
      return vim.deepcopy(result)
    end, {
      on_event = options.on_event,
      on_done = options.on_done,
      error_kind = "interaction",
    })
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

  it("publishes a closed completion while direct callers retain Session", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local agent = setup_model(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } }), {
      persistence = { enabled = true, directory = directory },
    })
    local finish
    local unsubscribe = agent:subscribe(function(update)
      if update.type == "finish" then finish = update.result end
    end)

    local run = assert(agent:send("retain bounded completion metadata"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and finish ~= nil
    end))

    assert.are.equal(agent:get_session(), run:result().session)
    local expected = {
      ok = true,
      status = "succeeded",
      message_count = 1,
      stop_reason = "stop",
      usage = {
        input = 0,
        output = 0,
        cacheRead = 0,
        cacheWrite = 0,
        totalTokens = 0,
      },
    }
    assert.are.same(expected, finish)
    assert.are.same(expected, agent:snapshot().result)
    unsubscribe()
  end)

  it("bounds retained completion errors and excludes provider owners", function()
    local failure = fake_model.assistant({ {
      type = "text", text = "partial",
    } }, "error")
    failure.ok = false
    failure.error = {
      kind = "provider",
      message = string.rep("m", 2000),
      detail = { message = string.rep("d", 2000), private = "hidden" },
      response = { body = "private provider response" },
      code = "overloaded",
      status = 503,
      retryable = false,
    }
    local agent = setup_model(fake_model.new({ { result = failure } }), {
      retry = { enabled = false },
    })

    local run = assert(agent:send("fail with bounded metadata"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))

    assert.are.equal("private provider response",
      run:result().error.response.body)
    local completion = agent:snapshot().result
    assert.are.equal("failed", completion.status)
    assert.are.equal(1, completion.message_count)
    assert.are.equal("error", completion.stop_reason)
    assert.are.equal(513, vim.fn.strchars(completion.error.message))
    assert.are.equal(1024, vim.fn.strchars(completion.error.detail))
    assert.are.equal("overloaded", completion.error.code)
    assert.are.equal(503, completion.error.status)
    assert.is_false(completion.error.retryable)
    assert.is_nil(completion.error.response)
    assert.is_nil(completion.session)
  end)

  it("uses returned Run results instead of synchronous completion callbacks", function()
    local returned
    local captured
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        captured = options
        options.on_done({
          ok = false,
          error = { kind = "interaction", message = "stale callback" },
        })
        returned = completed_run(options, { ok = true, new_messages = {} })
        return returned
      end,
    })

    local outer = assert(agent:send("complete synchronously"))
    assert(vim.wait(1000, function() return returned ~= nil end))
    assert.are_not.equal(returned, outer)
    assert(vim.wait(1000, function()
      return outer:is_done() and not agent:is_running()
    end))

    assert.is_true(returned:is_done())
    assert.are.equal("succeeded", agent:snapshot().result.status)
    captured.on_event({ type = "provider_status", text = "late" })
    captured.on_done({
      ok = false, error = { kind = "interaction", message = "late" },
    })
    vim.wait(20)
    assert.is_false(agent:snapshot().context.provider_status)
    assert.are.equal("succeeded", agent:snapshot().result.status)
  end)

  it("contains malformed returned interaction Runs", function()
    local agent = setup_model(fake_model.new({}), {
      _interaction = function()
        return {
          cancel = function() end,
          is_done = function() return true end,
          result = function() return "invalid" end,
        }
      end,
    })

    local run = assert(agent:send("return malformed completion"))
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))

    assert.is_false(run:result().ok)
    assert.matches("invalid result", run:result().error.message)
    assert.are.equal("failed", agent:snapshot().result.status)
  end)

  it("cancels preflight compaction before prompt acceptance", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({
      directory = directory,
      cwd = vim.fn.getcwd(),
    })
    assert(store:append({
      role = "user", content = string.rep("old ", 30), timestamp = 1,
    }, { model = { provider = "fake", model = "test" } }))
    assert(store:append({
      role = "assistant",
      content = { { type = "text", text = string.rep("work ", 30) } },
      provider = "fake", model = "test", stopReason = "stop", timestamp = 2,
      usage = { totalTokens = 90 },
    }))
    local service = {
      id = "fake", name = "Fake", state = function() return false end,
      operations = {},
    }
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      service, function(value) users[#users + 1] = value.users end)
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "unused" } }),
    } })
    model.context_window = 100
    local compaction_started = false
    local agent = setup_session(model, store, {
      providers = { fake = {
        api = "fake-api", models = { test = {} },
        service = function() return service end,
      } },
      compaction = {
        auto = true, reserve_tokens = 20, keep_recent_tokens = 10,
      },
      _compaction_run = function(options)
        compaction_started = true
        return controlled_run(options)
      end,
    })
    local before = #agent:get_session():messages()

    local run = assert(agent:send("must remain unaccepted"))
    assert(vim.wait(1000, function() return compaction_started end))
    assert.is_true(agent:stop())
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))

    assert.are.equal("cancelled", run:result().error.kind)
    assert.are.equal(0, #model.requests)
    assert.are.equal(before, #agent:get_session():messages())
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
  end)

  it("releases its provider lease when post-compaction launch fails", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({
      directory = directory,
      cwd = vim.fn.getcwd(),
    })
    assert(store:append({
      role = "user", content = string.rep("old ", 30), timestamp = 1,
    }, { model = { provider = "fake", model = "test" } }))
    assert(store:append({
      role = "assistant",
      content = { { type = "text", text = string.rep("work ", 30) } },
      provider = "fake", model = "test", stopReason = "stop", timestamp = 2,
      usage = { totalTokens = 90 },
    }))
    local service = {
      id = "fake", name = "Fake", state = function() return false end,
      operations = {},
    }
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      service, function(value) users[#users + 1] = value.users end)
    local model = fake_model.new({})
    model.context_window = 100
    local agent = setup_session(model, store, {
      providers = { fake = {
        api = "fake-api", models = { test = {} },
        service = function() return service end,
      } },
      compaction = {
        auto = true, reserve_tokens = 20, keep_recent_tokens = 10,
      },
      _compaction_run = function(options)
        return completed_run(options, {
          ok = true,
          summary = "checkpoint",
          first_kept_entry_id = options.preparation.first_kept_entry_id,
          tokens_before = options.preparation.tokens_before,
        })
      end,
      _interaction = function() error("continuation launch failed") end,
    })

    local run = assert(agent:send("continue after compaction"))
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))

    assert.is_false(run:result().ok)
    assert.matches("continuation launch failed", run:result().error.message)
    assert.are.equal("failed", agent:snapshot().result.status)
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
  end)

  it("releases manual compaction ownership after Agent destruction", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local store = require("neoagent.storage").new({
      directory = directory,
      cwd = vim.fn.getcwd(),
    })
    local appended, _, first = store:append({
      role = "user", content = string.rep("old ", 30), timestamp = 1,
    }, { model = { provider = "fake", model = "test" } })
    assert(appended and first)
    assert(store:append({
      role = "assistant",
      content = { { type = "text", text = string.rep("work ", 30) } },
      provider = "fake", model = "test", stopReason = "stop", timestamp = 2,
      usage = { totalTokens = 90 },
    }))
    local service = {
      id = "fake", name = "Fake", state = function() return false end,
      operations = {},
    }
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      service, function(value) users[#users + 1] = value.users end)
    local started = false
    local model = fake_model.new({})
    model.context_window = 100
    local agent = setup_session(model, store, {
      providers = { fake = {
        api = "fake-api", models = { test = {} },
        service = function() return service end,
      } },
      compaction = {
        auto = false, reserve_tokens = 20, keep_recent_tokens = 10,
      },
      _compaction_run = function(options)
        started = true
        return controlled_run(options)
      end,
    })
    local run = assert(agent:compact("destroy this compaction"))
    assert(vim.wait(1000, function() return started end))

    agent:destroy()

    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal("cancelled", run:result().error.kind)
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
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
    local agent = setup_model(model)
    local accepted = {}
    agent:subscribe(function(update)
      if update.type == "submission_accepted" then
        accepted[#accepted + 1] = vim.deepcopy(update)
      end
    end)
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
    assert.are.same({ "begin", "steer one", "steer two" },
      vim.tbl_map(function(update) return update.prompt end, accepted))
    for index, update in ipairs(accepted) do
      assert.are.equal(index, update.submission_id)
      assert.is_string(update.entry_id)
      assert.is_true(update.entry_id ~= "")
      if index > 1 then
        assert.is_true(accepted[index - 1].revision < update.revision)
      end
    end
  end)

  it("journals failed visible steering once when it is resubmitted", function()
    local async = require("neoagent.async")
    local pending
    local model = {
      api = "fake",
      provider = "fake",
      id = "test",
      requests = {},
    }
    function model:stream(opts)
      self.requests[#self.requests + 1] = vim.deepcopy(opts)
      if #self.requests == 1 then
        return async.run(function()
          return async.await(function(done) pending = done end)
        end, {
          on_event = opts.on_event,
          on_done = opts.on_done,
          error_kind = "model",
        })
      end
      local text = #self.requests == 2 and "second" or "duplicate"
      return async.run(function()
        return fake_model.assistant({ { type = "text", text = text } })
      end, {
        on_event = opts.on_event,
        on_done = opts.on_done,
        error_kind = "model",
      })
    end

    setup_model(model)
    assert(neoagent.open())
    local first = assert(neoagent.send("begin"))
    assert(vim.wait(1000, function() return pending ~= nil end, 5))
    local view = current_view()
    view:set_input("B")
    assert.is_true(neoagent.send("B"))
    assert.are.equal("", view:get_input())
    pending.resolve({
      ok = false,
      error = { kind = "model", message = "first failed" },
    })
    assert(vim.wait(1000, function()
      return first:is_done() and is_idle()
        and view:get_input() == "B"
        and vim.deep_equal(snapshot().context.steering, { "B" })
    end, 5))

    assert(neoagent.send(view:get_input()))
    assert(vim.wait(1000, function()
      return is_idle() and #model.requests >= 2
        and vim.deep_equal(snapshot().context.steering, {})
    end, 5))

    assert.are.equal(2, #model.requests)
    assert.are.same({ "user", "user", "assistant" },
      vim.tbl_map(function(message) return message.role end,
        neoagent.get_session():messages()))
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
    assert.is_false(current_view().context.provider_status)
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

  it("reuses context usage across streamed inference rates", function()
    local model = fake_model.new({ {
      events = {
        { type = "inference_stats", generation_tokens_per_second = 40 },
        { type = "inference_stats", generation_tokens_per_second = 45 },
        { type = "inference_stats", generation_tokens_per_second = 50 },
      },
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } })
    model.context_window = 1000
    local agent = setup_model(model)
    local session = neoagent.get_session()
    local context_messages = session.context_messages
    local context_reads = 0
    session.context_messages = function(...)
      context_reads = context_reads + 1
      return context_messages(...)
    end
    local reads = {}
    agent:subscribe(function(update)
      local stats = update.type == "context"
        and update.context.inference_stats or nil
      local rate = type(stats) == "table"
        and stats.generation_tokens_per_second or nil
      if rate and (not reads[#reads] or reads[#reads].rate ~= rate) then
        reads[#reads + 1] = { rate = rate, count = context_reads }
      end
    end)

    local run = assert(neoagent.send("measure"))
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.are.same({ 40, 45, 50 }, vim.tbl_map(function(value)
      return value.rate
    end, reads))
    assert.are.equal(reads[1].count, reads[2].count)
    assert.are.equal(reads[1].count, reads[3].count)
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
    assert.is_false(current_view().context.provider_status)
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
    assert.are.equal("length", snapshot().result.stop_reason)
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

  it("releases retry ownership when the Agent is destroyed", function()
    local failed = fake_model.assistant({}, "error")
    failed.ok = false
    failed.error = {
      kind = "transport",
      message = "HTTP 503: overloaded",
      retryable = true,
      retry_after_ms = 10000,
    }
    local service = {
      id = "fake", name = "Fake", state = function() return false end,
      operations = {},
    }
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      service, function(value) users[#users + 1] = value.users end)
    local agent = setup_model(fake_model.new({ { result = failed } }), {
      providers = { fake = {
        api = "fake-api", models = { test = {} },
        service = function() return service end,
      } },
    })
    local run = assert(agent:send("destroy during retry"))
    assert(vim.wait(1000, function()
      return agent:snapshot().context.provider_status == "Reconnecting… 1/3"
    end))

    agent:destroy()

    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal("cancelled", run:result().error.kind)
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
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
        options.on_event({ type = "provider_status", text = "synchronous" })
        options.on_done({
          ok = false,
          error = { kind = "compaction", message = "stale callback" },
        })
        return completed_run(options, {
          ok = true,
          summary = "synchronous summary",
          first_kept_entry_id = options.preparation.first_kept_entry_id,
          tokens_before = options.preparation.tokens_before,
        })
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

    local run = assert(neoagent.compact())
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.is_false(run:result().ok)
    assert.matches("must return a Run", run:result().error.message)
    assert.are.equal(2, attempts)

    run = assert(neoagent.compact())
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.is_true(run:result().ok)
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
        options.on_accept({ id = "accepted" })
        return controlled_run(options)
      end,
    }
    neoagent._setup(configured, take_runtime(configured))
    assert(neoagent.open())
    assert.matches("^ Neo ·", window_title(view_handles.window(current_view(), "transcript")))
    assert(neoagent.send("inspect"))
    assert(vim.wait(1000, function() return captured ~= nil end))
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
    assert(vim.wait(1000, is_idle))

    local applet = neoagent.applet()
    assert(applet:new("chat"))
    assert(vim.wait(1000, function()
      return window_title(view_handles.window(current_view(), "transcript")):match("^ Chat ·") ~= nil
    end))
    assert.is_nil(neoagent.get_session())
    assert(neoagent.send("hello"))
    assert(vim.wait(1000, function()
      return captured ~= nil and captured.prompt == "hello"
    end))
    assert.are.equal(2, #applet:agents())
    assert.are.equal("Chat", applet:active_agent():config().name)
    assert.are.same({}, captured.tools)
    assert.are.equal("", captured.system_prompt)
    assert.has_error(function() neoagent.setup({}) end)
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, is_idle))
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
        options.on_accept({ id = "accepted" })
        return controlled_run(options)
      end,
    }
    neoagent._setup(configured, take_runtime(configured))
    assert(neoagent.send("chat"))
    assert(vim.wait(1000, function() return captured ~= nil end))
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
      execute = function() error("unused") end,
    }
    local sandboxed = {
      name = "sandbox_tool",
      description = "Sandbox tool",
      input_schema = { type = "object", properties = {} },
      execute = function() error("unused") end,
    }
    setup_model(fake_model.new({}), {
      tools = { host },
      execute_tool = host_execute,
      _interaction = function(options)
        calls[#calls + 1] = options
        return controlled_run(options)
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
    assert(vim.wait(1000, function() return calls[1] ~= nil end))
    assert.are.equal("sandbox_tool", calls[1].tools[1].name)
    assert.are.equal(sandbox_execute, calls[1].execute_tool)
    local changed, err = agent:set_toolset(previous)
    assert.is_nil(changed)
    assert.are.equal("agent", err.kind)
    assert.are.equal("sandbox_tool", agent:get_toolset().tools[1].name)
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, function() return not agent:is_running() end))

    assert(agent:set_toolset(previous))
    assert(neoagent.send("use host tools"))
    assert(vim.wait(1000, function() return calls[2] ~= nil end))
    assert.are.equal("host_tool", calls[2].tools[1].name)
    assert.are.equal(initial.execute_tool, calls[2].execute_tool)
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, function() return not agent:is_running() end))
    assert.has_error(function() agent:set_toolset({ tools = "invalid" }) end,
      "toolset.tools must be a list")
    local stable = agent:get_toolset()
    assert.has_error(function()
      agent:set_toolset({ tools = { {
        name = "incomplete",
        description = "missing execution",
        input_schema = {},
      } } })
    end, "tool[1].execute must be a function")
    assert.are.same(stable.tools, agent:get_toolset().tools)
  end)

  it("releases a prepared provider lease when turn preparation fails", function()
    local model = fake_model.new({})
    local service = {
      id = "fake",
      name = "Fake",
      state = function() return false end,
      operations = {},
    }
    local options = model_options(model, {
      system_prompt = function() error("prompt preparation failed") end,
    })
    local runtime = provider_runtime(
      "fake", options.providers.fake, service)
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      service, function(value) users[#users + 1] = value.users end)
    local agent = neoagent.new(options, {
      runtimes = { fake = runtime },
    })
    neoagent._set_default(agent)

    local run, err = agent:send("must not be accepted")

    assert.is_nil(run)
    assert.matches("prompt preparation failed", err.message)
    assert.are.same({}, agent:get_session():messages())
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
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
        options.on_accept({ id = "accepted-" .. #interactions })
        return controlled_run(options)
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
      assert(vim.wait(1000, function() return interactions[1] ~= nil end))
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
      assert(vim.wait(1000, function() return not neo:is_running() end))

      assert(window:new("chat"))
      assert(neoagent.send("chat stays tool-free"))
      assert(vim.wait(1000, function() return interactions[2] ~= nil end))
      local chat = window:active_agent()
      assert.are.equal("Chat", chat:config().name)
      assert.are.same({}, chat:get_toolset().tools)
      local toggled, toggle_err = neoagent.toggle_sandbox()
      assert.is_nil(toggled)
      assert.are.equal("sandbox", toggle_err.kind)
      assert.is_true(neoagent.stop())
      assert(vim.wait(1000, function() return not chat:is_running() end))

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
        execute = function() error("unused") end,
      } },
      _interaction = function(options)
        captured = options
        options.on_accept({ id = "accepted" })
        return controlled_run(options)
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
      assert(vim.wait(1000, function() return captured ~= nil end))
      local stable_prompt = captured.system_prompt
      assert.matches("Sandbox controls", stable_prompt)
      assert.matches("require_escalation", captured.system_prompt)
      assert.is_true(neoagent.stop())
      assert(vim.wait(1000, is_idle))

      local previous_capture = captured
      assert(neoagent.toggle_sandbox())
      assert(neoagent.send("inspect"))
      assert(vim.wait(1000, function()
        return captured ~= previous_capture
      end))
      assert.are.equal(stable_prompt, captured.system_prompt)
      assert.is_true(neoagent.stop())
      assert(vim.wait(1000, is_idle))
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
      execute = function() error("unused") end,
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
        execute = function() error("unused") end,
      } },
      system_prompt = function(context)
        assert.are.equal(1, #context.agent_instructions)
        assert.are.equal(1, #context.skills)
        return "Custom base for " .. context.prompt
      end,
      _interaction = function(options)
        captured = options
        return controlled_run(options)
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
    assert(vim.wait(1000, function() return captured ~= nil end))
    assert.matches("missing YAML frontmatter", notifications[1].message)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.matches("^Custom base for inspect", captured.system_prompt)
    assert.matches("Always run the focused tests", captured.system_prompt)
    assert.matches("<name>review</name>", captured.system_prompt)
    assert.matches("Review Lua changes", captured.system_prompt)
    assert.matches(vim.pesc(vim.uv.fs_realpath(skill_path)), captured.system_prompt)
    assert.is_nil(captured.system_prompt:find("PRIVATE SKILL BODY", 1, true))
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, is_idle))

    local previous_capture = captured
    setup_model(fake_model.new({}), {
      agent_instructions = false,
      skills = { global_dirs = { skill_root }, project_dirs = {} },
      tools = {},
      system_prompt = "Tool-free chat",
      _interaction = function(options)
        captured = options
        return controlled_run(options)
      end,
    })
    assert(neoagent.send("chat"))
    assert(vim.wait(1000, function()
      return captured ~= previous_capture and captured.prompt == "chat"
    end))
    assert.are.equal("Tool-free chat", captured.system_prompt)
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, is_idle))
  end)

  it("keeps the draft when an interaction rejects setup", function()
    setup_model(fake_model.new({}), { _interaction = function() error("cannot start") end })
    assert(neoagent.open())
    local view = current_view()
    view:set_input("draft")
    local run = assert(neoagent.send("draft"))
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle()
    end))
    assert.are.equal("draft", view:get_input())
    assert.are.equal(0, #neoagent.get_session():messages())
  end)

  it("continues queued steering after an injected interaction settles", function()
    local calls = {}
    setup_model(fake_model.new({}), {
      _interaction = function(options)
        calls[#calls + 1] = options
        if #calls == 1 then options.on_accept({ id = "accepted" }) end
        return controlled_run(options)
      end,
    })
    assert(neoagent.send("begin"))
    assert.is_true(neoagent.send("queued"))
    assert(vim.wait(1000, function() return calls[1] ~= nil end))
    calls[1].complete({ ok = true })
    assert(vim.wait(1000, function() return #calls == 2 end))
    assert.are.equal("queued", calls[2].prompt)
    calls[2].complete({
      ok = false, error = { kind = "cancelled", message = "done" },
    })
  end)

  it("restores queued steering when a scheduled submission cannot start", function()
    local calls = {}
    setup_model(fake_model.new({}), {
      _interaction = function(options)
        calls[#calls + 1] = options
        if #calls == 1 then options.on_accept({ id = "accepted" }) end
        if #calls > 1 then error("queued interaction failed") end
        return controlled_run(options)
      end,
    })
    assert(neoagent.send("begin"))
    assert.is_true(neoagent.send("queued"))
    assert(vim.wait(1000, function() return calls[1] ~= nil end))
    calls[1].complete({ ok = true })
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
          catalog = {
            source_id = "dynamic-test-models",
            source_revision = 1,
            discover = function() error("not started") end,
          },
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
          catalog = {
            source_id = "dynamic-test-models",
            source_revision = 1,
            discover = function() error("not started") end,
          },
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

  it("clears persisted thinking for an accepted non-thinking model", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({ agents = { Neo = {
      default_model = { provider = "fake", model = "reasoning" },
      default_thinking_level = "high",
    } } }))
    local models = {
      reasoning = fake_model.new({}),
      plain = fake_model.new({ {
        result = fake_model.assistant({ { type = "text", text = "plain" } }),
      } }),
    }
    for id, model in pairs(models) do
      model.provider, model.id = "fake", id
    end
    models.plain.responses[1].result.message.model = "plain"
    local options = {
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = directory,
      },
      default_model = { provider = "fake", model = "reasoning" },
      default_thinking_level = "high",
      providers = { fake = { api = "fake-api", models = {
        reasoning = { thinking = { high = {} } },
        plain = {},
      } } },
      _apis = {
        ["fake-api"] = function(resolved) return models[resolved.model_id] end,
      },
    }
    local original = setup_model(models.reasoning, options)
    assert(neoagent.open())
    assert.are.equal("high", neoagent.get_thinking_level())
    assert.are.equal(models.plain, neoagent.set_model("fake", "plain"))
    assert.is_nil(neoagent.get_thinking_level())

    local run = assert(neoagent.send("use plain"))
    local session_path = neoagent.get_session():metadata().path
    assert(vim.wait(1000, function() return run:is_done() end, 5))

    local saved = assert(settings:load()).agents.Neo
    assert.are.same({ provider = "fake", model = "plain" },
      saved.default_model)
    assert.is_nil(saved.default_thinking_level)
    local stored = assert(require("neoagent.storage").open(session_path))
    assert.is_nil(stored:state().thinking_level)
    assert.are.equal(vim.NIL,
      stored:entries()[1].request.thinkingLevel)

    setup_model(models.plain, options)
    original:destroy()
    assert(neoagent.open())
    assert.are.equal(models.plain, neoagent.get_model())
    assert.is_nil(neoagent.get_thinking_level())
    assert.are.equal(models.reasoning,
      neoagent.set_model("fake", "reasoning"))
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
      assert.is_nil(err)
      assert(run)
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.is_false(run:result().ok)
      assert.are.equal(journal_error.message, run:result().error.message)
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
    local started = false
    setup_model(fake_model.new({}), {
      _interaction = function(options)
        started = true
        return controlled_run(options, function() cancelled.run = true end)
      end,
    })
    local agent = neoagent.default()
    local run = assert(agent:send("wait"))
    assert(vim.wait(1000, function() return started end))
    assert.is_true(agent:is_running())

    agent:destroy()

    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.same({ run = true }, cancelled)
    assert.is_false(agent:is_running())
  end)

  it("defers provider destruction until a cancelled Tool settles", function()
    local service = {
      id = "fake", name = "Fake", state = function() return false end,
      operations = {},
    }
    local users = {}
    local destroyed_with_users
    local unsubscribe = require("neoagent.provider_service").subscribe(
      service, function(value) users[#users + 1] = value.users end)
    service.destroy = function()
      destroyed_with_users = users[#users]
    end
    local model = fake_model.new({ { result = fake_model.assistant({ {
      type = "toolCall", id = "wait", name = "wait", arguments = {},
    } }, "toolUse") } })
    local tool_started = false
    local agent = setup_model(model, {
      providers = { fake = {
        api = "fake-api", models = { test = {} },
        service = function() return service end,
      } },
      tools = { {
        name = "wait", description = "Wait", input_schema = {},
        execute = function()
          tool_started = true
          return require("neoagent.async").await(function()
            return function() end
          end)
        end,
      } },
    })
    local run = assert(agent:send("wait for the Tool"))
    assert(vim.wait(1000, function()
      return tool_started and users[#users] == 1
    end))

    agent:destroy()

    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
        and destroyed_with_users ~= nil
    end))
    assert.are.same({ 1, 0 }, users)
    assert.are.equal(0, destroyed_with_users)
    unsubscribe()
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
        return controlled_run(options, function() cancelled = true end)
      end,
    })
    assert(neoagent.open())
    assert.are.equal("before", neoagent.get_session():messages()[1].content)
    assert(neoagent.send("continue"))
    assert(vim.wait(1000, function() return interaction_options ~= nil end))
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
