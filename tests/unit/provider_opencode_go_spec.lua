local assert = require("luassert")
local async = require("neoagent.async")
local config = require("neoagent.config")
local fake_transport = require("tests.helpers.fake_transport")
local model_api = require("neoagent.models")
local opencode_go = require("neoagent.providers.opencode_go")
local provider_runtimes = require("neoagent.provider_runtimes")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function block(snapshot, block_type, label)
  for _, candidate in ipairs(snapshot.blocks or {}) do
    if candidate.type == block_type
        and (label == nil or candidate.label == label
          or candidate.title == label) then
      return candidate
    end
  end
end

local function resolve_auth()
  return async.run(function()
    return {
      ok = true,
      configured = true,
      credential_type = "api_key",
      request_opts = { headers = {
        Authorization = "Bearer stored-key",
        ["x-api-key"] = "stored-key",
      } },
    }
  end)
end

local function operation(service, id, interact)
  return provider_service.run(service, id, {
    resolve_auth = resolve_auth,
    interact = interact,
  })
end

describe("OpenCode Go provider service", function()
  it("loads shared quotas through refresh", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ usage = {
      rolling = {
        status = "ok", percent = 50,
        resetsAt = "2026-08-20T17:30:00.000Z",
      },
      weekly = {
        status = "ok", percent = 75,
        resetsAt = "2026-08-24T00:00:00.000Z",
      },
      monthly = {
        status = "ok", percent = 10,
        resetsAt = "2026-09-03T12:00:00.000Z",
      },
    } }) } }
    local service = opencode_go.new({
      base_url = "https://example.test/zen/go/v1",
    }, { transport = transport })

    assert.are.equal("opencode-go", service.id)
    assert.are.equal("OpenCode Go", service.name)
    assert.are.same({ "refresh" }, vim.tbl_keys(service.operations))
    local progress
    local interact = provider_service.no_interact()
    interact.progress = function(value) progress = value end
    local result = wait(operation(service, "refresh", interact))
    assert.is_true(result.ok)
    assert.are.same({
      id = "refresh",
      label = "Refresh usage",
      state = "running",
      message = "Loading OpenCode Go usage",
    }, progress)
    local snapshot = service:state()
    assert.are.equal("Shared across all Go models",
      block(snapshot, "field", "Quota scope").value)
    assert.are.equal(0.5,
      block(snapshot, "limit", "5-hour limit").remaining)
    assert.are.equal("≈ $6.00 of $12 allowance remaining",
      block(snapshot, "limit", "5-hour limit").detail)
    assert.are.equal(0.25,
      block(snapshot, "limit", "Weekly limit").remaining)
    assert.are.equal(0.9,
      block(snapshot, "limit", "Monthly limit").remaining)
    assert.are.equal(1, #transport.fetch_requests)
  end)

  it("keeps prior quotas visible across refresh failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ usage = {
        rolling = { status = "ok", percent = 20,
          resetsAt = "2026-08-20T17:30:00.000Z" },
        weekly = { status = "ok", percent = 30,
          resetsAt = "2026-08-24T00:00:00.000Z" },
        monthly = { status = "ok", percent = 40,
          resetsAt = "2026-09-03T12:00:00.000Z" },
      } }) },
      { status = 429, body = "rate limited body" },
    }
    local service = opencode_go.new({
      base_url = "https://example.test/v1",
    }, { transport = transport })
    assert.is_true(wait(operation(service, "refresh")).ok)
    local result = wait(operation(service, "refresh"))
    assert.is_false(result.ok)
    local snapshot = service:state()
    assert.are.equal(0.8,
      block(snapshot, "limit", "5-hour limit").remaining)
    assert.matches("refresh failed", block(snapshot, "status").text)
    assert.is_nil(vim.inspect(snapshot):find("rate limited body", 1, true))
    assert.is_nil(vim.inspect(snapshot):find("stored-key", 1, true))
  end)

  it("publishes exhausted windows and destroys its state", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ usage = {
      rolling = { status = "rate-limited", percent = 100,
        resetsAt = "2026-08-20T17:30:00.000Z" },
      weekly = { status = "ok", percent = 1,
        resetsAt = "2026-08-24T00:00:00.000Z" },
      monthly = { status = "ok", percent = 2,
        resetsAt = "2026-09-03T12:00:00.000Z" },
    } }) } }
    local service = opencode_go.new({
      base_url = "https://example.test/v1",
    }, { transport = transport })
    local published
    local unsubscribe = service:subscribe(function(value) published = value end)
    assert.is_true(wait(operation(service, "refresh")).ok)
    assert.are.equal("A Go usage window is exhausted",
      block(service:state(), "status").text)
    assert.are.equal("error",
      block(service:state(), "limit", "5-hour limit").level)
    assert.is_table(published)
    unsubscribe()
    service:destroy()
    assert.are.same({}, service:state().blocks)
  end)

  it("rejects invalid service configuration", function()
    assert.has_error(function()
      opencode_go.new({ service_opts = { unsupported = 1 } })
    end)
    assert.has_error(function()
      opencode_go.new({ service_opts = { timeout_ms = 0 } })
    end)
  end)
end)

local function event(value)
  return "data: " .. vim.json.encode(value) .. "\n\n"
end

local function message_event(value)
  return "event: " .. value.type .. "\ndata: " .. vim.json.encode(value)
    .. "\n\n"
end

-- One complete stream per request API Go routes models through.
local streams = {
  ["openai-completions"] = {
    event({ choices = { { delta = { content = "ok" },
      finish_reason = "stop" } } }),
    "data: [DONE]\n\n",
  },
  ["openai-responses"] = {
    event({ type = "response.created", response = { id = "resp_1" } }),
    event({ type = "response.completed", response = {
      status = "completed", output = util.list(),
    } }),
  },
  ["anthropic-messages"] = {
    message_event({ type = "message_start", message = {
      id = "msg_1", type = "message", role = "assistant", content = {},
      model = "minimax-m3", stop_reason = vim.NIL,
      usage = { input_tokens = 2, output_tokens = 0 },
    } }),
    message_event({ type = "content_block_start", index = 0,
      content_block = { type = "text", text = "" } }),
    message_event({ type = "content_block_delta", index = 0,
      delta = { type = "text_delta", text = "ok" } }),
    message_event({ type = "content_block_stop", index = 0 }),
    message_event({ type = "message_delta",
      delta = { stop_reason = "end_turn", stop_sequence = vim.NIL },
      usage = { output_tokens = 1 } }),
    message_event({ type = "message_stop" }),
  },
}

describe("OpenCode Go conversation attribution", function()
  local runtimes
  local original_key
  local recorder
  local directories = {}

  before_each(function()
    config.setup({})
    original_key = vim.env.OPENCODE_API_KEY
    vim.env.OPENCODE_API_KEY = "go-key"
  end)

  after_each(function()
    if runtimes then provider_runtimes.destroy(runtimes) end
    runtimes = nil
    if recorder then recorder:destroy() end
    recorder = nil
    for _, directory in ipairs(directories) do
      vim.fn.delete(directory, "rf")
    end
    directories = {}
    vim.env.OPENCODE_API_KEY = original_key
    config._reset()
  end)

  -- Resolves a seeded Go model through the real provider definition,
  -- Authentication, API adapter, and transport, then returns the sent request.
  local function sent_request(model_id, api, request_context)
    local transport = fake_transport.new({
      { chunks = assert(streams[api], api) },
    })
    if runtimes then provider_runtimes.destroy(runtimes) end
    local composed, err = provider_runtimes.compose(config.get(), {
      startup = false, transport = transport,
    })
    assert(composed, err and err.message)
    runtimes = composed
    local model = model_api.resolve("opencode-go", model_id, config.get(),
      nil, runtimes, request_context)
    local result = wait(model:stream({ messages = { { role = "user", content = {
      { type = "text", text = "hi" },
    } } } }))
    assert.is_true(result.ok)
    assert.are.equal(1, #transport.requests)
    return transport.requests[1]
  end

  it("attributes each Session conversation across Go request APIs", function()
    for _, case in ipairs({
      { id = "glm-5.3", api = "openai-completions",
        path = "https://opencode.ai/zen/go/v1/chat/completions" },
      { id = "grok-4.6", api = "openai-responses",
        path = "https://opencode.ai/zen/go/v1/responses" },
      { id = "minimax-m3", api = "anthropic-messages",
        path = "https://opencode.ai/zen/go/v1/messages" },
    }) do
      local request = sent_request(case.id, case.api,
        { session_id = "session-7" })
      assert.are.equal(case.path, request.url)
      assert.are.equal("session-7", request.headers["x-opencode-session"])
    end
  end)

  it("omits attribution when the composition has no Session", function()
    local request = sent_request("glm-5.3", "openai-completions")
    assert.is_nil(request.headers["x-opencode-session"])
    request = sent_request("glm-5.3", "openai-completions", {
      workspace = "/workspace", session_id = "unsafe\r\nvalue",
    })
    assert.is_nil(request.headers["x-opencode-session"])
  end)

  it("attributes standalone chat calls across Go request APIs", function()
    local chat = require("neoagent.chat")
    local Session = require("neoagent.session")
    for _, case in ipairs({
      { id = "glm-5.3", api = "openai-completions" },
      { id = "grok-4.6", api = "openai-responses" },
      { id = "minimax-m3", api = "anthropic-messages" },
    }) do
      local transport = fake_transport.new({
        { chunks = streams[case.api] },
        { chunks = streams[case.api] },
        { chunks = streams[case.api] },
      })
      if runtimes then provider_runtimes.destroy(runtimes) end
      runtimes = assert(provider_runtimes.compose(config.get(), {
        startup = false, transport = transport,
      }))
      local model = model_api.resolve("opencode-go", case.id, config.get(),
        nil, runtimes)
      for index, method in ipairs({ "send", "run", "continue" }) do
        local session = assert(Session.new())
        local opts = { model = model }
        local run = method == "continue" and chat.continue(session, opts)
          or chat[method](session, "hello", opts)
        assert.is_true(wait(run).ok)
        assert.are.equal(session:id(),
          transport.requests[index].headers["x-opencode-session"])
      end
    end
  end)

  it("keeps Session headers and rolling recordings isolated on shared runtimes", function()
    local chat = require("neoagent.chat")
    local Session = require("neoagent.session")
    local directory, workspace = vim.fn.tempname(), vim.fn.tempname()
    directories = { directory, workspace }
    vim.fn.mkdir(workspace, "p")
    recorder = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json", retention = "rolling" },
      directory = directory,
    }))
    local transport = fake_transport.new({
      { chunks = streams["openai-completions"] },
      { chunks = streams["openai-completions"] },
      { chunks = streams["openai-completions"] },
    })
    runtimes = assert(provider_runtimes.compose(config.get(), {
      startup = false, transport = recorder:transport(transport),
    }))
    local sessions = { assert(Session.new()), assert(Session.new()) }
    local bound = model_api.resolve("opencode-go", "glm-5.3", config.get(),
      nil, runtimes, { workspace = workspace, session_id = sessions[1]:id() })
    local unbound = model_api.resolve("opencode-go", "glm-5.3", config.get(),
      nil, runtimes, { workspace = workspace })
    for index, selected in ipairs({ 1, 2, 1 }) do
      assert.is_true(wait(chat.send(sessions[selected], "turn " .. index, {
        model = selected == 1 and bound or unbound,
      })).ok)
      assert.are.equal(sessions[selected]:id(),
        transport.requests[index].headers["x-opencode-session"])
    end
    local paths = vim.fn.globpath(directory, "**/*.jsonl", false, true)
    assert.are.equal(2, #paths)
    local recorded = {}
    for _, path in ipairs(paths) do
      local exchange = vim.json.decode(vim.fn.readfile(path)[1])
      local id = exchange.context.session_id
      assert.is_true(vim.fs.basename(vim.fs.dirname(path)):sub(-#id) == id)
      assert.are.equal("*", exchange.request.headers["x-opencode-session"])
      local body = vim.json.decode(exchange.request.body)
      recorded[id] = body.messages[#body.messages].content
    end
    assert.are.same({
      [sessions[1]:id()] = "turn 3",
      [sessions[2]:id()] = "turn 2",
    }, recorded)
  end)

  it("rejects conflicting bound identity before sending a request", function()
    for _, case in ipairs({
      { id = "glm-5.3", api = "openai-completions" },
      { id = "grok-4.6", api = "openai-responses" },
      { id = "minimax-m3", api = "anthropic-messages" },
    }) do
      local transport = fake_transport.new({ { chunks = streams[case.api] } })
      if runtimes then provider_runtimes.destroy(runtimes) end
      runtimes = assert(provider_runtimes.compose(config.get(), {
        startup = false, transport = transport,
      }))
      local model = model_api.resolve("opencode-go", case.id, config.get(),
        nil, runtimes, { session_id = "bound-session" })
      local result = wait(model:stream({ messages = {},
        request_context = { session_id = "another-session" },
      }))
      assert.is_false(result.ok)
      assert.are.equal("request_context conflicts with Model identity",
        result.error.message)
      assert.are.equal(0, #transport.requests)
    end
  end)
end)
