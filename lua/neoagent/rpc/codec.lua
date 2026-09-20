local common = require("neoagent.tools.common")
local util = require("neoagent.util")
local validation = require("neoagent.validation")

local M = {}

M.events = {
  update = "tool_update",
  policy = "tool_policy",
  artifact_begin = "tool_artifact_begin",
  artifact_chunk = "tool_artifact_chunk",
  artifact_end = "tool_artifact_end",
}

local object = validation.object
local exact = validation.exact

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

---@class Neoagent.ToolRpcPolicyEvidence
---@field denial_output? string
---@field process_exit? {code: integer, signal: integer}

---@class Neoagent.ToolRpcContextOptions
---@field denial_keywords? string[]

---@param value unknown
---@return Neoagent.ToolRpcPolicyEvidence
function M.decode_policy(value)
  assert(object(value), "Tool RPC policy evidence must be an object")
  ---@cast value table
  exact(value, { denial_output = false, process_exit = false }, "Tool RPC policy evidence")
  assert(
    value.denial_output ~= nil or value.process_exit ~= nil,
    "Tool RPC policy evidence must contain an observation"
  )
  local result = {}
  if value.denial_output ~= nil then
    assert(
      type(value.denial_output) == "string"
        and value.denial_output ~= ""
        and #value.denial_output <= 8 * 1024
        and util.is_valid_utf8(value.denial_output),
      "Tool RPC denial evidence must be bounded UTF-8 text"
    )
    result.denial_output = value.denial_output
  end
  if value.process_exit ~= nil then
    local process_exit = value.process_exit
    assert(object(process_exit), "Tool RPC process exit must be an object")
    exact(process_exit, { code = true, signal = true }, "Tool RPC process exit")
    local code = common.integer(process_exit.code, "Tool RPC process exit code", true)
    local signal = common.integer(process_exit.signal, "Tool RPC process signal", true)
    assert(code <= 4294967295 and signal <= 127, "Tool RPC process exit is outside native bounds")
    result.process_exit = { code = code, signal = signal }
  end
  return result
end

---@param value unknown
---@return string[]
local function denial_keywords(value)
  if value == nil then
    return {}
  end
  assert(
    type(value) == "table" and util.is_list(value) and #value <= 32,
    "Tool RPC denial keywords must be a bounded list"
  )
  local selected = {}
  local total = 0
  for index, keyword in ipairs(value) do
    assert(
      type(keyword) == "string" and keyword ~= "" and #keyword <= 128 and util.is_valid_utf8(keyword),
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

---@param value unknown
---@return Neoagent.ToolResult
function M.result(value)
  local result = common.result(value)
  assert(result.execution == nil, "Tool RPC results cannot supply parent execution metadata")
  return result
end

---@param value unknown
---@return Neoagent.ToolResult
function M.update(value)
  local update = common.update(value)
  assert(update.execution == nil, "Tool RPC updates cannot supply parent execution metadata")
  return update
end

return M
