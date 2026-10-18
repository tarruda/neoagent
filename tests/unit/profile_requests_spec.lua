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
  it("publishes Codex skill locators and usage guidance as request-only instructions", function()
    local project = require("neoagent.profiles.codex.context").prepare({
      workspace = { root = "/project", cwd = "/project" },
      prompt = "work",
      tools = {},
      agent_instructions = {},
      skills = {
        {
          name = "review",
          description = "Review changes",
          path = "/skills/review/SKILL.md",
          directory = "/skills/review",
          source = "global",
        },
      },
    }, "/bin/bash")
    local history = { { role = "user", content = "review this" } }
    local request = require("neoagent.api.request_preparation").project(project, history, "base", {})
    local developer = assert(request.messages[1])
    assert.are.equal("developer", developer.role)
    local text = util.text_content(developer.content)
    assert.matches("review: Review changes (file: /skills/review/SKILL.md)", text, 1, true)
    assert.matches("How to use skills", text, 1, true)
    assert.matches("open and read its `SKILL.md` completely", text, 1, true)
    assert.are.same({ { role = "user", content = "review this" } }, history)
  end)
  it("attributes every Codex instruction source in broad-to-specific order", function()
    local files = {
      { path = "/home/example/global.md", content = "GLOBAL: see ./global-guide.md" },
      { path = "/project/AGENTS.md", content = "REPOSITORY: see ./root-guide.md" },
      { path = '/project/nested/quoted & "scope"/AGENTS.md', content = "NESTED: see ./local-guide.md" },
    }
    local project = require("neoagent.profiles.codex.context").prepare({
      workspace = { root = "/project", cwd = "/project/nested" },
      prompt = "work",
      tools = {},
      skills = {},
      agent_instructions = files,
    }, "/bin/bash")
    local request = require("neoagent.api.request_preparation").project(project, {}, "base", {})
    local message = assert(request.messages[1])
    assert.are.equal("userContext", message.role)
    local context = util.text_content(message.content)
    local position = 1
    for _, file in ipairs(files) do
      local path = file.path:gsub("&", "&amp;"):gsub('"', "&quot;")
      local first, last = context:find('<project_instructions path="' .. path .. '">', position, true)
      assert(first, "missing instruction origin: " .. file.path)
      local close = context:find("</project_instructions>", assert(last), true)
      assert(close)
      assert.matches(file.content, context:sub(assert(last) + 1, close - 1), 1, true)
      position = close + 1
    end
    assert.matches("broadest to most specific", context, 1, true)
  end)

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

  it("advertises and projects image detail using the selected Model capability", function()
    local fake = require("tests.helpers.fake_model")
    local target = fake.new({ { result = fake.assistant({ { type = "text", text = "done" } }) } })
    target.input = { "text", "image" }
    local tool = require("neoagent.tools.codex.view_image").new()
    assert(require("neoagent.agent_loop")
      .run({
        model = target,
        messages = { { role = "user", content = "work" } },
        tools = { tool },
        commit_message = function()
          return true
        end,
      })
      :await().ok)
    local definition = assert(assert(assert(target.requests[1]).tools)[1])
    assert.are.same({ "high" }, assert(assert(definition.input_schema.properties).detail).enum)
    local history = {
      {
        role = "user",
        content = {
          {
            type = "image",
            file_id = string.rep("a", 64),
            bytes = 4,
            mime_type = "image/png",
            detail = "original",
          },
        },
      },
    }
    local projected = require("neoagent.api.messages").for_model(history, target)
    local message = assert(projected[1])
    assert(message.role == "user" and type(message.content) == "table")
    local image = assert(message.content[1])
    assert(image.type == "image")
    assert.are.equal("high", image.detail)
    target.supports_image_detail_original = true
    projected = require("neoagent.api.messages").for_model(history, target)
    message = assert(projected[1])
    assert(message.role == "user" and type(message.content) == "table")
    image = assert(message.content[1])
    assert(image.type == "image")
    assert.are.equal("original", image.detail)
    assert.are.equal("original", history[1].content[1].detail)
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

  it("keeps trusted Profile context intact during bounded native reduction", function()
    local target = model(fake_transport.new({}))
    local profile = require("neoagent.profiles.codex.context").prepare({
      workspace = { root = vim.fn.getcwd(), cwd = vim.fn.getcwd() },
      prompt = "work",
      tools = {},
      skills = {},
      agent_instructions = { { path = "AGENTS.md", content = string.rep("trusted instructions ", 300) } },
    }, vim.o.shell)
    local call =
      assert(profile({ messages = { { role = "user", content = string.rep("history ", 2000) } }, tools = {} }))
    local trusted = util.copy(call.messages[1])
    local reduced, err = require("neoagent.compaction.reduction").request(target, {
      messages = call.messages,
      system_prompt = call.system_prompt,
    }, 2500, true, "compact")
    assert(reduced, err and err.message)
    assert.are.same(trusted, reduced[1])
    assert.matches("truncated for compaction", util.text_content(reduced[#reduced].content))
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

  it("replays a rejected freeform call as valid wire history", function()
    local tool = require("neoagent.tools.codex.apply_patch").new()
    local decoder = require("neoagent.api.openai_responses.decoder").new(
      require("tests.helpers.fake_model").new(),
      function() end,
      { tool }
    )
    decoder.process({
      type = "response.completed",
      response = {
        status = "completed",
        output = {
          { type = "custom_tool_call", id = "ct1", call_id = "call1", name = "apply_patch", input = "bad\255input" },
        },
      },
    })
    local transport = fake_transport.new({
      {
        chunks = {
          event({ type = "response.completed", response = { status = "completed", output = { answer } } }),
        },
      },
    })
    assert(model(transport)
      :stream({
        messages = {
          decoder.message,
          {
            role = "toolResult",
            toolCallId = "call1|ct1",
            toolName = "apply_patch",
            isError = true,
            content = { { type = "text", text = "Invalid input" } },
          },
        },
        tools = { tool },
      })
      :await().ok)
    local body = vim.json.decode((assert(assert(transport.requests[1]).body)))
    assert.are.equal("string", type(body.input[1].input))
    assert.are.equal("custom_tool_call_output", body.input[2].type)
  end)

  it("streams canonical patch arguments and replays custom calls without accumulating context", function()
    local root = vim.fn.tempname()
    assert(require("neoagent.fs").mkdirp(root))
    local patch = "*** Begin Patch\n*** Add File: result.txt\n+published\n*** End Patch"
    local tool = require("neoagent.tools.codex.apply_patch").new()
    local custom = { type = "custom_tool_call", id = "ct1", call_id = "call1", name = "apply_patch", input = patch }
    local transport = fake_transport.new({
      {
        chunks = {
          event({
            type = "response.output_item.added",
            output_index = 0,
            item = { type = "custom_tool_call", id = "ct1", call_id = "call1", name = "apply_patch", input = "" },
          }),
          event({ type = "response.custom_tool_call_input.delta", output_index = 0, delta = patch:sub(1, 20) }),
          event({ type = "response.custom_tool_call_input.done", output_index = 0, input = patch }),
          event({ type = "response.completed", response = { status = "completed", output = { custom } } }),
        },
      },
      { chunks = { event({ type = "response.completed", response = { status = "completed", output = { answer } } }) } },
    })
    local prompt = require("neoagent.profiles.codex.prompt").prepare({
      workspace = { root = root, cwd = root },
      prompt = "work",
      tools = { tool },
      agent_instructions = {},
      skills = {},
      base_prompt = "Instructions",
      execution_guidance = "Host execution is enabled",
    })
    ---@type Neoagent.Message[]
    local committed = {}
    local result = require("neoagent.agent_loop")
      .run({
        model = model(transport),
        messages = { { role = "user", content = "work" } },
        tools = { tool },
        context = { workspace = { root = root, cwd = root } },
        system_prompt = prompt.system_prompt,
        prepare_request = prompt.prepare_request,
        commit_message = function(message)
          committed[#committed + 1] = message
          return true
        end,
      })
      :await()
    local output = require("neoagent.fs").read(root .. "/result.txt")
    vim.fn.delete(root, "rf")
    assert.is_true(result.ok, vim.inspect(result))
    assert.are.equal("published\n", output)
    assert.are.equal(3, #committed)
    local assistant = committed[1]
    assert(assistant and assistant.role == "assistant")
    local call = assistant.content[1]
    assert(call and call.type == "toolCall")
    assert.are.same({ patch = patch }, call.arguments)
    assert.are.equal("patch", call.text_input)
    local first = vim.json.decode((assert(assert(transport.requests[1]).body)))
    local second = vim.json.decode((assert(assert(transport.requests[2]).body)))
    assert.are.equal("custom", first.tools[1].type)
    assert.are.equal("grammar", first.tools[1].format.type)
    assert.are.equal("developer", first.input[2].role)
    assert.matches("environment_context", first.input[3].content[1].text)
    assert.are.equal(1, #vim.tbl_filter(function(message)
      return message.role == "developer"
    end, second.input))
    local calls = vim.tbl_filter(function(message)
      return message.type == "custom_tool_call"
    end, second.input)
    assert.are.equal(patch, calls[1].input)
    assert.are.equal("custom_tool_call_output", second.input[#second.input].type)
    local fallback = fake_transport.new({
      { chunks = { event({ type = "response.completed", response = { status = "completed", output = { answer } } }) } },
    })
    local replay =
      model(fallback, false):stream({ messages = { committed[1], committed[2] }, tools = { tool } }):await()
    assert.is_true(replay.ok)
    local json = vim.json.decode((assert(assert(fallback.requests[1]).body)))
    assert.are.equal("function", json.tools[1].type)
    assert.are.equal("function_call", json.input[1].type)
    assert.are.same({ patch = patch }, vim.json.decode(json.input[1].arguments))
    assert.are.equal("function_call_output", json.input[2].type)
    assert.are.equal("patch", call.text_input)
  end)

  it("turns malformed text input into a Tool error before execution", function()
    local tool = require("neoagent.tools.codex.apply_patch").new()
    local decoder = require("neoagent.api.openai_responses.decoder").new(
      require("tests.helpers.fake_model").new(),
      function() end,
      { tool }
    )
    decoder.process({
      type = "response.completed",
      response = {
        status = "completed",
        output = {
          { type = "custom_tool_call", id = "ct1", call_id = "call1", name = "apply_patch", input = "bad\255input" },
        },
      },
    })
    local called = false
    tool.execute = function()
      called = true
      error("invalid patch executed")
    end
    local fake = require("tests.helpers.fake_model")
    local result = require("neoagent.agent_loop")
      .run({
        model = fake.new({
          { result = { ok = true, message = decoder.message, text = "" } },
          { result = fake.assistant({ { type = "text", text = "done" } }) },
        }),
        messages = {},
        tools = { tool },
        commit_message = function()
          return true
        end,
      })
      :await()
    assert(result.ok)
    assert.is_false(called)
    local error_message = result.new_messages[2]
    assert(error_message and error_message.role == "toolResult")
    assert.are.equal("toolResult", error_message.role)
    assert.is_true(error_message.isError)
    assert.matches("UTF%-8", util.text_content(error_message.content))
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
