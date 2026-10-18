local identities = require("neoagent.tools.identities")
local invocations = require("neoagent.tools.invocation")
local util = require("neoagent.util")
local M = {}
local patch_actions = { add = "Add ", delete = "Delete ", update = "Update " }

---@type table<table, fun(request: table): string>
local summaries = {
  [identities.read_file] = function(request)
    return "Read " .. request.resolved_path
  end,
  [identities.view_image] = function(request)
    return "View image " .. request.resolved_path .. " (" .. request.detail .. ")"
  end,
  [identities.write_file] = function(request)
    return string.format("Write %s (%d bytes)", request.resolved_path, #request.content)
  end,
  [identities.edit_file] = function(request)
    local count = #request.edits
    return string.format("Edit %s (%d replacement%s)", request.resolved_path, count, count == 1 and "" or "s")
  end,
  [identities.grep] = function(request)
    return "Search for " .. request.pattern .. " in " .. request.resolved_path
  end,
  [identities.find] = function(request)
    return "Find " .. request.pattern .. " in " .. request.resolved_path
  end,
  [identities.apply_patch] = function(request)
    local lines, index = {}, 1
    for _, operation in ipairs(require("neoagent.tools.codex.patch").parse(request.patch)) do
      local path = request.paths[index]
      index = index + 1
      if operation.destination then
        lines[#lines + 1] = "Move and update " .. path .. " to " .. request.paths[index]
        index = index + 1
      else
        lines[#lines + 1] = patch_actions[operation.kind] .. path
      end
    end
    return table.concat(lines, "\n")
  end,
}

---@generic C
---@param tool Neoagent.Tool<C>
---@param arguments Neoagent.JsonObject
---@param ctx? Neoagent.ToolContext<C>
---@return string
function M.for_tool(tool, arguments, ctx)
  local identity = identities.identity(tool)
  local shell = identity and (identity.token == identities.exec_command or identity.token == identities.shell)
  local summarize = identity and summaries[identity.token]
  if shell or summarize then
    local prepared = invocations.current(tool.execute, ctx)
      or assert(invocations.prepare(tool, arguments, assert(ctx, "Tool approval requires its execution context")))
    local request = util.copy(prepared.request)
    if shell then
      return "Shell argv: "
        .. vim.json.encode(rawget(request, "argv"))
        .. "\nWorking directory: "
        .. (rawget(request, "cwd") or assert(prepared.workspace).cwd)
    end
    return assert(summarize)(request)
  end
  if tool.name == "read_agent_documentation" then
    return "Read Neoagent documentation"
  end
  return "Run " .. tostring(tool.name) .. " with its current arguments"
end

return M
