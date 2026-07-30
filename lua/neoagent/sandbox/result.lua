local util = require("neoagent.util")

local M = {}

M.RETRY = table.concat({
  "",
  "To retry this exact tool call outside the sandbox, keep the same arguments",
  "and merge these fields into `options`:",
  '{"require_escalation":true,"escalation_justification":"why unrestricted execution is necessary"}',
  "",
  "Request elevated execution only when the task cannot be completed inside",
  "the sandbox.",
}, "\n")

function M.denied(message)
  return "Sandbox blocked this tool call.\n\n" .. message .. "\n" .. M.RETRY
end

M.RESTRICTED_FAILURE = table.concat({
  "",
  "This command ran inside the sandbox. If a sandbox restriction caused the",
  "failure and no sandboxed approach is available, retry the same call with",
  "options.require_escalation and a specific escalation_justification.",
}, "\n")

M.USER_DENIED = table.concat({
  "Elevated execution was denied by the user. Continue within the sandbox or",
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
