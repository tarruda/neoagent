local M = {}

---@param options? Neoagent.ToolPresetOptions
---@return Neoagent.Tool<unknown>[]
function M.coding(options)
  return {
    require("neoagent.tools.pi.read").new(),
    require("neoagent.tools.pi.command").new(options),
    require("neoagent.tools.pi.edit").new(),
    require("neoagent.tools.pi.write").new(),
  }
end

return M
