-- Model-facing contract adapted from Pi 3390bd9363 (MIT).
local M = {}

---@return Neoagent.Tool<unknown>
function M.new()
  local tool = require("neoagent.tools.write_file").new()
  tool.name = "write"
  tool.description =
    "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories."
  tool.prompt_snippet = "Write new files"
  tool.prompt_guidelines = { "Use write only for new files or complete rewrites" }
  return tool
end

return M
