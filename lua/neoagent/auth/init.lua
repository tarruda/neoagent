local async = require("neoagent.async")
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
  return valid_credential(credential)
    and (method.type == nil or method.type == credential_type(credential))
end

local function method_for(self, id)
  local method = self.methods[id]
  if not method then error(util.error("auth", "Unknown login method: " .. tostring(id)), 0) end
  return method
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
    local credential = credential_from(method.login(interaction):await(), "Login", method)
    modify_store(self, id, function() return credential end)
    return { ok = true, method = id, credential_type = credential_type(credential) }
  end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "auth" })
end

function Manager:resolve(id, opts)
  opts = opts or {}
  return async.run(function()
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
    end
    local override = method.request_opts(util.copy(credential))
    if type(override) ~= "table" then
      error(util.error("auth", "Login method request_opts must return a table"), 0)
    end
    return {
      ok = true,
      method = id,
      configured = true,
      credential_type = credential_type(credential),
      request_opts = override,
    }
  end, { on_done = opts.on_done, error_kind = "auth" })
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
    return { ok = true, method = id }
  end, { on_done = opts.on_done, error_kind = "auth" })
end

function Manager:wrap(model, id, opts)
  assert(type(model) == "table" and type(model.stream) == "function", "model is required")
  method_for(self, id)
  opts = opts or {}
  local wrapped = {
    api = model.api,
    provider = model.provider,
    id = model.id,
    context_window = model.context_window,
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
  return wrapped
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
  }, Manager)
end

function M.configured(configured)
  local options = configured and configured.auth or require("neoagent.config").get().auth
  return M.new({
    methods = options.methods,
    store = require("neoagent.auth.store").new(options.path),
  })
end

return M
