local async = require("neoagent.async")
local subprocess = require("neoagent.subprocess_common")
require("neoagent.subprocess.validate").REAP_MS = 1000
local scope = subprocess.scope()
---@type Neoagent.SubprocessHandle
local handle
local wrote = false
local run = async.run(function()
  handle = scope:spawn({
    argv = {
      "sh",
      "-c",
      "trap '' HUP; stty raw -echo; printf ready; dd bs=1 count=1 of=/dev/null 2>/dev/null; sleep 0.5 & exit 0",
    },
    cwd = assert(vim.uv.cwd()),
    stdio = { kind = "pty", columns = 80, rows = 24 },
    timeout_ms = arg[1] ~= "no-timeout" and 200 or nil,
  }, {
    on_output = function(event)
      if not wrote and event.data:find("ready", 1, true) then
        wrote = true
        for _ = 1, 16 do
          handle:write(string.rep("x", 65536))
        end
      end
    end,
  })
  return handle:wait()
end)
assert(
  vim.wait(5000, function()
    return run:is_done()
  end, 5),
  "PTY cleanup did not settle"
)
assert(wrote, "PTY input was not queued")
local result = assert(run:result())
assert(result.ok ~= false, vim.inspect(result))
assert(result.code == 0 and not result.timed_out, vim.inspect(result))
assert(scope:is_settled(), "PTY cleanup was not observed by its scope")
io.stdout:write("cleanup observed\n")
io.stdout:flush()
-- Normal editor teardown must also finish; the parent owns the watchdog.
vim.cmd("qa!")
