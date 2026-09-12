local assert = require("luassert")
local fs = require("neoagent.fs")
local http_replay = require("tests.helpers.http_replay")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param path string
---@return Neoagent.RecordedEvent[]
local function records(path)
  local result = {}
  for line in assert(fs.read(path)):gmatch("[^\n]+") do
    result[#result + 1] = vim.json.decode(line)
  end
  return result
end

describe("HTTP recording integration", function()
  ---@type string[]
  local directories = {}
  ---@type Neoagent.TestHttpReplay[]
  local scenarios = {}
  local native_open, native_write, native_close, native_rename =
    vim.uv.fs_open, vim.uv.fs_write, vim.uv.fs_close, vim.uv.fs_rename
  local native_system = vim.system
  ---@type vim.SystemObj[]
  local converters = {}
  ---@type Neoagent.Recorder[]
  local recorders = {}

  after_each(function()
    vim.uv.fs_open, vim.uv.fs_write, vim.uv.fs_close, vim.uv.fs_rename =
      native_open, native_write, native_close, native_rename
    vim.system = native_system
    for _, recorder in ipairs(recorders) do recorder:destroy() end
    for _, process in ipairs(converters) do process:wait(5000) end
    for _, scenario in ipairs(scenarios) do http_replay.finish(scenario) end
    for _, path in ipairs(directories) do vim.fn.delete(path, "rf") end
    scenarios, directories, converters, recorders = {}, {}, {}, {}
  end)

  for _, failure in ipairs({ "write", "close", "rename" }) do
    it("preserves decoded inference across a native YAML conversion " .. failure .. " failure", function()
      local directory = vim.fn.tempname()
      directories[#directories + 1] = directory
      local exchange = require("neoagent.http_replay").read("tests/recordings/openai/stream-01.yaml")
      -- Exercise conversion spooling with a large synthetic request while
      -- preserving the captured provider response and protocol structure.
      local prompt = string.rep("synthetic context ", 65536)
      local request = vim.json.decode((assert(exchange.request.body)))
      request.messages[1].content = prompt
      exchange.request.body = vim.json.encode(request)
      local scenario = http_replay.open({ { exchange = exchange, headers_subset = true } })
      scenarios[#scenarios + 1] = scenario
      local reports = {}
      local recorder = assert(require("neoagent.http_recording").new({
        config = { enabled = true, format = "yaml" }, directory = directory,
        report = function(message) reports[#reports + 1] = message end,
      }))
      recorders[#recorders + 1] = recorder
      local failed, spool, closes = false, nil, 0
      vim.system = function(command, options, done)
        local process = native_system(command, options, done)
        if command[1] == "yq" and command[2] ~= "--version" then converters[#converters + 1] = process end
        return process
      end
      vim.uv.fs_open = function(path, flags, mode)
        local fd, err = native_open(path, flags, mode)
        if path:sub(-10) == ".yaml.body" then spool = fd end
        return fd, err
      end
      vim.uv.fs_write = function(fd, data, offset)
        if failure == "write" and fd == spool and not failed then
          failed = true
          return nil, "native YAML write EIO"
        end
        return native_write(fd, data, offset)
      end
      vim.uv.fs_close = function(fd)
        local closed, err = native_close(fd)
        if fd == spool then
          closes = closes + 1
          if failure == "close" and not failed then
            failed = true
            return nil, "native YAML close EIO"
          end
        end
        return closed, err
      end
      vim.uv.fs_rename = function(source, target)
        if failure == "rename" and source:sub(-10) == ".yaml.body" and not failed then
          failed = true
          return nil, "native YAML rename EIO"
        end
        return native_rename(source, target)
      end
      local model = require("neoagent.api.openai_completions").new({
        provider = "mock", model = "test-model", base_url = scenario.url .. "/v1", api_key = "test-key",
        transport = recorder:transport(scenario, { provider = "mock", origin = "model" }),
      })
      local result = wait(model:stream({ messages = { { role = "user", content = prompt } } }))
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.equal("Hello", result.text)
      recorder:destroy()
      for _, process in ipairs(converters) do process:wait(5000) end
      assert.is_true(failed)
      assert.are.equal(1, closes)
      assert.are.equal(1, #converters)
      assert.are.equal(0, #vim.fn.globpath(directory, "**/*.yaml", false, true))
      local retained = vim.fn.globpath(directory, "**/*.partial.ndjson", false, true)
      assert.are.equal(1, #retained)
      local events = records(assert(retained[1]))
      assert.are.equal("complete", events[#events].type)
      assert.matches(failure == "write" and "failed to convert" or "failed to write YAML", table.concat(reports, "\n"))
    end)
  end

  for _, event in ipairs({ "response", "complete" }) do
    it("keeps inference usable after a native recording " .. event .. " append failure", function()
      local directory = vim.fn.tempname()
      directories[#directories + 1] = directory
      local scenario = http_replay.open({
        { path = "tests/recordings/openai/stream-01.yaml", headers_subset = true },
        { path = "tests/recordings/openai/stream-01.yaml", headers_subset = true },
      })
      scenarios[#scenarios + 1] = scenario
      local recorder = assert(require("neoagent.http_recording").new({
        config = { enabled = true, format = "json" }, directory = directory,
      }))
      recorders[#recorders + 1] = recorder
      local failed = false
      vim.uv.fs_write = function(fd, data, offset)
        if not failed and type(data) == "string" and data:find('"type"%s*:%s*"' .. event .. '"') then
          failed = true
          return nil, "native recording append EIO"
        end
        return native_write(fd, data, offset)
      end
      local model = require("neoagent.api.openai_completions").new({
        provider = "mock", model = "test-model", base_url = scenario.url .. "/v1", api_key = "test-key",
        transport = recorder:transport(scenario, { provider = "mock", origin = "model" }),
      })
      for _ = 1, 2 do
        local result = wait(model:stream({ messages = { { role = "user", content = "Hello" } } }))
        assert.is_true(result.ok, vim.inspect(result.error))
        assert.are.equal("Hello", result.text)
      end
      recorder:destroy()
      assert.is_true(failed)
      assert.are.equal(1, #vim.fn.globpath(directory, "**/*.partial.ndjson", false, true))
      local final = vim.fn.globpath(directory, "**/*.jsonl", false, true)
      assert.are.equal(1, #final)
      local recorded = require("neoagent.http_replay").read(assert(final[1]))
      assert.are.equal("complete", recorded.terminal.type)
      assert.is_true(recorded.terminal.ok)
    end)
  end

  it("records a replayed model stream after provider decoding", function()
    local directory = vim.fn.tempname()
    local workspace = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    assert.are.equal(1, vim.fn.mkdir(workspace, "p"))
    directory = assert(vim.uv.fs_realpath(directory))
    workspace = assert(vim.uv.fs_realpath(workspace))
    directories[#directories + 1] = directory
    directories[#directories + 1] = workspace
    local scenario = http_replay.open({
      { path = "tests/recordings/openai/stream-01.yaml", body_subset = false, headers_subset = true },
    })
    scenarios[#scenarios + 1] = scenario
    local recorder = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
    }))
    local transport = recorder:transport(
      scenario, {
        workspace = workspace,
        provider = "mock",
        model = "test-model",
        origin = "model",
        agent_id = "agent-integration",
        session_id = "session-integration",
      })
    local model = require("neoagent.api.openai_completions").new({
      provider = "mock",
      model = "test-model",
      base_url = scenario.url .. "/v1",
      api_key = "test-key",
      transport = transport,
    })

    local result = wait(model:stream({
      messages = { { role = "user", content = "Hello" } },
    }))
    assert(result.ok, vim.inspect(result))
    assert.are.equal("Hello", result.text)
    recorder:destroy()

    local paths = vim.fn.globpath(directory, "**/*.jsonl", false, true)
    assert.are.equal(1, #paths)
    local content = assert(fs.read(paths[1]))
    assert.is_nil((content:find("test-key", 1, true)))
    assert.matches('"session_id":"session%-integration"', content)
    assert.matches('"status":200', content)
    assert.matches('"type":"response_chunk"', content)
    assert.matches('"type":"response_body"', content)
    assert.matches("Hel", content)
    assert.matches("lo", content)
    assert.matches('"type":"complete"', content)
  end)

  it("replaces a real OAuth credential response classified by its adapter", function()
    local directory = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    directory = assert(vim.uv.fs_realpath(directory))
    directories[#directories + 1] = directory
    local scenario = http_replay.open({
      { path = "tests/recordings/openai/codex_oauth-01.yaml", body_subset = true, headers_subset = true },
    })
    scenarios[#scenarios + 1] = scenario
    local recorder = assert(require("neoagent.http_recording").new({
      config = { enabled = true, format = "json" },
      directory = directory,
    }))
    local http = recorder:transport(scenario, {
      origin = "authentication",
      auth_method = "openai-codex",
    })
    local method = require("neoagent.auth.openai_codex").new({
      auth_base_url = scenario.url,
      http = http,
      start_callback_server = function()
        return {
          port = 1455,
          wait = function() return "integration-code" end,
          close = function() return true end,
        }
      end,
    })

    local result = wait(method.login({
      prompt = function(prompt, done)
        assert.are.equal("select", prompt.type)
        done.resolve("browser")
      end,
      notify = function(event)
        assert.are.equal("auth_url", event.type)
      end,
    }))
    assert(result.ok)
    recorder:destroy()

    local paths = vim.fn.globpath(directory, "**/*.jsonl", false, true)
    assert.are.equal(1, #paths)
    assert.matches("/provider/recordings/openai%-codex/", paths[1])
    local content = assert(fs.read(paths[1]))
    assert.is_nil((content:find("integration-refresh", 1, true)))
    assert.is_nil((content:find("integration-code", 1, true)))
    local parsed = records(paths[1])
    local exchange = assert(parsed[1])
    assert(exchange.type == "exchange")
    local response = assert(parsed[3])
    assert(response.type == "response_body")
    assert.is_nil(exchange.workspace)
    assert.are.equal("authentication", assert(exchange.context).origin)
    assert.are.equal("openai-codex", assert(exchange.context).auth_method)
    assert.matches("client_id=%*", tostring(exchange.request.body))
    assert.matches("code=%*", tostring(exchange.request.body))
    assert.matches("code_verifier=%*", tostring(exchange.request.body))
    assert.are.equal("*", response.body)
    assert.is_true(response.redacted)
  end)
end)
