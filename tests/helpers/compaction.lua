local util = require("neoagent.util")

---@class Neoagent.TestCompactionEvaluation: Neoagent.CompactionEvaluation
---@field preparation? Neoagent.AnyCompactionPreparation
---@field error? Neoagent.Error

---@async
---@param component Neoagent.CompactionComponent
---@param options Neoagent.CompactionEvaluationOptions
---@return Neoagent.TestCompactionEvaluation
return function(component, options)
  local budget = component.evaluate(options)
  ---@type Neoagent.TestCompactionEvaluation
  local result = util.copy(budget)
  if budget.needed then
    ---@type Neoagent.CompactionPlanningOptions
    local inputs = vim.tbl_extend("force", {}, options, { budget = budget })
    result.preparation, result.error = component.prepare(inputs)
  end
  return result
end
