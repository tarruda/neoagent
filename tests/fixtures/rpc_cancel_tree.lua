-- Gate descendant creation on the test observing the parent's output through
-- RPC. Windows pipe launch attaches the parent's Job before delivering output,
-- so the child will inherit that Job rather than racing its assignment.
if arg[1] == "child" then
  local ready = assert(io.open(assert(arg[2]), "w"))
  assert(ready:write("ready"))
  assert(ready:close())
  -- Stay alive independently of the parent. Closing the parent's handles
  -- must not substitute for terminating the descendant through its Job.
  vim.wait(120000, function()
    return false
  end, 100)
  error("RPC cancellation did not terminate the descendant")
end

io.stdout:write("PARENT_READY\n")
io.stdout:flush()
assert(
  vim.wait(120000, function()
    return vim.uv.fs_stat(assert(arg[2])) ~= nil
  end, 10),
  "test did not permit descendant creation"
)

local exited = false
local process = assert(vim.uv.spawn(assert(arg[1]), {
  args = {
    "--headless",
    "--noplugin",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-n",
    "-l",
    assert(debug.getinfo(1, "S")).source:sub(2),
    "child",
    assert(arg[3]),
  },
  stdio = { nil, 1, 2 },
  cwd = assert(vim.uv.cwd()),
  detached = false,
  hide = true,
  verbatim = false,
}, function()
  exited = true
end))
local completed = vim.wait(120000, function()
  return exited
end, 100)
if not completed then
  process:kill(9)
  assert(
    vim.wait(5000, function()
      return exited
    end, 10),
    "descendant teardown did not settle"
  )
end
process:close()
error("RPC cancellation did not terminate the parent")
