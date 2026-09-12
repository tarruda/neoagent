local assert = require("luassert")
local provider_state = require("neoagent.provider_state")

describe("neoagent provider state", function()
  local function valid()
    return {
      blocks = {
        { type = "status", text = "Router online", level = "success" },
        { type = "field", label = "Endpoint", value = "127.0.0.1:8080",
          level = "success" },
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
    assert(normalized, err and assert(err).message)
    assert.are.same(value.blocks, normalized.blocks)
    assert.are.same(value.operation, normalized.operation)
    value.blocks[2].label = "changed"
    assert.are.equal("Endpoint", rawget(assert(normalized.blocks[2]), "label"))
  end)

  it("accepts minimal snapshots and false", function()
    local normalized = assert(provider_state.normalize({}))
    assert.are.same({}, normalized.blocks)
    assert.is_nil(normalized.operation)
    assert.is_false((provider_state.normalize(false)))
  end)

  it("rejects pre-Service dashboard snapshot fields", function()
    for _, value in ipairs({
      { summary = "Connected" },
      { fields = {} },
      { sections = {} },
      { activity = {} },
    }) do
      local normalized, err = provider_state.normalize(value)
      assert.is_nil(normalized)
      assert.are.equal("provider", assert(err).kind)
      assert.matches("unsupported provider state field", assert(err).message)
    end
  end)

  it("rejects malformed snapshots and block types", function()
    local normalized, err = provider_state.normalize(nil)
    assert.is_nil(normalized)
    assert.are.equal("provider", assert(err).kind)
    for _, value in ipairs({ true, 1, "state" }) do
      normalized, err = provider_state.normalize(value)
      assert.is_nil(normalized)
      assert.are.equal("provider", assert(err).kind)
    end
    normalized, err = provider_state.normalize({
      blocks = { { type = "gauge", label = "Mystery" } },
    })
    assert.is_nil(normalized)
    assert.matches("unknown provider block type", assert(err).message)

  end)

  it("rejects list-shaped blocks and object-shaped item collections", function()
    local normalized, err = provider_state.normalize({
      blocks = { { "status", "Ready" } },
    })
    assert.is_nil(normalized)
    assert.matches("provider block must be an object", assert(err).message)

    normalized, err = provider_state.normalize({
      blocks = { {
        type = "list",
        title = "Models",
        items = { current = { label = "active" } },
      } },
    })
    assert.is_nil(normalized)
    assert.matches("provider list items must be a list", assert(err).message)
  end)

  it("rejects control characters and invalid levels", function()
    local value = valid()
    value.blocks[5].items[1].label = "slot\nforged"
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    value.blocks[1].level = "debug"
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    value.blocks[2].level = "debug"
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    rawset(value.blocks[6].entries[1], "timestamp", math.huge)
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    value.blocks[1].text = ""
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    value.blocks[1].text = string.char(0xff)
    assert.is_nil((provider_state.normalize(value)))
  end)

  it("bounds strings, ratios, and collections", function()
    local value = valid()
    value.blocks[1].text = string.rep("a", 513)
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    value.blocks[3].value = 1.5
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    value.blocks[4].remaining = -0.1
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    rawset(value.blocks[4], "resets_at", math.huge)
    assert.is_nil((provider_state.normalize(value)))

    local oversized = { blocks = {} }
    for _ = 1, 65 do
      oversized.blocks[#oversized.blocks + 1] = { type = "status", text = "ok" }
    end
    assert.is_nil((provider_state.normalize(oversized)))

    value = valid()
    for _ = 2, 101 do
      value.blocks[5].items[#value.blocks[5].items + 1] = { label = "worker" }
    end
    assert.is_nil((provider_state.normalize(value)))

    value = valid()
    for _ = 2, 51 do
      value.blocks[6].entries[#value.blocks[6].entries + 1] = {
        level = "info", message = "event",
      }
    end
    assert.is_nil((provider_state.normalize(value)))
  end)

  it("publishes validated snapshots through a reusable push channel", function()
    local dashboard = provider_state.new({
      blocks = { { type = "status", text = "Connecting", level = "muted" } },
    })
    ---@type Neoagent.ProviderState[]
    local published = {}
    local unsubscribe = dashboard:subscribe(function(snapshot)
      published[#published + 1] = snapshot
    end)
    local pushed, err = dashboard:push(valid())
    assert(pushed, err and assert(err).message)
    assert.are.equal("Router online", rawget(assert(dashboard:state().blocks[1]), "text"))
    assert.are.equal("Router online", rawget(assert(assert(published[1]).blocks[1]), "text"))
    rawset(assert(assert(published[1]).blocks[1]), "text", "changed")
    assert.are.equal("Router online", rawget(assert(dashboard:state().blocks[1]), "text"))

    local rejected = dashboard:push({
      blocks = { { type = "progress", label = "Bad", value = -1 } },
    })
    assert.is_nil(rejected)
    assert.are.equal("Router online", rawget(assert(dashboard:state().blocks[1]), "text"))

    unsubscribe()
    assert(dashboard:push({ blocks = {} }))
    assert.are.equal(1, #published)
    dashboard:destroy()
    assert.are.same({}, dashboard:state().blocks)
  end)

  it("isolates failing push subscribers", function()
    local notifications = {}
    local dashboard = provider_state.new({ blocks = {} }, {
      report = function(message) notifications[#notifications + 1] = message end,
    })
    dashboard:subscribe(function() error("listener boom") end)
    assert(dashboard:push({ blocks = { { type = "status", text = "Ready" } } }))
    assert.are.equal(1, #notifications)
    assert.matches("listener boom", tostring(assert(notifications[1])))
  end)

  it("preserves published state when any dashboard block or operation is invalid", function()
    local dashboard = provider_state.new(valid())
    local retained = dashboard:state()
    local publications = 0
    local unsubscribe = dashboard:subscribe(function() publications = publications + 1 end)
    local invalid = {
      { value = false, error = "provider dashboard state must be an object" },
      { value = { blocks = { named = {} } }, error = "provider blocks must be a list" },
      { value = { operation = false }, error = "provider operation must be an object" },
    }
    ---@type { block: integer, field: string, value: boolean|string|table, error: string }[]
    local block_cases = {
      { block = 1, field = "type", value = false, error = "provider block type" },
      { block = 1, field = "level", value = false, error = "status level" },
      { block = 2, field = "label", value = false, error = "field label" },
      { block = 2, field = "value", value = false, error = "field value" },
      { block = 3, field = "label", value = false, error = "progress label" },
      { block = 3, field = "detail", value = false, error = "progress detail" },
      { block = 3, field = "level", value = "unknown", error = "progress level" },
      { block = 4, field = "label", value = false, error = "limit label" },
      { block = 4, field = "detail", value = false, error = "limit detail" },
      { block = 4, field = "level", value = "unknown", error = "limit level" },
      { block = 5, field = "title", value = false, error = "list title" },
      { block = 5, field = "items", value = { false }, error = "provider list item" },
      { block = 5, field = "items", value = { { label = "worker", detail = false } }, error = "list item detail" },
      { block = 6, field = "title", value = {}, error = "activity title" },
      { block = 6, field = "entries", value = false, error = "provider activity entries" },
      { block = 6, field = "entries", value = { false }, error = "provider activity entry" },
      { block = 6, field = "entries", value = { { message = "Ready", level = "unknown" } }, error = "activity level" },
      { block = 6, field = "entries", value = { { message = false } }, error = "activity message" },
    }
    for _, case in ipairs(block_cases) do
      local snapshot = valid()
      rawset(assert(snapshot.blocks[case.block]), case.field, case.value)
      invalid[#invalid + 1] = { value = snapshot, error = case.error }
    end
    for _, case in ipairs({
      { field = "label", value = false, error = "operation label" },
      { field = "state", value = false, error = "operation state" },
      { field = "message", value = false, error = "operation message" },
      { field = "ratio", value = math.huge, error = "operation ratio" },
      { field = "detail", value = false, error = "operation detail" },
    }) do
      local snapshot = valid()
      rawset(snapshot.operation, case.field, case.value)
      invalid[#invalid + 1] = { value = snapshot, error = case.error }
    end
    for _, case in ipairs(invalid) do
      local accepted, err = dashboard:push(case.value)
      assert.is_nil(accepted)
      assert.are.equal("provider", assert(err).kind)
      assert.matches(case.error, assert(err).message)
      assert.are.same(retained, dashboard:state())
      assert.are.equal(0, publications)
    end
    assert(dashboard:push({ blocks = { { type = "status", text = "Recovered" } } }))
    assert.are.equal(1, publications)
    assert.are.equal("Recovered", rawget(assert(dashboard:state().blocks[1]), "text"))
    unsubscribe()
    unsubscribe()
    dashboard:destroy()
  end)

  it("accepts pushes from provider-owned timers", function()
    local dashboard = provider_state.new({ blocks = {} })
    ---@type Neoagent.ProviderState?
    local published
    dashboard:subscribe(function(snapshot) published = snapshot end)
    local timer = assert(vim.uv.new_timer())
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
    assert.are.equal(0.75, rawget(assert(assert(published).blocks[1]), "value"))
  end)

  it("normalizes progress operations independently", function()
    local normalized, err = provider_state.normalize_operation({
      id = "download",
      label = "Download model",
      state = "running",
      message = "Working",
    })
    assert(normalized, err and assert(err).message)
    assert.is_nil(normalized.ratio)
    assert.is_nil(normalized.detail)
    assert.is_nil((provider_state.normalize_operation(nil)))
    normalized = assert(provider_state.normalize_operation({
      id = "download", label = "Download model", state = "running",
      message = "", detail = "",
    }))
    assert.is_nil(normalized.message)
    assert.is_nil(normalized.detail)
    assert.is_nil((provider_state.normalize_operation({ label = "missing" })))
    assert.is_nil((provider_state.normalize_operation({
      id = "download",
      label = "Download model",
      state = "paused",
    })))
  end)
end)
