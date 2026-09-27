local async = require("neoagent.async")
local request_preparation = require("neoagent.api.request_preparation")
local estimate = require("neoagent.context_estimate")
local tree = require("neoagent.session_tree")
local request_estimate = require("neoagent.api.request_estimate")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.CompactionOptions
---@field auto? boolean
---@field reserve_tokens? integer
---@field keep_recent_tokens? integer

---@class Neoagent.CompactionSettings: Neoagent.CompactionOptions
---@field auto boolean
---@field reserve_tokens integer
---@field keep_recent_tokens integer

---@class Neoagent.CompactionEvaluationOptions
---@field configured Neoagent.CompactionOptions
---@field model Neoagent.Model
---@field messages Neoagent.RequestMessage[]
---@field path Neoagent.JournalEntry[]
---@field system_prompt? string
---@field tools? Neoagent.ToolDefinition[]
---@field force? boolean
---@field model_options? Neoagent.StreamOverrides

---@class Neoagent.CompactionEvaluation
---@field needed boolean
---@field tokens number
---@field input_limit number
---@field settings Neoagent.CompactionSettings

---@class Neoagent.CompactionPlanningOptions: Neoagent.CompactionEvaluationOptions
---@field budget Neoagent.CompactionEvaluation

---@class Neoagent.CompactionCut
---@field first_kept_index integer
---@field turn_start_index? integer
---@field split_turn boolean

---@class Neoagent.CompactionPreparation
---@field kind "summary"
---@field max_output_tokens? integer
---@field first_kept_entry_id? string
---@field messages Neoagent.Message[]
---@field turn_prefix Neoagent.Message[]
---@field split_turn boolean
---@field tokens_before integer
---@field previous_summary? string
---@field settings Neoagent.CompactionSettings

---@class Neoagent.NativeCompactionPreparation
---@field kind "native"
---@field source_messages Neoagent.RequestMessage[] Original request copy for bounded provider-overflow retries.
---@field request_messages Neoagent.RequestMessage[] Bounded request copy; Session context remains unchanged.
---@field retained_users Neoagent.RetainedUser[]
---@field tokens_before integer
---@field settings Neoagent.CompactionSettings

---@alias Neoagent.AnyCompactionPreparation Neoagent.CompactionPreparation|Neoagent.NativeCompactionPreparation

---@type Neoagent.CompactionSettings
M.defaults = {
  auto = true,
  reserve_tokens = 16384,
  keep_recent_tokens = 20000,
}

M.messages_tokens = request_estimate.messages
M.usage_tokens = estimate.usage_tokens
M.estimate_tokens = estimate.estimate_tokens
M.valid_assistant_usage = estimate.valid_assistant_usage
M.estimate_context = estimate.estimate_context

---@param path Neoagent.JournalEntry[]
---@return boolean
function M.has_usage_after_checkpoint(path)
  local checkpoint
  for index, entry in ipairs(path) do
    if entry.type == "compaction" then
      checkpoint = index
    end
  end
  if not checkpoint then
    return true
  end
  for index = checkpoint + 1, #path do
    local entry = assert(path[index])
    if entry.type == "message" and M.valid_assistant_usage(entry.message) then
      return true
    end
  end
  return false
end

---@param configured? Neoagent.CompactionOptions
---@param context_window? number
---@param defaults? Neoagent.CompactionSettings
---@return Neoagent.CompactionSettings
function M.settings(configured, context_window, defaults)
  local merged = util.deep_merge(defaults or M.defaults, configured or {})
  ---@cast merged Neoagent.CompactionSettings
  local reserve = merged.reserve_tokens
  local keep = merged.keep_recent_tokens
  if type(context_window) == "number" and context_window > 0 then
    reserve = math.min(reserve, math.max(1, math.floor(context_window / 4)))
    keep = math.min(keep, math.max(1, math.floor((context_window - reserve) / 2)))
  end
  return { auto = merged.auto, reserve_tokens = reserve, keep_recent_tokens = keep }
end

---@param model Neoagent.Model
---@param settings Neoagent.CompactionSettings
---@return integer
function M.summary_output_limit(model, settings)
  return math.max(
    1,
    math.floor(
      math.min(
        8192,
        (model.context_window or 32768) / 16,
        settings.reserve_tokens / 2,
        model.max_output_tokens or math.huge
      )
    )
  )
end

---@param context_tokens number
---@param context_window number
---@param settings Neoagent.CompactionSettings
---@return boolean
function M.should_compact(context_tokens, context_window, settings)
  return settings.auto and context_window > 0 and context_tokens > context_window - settings.reserve_tokens
end

---@param entry Neoagent.JournalEntry
---@return boolean
local function is_cut_point(entry)
  if entry.type ~= "message" then
    return false
  end
  ---@cast entry Neoagent.MessageEntry
  local role = entry.message.role
  return role == "user" or role == "assistant"
end

---@param entry Neoagent.JournalEntry
---@return boolean
local function is_turn_start(entry)
  if entry.type ~= "message" then
    return false
  end
  ---@cast entry Neoagent.MessageEntry
  return entry.message.role == "user"
end

---@param entries Neoagent.JournalEntry[]
---@param entry_index integer
---@param start_index integer
---@return integer?
function M.find_turn_start(entries, entry_index, start_index)
  for index = entry_index, start_index, -1 do
    if is_turn_start(assert(entries[index])) then
      return index
    end
  end
  return nil
end

---@param entries Neoagent.JournalEntry[]
---@param start_index integer
---@param end_index integer
---@param keep_recent_tokens integer
---@return Neoagent.CompactionCut
function M.find_cut_point(entries, start_index, end_index, keep_recent_tokens)
  ---@type integer[]
  local cut_points = {}
  for index = start_index, end_index do
    if is_cut_point(assert(entries[index])) then
      cut_points[#cut_points + 1] = index
    end
  end
  if #cut_points == 0 then
    return { first_kept_index = start_index, split_turn = false }
  end
  local accumulated = 0
  local cut_index = cut_points[1]
  assert(cut_index)
  for index = end_index, start_index, -1 do
    local entry = assert(entries[index])
    if entry.type == "message" then
      accumulated = accumulated + M.estimate_tokens(entry.message)
    end
    if accumulated >= keep_recent_tokens then
      for _, candidate in ipairs(cut_points) do
        if candidate > index then
          break
        end
        cut_index = candidate
      end
      break
    end
  end
  while cut_index > start_index do
    local previous = assert(entries[cut_index - 1])
    if previous.type == "compaction" or previous.type == "message" then
      break
    end
    cut_index = cut_index - 1
  end
  local turn_start
  if not is_turn_start(assert(entries[cut_index])) then
    turn_start = M.find_turn_start(entries, cut_index, start_index)
  end
  return {
    first_kept_index = cut_index,
    turn_start_index = turn_start,
    split_turn = turn_start ~= nil,
  }
end

---@class Neoagent.LocalCompactionBoundary
---@field start_index integer
---@field previous_summary? string

---@param path_entries Neoagent.JournalEntry[]
---@return Neoagent.LocalCompactionBoundary?, Neoagent.Error?
local function local_boundary(path_entries)
  local previous_index
  for index = #path_entries, 1, -1 do
    if assert(path_entries[index]).type == "compaction" then
      previous_index = index
      break
    end
  end
  local boundary_start = 1
  local previous_summary
  if previous_index then
    local previous = path_entries[previous_index]
    ---@cast previous Neoagent.CompactionEntry
    if previous.native then
      return nil, util.error("compaction", "Local compaction cannot replace an encrypted checkpoint")
    end
    previous_summary = assert(previous.summary)
    for index, entry in ipairs(path_entries) do
      if entry.id == previous.first_kept_entry_id then
        boundary_start = index
        break
      end
    end
    if boundary_start == 1 and assert(path_entries[1]).id ~= previous.first_kept_entry_id then
      boundary_start = previous_index + 1
    end
  end
  return { start_index = boundary_start, previous_summary = previous_summary }
end

---@class Neoagent.LocalCompactionSelection
---@field consumed Neoagent.JournalEntry[]
---@field first_kept_entry_id? string
---@field turn_start_entry_id? string
---@field previous_summary? string
---@field tokens_before integer
---@field settings Neoagent.CompactionSettings

---@class Neoagent.LocalCompactionSource
---@field select fun(whole?: boolean, first_kept_index?: integer): Neoagent.LocalCompactionSelection?, Neoagent.Error?
---@field next_cut table<string, integer>

-- One planning operation owns its active projection and semantic estimate.
-- Neither changes as the candidate retention boundary moves forward.
---@param path Neoagent.JournalEntry[]
---@param settings Neoagent.CompactionSettings
---@return Neoagent.LocalCompactionSource?, Neoagent.Error?
local function local_source(path, settings)
  if #path == 0 then
    return nil
  end
  local boundary, err = local_boundary(path)
  if not boundary then
    return nil, err
  end
  local active = tree.context_entries(path)
  local tokens_before = math.ceil(M.estimate_context(tree.to_llm(tree.messages(active))).tokens)
  local preferred = M.find_cut_point(path, boundary.start_index, #path, settings.keep_recent_tokens)
  local first_message, turn_start
  local turns, next_cut = {}, {}
  for index = boundary.start_index, #path do
    local entry = assert(path[index])
    if entry.type == "message" and not first_message then
      first_message = index
    end
    if is_turn_start(entry) then
      turn_start = index
    else
      turns[index] = turn_start
    end
  end
  local following, after_following
  for index = #path, 1, -1 do
    local entry = assert(path[index])
    if is_cut_point(entry) then
      following, after_following = index, following
    end
    next_cut[entry.id] = after_following
  end
  return {
    next_cut = next_cut,
    select = function(whole, first_kept_index)
      local cut
      if not whole then
        cut = preferred
        if first_kept_index then
          cut = {
            first_kept_index = first_kept_index,
            turn_start_index = turns[first_kept_index],
            split_turn = turns[first_kept_index] ~= nil,
          }
        end
        if not first_message or first_message >= cut.first_kept_index then
          return nil, util.error("compaction", "Nothing can be compacted while retaining the recent context")
        end
      end
      ---@type Neoagent.LocalCompactionSelection
      local result = {
        consumed = {},
        settings = util.copy(settings),
        previous_summary = boundary.previous_summary,
        first_kept_entry_id = cut and assert(path[cut.first_kept_index]).id,
        tokens_before = tokens_before,
      }
      if cut and cut.turn_start_index then
        result.turn_start_entry_id = assert(path[cut.turn_start_index]).id
      end
      for _, entry in ipairs(active) do
        if entry.id == result.first_kept_entry_id then
          break
        end
        result.consumed[#result.consumed + 1] = entry
      end
      return result
    end,
  }
end

---@class Neoagent.LocalCheckpointPlan
---@field build fun(max_output_tokens: integer): Neoagent.CompactionPreparation
---@field known_summary string Fixed text carried into the checkpoint, excluding generated output.
---@field generations integer Number of independently capped generated summaries.

---@async
---@param model Neoagent.Model
---@param messages Neoagent.RequestMessage[]
---@param system_prompt? string
---@param tools? Neoagent.ToolDefinition[]
---@param model_options? Neoagent.StreamOverrides
---@param operation? "compact"
---@return integer
function M.request_tokens(model, messages, system_prompt, tools, model_options, operation)
  local call = request_preparation.copy(model_options or {})
  ---@cast call Neoagent.StreamOptions
  call.messages, call.system_prompt, call.tools = messages, system_prompt, tools
  return request_estimate.request(model, call, operation)
end

-- Observed usage already includes request overhead. It supplies a conservative
-- floor only when it belongs to the current context; semantic counts alone
-- never override the Model estimate.
---@param options Neoagent.CompactionEvaluationOptions
---@param defaults? Neoagent.CompactionSettings
---@return Neoagent.CompactionEvaluation
---@async
function M.evaluate_budget(options, defaults)
  local model = options.model
  local settings = M.settings(options.configured, model.context_window, defaults)
  ---@type number
  local tokens = M.request_tokens(model, options.messages, options.system_prompt, options.tools, options.model_options)
  local observed = M.estimate_context(options.messages)
  if observed.last_usage_index and M.has_usage_after_checkpoint(options.path) then
    tokens = math.max(tokens, observed.tokens)
  end
  local input_limit = model.context_window and model.context_window - settings.reserve_tokens or math.huge
  return {
    needed = options.force == true or M.should_compact(tokens, model.context_window or 0, settings),
    tokens = tokens,
    input_limit = input_limit,
    settings = settings,
  }
end

---@async
---@param options Neoagent.CompactionPlanningOptions
---@param assemble fun(selection: Neoagent.LocalCompactionSelection): Neoagent.LocalCheckpointPlan
---@return Neoagent.AnyCompactionPreparation?, Neoagent.Error?
function M.prepare_local(options, assemble)
  local evaluation = options.budget
  local settings = evaluation.settings
  local limit = M.summary_output_limit(options.model, settings)
  local leaf = options.path[#options.path]
  local recompacting = leaf ~= nil and leaf.type == "compaction"
  if recompacting then
    -- A provider overflow can follow a checkpoint without committing another
    -- message. Consume its active projection, including the retained suffix,
    -- and reduce output instead of selecting the same retention boundary.
    limit = math.min(limit, math.max(1, math.floor(M.messages_tokens(options.messages) / 2)))
  end
  local source, err = local_source(options.path, settings)
  if not source then
    return nil, err
  end
  local selection
  selection, err = source.select(recompacting)
  -- A completed exchange may occupy the entire request. It is still a valid
  -- checkpoint boundary when retaining any suffix would prevent progress.
  if not selection and evaluation.tokens <= evaluation.input_limit then
    return nil, err
  end
  local project = tree.compaction_projector(options.path)
  for _ = 1, #options.path + 1 do
    if not selection then
      selection = assert(source.select(true))
    end
    local checkpoint = assemble(selection)
    local projected, projection_err = project({
      summary = checkpoint.known_summary ~= "" and checkpoint.known_summary or "Summary pending.",
      tokens_before = selection.tokens_before,
      first_kept_entry_id = selection.first_kept_entry_id,
    })
    if not projected then
      return nil, projection_err
    end
    local fixed = M.request_tokens(
      options.model,
      projected,
      options.system_prompt,
      options.tools,
      options.model_options
    ) + 32
    local output = math.min(limit, math.floor((evaluation.input_limit - fixed) / checkpoint.generations))
    -- Prefer the complete output allowance; a whole-context checkpoint may
    -- use a smaller allowance if fixed request content takes most of the window.
    if output >= limit or not selection.first_kept_entry_id and output >= 1 then
      return checkpoint.build(output)
    end
    if not selection.first_kept_entry_id then
      break
    end
    -- Move through real journal boundaries, preserving Tool-call/result pairs.
    -- A preferred semantic suffix is only the first candidate, not a choice
    -- between retaining that entire suffix and retaining nothing.
    local next_index = source.next_cut[selection.first_kept_entry_id]
    async.yield()
    selection, err = source.select(next_index == nil, next_index)
  end
  return nil, util.error("compaction", "Request instructions and tools leave no room for compacted context")
end

return M
