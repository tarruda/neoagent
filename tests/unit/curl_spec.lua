local curl = require("neoagent.transport.curl")

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
    assert.are.equal(64 * 1024, #requested.error.detail)

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
      "curl", "--no-buffer", "--silent", "--show-error", "--fail-with-body",
      "-X", "POST", "-H", "Authorization: Bearer x", "-H",
      "Content-Type: application/json", "http://localhost",
    }, curl.command({
      url = "http://localhost",
      headers = { ["Content-Type"] = "application/json", Authorization = "Bearer x" },
    }))
    assert.are.same({
      "curl", "--silent", "--show-error", "-X", "GET", "--max-time", "1.500",
      "--write-out", "\n%{http_code}", "http://localhost",
    }, (function()
      local original_system = vim.system
      local commands = {}
      vim.system = function(command) commands[1] = command return { kill = function() end } end
      curl.fetch({
        request = { url = "http://localhost", method = "GET", timeout_ms = 1500 },
      })
      vim.system = original_system
      return commands[1]
    end)())
    assert.are.same({
      "curl", "--no-buffer", "--silent", "--show-error", "--fail-with-body",
      "-X", "GET", "--max-time", "1.500", "http://localhost",
    }, curl.command({ url = "http://localhost", method = "GET", timeout_ms = 1500 }))
  end)

  it("bounds fetched response bodies while curl is running", function()
    local original_system = vim.system
    local function result(maximum, send)
      vim.system = function(_, options, on_exit)
        send(options, on_exit)
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

    local fetched = result(2, function(options, on_exit)
      options.stdout(nil, "{}\n200")
      on_exit({ code = 0 })
    end)
    assert.is_true(fetched.ok)
    assert.are.equal("{}", fetched.body)
    assert.are.equal(200, fetched.status)

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
