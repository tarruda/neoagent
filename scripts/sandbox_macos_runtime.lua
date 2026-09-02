local function fail(message)
  io.stderr:write("neoagent macOS sandbox runtime: ",
    tostring(message), "\n")
  os.exit(70)
end

if jit.os ~= "OSX" then fail("macOS is required") end

local function missing(err, code)
  return code == "ENOENT"
    or type(err) == "string" and err:find("ENOENT", 1, true) ~= nil
end

local function content_fingerprint(data)
  local seeds = {
    0x811c9dc5, 0x9e3779b9, 0x85ebca6b, 0xc2b2ae35,
    0x27d4eb2f, 0x165667b1, 0xd3a2646c, 0xfd7046c5,
  }
  local parts = {}
  for index, seed in ipairs(seeds) do
    local hash = bit.tobit(seed)
    for offset = 1, #data do
      hash = bit.bxor(hash, data:byte(offset) + index - 1)
      hash = bit.tobit(hash + bit.lshift(hash, 1)
        + bit.lshift(hash, 4) + bit.lshift(hash, 7)
        + bit.lshift(hash, 8) + bit.lshift(hash, 24))
      hash = bit.bxor(hash, bit.rshift(hash, 13))
    end
    parts[index] = bit.tohex(hash, 8)
  end
  return table.concat(parts)
end

local function target_observation(stat)
  return {
    exists = stat ~= nil,
    type = stat and stat.type or nil,
    device = stat and stat.dev or nil,
    inode = stat and stat.ino or nil,
    mode = stat and type(stat.mode) == "number"
        and bit.band(stat.mode, 511) or nil,
  }
end

local function same_target(left, right)
  return left.exists == right.exists and left.type == right.type
    and left.device == right.device and left.inode == right.inode
    and left.mode == right.mode
end

local function atomic_replace(request, data)
  local policy = request.policy
  if type(policy) ~= "table" or vim.islist(policy)
      or policy.mode == nil and policy.preserve_mode ~= true
      or policy.preserve_mode == true and policy.new_mode == nil
      or policy.expected_content_fingerprint ~= nil
        and (type(policy.expected_content_fingerprint) ~= "string"
          or not policy.expected_content_fingerprint:match(
            "^" .. string.rep("%x", 64) .. "$")) then
    fail("invalid atomic replacement policy")
  end
  local stat, stat_err, stat_code = vim.uv.fs_lstat(request.path)
  local target = target_observation(stat)
  if not stat and not missing(stat_err, stat_code) then fail(stat_err) end
  if stat and stat.type == "link" then fail("target is a symbolic link") end
  if stat and stat.type ~= "file" then fail("target is not a regular file") end
  if not stat and policy.require_existing then fail("target must already exist") end
  local selected_mode = policy.mode
    or stat and bit.band(stat.mode, 511) or policy.new_mode
  if type(selected_mode) ~= "number" or selected_mode < 0
      or selected_mode > 511 or selected_mode % 1 ~= 0 then
    fail("invalid atomic replacement mode")
  end
  if type(request.suffix) ~= "string" or #request.suffix ~= 32
      or request.suffix:find("[^%x]") then
    fail("invalid atomic replacement suffix")
  end
  local temporary = request.path .. "." .. request.suffix .. ".tmp"
  local fd, open_err = vim.uv.fs_open(temporary, "wx", selected_mode)
  if not fd then fail(open_err) end
  local written = 0
  while written < #data do
    local count, write_err = vim.uv.fs_write(
      fd, data:sub(written + 1), written)
    if type(count) ~= "number" or count <= 0
        or count > #data - written then
      vim.uv.fs_close(fd)
      vim.uv.fs_unlink(temporary)
      fail(write_err or "invalid write length")
    end
    written = written + count
  end
  local closed, close_err = vim.uv.fs_close(fd)
  if not closed then
    vim.uv.fs_unlink(temporary)
    fail(close_err)
  end
  if policy.mode ~= nil or stat and policy.preserve_mode == true then
    local secured, secure_err = vim.uv.fs_chmod(temporary, selected_mode)
    if not secured then
      vim.uv.fs_unlink(temporary)
      fail(secure_err)
    end
  end
  local current, current_err, current_code = vim.uv.fs_lstat(request.path)
  if not current and not missing(current_err, current_code) then
    vim.uv.fs_unlink(temporary)
    fail(current_err)
  end
  if current and current.type == "link" then
    vim.uv.fs_unlink(temporary)
    fail("target became a symbolic link")
  end
  if current and current.type ~= "file" then
    vim.uv.fs_unlink(temporary)
    fail("target is not a regular file")
  end
  if not current and policy.require_existing then
    vim.uv.fs_unlink(temporary)
    fail("target must already exist")
  end
  if not same_target(target, target_observation(current)) then
    vim.uv.fs_unlink(temporary)
    fail("target changed during preparation")
  end
  if policy.expected_content_fingerprint ~= nil then
    if not target.exists then
      vim.uv.fs_unlink(temporary)
      fail("expected target content is missing")
    end
    local contents, read_err = (function()
      local held, open_err = vim.uv.fs_open(request.path, "r", 438)
      if not held then return nil, open_err end
      local observed = vim.uv.fs_fstat(held)
      if not same_target(target, target_observation(observed)) then
        vim.uv.fs_close(held)
        return nil, "target changed during content verification"
      end
      local chunks, offset = {}, 0
      while true do
        local chunk, chunk_err = vim.uv.fs_read(held, 65536, offset)
        if chunk == nil then vim.uv.fs_close(held) return nil, chunk_err end
        if chunk == "" then break end
        chunks[#chunks + 1] = chunk
        offset = offset + #chunk
      end
      local after = vim.uv.fs_fstat(held)
      vim.uv.fs_close(held)
      if not same_target(target, target_observation(after)) then
        return nil, "target changed during content verification"
      end
      return table.concat(chunks)
    end)()
    local latest = vim.uv.fs_lstat(request.path)
    if not contents or not same_target(target, target_observation(latest)) then
      vim.uv.fs_unlink(temporary)
      fail(read_err or "target changed during content verification")
    end
    if content_fingerprint(contents):lower()
        ~= policy.expected_content_fingerprint:lower() then
      vim.uv.fs_unlink(temporary)
      fail("target content changed concurrently")
    end
  end
  local replaced, replace_err = vim.uv.fs_rename(temporary, request.path)
  if not replaced then
    vim.uv.fs_unlink(temporary)
    fail(replace_err)
  end
end

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
    if not stat or stat.type ~= "file" then
      fail(stat_err or "not a regular file")
    end
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
  elseif request.operation == "atomic_replace" then
    atomic_replace(request, io.stdin:read("*a"))
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

local function schedule_descendant_cleanup()
  if cleanup_started then return true end
  -- The detached peer waits for this supervisor to exit before terminating
  -- every process that remains in the Seatbelt sandbox.
  local handle, err = vim.uv.spawn("/bin/sh", {
    args = {
      "-c",
      "parent=$PPID; while kill -0 \"$parent\" 2>/dev/null; "
        .. "do :; done; kill -KILL -1",
    },
    detached = true,
    stdio = { nil, nil, nil },
  }, function() end)
  if not handle then return nil, err end
  cleanup_started = true
  handle:unref()
  return true
end

local function stop(signal)
  if stopping then return end
  stopping = true
  local cleanup_ok, cleanup_err = schedule_descendant_cleanup()
  close_signal_watchers()
  vim.schedule(function()
    if not cleanup_ok then
      fail("could not start descendant cleanup: " .. tostring(cleanup_err))
    end
    os.exit(128 + signal)
  end)
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

local cleanup_ok, cleanup_err = schedule_descendant_cleanup()
close_signal_watchers()
if not cleanup_ok then
  fail("could not start descendant cleanup: " .. tostring(cleanup_err))
end
if completed.signal ~= 0 then
  pcall(vim.uv.kill, vim.fn.getpid(), completed.signal)
  os.exit(128 + completed.signal)
end
os.exit(completed.code)
