local util = require("neoagent.util")

local M = {}

---@param message string
---@return string
function M.denied(message)
  return message .. "\n" .. M.SANDBOX_FAILURE
end

M.SANDBOX_FAILURE = table.concat({
  "",
  "This tool call was blocked by the sandbox.",
  "",
  "To retry this exact tool call outside the sandbox, keep the same",
  "arguments and merge these fields into `options`:",
  '{"require_escalation":true,"escalation_justification":"(reason why you need to run this tool outside of the sandbox)"}',
}, "\n")

M.USER_DENIED = table.concat({
  "Escalated execution was denied by the user. Continue within the sandbox or",
  "use a different approach. Do not repeat the same elevation request unless",
  "the user provides new instructions.",
}, "\n")

---@param message string
---@param details? Neoagent.JsonValue
---@return Neoagent.ToolResult
function M.error(message, details)
  return {
    content = { { type = "text", text = message } },
    isError = true,
    details = details,
  }
end

---@param message string
---@param fields? Neoagent.JsonObject
---@return Neoagent.ToolResult
function M.sandbox(message, fields)
  local value = M.error(message)
  value.execution = { sandbox = util.copy(fields or {}) }
  return value
end

---@param value unknown
---@return TypeGuard<Neoagent.JsonObject>
local function object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

---@param value Neoagent.ToolResult
---@param fields? Neoagent.JsonObject
local function merge_sandbox(value, fields)
  local execution = value.execution
  if execution == nil then
    execution = {}
  end
  assert(object(execution), "Tool execution metadata must be an object")
  local sandbox = execution.sandbox
  assert(sandbox == nil or object(sandbox), "Sandbox execution metadata must be an object")
  ---@cast sandbox Neoagent.JsonObject?
  execution.sandbox = util.deep_merge(sandbox or {}, fields)
  value.execution = execution
end

---@param value Neoagent.ToolResult
---@param text string
---@param fields? Neoagent.JsonObject
---@return Neoagent.ToolResult
function M.append(value, text, fields)
  value = util.copy(value)
  local appended = false
  for _, block in ipairs(value.content or {}) do
    if block.type == "text" then
      block.text = (block.text or "") .. "\n" .. text
      appended = true
      break
    end
  end
  if not appended then
    value.content = value.content or {}
    table.insert(value.content, 1, { type = "text", text = text })
  end
  merge_sandbox(value, fields)
  return value
end

---@param value Neoagent.ToolResult
---@param message string
---@param fields? Neoagent.JsonObject
---@return Neoagent.ToolResult
function M.cleanup(value, message, fields)
  value = util.copy(value)
  value.content = value.content or {}
  local notice = fields
      and fields.cleanup_unobserved
      and "Stopped waiting for sandbox cleanup; cleanup continues independently and its outcome was not observed."
    or "Sandbox cleanup failed after the tool operation reported this result: " .. message
  local text = table.concat({
    notice,
    "The operation result above remains authoritative; do not retry it automatically.",
  }, "\n")
  value.content[#value.content + 1] = { type = "text", text = text }
  merge_sandbox(value, util.deep_merge(fields, { cleanup_notice = #value.content }))
  return value
end

return M
