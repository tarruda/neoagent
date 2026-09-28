local plan = require("neoagent.compaction.plan")
local summary = require("neoagent.compaction.summary")

---@class Neoagent.CompactionDelta
---@field type "compaction_delta"
---@field phase "history"|"turn_prefix"
---@field text string

---@alias Neoagent.CompactionEvent Neoagent.CompactionDelta|Neoagent.ModelProviderStatus|Neoagent.ModelInferenceStats

---@class Neoagent.CompactionSuccess
---@field ok true
---@field summary? string Local summary text; absent for native checkpoints.
---@field first_kept_entry_id? string
---@field retained_users? Neoagent.RetainedUser[]
---@field tokens_before integer
---@field usage? Neoagent.Usage
---@field estimated_tokens_after? number
---@field native? Neoagent.NativeCompactionMessage

---@alias Neoagent.CompactionResult Neoagent.CompactionSuccess|Neoagent.AsyncFailure

---@class Neoagent.CompactionRunOptions: Neoagent.RunOptions<Neoagent.CompactionResult, Neoagent.CompactionEvent>
---@field preparation Neoagent.AnyCompactionPreparation
---@field model Neoagent.Model
---@field model_options? Neoagent.StreamOverrides
---@field instructions? string
---@field reason? string
---@field system_prompt? string
---@field tools? Neoagent.ToolDefinition[]

local M = {
  defaults = plan.defaults,
  system_prompt = summary.system_prompt,
  usage_tokens = plan.usage_tokens,
  valid_assistant_usage = plan.valid_assistant_usage,
  estimate_tokens = plan.estimate_tokens,
  estimate_context = plan.estimate_context,
  has_usage_after_checkpoint = plan.has_usage_after_checkpoint,
  should_compact = plan.should_compact,
  find_turn_start = plan.find_turn_start,
  find_cut_point = plan.find_cut_point,
  serialize = summary.serialize,
}

---@class Neoagent.CompactionComponent
---@field evaluate async fun(options: Neoagent.CompactionEvaluationOptions): Neoagent.CompactionEvaluation
---@field prepare async fun(options: Neoagent.CompactionPlanningOptions): Neoagent.AnyCompactionPreparation?, Neoagent.Error?
---@field fit? async fun(candidate: Neoagent.CompactionSuccess, options: Neoagent.CheckpointAcceptanceOptions): Neoagent.CompactionSuccess?, Neoagent.Error?
---@field run fun(options: Neoagent.CompactionRunOptions): Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
---@field require_native? boolean
---@field required_api? string

---@param options Neoagent.CompactionEvaluationOptions
---@return Neoagent.CompactionEvaluation
---@async
function M.evaluate_budget(options)
  return plan.evaluate_budget(options, M.defaults)
end

---@type Neoagent.CompactionComponent
M.local_component = {
  evaluate = function(options)
    return M.evaluate_budget(options)
  end,
  prepare = summary.prepare,
  run = function(options)
    return M.run(options)
  end,
}

---@param configured? Neoagent.CompactionConfig|false
---@return Neoagent.CompactionComponent
function M.for_config(configured)
  if configured and configured.strategy == "prefix" then
    return require("neoagent.compaction.prefix").component
  end
  return M.local_component
end

---@param configured? Neoagent.CompactionOptions
---@param context_window? number
---@return Neoagent.CompactionSettings
function M.settings(configured, context_window)
  return plan.settings(configured, context_window, M.defaults)
end

---@param opts Neoagent.CompactionRunOptions
---@return Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
function M.run(opts)
  return summary.run(opts, M.system_prompt)
end

return M
