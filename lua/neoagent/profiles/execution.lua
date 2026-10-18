local M = {}

---@param facts? Neoagent.ExecutionPolicyFacts
---@param tools Neoagent.ProfilePromptTool[]
---@return string
function M.describe(facts, tools)
  if not facts then
    return ""
  end
  if facts.mode == "external" then
    return "External executor: Tool placement and approvals are managed by the configured executor. Neoagent does not infer its filesystem or network grants."
  end
  if facts.mode == "host" then
    return "Host execution: sandboxing is disabled. Tools have the editor user's filesystem, process, environment, and network authority. Sandbox escalation is inactive."
  end
  if facts.mode == "blocked" then
    return "Sandboxing is enabled but unavailable. Restricted Tool execution is blocked until sandbox activation succeeds or the user explicitly disables sandboxing."
  end
  local lines = { "Native sandbox: " .. (facts.platform or "current platform") .. "." }
  if facts.dynamic_grants then
    lines[#lines + 1] = "Filesystem and network grants are resolved by the configured policy for each operation."
  else
    local filesystem = assert(facts.filesystem)
    lines[#lines + 1] = "Filesystem default: " .. filesystem.default .. ". Path exceptions:"
    for _, entry in ipairs(filesystem.entries) do
      lines[#lines + 1] = "- " .. entry.access .. ": " .. entry.path
    end
    lines[#lines + 1] = "Network: " .. assert(facts.network) .. "."
  end
  lines[#lines + 1] =
    "Host execution requires user approval. Tools can request approval after a proven denial before effects."
  local commands = {}
  for _, tool in ipairs(tools) do
    local properties = tool.input_schema.properties
    if properties and properties.sandbox_permissions and properties.justification then
      commands[#commands + 1] = tool.name
    end
  end
  if #commands > 0 then
    lines[#lines + 1] = "Command escalation for "
      .. table.concat(commands, ", ")
      .. " uses sandbox_permissions and justification."
  end
  if #facts.parent_tools > 0 then
    lines[#lines + 1] = "Parent Tool exceptions: "
      .. table.concat(facts.parent_tools, ", ")
      .. ". These retain their existing authority."
  end
  return table.concat(lines, "\n")
end

return M
