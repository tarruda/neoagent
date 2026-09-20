local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local process = require("neoagent.process")

describe("macOS sandbox cleanup", function()
  local native_test = jit.os == "OSX" and it or pending
  local roots = {}

  after_each(function()
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots = {}
  end)

  native_test("finishes despite identity changes in a confirmed unrelated process", function()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    assert(fs.mkdirp(root))
    local runtime = assert(vim.api.nvim_get_runtime_file("scripts/sandbox_macos_runtime.lua", false)[1])
    local wrapper = root .. "/cleanup.lua"
    -- Keep native policy queries and process enumeration. Make this unrelated
    -- helper's identity change between observations on every cleanup scan.
    assert(fs.write_all(wrapper, string.format([[
local ffi = require("ffi")
local load = ffi.load
local scanning, observations, scans = false, 0, 0
ffi.load = function(name, ...)
  local native = load(name, ...)
  if name ~= "/usr/lib/libproc.dylib" then return native end
  return setmetatable({
    proc_listallpids = function(...)
      scanning, observations, scans = true, 0, scans + 1
      return native.proc_listallpids(...)
    end,
    proc_pidinfo = function(pid, flavor, arg, buffer, size)
      local value = native.proc_pidinfo(pid, flavor, arg, buffer, size)
      if scanning and pid == vim.fn.getpid() and flavor == 17 and value == 56 then
        observations = observations + 1
        if observations > 1 then buffer.idversion = buffer.idversion + 1 end
      end
      return value
    end,
  }, { __index = function(_, key) return native[key] end })
end
local exit = os.exit
os.exit = function(code)
  if code == 0 then
    assert(scans > 0 and observations > 0, "cleanup did not inspect the unrelated process")
  end
  return exit(code)
end
dofile(%q)
]], runtime)))
    local command = require("neoagent.process.nvim").command()
    vim.list_extend(command, { "--headless", "--noplugin", "-u", "NONE", "-i", "NONE", "-n", "-l", wrapper })
    local run = async.run(function()
      return process.run(command, {
        timeout_ms = 10000,
        env = { NEOAGENT_MACOS_SANDBOX_SPEC = vim.json.encode({
          mode = "cleanup", scope = "neoagent.sandbox." .. vim.fn.sha256(root):sub(1, 32),
        }) },
      })
    end)
    assert(vim.wait(15000, function() return run:is_done() end, 5))
    local result = assert(run:result())
    assert.is_not_false(result.ok)
    assert.are.equal(0, result.code, result.stderr)
  end)
end)
