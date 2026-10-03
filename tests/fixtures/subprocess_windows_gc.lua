local async = require("neoagent.async")
local subprocess = require("neoagent.subprocess_common")
local scope = subprocess.scope()
local started = vim.uv.hrtime()

local function progress(iteration, phase)
  io.stdout:write(("launch %d %s (%.3fs)\n"):format(iteration, phase, (vim.uv.hrtime() - started) / 1e9))
  io.stdout:flush()
end

local pause = collectgarbage("setpause", 0)
local step = collectgarbage("setstepmul", 1000)
local ok, failure = pcall(function()
  for iteration = 1, 20 do
    local expected = ("native_%d_"):format(iteration) .. ("value"):rep(40)
    local bytes = {}
    collectgarbage("collect")
    progress(iteration, "starting")
    local handle = scope:spawn({
      argv = { vim.fn.exepath("cmd.exe"), "/d", "/s", "/c", "echo %NATIVE_VALUE%" },
      cwd = assert(vim.uv.cwd()),
      stdio = { kind = "pty", columns = 1000, rows = 24 },
      -- Stress native storage with deterministic input. Inheriting the hosted
      -- runner's large environment mostly stresses LuaCov's per-byte hook
      -- allocations under full collection, before any native process exists.
      environment = { inherit = false, set = { NATIVE_VALUE = expected } },
      timeout_ms = 10000,
    }, {
      on_output = function(event)
        bytes[#bytes + 1] = event.data
      end,
    })
    progress(iteration, "started")
    local waiting = async.run(function()
      return handle:wait()
    end)
    assert(
      vim.wait(15000, function()
        return waiting:is_done()
      end, 5),
      "native launch did not settle"
    )
    local result = assert(waiting:result())
    assert(result.code == 0, vim.inspect(result))
    assert(table.concat(bytes):find(expected, 1, true), vim.inspect(bytes))
    progress(iteration, "settled")
  end
end)
collectgarbage("setpause", pause)
collectgarbage("setstepmul", step)
scope:close("native collection test finished")
local cleanup = async.run(function()
  return scope:wait(4000)
end)
assert(
  vim.wait(5000, function()
    return cleanup:is_done()
  end, 5),
  "native collection cleanup did not settle"
)
assert(cleanup:result() == true, vim.inspect(cleanup:result()))
assert(ok, vim.inspect(failure))
io.stdout:write("20 native launches survived aggressive collection\n")
io.stdout:flush()
vim.cmd("qa!")
