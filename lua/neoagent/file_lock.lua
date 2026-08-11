local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Lock = {}
Lock.__index = Lock
local Lease = {}
Lease.__index = Lease

local DEFAULT_TIMEOUT_MS = 15000
local DEFAULT_POLL_MS = 50
local DEFAULT_STALE_MS = 120000
local FILE_MODE = 384

local function pack(...)
  return { n = select("#", ...), ... }
end

local function failure(code, message, detail)
  local err = util.error("file_lock", message, detail)
  err.code = code
  return err
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function error_code(err, code)
  if type(code) == "string" and code ~= "" then return code end
  return type(err) == "string" and err:match("^([A-Z][A-Z0-9_]+):") or nil
end

local function is_error(err, code, expected)
  return error_code(err, code) == expected
end

local function mtime_ms(stat)
  local mtime = stat and stat.mtime or {}
  return (tonumber(mtime.sec) or 0) * 1000
    + math.floor((tonumber(mtime.nsec) or 0) / 1000000)
end

local function token()
  local bytes, err = vim.uv.random(16)
  if not bytes then
    return nil, failure("random", "Failed to create file lock token", err)
  end
  return (bytes:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

function Lease:_start_refresh(interval)
  local timer = vim.uv.new_timer()
  if not timer then
    self._refresh_error = failure("refresh", "Failed to create file lock refresh timer")
    return
  end
  self._timer = timer
  timer:start(interval, interval, function()
    if not self._active then return end
    local contents, read_err = fs.read(self.path)
    if contents ~= self.token then
      self._refresh_error = failure("ownership", "File lock ownership changed", read_err)
      close_timer(timer)
      return
    end
    local now = util.now_ms() / 1000
    local refreshed, refresh_err = vim.uv.fs_utime(self.path, now, now)
    if not refreshed then
      self._refresh_error = failure("refresh", "Failed to refresh file lock", refresh_err)
    end
  end)
end

function Lease:release()
  if not self._active then return true end
  self._active = false
  close_timer(self._timer)
  local refresh_error = self._refresh_error
  local contents, read_err = fs.read(self.path)
  if not contents then
    if not vim.uv.fs_stat(self.path) then
      return nil, failure("ownership", "File lock disappeared during lease")
    end
    return nil, failure("release", "Failed to inspect file lock during release", read_err)
  end
  if contents ~= self.token then
    return nil, failure("ownership", "File lock ownership changed")
  end
  local removed, remove_err, remove_code = vim.uv.fs_unlink(self.path)
  if not removed and not is_error(remove_err, remove_code, "ENOENT") then
    return nil, failure("release", "Failed to release file lock", remove_err)
  end
  if refresh_error then return nil, refresh_error end
  return true
end

function Lease:run(fn)
  assert(type(fn) == "function", "file lock callback is required")
  local results = pack(pcall(fn))
  local released, release_err = self:release()
  if not results[1] then error(results[2], 0) end
  if not released then return nil, release_err end
  return unpack(results, 2, results.n)
end

function Lock:_state()
  local value, err = token()
  if not value then return nil, err end
  return { token = value }
end

function Lock:_attempt(state)
  local fd, open_err, open_code = vim.uv.fs_open(self.path, "wx", self.mode)
  if fd then
    local written, write_err = vim.uv.fs_write(fd, state.token, 0)
    local closed, close_err = vim.uv.fs_close(fd)
    if written ~= #state.token or not closed then
      vim.uv.fs_unlink(self.path)
      return nil, failure(written ~= #state.token and "write" or "close",
        "Failed to initialize file lock", write_err or close_err or "short write")
    end
    local lease = setmetatable({
      path = self.path,
      token = state.token,
      _active = true,
    }, Lease)
    if self.refresh_ms then lease:_start_refresh(self.refresh_ms) end
    return lease
  end
  if not is_error(open_err, open_code, "EEXIST") then
    return nil, failure("open", "Failed to create file lock", open_err)
  end
  local stat, stat_err, stat_code = vim.uv.fs_stat(self.path)
  if not stat then
    if is_error(stat_err, stat_code, "ENOENT") then return nil end
    return nil, failure("inspect", "Failed to inspect file lock", stat_err)
  end
  if util.now_ms() - mtime_ms(stat) > self.stale_ms then
    local removed, remove_err, remove_code = vim.uv.fs_unlink(self.path)
    if not removed and not is_error(remove_err, remove_code, "ENOENT") then
      return nil, failure("recover", "Failed to recover stale file lock", remove_err)
    end
  end
  return nil
end

function Lock:acquire()
  local state, state_err = self:_state()
  if not state then return nil, state_err end
  local lease, attempt_err
  local function attempt()
    local ok
    ok, lease, attempt_err = pcall(self._attempt, self, state)
    if not ok then
      attempt_err = failure("acquire", "Failed to acquire file lock", lease)
      lease = nil
    end
    return lease ~= nil or attempt_err ~= nil
  end
  if not attempt() then
    vim.wait(self.timeout_ms, attempt, self.poll_ms, false)
  end
  if lease then return lease end
  if attempt_err then return nil, attempt_err end
  return nil, failure("timeout", "Timed out waiting for file lock")
end

function Lock:acquire_async()
  local state, state_err = self:_state()
  if not state then error(state_err, 0) end
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    if not timer then
      done.reject(failure("acquire", "Failed to create file lock timer"))
      return
    end
    local started_at = vim.uv.hrtime() / 1000000
    local settled = false
    local lease

    local function settle(method, value)
      if settled then return end
      settled = true
      close_timer(timer)
      done[method](value)
    end

    local attempt
    attempt = function()
      if settled then return end
      local ok, value, attempt_err = pcall(self._attempt, self, state)
      if not ok then
        settle("reject", failure("acquire", "Failed to acquire file lock", value))
        return
      end
      if value then
        lease = value
        settle("resolve", lease)
        return
      end
      if attempt_err then
        settle("reject", attempt_err)
        return
      end
      local elapsed = vim.uv.hrtime() / 1000000 - started_at
      if elapsed >= self.timeout_ms then
        settle("reject", failure("timeout", "Timed out waiting for file lock"))
        return
      end
      timer:start(math.min(self.poll_ms,
        math.max(1, self.timeout_ms - elapsed)), 0, attempt)
    end

    attempt()
    return function()
      if settled then return end
      settled = true
      close_timer(timer)
      if lease then lease:release() end
    end
  end)
end

function Lock:with(fn)
  assert(type(fn) == "function", "file lock callback is required")
  local lease, acquire_err = self:acquire()
  if not lease then return nil, acquire_err end
  return lease:run(fn)
end

local function positive_integer(value, name)
  assert(type(value) == "number" and value > 0 and value % 1 == 0,
    name .. " must be a positive integer")
  return value
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.path) == "string" and opts.path ~= "", "file lock path is required")
  local refresh_ms = opts.refresh_ms
  if refresh_ms ~= nil then refresh_ms = positive_integer(refresh_ms, "refresh_ms") end
  return setmetatable({
    path = fs.normalize(opts.path),
    timeout_ms = positive_integer(opts.timeout_ms or DEFAULT_TIMEOUT_MS, "timeout_ms"),
    poll_ms = positive_integer(opts.poll_ms or DEFAULT_POLL_MS, "poll_ms"),
    stale_ms = positive_integer(opts.stale_ms or DEFAULT_STALE_MS, "stale_ms"),
    refresh_ms = refresh_ms,
    mode = positive_integer(opts.mode or FILE_MODE, "mode"),
  }, Lock)
end

M.DEFAULT_TIMEOUT_MS = DEFAULT_TIMEOUT_MS
M.DEFAULT_POLL_MS = DEFAULT_POLL_MS
M.DEFAULT_STALE_MS = DEFAULT_STALE_MS

return M
