local async = require("neoagent.async")
local request_opts = require("neoagent.api.request_opts")
local util = require("neoagent.util")

local M = {}
local Manager = {}
Manager.__index = Manager

local function valid_credential(credential)
  return type(credential) == "table"
    and type(credential.access) == "string" and credential.access ~= ""
    and type(credential.refresh) == "string" and credential.refresh ~= ""
    and type(credential.expires) == "number"
end

local function method_for(self, id)
  local method = self.methods[id]
  if not method then error(util.error("auth", "Unknown login method: " .. tostring(id)), 0) end
  return method
end

local function credential_from(result, action)
  if not result.ok then error(result.error, 0) end
  local credential = result.credential
  if not valid_credential(credential) then
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
    local credential = credential_from(method.login(interaction):await(), "Login")
    modify_store(self, id, function() return credential end)
    return { ok = true, method = id }
  end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "auth" })
end

function Manager:resolve(id, opts)
  opts = opts or {}
  return async.run(function()
    local method = method_for(self, id)
    local credential, read_err = self.store:read(id)
    if read_err then error(read_err, 0) end
    if not credential then error(util.error("auth", "Not logged in with " .. id), 0) end
    if not valid_credential(credential) then error(util.error("auth", "Stored credential is invalid"), 0) end
    if self.now() >= credential.expires then
      credential = modify_store(self, id, function(current)
        if type(current) ~= "table" then return nil end
        if type(current.expires) == "number" and self.now() < current.expires then return nil end
        return credential_from(method.refresh(util.copy(current)):await(), "Token refresh")
      end)
      if not credential then error(util.error("auth", "Credential was removed during refresh"), 0) end
    end
    local override = method.request_opts(util.copy(credential))
    if type(override) ~= "table" then
      error(util.error("auth", "Login method request_opts must return a table"), 0)
    end
    return { ok = true, method = id, request_opts = override }
  end, { on_done = opts.on_done, error_kind = "auth" })
end

function Manager:has_credentials(id)
  method_for(self, id)
  local credential, err = self.store:read(id)
  if err then return nil, err end
  return valid_credential(credential)
end

function Manager:wrap(model, id)
  assert(type(model) == "table" and type(model.stream) == "function", "model is required")
  method_for(self, id)
  local wrapped = {
    api = model.api,
    provider = model.provider,
    id = model.id,
    thinking = util.copy(model.thinking),
  }
  function wrapped:stream(opts)
    opts = opts or {}
    return async.run(function(run)
      local resolved = self._manager:resolve(self._method):await()
      if not resolved.ok then error(resolved.error, 0) end
      local call = util.copy(opts)
      local user_layer = call.request_opts
      call.request_opts = function(context)
        local request = request_opts.apply(context.request, user_layer, context)
        return request_opts.apply(request, resolved.request_opts, context)
      end
      call.on_event = function(event) run:emit(event) end
      call.on_done = nil
      return self._model:stream(call):await()
    end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "auth" })
  end
  wrapped._manager, wrapped._method, wrapped._model = self, id, model
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
