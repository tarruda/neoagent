local assert = require("luassert")
local fake_model = require("tests.helpers.fake_model")
local presentation = require("tests.helpers.presentation")
local view_handles = require("tests.helpers.view_handles")

describe("neoagent default agent", function()
  local neoagent = require("neoagent")
  ---@type string
  local original_cwd
  ---@type string[]
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
    return (assert(neoagent.applet():view()))
  end

  local function current_session()
    return (assert(neoagent.get_session()))
  end

  local function snapshot()
    return assert(neoagent.default()):snapshot()
  end

  local function is_idle()
    return snapshot().context.state == "idle"
  end

  ---@param keys string
  local function feed(keys)
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  ---@param window integer
  local function window_title(window)
    local value = vim.api.nvim_win_get_config(window).title or ""
    if type(value) == "string" then return value end
    return table.concat(vim.tbl_map(function(chunk)
      return type(chunk) == "table" and chunk[1] or chunk
    end, value))
  end

  ---@class Neoagent.TestControlledInteraction: Neoagent.AgentInteractionOptions
  ---@field complete? fun(result: Neoagent.ChatResult)

  ---@class Neoagent.TestAgentUIConfig: Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  ---@field _interaction? fun(options: Neoagent.AgentInteractionOptions): Neoagent.ChatRun
  ---@field _compaction_run? fun(options: Neoagent.AgentCompactionOptions): Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>

  ---@param model Neoagent.Model
  ---@param extra? Neoagent.TestAgentUIConfig
  ---@return Neoagent.TestAgentUIConfig
  local function model_options(model, extra)
    ---@type Neoagent.TestAgentUIConfig
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
    return vim.tbl_extend("force", options, extra or {})
  end

  ---@param notifications {message: string}[]
  ---@param pattern string
  local function has_notification(notifications, pattern)
    for _, notification in ipairs(notifications) do
      if notification.message:match(pattern) then return true end
    end
    return false
  end

  ---@param options Neoagent.TestAgentUIConfig
  ---@param id string
  ---@return Neoagent.ProviderOptions
  local function configured_provider(options, id)
    local definition = assert(options.providers)[id]
    assert(type(definition) == "table")
    return definition
  end

  ---@param provider_id string
  ---@param definition Neoagent.ProviderOptions
  ---@param service? Neoagent.ProviderService
  ---@return Neoagent.ProviderRuntime
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
      definition = definition --[[@as Neoagent.ProviderDefinition]],
      credentials = require("neoagent.provider_credentials").new({ provider_id = provider_id, provider = definition }),
      auth_services = {},
      catalog = catalog,
      service = service or {
        id = provider_id,
        name = provider_id,
        state = function() return false end,
        operations = {},
      },
    }
  end

  ---@param options Neoagent.TestAgentUIConfig
  ---@param runtime? Neoagent.AgentRuntimeOptions
  ---@return Neoagent.AgentRuntimeOptions
  local function take_runtime(options, runtime)
    runtime = vim.tbl_extend("force", {}, runtime or {})
    runtime.interaction = options._interaction or runtime.interaction
    runtime.compaction_run = options._compaction_run
      or runtime.compaction_run
    options._interaction = nil
    options._compaction_run = nil
    return runtime
  end

  ---@param options Neoagent.TestAgentUIConfig
  ---@return Neoagent.ProfileRuntimeOptions
  local function profile_runtime(options)
    local runtime = take_runtime(options)
    return { interaction = runtime.interaction, compaction_run = runtime.compaction_run }
  end

  ---@param options Neoagent.AgentInteractionOptions
  ---@param id string
  local function accept_entry(options, id)
    assert(options.on_accept)({
      type = "message", id = id, created_at = 1767225600000,
      message = { role = "user", content = options.prompt, timestamp = 1 },
    })
  end

  ---@param model Neoagent.Model
  ---@param extra? Neoagent.TestAgentUIConfig
  local function setup_model(model, extra)
    local options = model_options(model, extra)
    local agent = neoagent.new(options, take_runtime(options))
    neoagent._set_default(agent)
    return agent
  end

  ---@param model Neoagent.Model
  ---@param store Neoagent.SessionStore
  ---@param extra? Neoagent.TestAgentUIConfig
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

  ---@param directory string
  ---@param extra? Partial<Neoagent.StoreOptions>
  local function profile_store(directory, extra)
    ---@type Neoagent.StoreOptions
    local options = vim.tbl_extend("force", {
      directory = directory,
      cwd = vim.fn.getcwd(),
      metadata = { neoagent = { profileId = "neo" } },
      index_attributes = { profileId = "neo" },
    }, extra or {})
    return require("neoagent.storage").new(options)
  end

  ---@param model Neoagent.Model
  ---@param extra? Neoagent.TestAgentUIConfig
  local function setup_bundled_model(model, extra)
    local options = model_options(model, extra)
    local runtime = take_runtime(options)
    return neoagent._setup(options, {
      interaction = runtime.interaction, compaction_run = runtime.compaction_run,
    })
  end

  ---@generic T, E
  ---@param options {on_event?: fun(event: E), on_done?: fun(result: T), complete?: fun(result: T)}
  ---@param on_cancel? fun()
  ---@return Neoagent.Run<T, E>
  local function controlled_run(options, on_cancel)
    ---@type Neoagent.AwaitCallbacks<T>?
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
    options.complete = function(result) assert(pending).resolve(result) end
    return run
  end

  ---@generic T, E
  ---@param options {on_event?: fun(event: E), on_done?: fun(result: T)}
  ---@param result T
  ---@return Neoagent.Run<T, E>
  local function completed_run(options, result)
    return require("neoagent.async").run(function()
      return require("neoagent.util").copy(result)
    end, {
      on_event = options.on_event,
      on_done = options.on_done,
      error_kind = "interaction",
    })
  end

  ---@param assistant Neoagent.ModelSuccess
  ---@param err Neoagent.Error
  ---@return Neoagent.ModelFailure
  local function model_failure(assistant, err)
    return { ok = false, message = assistant.message, text = assistant.text, error = err }
  end

  it("publishes an accepted prompt before uploads and stays editable during preparation", function()
    local async = require("neoagent.async")
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = {
      require("tests.helpers.attachments").new(session:files()).image("abc"),
    } }))
    ---@type Neoagent.AwaitCallbacks<Neoagent.ByteFetchResult>?
    local pending
    local visible_at_upload = false
    local requests = 0
    local prompt = "Inspect the retained synthetic image"
    local function transcript()
      local buffer = assert(view_handles.buffer(current_view(), "transcript"))
      return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    end
    local agent = neoagent.new({
      workspace_trust = false, default_registry = false, persistence = { enabled = false },
      default_model = { provider = "deepseek", model = "deepseek-v4.1-flash-expires-on-0910" },
      providers = { deepseek = { api = "openai-completions", base_url = "https://api.deepseek.com",
        auth = "deepseek", api_key = "synthetic-key", models = {
          ["deepseek-v4.1-flash-expires-on-0910"] = { input = { "text", "image" } },
        } } },
      tools = {}, agent_instructions = false, skills = false, ui = { images = false },
    }, { session = session, transport = {
      fetch = function()
        visible_at_upload = transcript():find(prompt, 1, true) ~= nil
        return async.run(function() return async.await(function(done) pending = done end) end)
      end,
      request = function()
        requests = requests + 1
        return async.run(function() return { ok = true, response = { status = 200, headers = {} } } end)
      end,
    } })
    neoagent._set_default(agent)
    assert(neoagent.open())
    vim.cmd("stopinsert")
    current_view():set_input(prompt)
    local run = assert(neoagent.send(prompt))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return pending ~= nil end, 1))
    current_view():set_input("Draft while upload is pending")
    assert.are.equal("Draft while upload is pending", current_view():get_input())
    assert.is_false(run:is_done())
    assert.are.equal(0, requests)
    assert(pending).reject({ kind = "transport", message = "Synthetic upload failure" })
    assert(vim.wait(1000, function() return run:is_done() end, 1))
    assert.is_false(assert(run:result()).ok)
    assert.is_not_nil((transcript():find(prompt, 1, true)))
    assert.are.equal("Draft while upload is pending", current_view():get_input())
    assert.is_true(visible_at_upload, "upload began before the accepted prompt reached the native transcript")
  end)

  it("composes a model, session, interaction, and passive UI", function()
    local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "hello" } }) } })
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("hi"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.are.equal(2, #current_session():messages())
    local lines = table.concat(vim.api.nvim_buf_get_lines((assert(view_handles.buffer(current_view(), "transcript"))), 0, -1, false), "\n")
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and finish ~= nil
    end))

    assert.are.equal(agent:get_session(), assert(run:result()).session)
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
    local failure = model_failure(fake_model.assistant({ {
      type = "text", text = "partial",
    } }, "error"), {
      kind = "provider",
      message = string.rep("m", 2000),
      detail = { message = string.rep("d", 2000), private = "hidden" },
      response = { body = "private provider response" },
      code = "overloaded",
      status = 503,
      retryable = false,
    })
    local agent = setup_model(fake_model.new({ { result = failure } }), {
      retry = { enabled = false },
    })

    local run = assert(agent:send("fail with bounded metadata"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))

    local response = rawget(assert(assert(run:result()).error), "response")
    ---@cast response {body: string}
    assert.are.equal("private provider response", response.body)
    local completion = agent:snapshot().result
    assert.are.equal("failed", assert(completion).status)
    assert.are.equal(1, assert(completion).message_count)
    assert.are.equal("error", assert(completion).stop_reason)
    assert.are.equal(513, vim.fn.strchars(assert(assert(completion).error).message))
    local detail = assert(assert(completion).error).detail
    assert(type(detail) == "string")
    assert.are.equal(1024, vim.fn.strchars(detail))
    assert.are.equal("overloaded", rawget(assert(assert(completion).error), "code"))
    assert.are.equal(503, rawget(assert(assert(completion).error), "status"))
    assert.is_false(rawget(assert(assert(completion).error), "retryable"))
    assert.is_nil(rawget(assert(assert(completion).error), "response"))
    assert.is_nil(rawget(assert(completion), "session"))
  end)

  it("normalizes scalar completion details without retaining owners", function()
    local failed = model_failure(fake_model.assistant({}, "error"), {
      kind = "provider",
      message = "failed",
      detail = 42,
    })
    local agent = setup_model(fake_model.new({ { result = failed } }), {
      retry = { enabled = false },
    })

    local run = assert(agent:send("retain a scalar detail"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal("42", assert(assert(agent:snapshot().result).error).detail)
  end)

  it("uses returned Run results instead of synchronous completion callbacks", function()
    ---@type Neoagent.ChatRun?
    local returned
    ---@type Neoagent.TestControlledInteraction?
    local captured
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        captured = options
        assert(options.on_done)({
          ok = false,
          error = { kind = "interaction", message = "stale callback" },
        })
        returned = completed_run(options, { ok = true, new_messages = {}, session = options.session, message = fake_model.assistant({}).message })
        return returned
      end,
    })
    local accepted = 0
    local unsubscribe = agent:subscribe(function(update)
      if update.type == "submission_accepted" then
        accepted = accepted + 1
      end
    end)

    local outer = assert(agent:send("complete synchronously"))
    assert(type(outer) == "table")
    assert(vim.wait(1000, function() return returned ~= nil end))
    assert.are_not.equal(returned, outer)
    assert(vim.wait(1000, function()
      return outer:is_done() and not agent:is_running()
    end))

    assert.is_true(assert(returned):is_done())
    assert.are.equal("succeeded", assert(agent:snapshot().result).status)
    assert(assert(captured).on_event)({ type = "provider_status", text = "late" })
    assert(assert(captured).on_done)({
      ok = false, error = { kind = "interaction", message = "late" },
    })
    accept_entry(assert(captured), "late-entry")
    vim.wait(20)
    assert.is_false(agent:snapshot().context.provider_status)
    assert.are.equal("succeeded", assert(agent:snapshot().result).status)
    assert.are.equal(0, accepted)
    assert.are.equal(0, #agent:get_session():entries())
    unsubscribe()
  end)

  it("stops acceptance when a publication destroys the Agent", function()
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        accept_entry(options, "accepted-before-destroy")
        return completed_run(options, {
          ok = true,
          new_messages = {},
          session = options.session,
          message = fake_model.assistant({}).message,
        })
      end,
    })
    local submissions = 0
    local destroyed_from_messages = false
    local unsubscribe = agent:subscribe(function(update)
      if update.type == "messages" and not destroyed_from_messages then
        destroyed_from_messages = true
        agent:destroy()
      elseif update.type == "submission_accepted" then
        submissions = submissions + 1
      end
    end)

    local run = assert(agent:send("destroy during acceptance"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))

    assert.is_true(destroyed_from_messages)
    assert.is_true(agent:is_destroyed())
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
    assert.are.equal(0, submissions)
    unsubscribe()
  end)

  it("contains completion metadata projection failures", function()
    local result = setmetatable({ ok = true, new_messages = {} }, {
      __index = function(_, key)
        if key == "usage" then error("completion usage failed") end
        return nil
      end,
    })
    ---@cast result Neoagent.ChatResult
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        return require("neoagent.async").run(function()
          return result
        end, {
          on_event = options.on_event,
          on_done = options.on_done,
          error_kind = "interaction",
        })
      end,
    })

    local run = assert(agent:send("project hostile metadata"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal("failed", assert(agent:snapshot().result).status)
    assert.matches("completion usage failed",
      assert(assert(agent:snapshot().result).error).message)
  end)

  it("reports completion publication failures without losing cleanup", function()
    ---@type Neoagent.TestControlledInteraction?
    local options
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(value)
        options = value
        return controlled_run(value)
      end,
    })
    local run = assert(agent:send("finish with a broken projection"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return options ~= nil end))
    local unsubscribe = agent:subscribe(function()
      error("completion listener failed")
    end)
    local presenter = agent:presenter()
    local notify = presenter.notify
    presenter.notify = function()
      error("completion notification failed")
    end
    assert(assert(options).complete)({ ok = true, new_messages = {}, session = assert(options).session, message = fake_model.assistant({}).message })
    assert(vim.wait(1000, function() return run:is_done() end))
    presenter.notify = notify
    unsubscribe()
    assert(vim.wait(1000, function() return not agent:is_running() end))
    assert.is_true(assert(run:result()).ok)
  end)

  it("rejects blank prompts without acquiring provider ownership", function()
    local service = {
      id = "fake", name = "Fake", state = function() return false end,
      operations = {},
    }
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      service, function(value) users[#users + 1] = value.users end)
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "recovered" } }),
    } })
    local agent = setup_model(model, {
      providers = { fake = {
        api = "fake-api", models = { test = {} },
        service = function() return service end,
      } },
    })
    assert.is_nil(agent:send(" \n "))
    assert.are.equal(0, #model.requests)
    assert.is_false(agent:is_running())
    assert.are.same({}, users)
    unsubscribe()
  end)

  it("cancels a child when interaction installation or its parent is lost", function()
    local child_cancelled = false
    ---@type Neoagent.Agent?
    local agent
    agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        local child = controlled_run(options, function()
          child_cancelled = true
        end)
        assert.is_true(assert(agent):stop())
        return child
      end,
    })
    local run = assert(agent:send("cancel during launch"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.is_true(child_cancelled)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)

    local original_messages
    agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        local child = controlled_run(options, function()
          child_cancelled = true
        end)
        local session = agent:get_session()
        original_messages = session.messages
        session.messages = function() error("transcript installation failed") end
        return child
      end,
    })
    child_cancelled = false
    run = assert(agent:send("fail child installation"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    agent:get_session().messages = original_messages
    assert.is_true(child_cancelled)
    assert.matches("transcript installation failed", assert(assert(run:result()).error).message)
  end)

  it("reports failed provider release after an accepted submission", function()
    local service = {
      id = "fake", name = "Fake", state = function() return false end,
      operations = {},
    }
    local provider_service = require("neoagent.provider_service")
    local acquire_use = provider_service.acquire_use
    provider_service.acquire_use = function(selected)
      local lease, err = acquire_use(selected)
      if not lease then return nil, err end
      return {
        release = function()
          lease:release()
          return nil, require("neoagent.util").error(
            "provider", "release confirmation failed")
        end,
      }
    end
    ---@type Neoagent.AgentPublication?
    local accepted
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local agent = setup_model(fake_model.new({}), {
      providers = { fake = {
        api = "fake-api", models = { test = {} },
        service = function() return service end,
      } },
      _interaction = function(options)
        accept_entry(options, "entry-1")
        return completed_run(options, { ok = true, new_messages = {}, session = options.session, message = fake_model.assistant({}).message })
      end,
    })
    agent:subscribe(function(update)
      if update.type == "submission_accepted" then accepted = update end
    end)
    local run = assert(agent:send("accept safely"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    provider_service.acquire_use = acquire_use
    vim.notify = original_notify

    assert.is_not_nil(accepted)
    assert.are.equal("entry-1", assert(accepted).entry_id)
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(item)
      return item.message:find("release confirmation failed", 1, true) ~= nil
    end, notifications), true))
  end)

  it("reports busy manual lifecycle operations", function()
    ---@type Neoagent.TestControlledInteraction?
    local options
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(value)
        options = value
        return controlled_run(value)
      end,
    })
    local run = assert(agent:send("remain active"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return options ~= nil end))
    local compacted = agent:compact("not yet")
    assert.is_nil(compacted)
    local steered, steer_err = agent:steer(" \n ")
    assert.is_nil(steered)
    assert.matches("must contain content", assert(steer_err).message)
    local resumed, err = agent:resubmit_steering(1)
    assert.is_nil(resumed)
    assert.are.equal("steering", assert(err).kind)
    assert.matches("busy", assert(err).message)
    assert(assert(options).complete)({ ok = true, new_messages = {}, session = assert(options).session, message = fake_model.assistant({}).message })
    assert(vim.wait(1000, function() return run:is_done() end))
    resumed, err = agent:resubmit_steering(1)
    assert.is_nil(resumed)
    assert.matches("unavailable", assert(err).message)
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return compaction_started end))
    assert.is_true(agent:stop())
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))

    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
    assert.are.equal(0, #model.requests)
    assert.are.equal(before, #agent:get_session():messages())
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
  end)

  it("honors cancellation published by completed preflight compaction", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "unused" } }),
    } })
    model.context_window = 100
    local agent = setup_model(model, {
      compaction = {
        auto = true, reserve_tokens = 20, keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        return completed_run(options, {
          ok = true,
          summary = "checkpoint before cancellation",
          first_kept_entry_id = options.preparation.first_kept_entry_id,
          tokens_before = options.preparation.tokens_before,
        })
      end,
    })
    local session = agent:get_session()
    assert(session:append({
      role = "user", content = string.rep("old ", 30),
    }))
    assert(session:append({
      role = "assistant",
      content = { { type = "text", text = string.rep("work ", 30) } },
      stopReason = "stop",
      usage = { totalTokens = 90 },
    }))
    local cancelled = false
    local unsubscribe = agent:subscribe(function(update)
      local event = update.type == "event" and update.event or nil
      if event
        and event.type == "compaction_end"
        and event.result.ok
      then
        cancelled = agent:stop()
      end
    end)

    local run = assert(agent:send("do not accept after cancellation"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))

    assert.is_true(cancelled)
    assert.are.equal(0, #model.requests)
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))

    assert.is_false(assert(run:result()).ok)
    assert.matches("continuation launch failed", assert(assert(run:result()).error).message)
    assert.are.equal("failed", assert(agent:snapshot().result).status)
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return started end))

    agent:destroy()

    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
  end)

  it("continues after stopping a tool and manually compacting its turn", function()
    local async = require("neoagent.async")
    local entered, executions = false, 0
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "Earlier response" } }) },
      { result = fake_model.assistant({ {
        type = "toolCall", id = "interrupted", name = "pending", arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "Continued" } }) },
    })
    model.context_window = 1000
    ---@async
    local function execute_pending()
      entered, executions = true, executions + 1
      return async.await(function() return function() end end)
    end
    local agent = setup_model(model, {
      compaction = { auto = false, reserve_tokens = 200, keep_recent_tokens = 1 },
      tools = { {
        name = "pending", description = "Wait", input_schema = { type = "object" },
        execute = execute_pending,
      } },
      _compaction_run = function(options)
        return completed_run(options, {
          ok = true, summary = "Earlier work",
          first_kept_entry_id = options.preparation.first_kept_entry_id,
          tokens_before = options.preparation.tokens_before,
        })
      end,
    })
    local earlier = assert(agent:send("Earlier task"))
    assert(type(earlier) == "table")
    assert(vim.wait(1000, function() return earlier:is_done() end))
    local interrupted = assert(agent:send("Start a tool"))
    assert(type(interrupted) == "table")
    assert(vim.wait(1000, function() return entered end))
    assert.is_true(agent:stop())
    assert(vim.wait(1000, function() return interrupted:is_done() and not agent:is_running() end))
    assert.are.equal("cancelled", assert(assert(interrupted:result()).error).kind)
    local session = agent:get_session()
    local append = session.append
    ---@param message unknown
    ---@param state? Neoagent.RequestStateInput
    function session:append(message, state)
      if type(message) == "table" and message.role == "toolResult" then
        return nil, require("neoagent.util").error(
          "storage", "interrupted result unavailable")
      end
      return append(self, message, state)
    end
    local compacted, compact_err = agent:compact()
    assert.is_nil(compacted)
    assert.matches("interrupted result unavailable", assert(compact_err).message)
    session.append = append

    local path = session.path
    session.path = function()
      return nil, require("neoagent.util").error(
        "storage", "compaction path unavailable")
    end
    compacted, compact_err = agent:compact()
    assert.is_nil(compacted)
    assert.matches("compaction path unavailable", assert(compact_err).message)
    session.path = path

    compacted = assert(agent:compact())
    assert(type(compacted) == "table")
    assert(vim.wait(1000, function() return compacted:is_done() and not agent:is_running() end))
    assert.is_true(assert(compacted:result()).ok)
    local resumed, err = agent:send("Continue")
    assert.is_nil(err)
    assert(type(resumed) == "table")
    assert(vim.wait(1000, function() return assert(resumed):is_done() end))
    assert.is_true(assert(assert(resumed):result()).ok)
    assert.are.equal(3, #model.requests)
    assert.are.equal(1, executions)
    local results = vim.tbl_filter(function(message)
      return message.role == "toolResult" and message.toolCallId == "interrupted"
    end, session:messages())
    assert.are.equal(1, #results)
    assert.is_true(assert(results[1]).isError)
  end)

  it("rejects new work after destruction with shared provider runtimes", function()
    local executions = 0
    local model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "destroyed-call", name = "effect", arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "Done" } }) },
    })
    local options = model_options(model, { tools = { {
      name = "effect", description = "Execute", input_schema = { type = "object" },
      execute = function()
        executions = executions + 1
        return { content = { { type = "text", text = "Executed" } } }
      end,
    } } })
    local runtimes = { fake = provider_runtime("fake", configured_provider(options, "fake")) }
    local session = assert(require("neoagent.session").new())
    local agent = neoagent.new(options, { session = session, runtimes = runtimes })
    neoagent._set_default(agent)
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      runtimes.fake.service, function(value) users[#users + 1] = value.users end)
    local sibling
    local ok, failure = pcall(function()
      assert(agent:prepare())
      agent:destroy()
      for _, call in ipairs({
        function() return agent:send("Execute after destruction") end,
        function() return agent:compact() end,
        function() return agent:steer("Steer after destruction") end,
        function() return agent:resubmit_steering(1) end,
      }) do
        local run, err = call()
        if type(run) == "table" and run.is_done then
          assert(vim.wait(1000, function() return run:is_done() end))
        end
        assert.is_nil(run)
        assert.are.equal("Agent is destroyed", assert(err).message)
      end
      assert.are.equal(0, #model.requests)
      assert.are.equal(0, executions)
      assert.are.same({}, session:messages())
      assert.are.same({}, users)
      sibling = neoagent.new(options, { runtimes = runtimes })
      local run = assert(sibling:send("Execute on the live Agent"))
      assert(type(run) == "table")
      assert(vim.wait(1000, function() return run:is_done() end))
      assert.is_true(assert(run:result()).ok)
      assert.are.equal(1, executions)
      assert.are.same({ 1, 0 }, users)
      assert.are.same({}, session:messages())
    end)
    if sibling then sibling:destroy() end
    agent:destroy()
    unsubscribe()
    require("neoagent.provider_runtimes").destroy(runtimes)
    assert(ok, failure)
  end)

  it("rejects a submission destroyed by its prompt preparation callback", function()
    ---@type Neoagent.Agent?
    local agent
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "Must not run" } }),
    } })
    local options = model_options(model, {
      system_prompt = function()
        assert(agent):destroy()
        return "Destroyed during preparation"
      end,
    })
    local runtimes = { fake = provider_runtime("fake", configured_provider(options, "fake")) }
    agent = neoagent.new(options, { runtimes = runtimes })
    neoagent._set_default(agent)
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      runtimes.fake.service, function(value) users[#users + 1] = value.users end)
    local ok, failure = pcall(function()
      local run, err = agent:send("Prepare a request")
      if type(run) == "table" then assert(vim.wait(1000, function() return run:is_done() end)) end
      assert.is_nil(run)
      assert.are.equal("Agent is destroyed", assert(err).message)
      assert.are.same({}, agent:get_session():messages())
      assert.are.equal(0, #model.requests)
      assert.are.same({ 1, 0 }, users)
    end)
    agent:destroy()
    unsubscribe()
    require("neoagent.provider_runtimes").destroy(runtimes)
    assert(ok, failure)
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
    assert(type(run) == "table")
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
    assert(type(run) == "table")
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
    local ok = pcall(function() assert(neoagent.default()):snapshot() end)
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
    assert(type(run) == "table")
    assert.is_true((neoagent.send("steer one")))
    assert.is_true(neoagent.steer("steer two"))
    assert.are.same({ "steer one", "steer two" },
      assert(neoagent.default()):snapshot().context.steering)
    assert(vim.wait(1000, function() return run:is_done() end))
    local messages = current_session():messages()
    assert.are.same({ "user", "assistant", "user", "assistant", "user", "assistant" },
      vim.tbl_map(function(message) return message.role end, messages))
    assert.are.equal("steer one", assert(assert(model.requests[2]).messages[3]).content)
    assert.are.equal("steer two", assert(assert(model.requests[3]).messages[5]).content)
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
    ---@type Neoagent.AwaitCallbacks<Neoagent.ModelResult>?
    local pending
    local model = {
      input = { "text" },
      api = "fake",
      provider = "fake",
      id = "test",
      requests = {},
    }
    ---@param opts Neoagent.StreamOptions
    ---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
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
    assert(type(first) == "table")
    assert(vim.wait(1000, function() return pending ~= nil end, 5))
    local view = current_view()
    view:set_input("B")
    assert.is_true((neoagent.send("B")))
    assert.are.equal("", view:get_input())
    assert(assert(pending)).resolve({
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
        current_session():messages()))
  end)

  it("tracks model context usage, provider status, and inference speed", function()
    local assistant = fake_model.assistant({ { type = "text", text = "done" } })
    assert(assistant.message.usage).totalTokens = nil
    assert(assistant.message.usage).input = 200
    assert(assistant.message.usage).output = 50
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
    assert(type(run) == "table")
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
        and assert(update.context).state == "running"
        and assert(update.context).inference_stats or nil
      if type(stats) == "table"
          and not vim.deep_equal(observed[#observed], stats) then
        observed[#observed + 1] = vim.deepcopy(stats)
      end
    end)

    local run = assert(neoagent.send("measure"))
    assert(type(run) == "table")
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
    local session = current_session()
    local context_messages = assert(session).context_messages
    local context_reads = 0
    function session:context_messages()
      context_reads = context_reads + 1
      return context_messages(self)
    end
    local reads = {}
    agent:subscribe(function(update)
      local stats = update.type == "context"
        and assert(update.context).inference_stats or nil
      local rate = type(stats) == "table"
        and stats.generation_tokens_per_second or nil
      if rate and (not reads[#reads] or reads[#reads].rate ~= rate) then
        reads[#reads + 1] = { rate = rate, count = context_reads }
      end
    end)

    local run = assert(neoagent.send("measure"))
    assert(type(run) == "table")
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
        elapsed_ms = 2000,
      } },
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } })
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("measure"))
    assert(type(run) == "table")
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))

    local messages = assert(current_session():context_messages())
    local estimated = 0
    for _, message in ipairs(messages) do
      estimated = estimated + require("neoagent.compaction").estimate_tokens(message)
    end
    assert.are.equal(estimated, assert(current_view().context.context_usage).used)
    assert.is_true(estimated > 0)
  end)

  it("automatically compacts large contexts and persists the checkpoint", function()
    local assistant = fake_model.assistant({ { type = "text", text = string.rep("work ", 30) } })
    assert(assistant.message.usage).totalTokens = 900
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))
    local entries = current_session():entries()
    assert.are.equal("compaction", entries[#entries].type)
    local checkpoint = entries[#entries]
    assert(checkpoint.type == "compaction")
    assert(type(checkpoint.summary) == "string")
    assert.matches("Turn Context %(split turn%):.-## Goal\nContinue the work", checkpoint.summary)
    assert.are.equal(900, entries[#entries].tokens_before)
    assert.matches("context summarization assistant", (assert(assert(model.requests[2]).system_prompt)))
    local context = assert(current_session():context_messages())
    assert.matches("Continue the work", (assert(assert(assert(context[1]).content[1]).text)))
    local estimated = 0
    for _, message in ipairs(context) do
      estimated = estimated + require("neoagent.compaction").estimate_tokens(message)
    end
    assert.are.equal(estimated, assert(current_view().context.context_usage).used)
    assert.is_true(estimated < entries[#entries].tokens_before)
    local transcript = table.concat(vim.api.nvim_buf_get_lines(
      (assert(view_handles.buffer(current_view(), "transcript"))), 0, -1, false), "\n")
    assert.matches("Compacted from 900 tokens", transcript)
    assert.matches("Continue the work", transcript)
    local retained = assert((transcript:find("work work work", 1, true)))
    local compaction_card = assert((transcript:find("Compacted from 900 tokens", 1, true)))
    assert.is_true(compaction_card < retained)
    assert.are.equal("perform the large task", assert(current_session():messages()[1]).content)
    assert.is_not.matches("perform the large task", transcript)
    assert.is_false(current_view().context.provider_status)
  end)

  it("continues a length-limited turn after automatic compaction", function()
    local truncated = fake_model.assistant({ {
      type = "thinking", thinking = "Updating review status for SSE progress",
    } }, "length")
    assert(truncated.message.usage).totalTokens = 900
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
    assert(type(run) == "table")
    assert(vim.wait(2000, function()
      return run:is_done() and is_idle() and #model.requests == 4
    end))
    local messages = current_session():messages()
    local length_messages = vim.tbl_filter(function(message)
      return message.role == "assistant" and message.stopReason == "length"
    end, messages)
    assert.are.equal(1, #length_messages)
    assert.are.equal("Finished after compaction",
      assert(assert(messages[#messages].content)[1]).text)
    local entries = current_session():entries()
    assert.are.equal("compaction", assert(entries[#entries - 1]).type)
    assert.matches("context summarization assistant",
      (assert(assert(model.requests[3]).system_prompt)))
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))
    assert.is_true(assert(snapshot().result).ok)
    assert.are.equal("length", assert(snapshot().result).stop_reason)
    assert.are.equal(3, #current_session():messages())
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))
    assert.matches("context summarization assistant", (assert(assert(model.requests[1]).system_prompt)))
    assert.are.equal("new question", assert(assert(model.requests[2]).messages[#assert(model.requests[2]).messages]).content)
    assert.are.equal("compaction", assert(current_session():entries()[#current_session():entries() - 2]).type)
  end)

  it("surfaces context projection failures before starting a request", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "unused" } }),
    } })
    model.context_window = 100
    local agent = setup_model(model, {
      compaction = {
        auto = true, reserve_tokens = 20, keep_recent_tokens = 5,
      },
    })
    local session = agent:get_session()
    local context_messages = session.context_messages
    session.context_messages = function()
      return nil, require("neoagent.util").error(
        "storage", "context projection unavailable")
    end

    local run = assert(agent:send("do not start the request"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    session.context_messages = context_messages

    assert.are.equal(0, #model.requests)
    assert.is_false(assert(run:result()).ok)
    assert.matches("context projection unavailable",
      assert(assert(run:result()).error).message)
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
    local overflow = model_failure(fake_model.assistant({}, "error"), {
      kind = "model",
      message = "request failed",
      detail = { message = "the request exceeds the available context size" },
    })
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 3
    end))
    local messages = current_session():messages()
    assert.are.equal("recovered", assert(assert(messages[#messages].content)[1]).text)
    assert.are.equal(2, vim.tbl_count(vim.tbl_filter(function(message)
      return message.role == "user"
    end, messages)))
    assert.are.equal("compaction", assert(current_session():entries()[#current_session():entries() - 1]).type)
  end)

  it("keeps a context-overflow result when compaction is disabled", function()
    local overflow = model_failure(fake_model.assistant({}, "error"), {
      kind = "model",
      message = "maximum context length exceeded",
    })
    local model = fake_model.new({ { result = overflow } })
    setup_model(model, { compaction = false })

    local run = assert(neoagent.send("retain the provider failure"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle()
    end))

    assert.are.equal(1, #model.requests)
    assert.is_false(assert(run:result()).ok)
    assert.are.equal(overflow.error.message,
      assert(assert(run:result()).error).message)
  end)

  it("propagates cancellation from context-overflow recovery", function()
    local overflow = model_failure(fake_model.assistant({}, "error"), {
      kind = "model",
      message = "the request exceeds the available context size",
    })
    local model = fake_model.new({ { result = overflow } })
    model.context_window = 100
    local agent = setup_model(model, {
      compaction = {
        auto = false, reserve_tokens = 20, keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        return completed_run(options, {
          ok = false,
          error = { kind = "cancelled", message = "compaction cancelled" },
        })
      end,
    })
    local session = agent:get_session()
    assert(session:append({
      role = "user", content = string.rep("old ", 30),
    }))
    assert(session:append({
      role = "assistant",
      content = { { type = "text", text = string.rep("work ", 30) } },
      stopReason = "stop",
    }))

    local run = assert(agent:send("overflow"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
    assert.are.equal(1, #model.requests)
  end)

  it("keeps the provider failure when overflow compaction fails", function()
    local overflow = model_failure(fake_model.assistant({}, "error"), {
      kind = "model",
      message = "the request exceeds the available context size",
    })
    local model = fake_model.new({ { result = overflow } })
    model.context_window = 100
    local agent = setup_model(model, {
      compaction = {
        auto = false, reserve_tokens = 20, keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        return completed_run(options, {
          ok = false,
          error = { kind = "compaction", message = "summary failed" },
        })
      end,
    })
    local session = agent:get_session()
    assert(session:append({ role = "user", content = string.rep("old ", 30) }))
    assert(session:append({
      role = "assistant",
      content = { { type = "text", text = string.rep("work ", 30) } },
      stopReason = "stop",
    }))

    local run = assert(agent:send("overflow"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal(overflow.error.message, assert(assert(run:result()).error).message)
    assert.are.equal(1, #model.requests)
  end)

  it("keeps a length result when threshold compaction fails", function()
    local limited = fake_model.assistant({ {
      type = "text", text = string.rep("partial ", 20),
    } }, "length")
    assert(limited.message.usage).totalTokens = 90
    local model = fake_model.new({ { result = limited } })
    model.context_window = 100
    local compactions = 0
    local agent = setup_model(model, {
      compaction = {
        auto = true, reserve_tokens = 20, keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        compactions = compactions + 1
        return completed_run(options, {
          ok = false,
          error = { kind = "compaction", message = "summary unavailable" },
        })
      end,
    })

    local run = assert(agent:send("fill the context"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal("length", assert(assert(run:result()).message).stopReason)
    assert.are.equal(1, compactions)
  end)

  it("returns cancelled length-recovery compaction", function()
    local limited = fake_model.assistant({ {
      type = "text", text = string.rep("partial ", 20),
    } }, "length")
    assert(limited.message.usage).totalTokens = 90
    local model = fake_model.new({ { result = limited } })
    model.context_window = 100
    local agent = setup_model(model, {
      compaction = {
        auto = true, reserve_tokens = 20, keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        return completed_run(options, {
          ok = false,
          error = { kind = "cancelled", message = "stop compacting" },
        })
      end,
    })

    local run = assert(agent:send("fill then cancel"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
  end)

  it("returns cancelled post-turn compaction", function()
    local complete = fake_model.assistant({ {
      type = "text", text = string.rep("answer ", 20),
    } })
    assert(complete.message.usage).totalTokens = 90
    local model = fake_model.new({ { result = complete } })
    model.context_window = 100
    local agent = setup_model(model, {
      compaction = {
        auto = true, reserve_tokens = 20, keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        return completed_run(options, {
          ok = false,
          error = { kind = "cancelled", message = "stop compacting" },
        })
      end,
    })

    local run = assert(agent:send("finish then compact"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
  end)

  it("cleans up when overflow recovery cannot reset the failed branch", function()
    local overflow = model_failure(fake_model.assistant({ {
      type = "thinking", thinking = "partial overflow",
    } }, "error"), {
      kind = "model",
      message = "request failed",
      detail = { message = "the request exceeds the available context size" },
    })
    local model = fake_model.new({
      { result = overflow },
      { result = fake_model.assistant({ { type = "text", text = "next answer" } }) },
    })
    model.context_window = 100
    setup_model(model, {
      compaction = { auto = false, reserve_tokens = 20, keep_recent_tokens = 10 },
    })
    local session = current_session()
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    local result = snapshot().result
    assert.is_false(assert(result).ok)
    assert.are.equal("agent", assert(assert(result).error).kind)
    assert.matches("completion", assert(assert(result).error).message)
    assert.are.equal("leaf unavailable", assert(assert(result).error).detail)

    local next_run = assert(neoagent.send("try a new turn"))
    assert(type(next_run) == "table")
    assert(vim.wait(1000, function() return next_run:is_done() and is_idle() end))
    assert.are.equal("next answer",
      assert(assert(assert(current_session():messages()[#current_session():messages()]).content)[1]).text)
  end)

  it("replays retryable partial turns without retaining the failed branch", function()
    local failed = model_failure(fake_model.assistant({ { type = "thinking", thinking = "partial" } }, "error"), {
      kind = "model",
      message = "upstream disconnected",
      retryable = true,
      stream_max_retries = 5,
      retry_after_ms = 1,
    })
    local model = fake_model.new({
      { events = { { type = "thinking_delta", text = "partial" } }, result = failed },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    setup_model(model)
    assert(neoagent.open())
    local run = assert(neoagent.send("retry this"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    local messages = current_session():messages()
    assert.are.equal(2, #messages)
    assert.are.equal("retry this", assert(messages[1]).content)
    assert.are.equal("recovered", assert(assert(assert(messages[2]).content)[1]).text)
    assert.is_true(assert(snapshot().result).ok)
    assert.is_false(snapshot().context.provider_status)
  end)

  it("retries a transport failure with a projection-only Session store", function()
    ---@type Neoagent.Message[]
    local committed = {}
    ---@type Neoagent.SessionStorage
    local store = {
      load = function() return vim.deepcopy(committed) end,
      append = function(_, message)
        committed[#committed + 1] = vim.deepcopy(message)
        return true, nil, nil, { type = "append", messages = { vim.deepcopy(message) } }
      end,
    }
    local session = assert(require("neoagent.session").new({ store = store }))
    local model = fake_model.new({
      { result = { ok = false, error = {
        kind = "transport", message = "connection reset", retryable = true,
      } } },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local options = model_options(model, {
      compaction = false,
      retry = { enabled = true, max_retries = 1, base_delay_ms = 1 },
    })
    local agent = neoagent.new(options, { session = session })
    neoagent._set_default(agent)
    local accepted = 0
    agent:subscribe(function(update)
      if update.type == "submission_accepted" then accepted = accepted + 1 end
    end)

    local run = assert(agent:send("retry this"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and not agent:is_running() end))
    local result = assert(run:result())
    assert.is_true(result.ok, vim.inspect(result))
    assert.are.equal(2, #model.requests)
    assert.are.same(assert(model.requests[1]).messages, assert(model.requests[2]).messages)
    assert.are.equal(1, #assert(model.requests[2]).messages)
    assert.are.equal(1, accepted)
    local messages = session:messages()
    assert.are.same(committed, messages)
    assert.are.equal(2, #messages)
    assert.are.equal("retry this", assert(messages[1]).content)
    assert.are.equal("recovered", assert(assert(assert(messages[2]).content)[1]).text)
  end)

  it("retries a failed response at the root of a Session", function()
    local failed = model_failure(fake_model.assistant({ { type = "thinking", thinking = "partial" } }, "error"), {
      kind = "model", message = "upstream disconnected",
      retryable = true, retry_after_ms = 1,
    })
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    local agent = setup_model(model, {
      _interaction = function(options)
        assert(options.session:append(failed.message))
        return completed_run(options, { ok = false, error = failed.error, message = failed.message, session = options.session })
      end,
    })
    local run = assert(agent:send("continue"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and not agent:is_running() end))
    assert.is_true(assert(run:result()).ok, vim.inspect(run:result()))
    assert.are.equal(1, #model.requests)
    assert.are.same({}, assert(model.requests[1]).messages)
    local session = current_session()
    assert.are.equal("recovered", assert(assert(assert(assert(session):messages()[1]).content)[1]).text)
    assert.are.equal(1, #assert(session):messages())
    assert.are.equal("error", assert(assert(assert(session):entries()[1]).message).stopReason)
  end)

  it("cleans up when retry replay cannot reset the failed branch", function()
    local failed = model_failure(fake_model.assistant({ {
      type = "thinking", thinking = "partial retry",
    } }, "error"), {
      kind = "transport",
      message = "upstream disconnected",
      retryable = true,
      retry_after_ms = 1,
    })
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "next answer" } }) },
    })
    local stream = model.stream
    local first_request = true
    ---@type Neoagent.AwaitCallbacks<Neoagent.ModelResult>?
    local pending
    ---@param options Neoagent.StreamOptions
    function model:stream(options)
      if not first_request then
        return stream(self, options)
      end
      first_request = false
      self.requests[#self.requests + 1] = require("neoagent.util").copy(options)
      return require("neoagent.async").run(function()
        return require("neoagent.async").await(function(done)
          pending = done
        end)
      end, {
        on_event = options.on_event,
        on_done = options.on_done,
        error_kind = "model",
      })
    end
    local agent = setup_model(model)
    local session = agent:get_session()
    local path = session.path

    local run = assert(neoagent.send("retry this"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return pending ~= nil end))
    session.path = function()
      return nil, require("neoagent.util").error("storage", "journal unavailable")
    end
    assert(pending).resolve(failed)
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    session.path = path
    local result = snapshot().result
    assert.is_false(assert(result).ok)
    assert.are.equal("agent", assert(assert(result).error).kind)
    assert.are.equal("journal unavailable", assert(assert(result).error).detail)
    local next_run = assert(neoagent.send("try a new turn"))
    assert(type(next_run) == "table")
    assert(vim.wait(1000, function() return next_run:is_done() and is_idle() end))
    assert.are.equal("next answer",
      assert(assert(assert(current_session():messages()[#current_session():messages()]).content)[1]).text)
  end)

  it("retries interrupted transports without provider-specific error metadata", function()
    local failed = model_failure(fake_model.assistant({ { type = "text", text = "partial" } }, "error"), {
      kind = "transport",
      message = "curl exited with status 18: curl: (18) transfer closed with outstanding read data remaining",
      exit_code = 18,
    })
    local model = fake_model.new({
      { events = { { type = "text_delta", text = "partial" } }, result = failed },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    setup_model(model, {
      retry = { enabled = true, max_retries = 3, base_delay_ms = 1 },
    })
    assert(neoagent.open())
    local run = assert(neoagent.send("retry this"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    local messages = current_session():messages()
    assert.are.equal(2, #messages)
    assert.are.equal("retry this", assert(messages[1]).content)
    assert.are.equal("recovered", assert(assert(assert(messages[2]).content)[1]).text)
    assert.is_true(assert(snapshot().result).ok)
  end)

  it("retries premature protocol stream endings", function()
    local failed = model_failure(fake_model.assistant({}, "error"), {
      kind = "protocol",
      message = "Request failed",
      detail = { reason = "stream ended before the terminal event" },
    })
    local model = fake_model.new({
      { result = failed },
      { result = fake_model.assistant({ { type = "text", text = "recovered" } }) },
    })
    setup_model(model, {
      retry = { enabled = true, max_retries = 1, base_delay_ms = 1 },
    })
    local run = assert(neoagent.send("retry truncated stream"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    assert.is_true(assert(snapshot().result).ok)
  end)

  it("retries provider timeouts reported with terminal HTTP statuses", function()
    local failed = model_failure(fake_model.assistant({}, "error"), {
      kind = "transport",
      message = "HTTP 400: Download multimodal file timed out",
      response = { status = 400 },
    })
    local model = fake_model.new({
      { result = failed },
      { result = fake_model.assistant({
        { type = "text", text = "recovered" },
      }) },
    })
    setup_model(model, {
      retry = { enabled = true, max_retries = 1, base_delay_ms = 1 },
    })
    local run = assert(neoagent.send("retry provider timeout"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    assert.are.equal(2, #model.requests)
    assert.is_true(assert(snapshot().result).ok)
  end)

  it("bounds automatic retries with the configured retry budget", function()
    local function interrupted()
      local failed = model_failure(fake_model.assistant({}, "error"), { kind = "transport", message = "connection refused" })
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle() and #model.requests == 2
    end))

    assert.are.equal(2, #model.requests)
    assert.is_false(assert(snapshot().result).ok)
  end)

  it("contains retry timer allocation failure", function()
    local failed = model_failure(fake_model.assistant({}, "error"), {
      kind = "transport",
      message = "HTTP 503: overloaded",
      retryable = true,
      retry_after_ms = 1,
    })
    local agent = setup_model(fake_model.new({ { result = failed } }), {
      retry = { enabled = true, max_retries = 1, base_delay_ms = 1 },
    })
    local new_timer = vim.uv.new_timer
    vim.uv.new_timer = function()
      local caller = debug.getinfo(2, "S")
      if caller and caller.source:match("agent/run_lifecycle.lua$") then
        return nil
      end
      return new_timer()
    end
    ---@type Neoagent.AgentRun?
    local run
    local sent, send_err = pcall(function()
      local sent_run = assert(agent:send("retry without a timer"))
      assert(type(sent_run) == "table")
      run = sent_run
    end)
    local completed = sent and vim.wait(1000, function()
      return assert(run):is_done() and not agent:is_running()
    end)
    vim.uv.new_timer = new_timer
    assert(sent, send_err)
    assert(completed)

    assert.is_false(assert(assert(run):result()).ok)
    assert.matches("Failed to create retry timer", assert(assert(assert(run):result()).error).message)
  end)

  it("does not retry terminal HTTP transport failures", function()
    local failed = model_failure(fake_model.assistant({}, "error"), {
      kind = "transport",
      message = "HTTP 401: invalid API key",
      response = { status = 401 },
    })
    local model = fake_model.new({
      { result = failed },
      { result = fake_model.assistant({ { type = "text", text = "unexpected" } }) },
    })
    setup_model(model, {
      retry = { enabled = true, max_retries = 3, base_delay_ms = 1 },
    })
    local run = assert(neoagent.send("do not retry"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle()
    end))

    assert.are.equal(1, #model.requests)
    assert.is_false(assert(snapshot().result).ok)
  end)

  it("classifies cancellation, billing, transport, and rate-limit failures", function()
    ---@param kind string
    ---@param message string
    ---@param extra? table<string, unknown>
    ---@return Neoagent.ModelFailure
    local function failure(kind, message, extra)
      local err = vim.tbl_extend("force", { kind = kind, message = message }, extra or {})
      ---@cast err Neoagent.Error
      return model_failure(
        fake_model.assistant({}, "error"),
        err
      )
    end
    local model = fake_model.new({
      { result = failure("cancelled", "provider request cancelled") },
      { result = failure("provider", "billing account unavailable") },
      { result = failure("transport", "remote channel vanished") },
      { result = fake_model.assistant({ { type = "text", text = "reconnected" } }) },
      { result = failure("provider", "rate limit: too many tokens", {
        retryable = false,
      }) },
    })
    local compactions = 0
    local agent = setup_model(model, {
      retry = { enabled = true, max_retries = 1, base_delay_ms = 1 },
      compaction = {
        auto = false,
        reserve_tokens = 20,
        keep_recent_tokens = 5,
      },
      _compaction_run = function()
        compactions = compactions + 1
        error("rate limits must not trigger compaction")
      end,
    })

    ---@param prompt string
    ---@param expected_requests integer
    ---@return Neoagent.ChatResult|Neoagent.CompactionResult
    local function send(prompt, expected_requests)
      local run = assert(agent:send(prompt))
      assert(type(run) == "table")
      assert(vim.wait(1000, function()
        return run:is_done() and not agent:is_running()
      end))
      assert.are.equal(expected_requests, #model.requests)
      local result = assert(run:result())
      return result
    end

    assert.are.equal("cancelled", assert(send("cancel", 1).error).kind)
    assert.matches("billing", assert(send("quota", 2).error).message)
    assert.is_true(send("reconnect", 4).ok)
    assert.matches("rate limit", assert(send("limited", 5).error).message)
    assert.are.equal(0, compactions)
  end)

  it("cancels a pending retry without launching another turn", function()
    local failed = model_failure(fake_model.assistant({}, "error"), {
      kind = "transport",
      message = "HTTP 503: overloaded",
      retryable = true,
      stream_max_retries = 5,
      retry_after_ms = 10000,
    })
    local model = fake_model.new({ { result = failed } })
    setup_model(model)
    assert(neoagent.send("stop retrying"))
    assert(vim.wait(1000, function()
      return snapshot().context.provider_status == "Reconnecting… 1/3"
    end))
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, function() return is_idle() end))

    assert.are.equal(1, #model.requests)
    assert.are.equal("cancelled", assert(assert(snapshot().result).error).kind)
    assert.is_false(snapshot().context.provider_status)
  end)

  it("releases retry ownership when the Agent is destroyed", function()
    local failed = model_failure(fake_model.assistant({}, "error"), {
      kind = "transport",
      message = "HTTP 503: overloaded",
      retryable = true,
      retry_after_ms = 10000,
    })
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return agent:snapshot().context.provider_status == "Reconnecting… 1/3"
    end))

    agent:destroy()

    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.equal("cancelled", assert(assert(run:result()).error).kind)
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
  end)

  it("reports manual compaction model resolution failures", function()
    local options = model_options(fake_model.new({}))
    options.default_model = nil
    options.providers = {}
    local value = neoagent.new(options)
    neoagent._set_default(value)

    assert(value:prepare())
    local levels, levels_err = value:available_thinking_levels()
    assert.is_nil(levels)
    assert.matches("No models are configured", assert(levels_err).message)
    local cycled, cycle_err = value:cycle_thinking_level()
    assert.is_nil(cycled)
    assert.matches("No models are configured", assert(cycle_err).message)
    assert.is_nil((value:select_model()))
    local position, position_err = value:set_ui_position("diagonal" --[[@as Neoagent.UiPosition]])
    assert.is_nil(position)
    assert.matches("invalid window position", assert(position_err).message)
    local run, err = value:compact("summarize")

    assert.is_nil(run)
    assert.matches("No models are configured", assert(err).message)
  end)

  it("passes manual instructions through the internal compaction runtime", function()
    ---@type Neoagent.AgentCompactionOptions?
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
    assert.is_nil((neoagent.compact()))
    local interaction = assert(neoagent.send("manual compact"))
    assert(type(interaction) == "table")
    assert(vim.wait(1000, function() return interaction:is_done() and is_idle() end))
    local run = assert(neoagent.compact("focus on tests"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.are.equal("focus on tests", assert(captured).instructions)
    local entries = current_session():entries()
    local checkpoint = entries[#entries]
    assert.are.equal("compaction", checkpoint.type)
  end)

  it("contains post-compaction persistence, projection, and callback failures", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ {
        type = "text", text = string.rep("answer ", 20),
      } }),
    } })
    model.context_window = 100
    ---@type Neoagent.Agent?
    local agent
    local original_context_messages
    local attempts = 0
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    agent = setup_model(model, {
      compaction = {
        auto = false, reserve_tokens = 20, keep_recent_tokens = 5,
      },
      _compaction_run = function(options)
        attempts = attempts + 1
        assert(options.report)({ kind = "callback", phase = "done", message = "failed" })
        if attempts == 2 then
          local session = assert(agent):get_session()
          original_context_messages = session.context_messages
          session.context_messages = function()
            return nil, require("neoagent.util").error(
              "storage", "projection unavailable")
          end
        end
        return completed_run(options, {
          ok = true,
          summary = "checkpoint",
          first_kept_entry_id = options.preparation.first_kept_entry_id,
          tokens_before = options.preparation.tokens_before,
        })
      end,
    })
    local interaction = assert(agent:send("prepare a compactable turn"))
    assert(type(interaction) == "table")
    assert(vim.wait(1000, function() return interaction:is_done() end))
    local session = agent:get_session()
    local append_compaction = session.append_compaction
    session.append_compaction = function()
      return nil, require("neoagent.util").error(
        "storage", "checkpoint unavailable")
    end
    local run = assert(agent:compact())
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.is_false(assert(run:result()).ok)
    assert.matches("checkpoint unavailable", assert(assert(run:result()).error).message)
    session.append_compaction = append_compaction

    run = assert(agent:compact())
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    session.context_messages = original_context_messages
    vim.notify = original_notify

    assert.is_false(assert(run:result()).ok)
    assert.matches("projection unavailable", assert(assert(run:result()).error).message)
    assert.are.equal(2, attempts)
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(item)
      return item.message:find(
        "callback failed during done", 1, true) ~= nil
    end, notifications), true))
  end)

  it("recovers when a custom compaction runner cannot start", function()
    local assistant = fake_model.assistant({ {
      type = "text", text = string.rep("answer ", 20),
    } })
    assert(assistant.message.usage).totalTokens = 90
    local attempts = 0
    ---@type Neoagent.AgentCompactionOptions?
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
          assert(options.on_event)({ type = "provider_status", text = "discarded" })
          assert(options.on_done)({
            ok = true,
            summary = "discarded summary",
            first_kept_entry_id = options.preparation.first_kept_entry_id,
            tokens_before = options.preparation.tokens_before,
          })
          error("compactor exploded")
        end
        assert(options.on_event)({ type = "provider_status", text = "synchronous" })
        assert(options.on_done)({
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
    assert(type(interaction) == "table")
    assert(vim.wait(1000, function()
      return interaction:is_done() and is_idle()
    end))
    assert.are.equal(1, attempts)
    assert.are.equal(0, #vim.tbl_filter(function(entry)
      return entry.type == "compaction"
    end, current_session():entries()))
    assert(assert(failed_options).on_event)({ type = "provider_status", text = "late" })
    assert(assert(failed_options).on_done)({ ok = false, error = {
      kind = "compaction", message = "late failure",
    } })

    local run = assert(neoagent.compact())
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(2, attempts)
    local entries = current_session():entries()
    assert.are.equal("compaction", entries[#entries].type)
    assert.are.equal("synchronous summary", entries[#entries].summary)
  end)

  it("reports manual compaction preconditions and failed summaries", function()
    setup_model(fake_model.new({}), { compaction = false })
    assert.is_nil((neoagent.compact()))
    assert.is_nil((neoagent.compact()))

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
    assert(type(interaction) == "table")
    assert(vim.wait(1000, function() return interaction:is_done() and is_idle() end))
    local run = assert(neoagent.compact())
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() and is_idle() end))
    local transcript = table.concat(vim.api.nvim_buf_get_lines((assert(view_handles.buffer(current_view(), "transcript"))), 0, -1, false), "\n")
    assert.matches("summary failed", transcript)

    setup_model(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "brief" } }),
    } }), {
      compaction = { auto = false, reserve_tokens = 20, keep_recent_tokens = 100 },
    })
    local short = assert(neoagent.send("short"))
    assert(type(short) == "table")
    assert(vim.wait(1000, function() return short:is_done() end))
    local compacted, err = neoagent.compact()
    assert.is_nil(compacted)
    assert.matches("Nothing can be compacted", assert(err).message)

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
        error("unexpected compaction while provider is busy")
      end,
    })
    local interaction = assert(neoagent.send("create a session"))
    assert(type(interaction) == "table")
    assert(vim.wait(1000, function() return interaction:is_done() end))
    local operation = assert(require("neoagent.provider_service").run(
      service, "mutate"))
    assert(vim.wait(1000, function() return pending ~= nil end))

    local called, run, err = pcall(neoagent.compact)
    assert.is_true(called)
    assert.is_nil(run)
    assert.are.equal("provider", assert(err).kind)
    assert.matches("mutating provider operation", assert(err).message)
    assert.are.equal(0, compactions)
    assert.is_false(assert(neoagent.default()):is_running())

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
    assert.is_nil((neoagent.set_thinking_level("minimal")))
    assert.is_nil((neoagent.set_thinking_level("unknown" --[[@as Neoagent.ThinkingLevel]])))
    local run = assert(neoagent.send("think"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.equal("low", assert(assert(assert(model.requests[1]).request_opts).body).reasoning_effort)
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
    assert.is_nil(assert(current_session():state()).thinking_level)
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert.are.same({}, settings:load())
  end)

  it("constructs Neo and Chat Agents from their Profiles", function()
    ---@type Neoagent.TestControlledInteraction?
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
        accept_entry(options, "accepted")
        return controlled_run(options)
      end,
    }
    neoagent._setup(configured, profile_runtime(configured))
    assert(neoagent.open())
    assert.matches("^ Neo ·", window_title((assert(view_handles.window(current_view(), "transcript")))))
    assert(neoagent.send("inspect"))
    assert(vim.wait(1000, function() return captured ~= nil end))
    assert.are.same({ "read_file", "write_file", "edit_file", "shell", "read_agent_documentation" },
      vim.tbl_map(function(tool) return tool.name end, assert(assert(captured).tools)))
    local shell
    for _, tool in ipairs(assert(assert(captured).tools)) do
      if tool.name == "shell" then shell = tool break end
    end
    assert(shell)
    assert.matches("Defaults to 42", shell.input_schema.properties.timeout.description)
    assert.matches("Available tools:", (assert(assert(captured).system_prompt)))
    for _, name in ipairs({ "read_file", "write_file", "edit_file", "shell" }) do
      assert.is_truthy((assert(assert(captured).system_prompt):find("- " .. name .. ":", 1, true)))
    end
    assert.is_nil((assert(assert(captured).system_prompt):find("- grep:", 1, true)))
    assert.is_nil((assert(assert(captured).system_prompt):find("- find:", 1, true)))
    assert.matches("read_agent_documentation", (assert(assert(captured).system_prompt)))
    assert.matches("Use this only when the user asks about Neoagent", (assert(assert(captured).system_prompt)))
    assert.is_nil((assert(assert(captured).system_prompt):find("Main documentation:", 1, true)))
    assert.is_truthy((assert(assert(captured).system_prompt):find("Current working directory: " .. vim.fn.getcwd(), 1, true)))
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, is_idle))

    local applet = neoagent.applet()
    assert(applet:new("chat"))
    assert(vim.wait(1000, function()
      return window_title((assert(view_handles.window(current_view(), "transcript")))):match("^ Chat ·") ~= nil
    end))
    assert.is_nil(neoagent.get_session())
    assert(neoagent.send("hello"))
    assert(vim.wait(1000, function()
      return captured ~= nil and captured.prompt == "hello"
    end))
    assert.are.equal(2, #applet:agents())
    assert.are.equal("Chat", assert(applet:active_agent()):config().name)
    assert.are.same({}, assert(assert(captured).tools))
    assert.are.equal("", assert(captured).system_prompt)
    assert.has_error(function() neoagent.setup({}) end)
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, is_idle))
    assert.are.equal("Neo", assert(applet:select(
      assert(applet:agents()[1]):id())):config().name)
  end)

  it("honors an explicit tool list exactly", function()
    ---@type Neoagent.TestControlledInteraction?
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
        accept_entry(options, "accepted")
        return controlled_run(options)
      end,
    }
    neoagent._setup(configured, profile_runtime(configured))
    assert(neoagent.send("chat"))
    assert(vim.wait(1000, function() return captured ~= nil end))
    assert.matches("You are Neo", (assert(assert(captured).system_prompt)))
    assert.are.same({ "read_file", "write_file", "edit_file", "shell" },
      vim.tbl_map(function(tool) return tool.name end, assert(assert(captured).tools)))
    assert.is_nil((assert(assert(captured).system_prompt):find("read_agent_documentation", 1, true)))
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
    local initial = assert(agent):get_toolset()
    assert(initial.tools[1]).name = "changed copy"
    assert.are.equal("host_tool", assert(assert(agent):get_toolset().tools[1]).name)

    local previous = assert(agent):set_toolset({
      tools = { sandboxed },
      execute_tool = sandbox_execute,
    })
    assert.are.equal("host_tool", assert(assert(previous).tools[1]).name)
    assert.are.equal(initial.execute_tool, assert(previous).execute_tool)
    assert.are.equal("host_tool", assert(assert(assert(agent):config().tools)[1]).name)
    assert.are.equal(host_execute, assert(agent):config().execute_tool)

    assert(neoagent.send("use sandbox tools"))
    assert(vim.wait(1000, function() return calls[1] ~= nil end))
    assert.are.equal("sandbox_tool", calls[1].tools[1].name)
    assert.are.equal(sandbox_execute, calls[1].execute_tool)
    local changed, err = assert(agent):set_toolset(assert(previous))
    assert.is_nil(changed)
    assert.are.equal("agent", assert(err).kind)
    assert.are.equal("sandbox_tool", assert(assert(agent):get_toolset().tools[1]).name)
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, function() return not assert(agent):is_running() end))

    assert(assert(agent):set_toolset(assert(previous)))
    assert(neoagent.send("use host tools"))
    assert(vim.wait(1000, function() return calls[2] ~= nil end))
    assert.are.equal("host_tool", calls[2].tools[1].name)
    assert.are.equal(initial.execute_tool, calls[2].execute_tool)
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, function() return not assert(agent):is_running() end))
    local malformed_list = { tools = "invalid" }
    ---@cast malformed_list Neoagent.AgentToolset<Neoagent.AgentToolEnvironment>
    assert.has_error(function() assert(agent):set_toolset(malformed_list) end,
      "toolset.tools must be a list")
    local stable = assert(agent):get_toolset()
    local malformed_toolset = { tools = { {
      name = "incomplete", description = "missing execution", input_schema = {},
    } } }
    ---@cast malformed_toolset Neoagent.AgentToolset<Neoagent.AgentToolEnvironment>
    assert.has_error(function()
      assert(agent):set_toolset(malformed_toolset)
    end, "tool[1].execute must be a function")
    assert.are.same(stable.tools, assert(agent):get_toolset().tools)
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
      "fake", configured_provider(options, "fake"), service)
    local users = {}
    local unsubscribe = require("neoagent.provider_service").subscribe(
      service, function(value) users[#users + 1] = value.users end)
    local agent = neoagent.new(options, {
      runtimes = { fake = runtime },
    })
    neoagent._set_default(agent)

    local run, err = agent:send("must not be accepted")

    assert.is_nil(run)
    assert.matches("prompt preparation failed", assert(err).message)
    assert.are.same({}, agent:get_session():messages())
    assert.are.same({ 1, 0 }, users)
    unsubscribe()
  end)

  it("toggles built-in sandbox execution while Chat or Neo is active", function()
    ---@type Neoagent.TestControlledInteraction[]
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
        accept_entry(options, "accepted-" .. #interactions)
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
      local stable = assert(neo):get_toolset()
      assert.is_table(assert(assert(stable.tools[1]).input_schema.properties).options)
      local running = assert(interactions[1])
      local function execute()
        ---@type Neoagent.ToolResult?
        local value
        local executor = assert(running.execute_tool)
        local loop = require("neoagent.agent_loop").run({
          model = fake_model.new({
            { result = fake_model.assistant({ {
              type = "toolCall", id = "inspect", name = "inspect", arguments = {},
            } }, "toolUse") },
            { result = fake_model.assistant({}) },
          }),
          messages = {}, tools = running.tools, context = assert(running.context),
          commit_message = function() return true end,
          execute_tool = function(selected, arguments, ctx)
            value = executor(selected, arguments, ctx)
            return value
          end,
        })
        assert(vim.wait(1000, function() return loop:is_done() end))
        assert.is_true(assert(loop:result()).ok)
        local content = assert(assert(value).content[1])
        assert(content.type == "text")
        return content.text
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
      assert.are.same(stable.tools, assert(neo):get_toolset().tools)
      assert.are.equal(stable.execute_tool,
        assert(neo):get_toolset().execute_tool)
      assert.is_true(neoagent.stop())
      assert(vim.wait(1000, function() return not assert(neo):is_running() end))

      assert(window:new("chat"))
      assert(neoagent.send("chat stays tool-free"))
      assert(vim.wait(1000, function() return interactions[2] ~= nil end))
      local chat = window:active_agent()
      assert.are.equal("Chat", assert(chat):config().name)
      assert.are.same({}, assert(chat):get_toolset().tools)
      local toggled, toggle_err = neoagent.toggle_sandbox()
      assert.is_nil(toggled)
      assert.are.equal("sandbox", assert(toggle_err).kind)
      assert.is_true(neoagent.stop())
      assert(vim.wait(1000, function() return not assert(chat):is_running() end))

      assert.are.equal(neo, window:select(assert(neo)))
      assert.is_true(assert(neoagent.toggle_sandbox()).active)
      assert.are.same(stable.tools, assert(neo):get_toolset().tools)
    end)
    dispatch.select = original_select
    assert(ok, err)
  end)

  it("keeps sandbox guidance stable across runtime toggles", function()
    ---@type Neoagent.TestControlledInteraction?
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
        accept_entry(options, "accepted")
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
      local stable_prompt = assert(captured).system_prompt
      assert.matches("Sandbox controls", (assert(stable_prompt)))
      assert.matches("require_escalation", (assert(assert(captured).system_prompt)))
      assert.is_true(neoagent.stop())
      assert(vim.wait(1000, is_idle))

      local previous_capture = captured
      assert(neoagent.toggle_sandbox())
      assert(neoagent.send("inspect"))
      assert(vim.wait(1000, function()
        return captured ~= previous_capture
      end))
      assert.are.equal(stable_prompt, assert(captured).system_prompt)
      assert.is_true(neoagent.stop())
      assert(vim.wait(1000, is_idle))
    end)
    dispatch.select = original_select
    assert(ok, err)
  end)

  it("blocks tools after failed activation until sandboxing is explicitly disabled", function()
    local executions = 0
    local tool = {
      name = "inspect",
      description = "Inspect",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
      execute = function()
        executions = executions + 1
        return { content = { { type = "text", text = "host" } } }
      end,
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
      assert(type(run) == "table")
      assert(vim.wait(1000, function() return run:is_done() end))
      local toolset = assert(neoagent.default()):get_toolset()
      local function execute()
        local loop = require("neoagent.agent_loop").run({
          model = fake_model.new({
            { result = fake_model.assistant({ {
              type = "toolCall", id = "inspect", name = "inspect", arguments = {},
            } }, "toolUse") },
            { result = fake_model.assistant({}) },
          }),
          messages = {}, tools = toolset.tools, execute_tool = toolset.execute_tool,
          commit_message = function() return true end,
        })
        assert(vim.wait(1000, function() return loop:is_done() end))
        local completed = assert(loop:result())
        assert(completed.ok)
        local tool_result = assert(completed.new_messages[2])
        assert(tool_result.role == "toolResult")
        return tool_result.isError
      end
      local status = assert(neoagent.toggle_sandbox())
      assert.is_true(status.enabled)
      assert.is_false(status.active)
      assert.are.equal("inspect",
        assert(assert(neoagent.default()):get_toolset().tools[1]).name)
      assert.matches("tool execution is blocked",
        notifications[#notifications][1])
      assert.are.equal(vim.log.levels.WARN,
        notifications[#notifications][2])
      assert.is_true(execute())
      assert.are.equal(0, executions)
      status = assert(neoagent.toggle_sandbox())
      assert.is_false(status.enabled)
      assert.is_false(execute())
      assert.are.equal(1, executions)
      dispatch.select = function() error("sandbox probe exploded") end
      local failed, failure = neoagent.toggle_sandbox()
      assert.is_nil(failed)
      assert.are.equal("sandbox", assert(failure).kind)
      assert.matches("sandbox probe exploded", assert(failure).message)
      assert.is_true(neoagent.sandbox_info().enabled)
      assert.is_false(neoagent.sandbox_info().active)
      assert.is_true(execute())
      assert.are.equal(1, executions)
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
    ---@type Neoagent.TestControlledInteraction?
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
    assert.matches("^Custom base for inspect", (assert(assert(captured).system_prompt)))
    assert.matches("Always run the focused tests", (assert(assert(captured).system_prompt)))
    assert.matches("<name>review</name>", (assert(assert(captured).system_prompt)))
    assert.matches("Review Lua changes", (assert(assert(captured).system_prompt)))
    assert.matches(vim.pesc(vim.uv.fs_realpath(skill_path)), (assert(assert(captured).system_prompt)))
    assert.is_nil((assert(assert(captured).system_prompt):find("PRIVATE SKILL BODY", 1, true)))
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
      return captured ~= previous_capture and assert(captured).prompt == "chat"
    end))
    assert.are.equal("Tool-free chat", assert(captured).system_prompt)
    assert.is_true(neoagent.stop())
    assert(vim.wait(1000, is_idle))
  end)

  it("keeps the draft when an interaction rejects setup", function()
    setup_model(fake_model.new({}), { _interaction = function() error("cannot start") end })
    assert(neoagent.open())
    local view = current_view()
    view:set_input("draft")
    local run = assert(neoagent.send("draft"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function()
      return run:is_done() and is_idle()
    end))
    assert.are.equal("draft", view:get_input())
    assert.are.equal(0, #current_session():messages())
  end)

  it("continues queued steering after an injected interaction settles", function()
    local calls = {}
    setup_model(fake_model.new({}), {
      _interaction = function(options)
        calls[#calls + 1] = options
        if #calls == 1 then accept_entry(options, "accepted") end
        return controlled_run(options)
      end,
    })
    assert(neoagent.send("begin"))
    assert.is_true((neoagent.send("queued")))
    assert(vim.wait(1000, function() return calls[1] ~= nil end))
    calls[1].complete({ ok = true })
    assert(vim.wait(1000, function() return #calls == 2 end))
    assert.are.equal("queued", calls[2].prompt)
    calls[2].complete({
      ok = false, error = { kind = "cancelled", message = "done" },
    })
  end)

  it("does not submit scheduled steering after the Agent is destroyed", function()
    local calls = {}
    local scheduled_callbacks_drained = false
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        calls[#calls + 1] = options
        accept_entry(options, "accepted")
        return controlled_run(options)
      end,
    })
    local unsubscribe = agent:subscribe(function(update)
      if update.type == "finish" then
        vim.schedule(function()
          agent:destroy()
          vim.schedule(function()
            scheduled_callbacks_drained = true
          end)
        end)
      end
    end)
    assert(agent:send("begin"))
    assert.is_true(agent:send("queued"))
    assert(vim.wait(1000, function() return calls[1] ~= nil end))
    calls[1].complete({
      ok = true,
      new_messages = {},
      session = calls[1].session,
      message = fake_model.assistant({}).message,
    })
    assert(vim.wait(1000, function()
      return agent:is_destroyed()
        and not agent:is_running()
        and scheduled_callbacks_drained
    end))

    assert.are.equal(1, #calls)
    assert.are.same({ "queued" }, agent:snapshot().context.steering)
    unsubscribe()
  end)

  it("restores queued steering when a scheduled submission cannot start", function()
    local calls = {}
    setup_model(fake_model.new({}), {
      _interaction = function(options)
        calls[#calls + 1] = options
        if #calls == 1 then accept_entry(options, "accepted") end
        if #calls > 1 then error("queued interaction failed") end
        return controlled_run(options)
      end,
    })
    assert(neoagent.send("begin"))
    assert.is_true((neoagent.send("queued")))
    assert(vim.wait(1000, function() return calls[1] ~= nil end))
    calls[1].complete({ ok = true })
    assert(vim.wait(1000, function()
      return #calls == 2 and is_idle()
        and vim.deep_equal(assert(neoagent.default()):snapshot().context.steering, { "queued" })
    end))
    assert.are.equal(2, #calls)
  end)

  it("restores claimed steering when submission preparation fails", function()
    local calls = {}
    local steering = {}
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        calls[#calls + 1] = options
        if #calls == 1 then accept_entry(options, "accepted") end
        return controlled_run(options)
      end,
    })
    agent:subscribe(function(update)
      if update.type == "context" then steering = assert(update.context).steering or {} end
    end)
    assert(agent:send("begin"))
    assert.is_true(agent:send("queued"))
    assert(vim.wait(1000, function() return calls[1] ~= nil end))
    local session = agent:get_session()
    local messages = session.messages
    session.messages = function() error("conversation unavailable") end
    calls[1].complete({ ok = true, new_messages = {} })
    assert(vim.wait(1000, function()
      return not agent:is_running()
        and vim.deep_equal(steering, { "queued" })
    end))
    session.messages = messages
    assert.are.equal(1, #calls)
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
    assert.is_nil((neoagent.fork()))
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
    ---@type Neoagent.TestAgentUIConfig
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
    assert(previous):destroy()
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
    assert.matches("No models are configured", assert(err).message)
    assert.is_nil(value:get_model())
  end)

  it("resolves dynamic catalogs and contains Provider Service failures", function()
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local provider_events = {}
    local failed = model_failure(fake_model.assistant({}, "error"), {
      kind = "model",
      message = "provider limited",
      provider_status = "limited",
      provider_status_details = { scope = "dynamic" },
    })
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
    local runtime = provider_runtime("dynamic", configured_provider(options, "dynamic"),
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
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return run:is_done() end, 5))
    assert.is_true(#provider_events > 0)
    value:destroy()
    assert(vim.wait(1000, function()
      return has_notification(notifications, "provider unsubscribe failed")
    end, 5))

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
        "fake", configured_provider(rejected_options, "fake"), subscription),
    } })
    neoagent._set_default(rejected)
    assert(rejected:prepare())

    vim.notify = original_notify
    assert(has_notification(notifications, "provider subscription failed"))
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
      "dynamic", configured_provider(options, "dynamic"))
    local value = neoagent.new(options, {
      runtimes = { dynamic = runtime },
    })
    neoagent._set_default(value)
    assert(value:prepare())
    assert(neoagent.open())
    assert.is_true((value:select_model()))
    local view, request = presentation.active(neoagent.applet())
    local component = view.presentation_component
    assert.are.equal("dynamic/seed", assert(component).selected)
    assert.are.equal("presentation-filter", view.applet:focused_pane())

    assert(runtime.catalog:publish_discoveries({
      { id = "remote" }, { id = "seed" },
    }))
    assert(vim.wait(1000, function()
      local target = "presentation:" .. request.id
        .. ":item:dynamic/remote"
      return view.presentation_component == component
        and #assert(assert(view.presentation).active).items == 2
        and assert(assert(assert(component).results).layout).targets[target] ~= nil
    end, 5))
    assert.are.equal(request.id, assert(assert(view.presentation).active).id)
    assert.are.equal("dynamic/seed", assert(component).selected)
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
    local runtime = provider_runtime("dynamic", configured_provider(options, "dynamic"),
      service)
    local value = neoagent.new(options, {
      runtimes = { dynamic = runtime },
    })
    neoagent._set_default(value)
    assert(value:prepare())
    assert(runtime.catalog:publish_discoveries({ { id = "remote" } }))

    assert(vim.wait(1000, function()
      for _, notification in ipairs(notifications) do
        if notification.message:match("could not resolve dynamic/remote")
          and notification.message:match("model constructor failed") then
          return true
        end
      end
      return false
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
    assert.matches("does not support thinking", assert(err).message)
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
    assert(assert(models.selected.responses[1]).result.message).model = "selected"
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
    assert(type(saved) == "table")
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
      assert(assert(model.responses[1]).result.message).model = id
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
    assert(type(first) == "table")
    assert(vim.wait(1000, function() return first:is_done() end, 5))
    local path = assert(current_session():metadata()).path
    local workspace_storage = require("neoagent.workspace_storage").new(settings:metadata().directory)
    assert.are.same({ provider = "fake", model = "test" },
      assert(assert(settings:load()).agents.Neo).default_model)
    assert.are.same({ provider = "fake", model = "test" },
      assert(require("neoagent.storage").open(assert(path), workspace_storage)):state().model)

    assert.are.equal(models.alpha, neoagent.set_model("fake", "alpha"))
    assert.are.same({ provider = "fake", model = "test" },
      assert(assert(settings:load()).agents.Neo).default_model)
    assert.are.same({ provider = "fake", model = "test" },
      assert(require("neoagent.storage").open(assert(path), workspace_storage)):state().model)

    local second = assert(neoagent.send("use alpha"))
    assert(type(second) == "table")
    assert(vim.wait(1000, function() return second:is_done() end, 5))
    assert.are.same({ provider = "fake", model = "test" },
      assert(assert(settings:load()).agents.Neo).default_model)
    assert.are.same({ provider = "fake", model = "alpha" },
      assert(require("neoagent.storage").open(assert(path), workspace_storage)):state().model)

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
    ---@type Neoagent.TestAgentUIConfig
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
    assert.are.equal("test", assert(neoagent.get_model()).id)
    assert.are.equal("low", neoagent.get_thinking_level())
    assert.are.equal("off", neoagent.set_thinking_level("off"))
    saved = assert(settings:load())
    assert.is_nil(saved.agents)
    assert.are.equal(chat, neoagent._set_default(neo))
    assert.are.equal("alpha", assert(neoagent.get_model()).id)
    assert.are.equal("high", neoagent.get_thinking_level())
    assert.are.same({}, require("neoagent.storage").list(directory, vim.fn.getcwd()))
    local run = assert(neoagent.send("remember this"))
    assert(type(run) == "table")
    local session_path = assert(current_session():metadata()).path
    local workspace_storage = require("neoagent.workspace_storage").new(settings:metadata().directory)
    assert(vim.wait(1000, function() return run:is_done() end))
    local stored = assert(require("neoagent.storage").open(assert(session_path), workspace_storage)):state()
    assert.are.same({ provider = "fake", model = "alpha" }, stored.model)
    assert.are.equal("high", stored.thinking_level)
    saved = assert(settings:load())
    assert.are.same({ provider = "fake", model = "alpha" },
      assert(saved.agents.Neo).default_model)
    assert.are.equal("high", assert(saved.agents.Neo).default_thinking_level)

    local replacement = neoagent.new(options)
    assert.are.equal(neo, neoagent._set_default(replacement))
    neo:destroy()
    chat:destroy()
    assert(neoagent.open())
    assert.are.equal("left", current_view().position)
    assert.are.equal("fake/alpha", current_view().context.model)
    assert.are.same({ "off", "low", "high" }, assert(neoagent.available_thinking_levels()))
    assert.are.equal("alpha", assert(neoagent.get_model()).id)
    assert.are.equal("high", neoagent.get_thinking_level())

    setup_session(models.test,
      assert(require("neoagent.storage").open(assert(session_path), workspace_storage)), options)
    assert.are.equal("alpha", assert(neoagent.get_model()).id)
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
    assert(assert(models.plain.responses[1]).result.message).model = "plain"
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
    assert(type(run) == "table")
    local session_path = assert(current_session():metadata()).path
    local workspace_storage = require("neoagent.workspace_storage").new(settings:metadata().directory)
    assert(vim.wait(1000, function() return run:is_done() end, 5))

    local saved = assert(settings:load()).agents.Neo
    assert.are.same({ provider = "fake", model = "plain" },
      assert(saved).default_model)
    assert.is_nil(assert(saved).default_thinking_level)
    local stored = assert(require("neoagent.storage").open(assert(session_path), workspace_storage))
    assert.is_nil(stored:state().thinking_level)
    assert.are.equal(vim.NIL,
      assert(assert(stored:entries()[1]).request).thinking_level)

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
    ---@type Neoagent.SessionStore?
    local captured_store
    local fail_settings = true
    workspace_settings.new = function(opts)
      local settings = original_settings_new(opts)
      local update = settings.update
      function settings:update(values)
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
      assert(assert(agent):prepare())

      local selected, err = assert(agent):set_model("fake", "test")
      assert.are.equal(model, selected)
      assert.is_nil(err)

      local position, position_err = assert(agent):set_ui_position("left")
      assert.is_nil(position)
      assert.are.equal(save_error, position_err)

      local level
      level, err = assert(agent):set_thinking_level("high")
      assert.are.equal("high", level)
      assert.is_nil(err)
      assert.are.equal("high", assert(agent):get_thinking_level())

      local append = assert(captured_store).append
      local run = assert(assert(agent):send("accepted without settings"))
      assert(type(run) == "table")
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.is_true(assert(run:result()).ok)
      assert.are.same({ provider = "fake", model = "test" },
        assert(assert(agent):get_session():state()).model)

      fail_settings = false
      assert(captured_store).append = function() return nil, journal_error end
      selected, err = assert(agent):set_model("fake", "test")
      assert.are.equal(model, selected)
      assert.is_nil(err)
      local rejected_run
      rejected_run, err = assert(agent):send("rejected")
      assert(type(rejected_run) == "table")
      run = rejected_run
      assert.is_nil(err)
      assert(run)
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.is_false(assert(run:result()).ok)
      assert.are.equal(journal_error.message, assert(assert(run:result()).error).message)
      assert.are.same({ provider = "fake", model = "test" },
        assert(assert(agent):get_session():state()).model)

      assert(captured_store).append = append
      run = assert(assert(agent):send("accepted"))
      assert(type(run) == "table")
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.are.same({ provider = "fake", model = "test" },
        assert(assert(agent):get_session():state()).model)
    end)
    workspace_settings.new = original_settings_new
    storage.new = original_storage_new
    assert(ok, test_err)
  end)
  it("cancels an active interaction Run when destroyed", function()
    local cancelled = {}
    local started = false
    ---@type Neoagent.TestControlledInteraction?
    local captured
    local agent = setup_model(fake_model.new({}), {
      _interaction = function(options)
        captured = options
        started = true
        return controlled_run(options, function() cancelled.run = true end)
      end,
    })
    local events = 0
    local unsubscribe = agent:subscribe(function(update)
      if update.type == "event" then
        events = events + 1
        if events == 1 then
          agent:destroy()
          assert(assert(captured).on_event)({
            type = "provider_status", text = "stale after destruction",
          })
        end
      end
    end)
    local run = assert(agent:send("wait"))
    assert(type(run) == "table")
    assert(vim.wait(1000, function() return started end))
    assert.is_true(agent:is_running())
    assert(assert(captured).on_event)({
      type = "provider_status", text = "destroy now",
    })

    assert(vim.wait(1000, function()
      return run:is_done() and not agent:is_running()
    end))
    assert.are.same({ run = true }, cancelled)
    assert.are.equal(1, events)
    assert.is_false(agent:is_running())
    unsubscribe()
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
    ---@async
    local function execute_wait()
      tool_started = true
      return require("neoagent.async").await(function()
        return function() end
      end)
    end
    local agent = setup_model(model, {
      providers = { fake = {
        api = "fake-api", models = { test = {} },
        service = function() return service end,
      } },
      tools = { {
        name = "wait", description = "Wait", input_schema = {},
        execute = execute_wait,
      } },
    })
    local run = assert(agent:send("wait for the Tool"))
    assert(type(run) == "table")
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

  it("reports credential failures while enumerating models", function()
    local options = model_options(fake_model.new({}))
    options.default_model = nil
    assert(options.providers).fake.api_key = function()
      error("private credential resolver failure")
    end
    local original_notify = vim.notify
    ---@type {[1]: string, [2]?: integer}[]
    local notifications = {}
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local value = neoagent.new(options)
    neoagent._set_default(value)

    local prepared, prepare_err = value:prepare()
    local selected = value:select_model()

    vim.notify = original_notify
    assert.is_nil(prepared)
    assert.matches("Failed to resolve the provider environment credential",
      assert(prepare_err).message)
    assert.is_not_matches("private credential resolver failure",
      assert(prepare_err).message)
    assert.is_nil(selected)
    assert.matches("Failed to resolve the provider environment credential",
      assert(notifications[#notifications])[1])
    assert.are.equal(vim.log.levels.ERROR,
      assert(notifications[#notifications])[2])
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
    assert.are.equal("test", assert(neoagent.get_model()).id)
    assert.are.equal("low", neoagent.get_thinking_level())
    assert(neoagent.open())
    assert.are.equal("center", current_view().position)

    assert(settings:write({ agents = "invalid" }))
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", assert(neoagent.get_model()).id)
    assert(settings:write({ agents = { Neo = "invalid" } }))
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", assert(neoagent.get_model()).id)

    vim.fn.writefile({ "{" }, settings.settings_path)
    setup_model(model, extra)
    assert(neoagent.available_thinking_levels())
    assert.are.equal("test", assert(neoagent.get_model()).id)

    assert(settings:write({}))
    local store = require("neoagent.storage").new({ directory = directory, cwd = vim.fn.getcwd() })
    assert(store:append({ role = "user", content = "fallback", timestamp = 1 }, {
      model = { provider = "missing", model = "gone" },
    }))
    setup_session(model, store, extra)
    assert.are.equal("test", assert(neoagent.get_model()).id)
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
    assert(type(run) == "table")
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
    assert(type(run) == "table")

    assert(vim.wait(1500, function() return run:is_done() end))
    assert(vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1] == "new"
    end))

    local failed_tool = {
      name = "failed_disk_replacement",
      description = "Report a failed disk replacement",
      input_schema = {
        type = "object", properties = {}, additionalProperties = false,
      },
      execute = function()
        vim.fn.writefile({ "failed on disk" }, path)
        return {
          content = { { type = "text", text = "replacement failed" } },
          isError = true,
          details = { changed_paths = { path } },
        }
      end,
    }
    local failed_model = fake_model.new({
      { result = fake_model.assistant({ {
        type = "toolCall", id = "failed-replace",
        name = failed_tool.name, arguments = {},
      } }, "toolUse") },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    local failed_agent = setup_model(failed_model, { tools = { failed_tool } })
    local failed_run = assert(failed_agent:send("attempt the replacement"))
    assert(type(failed_run) == "table")
    assert(vim.wait(1500, function() return failed_run:is_done() end))

    assert.are.equal("failed on disk", assert(vim.fn.readfile(path)[1]))
    assert.are.equal("new",
      vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1])
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
    assert(type(run) == "table")
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
    assert(neoagent.default()):snapshot()
    local resumed_id = session_ids[#session_ids]
    assert.are.same(plan, tool.current({ session_id = resumed_id }))
    assert(neoagent.open())
    assert(vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(
        (assert(view_handles.buffer(current_view(), "transcript"))), 0, -1, false)
      return table.concat(lines, "\n"):find("Updated Plan", 1, true) ~= nil
    end))

    setup_model(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
      tools = { tool },
      ui = { style = "codex" },
    })
    assert(neoagent.default()):snapshot()
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
    ---@type Neoagent.TestControlledInteraction?
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
    assert.are.equal("before", assert(current_session():messages()[1]).content)
    assert(neoagent.send("continue"))
    assert(vim.wait(1000, function() return interaction_options ~= nil end))
    local messages = current_session():messages()
    assert.are.equal(5, #messages)
    assert.are.equal("toolResult", assert(messages[5]).role)
    assert.are.equal("pending", assert(messages[5]).toolCallId)
    assert.is_true(assert(messages[5]).isError)
    assert.matches("Available tools:\n%(none%)", (assert(assert(interaction_options).system_prompt)))
    assert.matches("prompt: continue$", (assert(assert(interaction_options).system_prompt)))
    assert.is_nil((neoagent.fork()))
    assert.is_nil(neoagent.select_model())
    assert.is_nil((neoagent.set_model("fake", "test")))
    assert.is_nil((neoagent.cycle_thinking_level()))
    assert.is_nil((neoagent.set_thinking_level("high")))
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

  require("tests.helpers.async_test")("selects forked sessions by recent tree activity", function()
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

    assert.is_false((neoagent.toggle()))
    assert(neoagent.resume())
    assert.is_true(current_view():is_open())
    local _, request = presentation.active(neoagent.applet())
    assert.are.equal(8, #request.items)
    assert.matches("^● parent preview%s+3d.*Neo$", assert(assert(request.items)[1]).label)
    assert.matches("^  ├─ parent preview%s+1h.*Neo$", assert(assert(request.items)[2]).label)
    assert.matches("^  │  └─ parent preview%s+10m.*Neo$", assert(assert(request.items)[3]).label)
    assert.matches("^  └─ parent preview%s+30m.*Neo$", assert(assert(request.items)[4]).label)
    assert.matches("^  Recent root%s+2h.*Neo$", assert(assert(request.items)[5]).label)
    assert.matches("^  Weekly root%s+1w.*Neo$", assert(assert(request.items)[6]).label)
    assert.matches("^  Monthly root%s+2mo.*Neo$", assert(assert(request.items)[7]).label)
    assert.matches("^  Yearly root%s+2y.*Neo$", assert(assert(request.items)[8]).label)
    presentation.choose(neoagent.applet(), "session-2")
    assert(vim.wait(1000, function()
      return assert(current_session():metadata()).path == child:metadata().path
    end, 5))
    assert.are.equal(child:metadata().path, assert(current_session():metadata()).path)
    assert.are.equal("child work", assert(current_session():messages()[2]).content)
    assert.is_true(current_view():is_open())

    local empty = vim.fn.tempname()
    paths[#paths + 1] = empty
    setup_bundled_model(fake_model.new({}), {
      persistence = { enabled = true, directory = empty },
    })
    assert.is_nil((neoagent.resume()))
    assert.is_true(assert(neoagent.applet():view()):is_open())
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
    assert.is_truthy((assert(assert(request.items)[1]).label:find(text, 1, true)))
    assert.is_nil((assert(assert(request.items)[1]).label:find("…", 1, true)))
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
    assert(store:set_leaf(assert(first).id))
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
    assert.are.equal("right", assert(assert(assert(current_session():messages()[2]).content)[1]).text)
    assert.is_false((neoagent.toggle()))
    assert(neoagent.select_branch())
    assert.is_true(current_view():is_open())
    local _, request = presentation.active(neoagent.applet())
    assert.is_true(#request.items >= 3)
    ---@type Neoagent.NormalizedSelectItem?
    local choice
    for _, item in ipairs(assert(request.items)) do
      if item.id == assert(left).id then choice = item break end
    end
    assert.matches("assistant · left", assert(assert(choice)).label)
    presentation.choose(neoagent.applet(), assert(left).id)
    assert(vim.wait(1000, function()
      return assert(assert(assert(current_session():messages()[2]).content)[1]).text == "left"
    end, 5))
    assert.are.equal("left", assert(assert(assert(current_session():messages()[2]).content)[1]).text)
    assert.are.equal("high", neoagent.get_thinking_level())

    local source_id = current_session():id()
    assert.is_false((neoagent.toggle()))
    assert(neoagent.select_fork())
    assert.is_true(current_view():is_open())
    _, request = presentation.active(neoagent.applet())
    assert.matches("user · question", assert(assert(request.items)[1]).label)
    presentation.choose(neoagent.applet(), assert(first).id)
    assert(vim.wait(1000, function()
      local session = current_session()
      return session and assert(session:metadata()).parent_session == source_id
    end, 5))
    local forked = current_session()
    assert.are.equal(source_id, assert(assert(forked):metadata()).parent_session)
    assert.are.same({}, assert(forked):messages())
    assert.are.equal("question", current_view():get_input())
    assert.are.equal(2, #require("neoagent.storage").list(directory, vim.fn.getcwd()))
    assert.are.equal(2, #neoagent.applet():agents())
  end)

  it("reports branch and fork selection preconditions", function()
    setup_model(fake_model.new({}))
    assert.is_nil(neoagent.steer("idle steering"))
    assert.is_nil((neoagent.branch("missing")))
    assert.is_nil(neoagent.select_branch())
    assert.is_nil((neoagent.fork()))
    assert.is_nil((neoagent.select_fork()))
    assert.is_nil(neoagent.select_branch())
    assert.is_nil((neoagent.select_fork()))
    assert.is_nil((neoagent.fork()))
    local _, _, entry = current_session():append({ role = "user", content = "memory" })
    local ok, err = neoagent.branch("missing")
    assert.is_nil(ok)
    assert.matches("Entry not found", assert(err).message)
    assert(neoagent.branch(assert(entry).id))
    assert.are.equal(1, #current_session():messages())
  end)

  it("toggles the view and changes configured models", function()
    setup_model(fake_model.new({}))
    assert(neoagent.open())
    assert.is_true(current_view():is_open())
    neoagent.toggle()
    assert.is_false(current_view():is_open())
    neoagent.toggle()
    assert.is_true(current_view():is_open())
    local selected = assert(neoagent.set_model("fake", "test"))
    local model = assert(neoagent.get_model())
    assert.are.equal(model, selected)
    assert.are.equal("fake", model.id)
    assert.is_nil(neoagent.get_thinking_level())
    assert.is_nil((neoagent.set_model("missing", "missing")))

    setup_model(model, {
      providers = { fake = { api = "fake-api", models = { test = {}, alpha = {} } } },
    })
    local ok, err = pcall(neoagent.select_model)
    assert(ok, err)
    local window = neoagent.applet()
    local _, model_request = presentation.active(window)
    assert.are.same({ "fake/alpha", "fake/test" },
      vim.tbl_map(function(item) return item.label end, assert(model_request.items)))
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
