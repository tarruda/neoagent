local assert = require("luassert")
local helper = require("tests.helpers.subprocess")

describe("bundled Tool process environment", function()
  if jit.os == "Windows" then
    pending("POSIX shell syntax; Windows has native process tests")
    return
  end

  it("points shell commands at their executing editor without changing generic inheritance", function()
    local nvim, legacy = vim.env.NVIM, vim.env.NVIM_LISTEN_ADDRESS
    local server = vim.v.servername == "" and vim.fn.serverstart(vim.fn.tempname()) or nil
    local address = vim.v.servername
    vim.env.NVIM, vim.env.NVIM_LISTEN_ADDRESS = "synthetic-stale-address", "synthetic-legacy-address"
    local ok, err = pcall(function()
      local command =
        [[printf '%s\n' "$NVIM"; if [ "${NVIM_LISTEN_ADDRESS+x}" ]; then printf legacy-present; else printf legacy-absent; fi]]
      local cwd = assert(vim.uv.cwd())
      local result = helper.complete(function()
        return require("neoagent.tools.shell").new().execute({ command = command }, {
          context = { workspace = require("neoagent.workspace").new({ root = cwd, cwd = cwd }) },
        })
      end)
      assert.is_nil(result.error, vim.inspect(result.error))
      assert.are.equal(address .. "\nlegacy-absent", assert(result.content[1]).text)
      local generic = helper.complete(function()
        return require("neoagent.subprocess_common").run(helper.spec(command), { capture = { max_bytes = 1024 } })
      end)
      assert.are.equal("synthetic-stale-address\nlegacy-present", generic.stdout)
    end)
    vim.env.NVIM, vim.env.NVIM_LISTEN_ADDRESS = nvim, legacy
    if server then
      vim.fn.serverstop(server)
    end
    assert.is_true(ok, vim.inspect(err))
  end)
end)
