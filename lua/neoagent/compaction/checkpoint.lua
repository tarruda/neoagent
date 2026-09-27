local model_contract = require("neoagent.model")
local plan = require("neoagent.compaction.plan")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.CheckpointAcceptanceOptions
---@field model Neoagent.Model
---@field settings Neoagent.CompactionSettings
---@field system_prompt? string
---@field tools? Neoagent.ToolDefinition[]
---@field model_options? Neoagent.StreamOverrides
---@field project fun(payload: Neoagent.CompactionPayload): Neoagent.RequestMessage[]?, Neoagent.Error?

---@param candidate Neoagent.CompactionSuccess
---@return Neoagent.CompactionPayload
function M.payload(candidate)
  return {
    summary = candidate.summary,
    native = util.copy(candidate.native),
    first_kept_entry_id = candidate.first_kept_entry_id,
    retained_users = util.copy(candidate.retained_users),
    tokens_before = candidate.tokens_before,
  }
end

-- Projection validation and budgeting are shared; retention policy belongs
-- to the component producing the candidate.
---@async
---@param candidate Neoagent.CompactionSuccess
---@param options Neoagent.CheckpointAcceptanceOptions
---@return number?, Neoagent.RequestMessage[]|Neoagent.Error
function M.evaluate(candidate, options)
  local messages, err = options.project(M.payload(candidate))
  if not messages then
    return nil, assert(err)
  end
  local compatible, compatibility_err = model_contract.compatible_context(options.model, messages)
  if not compatible then
    return nil, assert(compatibility_err)
  end
  model_contract.require_files({ messages = messages, files = options.model_options and options.model_options.files })
  local tokens =
    plan.request_tokens(options.model, messages, options.system_prompt, options.tools, options.model_options)
  return tokens, messages
end

---@async
---@param candidate Neoagent.CompactionSuccess
---@param options Neoagent.CheckpointAcceptanceOptions
---@return Neoagent.CompactionSuccess?, Neoagent.Error?
function M.accept(candidate, options)
  local tokens, err = M.evaluate(candidate, options)
  if not tokens then
    return nil, err --[[@as Neoagent.Error]]
  end
  local limit = options.model.context_window and options.model.context_window - options.settings.reserve_tokens
    or math.huge
  if tokens > limit then
    return nil, util.error("compaction", "Checkpoint exceeds the request limit; Session context was not replaced")
  end
  local accepted = util.copy(candidate)
  accepted.estimated_tokens_after = tokens
  return accepted
end

return M
