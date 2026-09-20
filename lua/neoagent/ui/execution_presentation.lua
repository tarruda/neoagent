local util = require("neoagent.util")

local M = {}

-- Executor notices remain content for the Model. Extract their explicitly
-- referenced blocks before Tool-owned previews render the remaining result.
---@param block Neoagent.RenderBlock
---@return Neoagent.RenderBlock, string?
function M.split(block)
  local message = block.message
  local execution = message and message.execution
  local sandbox = type(execution) == "table" and execution.sandbox or nil
  local index = type(sandbox) == "table" and sandbox.cleanup_notice or nil
  if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
    return block
  end
  ---@cast index integer
  local part = assert(message).content[index]
  if not part or part.type ~= "text" or part.text == "" then
    return block
  end
  local copied = util.copy(block)
  table.remove(assert(copied.message).content, index)
  return copied, part.text
end

return M
