local provider_auth = require("neoagent.provider_auth")
local util = require("neoagent.util")

local M = {}
local ProviderCredentials = {}
ProviderCredentials.__index = ProviderCredentials

local function auth_error(message, detail)
  return util.error("auth", message, detail)
end

function ProviderCredentials.new(opts)
  opts = opts or {}
  assert(type(opts.provider_id) == "string" and opts.provider_id ~= "",
    "ProviderCredentials provider_id is required")
  assert(type(opts.provider) == "table"
      and (next(opts.provider) == nil or not util.is_list(opts.provider)),
    "ProviderCredentials provider must be an object")
  assert(opts.authentication == nil or type(opts.authentication) == "table",
    "ProviderCredentials authentication must be a table")
  assert(opts.method == nil or type(opts.method) == "table",
    "ProviderCredentials method must be a table")
  assert(opts.scope == nil or type(opts.scope) == "string"
      and opts.scope ~= "",
    "ProviderCredentials scope must be a non-empty string")
  return setmetatable({
    provider_id = opts.provider_id,
    provider = opts.provider,
    authentication = opts.authentication,
    method = opts.method,
    scope = opts.scope,
  }, ProviderCredentials)
end

function ProviderCredentials:_method_id()
  return provider_auth.for_scope(self.provider, self.scope)
end

function ProviderCredentials:_stored()
  local method_id = self:_method_id()
  if method_id == nil then return false end
  local authentication = self.authentication
  if type(authentication) ~= "table"
      or type(authentication.has_credentials) ~= "function" then
    return nil, auth_error(
      "Authentication is unavailable for " .. self.provider_id)
  end
  local ok, stored, err = pcall(
    authentication.has_credentials, authentication, method_id)
  if not ok then
    return nil, auth_error(
      "Failed to inspect stored credentials for " .. self.provider_id)
  end
  if stored == nil then
    return nil, util.normalize_error(err,
      "auth")
  end
  return stored == true
end

function ProviderCredentials:_ambient()
  if self.scope ~= nil and self.scope ~= "inference" then return nil end
  local source = self.provider.api_key
  if source == nil then return nil end
  local ok, value = pcall(function()
    return type(source) == "function" and source() or source
  end)
  if not ok then
    return nil, nil, auth_error(
      "Failed to resolve the provider environment credential")
  end
  if type(value) ~= "string" or util.trim(value) == "" then return nil end
  return util.trim(value), type(source) == "string"
      and "configured" or "environment"
end

function ProviderCredentials:state()
  local method_id = self:_method_id()
  local method_name = self.method and self.method.name or method_id
  local stored, stored_err = self:_stored()
  if stored == nil then
    return {
      usable = false,
      source = "error",
      method_id = method_id,
      method_name = method_name,
      error = util.copy(stored_err),
    }
  end
  if stored then
    return {
      usable = true,
      source = "stored",
      method_id = method_id,
      method_name = method_name,
    }
  end
  local _, source, ambient_err = self:_ambient()
  if ambient_err then
    return {
      usable = false,
      source = "error",
      method_id = method_id,
      method_name = method_name,
      error = util.copy(ambient_err),
    }
  end
  if source then
    return {
      usable = true,
      source = source,
      method_id = method_id,
      method_name = method_name,
    }
  end
  if method_id == nil and self.provider.api_key == nil then
    return { usable = true, source = "none" }
  end
  if method_id ~= nil and self.provider.auth_optional == true
      and (self.scope == nil or self.scope == "inference") then
    return {
      usable = true,
      source = "optional",
      method_id = method_id,
      method_name = method_name,
    }
  end
  return {
    usable = false,
    source = "logged_out",
    method_id = method_id,
    method_name = method_name,
  }
end

function ProviderCredentials:ambient_api_key()
  local stored, stored_err = self:_stored()
  if stored == nil then error(stored_err, 0) end
  if stored then return nil end
  local key, _, ambient_err = self:_ambient()
  if ambient_err then error(ambient_err, 0) end
  return key
end

function ProviderCredentials:cache_identity()
  local method_id = self:_method_id()
  if type(method_id) ~= "string" then
    return nil, auth_error(
      "Model catalog account identity is unavailable")
  end
  local authentication = self.authentication
  if type(authentication) ~= "table" then
    return nil, auth_error(
      "Model catalog account identity is unavailable")
  end
  local stored, stored_err = self:_stored()
  if stored == nil then return nil, stored_err end
  if stored then
    if type(authentication.cache_identity) ~= "function" then
      return nil, auth_error(
        "Model catalog account identity is unavailable")
    end
    local ok, identity, err = pcall(
      authentication.cache_identity, authentication, method_id)
    if not ok then
      return nil, auth_error("Model catalog account identity failed")
    end
    if identity == nil then
      return nil, err or auth_error(
        "Model catalog account identity is unavailable")
    end
    return identity
  end
  local key, _, ambient_err = self:_ambient()
  if ambient_err then return nil, ambient_err end
  if not key and self.provider.auth_optional == true then
    return vim.fn.sha256("neoagent:optional-auth:" .. method_id)
  end
  if not key or type(authentication.derive_cache_identity) ~= "function" then
    return nil, auth_error(
      "Model catalog account identity is unavailable")
  end
  local ok, identity, err = pcall(
    authentication.derive_cache_identity, authentication, method_id, {
      type = "api_key",
      key = key,
    })
  if not ok then
    return nil, auth_error("Model catalog account identity failed")
  end
  if identity == nil then
    return nil, err or auth_error(
      "Model catalog account identity is unavailable")
  end
  return identity
end

function ProviderCredentials:uses_method(method_id)
  return provider_auth.uses(self.provider, method_id)
end

M.new = ProviderCredentials.new
M.ProviderCredentials = ProviderCredentials

return M
