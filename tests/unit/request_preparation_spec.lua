local it = require("tests.helpers.async_test")
local assert = require("luassert")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function finish(run)
  assert(vim.wait(1000, function()
    return run:is_done()
  end))
  return (assert(run:result()))
end

describe("neoagent.request_preparation", function()
  it("revalidates callable API keys after estimation without repeating unchanged shaping", function()
    for _, api in ipairs({ "openai_completions", "openai_responses", "anthropic_messages" }) do
      ---@type string?
      local key = "synthetic-before"
      local shaped = 0
      local model = require("neoagent.api." .. api).new({
        provider = "test", model = "test", base_url = "https://example.test", api_key = function() return key end,
        request_opts = function() shaped = shaped + 1 return {} end,
      })
      local call = { messages = {}, _preparation = require("neoagent.api.request_preparation").new() }
      model:estimate_request(call)
      key = "synthetic-after"
      local prepared = model:_request(call)
      local field = api == "anthropic_messages" and "x-api-key" or "Authorization"
      local prefix = api == "anthropic_messages" and "" or "Bearer "
      assert.are.equal(prefix .. "synthetic-after", assert(prepared.request.headers)[field])
      model:_request(call)
      assert.are.equal(2, shaped)
      key = nil
      local cleared = model:_request(call)
      assert.is_nil(assert(cleared.request.headers)[field])
      assert.are.equal(3, shaped)
    end
  end)

  it("blocks semantically changed requests after callable key rotation", function()
    for _, api in ipairs({ "openai_completions", "openai_responses", "anthropic_messages" }) do
      local key = "synthetic-before"
      local transport = require("tests.helpers.fake_transport").new()
      local model = require("neoagent.api." .. api).new({
        provider = "test", model = "test", base_url = "https://example.test", transport = transport,
        api_key = function() return key end,
        request_opts = function(context)
          return { messages = key == "synthetic-before" and context.messages
            or { { role = "user", content = string.rep("unbudgeted", 2000) } } }
        end,
      })
      local call = { messages = { { role = "user", content = "Budgeted" } },
        _preparation = require("neoagent.api.request_preparation").new() }
      model:estimate_request(call)
      key = "synthetic-after"
      local result = finish(model:stream(call))
      assert.is_false(result.ok)
      assert.are.equal("stale_request_preparation", assert(result.error).code)
      assert.are.equal(0, #transport.requests)
    end
  end)

  it("allows refreshed credentials when the estimated request content is unchanged", function()
    local transport = require("tests.helpers.fake_transport").new({ { chunks = {
      'data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}\n\n',
      'data: [DONE]\n\n',
    } } })
    local store = require("tests.helpers.auth_manager").store({ key = { type = "api_key", key = "synthetic-before" } })
    local manager = require("neoagent.auth").new({
      methods = { key = require("neoagent.auth.api_key").new({ name = "Synthetic key" }) }, store = store,
    })
    local model = manager:wrap(require("neoagent.api.openai_completions").new({
      provider = "test", model = "test", base_url = "https://example.test", transport = transport,
    }), "key")
    local call = { messages = { { role = "user", content = "Budgeted" } },
      _preparation = require("neoagent.api.request_preparation").new() }
    assert(model.estimate_request)(model, call)
    assert(store:write("key", { type = "api_key", key = "synthetic-after" }))
    assert.is_true(finish(model:stream(call)).ok)
    assert.are.equal("Bearer synthetic-after", rawget(assert(assert(transport.requests[1]).headers), "Authorization"))
    assert.are.equal("Budgeted", vim.json.decode((assert(assert(transport.requests[1]).body))).messages[1].content)
  end)

  it("requires fresh budgeting after Authentication changes request content", function()
    local transport = require("tests.helpers.fake_transport").new({ { chunks = {
      'data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}\n\n',
      'data: [DONE]\n\n',
    } } })
    local store = require("tests.helpers.auth_manager").store({ key = { type = "api_key", key = "synthetic-before" } })
    local manager = require("neoagent.auth").new({
      methods = { key = require("neoagent.auth.api_key").new({ name = "Synthetic key",
        request_opts = function(credential)
          return { headers = { Authorization = "Bearer " .. credential.key },
            messages = { { role = "user", content = credential.key == "synthetic-before" and "Short"
              or string.rep("New authenticated instructions. ", 1000) } } }
        end,
      }) }, store = store,
    })
    local model = manager:wrap(require("neoagent.api.openai_completions").new({
      provider = "test", model = "test", base_url = "https://example.test", transport = transport,
    }), "key")
    local call = { messages = {}, _preparation = require("neoagent.api.request_preparation").new() }
    local before = assert(model.estimate_request)(model, call)
    assert(store:write("key", { type = "api_key", key = "synthetic-after" }))
    local result = finish(model:stream(call))
    assert.is_false(result.ok)
    assert.are.equal("stale_request_preparation", assert(result.error).code)
    assert.are.equal(0, #transport.requests)
    assert.is_true(assert(model.estimate_request)(model, call) > before)
    assert.is_true(finish(model:stream(call)).ok)
    assert.are.equal(1, #transport.requests)
  end)

  it("executes the same shaped request that the gate estimated", function()
    local shaped = 0
    local transport = require("tests.helpers.fake_transport").new({
      {
        chunks = {
          'data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}\n\n',
          "data: [DONE]\n\n",
        },
      },
    })
    local model = require("neoagent.api.openai_completions").new({
      provider = "test",
      model = "test",
      base_url = "https://example.test",
      transport = transport,
      request_opts = function(context)
        shaped = shaped + 1
        return { body = { metadata = { preparation = shaped } }, messages = context.messages }
      end,
    })
    local manager = require("neoagent.auth").new({
      methods = {
        key = require("neoagent.auth.api_key").new({
          name = "Synthetic key",
          request_opts = function()
            return { headers = { Authorization = "Bearer synthetic" } }
          end,
        }),
      },
      store = require("tests.helpers.auth_manager").store({ key = { type = "api_key", key = "synthetic" } }),
    })
    model = manager:wrap(model, "key")
    local run = require("neoagent.agent_loop").run({
      model = model,
      messages = { { role = "user", content = "Continue" } },
      tools = {},
      execute_tool = function()
        error("Unexpected Tool")
      end,
      commit_message = function()
        return true
      end,
      prepare_request_messages = function(messages, options)
        local call = assert(options)
        call.messages = messages
        require("neoagent.api.request_estimate").request(model, call)
        return messages
      end,
    })
    assert(vim.wait(1000, function()
      return run:is_done()
    end))
    assert.is_true(assert(run:result()).ok)
    assert.are.equal(1, shaped)
    local body = vim.json.decode((assert(assert(transport.requests[1]).body)))
    assert.are.equal(1, body.metadata.preparation)
  end)

  it("rejects an unbudgeted replacement returned by the gate", function()
    local shaped = 0
    local transport = require("tests.helpers.fake_transport").new({
      {
        chunks = {
          'data: {"choices":[{"delta":{"content":"Done"},"finish_reason":"stop"}]}\n\n',
          "data: [DONE]\n\n",
        },
      },
    })
    local model = require("neoagent.api.openai_completions").new({
      provider = "test",
      model = "test",
      base_url = "https://example.test",
      transport = transport,
      request_opts = function(context)
        shaped = shaped + 1
        return { messages = context.messages }
      end,
    })
    local run = require("neoagent.agent_loop").run({
      model = model,
      messages = { { role = "user", content = "Original" } },
      tools = {},
      commit_message = function()
        return true
      end,
      execute_tool = function()
        error("Unexpected Tool")
      end,
      prepare_request_messages = function(_, options)
        require("neoagent.api.request_estimate").request(model, options)
        return { { role = "user", content = "Replacement checkpoint" } }
      end,
    })
    assert(vim.wait(1000, function()
      return run:is_done()
    end))
    assert.is_false(assert(run:result()).ok)
    assert.are.equal("stale_request_preparation", assert(assert(run:result()).error).code)
    assert.are.equal(2, shaped)
    assert.are.equal(0, #transport.requests)
  end)

  it("revalidates Authentication before executing a prepared request", function()
    local transport = require("tests.helpers.fake_transport").new({
      {
        chunks = {
          'data: {"choices":[{"delta":{"content":"Unexpected"},"finish_reason":"stop"}]}\n\n',
          "data: [DONE]\n\n",
        },
      },
    })
    local manager = require("neoagent.auth").new({
      methods = { key = require("neoagent.auth.api_key").new({ name = "Synthetic key" }) },
      store = require("tests.helpers.auth_manager").store({ key = { type = "api_key", key = "synthetic" } }),
    })
    local model = manager:wrap(
      require("neoagent.api.openai_completions").new({
        provider = "test",
        model = "test",
        base_url = "https://example.test",
        transport = transport,
      }),
      "key"
    )
    local run = require("neoagent.agent_loop").run({
      model = model,
      messages = { { role = "user", content = "Continue" } },
      tools = {},
      commit_message = function()
        return true
      end,
      execute_tool = function()
        error("Unexpected Tool")
      end,
      prepare_request_messages = function(messages, options)
        require("neoagent.api.request_estimate").request(model, options)
        assert.is_true(manager:logout("key"):await().ok)
        return messages
      end,
    })
    assert(vim.wait(1000, function()
      return run:is_done()
    end))
    assert.is_false(assert(run:result()).ok)
    assert.are.equal(0, #transport.requests)
  end)
end)
