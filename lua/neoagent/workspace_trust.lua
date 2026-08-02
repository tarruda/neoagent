local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
local Store = {}
Store.__index = Store
local Policy = {}
Policy.__index = Policy
local process_session = {}

local DIRECTORY_MODE = 448
local FILE_MODE = 384
local LOCK_STALE_MS = 120000
local LOCK_TIMEOUT_MS = 3000

local function failure(message, detail)
  if detail ~= nil then
    detail = tostring(detail):gsub("[%z\1-\31\127]", " ")
    if #detail > 1000 then detail = detail:sub(1, 997) .. "..." end
  end
  return util.error("workspace_trust", message, detail)
end

local function absolute(path)
  if fs.is_absolute(path) then return path end
  return fs.join(vim.fn.getcwd(), path)
end

local function git_marker(directory)
  local marker = fs.join(directory, ".git")
  local stat = vim.uv.fs_stat(marker)
  if not stat then return false end
  if stat.type == "file" then return true end
  return stat.type == "directory"
    and vim.uv.fs_stat(fs.join(marker, "HEAD")) ~= nil
end

function M.target(cwd)
  assert(type(cwd) == "string" and cwd ~= "",
    "workspace trust cwd is required")
  local canonical = fs.canonical(absolute(cwd))
  local current = canonical
  while true do
    if git_marker(current) then return current end
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    current = parent
  end
  return canonical
end

function M.key(path, os_name)
  local value = fs.normalize(path)
  if (os_name or jit.os) == "Windows" then value = value:lower() end
  return value
end

local function validate_document(value)
  if type(value) ~= "table" or util.is_list(value) then
    return nil, "expected an object"
  end
  for name in pairs(value) do
    if name ~= "version" and name ~= "trusted" then
      return nil, "unsupported field"
    end
  end
  if value.version ~= 1 then return nil, "unsupported version" end
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
    if seen[key] then return nil, "trusted entries must be unique" end
    if previous and previous >= path then
      return nil, "trusted entries must be sorted"
    end
    seen[key], previous = true, path
  end
  return util.copy(value.trusted)
end

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

function Store:list()
  local trusted, err = self:_read_all()
  if not trusted then return nil, err end
  return util.copy(trusted)
end

function Store:is_trusted(cwd)
  local trusted, err = self:_read_all()
  if not trusted then return nil, err end
  local selected = M.key(M.target(cwd))
  for _, path in ipairs(trusted) do
    if M.key(path) == selected then return true end
  end
  return false
end

local function close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

function Store:_lock()
  local lock_path = self.path .. ".lock"
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    local acquired = false
    local started = util.now_ms()
    local function settle_error(err)
      close_handle(timer)
      done.reject(err)
    end
    local function attempt()
      local fd, open_err = vim.uv.fs_open(lock_path, "wx", FILE_MODE)
      if fd then
        local closed, close_err = vim.uv.fs_close(fd)
        if not closed then
          vim.uv.fs_unlink(lock_path)
          settle_error(failure("Failed to create workspace trust lock", close_err))
          return
        end
        acquired = true
        close_handle(timer)
        done.resolve(function()
          if not acquired then return true end
          acquired = false
          local removed, remove_err = vim.uv.fs_unlink(lock_path)
          if not removed and remove_err
              and not tostring(remove_err):find("ENOENT", 1, true) then
            return nil, failure("Failed to release workspace trust lock", remove_err)
          end
          return true
        end)
        return
      end
      if open_err and not tostring(open_err):find("EEXIST", 1, true) then
        settle_error(failure("Failed to create workspace trust lock", open_err))
        return
      end
      local stat = vim.uv.fs_stat(lock_path)
      local modified = stat and stat.mtime
        and (stat.mtime.sec * 1000 + math.floor((stat.mtime.nsec or 0) / 1000000))
      if modified and util.now_ms() - modified > LOCK_STALE_MS then
        local removed = vim.uv.fs_unlink(lock_path)
        if removed then
          attempt()
          return
        end
      end
      if util.now_ms() - started >= LOCK_TIMEOUT_MS then
        settle_error(failure("Timed out waiting for workspace trust lock"))
        return
      end
      timer:start(50, 0, attempt)
    end
    attempt()
    return function()
      close_handle(timer)
    end
  end)
end

local function random_suffix()
  local bytes, err = vim.uv.random(8)
  if not bytes then return nil, err end
  return (bytes:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

function Store:_write_all(trusted)
  local suffix, random_err = random_suffix()
  if not suffix then
    return nil, failure("Failed to create workspace trust temporary file", random_err)
  end
  local temporary = self.path .. "." .. suffix .. ".tmp"
  local document = { version = 1, trusted = util.copy(trusted) }
  local written, write_err = fs.write_all(
    temporary, util.json_encode(document) .. "\n", "wx", FILE_MODE)
  if not written then
    return nil, failure("Failed to write workspace trust store", write_err)
  end
  local replaced, replace_err = vim.uv.fs_rename(temporary, self.path)
  if not replaced then
    vim.uv.fs_unlink(temporary)
    return nil, failure("Failed to replace workspace trust store", replace_err)
  end
  return true
end

function Store:_modify(cwd, remove)
  return async.run(function()
    local directory = vim.fs.dirname(self.path)
    local existed = vim.uv.fs_stat(directory) ~= nil
    local created, create_err = fs.mkdirp(directory)
    if not created then
      error(failure("Failed to create workspace trust directory", create_err), 0)
    end
    if not existed then
      local secured, secure_err = vim.uv.fs_chmod(directory, DIRECTORY_MODE)
      if not secured then
        error(failure("Failed to secure workspace trust directory", secure_err), 0)
      end
    end

    local release = self:_lock()
    local ok, result = pcall(function()
      local trusted, read_err = self:_read_all()
      if not trusted then error(read_err, 0) end
      local selected = M.target(cwd)
      local selected_key = M.key(selected)
      local next_values = {}
      local found = false
      for _, path in ipairs(trusted) do
        if M.key(path) == selected_key then
          found = true
          if not remove then next_values[#next_values + 1] = path end
        else
          next_values[#next_values + 1] = path
        end
      end
      if not remove and not found then next_values[#next_values + 1] = selected end
      table.sort(next_values)
      if (remove and found) or (not remove and not found) then
        local written, write_err = self:_write_all(next_values)
        if not written then error(write_err, 0) end
      end
      return true
    end)
    local released, release_err = release()
    if not ok then error(result, 0) end
    if not released then error(release_err, 0) end
    return { ok = true }
  end, { error_kind = "workspace_trust" })
end

function Store:trust(cwd)
  return self:_modify(cwd, false)
end

function Store:remove(cwd)
  if not vim.uv.fs_stat(self.path) then
    return async.run(function() return { ok = true } end,
      { error_kind = "workspace_trust" })
  end
  return self:_modify(cwd, true)
end

function M.new_store(path)
  assert(type(path) == "string" and path ~= "",
    "workspace trust path is required")
  return setmetatable({ path = fs.normalize(absolute(path)) }, Store)
end

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
  if #reason > 500 then reason = reason:sub(1, 497) .. "..." end
  return "Tools run on the host because sandbox activation failed: " .. reason
end

function Policy:_dialog(target)
  local request = {
    placement = "transcript",
    title = "Trust workspace?",
    body = table.concat({
      target,
      "",
      "Repository content may contain prompt injection.",
      (self.controller_name or "Neo")
        .. " can load AGENTS.md and project skills, read and modify files, and run commands.",
      sandbox_text(self.sandbox_status),
    }, "\n"),
    actions = {
      { id = "trust", label = "Trust workspace", key = "t" },
      { id = "session", label = "Trust until Neovim exits", key = "s" },
      { id = "cancel", label = "Cancel", key = "q" },
    },
  }
  if self.controller_name then
    request.controller = self.controller_name
  end
  return request
end

function Policy:is_trusted(cwd)
  local target = M.target(cwd)
  if self.session[M.key(target)] then return true, nil, target end
  local trusted, err = self.store:is_trusted(target)
  return trusted, err, target
end

function Policy:trust_session(cwd)
  local target = M.target(cwd)
  self.session[M.key(target)] = true
  return true
end

function Policy:_close()
  if self.close then pcall(self.close) end
end

function Policy:_notify(err)
  if self.notify then
    self.notify(err)
  else
    vim.notify("neoagent: " .. err.message, vim.log.levels.ERROR)
  end
end

function Policy:request(cwd)
  local trusted, err, target = self:is_trusted(cwd)
  if trusted then return true end
  if err then
    self:_notify(err)
    return nil, err
  end
  local key = M.key(target)
  if self.pending[key] or self.scheduled[key] then return false end
  self.scheduled[key] = true
  vim.schedule(function()
    self.scheduled[key] = nil
    local current, current_err = self:is_trusted(target)
    if current then return end
    if current_err then
      self:_notify(current_err)
      return
    end
    if self.pending[key] then return end
    if self.activate then
      local ok, activate_err = pcall(self.activate)
      if not ok then
        self:_notify(failure("Failed to activate workspace trust prompt",
          activate_err))
        return
      end
    end
    local run
    run = async.run(function()
      local result = self.dialogs:show(self:_dialog(target)):await()
      if not result.ok or result.action == "cancel" then
        self:_close()
        return result.ok and { ok = false,
          error = failure("Workspace trust was cancelled") } or result
      end
      if result.action == "session" then
        self:trust_session(target)
        return { ok = true, target = target, persistent = false }
      end
      local saved = self.store:trust(target):await()
      if not saved.ok then error(saved.error, 0) end
      return { ok = true, target = target, persistent = true }
    end, {
      error_kind = "workspace_trust",
      on_done = function(result)
        if self.pending[key] == run then self.pending[key] = nil end
        if not result.ok and not result.presenter_unavailable and result.error.kind ~= "cancelled"
            and result.error.message ~= "Workspace trust was cancelled"
            and not (result.error.kind == "dialog"
              and result.error.message == "dialog dismissed by user") then
          self:_notify(result.error)
        end
      end,
    })
    self.pending[key] = run
  end)
  return false
end

function Policy:check(cwd)
  local trusted, err, target = self:is_trusted(cwd)
  if trusted then return true end
  if err then return nil, err end
  self:request(target)
  local display = target:gsub("[%z\1-\31\127]", " ")
  if #display > 900 then display = display:sub(1, 897) .. "..." end
  return nil, failure("Workspace trust is required for " .. display)
end

function Policy:set_sandbox_status(status)
  self.sandbox_status = util.copy(status)
end

function Policy:attach(opts)
  opts = opts or {}
  assert(opts.activate == nil or type(opts.activate) == "function",
    "workspace trust activate callback must be a function")
  assert(opts.close == nil or type(opts.close) == "function",
    "workspace trust close callback must be a function")
  self.activate = opts.activate
  self.close = opts.close
  return self
end

function Policy:attach_window(window, controller)
  assert(type(window) == "table" and window._neoagent_window
      and type(window.controllers) == "function"
      and type(window.active) == "function"
      and type(window.select) == "function"
      and type(window.close) == "function",
    "workspace trust Window is invalid")
  assert(type(controller) == "table" and controller._neoagent_controller
      and type(controller.config) == "function",
    "workspace trust Controller is invalid")
  local attached = false
  for _, candidate in ipairs(window:controllers()) do
    if candidate == controller then attached = true break end
  end
  assert(attached, "workspace trust Controller is not attached to the Window")
  local name = controller:config().name
  assert(self.controller_name == nil or self.controller_name == name,
    "workspace trust Controller name does not match the policy")
  self.controller_name = name
  return self:attach({
    activate = function()
      if window:active() == controller then return end
      local selected, err = window:select(controller)
      if not selected then
        error(err and err.message
          or "Failed to select workspace trust Controller", 0)
      end
    end,
    close = function() window:close() end,
  })
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table" and not util.is_list(opts),
    "workspace trust options must be an object")
  assert(type(opts.path) == "string" and opts.path ~= "",
    "workspace trust path is required")
  assert(type(opts.dialogs) == "table"
      and type(opts.dialogs.show) == "function",
    "workspace trust dialogs are required")
  assert(opts.notify == nil or type(opts.notify) == "function",
    "workspace trust notify callback must be a function")
  assert(opts.controller == nil
      or type(opts.controller) == "string" and opts.controller ~= "",
    "workspace trust Controller name must be a non-empty string")
  return setmetatable({
    controller_name = opts.controller,
    store = opts.store or M.new_store(opts.path),
    dialogs = opts.dialogs,
    sandbox_status = util.copy(opts.sandbox_status),
    notify = opts.notify,
    session = opts.session or process_session,
    pending = {},
    scheduled = {},
  }, Policy)
end

local function default_view(opts)
  return require("neoagent.ui").new(opts)
end

function M.view(factory, policy, controller_name)
  assert(factory == nil or type(factory) == "function",
    "workspace trust View factory must be a function")
  assert(type(policy) == "table" and type(policy.request) == "function",
    "workspace trust policy is required")
  assert(type(controller_name) == "string" and controller_name ~= "",
    "workspace trust Controller name is required")
  factory = factory or default_view
  return function(opts)
    local view = factory(opts)
    assert(type(view) == "table" and type(view.open) == "function",
      "workspace trust View must implement open")
    local selected, workspace
    local function request_if_visible()
      if selected == controller_name and workspace
          and type(view.is_open) == "function" and view:is_open() then
        policy:request(workspace)
      end
    end
    local set_context = view.set_context
    if type(set_context) == "function" then
      view.set_context = function(self, context, ...)
        if type(context) == "table" then
          selected, workspace = context.name, context.workspace
        end
        local result = { set_context(self, context, ...) }
        request_if_visible()
        return unpack(result)
      end
    end
    local open = view.open
    view.open = function(self, ...)
      local result = { open(self, ...) }
      if result[1] then request_if_visible() end
      return unpack(result)
    end
    return view
  end
end

function M.compose(configured, opts)
  assert(type(configured) == "table" and not util.is_list(configured),
    "workspace trust Controller configuration must be an object")
  assert(type(configured.name) == "string" and configured.name ~= "",
    "workspace trust Controller configuration requires a name")
  opts = opts or {}
  assert(type(opts) == "table" and not util.is_list(opts),
    "workspace trust composition options must be an object")
  local path = opts.path
  if path == nil and type(configured.workspace_trust) == "table" then
    path = configured.workspace_trust.path
  end
  local policy = M.new({
    path = path,
    dialogs = opts.dialogs,
    sandbox_status = opts.sandbox_status,
    notify = opts.notify,
    store = opts.store,
    session = opts.session,
    controller = configured.name,
  })
  return M.view(configured.view, policy, configured.name), policy
end

return M
