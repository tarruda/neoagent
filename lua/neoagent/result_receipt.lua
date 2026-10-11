local util = require("neoagent.util")

local M = {}

-- Receipts describe delivery, not durable Tool data. Bind a snapshot so copied
-- results preserve delivery while content edits require an explicit decision.
---@param result Neoagent.ToolResult
---@param value Neoagent.JsonObject
---@return Neoagent.ToolResult
function M.bind(result, value)
  result = util.copy(result)
  result.receipt = { content = util.copy(result.content), value = util.copy(value) }
  return result
end

---@param result Neoagent.ToolResult
---@return Neoagent.JsonObject?
function M.read(result)
  local receipt = result.receipt
  if type(receipt) == "table" and vim.deep_equal(result.content, receipt.content) then
    return util.copy(receipt.value)
  end
end

return M
