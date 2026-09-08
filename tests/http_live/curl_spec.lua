local assert = require("luassert")
local curl = require("neoagent.transport.curl")
local http = require("neoagent.transport.http")
---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(2000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe("real curl HTTP backend", function()
  ---@type { url: string, close: fun() }
  local server
  local original = vim.system
  ---@type string[]
  local paths = {}
  ---@type vim.SystemObj[]
  local processes = {}
  before_each(function()
    server = require("tests.helpers.http_live").start()
    original, paths, processes = vim.system, {}, {}
    vim.system = function(command, opts, done)
      if command[1] == "curl" then
        for index, arg in ipairs(command) do
          if arg == "--dump-header" then paths[#paths + 1] = assert(command[index + 1]) end
        end
      end
      local process = original(command, opts, done)
      processes[#processes + 1] = process
      return process
    end
  end)
  after_each(function()
    vim.system = original
    server.close()
    for _, process in ipairs(processes) do process:kill(15); process:wait(2000) end
    for _, path in ipairs(paths) do assert.is_nil(vim.uv.fs_stat(path)) end
  end)

  it("parses final headers and status without consuming a body status suffix", function()
    local result = wait(curl.fetch({ request = { url = server.url .. "/headers", method = "GET" } }))
    assert(result.ok)
    assert.are.equal(200, result.status)
    assert.are.equal("first\n200", result.body)
    assert.are.equal("final", result.headers["x-request-id"])
    assert.are.equal("last", result.headers["x-duplicate"])
    assert.is_nil(result.headers["x-transient"])
  end)

  it("retains non-2xx bodies and distinguishes a connection failure", function()
    local result = wait(http.new().stream({
      request = { url = server.url .. "/error", method = "GET" },
      on_event = function() error("HTTP error delivered as an SSE event") end,
    }))
    assert(result.ok)
    assert.are.equal(429, result.status)
    assert.are.equal("limited", assert(assert(result.body).error).message)
    assert.are.equal("final", result.headers["x-request-id"])
    local disconnected = wait(curl.request({ request = { url = server.url .. "/disconnect", method = "GET" } }))
    assert.is_false(disconnected.ok)
    assert.are.equal("transport", assert(disconnected.error).kind)
    assert.is_number(rawget(assert(disconnected.error), "exit_code"))
    assert.is_string(rawget(assert(disconnected.error), "stderr"))
  end)

  it("delivers SSE before EOF and cancels the process and temporary files", function()
    ---@type Neoagent.JsonValue[]
    local received = {}
    local run = http.new().stream({
      request = { url = server.url .. "/stream", method = "GET" },
      on_event = function(event) received[#received + 1] = event end,
    })
    assert(vim.wait(1000, function() return #received == 1 end))
    assert.is_false(run:is_done())
    run:cancel()
    assert.are.equal("cancelled", assert(wait(run).error).kind)
    assert.are.same({ { value = 1 } }, received)
    assert(vim.wait(1000, function() return vim.uv.fs_stat((assert(paths[1]))) == nil end))
  end)

  it("bounds a fetched body while the process is running", function()
    local result = wait(curl.fetch({ request = {
      url = server.url .. "/large", method = "GET", max_response_bytes = 64,
    } }))
    assert.is_false(result.ok)
    assert.matches("exceeds 64 bytes", assert(result.error).message)
  end)
end)
