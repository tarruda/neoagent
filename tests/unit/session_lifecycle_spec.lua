local assert = require("luassert")
local lifecycle_module = require("neoagent.agent.session_lifecycle")

describe("neoagent Agent session lifecycle", function()
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
