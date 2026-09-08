local M = {}

---@alias Neoagent.SandboxApprovalContext {context?: {cwd?: string}|{workspace?: {cwd?: string}}}

---@param ctx? Neoagent.SandboxApprovalContext
---@return {cwd?: string}?
local function workspace(ctx)
  local context = ctx and ctx.context
  return context and rawget(context, "workspace") or context
end

---@param ctx? Neoagent.SandboxApprovalContext
---@return string?
local function cwd(ctx)
  local value = workspace(ctx)
  return type(value) == "table" and value.cwd or nil
end

---@type table<string, fun(arguments: Neoagent.JsonObject, ctx?: Neoagent.SandboxApprovalContext): string>
local summaries = {
  shell = function(arguments)
    return "$ " .. tostring(arguments.command)
  end,
  read_file = function(arguments)
    return "Read " .. tostring(arguments.path)
  end,
  write_file = function(arguments)
    local size = type(arguments.content) == "string" and #arguments.content or 0
    return string.format("Write %s (%d bytes)", tostring(arguments.path), size)
  end,
  edit_file = function(arguments)
    local count = type(arguments.edits) == "table" and #arguments.edits or 0
    return string.format("Edit %s (%d replacement%s)",
      tostring(arguments.path), count, count == 1 and "" or "s")
  end,
  grep = function(arguments, ctx)
    local root = arguments.path or cwd(ctx) or "the workspace"
    return "Search for " .. tostring(arguments.pattern) .. " in " .. tostring(root)
  end,
  find = function(arguments, ctx)
    local root = arguments.path or cwd(ctx) or "the workspace"
    return "Find " .. tostring(arguments.pattern) .. " in " .. tostring(root)
  end,
  read_agent_documentation = function()
    return "Read Neoagent documentation"
  end,
}

---@param tool Neoagent.ToolDefinition
---@param arguments Neoagent.JsonObject
---@param ctx? Neoagent.SandboxApprovalContext
---@return string
function M.for_tool(tool, arguments, ctx)
  local summarize = summaries[tool.name]
  if summarize then return summarize(arguments, ctx) end
  return "Run " .. tostring(tool.name) .. " with its current arguments"
end

return M
