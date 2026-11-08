local assert = require("luassert")
local it = require("tests.helpers.async_test")
local async = require("neoagent.async")
local codex = require("neoagent.api.openai_codex_responses")
local fake_transport = require("tests.helpers.fake_transport")
local request_preparation = require("neoagent.api.request_preparation")

---@param token? string
---@param call? string
---@return Neoagent.TestByteResponse
local function response(token, call)
  local output = call
      and {
        {
          type = "function_call",
          id = "fc_" .. call,
          call_id = call,
          name = "inspect",
          arguments = "{}",
        },
      }
    or {
      {
        type = "message",
        id = "msg_reply",
        role = "assistant",
        status = "completed",
        content = { { type = "output_text", text = "Synthetic answer", annotations = {} } },
      },
    }
  return {
    headers = token and { ["X-Codex-Turn-State"] = token } or {},
    chunks = {
      "data: " .. vim.json.encode({
        type = "response.completed",
        response = {
          id = "synthetic-response",
          status = "completed",
          output = output,
        },
      }) .. "\n\n",
    },
  }
end

---@param request Neoagent.HttpRequest
---@param name string
---@return string?
local function header(request, name)
  for key, value in pairs(request.headers or {}) do
    if key:lower() == name then
      return value
    end
  end
  return nil
end

describe("Codex request affinity", function()
  it("budgets the default cache key and permits explicit request overrides", function()
    local transport = fake_transport.new({ response("token"), response("ignored") })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
      request_context = { session_id = "bound-session" },
    })
    local options = { messages = {}, _preparation = request_preparation.new() }
    assert.is_number(model:estimate_request(options))
    local estimated = assert(assert(options._preparation.request).plan.request.body)
    assert.are.equal("bound-session", estimated.prompt_cache_key)
    assert.is_true(model:stream(options):await().ok)
    local custom = {
      messages = {},
      request_opts = {
        headers = { ["Session-Id"] = "custom-session", ["Thread-Id"] = "custom-thread" },
        body = { prompt_cache_key = "custom-key" },
      },
    }
    assert.is_true(model:stream(custom):await().ok)
    local request = assert(transport.requests[2])
    assert.are.equal("custom-session", header(request, "session-id"))
    assert.are.equal("custom-thread", header(request, "thread-id"))
    assert.are.equal("custom-key", vim.json.decode((assert(request.body))).prompt_cache_key)
  end)

  it("bounds cache keys independently of full Session identity at the provider limit", function()
    local prefix = string.rep("s", 64)
    local sessions = { prefix, prefix .. "a", prefix .. "b", string.rep("s", 512) }
    local transport = fake_transport.new()
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
    })
    local keys = {}
    for _, id in ipairs(sessions) do
      local session = assert(require("neoagent.session").new({ id = id }))
      for _ = 1, 2 do
        transport.responses[#transport.responses + 1] = response("synthetic-turn")
        local result = require("neoagent.chat").send(session, "Synthetic prompt", { model = model }):await()
        assert.is_true(result.ok)
        local request = assert(transport.requests[#transport.requests])
        assert.are.equal(id, header(request, "session-id"))
        assert.are.equal(id, header(request, "thread-id"))
        local key = vim.json.decode((assert(request.body))).prompt_cache_key
        assert.is_true(#key <= 64, "prompt_cache_key exceeds the provider's 64-character limit")
        if keys[id] then
          assert.are.equal(keys[id], key)
        end
        keys[id] = key
      end
    end
    assert.are.equal(prefix, keys[prefix])
    assert.are_not.equal(keys[sessions[2]], keys[sessions[3]])
  end)

  it("supports requests without Session identity and rejects unsafe identity before sending", function()
    local transport = fake_transport.new({ response("token") })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
    })
    assert.is_true(model:stream({ messages = {} }):await().ok)
    local request = assert(transport.requests[1])
    assert.is_nil(header(request, "session-id"))
    assert.is_nil(header(request, "thread-id"))
    assert.is_nil(vim.json.decode((assert(request.body))).prompt_cache_key)
    for _, session in ipairs({ "", "unsafe\r\nheader", string.rep("s", 513) }) do
      local result = model:stream({ messages = {}, request_context = { session_id = session } }):await()
      assert.is_false(result.ok)
      assert.matches("session_id", assert(result.error).message)
    end
    assert.are.equal(1, #transport.requests)
  end)

  it("routes a Chat tool loop with one token and starts the next turn without it", function()
    local transport =
      fake_transport.new({ response("first-turn", "inspect-1"), response("ignored-change"), response("next-turn") })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
    })
    local session = assert(require("neoagent.session").new({ id = "synthetic-session" }))
    local options = {
      model = model,
      tools = {
        {
          name = "inspect",
          description = "Inspect synthetic data",
          input_schema = { type = "object", properties = {} },
          execute = function()
            return { content = {} }
          end,
        },
      },
    }
    local first = require("neoagent.chat").run(session, "Inspect", options):await()
    assert.is_true(first.ok)
    assert.is_true(require("neoagent.chat").run(session, "Continue", options):await().ok)
    assert.are.equal(3, #transport.requests)
    for _, request in ipairs(transport.requests) do
      assert.are.equal(session:id(), header(request, "session-id"))
      assert.are.equal(session:id(), header(request, "thread-id"))
      assert.are.equal(session:id(), vim.json.decode((assert(request.body))).prompt_cache_key)
    end
    assert.is_nil(header(assert(transport.requests[1]), "x-codex-turn-state"))
    assert.are.equal("first-turn", header(assert(transport.requests[2]), "x-codex-turn-state"))
    assert.is_nil(header(assert(transport.requests[3]), "x-codex-turn-state"))
  end)

  it("retains routing through request retries and ignores replacement tokens", function()
    local transport = fake_transport.new({
      {
        error = {
          kind = "transport",
          message = "Temporary failure",
          response = { status = 503, headers = { ["x-codex-turn-state"] = "retry-turn" } },
        },
      },
      response("replacement"),
      response("last-value"),
    })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
      sleep = function() end,
    })
    local options = { messages = {}, request_context = { session_id = "retry-session" }, _turn = async.current() }
    assert.is_true(model:stream(options):await().ok)
    assert.is_true(model:stream(options):await().ok)
    assert.is_nil(header(assert(transport.requests[1]), "x-codex-turn-state"))
    assert.are.equal("retry-turn", header(assert(transport.requests[2]), "x-codex-turn-state"))
    assert.are.equal("retry-turn", header(assert(transport.requests[3]), "x-codex-turn-state"))
  end)

  it("does not share routing between standalone Model calls", function()
    local transport = fake_transport.new({ response("first"), response("second") })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
    })
    local options = { messages = {}, request_context = { session_id = "standalone-session" } }
    assert.is_true(model:stream(options):await().ok)
    assert.is_true(model:stream(options):await().ok)
    assert.is_nil(header(assert(transport.requests[2]), "x-codex-turn-state"))
    assert.is_nil(options._turn)
  end)

  it("waits for a usable server token and removes caller-supplied turn state", function()
    local transport = fake_transport.new({
      response(),
      response(""),
      response("unsafe\r\nheader"),
      response(string.rep("t", 8193)),
      response(string.char(255)),
      response("accepted"),
      response("ignored"),
    })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
    })
    for _ = 1, 7 do
      assert.is_true(model
        :stream({
          messages = {},
          _turn = async.current(),
          request_context = { session_id = "synthetic-session" },
          request_opts = { headers = { ["X-Codex-Turn-State"] = "caller-stale-state" } },
        })
        :await().ok)
    end
    for index = 1, 6 do
      assert.is_nil(header(assert(transport.requests[index]), "x-codex-turn-state"))
    end
    assert.are.equal("accepted", header(assert(transport.requests[7]), "x-codex-turn-state"))
  end)

  it("separates sessions and resets routing after an account change within a turn", function()
    local transport = fake_transport.new({
      response("session-a"),
      response("session-b"),
      response("ignored"),
      response("new-owner"),
      response("ignored-again"),
    })
    local account = "synthetic-account-a"
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
      request_opts = function()
        return { headers = { ["chatgpt-account-id"] = account } }
      end,
    })
    ---@async
    ---@param session string
    local function call(session)
      return model
        :stream({ messages = {}, request_context = { session_id = session }, _turn = async.current() })
        :await()
    end
    assert.is_true(call("session-a").ok)
    assert.is_true(call("session-b").ok)
    assert.is_true(call("session-a").ok)
    account = "synthetic-account-b"
    assert.is_true(call("session-a").ok)
    assert.is_true(call("session-a").ok)
    assert.is_nil(header(assert(transport.requests[2]), "x-codex-turn-state"))
    assert.are.equal("session-a", header(assert(transport.requests[3]), "x-codex-turn-state"))
    assert.is_nil(header(assert(transport.requests[4]), "x-codex-turn-state"))
    assert.are.equal("new-owner", header(assert(transport.requests[5]), "x-codex-turn-state"))
  end)

  it("keeps routing on token refresh but resets it on API key and endpoint changes", function()
    local transport = fake_transport.new({
      response("account-token"),
      response("ignored"),
      response("key-token"),
      response("rotated-key-token"),
      response("endpoint-token"),
      response("ignored"),
    })
    local account, key, url = "account", "key-a", "https://example.test/responses"
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
      request_opts = function()
        return { url = url, headers = { ["chatgpt-account-id"] = account, Authorization = "Bearer " .. key } }
      end,
    })
    ---@async
    local function call()
      assert.is_true(model:stream({ messages = {}, _turn = async.current() }):await().ok)
    end
    call()
    key = "key-b"
    call()
    account = ""
    call()
    key = "key-c"
    call()
    url = "https://other.example.test/responses"
    call()
    call()
    assert.are.equal("account-token", header(assert(transport.requests[2]), "x-codex-turn-state"))
    for _, index in ipairs({ 3, 4, 5 }) do
      assert.is_nil(header(assert(transport.requests[index]), "x-codex-turn-state"))
    end
    assert.are.equal("endpoint-token", header(assert(transport.requests[6]), "x-codex-turn-state"))
  end)

  it("uses the same turn for inference, native compaction, and resumed inference", function()
    local compacted = response("ignored-compaction-token")
    table.insert(assert(compacted.chunks), 1, "data: " .. vim.json.encode({
      type = "response.output_item.done",
      item = { type = "compaction", encrypted_content = "synthetic-checkpoint" },
    }) .. "\n\n")
    local transport = fake_transport.new({ response("inference-token"), compacted, response("ignored") })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
    })
    local options = { messages = {}, _turn = async.current(), request_context = { session_id = "same-session" } }
    assert.is_true(model:stream(options):await().ok)
    local result = assert(model.compact)(model, options):await()
    assert.is_true(result.ok)
    assert.is_true(model:stream(options):await().ok)
    assert.are.equal("inference-token", header(assert(transport.requests[2]), "x-codex-turn-state"))
    assert.are.equal("inference-token", header(assert(transport.requests[3]), "x-codex-turn-state"))
    assert.is_nil(result.item and rawget(result.item, "x-codex-turn-state"))
  end)

  it("does not let cached Authentication options retain a finished turn", function()
    local transport = fake_transport.new({ response("first-turn"), response("second-turn") })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
    })
    local manager = require("neoagent.auth").new({
      store = require("tests.helpers.auth_manager").store({ key = { type = "api_key", key = "synthetic-key" } }),
      methods = { key = require("neoagent.auth.api_key").new({ name = "Synthetic key" }) },
    })
    local authenticated = manager:wrap(model, "key")
    local options = {
      messages = {},
      request_context = { session_id = "auth-session" },
      _preparation = request_preparation.new(),
    }
    assert.is_number(assert(authenticated.estimate_request)(authenticated, options))
    for _ = 1, 2 do
      local turn = async.run(function(run)
        options._turn = run
        return authenticated:stream(options):await()
      end)
      assert.is_true(turn:await().ok)
    end
    assert.is_nil(header(assert(transport.requests[2]), "x-codex-turn-state"))
  end)

  it("keeps native reduction retries in the standalone compaction lifetime", function()
    local compacted = response("ignored")
    table.insert(assert(compacted.chunks), 1, "data: " .. vim.json.encode({
      type = "response.output_item.done",
      item = { type = "compaction", encrypted_content = "synthetic-checkpoint" },
    }) .. "\n\n")
    local transport = fake_transport.new({
      {
        status = 400,
        headers = { ["x-codex-turn-state"] = "native-reduction" },
        chunks = {
          vim.json.encode({
            error = { code = "context_length_exceeded", message = "maximum context length exceeded" },
          }),
        },
      },
      compacted,
      compacted,
    })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      context_window = 20000,
      transport = transport,
    })
    ---@type Neoagent.RequestMessage[]
    local messages = {}
    for index = 1, 6 do
      messages[#messages + 1] = { role = "user", content = string.rep("Synthetic history " .. index .. ". ", 100) }
    end
    ---@type Neoagent.NativeCompactionPreparation
    local preparation = {
      kind = "native",
      source_messages = messages,
      request = { messages = messages, request_context = { session_id = "native-session" } },
      retained_users = {},
      tokens_before = 3000,
      settings = require("neoagent.compaction").settings({}),
    }
    local component = require("neoagent.compaction.codex").component
    assert.is_true(component.run({ model = model, preparation = preparation }):await().ok)
    assert.are.equal("native-reduction", header(assert(transport.requests[2]), "x-codex-turn-state"))
    assert.is_true(component.run({ model = model, preparation = preparation }):await().ok)
    assert.is_nil(header(assert(transport.requests[3]), "x-codex-turn-state"))
  end)

  it("shares routing across both generations of a standalone split summary", function()
    local transport = fake_transport.new({ response("summary-turn"), response("ignored") })
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      context_window = 20000,
      transport = transport,
    })
    ---@type Neoagent.CompactionPreparation
    local preparation = {
      kind = "summary",
      messages = { { role = "user", content = "Earlier history" } },
      turn_prefix = { { role = "user", content = "Current turn prefix" } },
      split_turn = true,
      tokens_before = 3000,
      max_output_tokens = 128,
      settings = require("neoagent.compaction").settings({}),
    }
    local result = require("neoagent.compaction.summary")
      .run({
        model = model,
        preparation = preparation,
        model_options = { request_context = { session_id = "summary-session" } },
      })
      :await()
    assert.is_true(result.ok)
    assert.are.equal(2, #transport.requests)
    assert.are.equal("summary-turn", header(assert(transport.requests[2]), "x-codex-turn-state"))
  end)

  it("rejects finished and cancelled borrowed turns before another request", function()
    for _, cancel in ipairs({ false, true }) do
      local transport = fake_transport.new({ response("old-turn"), response("new-turn") })
      local model = codex.new({
        provider = "codex",
        model = "synthetic",
        base_url = "https://example.test",
        transport = transport,
      })
      ---@type fun(value: boolean): boolean
      local release = function()
        error("turn is not waiting")
      end
      local turn = async.run(function()
        async.await(function(done)
          release = done.resolve
        end)
      end)
      local options = { messages = {}, _turn = turn, request_context = { session_id = "same-session" } }
      assert.is_true(model:stream(options):await().ok)
      if cancel then
        turn:cancel()
      else
        release(true)
      end
      turn:await()
      local rejected = model:stream(options):await()
      assert.is_false(rejected.ok)
      assert.matches("turn has finished", assert(rejected.error).message)
      options._turn = async.current()
      assert.is_true(model:stream(options):await().ok)
      assert.are.equal(2, #transport.requests)
      assert.is_nil(header(assert(transport.requests[2]), "x-codex-turn-state"))
    end
  end)

  it("stops before inference if the borrowed turn ends during file preparation", function()
    local turn = async.run(function()
      async.await(function() end)
    end)
    local transport = fake_transport.new()
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
      _images = {
        stream = function(http, plan, dependencies, options)
          turn:cancel()
          return require("neoagent.api.request_stream").send(http, plan, dependencies, options)
        end,
      },
    })
    local result = model:stream({ messages = {}, _turn = turn }):await()
    turn:await()
    assert.is_false(result.ok)
    assert.matches("turn has finished", assert(result.error).message)
    assert.are.same({}, transport.requests)
  end)

  it("ignores an older response after the account owner has changed", function()
    local transport = fake_transport.new({ response("old-owner"), response("new-owner"), response("ignored") })
    local request = assert(transport.request)
    ---@type fun(value: boolean): boolean
    local release = function()
      error("response is not waiting")
    end
    transport.request = function(options)
      local first = #transport.requests == 0
      local child = request(options)
      if not first then
        return child
      end
      return async.run(function()
        async.await(function(done)
          release = done.resolve
        end)
        return child:await()
      end)
    end
    local account = "old-account"
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
      request_opts = function()
        return { headers = { ["chatgpt-account-id"] = account } }
      end,
    })
    local options = { messages = {}, _turn = async.current() }
    local old = model:stream(options)
    account = "new-account"
    assert.is_true(model:stream(options):await().ok)
    release(true)
    assert.is_true(old:await().ok)
    assert.is_true(model:stream(options):await().ok)
    assert.are.equal("new-owner", header(assert(transport.requests[3]), "x-codex-turn-state"))
  end)

  it("isolates overlapping turns on a shared Model and Session", function()
    local transport =
      fake_transport.new({ response("turn-a"), response("turn-b"), response("ignored-b"), response("ignored-a") })
    local request = assert(transport.request)
    ---@type fun(value: boolean): boolean
    local release = function()
      error("response is not waiting")
    end
    transport.request = function(options)
      local first = #transport.requests == 0
      local child = request(options)
      if not first then
        return child
      end
      return async.run(function()
        async.await(function(done)
          release = done.resolve
        end)
        return child:await()
      end)
    end
    local model = codex.new({
      provider = "codex",
      model = "synthetic",
      base_url = "https://example.test",
      transport = transport,
    })
    ---@async
    ---@param run Neoagent.Run<nil, nil>
    local function workflow(run)
      local options = { messages = {}, _turn = run, request_context = { session_id = "shared-session" } }
      assert.is_true(model:stream(options):await().ok)
      assert.is_true(model:stream(options):await().ok)
    end
    local first = async.run(workflow)
    assert.is_true(async.run(workflow):await().ok)
    release(true)
    assert.is_true(first:await().ok)
    assert.is_nil(header(assert(transport.requests[2]), "x-codex-turn-state"))
    assert.are.equal("turn-b", header(assert(transport.requests[3]), "x-codex-turn-state"))
    assert.are.equal("turn-a", header(assert(transport.requests[4]), "x-codex-turn-state"))
  end)
end)
