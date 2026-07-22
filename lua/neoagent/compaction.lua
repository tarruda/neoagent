local plan = require("neoagent.compaction.plan")
local summary = require("neoagent.compaction.summary")

local M = {
  defaults = plan.defaults,
  system_prompt = summary.system_prompt,
  usage_tokens = plan.usage_tokens,
  estimate_tokens = plan.estimate_tokens,
  estimate_context = plan.estimate_context,
  should_compact = plan.should_compact,
  find_turn_start = plan.find_turn_start,
  find_cut_point = plan.find_cut_point,
  prepare = plan.prepare,
  serialize = summary.serialize,
}

function M.settings(configured, context_window)
  return plan.settings(configured, context_window, M.defaults)
end

function M.run(opts)
  return summary.run(opts, M.system_prompt)
end

return M
