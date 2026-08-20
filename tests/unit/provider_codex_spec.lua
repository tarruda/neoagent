local codex = require("neoagent.providers.codex")

describe("neoagent Codex provider service", function()
  local function block(snapshot, block_type, label)
    for _, candidate in ipairs(snapshot.blocks or {}) do
      if candidate.type == block_type
          and (label == nil or candidate.label == label) then
        return candidate
      end
    end
  end

  it("parses response rate limits into progress meters", function()
    assert.are.same({
      { type = "progress", label = "Plan window", value = 0.84, detail = "84% left" },
      { type = "progress", label = "Rolling window", value = 0.6, detail = "60% left" },
    }, codex.parse_limits("weekly 84% left · 5h 60% left"))
    assert.are.same({
      { type = "progress", label = "custom window", value = 0.12, detail = "12% left" },
    }, codex.parse_limits("custom 12% left"))
    assert.are.same({}, codex.parse_limits("Reconnecting… 2/3"))
  end)

  it("pushes quota meters and connection state from provider events", function()
    local service = codex.new({ base_url = "https://chatgpt.com/backend-api" })
    assert.are.equal("openai-codex", service.id)
    assert.are.equal("Codex", service.name)
    assert.are.same({}, service.operations)
    assert.are.same({
      type = "status", text = "Awaiting first response", level = "muted",
    }, service:state().blocks[1])

    local initial, err = require("neoagent.provider_state").normalize(service:state())
    assert(initial, err and err.message)
    assert.are.equal("Awaiting first response", initial.blocks[1].text)

    local published
    local unsubscribe = service:subscribe(function(snapshot)
      published = snapshot
    end)
    service:on_event({
      type = "provider_status",
      text = "weekly 84% left · 5h 60% left",
    })

    local snapshot = service:state()
    assert.are.same({
      type = "status", text = "Usage updated", level = "success",
    }, snapshot.blocks[1])
    assert.are.equal(0.84, block(snapshot, "progress", "Plan window").value)
    assert.are.equal(0.6, block(snapshot, "progress", "Rolling window").value)
    assert.are.equal(0.84, block(published, "progress", "Plan window").value)
    snapshot.blocks[2].value = 0
    assert.are.equal(0.84,
      block(service:state(), "progress", "Plan window").value)

    service:on_event({ type = "provider_status", text = "Reconnecting… 1/3" })
    snapshot = service:state()
    assert.are.same({
      type = "status", text = "Reconnecting… 1/3", level = "warn",
    }, snapshot.blocks[1])
    assert.are.equal(0.84, block(snapshot, "progress", "Plan window").value)

    unsubscribe()
    service:on_event({ type = "provider_status", text = "weekly 50% left" })
    assert.are.equal("Reconnecting… 1/3", published.blocks[1].text)

    service:destroy()
    assert.are.same({}, service:state().blocks)
  end)

  it("pushes request token usage without polling", function()
    local service = codex.new()
    local publications = 0
    service:subscribe(function() publications = publications + 1 end)
    service:on_event({
      type = "usage",
      usage = { inputTokens = 1250, outputTokens = 87, totalTokens = 1337 },
    })
    local snapshot = service:state()
    assert.are.equal("Last response", snapshot.blocks[2].label)
    assert.are.equal("1,250 in · 87 out", snapshot.blocks[2].value)
    assert.are.equal(1, publications)
  end)

  it("ignores events without usable status or usage", function()
    local service = codex.new()
    service:on_event({ type = "usage" })
    service:on_event({ type = "provider_status" })
    assert.are.equal("Awaiting first response", service:state().blocks[1].text)
  end)

  it("reports provider status that exceeds dashboard bounds", function()
    local service = codex.new()
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message) notifications[#notifications + 1] = message end
    service:on_event({
      type = "provider_status",
      text = string.rep("x", 513),
    })
    vim.notify = original_notify
    assert.are.equal(1, #notifications)
    assert.matches("Codex dashboard failed", notifications[1])
    assert.are.equal("Awaiting first response", service:state().blocks[1].text)
  end)
end)
