local function fail(message)
  io.stderr:write("neoagent macOS sandbox runtime: ",
    tostring(message), "\n")
  os.exit(70)
end

if jit.os ~= "OSX" then fail("macOS is required") end

local function filesystem_request(encoded)
  if #encoded > 16 * 1024 then fail("invalid request") end
  local ok, request = pcall(vim.json.decode, encoded)
  if not ok or type(request) ~= "table"
      or type(request.operation) ~= "string"
      or type(request.path) ~= "string" then
    fail("invalid request")
  end

  if request.operation == "read" then
    local stat, stat_err = vim.uv.fs_stat(request.path)
    if not stat or stat.type ~= "file" then fail(stat_err or "not a file") end
    local fd, open_err = vim.uv.fs_open(request.path, "r", 438)
    if not fd then fail(open_err) end
    local data, read_err = vim.uv.fs_read(fd, stat.size, 0)
    vim.uv.fs_close(fd)
    if not data then fail(read_err) end
    io.stdout:write(data)
  elseif request.operation == "mkdirp" then
    local mkdir_ok, created = pcall(vim.fn.mkdir, request.path, "p")
    if not mkdir_ok
        or created == 0 and not vim.uv.fs_stat(request.path) then
      fail("could not create directory")
    end
  elseif request.operation == "write_all" then
    local data = io.stdin:read("*a")
    local fd, open_err = vim.uv.fs_open(
      request.path, request.flags or "w", request.mode or 420)
    if not fd then fail(open_err) end
    local offset, written = request.flags == "a" and -1 or 0, 0
    while written < #data do
      local count, write_err = vim.uv.fs_write(
        fd, data:sub(written + 1), offset < 0 and -1 or offset + written)
      if not count then
        vim.uv.fs_close(fd)
        fail(write_err)
      end
      written = written + count
    end
    local closed, close_err = vim.uv.fs_close(fd)
    if not closed then fail(close_err) end
  else
    fail("unsupported operation")
  end
end

local encoded = vim.env.NEOAGENT_SANDBOX_FS
vim.env.NEOAGENT_SANDBOX_FS = nil
if encoded ~= nil then
  if type(encoded) ~= "string" then fail("invalid request") end
  filesystem_request(encoded)
  return
end

if vim.env.NEOAGENT_SANDBOX_EXEC ~= "1" then fail("invalid request") end
vim.env.NEOAGENT_SANDBOX_EXEC = nil

local command = vim.list_slice(arg)
if command[1] == "--" then table.remove(command, 1) end
if #command == 0 then fail("command is required") end

local signal_watchers = {}
local stopping = false
local function close_signal_watchers()
  for _, watcher in ipairs(signal_watchers) do
    if not watcher:is_closing() then
      watcher:stop()
      watcher:close()
    end
  end
  signal_watchers = {}
end

local function kill_descendants(signal)
  pcall(vim.uv.kill, -1, signal)
end

local function stop(signal)
  if stopping then return end
  stopping = true
  kill_descendants(15)
  kill_descendants(9)
  close_signal_watchers()
  vim.schedule(function() os.exit(128 + signal) end)
end

for _, signal in ipairs({ 1, 2, 15 }) do
  local selected = signal
  local watcher = assert(vim.uv.new_signal())
  watcher:start(selected, function() stop(selected) end)
  signal_watchers[#signal_watchers + 1] = watcher
end

local input = io.stdin:read("*a")
local completed
local started, process = pcall(vim.system, command, {
  clear_env = true,
  env = vim.fn.environ(),
  stdin = input,
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

while not completed and not stopping do
  vim.wait(100, function() return completed ~= nil or stopping end, 10)
end
if stopping then
  while true do vim.wait(100, function() return false end, 10) end
end

kill_descendants(9)
close_signal_watchers()
if completed.signal ~= 0 then
  pcall(vim.uv.kill, vim.fn.getpid(), completed.signal)
  os.exit(128 + completed.signal)
end
os.exit(completed.code)
