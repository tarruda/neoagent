local exit = os.exit --[[@as fun(status?: integer): never]]

---@param message unknown
---@return never
local function fail(message)
  io.stderr:write("neoagent macOS sandbox runtime: ",
    tostring(message), "\n")
  return exit(70)
end

if jit.os ~= "OSX" then fail("macOS is required") end

if vim.env.NEOAGENT_SANDBOX_EXEC ~= "1" then fail("invalid request") end
vim.env.NEOAGENT_SANDBOX_EXEC = nil
local streaming = vim.env.NEOAGENT_SANDBOX_STREAM == "1"
if vim.env.NEOAGENT_SANDBOX_STREAM ~= nil and not streaming then
  fail("invalid streaming mode")
end
vim.env.NEOAGENT_SANDBOX_STREAM = nil

local command = vim.list_slice(arg)
if command[1] == "--" then table.remove(command, 1) end
if #command == 0 then fail("command is required") end

---@type uv.uv_signal_t[]
local signal_watchers = {}
local stopping = false
local cleanup_started = false
local function close_signal_watchers()
  for _, watcher in ipairs(signal_watchers) do
    if not watcher:is_closing() then
      watcher:stop()
      watcher:close()
    end
  end
  signal_watchers = {}
end

---@return true?, string?
local function schedule_descendant_cleanup()
  if cleanup_started then return true end
  -- The detached peer waits for this supervisor to exit before terminating
  -- every process that remains in the Seatbelt sandbox.
  local spawn_options = {
    args = {
      "-c",
      "parent=$PPID; while kill -0 \"$parent\" 2>/dev/null; "
        .. "do :; done; kill -KILL -1",
    },
    detached = true,
    stdio = { nil, nil, nil },
  }
  local handle, err = vim.uv.spawn("/bin/sh",
    spawn_options --[[@as uv.spawn.options]], function() end)
  if not handle then return nil, err --[[@as string?]] end
  cleanup_started = true
  handle:unref()
  return true
end

---@param signal integer
local function stop(signal)
  if stopping then return end
  stopping = true
  local cleanup_ok, cleanup_err = schedule_descendant_cleanup()
  close_signal_watchers()
  vim.schedule(function()
    if not cleanup_ok then
      fail("could not start descendant cleanup: " .. tostring(cleanup_err))
    end
    exit(128 + signal)
  end)
end

for _, signal in ipairs({ 1, 2, 15 }) do
  local selected = signal
  local watcher = assert(vim.uv.new_signal())
  watcher:start(selected, function() stop(selected) end)
  signal_watchers[#signal_watchers + 1] = watcher
end

local input = not streaming and io.stdin:read("*a") or nil
---@type vim.SystemCompleted?
local completed
local started, process = pcall(vim.system, command, {
  clear_env = true,
  env = vim.fn.environ(),
  stdin = streaming and true or input,
  stdout = function(err, data)
    if err then stop(15) end
    if data then io.stdout:write(data) io.stdout:flush() end
  end,
  stderr = function(err, data)
    if err then stop(15) end
    if data then io.stderr:write(data) io.stderr:flush() end
  end,
}, function(value)
  completed = value
end)
if not started then
  close_signal_watchers()
  fail(process)
end

---@type uv.uv_pipe_t?
local input_pipe
if streaming then
  input_pipe = assert(vim.uv.new_pipe(false))
  input_pipe:open(0)
  input_pipe:read_start(function(err, data)
    if err then
      stop(15)
      return
    end
    if data then
      local written = pcall(process.write, process, data)
      if not written then stop(15) end
      return
    end
    pcall(process.write, process, nil)
    if input_pipe and not input_pipe:is_closing() then
      input_pipe:read_stop()
      input_pipe:close()
    end
  end)
end

while not completed and not stopping do
  vim.wait(100, function() return completed ~= nil or stopping end, 10)
end
if stopping then
  while true do vim.wait(100, function() return false end, 10) end
end

local cleanup_ok, cleanup_err = schedule_descendant_cleanup()
close_signal_watchers()
if input_pipe and not input_pipe:is_closing() then
  input_pipe:read_stop()
  input_pipe:close()
end
if not cleanup_ok then
  fail("could not start descendant cleanup: " .. tostring(cleanup_err))
end
assert(completed)
if completed.signal ~= 0 then
  pcall(vim.uv.kill, vim.fn.getpid(), completed.signal --[[@as integer]])
  exit(128 + completed.signal --[[@as integer]])
end
exit(completed.code --[[@as integer]])
