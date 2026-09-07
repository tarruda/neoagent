local async = require("neoagent.async")
local model_contract = require("neoagent.model")
local request_opts = require("neoagent.api.request_opts")
local util = require("neoagent.util")

local M = {}
local Manager = {}
Manager.__index = Manager

local function valid_env(env)
  if env == nil then return true end
  if type(env) ~= "table" or util.is_list(env) then return false end
  for name, value in pairs(env) do
    if type(name) ~= "string" or name == "" or type(value) ~= "string" or value == "" then
      return false
    end
  end
  return true
end

local function public_metadata(value)
  if value == nil then return nil end
  if type(value) ~= "table" or util.is_list(value) then
    return nil, util.error("auth", "Login method public_metadata must return a keyed table")
  end
  local result = {}
  for name, entry in pairs(value) do
    if type(name) ~= "string" or name == "" then
      return nil, util.error("auth", "public_metadata names must be non-empty strings")
    end
    local lower = name:lower()
    if lower:find("key", 1, true) or lower:find("token", 1, true)
        or lower:find("secret", 1, true)
        or lower:find("authorization", 1, true) then
      return nil, util.error("auth", "public_metadata name is reserved: " .. name)
    end
    if type(entry) ~= "string" or entry == "" or #entry > 512 then
      return nil, util.error("auth", "public_metadata values must be non-empty strings of at most 512 bytes")
    end
    if entry:find("[%z\1-\31\127]") then
      return nil, util.error("auth", "public_metadata values contain control characters")
    end
    if not util.is_valid_utf8(entry) then
      return nil, util.error("auth", "public_metadata values must contain valid UTF-8")
    end
    result[name] = entry
  end
  return result
end

local function safe_cache_identity(value)
  if value == nil then return nil end
  if type(value) ~= "string" or value == "" or #value > 1024
      or not util.is_valid_utf8(value)
      or value:find("[%z\1-\31\127]") then
    return nil, util.error("auth",
      "Login method cache_identity must return safe non-empty text")
  end
  return value
end

local function hash_identity(method_id, value)
  return vim.fn.sha256(#method_id .. ":" .. method_id
    .. ":" .. #value .. ":" .. value)
end

local function credential_type(credential)
  if type(credential) ~= "table" then return nil end
  if credential.type == "api_key" then return "api_key" end
  if credential.type == "oauth" then return "oauth" end
  if credential.type == nil and type(credential.access) == "string"
      and type(credential.refresh) == "string" and type(credential.expires) == "number" then
    return "oauth"
  end
  return nil
end

local function valid_credential(credential)
  local kind = credential_type(credential)
  if kind == "api_key" then
    return type(credential.key) == "string" and util.trim(credential.key) ~= ""
      and valid_env(credential.env)
  end
  if kind == "oauth" then
    return type(credential.access) == "string" and credential.access ~= ""
      and type(credential.refresh) == "string" and credential.refresh ~= ""
      and type(credential.expires) == "number"
  end
  return false
end

local function valid_for(method, credential)
  if not valid_credential(credential)
      or method.type ~= nil and method.type ~= credential_type(credential) then
    return false
  end
  if type(method.validate_credential) ~= "function" then return true end
  local ok, valid = pcall(method.validate_credential, util.copy(credential))
  return ok and valid == true
end

local function method_for(self, id)
  local method = self.methods[id]
  if not method then error(util.error("auth", "Unknown login method: " .. tostring(id)), 0) end
  return method
end

local function credential_identity(self, id, method, credential)
  if credential == nil or type(method.cache_identity) ~= "function" then
    return nil
  end
  local ok, value = pcall(method.cache_identity, util.copy(credential))
  if not ok then
    return nil, util.error("auth",
      "Login method cache_identity failed")
  end
  local selected, err = safe_cache_identity(value)
  if not selected then return nil, err end
  return hash_identity(id, selected)
end

local function publish(self, id, kind)
  self.revisions[id] = (self.revisions[id] or 0) + 1
  local event = {
    method = id,
    kind = kind,
    revision = self.revisions[id],
  }
  for _, subscription in pairs(self.listeners[id] or {}) do
    pcall(subscription, util.copy(event))
  end
  return event.revision
end

local function credential_from(result, action, method)
  if type(result) ~= "table" then
    error(util.error("auth", action .. " returned an invalid result"), 0)
  end
  if not result.ok then error(result.error or util.error("auth", action .. " failed"), 0) end
  local credential = result.credential
  if not valid_for(method, credential) then
    error(util.error("auth", action .. " returned an invalid credential"), 0)
  end
  return credential
end

local function modify_store(self, id, fn)
  if type(self.store.modify) == "function" then
    local result = self.store:modify(id, fn):await()
    if not result.ok then error(result.error, 0) end
    return result.credential
  end
  local current, read_err = self.store:read(id)
  if read_err then error(read_err, 0) end
  local value = fn(current)
  if value ~= nil then
    local stored, write_err = self.store:write(id, value)
    if not stored then error(write_err, 0) end
    return value
  end
  return current
end

function Manager:login(id, opts)
  opts = opts or {}
  return async.run(function(run)
    local method = method_for(self, id)
    local interaction = {
      prompt = assert(opts.prompt, "login prompt callback is required"),
      notify = function(event)
        run:emit(event)
        if opts.notify then opts.notify(event) end
      end,
    }
    local credential = credential_from(method.login(interaction):await(),
      "Login", method)
    credential = modify_store(self, id, function() return credential end)
    local revision = publish(self, id, "login")
    return {
      ok = true,
      method = id,
      credential_type = credential_type(credential),
      revision = revision,
    }
  end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "auth" })
end

function Manager:resolve(id, opts)
  opts = opts or {}
  return async.run(function()
    if opts.scope ~= nil and (type(opts.scope) ~= "string"
        or opts.scope == "" or #opts.scope > 128
        or not opts.scope:match("^[%w_.-]+$")) then
      error(util.error("auth", "Authentication scope is invalid"), 0)
    end
    local method = method_for(self, id)
    local credential, read_err = self.store:read(id)
    if read_err then error(read_err, 0) end
    if not credential then
      if opts.optional then return { ok = true, method = id, configured = false } end
      error(util.error("auth", "Not logged in with " .. id), 0)
    end
    if not valid_for(method, credential) then
      error(util.error("auth", "Stored credential is invalid"), 0)
    end
    if credential_type(credential) == "oauth" and self.now() >= credential.expires then
      if type(method.refresh) ~= "function" then
        error(util.error("auth", "Login method cannot refresh OAuth credentials"), 0)
      end
      local previous_identity = credential_identity(self, id, method, credential)
      credential = modify_store(self, id, function(current)
        if type(current) ~= "table" then return nil end
        if not valid_for(method, current) then
          error(util.error("auth", "Stored credential is invalid"), 0)
        end
        if credential_type(current) ~= "oauth" or self.now() < current.expires then return nil end
        return credential_from(method.refresh(util.copy(current)):await(), "Token refresh", method)
      end)
      if not credential then error(util.error("auth", "Credential was removed during refresh"), 0) end
      if not valid_for(method, credential) then
        error(util.error("auth", "Stored credential changed during refresh"), 0)
      end
      local next_identity = credential_identity(self, id, method, credential)
      if previous_identity ~= next_identity
          and (previous_identity ~= nil or next_identity ~= nil) then
        publish(self, id, "refresh")
      end
    end
    local override = method.request_opts(
      util.copy(credential), opts.scope)
    if type(override) ~= "table" then
      error(util.error("auth", "Login method request_opts must return a table"), 0)
    end
    local metadata
    if type(method.public_metadata) == "function" then
      local ok, value = pcall(method.public_metadata, util.copy(credential))
      if not ok then
        error(util.error("auth", "Login method public_metadata failed: " .. tostring(value)), 0)
      end
      local metadata_err
      metadata, metadata_err = public_metadata(value)
      if not metadata then error(metadata_err, 0) end
    end
    return {
      ok = true,
      method = id,
      configured = true,
      credential_type = credential_type(credential),
      request_opts = override,
      metadata = metadata,
    }
  end, { on_done = opts.on_done, error_kind = "auth" })
end

function Manager:cache_identity(id)
  local method = method_for(self, id)
  local credential, err = self.store:read(id)
  if err then return nil, err end
  if credential == nil then return nil end
  if not valid_for(method, credential) then
    return nil, util.error("auth", "Stored credential is invalid for " .. id)
  end
  return self:derive_cache_identity(id, credential)
end

function Manager:derive_cache_identity(id, credential)
  local method = method_for(self, id)
  if not valid_for(method, credential) then
    return nil, util.error("auth",
      "Credential is invalid for cache identity: " .. id)
  end
  return credential_identity(self, id, method, credential)
end

function Manager:revision(id)
  method_for(self, id)
  return self.revisions[id] or 0
end

function Manager:subscribe(id, listener)
  method_for(self, id)
  assert(type(listener) == "function",
    "authentication revision listener must be a function")
  self.next_listener_id = self.next_listener_id + 1
  local listener_id = self.next_listener_id
  self.listeners[id] = self.listeners[id] or {}
  self.listeners[id][listener_id] = listener
  local active = true
  return function()
    if not active then return false end
    active = false
    if self.listeners[id] then self.listeners[id][listener_id] = nil end
    return true
  end
end

function Manager:has_credentials(id)
  local method = method_for(self, id)
  local credential, err = self.store:read(id)
  if err then return nil, err end
  if credential == nil then return false end
  if not valid_for(method, credential) then
    return nil, util.error("auth", "Stored credential is invalid for " .. id)
  end
  return true
end

function Manager:list_credentials()
  local entries, err
  if type(self.store.list) == "function" then
    entries, err = self.store:list()
    if not entries then return nil, err end
  else
    entries = {}
    for id in pairs(self.methods) do
      local credential, read_err = self.store:read(id)
      if read_err then return nil, read_err end
      if credential ~= nil then
        entries[#entries + 1] = { id = id, type = credential_type(credential) or "invalid" }
      end
    end
  end
  local result = {}
  for _, entry in ipairs(entries) do
    local id = entry.id or entry.providerId
    if type(id) == "string" and id ~= "" then
      local method = self.methods[id]
      result[#result + 1] = {
        id = id,
        name = method and method.name or id,
        type = entry.type == "api_key" and "api_key"
          or entry.type == "oauth" and "oauth" or "invalid",
      }
    end
  end
  table.sort(result, function(a, b)
    if a.name == b.name then return a.id < b.id end
    return a.name < b.name
  end)
  return result
end

function Manager:logout(id, opts)
  opts = opts or {}
  assert(type(id) == "string" and id ~= "", "credential id is required")
  return async.run(function()
    if type(self.store.delete) == "function" then
      local operation, delete_err = self.store:delete(id)
      if type(operation) == "table" and type(operation.await) == "function" then
        local result = operation:await()
        if type(result) == "table" and result.ok == false then error(result.error, 0) end
      elseif operation == false or (operation == nil and delete_err ~= nil) then
        error(delete_err or util.error("auth", "Failed to remove credential"), 0)
      end
    else
      local removed, delete_err = self.store:write(id, nil)
      if not removed then error(delete_err, 0) end
    end
    return {
      ok = true,
      method = id,
      revision = publish(self, id, "logout"),
    }
  end, { on_done = opts.on_done, error_kind = "auth" })
end

function Manager:wrap(model, id, opts)
  model = model_contract.assert(model, "Authentication input Model")
  method_for(self, id)
  opts = opts or {}
  local wrapped = {
    api = model.api,
    provider = model.provider,
    id = model.id,
    input = util.copy(model.input),
    context_window = model.context_window,
    timeout_ms = model.timeout_ms,
    thinking = util.copy(model.thinking),
  }
  function wrapped:stream(call_opts)
    call_opts = call_opts or {}
    return async.run(function(run)
      local resolved = self._manager:resolve(self._method, { optional = self._optional }):await()
      if not resolved.ok then error(resolved.error, 0) end
      local call = util.copy(call_opts)
      if resolved.configured then
        local user_layer = call.request_opts
        call.request_opts = function(context)
          local request = request_opts.apply(context.request, user_layer, context)
          return request_opts.apply(request, resolved.request_opts, context)
        end
      end
      call.on_event = function(event) run:emit(event) end
      call.on_done = nil
      return self._model:stream(call):await()
    end, { on_event = call_opts.on_event, on_done = call_opts.on_done, error_kind = "auth" })
  end
  wrapped._manager, wrapped._method, wrapped._model = self, id, model
  wrapped._optional = opts.optional == true
  return model_contract.assert(wrapped, "Authentication Model wrapper")
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.methods) == "table", "auth methods are required")
  assert(type(opts.store) == "table" and type(opts.store.read) == "function"
    and type(opts.store.write) == "function", "credential store is required")
  return setmetatable({
    methods = util.copy(opts.methods),
    store = opts.store,
    now = opts.now or util.now_ms,
    revisions = {},
    listeners = {},
    next_listener_id = 0,
  }, Manager)
end

function M.configured(configured, runtime)
  local options = configured and configured.auth or require("neoagent.config").get().auth
  runtime = runtime or {}
  local methods = util.copy(options.methods)
  if runtime.transport then
    for id, method in pairs(methods) do
      if type(method._with_transport) == "function" then
        local transport = runtime.transport
        if type(transport.with_context) == "function" then
          transport = transport.with_context({
            auth_method = id,
            origin = "authentication",
          })
        end
        methods[id] = method._with_transport(transport)
      end
    end
  end
  return M.new({
    methods = methods,
    store = require("neoagent.auth.store").new(options.path),
  })
end

return M
