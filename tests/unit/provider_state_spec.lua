local provider_state = require("neoagent.provider_state")

describe("neoagent provider state", function()
  local function valid()
    return {
      blocks = {
        { type = "status", text = "Router online", level = "success" },
        { type = "field", label = "Endpoint", value = "127.0.0.1:8080" },
        {
          type = "progress",
          label = "Downloading qwen3",
          value = 0.5,
          detail = "4 GiB / 8 GiB",
          level = "info",
        },
        {
          type = "limit",
          label = "Weekly limit",
          remaining = 0.84,
          resets_at = 1787812620,
          detail = "Codex",
          level = "success",
        },
        {
          type = "list",
          title = "Workers",
          items = { { label = "slot 0", detail = "generating" } },
        },
        {
          type = "activity",
          title = "Recent activity",
          entries = { { level = "info", message = "Started", timestamp = 1 } },
        },
      },
      operation = {
        id = "download",
        label = "Download model",
        state = "running",
        message = "Downloading",
        ratio = 0.5,
        detail = "4 GiB / 8 GiB",
      },
    }
  end

  it("normalizes declarative dashboard blocks into bounded copies", function()
    local value = valid()
    local normalized, err = provider_state.normalize(value)
    assert(normalized, err and err.message)
    assert.are.same(value.blocks, normalized.blocks)
    assert.are.same(value.operation, normalized.operation)
    value.blocks[2].label = "changed"
    assert.are.equal("Endpoint", normalized.blocks[2].label)
  end)

  it("accepts minimal snapshots and false", function()
    local normalized = provider_state.normalize({})
    assert.are.same({}, normalized.blocks)
    assert.is_nil(normalized.operation)
    assert.is_false(provider_state.normalize(false))
  end)

  it("adapts the original snapshot shape into dashboard blocks", function()
    local normalized, err = provider_state.normalize({
      summary = "Connected",
      fields = { { label = "Server", value = "localhost" } },
      sections = {
        { title = "Models", rows = { { label = "qwen3", detail = "loaded" } } },
      },
      activity = { { level = "warn", message = "Slow" } },
    })
    assert(normalized, err and err.message)
    assert.are.same({
      { type = "status", text = "Connected", level = "info" },
      { type = "field", label = "Server", value = "localhost" },
      {
        type = "list",
        title = "Models",
        items = { { label = "qwen3", detail = "loaded" } },
      },
      {
        type = "activity",
        title = "Recent activity",
        entries = { { level = "warn", message = "Slow" } },
      },
    }, normalized.blocks)
  end)

  it("rejects malformed snapshots and block types", function()
    for _, value in ipairs({ nil, true, 1, "state" }) do
      local normalized, err = provider_state.normalize(value)
      assert.is_nil(normalized)
      assert.are.equal("provider", err.kind)
    end
    local normalized, err = provider_state.normalize({
      blocks = { { type = "gauge", label = "Mystery" } },
    })
    assert.is_nil(normalized)
    assert.matches("unknown provider block type", err.message)

    for _, value in ipairs({
      { fields = "invalid" },
      { sections = { true } },
      { activity = "invalid" },
    }) do
      local ok, legacy, legacy_err = pcall(provider_state.normalize, value)
      assert.is_true(ok)
      assert.is_nil(legacy)
      assert.are.equal("provider", legacy_err.kind)
    end
  end)

  it("rejects control characters and invalid levels", function()
    local value = valid()
    value.blocks[5].items[1].label = "slot\nforged"
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    value.blocks[1].level = "debug"
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    value.blocks[6].entries[1].timestamp = math.huge
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    value.blocks[1].text = ""
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    value.blocks[1].text = string.char(0xff)
    assert.is_nil(provider_state.normalize(value))
  end)

  it("bounds strings, ratios, and collections", function()
    local value = valid()
    value.blocks[1].text = string.rep("a", 513)
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    value.blocks[3].value = 1.5
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    value.blocks[4].remaining = -0.1
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    value.blocks[4].resets_at = math.huge
    assert.is_nil(provider_state.normalize(value))

    value = { blocks = {} }
    for _ = 1, 65 do
      value.blocks[#value.blocks + 1] = { type = "status", text = "ok" }
    end
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    for _ = 2, 101 do
      value.blocks[5].items[#value.blocks[5].items + 1] = { label = "worker" }
    end
    assert.is_nil(provider_state.normalize(value))

    value = valid()
    for _ = 2, 51 do
      value.blocks[6].entries[#value.blocks[6].entries + 1] = {
        level = "info", message = "event",
      }
    end
    assert.is_nil(provider_state.normalize(value))
  end)

  it("publishes validated snapshots through a reusable push channel", function()
    local dashboard = provider_state.new({
      blocks = { { type = "status", text = "Connecting", level = "muted" } },
    })
    local published = {}
    local unsubscribe = dashboard:subscribe(function(snapshot)
      published[#published + 1] = snapshot
    end)
    local pushed, err = dashboard:push(valid())
    assert(pushed, err and err.message)
    assert.are.equal("Router online", dashboard:state().blocks[1].text)
    assert.are.equal("Router online", published[1].blocks[1].text)
    published[1].blocks[1].text = "changed"
    assert.are.equal("Router online", dashboard:state().blocks[1].text)

    local rejected = dashboard:push({
      blocks = { { type = "progress", label = "Bad", value = -1 } },
    })
    assert.is_nil(rejected)
    assert.are.equal("Router online", dashboard:state().blocks[1].text)

    unsubscribe()
    assert(dashboard:push({ blocks = {} }))
    assert.are.equal(1, #published)
    dashboard:destroy()
    assert.are.same({}, dashboard:state().blocks)
  end)

  it("isolates failing push subscribers", function()
    local dashboard = provider_state.new({})
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message) notifications[#notifications + 1] = message end
    dashboard:subscribe(function() error("listener boom") end)
    assert(dashboard:push({ blocks = { { type = "status", text = "Ready" } } }))
    vim.notify = original_notify
    assert.are.equal(1, #notifications)
    assert.matches("listener boom", notifications[1])
  end)

  it("accepts pushes from provider-owned timers", function()
    local dashboard = provider_state.new({})
    local published
    dashboard:subscribe(function(snapshot) published = snapshot end)
    local timer = vim.uv.new_timer()
    timer:start(1, 0, function()
      timer:stop()
      timer:close()
      dashboard:push({
        blocks = {
          { type = "progress", label = "Download", value = 0.75 },
        },
      })
    end)
    assert(vim.wait(1000, function() return published ~= nil end))
    assert.are.equal(0.75, published.blocks[1].value)
  end)

  it("normalizes progress operations independently", function()
    local normalized, err = provider_state.normalize_operation({
      id = "download",
      label = "Download model",
      state = "running",
      message = "Working",
    })
    assert(normalized, err and err.message)
    assert.is_nil(normalized.ratio)
    assert.is_nil(normalized.detail)
    assert.is_nil(provider_state.normalize_operation({ label = "missing" }))
    assert.is_nil(provider_state.normalize_operation({
      id = "download",
      label = "Download model",
      state = "paused",
    }))
  end)
end)
