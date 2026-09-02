local lifecycle_module = require("neoagent.agent.session_lifecycle")

describe("neoagent Agent session lifecycle", function()
  local function fixture(overrides)
    local steering = require("neoagent.agent.steering").new()
    steering:enqueue(1, "previous", 1)
    local session = {
      path = function() return {} end,
      state = function() return {} end,
      move_to = function() return true end,
    }
    local selection = {
      model_value = { id = "previous" },
      selected = { provider = "fake", model = "previous" },
      thinking = "high",
    }
    function selection:clear()
      self.model_value, self.selected, self.thinking = nil, nil, nil
    end
    function selection:resolve(selected, thinking)
      self.model_value = { id = selected.model }
      self.selected = vim.deepcopy(selected)
      self.thinking = thinking
      return self.model_value
    end
    function selection:model() return self.model_value end
    function selection:model_selection() return vim.deepcopy(self.selected) end
    local state = {
      session = session,
      request_selection = selection,
      live_usage = { used = 1 },
      provider_status = "ready",
      inference_stats = { generation_tokens_per_second = 40 },
      pending_events = { "previous" },
      steering = steering,
      last_result = { ok = true },
    }
    local notifications = {}
    local activated
    local published = 0
    local updated = 0
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
      activate_workspace = function(cwd) activated = cwd end,
    }
    for key, value in pairs(overrides or {}) do opts[key] = value end
    return lifecycle_module.new(opts), state, notifications, session,
      function() return activated, published, updated end
  end

  it("labels empty messages with stable entry identity", function()
    assert.are.equal("assistant · empty-me", lifecycle_module.entry_label({
      type = "message",
      id = "empty-message-id",
      message = { role = "assistant", content = {} },
    }))
  end)

  it("preserves complete message text in branch labels", function()
    local text = "branch:" .. string.rep(" complete-message-text", 12)
    assert.are.equal("user · " .. text, lifecycle_module.entry_label({
      type = "message",
      id = "complete-message-id",
      message = { role = "user", content = text },
    }))
  end)

  it("initializes the immutable Session in its bound Workspace", function()
    local lifecycle, state, _, session, observed = fixture()

    assert(lifecycle.initialize())

    local activated = observed()
    assert.are.equal("/bound-workspace", activated)
    assert.are.equal(session, state.session)
  end)

  it("changes branches within the owned Session and resets transient state", function()
    local moved
    local lifecycle, state, _, session, observed = fixture()
    session.move_to = function(_, entry_id)
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
    local _, published, updated = observed()
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
    state.activity = { phase = "running" }

    assert.is_nil(lifecycle.branch("entry"))
    assert.matches("cannot change branches", notifications[1].message)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
  end)
end)
