local M = {}

---@param options? {update_plan?: boolean}
---@return Neoagent.Tool<unknown>[]
function M.coding(options)
  local tools = {
    require("neoagent.tools.process").exec_command(),
    require("neoagent.tools.process").write_stdin(),
    require("neoagent.tools.codex.apply_patch").new(),
    require("neoagent.tools.codex.view_image").new(),
  }
  if options and options.update_plan then
    tools[#tools + 1] = require("neoagent.tools.update_plan").new()
  end
  return tools
end

return M
