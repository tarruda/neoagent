local Steering = require("neoagent.agent.steering")

describe("neoagent Agent steering ownership", function()
  it("offers, acknowledges, claims, and restores records by identity", function()
    local queue = Steering.new()
    local first = queue:enqueue(1, "first", 10)
    local second = queue:enqueue(2, "second", 20)
    assert.are.same({
      id = 1,
      message = { role = "user", content = "first", timestamp = 10 },
    }, first)
    assert.are.same({ "first", "second" }, queue:texts())

    local offered, reject = queue:offer()
    assert.are.same(first, offered)
    assert.are.same(first, reject(false))
    assert.are.same({ "first", "second" }, queue:texts())

    offered, reject = queue:offer()
    assert.are.same(first, offered)
    assert.are.same(first, reject(true))
    assert.is_false(reject(true))
    assert.are.same({ "second" }, queue:texts())

    local claim = assert(queue:claim(second.id))
    assert.are.same(second, claim.record)
    assert.are.same({}, queue:texts())
    assert.is_true(claim:rollback())
    assert.is_false(claim:rollback())
    assert.are.same({ "second" }, queue:texts())

    claim = assert(queue:claim(second.id))
    assert.is_true(claim:commit())
    assert.is_false(claim:rollback())
    assert.are.same({}, queue:texts())
  end)

  it("dequeues copied records and rejects unavailable claims", function()
    local queue = Steering.new()
    queue:enqueue(3, "queued", 30)
    local records = queue:dequeue_all()
    records[1].text = "changed"
    assert.are.same({}, queue:texts())
    local claim, err = queue:claim(3)
    assert.is_nil(claim)
    assert.matches("unavailable", err.message)
  end)

  it("rejects invalid messages without changing the queue", function()
    local queue = Steering.new()
    assert(queue:enqueue(1, "valid", 10))
    for _, values in ipairs({
      { 2, "   ", 20 },
      { 2, "bad\255", 20 },
      { 2, "text", 1.5 },
      { 2, "text", nil },
      { 0, "text", 20 },
      { 1, "duplicate", 20 },
    }) do
      local record, err = queue:enqueue(unpack(values))
      assert.is_nil(record)
      assert.are.equal("steering", err.kind)
      assert.are.same({ "valid" }, queue:texts())
    end
  end)
end)
