local common = require("neoagent.tools.common")
local methods = require("neoagent.rpc.methods")
local util = require("neoagent.util")

local M = {}

M.methods = methods.names

M.events = {
  update = "tool_update",
  artifact_begin = "tool_artifact_begin",
  artifact_chunk = "tool_artifact_chunk",
  artifact_end = "tool_artifact_end",
}

---@param value unknown
---@return boolean
local function object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

---@param value table
---@param allowed table<string, boolean>
---@param label string
local function exact(value, allowed, label)
  for key in pairs(value) do
    assert(type(key) == "string" and allowed[key] ~= nil, label .. " has an unknown field")
  end
  for key, required in pairs(allowed) do
    assert(not required or rawget(value, key) ~= nil, label .. " is missing " .. key)
  end
end

---@param value unknown
---@param label string
---@return string
local function path(value, label)
  assert(
    type(value) == "string"
      and value ~= ""
      and #value <= require("neoagent.tools.limits").MAX_PATH_BYTES
      and not value:find("\0", 1, true)
      and util.is_valid_utf8(value),
    label .. " must be a bounded UTF-8 path"
  )
  return value
end

---@param value unknown
---@return string
function M.method(value)
  local descriptor = type(value) == "string" and methods.by_name[value] or nil
  assert(descriptor, "unknown Tool RPC method")
  return descriptor.name
end

---@param method string
---@param value unknown
---@return table
local function request(method, value)
  local descriptor = assert(methods.by_name[M.method(method)], "unknown Tool RPC method")
  return descriptor.validate_request(value)
end

---@class Neoagent.ToolRpcPolicyEvidence
---@field denial_output string

---@class Neoagent.ToolRpcContextOptions
---@field denial_keywords? string[]

---@param value unknown
---@return Neoagent.ToolRpcPolicyEvidence
local function policy(value)
  assert(object(value), "Tool RPC policy evidence must be an object")
  ---@cast value table
  exact(value, { denial_output = true }, "Tool RPC policy evidence")
  assert(
    type(value.denial_output) == "string"
      and value.denial_output ~= ""
      and #value.denial_output <= 8 * 1024
      and util.is_valid_utf8(value.denial_output),
    "Tool RPC denial evidence must be bounded UTF-8 text"
  )
  return { denial_output = value.denial_output }
end

---@param value unknown
---@return string[]
local function denial_keywords(value)
  if value == nil then
    return {}
  end
  assert(type(value) == "table" and util.is_list(value) and #value <= 32,
    "Tool RPC denial keywords must be a bounded list")
  local selected = {}
  local total = 0
  for index, keyword in ipairs(value) do
    assert(
      type(keyword) == "string"
        and keyword ~= ""
        and #keyword <= 128
        and util.is_valid_utf8(keyword),
      "Tool RPC denial keyword[" .. index .. "] must be bounded UTF-8 text"
    )
    total = total + #keyword
    assert(total <= 1024, "Tool RPC denial keywords exceed the aggregate limit")
    selected[index] = keyword
  end
  return selected
end

---@param call Neoagent.ToolOperationCall
---@param options? Neoagent.ToolRpcContextOptions
---@return Neoagent.JsonObject
function M.encode_context(call, options)
  local selected = common.validate_call(call)
  options = options or {}
  assert(object(options), "Tool RPC context options must be an object")
  exact(options, { denial_keywords = false }, "Tool RPC context options")
  local result = {
    workspace = {
      root = selected.workspace.root,
      cwd = selected.workspace.cwd,
    },
  }
  local keywords = denial_keywords(options.denial_keywords)
  if #keywords > 0 then
    result.denial_keywords = keywords
  end
  return result
end

---@param value unknown
---@return {workspace: Neoagent.ToolWorkspace, denial_keywords: string[]}
function M.decode_context(value)
  assert(object(value), "Tool RPC context must be an object")
  ---@cast value table
  exact(value, { workspace = true, denial_keywords = false }, "Tool RPC context")
  assert(object(value.workspace), "Tool RPC workspace must be an object")
  exact(value.workspace, { root = true, cwd = true }, "Tool RPC workspace")
  return {
    workspace = {
      root = path(value.workspace.root, "Tool RPC workspace root"),
      cwd = path(value.workspace.cwd, "Tool RPC workspace cwd"),
    },
    denial_keywords = denial_keywords(value.denial_keywords),
  }
end

---@param method string
---@param value unknown
---@return Neoagent.JsonObject
function M.encode_request(method, value)
  return util.copy(request(method, value)) --[[@as Neoagent.JsonObject]]
end

---@param method string
---@param value unknown
---@return table
function M.decode_request(method, value)
  return request(method, value)
end

---@param value Neoagent.ToolResult
---@param evidence? Neoagent.ToolRpcPolicyEvidence
---@return Neoagent.JsonObject
function M.encode_result(value, evidence)
  return {
    result = common.result(value),
    policy = evidence and policy(evidence) or nil,
  } --[[@as Neoagent.JsonObject]]
end

---@param value unknown
---@return Neoagent.ToolResult, Neoagent.ToolRpcPolicyEvidence?
function M.decode_result(value)
  assert(object(value), "Tool RPC response must be an object")
  ---@cast value table
  exact(value, { result = true, policy = false }, "Tool RPC response")
  return common.result(value.result), value.policy ~= nil and policy(value.policy) or nil
end

return M
