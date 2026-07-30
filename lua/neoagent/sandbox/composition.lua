local util = require("neoagent.util")
local path_module = require("neoagent.sandbox.path")

local M = {}

local function bounded(value)
  value = util.trim(tostring(value or ""):gsub("[%z\1-\31\127]", " "))
  if value == "" then value = "requirements check failed" end
  if #value > 1000 then value = value:sub(1, 997) .. "..." end
  return value
end

local function workspace_root(ctx, paths)
  local context = ctx and ctx.context
  local workspace = context and context.workspace or context
  local root = type(workspace) == "table" and workspace.root or nil
  if type(root) ~= "string" or root == "" then
    error(util.error("sandbox", "Sandbox requires a workspace root"), 0)
  end
  return paths.normalize(root)
end

local function canonical_directory(path, paths)
  if type(path) ~= "string" or path == "" then return end
  local normalized = paths.normalize(path)
  local canonical = paths.realpath(normalized)
  local stat = canonical and paths.stat(canonical)
  if stat and stat.type == "directory" then
    return canonical
  end
end

local function temporary_roots(paths, configured)
  local active = canonical_directory(configured or vim.uv.os_tmpdir(), paths)
  if not active and paths == path_module.posix then
    active = canonical_directory("/tmp", paths)
  end
  if not active then
    error(util.error("sandbox",
      "Sandbox requires a host temporary directory"), 0)
  end
  local roots, seen = {}, {}
  local sources = { active }
  if not configured and paths == path_module.posix then
    table.insert(sources, 1, "/tmp")
  end
  for _, source in ipairs(sources) do
    local path = canonical_directory(source, paths)
    if path and not seen[path] then
      seen[path] = true
      roots[#roots + 1] = path
    end
  end
  return active, roots
end

function M.default_profile(ctx, paths, temporary_root)
  paths = paths or path_module.posix
  local root = workspace_root(ctx, paths)
  local temporary, shared_roots = temporary_roots(paths, temporary_root)
  local entries = {}
  if paths.key(root) ~= paths.key(paths.root(root)) then
    entries[#entries + 1] = { path = root, access = "write" }
  end
  for _, path in ipairs(shared_roots) do
    entries[#entries + 1] = { path = path, access = "write" }
  end
  entries[#entries + 1] = {
    path = paths.join(root, ".git"),
    access = "read",
  }
  local inherited = { "HOME", "PATH", "LANG", "LC_ALL", "TERM", "USER" }
  if paths.name == "windows" then
    inherited = {
      "PATH",
      "SystemRoot",
      "WINDIR",
      "COMSPEC",
      "PATHEXT",
    }
  end
  return {
    id = "neo-workspace",
    filesystem = {
      default = "read",
      entries = entries,
    },
    network = "restricted",
    environment = {
      clear = true,
      inherit = inherited,
      set = { TMPDIR = temporary, TMP = temporary, TEMP = temporary },
    },
  }
end

local function profile_source(setting, paths, temporary_root)
  if setting == nil then
    return function(ctx)
      return M.default_profile(ctx, paths, temporary_root)
    end
  end
  if type(setting) == "table" then
    local override = util.copy(setting)
    return function(ctx)
      return util.deep_merge(
        M.default_profile(ctx, paths, temporary_root), override)
    end
  end
  assert(type(setting) == "function",
    "sandbox.profile must be a table or function")
  return function(ctx)
    local default = M.default_profile(ctx, paths, temporary_root)
    return setting(util.copy(default), ctx)
  end
end

local function validate_settings(settings)
  assert(type(settings) == "table" and not util.is_list(settings),
    "sandbox must be a table")
  for key in pairs(settings) do
    assert(key == "enabled" or key == "profile",
      "unsupported sandbox setting: " .. tostring(key))
  end
  assert(type(settings.enabled) == "boolean",
    "sandbox.enabled must be boolean")
  if settings.profile ~= nil then
    assert(type(settings.profile) == "table"
      or type(settings.profile) == "function",
      "sandbox.profile must be a table or function")
  end
end

function M.warning(name, status)
  local reason = status and status.message
    or "sandbox requirements are unavailable"
  if status and status.stage then
    reason = status.stage .. ": " .. reason
  end
  return string.format(
    "neoagent: sandbox unavailable for %s; tools will run without a sandbox: %s",
    bounded(name or "Neo"), bounded(reason))
end

local function base_executor(tool, arguments, ctx)
  return tool.execute(arguments, ctx)
end

function M.controller(configured, opts)
  assert(type(configured) == "table",
    "sandbox Controller configuration is required")
  opts = opts or {}
  local copied = util.copy(configured)
  local settings = copied.sandbox or { enabled = false }
  validate_settings(settings)
  if not settings.enabled then
    copied._sandbox_status = {
      enabled = false,
      active = false,
    }
    return copied
  end

  local dispatch = require("neoagent.sandbox.platform")
  local selected, status = opts.platform, opts.status
  if selected == nil and status == nil then
    selected, status = dispatch.select(opts.os, opts.platforms)
  end
  local fs = opts.fs or require("neoagent.fs")
  local process = opts.process or require("neoagent.process").run
  local services = {
    fs = fs,
    process = process,
    nvim = opts.nvim,
    system = opts.system,
    sandbox_exec = opts.sandbox_exec,
    probe_timeout_ms = opts.probe_timeout_ms,
  }
  if selected and status == nil then
    local checked, value = pcall(selected.check, services)
    status = checked and value or {
      ok = false,
      platform = selected.name,
      stage = "requirements",
      message = util.normalize_error(value, "sandbox_unavailable").message,
    }
  end
  if not selected or type(status) ~= "table" or not status.ok then
    copied._sandbox_status = util.copy(status or {
      ok = false,
      stage = "platform",
      message = "sandbox platform is unavailable",
    })
    copied._sandbox_status.enabled = true
    copied._sandbox_status.active = false
    copied.view = require("neoagent.sandbox.view").warn_once(
      copied.view, M.warning(copied.name or "Neo", status),
      copied.name or "Neo")
    return copied
  end
  copied._sandbox_status = util.copy(status)
  copied._sandbox_status.enabled = true
  copied._sandbox_status.active = true

  local dialogs = require("neoagent.dialog").new()
  local paths = opts.paths or selected.paths or path_module.posix
  local temporary_root = type(selected.temporary_root) == "function"
      and selected.temporary_root(services) or nil
  local enforcement = require("neoagent.sandbox.enforce").new({
    platform = selected,
    profile = profile_source(settings.profile, paths, temporary_root),
    paths = paths,
    temporary_root = temporary_root,
    fs = fs,
    process = process,
    environ = opts.environ,
    nvim = opts.nvim,
    capabilities = status.capabilities,
  })
  local escalation = require("neoagent.sandbox.escalation").new({
    fs = fs,
    process = process,
  })
  local selected_tools = copied._tools_supplied and copied.tools
    or require("neoagent.tools").coding()
  local base = copied.execute_tool or base_executor
  copied.tools = escalation:tools(selected_tools)
  copied._tools_supplied = true
  copied.execute_tool = require("neoagent.dialog").wrap(
    dialogs, escalation:wrap({
      restricted = enforcement:wrap(base),
      elevated = base,
    }))
  return copied, dialogs
end

return M
