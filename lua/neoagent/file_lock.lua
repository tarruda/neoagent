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
local FILE_MODE = 384

local function pack(...)
  return { n = select("#", ...), ... }
end

local function failure(code, message, detail)
  local err = util.error("file_lock", message, detail)
  err.code = code
  return err
end

local function backend_failure(err, fallback_code, fallback_message)
  if type(err) ~= "table" then
    return failure(fallback_code, fallback_message, err)
  end
  return failure(err.code or fallback_code, err.message or fallback_message,
    err.detail)
end

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function load_backend()
  local module
  if jit.os == "Linux" or jit.os == "OSX" then
    module = "neoagent.file_lock.posix"
  elseif jit.os == "Windows" then
    module = "neoagent.file_lock.windows"
  else
    return nil, failure("unavailable",
      "File locks are unavailable on " .. tostring(jit.os))
  end
  local loaded, value = pcall(require, module)
  if not loaded then
    return nil, failure("unavailable", "File lock backend is unavailable", value)
  end
  local created, backend = pcall(value.new)
  if not created then
    return nil, failure("unavailable", "File lock backend is unavailable", backend)
  end
  return backend
end

local function release_handle(handle)
  local released, release_err = handle:release()
  local closed, close_err = handle:close()
  if not released then return nil, release_err end
  if not closed then return nil, close_err end
  return true
end

function Lease:release()
  if not self._active then return true end
  self._active = false
  local verified, verify_err = self._handle:verify_token(self.token)
  local released, release_err = self._handle:release()
  local closed, close_err = self._handle:close()
  self._handle = nil
  if not verified then
    return nil, backend_failure(
      verify_err, "ownership", "Failed to verify file lock ownership")
  end
  if not released then
    return nil, backend_failure(
      release_err, "release", "Failed to unlock file lock")
  end
  if not closed then
    return nil, backend_failure(
      close_err, "release", "Failed to close file lock")
  end
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
  if not self.backend then return nil, self.backend_error end
  local directory = vim.fs.dirname(self.path)
  local created, create_err = fs.mkdirp(directory)
  if not created then
    return nil, failure("open", "Failed to create file lock directory", create_err)
  end
  local bytes, random_err = vim.uv.random(16)
  if not bytes then
    return nil, failure("random", "Failed to create file lock token", random_err)
  end
  local owner = bytes:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end)
  return { token = owner, handle = nil }
end

function Lock:_close_state(state)
  if not state or not state.handle then return true end
  local handle = state.handle
  state.handle = nil
  local closed, close_err = handle:close()
  if not closed then
    return nil, backend_failure(
      close_err, "release", "Failed to close file lock candidate")
  end
  return true
end

function Lock:_attempt(state)
  if not state.handle then
    local handle, open_err = self.backend:open(self.path, self.mode)
    if not handle then
      return nil, backend_failure(open_err, "open", "Failed to open file lock")
    end
    state.handle = handle
  end

  local acquired, acquire_err = state.handle:try_acquire()
  if acquired == false then return nil end
  if not acquired then
    local handle = state.handle
    state.handle = nil
    handle:close()
    return nil, backend_failure(
      acquire_err, "lock", "Failed to acquire file lock")
  end

  local prepared, prepare_err = state.handle:prepare(self.mode)
  local written, write_err
  local verified, verify_err
  if prepared then written, write_err = state.handle:write_token(state.token) end
  if written then verified, verify_err = state.handle:verify_token(state.token) end
  if not prepared or not written or not verified then
    local initialization_err = prepare_err or write_err or verify_err
    local handle = state.handle
    state.handle = nil
    release_handle(handle)
    return nil, backend_failure(initialization_err, "initialize",
      "Failed to initialize file lock")
  end

  local handle = state.handle
  state.handle = nil
  return setmetatable({
    path = self.path,
    token = state.token,
    _active = true,
    _handle = handle,
  }, Lease)
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
  local closed, close_err = self:_close_state(state)
  if attempt_err then return nil, attempt_err end
  if not closed then return nil, close_err end
  return nil, failure("timeout", "Timed out waiting for file lock")
end

function Lock:acquire_async()
  local state, state_err = self:_state()
  if not state then error(state_err, 0) end
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    if not timer then
      self:_close_state(state)
      done.reject(failure("acquire", "Failed to create file lock timer"))
      return
    end
    local started_at = vim.uv.hrtime() / 1000000
    local settled = false

    local function settle(method, value, disposer)
      if settled then return end
      settled = true
      close_timer(timer)
      if method == "reject" then self:_close_state(state) end
      done[method](value, disposer)
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
        settle("resolve", value, function(acquired)
          local released, release_err = acquired:release()
          if not released then error(release_err, 0) end
        end)
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
      self:_close_state(state)
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

local function permission_mode(value)
  assert(type(value) == "number" and value >= 0 and value <= 511
      and value % 1 == 0,
    "file lock mode must be a permission mode between 0000 and 0777")
  return value
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table"
      and (next(opts) == nil or not util.is_list(opts)),
    "file lock options must be an object")
  for name in pairs(opts) do
    assert(name == "path" or name == "timeout_ms" or name == "poll_ms"
        or name == "mode",
      "unsupported file lock option " .. tostring(name))
  end
  assert(type(opts.path) == "string" and opts.path ~= "",
    "file lock path is required")
  local backend, backend_err = load_backend()
  return setmetatable({
    path = fs.normalize(opts.path),
    timeout_ms = positive_integer(
      opts.timeout_ms or DEFAULT_TIMEOUT_MS, "timeout_ms"),
    poll_ms = positive_integer(opts.poll_ms or DEFAULT_POLL_MS, "poll_ms"),
    mode = permission_mode(opts.mode or FILE_MODE),
    backend = backend,
    backend_error = backend_err,
  }, Lock)
end

M.DEFAULT_TIMEOUT_MS = DEFAULT_TIMEOUT_MS
M.DEFAULT_POLL_MS = DEFAULT_POLL_MS

return M
