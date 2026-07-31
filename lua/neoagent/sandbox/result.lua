local util = require("neoagent.util")

local M = {}

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

function M.error(message, details)
  return {
    content = { { type = "text", text = message } },
    isError = true,
    details = details,
  }
end

function M.sandbox(message, fields)
  return M.error(message, { sandbox = util.copy(fields or {}) })
end

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
  value.details = value.details or {}
  value.details.sandbox = util.deep_merge(value.details.sandbox or {}, fields)
  return value
end

return M
