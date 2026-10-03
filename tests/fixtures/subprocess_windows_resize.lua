local async = require("neoagent.async")
local subprocess = require("neoagent.subprocess_common")
local owner = subprocess.scope()
---@type Neoagent.SubprocessHandle
local handle
local resized = false
local run = async.run(function()
  handle = owner:spawn({
    argv = {
      "python",
      "-c",
      "import sys,time; print('ready',flush=True); sys.stdout.write('x'*4194304); sys.stdout.flush(); time.sleep(30)",
    },
    cwd = assert(vim.uv.cwd()),
    stdio = { kind = "pty", columns = 80, rows = 24 },
    timeout_ms = 3000,
    kill_grace_ms = 0,
  }, {
    on_output = function()
      if resized then
        return
      end
      resized = true
      -- Output reads are paused during this observer. An inline synchronous
      -- control-pipe write can then block the editor and all of its deadlines.
      for index = 1, 5000 do
        handle:resize(80 + index % 2, 24)
      end
    end,
  })
  return handle:wait()
end)
assert(
  vim.wait(8000, function()
    return run:is_done()
  end, 5),
  "resize prevented deadline completion"
)
local result = assert(run:result())
assert(result.ok ~= false and result.timed_out, vim.inspect(result))
assert(resized, "no terminal output reached the resize observer")
assert(owner:is_settled(), "console cleanup did not finish")
owner:close("test finished")
io.stdout:write("resize remained responsive\n")
io.stdout:flush()
vim.cmd("qa!")
