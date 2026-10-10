local async = require("neoagent.async")
local util = require("neoagent.util")
local M = {}

-- These native helpers also run in the standalone host, where runtimepath is
-- deliberately absent. Cache the same modules when loaded by the editor.
local function native(directory, name)
  local key = "scripts.sandbox_windows_" .. name
  local module = package.loaded[key]
  if not module then
    module = dofile(vim.fs.joinpath(directory, "sandbox_windows_" .. name .. ".lua"))
    package.loaded[key] = module
  end
  return module
end

---@class Neoagent.WindowsSandboxCustody
---@field id? string
---@field _job? Neoagent.WindowsSandboxJob
---@field _scripts string
---@field _recover async fun(id: string): true
---@field _released boolean
---@field _finishing boolean
---@field _failure? Neoagent.Error
---@field _changed Neoagent.Notification
local Custody = {}
Custody.__index = Custody
---@type table<Neoagent.WindowsSandboxCustody, true>
local retained = {}

-- The editor creates the authenticated namespace and Job before starting its
-- host. The host can only open this Job; no handoff interval loses custody.
function Custody:start()
  assert(not self.id, "Windows sandbox custody already started")
  retained[self] = true
  local text = require("neoagent.subprocess.windows_text")
  local function failure(stage, code)
    error(
      util.error("sandbox_unavailable", "Windows sandbox custody failed at " .. stage, "errno=" .. tostring(code or 0)),
      0
    )
  end
  local function wide(value)
    return (assert(text.wide(value)))
  end
  local coordinator = native(self._scripts, "coordinator").new({
    wide = wide,
    utf8 = text.narrow,
    failure = failure,
  })
  local registration = vim.json.decode((assert(coordinator.read(), "Windows sandbox setup is required")))
  assert(
    type(registration.owner_sid) == "string" and type(registration.directory) == "string",
    "Invalid Windows sandbox registration"
  )
  self.id = (assert(vim.uv.random(16)):gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
  local name = "NeoagentSandbox-"
    .. vim.fn.sha256(registration.directory:gsub("/", "\\"):lower()):sub(1, 32)
    .. "-job-"
    .. self.id
  local deps = { identity = registration.owner_sid, wide = wide, failure = failure }
  local namespace = native(self._scripts, "objects").new(name, deps)
  self._job = native(self._scripts, "job").new(namespace, deps)
  self._job:create()
end

---@return boolean
function Custody:is_released()
  return self._released
end

---@async
---@return true
function Custody:wait_release()
  while not self._released do
    self._changed.wait()
  end
  return true
end

-- One retained owner retries release after bounded cleanup has failed. It
-- keeps the authenticated Job open until the host cannot execute more work,
-- native accounting confirms emptiness, and the journal confirms retirement.
---@async
---@param result Neoagent.WorkerResult
---@param terminal? Neoagent.SandboxTerminalEvent
---@param host? Neoagent.WorkerLease
---@return true?, string?
function Custody:finish(result, terminal, host)
  assert(not self._finishing, "Windows sandbox custody already finalizing")
  self._finishing = true
  async.run(function()
    if result.execution == "unknown" and result.code == nil then
      error(util.error("sandbox_unavailable", "Native host execution could not be established"), 0)
    end
    if result.execution ~= "not_started" and result.code == nil then
      assert(host):wait_release()
    end
    local acknowledged = terminal and terminal.cleanup and terminal.cleanup.released
    local delay = 25
    while not self._released do
      local ok, err = pcall(function()
        local job = self._job
        if job then
          job:terminate()
          if not job:observe() then
            return
          end
        end
        if result.execution ~= "not_started" and not acknowledged then
          self._recover(assert(self.id))
        end
        if job then
          job:close()
        end
        self._released = true
        retained[self] = nil
      end)
      if not ok then
        self._failure = util.normalize_error(err, "sandbox_unavailable")
        delay = math.min(delay * 2, 30000)
      end
      self._changed.notify()
      if not self._released then
        self._changed.wait(delay)
      end
    end
  end, {
    error_kind = "sandbox_unavailable",
    on_done = function(result_value)
      if result_value.ok == false then
        self._failure = result_value.error
        self._changed.notify()
      end
    end,
  })
  local deadline = vim.uv.hrtime() + require("neoagent.subprocess.validate").REAP_MS * 1000000
  while not self._released do
    local remaining = math.ceil((deadline - vim.uv.hrtime()) / 1000000)
    if remaining <= 0 then
      return nil, self._failure and self._failure.message or "Windows sandbox authority release is still pending"
    end
    self._changed.wait(remaining)
  end
  local failure = terminal and terminal.cleanup and terminal.cleanup.error
  if failure then
    return nil, "Native sandbox cleanup failed at " .. failure.stage .. " (errno=" .. tostring(failure.errno) .. ")"
  end
  return true
end

---@param scripts string
---@param recover async fun(id: string): true
---@return Neoagent.WindowsSandboxCustody
function M.new(scripts, recover)
  return setmetatable({
    _scripts = scripts,
    _recover = recover,
    _released = false,
    _finishing = false,
    _changed = async.notification(),
  }, Custody)
end

return M
