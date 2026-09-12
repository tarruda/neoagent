local M = {}

---@class Neoagent.ProviderAuthConfig
---@field auth? string
---@field auth_scopes? table<string, string>

---@class Neoagent.ProviderAuthEntry
---@field scope string
---@field method? string
---@field primary boolean

---@param provider? Neoagent.ProviderAuthConfig
---@param scope? string
---@return string?, boolean
function M.for_scope(provider, scope)
  provider = type(provider) == "table" and provider or {}
  if scope == nil or scope == "inference" then
    return provider.auth, false
  end
  local scopes = type(provider.auth_scopes) == "table" and provider.auth_scopes or {}
  if type(scope) == "string" and scopes[scope] ~= nil then
    return scopes[scope], true
  end
  return nil, false
end

---@param provider? Neoagent.ProviderAuthConfig
---@return Neoagent.ProviderAuthEntry[]
function M.entries(provider)
  provider = type(provider) == "table" and provider or {}
  local result = { {
    scope = "inference",
    method = provider.auth,
    primary = true,
  } }
  local scopes = type(provider.auth_scopes) == "table" and provider.auth_scopes or {}
  local names = vim.tbl_keys(scopes)
  table.sort(names)
  local seen = {}
  if type(provider.auth) == "string" then
    seen[provider.auth] = true
  end
  for _, scope in ipairs(names) do
    local method = scopes[scope]
    if not seen[method] then
      seen[method] = true
      result[#result + 1] = {
        scope = scope,
        method = method,
        primary = false,
      }
    end
  end
  return result
end

---@param provider? Neoagent.ProviderAuthConfig
---@param method unknown
---@return boolean
function M.uses(provider, method)
  if type(method) ~= "string" then
    return false
  end
  for _, entry in ipairs(M.entries(provider)) do
    if entry.method == method then
      return true
    end
  end
  return false
end

return M
