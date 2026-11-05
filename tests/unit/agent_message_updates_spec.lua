local assert = require("luassert")
local fake = require("tests.helpers.fake_model")

describe("Agent tool message updates", function()
  ---@type Neoagent.Agent?
  local agent
  after_each(function()
    if agent then
      agent:destroy()
    end
    agent = nil
  end)

  ---@param model Neoagent.TestModel
  ---@param tools Neoagent.Tool<Neoagent.AgentToolEnvironment>[]
  ---@return Neoagent.Agent
  local function create(model, tools)
    return require("neoagent").new({
      default_registry = false,
      workspace_trust = false,
      persistence = { enabled = false },
      sandbox = { enabled = false },
      compaction = false,
      agent_instructions = false,
      skills = false,
      tools = tools,
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake", models = { test = {} } } },
      _apis = {
        fake = function()
          return model
        end,
      },
    })
  end

  it("restores the plan once and applies newly committed messages without full history snapshots", function()
    local plan = { plan = { { step = "Keep the accepted plan", status = "in_progress" } } }
    local model = fake.new({
      {
        result = fake.assistant(
          { { type = "toolCall", id = "plan", name = "update_plan", arguments = plan } },
          "toolUse"
        ),
      },
      { result = fake.assistant({ { type = "text", text = "Updated" } }) },
    })
    local tool = require("neoagent.tools.update_plan").new()
    local full_updates = 0
    local on_messages = tool.on_messages
    assert(type(on_messages) == "function")
    tool.on_messages = function(messages, ctx)
      full_updates = full_updates + 1
      return on_messages(messages, ctx)
    end
    agent = create(model, { tool })
    local run = assert(agent:send("Update the plan"))
    assert(type(run) == "table")
    assert(vim.wait(3000, function()
      return run:is_done()
    end))
    assert.is_true(assert(run:result()).ok)
    local selected = agent:get_toolset().tools[1]
    assert(type(selected) == "table")
    local context = { session_id = agent:get_session():identity(), files = agent:get_session():files() }
    assert.are.same(plan, assert(selected.current)(context))
    agent:snapshot()
    agent:snapshot()
    assert.are.equal(1, full_updates, "ordinary message updates rebuilt the plan from the full history")
    assert(agent:get_session():move_to(nil))
    agent:snapshot()
    assert.is_nil(assert(selected.current)(context))
    assert.are.equal(2, full_updates)
  end)

  it("isolates copied updates and restores a failed incremental hook from committed history", function()
    local restores, appends = {}, {}
    local fail = false
    local tool = {
      name = "observe",
      description = "",
      input_schema = { type = "object", properties = {} },
      execute = function()
        return { content = {} }
      end,
      on_messages = function(messages)
        restores[#restores + 1] = #messages
        if messages[1] then
          messages[1].content = "changed by observer"
        end
      end,
      on_message = function(message)
        appends[#appends + 1] = message.content
        message.content = "changed by observer"
        if fail then
          error("observer failed")
        end
      end,
    }
    agent = create(fake.new({}), { tool })
    agent:snapshot()
    local session = agent:get_session()
    assert(session:append({ role = "user", content = "first" }))
    agent:snapshot()
    agent:snapshot()
    assert.are.same({ 0 }, restores)
    assert.are.same({ "first" }, appends)
    fail = true
    assert(session:append({ role = "user", content = "second" }))
    agent:snapshot()
    fail = false
    agent:snapshot()
    assert.are.same({ 0, 2 }, restores)
    assert.are.same({ "first", "second" }, appends)
    assert.are.equal("first", assert(session:messages()[1]).content)
    assert.are.equal("second", assert(session:messages()[2]).content)
  end)

  it("keeps full-snapshot hooks current without reading history when there are no observers", function()
    local snapshots = {}
    local tool = {
      name = "observe",
      description = "",
      input_schema = { type = "object", properties = {} },
      execute = function()
        return { content = {} }
      end,
      on_messages = function(messages)
        snapshots[#snapshots + 1] = #messages
      end,
    }
    agent = create(fake.new({}), { tool })
    agent:snapshot()
    assert(agent:get_session():append({ role = "user", content = "one" }))
    agent:snapshot()
    agent:snapshot()
    assert.are.same({ 0, 1 }, snapshots)
    agent:destroy()
    agent = create(fake.new({}), {})
    local session = agent:get_session()
    local reads = 0
    session.messages = function()
      reads = reads + 1
      return {}
    end
    agent:snapshot()
    assert.are.equal(0, reads)
  end)
end)
