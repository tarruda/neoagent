local policy = require("neoagent.sandbox.policy")
local path_module = require("neoagent.sandbox.path")
local profile_module = require("neoagent.sandbox.profile")
local result = require("neoagent.sandbox.result")
local util = require("neoagent.util")

local M = {}
local Enforcement = {}
Enforcement.__index = Enforcement

local function copy_context(ctx)
  local copied = {}
  for key, value in pairs(ctx or {}) do copied[key] = value end
  return copied
end

local function workspace(ctx)
  local context = ctx and ctx.context
  return context and context.workspace or context
end

local function effective_environment(profile, source, paths)
  source = source or vim.fn.environ()
  local environment = profile.environment
  local values = environment.clear and {} or util.copy(source)
  local by_key = {}
  local source_names = vim.tbl_keys(source)
  table.sort(source_names)
  for _, name in ipairs(source_names) do
    local key = paths.environment_key(name)
    if not by_key[key] then by_key[key] = name end
  end
  local function assign(name, value)
    local key = paths.environment_key(name)
    local existing = by_key[key]
    if existing and existing ~= name then values[existing] = nil end
    values[name] = value
    by_key[key] = name
  end
  if environment.clear then
    for _, name in ipairs(environment.inherit) do
      local source_name = by_key[paths.environment_key(name)]
      if source_name then assign(name, source[source_name]) end
    end
  end
  for name, item in pairs(environment.set) do assign(name, item) end
  return values
end

local function denied(operation, path, profile, platform, granted)
  local action = operation == "filesystem.read" and "Read"
    or operation == "filesystem.write" and "Write"
    or "Execution"
  return {
    kind = "sandbox_denied",
    message = action .. " access is denied" .. (path and ": " .. path or ""),
    sandbox = {
      denied = true,
      can_escalate = true,
      operation = operation,
      path = path,
      profile = profile.id,
      backend = platform.name,
      granted = granted,
    },
  }
end

local function validate_argv(argv)
  if type(argv) ~= "table" or not util.is_list(argv) or #argv == 0 then
    error(util.error("sandbox", "Sandbox argv must be a non-empty list"), 0)
  end
  local copied = {}
  for index, value in ipairs(argv) do
    if type(value) ~= "string" or index == 1 and value == ""
        or value:find("\0", 1, true) then
      error(util.error("sandbox", "Sandbox argv[" .. index
        .. "] must be NUL-free and argv[1] must be non-empty"), 0)
    end
    copied[index] = value
  end
  return copied
end

function Enforcement:_resolve_profile(ctx)
  local profile, fingerprint
  if self._fingerprint then
    profile, fingerprint = self._configured_profile, self._fingerprint
  else
    profile, fingerprint = profile_module.resolve(
      self._profile_source, ctx, { paths = self._paths })
  end
  if type(self._platform.compile) == "function" then
    profile = self._platform.compile(profile, ctx, self._services)
  end
  return profile, fingerprint
end

function Enforcement:_guarded_fs(ctx, profile, require_active)
  local temporary = {}
  local raw, platform = self._fs, self._platform
  local remembered = self._temporary_paths
  local function forget(record)
    remembered[record.lexical] = nil
    remembered[record.canonical] = nil
  end
  local function remembered_file(lexical, canonical)
    local record = remembered[lexical] or remembered[canonical]
    if not record then return end
    local stat = vim.uv.fs_stat(record.canonical)
    if canonical ~= record.canonical or not stat or stat.type ~= "file"
        or stat.dev ~= record.dev or stat.ino ~= record.ino then
      forget(record)
      return
    end
    return record
  end
  local function dispatch(operation, path, arguments)
    require_active()
    if temporary[path] then
      if operation == "read" then return raw.read(path) end
      if operation == "write_all" then
        return raw.write_all(path, arguments.data, arguments.flags, arguments.mode)
      end
    end
    local lexical, canonical = policy.resolve_path(ctx, path, self._paths)
    local required = operation == "read" and "read" or "write"
    local allowed, granted = policy.allows(
      profile, lexical, canonical, required, self._paths)
    if not allowed then
      error(denied("filesystem." .. required, lexical,
        profile, platform, granted), 0)
    end
    local effective_profile = profile
    local record = operation == "read"
      and remembered_file(lexical, canonical) or nil
    if record then
      effective_profile = util.copy(profile)
      effective_profile.filesystem.entries[
        #effective_profile.filesystem.entries + 1
      ] = {
        path = record.canonical,
        access = "read",
      }
      lexical, canonical = record.canonical, record.canonical
    end
    return platform.fs({
      operation = operation,
      path = lexical,
      canonical_path = canonical,
      profile = effective_profile,
      data = arguments and arguments.data,
      flags = arguments and arguments.flags,
      mode = arguments and arguments.mode,
    }, self._services)
  end
  return {
    create_temp = function(prefix)
      require_active()
      if prefix ~= nil and (type(prefix) ~= "string"
          or prefix:find("[/%z]") or prefix:find("\\", 1, true)) then
        error(util.error("sandbox",
          "Sandbox temporary prefix must be a basename without NUL bytes"), 0)
      end
      if prefix ~= nil then
        local valid = pcall(self._paths.validate_component, prefix)
        if not valid then
          error(util.error("sandbox",
            "Sandbox temporary prefix is invalid for this platform"), 0)
        end
      end
      local path, err = raw.create_temp(prefix, self._temporary_root)
      if path then
        temporary[path] = true
        local lexical = self._paths.normalize(path)
        local canonical = self._paths.realpath(lexical)
        local stat = canonical and self._paths.stat(canonical)
        if stat and stat.type == "file" then
          local record = {
            lexical = lexical,
            canonical = canonical,
            dev = stat.dev,
            ino = stat.ino,
          }
          remembered[lexical] = record
          remembered[canonical] = record
        end
      end
      return path, err
    end,
    read = function(path)
      return dispatch("read", path)
    end,
    mkdirp = function(path)
      return dispatch("mkdirp", path)
    end,
    write_all = function(path, data, flags, mode)
      return dispatch("write_all", path, {
        data = data,
        flags = flags,
        mode = mode,
      })
    end,
  }
end

function Enforcement:_guarded_process(
    ctx, profile, observed, require_active)
  return function(argv, opts)
    require_active()
    opts = opts or {}
    if type(opts) ~= "table" or util.is_list(opts) then
      error(util.error("sandbox", "Sandbox process options must be an object"), 0)
    end
    local active_workspace = workspace(ctx)
    local cwd = opts.cwd or active_workspace and active_workspace.cwd
    if type(cwd) ~= "string" or cwd == "" then
      error(util.error("sandbox", "Sandbox process cwd is required"), 0)
    end
    local lexical, canonical =
      policy.resolve_path(ctx, cwd, self._paths)
    local allowed, granted = policy.allows(
      profile, lexical, canonical, "read", self._paths)
    if not allowed then
      error(denied("filesystem.read", lexical,
        profile, self._platform, granted), 0)
    end
    local request = {
      argv = validate_argv(argv),
      cwd = canonical,
      env = effective_environment(profile, self._environ(), self._paths),
      clear_env = true,
      stdin = opts.stdin,
      capture = opts.capture,
      timeout_ms = opts.timeout_ms,
      kill_grace_ms = opts.kill_grace_ms,
      on_output = opts.on_output,
      profile = profile,
    }
    local value = self._platform.exec(request, self._services)
    if type(value) ~= "table" or type(value.code) ~= "number" then
      error(util.error("sandbox_unavailable",
        "Sandbox platform returned an invalid process result"), 0)
    end
    if value.code ~= 0 then observed.process_failed = true end
    return value
  end
end

function Enforcement:wrap(next_execute_tool)
  next_execute_tool = next_execute_tool or function(tool, arguments, ctx)
    return tool.execute(arguments, ctx)
  end
  assert(type(next_execute_tool) == "function",
    "sandbox next executor must be a function")
  return function(tool, arguments, ctx)
    local ok, profile =
      pcall(self._resolve_profile, self, ctx)
    if not ok then
      local err = util.normalize_error(profile, "sandbox")
      return result.sandbox(err.message, {
        unavailable = true,
        kind = err.kind,
        backend = self._platform.name,
      })
    end
    local observed = { process_failed = false }
    local active = true
    local function require_active()
      if not active then
        error(util.error("sandbox",
          "Restricted sandbox capability has expired"), 0)
      end
    end
    local guarded = copy_context(ctx)
    guarded.fs = self:_guarded_fs(ctx, profile, require_active)
    guarded.process = self:_guarded_process(
      ctx, profile, observed, require_active)
    local executed, value = pcall(next_execute_tool,
      tool, arguments, guarded)
    active = false
    if not executed then
      local err = util.normalize_error(value, "tool")
      if err.kind == "sandbox_denied" and err.sandbox then
        return result.sandbox(result.denied(err.message), err.sandbox)
      elseif err.kind == "sandbox_unavailable" or err.kind == "sandbox" then
        return result.sandbox(err.message, {
          unavailable = true,
          kind = err.kind,
          backend = self._platform.name,
        })
      elseif observed.process_failed then
        return result.append(result.error(err.message),
          result.RESTRICTED_FAILURE, {
            ran_restricted = true,
            backend = self._platform.name,
            profile = profile.id,
          })
      end
      error(value, 0)
    end
    if observed.process_failed and type(value) == "table"
        and (value.isError == true or value.is_error == true) then
      return result.append(value, result.RESTRICTED_FAILURE, {
        ran_restricted = true,
        backend = self._platform.name,
        profile = profile.id,
      })
    end
    return value
  end
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "sandbox enforcement options must be a table")
  assert(type(opts.profile) == "table" or type(opts.profile) == "function",
    "sandbox profile is required")
  assert(type(opts.platform) == "table"
    and type(opts.platform.exec) == "function"
    and type(opts.platform.fs) == "function",
    "sandbox platform must implement exec and fs")
  local raw_fs = opts.fs or require("neoagent.fs")
  local raw_process = opts.process or require("neoagent.process").run
  local paths = opts.paths or opts.platform.paths or path_module.posix
  local configured_profile, fingerprint = opts.profile, nil
  if type(configured_profile) == "table" then
    configured_profile, fingerprint = profile_module.validate(
      configured_profile, { paths = paths })
  end
  return setmetatable({
    _profile_source = opts.profile,
    _configured_profile = configured_profile,
    _fingerprint = fingerprint,
    _platform = opts.platform,
    _paths = paths,
    _temporary_root = opts.temporary_root,
    _fs = raw_fs,
    _temporary_paths = {},
    _environ = opts.environ or vim.fn.environ,
    _services = {
      fs = raw_fs,
      process = raw_process,
      nvim = opts.nvim,
      capabilities = util.copy(opts.capabilities or {}),
    },
  }, Enforcement)
end

return M
