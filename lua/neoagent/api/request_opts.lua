local util = require("neoagent.util")

local M = {}

---@class Neoagent.ApiModelOptions
---@field provider string
---@field model string
---@field base_url string
---@field api_key? string|fun(): string?
---@field input? ('text'|'image')[]
---@field context_window? number
---@field thinking? Neoagent.ThinkingOptions
---@field max_output_tokens? number
---@field timeout_ms? integer
---@field request_opts? Neoagent.RequestLayer
---@field request_opts_layers? Neoagent.RequestLayer[]
---@field request_context? Neoagent.RequestIdentity
---@field transport? Neoagent.ByteBackend

---@class Neoagent.ApiRequest
---@field url string
---@field headers? table<string, unknown>
---@field body? Neoagent.JsonObject
---@field timeout_ms? number|false

---@class Neoagent.RequestOverride
---@field url? string
---@field headers? table<string, unknown>
---@field body? Neoagent.JsonObject

---@class Neoagent.RequestOptionsInput
---@field model Neoagent.Model
---@field messages Neoagent.Message[]
---@field system_prompt? string
---@field tools Neoagent.ToolDefinition[]
---@field request_context? Neoagent.RequestIdentity

---@class Neoagent.RequestOptionsContext: Neoagent.RequestOptionsInput
---@field request Neoagent.ApiRequest

---@alias Neoagent.RequestLayer Neoagent.RequestOverride|fun(context: Neoagent.RequestOptionsContext): Neoagent.RequestOverride

---@overload fun(default?: integer): integer?
---@param default? integer
---@param override? number|false
---@return integer|false|nil
function M.timeout(default, override)
  if override == false then return false end
  ---@type number?
  local value = default
  if override ~= nil then value = override end
  assert(value == nil or type(value) == "number" and value > 0
      and value < math.huge and value % 1 == 0,
    "timeout_ms must be a positive integer")
  ---@cast value integer?
  return value
end

---@param request Neoagent.ApiRequest
---@param override Neoagent.RequestOverride
---@return Neoagent.ApiRequest
local function merge(request, override)
  for key in pairs(override) do
    if key ~= "url" and key ~= "headers" and key ~= "body" then
      error(util.error("model", "Unsupported request_opts field: " .. tostring(key)), 0)
    end
  end
  local result = util.copy(request)
  if override.url ~= nil then
    if type(override.url) ~= "string" or override.url == "" then
      error(util.error("model", "request_opts.url must be a non-empty string"), 0)
    end
    result.url = override.url
  end
  if override.headers ~= nil then
    if type(override.headers) ~= "table" or (next(override.headers) ~= nil and util.is_list(override.headers)) then
      error(util.error("model", "request_opts.headers must be a table"), 0)
    end
    result.headers = util.deep_merge(result.headers, override.headers, function(key)
      return type(key) == "string" and key:lower() or key
    end)
  end
  if override.body ~= nil then
    if type(override.body) ~= "table" or (next(override.body) ~= nil and util.is_list(override.body)) then
      error(util.error("model", "request_opts.body must be a table"), 0)
    end
    result.body = util.deep_merge(result.body, override.body)
  end
  return result
end

---@param request Neoagent.ApiRequest
---@param layer? Neoagent.RequestLayer
---@param context Neoagent.RequestOptionsInput
---@return Neoagent.ApiRequest
function M.apply(request, layer, context)
  if layer == nil then return request end
  local override = layer
  if type(layer) == "function" then
    local snapshot = util.copy(context)
    override = layer({
      model = snapshot.model,
      messages = snapshot.messages,
      system_prompt = snapshot.system_prompt,
      tools = snapshot.tools,
      request_context = snapshot.request_context,
      request = util.copy(request),
    })
  end
  if type(override) ~= "table" then
    error(util.error("model", "request_opts must be a table or return a table"), 0)
  end
  return merge(request, override)
end

return M
