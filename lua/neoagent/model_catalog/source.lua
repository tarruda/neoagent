local util = require("neoagent.util")

local M = {}

local MAX_SOURCE_OPTIONS_BYTES = 16 * 1024

local function normalize_base_url(value)
  if type(value) ~= "string" then return "" end
  value = util.trim(value)
  local scheme, authority, tail = value:match(
    "^([%a][%w+.-]*)://([^/]*)(.*)$")
  if not scheme then return value:gsub("/+$", "") end
  scheme = scheme:lower()
  authority = authority:lower()
  if scheme == "https" then authority = authority:gsub(":443$", "") end
  if scheme == "http" then authority = authority:gsub(":80$", "") end
  tail = tail:gsub("/+$", "")
  return scheme .. "://" .. authority .. tail
end

local function fingerprint_part(value)
  value = tostring(value or "")
  return tostring(#value) .. ":" .. value
end

local function safe_text(value)
  return type(value) == "string" and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

local function copy_json(value, stack)
  local kind = type(value)
  if kind == "nil" or kind == "boolean" then return value end
  if kind == "string" then
    if not safe_text(value) then error("source option text is unsafe", 0) end
    return value
  end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("source option numbers must be finite", 0)
    end
    return value
  end
  if kind ~= "table" then
    error("source options must contain JSON values", 0)
  end
  if getmetatable(value) ~= nil then
    error("source option tables must not have metatables", 0)
  end
  if stack[value] then error("source options must not contain cycles", 0) end
  stack[value] = true
  local result = {}
  if util.is_list(value) then
    for index = 1, #value do result[index] = copy_json(value[index], stack) end
  else
    for key, child in pairs(value) do
      if not safe_text(key) then
        error("source option object keys must be safe strings", 0)
      end
      result[key] = copy_json(child, stack)
    end
  end
  stack[value] = nil
  return result
end

function M.provider_projection(provider)
  local result = {}
  for _, key in ipairs({
    "api", "base_url", "auth", "auth_optional", "service_opts",
  }) do
    if provider[key] ~= nil then result[key] = util.copy(provider[key]) end
  end
  return result
end

local function source_options(provider, definition)
  if type(definition.source_options) ~= "function" then return "" end
  local ok, value = pcall(
    definition.source_options, M.provider_projection(provider))
  if not ok then
    return nil, util.error("provider",
      "Model catalog source_options failed")
  end
  local copied_ok, copied = pcall(copy_json, value, {})
  if not copied_ok then
    return nil, util.error("provider",
      "Model catalog source_options returned an invalid value", copied)
  end
  local encoded_ok, encoded = pcall(util.json_encode, copied)
  if not encoded_ok or #encoded > MAX_SOURCE_OPTIONS_BYTES then
    return nil, util.error("provider",
      "Model catalog source_options exceeds its safe bound")
  end
  return encoded
end

local function account_identity(opts, provider, definition)
  if definition.account_scoped ~= true then return "" end
  local owner = opts.credentials or opts.authentication
  if type(owner) ~= "table" or type(owner.cache_identity) ~= "function" then
    return nil, util.error("auth",
      "Model catalog account identity is unavailable")
  end
  local ok, identity, err
  if opts.credentials then
    ok, identity, err = pcall(owner.cache_identity, owner)
  else
    ok, identity, err = pcall(
      owner.cache_identity, owner, provider.auth)
  end
  if not ok then
    return nil, util.error("auth", "Model catalog account identity failed")
  end
  if identity == nil then
    return nil, err or util.error("auth",
      "Model catalog account identity is unavailable")
  end
  if not safe_text(identity) or identity == "" or #identity > 1024 then
    return nil, util.error("auth",
      "Model catalog account identity is invalid")
  end
  return identity
end

function M.fingerprint(opts)
  opts = opts or {}
  local provider = opts.provider or {}
  local definition = opts.definition or {}
  local source_id = definition.source_id
  local source_revision = definition.source_revision
  if type(source_id) ~= "string" or source_id == ""
      or source_revision == nil then
    return nil, util.error("provider",
      "Model catalog persistence requires source_id and source_revision")
  end
  local identity, identity_err = account_identity(opts, provider, definition)
  if identity == nil then return nil, identity_err end
  local options, options_err = source_options(provider, definition)
  if options == nil then return nil, options_err end
  local values = {
    tostring(opts.provider_id or ""),
    tostring(provider.api or ""),
    normalize_base_url(provider.base_url),
    tostring(provider.auth or ""),
    provider.auth_optional == true and "true" or "false",
    tostring(source_id),
    tostring(source_revision),
    options,
    identity,
  }
  local encoded = {}
  for _, value in ipairs(values) do
    encoded[#encoded + 1] = fingerprint_part(value)
  end
  return vim.fn.sha256(table.concat(encoded, "|"))
end

M.MAX_SOURCE_OPTIONS_BYTES = MAX_SOURCE_OPTIONS_BYTES
M.no_options = function() return {} end

return M
