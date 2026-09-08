local assert = require("luassert")
local curl = require("neoagent.transport.curl")
local util = require("neoagent.util")
local bit = require("bit")

describe("neoagent.transport.curl", function()
  it("bounds stderr and reports stream read failures", function()
    local original_system = vim.system
    local function result()
      local run = curl.request({ request = { url = "http://localhost", body = "{}" } })
      assert(vim.wait(1000, function() return run:is_done() end))
      return run:result()
    end

    vim.system = function(_, options, on_exit)
      options.stderr(nil, string.rep("x", 70 * 1024))
      on_exit({ code = 1 })
      return { kill = function() end }
    end
    local requested = result()
    assert.is_false(requested.ok)
    assert.is_true(#requested.error.detail <= util.MAX_ERROR_STRING_CHARACTERS + 3)

    vim.system = function(_, options, on_exit)
      options.stderr("stderr read failed")
      on_exit({ code = 1 })
      return { kill = function() end }
    end
    requested = result()
    assert.matches("stderr read failed", requested.error.detail)

    vim.system = function(_, options, on_exit)
      options.stdout("stdout read failed")
      on_exit({ code = 1 })
      return { kill = function() end }
    end
    requested = result()
    vim.system = original_system
    assert.matches("Failed reading curl stdout", requested.error.message)
  end)

  it("builds an argument vector without a shell", function()
    assert.are.same({
      "curl", "--no-buffer", "--silent", "--show-error",
      "-X", "POST", "-H", "Authorization: Bearer x", "-H",
      "Content-Type: application/json", "http://localhost",
    }, curl.command({
      url = "http://localhost",
      headers = { ["Content-Type"] = "application/json", Authorization = "Bearer x" },
    }))
    local fetch_command = (function()
      local original_system = vim.system
      local commands = {}
      vim.system = function(command) commands[1] = command return { kill = function() end } end
      local run = curl.fetch({
        request = { url = "http://localhost", method = "GET", timeout_ms = 1500 },
      })
      assert.are.equal(384, bit.band(
        assert(vim.uv.fs_stat(commands[1][7])).mode, 511))
      run:cancel()
      assert(vim.wait(1000, function() return run:is_done() end))
      vim.system = original_system
      return commands[1]
    end)()
    assert.are.same({
      "curl", "--silent", "--show-error", "-X", "GET", "--dump-header",
    }, vim.list_slice(fetch_command, 1, 6))
    assert.is_string(fetch_command[7])
    assert.are.same({
      "--max-time", "1.500", "--write-out", "\n%{http_code}",
      "http://localhost",
    }, vim.list_slice(fetch_command, 8))
    assert.are.same({
      "curl", "--no-buffer", "--silent", "--show-error",
      "-X", "GET", "--max-time", "1.500", "http://localhost",
    }, curl.command({ url = "http://localhost", method = "GET", timeout_ms = 1500 }))
  end)

  it("bounds fetched response bodies while curl is running", function()
    local original_system = vim.system
    local function result(maximum, send)
      vim.system = function(command, options, on_exit)
        send(options, on_exit, command)
        return { kill = function() end }
      end
      local run = curl.fetch({ request = {
        url = "http://localhost",
        method = "GET",
        max_response_bytes = maximum,
      } })
      assert(vim.wait(1000, function() return run:is_done() end))
      return run:result()
    end

    local fetched = result(2, function(options, on_exit, command)
      assert.are.equal(384, bit.band(
        assert(vim.uv.fs_stat(command[7])).mode, 511))
      vim.fn.writefile({
        "HTTP/1.1 200 OK",
        "Content-Type: application/json",
        "X-Request-Id: req-1",
        "",
      }, command[7], "b")
      options.stdout(nil, "{}\n200")
      on_exit({ code = 0 })
    end)
    assert.is_true(fetched.ok)
    assert.are.equal("{}", fetched.body)
    assert.are.equal(200, fetched.status)
    assert.are.same({
      ["content-type"] = "application/json",
      ["x-request-id"] = "req-1",
    }, fetched.headers)

    fetched = result(2, function(options, on_exit)
      options.stdout(nil, "too-large\n200")
      on_exit({ code = 15 })
    end)
    assert.is_false(fetched.ok)
    assert.matches("exceeds 2 bytes", fetched.error.message)

    fetched = result(2, function(options, on_exit)
      options.stdout("read failed")
      on_exit({ code = 15 })
    end)
    assert.is_false(fetched.ok)
    assert.matches("Failed reading curl stdout", fetched.error.message)

    fetched = result(-1, function() end)
    vim.system = original_system
    assert.is_false(fetched.ok)
    assert.matches("max_response_bytes", fetched.error.message)
  end)
end)

describe("curl process boundary", function()
  local original, create_temp, files
  before_each(function()
    original, create_temp, files = vim.system, require("neoagent.fs").create_temp, {}
  end)
  after_each(function()
    vim.system, require("neoagent.fs").create_temp = original, create_temp
    for _, path in ipairs(files) do
      local retained = vim.uv.fs_stat(path)
      vim.fn.delete(path)
      assert.is_nil(retained)
    end
  end)
  local function wait(run)
    assert(vim.wait(1000, function() return run:is_done() end))
    return run:result()
  end
  local function process(header_lines)
    local callbacks, completion, killed
    vim.system = function(command, opts, done)
      local flag = vim.fn.index(command, "--dump-header")
      assert(flag >= 0, "curl must collect response headers")
      local index = flag + 2
      files[#files + 1] = command[index]
      vim.fn.writefile(header_lines, command[index], "b")
      callbacks, completion = opts, done
      return { kill = function() killed = true end }
    end
    return function() return callbacks, completion, killed end
  end

  it("preserves final header blocks and streamed bytes across process completion", function()
    local state = process({ "HTTP/1.1 100 Continue", "X-Interim: gone", "",
      "HTTP/2 201 Created", "X-Request-Id: final", "" })
    local chunks = {}
    local run = curl.request({ request = { url = "https://api.test", body = "{}" },
      on_chunk = function(chunk) chunks[#chunks + 1] = chunk end })
    local callbacks, finish = state()
    assert.are.equal("{}", callbacks.stdin)
    callbacks.stdout(nil, "first\000")
    callbacks.stdout(nil, "second")
    finish({ code = 0 })
    local result = wait(run)
    assert.is_true(result.ok)
    assert.are.same({ "first\000", "second" }, chunks)
    assert.are.equal("first\000second", result.response.stdout)
    assert.are.equal(201, result.response.status)
    assert.are.same({ ["x-request-id"] = "final" }, result.response.headers)
  end)

  it("stops the process on consumer failure and retains parsed response metadata", function()
    local state = process({ "HTTP/2 200 OK", "X-Request-Id: failed-stream", "" })
    local run = curl.request({ request = { url = "https://api.test" },
      on_chunk = function() error(util.error("protocol", "broken event"), 0) end })
    local callbacks = state()
    callbacks.stdout(nil, "data: broken\n\n")
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)
    assert.are.equal("broken event", result.error.message)
    assert.are.equal("failed-stream", result.error.response.headers["x-request-id"])
    local _, _, killed = state()
    assert.is_true(killed)
  end)

  it("sends fetched bodies on stdin and rejects missing status output", function()
    local state = process({})
    local run = curl.fetch({ request = { url = "https://api.test", body = "private body" } })
    local callbacks, finish = state()
    assert.are.equal("private body", callbacks.stdin)
    finish({ code = 0, stdout = "body without a status suffix" })
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("protocol", result.error.kind)
    assert.matches("missing an HTTP status", result.error.message)
  end)

  it("reports private header file allocation failures before starting a process", function()
    require("neoagent.fs").create_temp = function() return nil, "disk full" end
    vim.system = function() error("process started without private header storage") end
    local result = wait(curl.request({ request = { url = "https://api.test" } }))
    assert.is_false(result.ok)
    assert.matches("Failed to create curl header file", result.error.message)
    assert.are.equal("disk full", result.error.detail)
  end)
end)
