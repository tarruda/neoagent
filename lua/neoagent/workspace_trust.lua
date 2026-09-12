local async = require("neoagent.async")
local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
---@alias Neoagent.TrustRequestState "trusted"|"active"|"scheduled"
---@alias Neoagent.TrustSandboxStatus {enabled: boolean, active: boolean, platform?: string, message?: string}

---@class Neoagent.WorkspaceTrustError: Neoagent.Error
---@field pending? true
---@field request_state? Neoagent.TrustRequestState

---@alias Neoagent.TrustStoreResult Neoagent.AsyncSuccess|Neoagent.AsyncFailure
---@alias Neoagent.TrustStoreRun Neoagent.Run<Neoagent.TrustStoreResult, nil>

---@class Neoagent.WorkspaceTrustStore
---@field path string
local Store = {}
Store.__index = Store
---@class Neoagent.WorkspaceTrustSuccess
---@field ok true
---@field target string
---@field persistent boolean
---@field already_trusted? true

---@alias Neoagent.WorkspaceTrustResult Neoagent.WorkspaceTrustSuccess|Neoagent.DialogFailure
---@alias Neoagent.WorkspaceTrustRun Neoagent.Run<Neoagent.WorkspaceTrustResult, nil>

---@class Neoagent.WorkspaceTrustAttachment
---@field activate? fun()
---@field close? fun()
---@field on_trusted? fun(target: string)
---@field on_result? fun(result: Neoagent.WorkspaceTrustResult)

---@class Neoagent.WorkspaceTrustCompositionOptions
---@field path? string
---@field dialogs Neoagent.Dialogs
---@field sandbox_status? Neoagent.TrustSandboxStatus
---@field notify? fun(error: Neoagent.Error)
---@field agent? string
---@field store? Neoagent.WorkspaceTrustStore
---@field session? table<string, boolean>

---@class Neoagent.WorkspaceTrustOptions: Neoagent.WorkspaceTrustCompositionOptions
---@field path string

---@class Neoagent.WorkspaceTrust: Neoagent.WorkspaceTrustAttachment
---@field agent_name? string
---@field store Neoagent.WorkspaceTrustStore
---@field dialogs Neoagent.Dialogs
---@field sandbox_status? Neoagent.TrustSandboxStatus
---@field notify fun(error: Neoagent.Error)
---@field session table<string, boolean>
---@field pending table<string, Neoagent.WorkspaceTrustRun>
---@field scheduled table<string, boolean>
local Policy = {}
Policy.__index = Policy
---@type table<string, boolean>
local process_session = {}

local DIRECTORY_MODE = 448
local FILE_MODE = 384
local LOCK_TIMEOUT_MS = 3000

---@param message string
---@param detail? unknown
---@return Neoagent.WorkspaceTrustError
local function failure(message, detail)
  if detail ~= nil then
    detail = tostring(detail):gsub("[%z\1-\31\127]", " ")
    if #detail > 1000 then
      detail = detail:sub(1, 997) .. "..."
    end
  end
  return util.error("workspace_trust", message, detail)
end

---@param path string
---@return string
local function absolute(path)
  if fs.is_absolute(path) then
    return path
  end
  return fs.join(vim.fn.getcwd(), path)
end

---@param directory string
---@return boolean
local function git_marker(directory)
  local marker = fs.join(directory, ".git")
  local stat = vim.uv.fs_stat(marker)
  if not stat then
    return false
  end
  if stat.type == "file" then
    return true
  end
  return stat.type == "directory" and vim.uv.fs_stat(fs.join(marker, "HEAD")) ~= nil
end

---@param cwd string
---@return string
function M.target(cwd)
  assert(type(cwd) == "string" and cwd ~= "", "workspace trust cwd is required")
  local canonical = fs.canonical(absolute(cwd))
  local current = canonical
  while true do
    if git_marker(current) then
      return current
    end
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    current = parent
  end
  return canonical
end

---@param path string
---@param os_name? string
---@return string
function M.key(path, os_name)
  local value = fs.normalize(path)
  if (os_name or jit.os) == "Windows" then
    value = value:lower()
  end
  return value
end

---@param value unknown
---@return string[]?, string?
local function validate_document(value)
  if type(value) ~= "table" or util.is_list(value) then
    return nil, "expected an object"
  end
  for name in pairs(value) do
    if name ~= "version" and name ~= "trusted" then
      return nil, "unsupported field"
    end
  end
  if value.version ~= 1 then
    return nil, "unsupported version"
  end
  if type(value.trusted) ~= "table" or not util.is_list(value.trusted) then
    return nil, "trusted must be a list"
  end
  local seen, previous = {}, nil
  for _, path in ipairs(value.trusted) do
    if type(path) ~= "string" or path == "" or not fs.is_absolute(path) then
      return nil, "trusted entries must be absolute paths"
    end
    if fs.normalize(path) ~= path then
      return nil, "trusted entries must be normalized paths"
    end
    if vim.uv.fs_stat(path) and M.target(path) ~= path then
      return nil, "trusted entries must be canonical trust targets"
    end
    local key = M.key(path)
    if seen[key] then
      return nil, "trusted entries must be unique"
    end
    if previous and previous >= path then
      return nil, "trusted entries must be sorted"
    end
    seen[key], previous = true, path
  end
  return util.copy(value.trusted)
end

---@return string[]?, Neoagent.Error?
function Store:_read_all()
  local stat, stat_err = vim.uv.fs_stat(self.path)
  if not stat then
    if stat_err and not tostring(stat_err):find("ENOENT", 1, true) then
      return nil, failure("Failed to inspect workspace trust store", stat_err)
    end
    return {}
  end
  if stat.type ~= "file" then
    return nil, failure("Invalid workspace trust store", "expected a file")
  end
  local content, read_err = fs.read(self.path)
  if not content then
    return nil, failure("Failed to read workspace trust store", read_err)
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    return nil, failure("Invalid workspace trust store", "invalid JSON")
  end
  local trusted, validation_err = validate_document(decoded)
  if not trusted then
    return nil, failure("Invalid workspace trust store", validation_err)
  end
  return trusted
end

---@return string[]?, Neoagent.Error?
function Store:list()
  local trusted, err = self:_read_all()
  if not trusted then
    return nil, err
  end
  return util.copy(trusted)
end

---@param cwd string
---@return boolean?, Neoagent.Error?
function Store:is_trusted(cwd)
  local trusted, err = self:_read_all()
  if not trusted then
    return nil, err
  end
  local selected = M.key(M.target(cwd))
  for _, path in ipairs(trusted) do
    if M.key(path) == selected then
      return true
    end
  end
  return false
end

---@param err unknown
---@param releasing boolean
---@return Neoagent.Error
local function trust_lock_error(err, releasing)
  err = util.normalize_error(err, "file_lock")
  if err.kind == "cancelled" then
    return err
  end
  if releasing then
    return failure("Failed to release workspace trust lock", rawget(err, "detail") or err.message)
  end
  if rawget(err, "code") == "timeout" then
    return failure("Timed out waiting for workspace trust lock", rawget(err, "detail"))
  end
  return failure("Failed to acquire workspace trust lock", rawget(err, "detail") or err.message)
end

---@async
---@return fun(): true?, Neoagent.Error?
function Store:_lock()
  local lock = file_lock.new({
    path = self.path .. ".lock",
    timeout_ms = LOCK_TIMEOUT_MS,
    poll_ms = 50,
    mode = FILE_MODE,
  })
  local ok, lease = pcall(function()
    return lock:acquire_async()
  end)
  if not ok then
    error(trust_lock_error(lease, false), 0)
  end
  return function()
    local released, release_err = lease:release()
    if not released then
      return nil, trust_lock_error(release_err, true)
    end
    return true
  end
end

---@param trusted string[]
---@return true?, Neoagent.Error?
function Store:_write_all(trusted)
  local document = { version = 1, trusted = util.copy(trusted) }
  local written, write_err, stage =
    fs.atomic_replace(self.path, util.json_encode(document) .. "\n", { mode = FILE_MODE })
  if not written then
    local action = stage == "temporary" and "create workspace trust temporary file"
      or stage == "rename" and "replace workspace trust store"
      or "write workspace trust store"
    return nil, failure("Failed to " .. action, write_err)
  end
  return true
end

---@param cwd string
---@param remove boolean
---@return Neoagent.TrustStoreRun
function Store:_modify(cwd, remove)
  return async.run(
    ---@return Neoagent.TrustStoreResult
    function()
      local directory = vim.fs.dirname(self.path)
      local created, create_err = fs.ensure_private_directory(directory, DIRECTORY_MODE)
      if not created then
        error(failure("Failed to create workspace trust directory", create_err), 0)
      end

      local release = self:_lock()
      local ok, result = pcall(function()
        local trusted, read_err = self:_read_all()
        if not trusted then
          error(read_err, 0)
        end
        local selected = M.target(cwd)
        local selected_key = M.key(selected)
        local next_values = {}
        local found = false
        for _, path in ipairs(trusted) do
          if M.key(path) == selected_key then
            found = true
            if not remove then
              next_values[#next_values + 1] = path
            end
          else
            next_values[#next_values + 1] = path
          end
        end
        if not remove and not found then
          next_values[#next_values + 1] = selected
        end
        table.sort(next_values)
        if (remove and found) or (not remove and not found) then
          local written, write_err = self:_write_all(next_values)
          if not written then
            error(write_err, 0)
          end
        end
        return true
      end)
      local released, release_err = release()
      if not ok then
        error(result, 0)
      end
      if not released then
        error(release_err, 0)
      end
      return { ok = true }
    end,
    { error_kind = "workspace_trust" }
  )
end

---@param cwd string
---@return Neoagent.TrustStoreRun
function Store:trust(cwd)
  return self:_modify(cwd, false)
end

---@param cwd string
---@return Neoagent.TrustStoreRun
function Store:remove(cwd)
  if not vim.uv.fs_stat(self.path) then
    return async.run(function()
      return { ok = true }
    end, { error_kind = "workspace_trust" })
  end
  return self:_modify(cwd, true)
end

---@param path string
---@return Neoagent.WorkspaceTrustStore
function M.new_store(path)
  assert(type(path) == "string" and path ~= "", "workspace trust path is required")
  return setmetatable({ path = fs.normalize(absolute(path)) }, Store)
end

---@param status? Neoagent.TrustSandboxStatus
---@return string
local function sandbox_text(status)
  status = status or { enabled = false, active = false }
  if status.active then
    local platform = status.platform and (" " .. status.platform) or ""
    return "Tools use the native" .. platform .. " sandbox."
  end
  if not status.enabled then
    return "Tools run on the host because sandboxing is disabled."
  end
  local reason = status.message or "sandbox activation failed"
  reason = tostring(reason):gsub("[%z\1-\31\127]", " ")
  if #reason > 500 then
    reason = reason:sub(1, 497) .. "..."
  end
  return "Tool execution is blocked because sandbox activation failed: " .. reason
end

---@param target string
---@return Neoagent.DialogRequest
function Policy:_dialog(target)
  ---@type Neoagent.DialogRequest
  local request = {
    placement = "transcript",
    title = "Trust workspace?",
    body = table.concat({
      target,
      "",
      "Repository content may contain prompt injection.",
      (self.agent_name or "Neo") .. " can load AGENTS.md and project skills, read and modify files, and run commands.",
      sandbox_text(self.sandbox_status),
    }, "\n"),
    actions = {
      { id = "trust", label = "Trust workspace", key = "t" },
      { id = "session", label = "Trust until Neovim exits", key = "s" },
      { id = "cancel", label = "Cancel", key = "q" },
    },
  }
  if self.agent_name then
    request.agent = self.agent_name
  end
  return request
end

---@param cwd string
---@return boolean?, Neoagent.Error?, string
function Policy:is_trusted(cwd)
  local target = M.target(cwd)
  if self.session[M.key(target)] then
    return true, nil, target
  end
  local trusted, err = self.store:is_trusted(target)
  return trusted, err, target
end

---@param cwd string
---@return true
function Policy:trust_session(cwd)
  local target = M.target(cwd)
  self.session[M.key(target)] = true
  return true
end

function Policy:_close()
  if self.close then
    pcall(self.close)
  end
end

---@param err Neoagent.Error
function Policy:_notify(err)
  self.notify(err)
end

---@param result Neoagent.WorkspaceTrustResult
function Policy:_finish(result)
  if self.on_result then
    local ok, err = pcall(self.on_result, util.copy(result))
    if not ok then
      self:_notify(util.normalize_error(err, "workspace_trust"))
    end
  end
  if result.ok and self.on_trusted then
    ---@cast result Neoagent.WorkspaceTrustSuccess
    local ok, err = pcall(self.on_trusted, result.target)
    if not ok then
      self:_notify(util.normalize_error(err, "workspace_trust"))
    end
  end
end

---@param cwd string
---@return boolean?, Neoagent.Error?, Neoagent.TrustRequestState?
function Policy:request(cwd)
  local trusted, err, target = self:is_trusted(cwd)
  if trusted then
    return true, nil, "trusted"
  end
  if err then
    self:_notify(err)
    return nil, err
  end
  local key = M.key(target)
  if self.pending[key] then
    return false, nil, "active"
  end
  if self.scheduled[key] then
    return false, nil, "scheduled"
  end
  self.scheduled[key] = true
  vim.schedule(function()
    self.scheduled[key] = nil
    local current, current_err = self:is_trusted(target)
    if current then
      self:_finish({
        ok = true,
        target = target,
        persistent = true,
        already_trusted = true,
      })
      return
    end
    if current_err then
      self:_notify(current_err)
      self:_finish({ ok = false, error = current_err })
      return
    end
    if self.pending[key] then
      return
    end
    if self.activate then
      local ok, activate_err = pcall(self.activate)
      if not ok then
        local activate_failure = failure("Failed to activate workspace trust prompt", activate_err)
        self:_notify(activate_failure)
        self:_finish({ ok = false, error = activate_failure })
        return
      end
    end
    ---@type Neoagent.WorkspaceTrustRun
    local run
    run = async.run(
      ---@return Neoagent.WorkspaceTrustResult
      function()
        local result = self.dialogs:show(self:_dialog(target)):await()
        if not result.ok or result.action == "cancel" then
          self:_close()
          if result.ok then
            return { ok = false, error = failure("Workspace trust was cancelled") }
          end
          ---@cast result Neoagent.DialogFailure
          return result
        end
        if result.action == "session" then
          self:trust_session(target)
          return { ok = true, target = target, persistent = false }
        end
        local saved = self.store:trust(target):await()
        if not saved.ok then
          error(saved.error, 0)
        end
        return { ok = true, target = target, persistent = true }
      end,
      {
        error_kind = "workspace_trust",
        on_done = function(result)
          if self.pending[key] == run then
            self.pending[key] = nil
          end
          self:_finish(result)
          if
            not result.ok
            and not result.presenter_unavailable
            and result.error.kind ~= "cancelled"
            and result.error.message ~= "Workspace trust was cancelled"
            and not (result.error.kind == "dialog" and result.error.message == "dialog dismissed by user")
          then
            self:_notify(result.error)
          end
        end,
      }
    )
    self.pending[key] = run
  end)
  return false, nil, "scheduled"
end

---@param cwd string
---@return true?, Neoagent.Error?
function Policy:check(cwd)
  local trusted, err, target = self:is_trusted(cwd)
  if trusted then
    return true
  end
  if err then
    return nil, err
  end
  local requested, request_err, request_state = self:request(target)
  if requested then
    return true
  end
  if requested == nil then
    return nil, request_err
  end
  local display = target:gsub("[%z\1-\31\127]", " ")
  if #display > 900 then
    display = display:sub(1, 897) .. "..."
  end
  local err = failure("Workspace trust is required for " .. display)
  err.pending = true
  err.request_state = request_state
  return nil, err
end

---@param status Neoagent.TrustSandboxStatus
function Policy:set_sandbox_status(status)
  self.sandbox_status = util.copy(status)
end

---@param opts? Neoagent.WorkspaceTrustAttachment
---@return Neoagent.WorkspaceTrust
function Policy:attach(opts)
  opts = opts or {}
  assert(
    opts.activate == nil or type(opts.activate) == "function",
    "workspace trust activate callback must be a function"
  )
  assert(opts.close == nil or type(opts.close) == "function", "workspace trust close callback must be a function")
  assert(
    opts.on_trusted == nil or type(opts.on_trusted) == "function",
    "workspace trust on_trusted callback must be a function"
  )
  assert(
    opts.on_result == nil or type(opts.on_result) == "function",
    "workspace trust on_result callback must be a function"
  )
  self.activate = opts.activate
  self.close = opts.close
  self.on_trusted = opts.on_trusted
  self.on_result = opts.on_result
  return self
end

---@param opts Neoagent.WorkspaceTrustOptions
---@return Neoagent.WorkspaceTrust
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table" and not util.is_list(opts), "workspace trust options must be an object")
  assert(type(opts.path) == "string" and opts.path ~= "", "workspace trust path is required")
  assert(
    type(opts.dialogs) == "table" and type(opts.dialogs.show) == "function",
    "workspace trust dialogs are required"
  )
  assert(opts.notify == nil or type(opts.notify) == "function", "workspace trust notify callback must be a function")
  assert(
    opts.agent == nil or type(opts.agent) == "string" and opts.agent ~= "",
    "workspace trust Agent name must be a non-empty string"
  )
  return setmetatable({
    agent_name = opts.agent,
    store = opts.store or M.new_store(opts.path),
    dialogs = opts.dialogs,
    sandbox_status = util.copy(opts.sandbox_status),
    notify = opts.notify or function() end,
    session = opts.session or process_session,
    pending = {},
    scheduled = {},
  }, Policy)
end

---@param configured {name: string, workspace_trust?: {path: string}|false}
---@param opts Neoagent.WorkspaceTrustCompositionOptions
---@return Neoagent.WorkspaceTrust
function M.compose(configured, opts)
  assert(
    type(configured) == "table" and not util.is_list(configured),
    "workspace trust Agent configuration must be an object"
  )
  assert(
    type(configured.name) == "string" and configured.name ~= "",
    "workspace trust Agent configuration requires a name"
  )
  opts = opts or {}
  assert(type(opts) == "table" and not util.is_list(opts), "workspace trust composition options must be an object")
  local path = opts.path
  if path == nil and type(configured.workspace_trust) == "table" then
    path = configured.workspace_trust.path
  end
  local policy = M.new({
    path = assert(path, "workspace trust path is required"),
    dialogs = opts.dialogs,
    sandbox_status = opts.sandbox_status,
    notify = opts.notify,
    store = opts.store,
    session = opts.session,
    agent = configured.name,
  })
  return policy
end

return M
