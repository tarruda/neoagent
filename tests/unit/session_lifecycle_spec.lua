local assert = require("luassert")
local lifecycle_module = require("neoagent.agent.session_lifecycle")

describe("neoagent Agent session lifecycle", function()
  local owned_runtimes = {}
  after_each(function()
    for _, runtimes in ipairs(owned_runtimes) do require("neoagent.provider_runtimes").destroy(runtimes) end
    owned_runtimes = {}
  end)

  ---@param restore_selection? boolean
  local function fixture(restore_selection)
    local steering = require("neoagent.agent.steering").new()
    steering:enqueue(1, "previous", 1)
    local session = assert(require("neoagent.session").new())
    function session:move_to() return true end
    local selection = require("neoagent.request_selection").new({
      config = require("neoagent.config").resolve({ default_registry = false }),
    })
    selection.model_value = require("tests.helpers.fake_model").new()
    selection.model_value.id = "previous"
    selection.selected = { provider = "fake", model = "previous" }
    selection.thinking_value = "high"
    ---@class Neoagent.TestSessionLifecycleState: Neoagent.SessionLifecycleState
    ---@field request_selection Neoagent.RequestSelection
    local state = {
      session = session,
      request_selection = selection,
      live_usage = { tokens = 1, message_count = 1 },
      provider_status = "ready",
      inference_stats = { generation_tokens_per_second = 40 },
      pending_events = { { type = "provider_status", text = "previous" } },
      steering = steering,
      last_result = { ok = true, status = "succeeded", message_count = 1 },
    }
    ---@type {message: string, level: integer}[]
    local notifications = {}
    local published = 0
    local updated = 0
    ---@type Neoagent.SessionLifecycleOptions
    local opts = {
      state = state,
      workspace = "/bound-workspace",
      preferences = function() return {} end,
      notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end,
      request_selection = selection,
      bind_provider = function() end,
      publish_messages = function() published = published + 1 end,
      update_context = function() updated = updated + 1 end,
      restore_selection = restore_selection,
    }
    return lifecycle_module.new(opts), state, notifications, session,
      function() return published, updated end
  end

  it("labels empty messages with stable entry identity", function()
    assert.are.equal("assistant · empty-me", lifecycle_module.entry_label({
      type = "message",
      id = "empty-message-id", created_at = 1767225600000,
      message = { role = "assistant", content = {} },
    }))
  end)

  it("preserves complete message text in branch labels", function()
    local text = "branch:" .. string.rep(" complete-message-text", 12)
    assert.are.equal("user · " .. text, lifecycle_module.entry_label({
      type = "message",
      id = "complete-message-id", created_at = 1767225600000,
      message = { role = "user", content = text },
    }))
  end)

  it("changes branches within the owned Session and resets transient state", function()
    local moved
    local lifecycle, state, _, session, observed = fixture()
    function session:move_to(entry_id)
      moved = entry_id
      return true
    end

    assert(lifecycle.branch("entry-id"))

    assert.are.equal("entry-id", moved)
    assert.are.equal(session, state.session)
    assert.is_nil(state.live_usage)
    assert.is_nil(state.provider_status)
    assert.is_nil(state.inference_stats)
    assert.are.same({}, state.pending_events)
    assert.are.same({}, state.steering:texts())
    assert.is_nil(state.last_result)
    assert.is_nil(state.request_selection:model())
    local published, updated = observed()
    assert.are.equal(1, published)
    assert.are.equal(1, updated)
  end)

  it("preserves an unjournaled live selection across branch changes", function()
    local lifecycle, state, _, session = fixture()
    state.session_selection_pending = true
    local model = state.request_selection:model()
    local selection = state.request_selection:model_selection()
    session.state = function()
      return { model = { provider = "fake", model = "historical" } }
    end

    assert(lifecycle.branch("entry-id"))

    assert.are.equal(model, state.request_selection:model())
    assert.are.same(selection, state.request_selection:model_selection())
  end)

  it("restores the checkpoint Model when it differs from message history and defaults", function()
    local session = assert(require("neoagent.session").new())
    local _, _, original = session:append({ role = "user", content = "Earlier request" }, {
      model = { provider = "fake", model = "one" },
    })
    local _, _, checkpoint = session:append_compaction({
      native = { role = "nativeCompaction", api = "openai-codex-responses", provider = "fake",
        model = "two", encrypted_content = "synthetic-checkpoint" }, retained_users = {}, tokens_before = 100,
    })
    assert(checkpoint)
    local configured = require("neoagent.config").resolve({
      default_registry = false, default_model = { provider = "fake", model = "one" },
      providers = { fake = { api = "openai-codex-responses", base_url = "https://example.test",
        models = { one = {}, two = {} } } },
      _apis = { ["openai-codex-responses"] = function(resolved)
        local model = require("tests.helpers.fake_model").new()
        model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
        return model
      end },
    })
    local runtimes = assert(require("neoagent.provider_runtimes").compose(configured, { startup = false }))
    owned_runtimes[#owned_runtimes + 1] = runtimes
    local selection = require("neoagent.request_selection").new({
      config = configured, runtimes = runtimes, required_api = "openai-codex-responses",
      checkpoint_identity = function() return session:checkpoint_identity() end,
    })
    local warnings = {}
    local lifecycle = lifecycle_module.new({
      state = { session = session, steering = require("neoagent.agent.steering").new(), pending_events = {} },
      workspace = "/bound-workspace", restore_selection = true, request_selection = selection,
      preferences = function() return { default_model = { provider = "fake", model = "one" } } end,
      bind_provider = function() end, publish_messages = function() end, update_context = function() end,
      notify = function(message) warnings[#warnings + 1] = message end,
    })
    assert(lifecycle.initialize())
    assert.are.equal("two", assert(selection:model()).id)
    assert(lifecycle.branch(assert(original).id))
    assert.are.equal("one", assert(selection:model()).id)
    assert(lifecycle.branch(checkpoint.id))
    assert.are.equal("two", assert(selection:model()).id)
    assert.are.same({}, warnings)
  end)

  it("rejects branch changes while a Run is active", function()
    local lifecycle, state, notifications = fixture()
    state.activity = {
      id = 1, kind = "interaction", phase = "running",
      accepted = true, finalized = false,
    }

    assert.is_nil((lifecycle.branch("entry")))
    assert.matches("cannot change branches", assert(notifications[1]).message)
    assert.are.equal(vim.log.levels.WARN, assert(notifications[1]).level)
  end)

  it("propagates invalid Session projections during initialization and branching", function()
    local path_error = { kind = "session", message = "path unavailable" }
    local _, _, _, invalid_session = fixture()
    invalid_session.path = function() return nil, path_error end
    local path_ok, raised = pcall(function()
      lifecycle_module.transcript_messages(invalid_session)
    end)
    assert.is_false(path_ok)
    assert.are.equal(path_error, raised)

    local lifecycle, _, _, session = fixture(true)
    session.state = function()
      return nil, { kind = "session", message = "state unavailable" }
    end
    local initialized, initialize_err = lifecycle.initialize()
    assert.is_nil(initialized)
    assert.matches("state unavailable", assert(initialize_err).message)

    lifecycle, _, _, session = fixture()
    session.state = function()
      return nil, { kind = "session", message = "branch state unavailable" }
    end
    local moved, move_err = lifecycle.branch("entry-id")
    assert.is_nil(moved)
    assert.matches("branch state unavailable", assert(move_err).message)
  end)

  it("orders equally recent Session choices by their stable paths", function()
    local choices = require("neoagent.agent.session_choices").build({
      { id = "a", path = "/workspace/a", modified_at = 1000, text = "A" },
      { id = "b", path = "/workspace/b", modified_at = 1000, text = "B" },
    })
    assert.are.same({ "/workspace/b", "/workspace/a" },
      vim.tbl_map(function(choice) return choice.path end, choices))
  end)
end)
