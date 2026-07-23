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
      "Content-Type: application/json", "--data-binary", "@-", "http://localhost",
    }, curl.command({
      url = "http://localhost",
      headers = { ["Content-Type"] = "application/json", Authorization = "Bearer x" },
    }))
  end)
end)
