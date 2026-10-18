local assert = require("luassert")
local it = require("tests.helpers.async_test")
local fake_transport = require("tests.helpers.fake_transport")
local responses = require("neoagent.api.openai_responses")
local util = require("neoagent.util")

---@param value Neoagent.JsonObject
---@return string
local function event(value)
  return "data: " .. vim.json.encode(value) .. "\n\n"
end

local answer = {
  type = "message",
  id = "answer",
  role = "assistant",
  status = "completed",
  content = { { type = "output_text", text = "done" } },
}

---@param transport Neoagent.ByteBackend
---@param custom_tools? boolean
---@return Neoagent.ResponsesModel
local function model(transport, custom_tools)
  return responses.new({
    provider = "test",
    model = "test",
    base_url = "https://example.test",
    transport = transport,
    custom_tools = custom_tools,
  })
end

describe("Profile request context and freeform Tools", function()
  it("encodes projected image detail in Completions user and Tool images", function()
    local fixture = require("tests.helpers.attachments").new()
    local image = fixture.image("synthetic image bytes", "image/png")
    image.detail = "original"
    local history = {
      { role = "user", content = { image } },
      { role = "assistant", content = { { type = "toolCall", id = "read1", name = "read", arguments = {} } } },
      { role = "toolResult", toolCallId = "read1", content = { image } },
    }
    local target = require("neoagent.api.openai_completions").new({
      provider = "test", model = "test", base_url = "https://example.test", input = { "text", "image" },
    })
    local projected = require("neoagent.api.messages").for_model(history, target)
    local plan = target:_request({ messages = projected })
    local body = plan.encode(require("neoagent.api.images").inline(plan.api, fixture.files))
    local user = assert(body.messages[1].content)
    local tool = assert(body.messages[4].content)
    assert(type(user) == "table" and type(tool) == "table")
    local expected = { url = "data:image/png;base64," .. vim.base64.encode("synthetic image bytes"), detail = "high" }
    assert.are.same(expected, assert(user[1]).image_url)
    assert.are.same(expected, assert(tool[2]).image_url)
    assert.are.equal("original", image.detail)
  end)

  it("rebuilds a projected request when steering arrives during preparation", function()
    local fake = require("tests.helpers.fake_model")
    local target = fake.new({ { result = fake.assistant({ { type = "text", text = "done" } }) } })
    local steering, projected = {}, 0
    assert(require("neoagent.agent_loop").run({ model = target,
      messages = { { role = "user", content = "work" } },
      get_steering_messages = function()
        local pending = steering
        steering = {}
        return pending
      end,
      prepare_request = function(request)
        projected = projected + 1
        if projected == 1 then
          steering[1] = { role = "user", content = "latest direction" }
          require("neoagent.async").yield()
        end
        return { messages = request.messages, system_prompt = "snapshot" }
      end,
      commit_message = function() return true end,
    }):await().ok)
    assert.are.equal(2, projected)
    local request = assert(target.requests[1])
    assert.are.equal("latest direction", assert(request.messages[2]).content)
  end)

  it("reuses the projected candidate validated by the request owner", function()
    local transport = fake_transport.new({
      {
        chunks = {
          event({ type = "response.completed", response = { status = "completed", output = { answer } } }),
        },
      },
    })
    local target = model(transport)
    local preparation = require("neoagent.api.request_preparation")
    local projections = 0
    local function project(request)
      projections = projections + 1
      return { messages = request.messages, system_prompt = "snapshot " .. projections }
    end
    local result = require("neoagent.agent_loop")
      .run({
        model = target,
        messages = { { role = "user", content = "work" } },
        prepare_request = project,
        commit_message = function()
          return true
        end,
        prepare_request_messages = function(messages, call)
          local candidate =
            preparation.project(project, messages, call.system_prompt, call.tools or {}, call.files, call._preparation)
          call.messages, call.system_prompt = candidate.messages, candidate.system_prompt
          target:estimate_request(call)
          return messages
        end,
      })
      :await()
    assert.is_true(result.ok, vim.inspect(result))
    assert.are.equal(1, projections)
    assert.are.equal("snapshot 1", vim.json.decode((assert(assert(transport.requests[1]).body))).input[1].content)
  end)

  it("budgets the final projection without a compaction owner", function()
    local transport = fake_transport.new({
      {
        chunks = {
          event({ type = "response.completed", response = { status = "completed", output = { answer } } }),
        },
      },
    })
    ---@type Neoagent.Model
    local target = model(transport)
    local estimate = assert(target.estimate_request)
    local estimates = 0
    target.estimate_request = function(self, call, operation)
      estimates = estimates + 1
      return estimate(self, call, operation)
    end
    assert(require("neoagent.agent_loop")
      .run({
        model = target,
        messages = { { role = "user", content = "work" } },
        commit_message = function()
          return true
        end,
        prepare_request = function(request)
          return { messages = request.messages, system_prompt = "trusted snapshot" }
        end,
      })
      :await().ok)
    assert.are.equal(1, estimates)
  end)

  it("budgets request-only instructions through Responses", function()
    local target = model(fake_transport.new({}))
    local baseline = target:estimate_request({ messages = { { role = "user", content = "work" } } })
    local projected = target:estimate_request({
      messages = {
        { role = "system", content = string.rep("s", 4000) },
        { role = "developer", content = string.rep("d", 4000) },
        { role = "user", content = "work" },
      },
    })
    assert.is_true(projected >= baseline + 2000)
  end)

  it("encodes ephemeral instruction roles through each API", function()
    local messages = {
      { role = "system", content = "request system" },
      { role = "developer", content = "request developer" },
      { role = "user", content = "conversation" },
    }
    local choices = {
      {
        chunks = {
          'data: {"choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
        },
      },
    }
    local completion = fake_transport.new(choices)
    assert(
      require("neoagent.api.openai_completions")
        .new({ provider = "test", model = "test", base_url = "https://example.test", transport = completion })
        :stream({ messages = messages, system_prompt = "base" })
        :await().ok
    )
    local completion_body = vim.json.decode((assert(assert(completion.requests[1]).body)))
    assert.are.same(
      { "system", "system", "developer", "user" },
      vim.tbl_map(function(message)
        return message.role
      end, completion_body.messages)
    )
    local response = fake_transport.new({
      { chunks = { event({ type = "response.completed", response = { status = "completed", output = { answer } } }) } },
    })
    assert(model(response):stream({ messages = messages, system_prompt = "base" }):await().ok)
    local response_body = vim.json.decode((assert(assert(response.requests[1]).body)))
    assert.are.same(
      { "system", "system", "developer", "user" },
      vim.tbl_map(function(message)
        return message.role
      end, response_body.input)
    )
    local anthropic = fake_transport.new({
      {
        chunks = {
          event({ type = "message_start", message = { id = "m", role = "assistant", usage = {} } }),
          event({ type = "content_block_start", index = 0, content_block = { type = "text", text = "done" } }),
          event({ type = "content_block_stop", index = 0 }),
          event({ type = "message_delta", delta = { stop_reason = "end_turn" }, usage = {} }),
          event({ type = "message_stop" }),
        },
      },
    })
    assert(
      require("neoagent.api.anthropic_messages")
        .new({ provider = "test", model = "test", base_url = "https://example.test", transport = anthropic })
        :stream({ messages = messages, system_prompt = "base" })
        :await().ok
    )
    local anthropic_body = vim.json.decode((assert(assert(anthropic.requests[1]).body)))
    assert.matches("base", vim.inspect(anthropic_body.system))
    assert.matches("request system", vim.inspect(anthropic_body.system))
    assert.matches("request developer", vim.inspect(anthropic_body.system))
    assert.are.equal(1, #anthropic_body.messages)
    assert.are.equal("user", anthropic_body.messages[1].role)
    assert.are.same("request system", messages[1].content)
    assert.is_nil(require("neoagent.semantic_message").normalize(messages[1]))
  end)
end)
