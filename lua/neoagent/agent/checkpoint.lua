local async = require("neoagent.async")
local request_preparation = require("neoagent.api.request_preparation")
local checkpoint = require("neoagent.compaction.checkpoint")
local util = require("neoagent.util")

local M = {}

---@alias Neoagent.CompactionRequest {system_prompt?: string, tools: Neoagent.ToolDefinition[], model_options: Neoagent.StreamOverrides}

---@class Neoagent.AgentCheckpointContext
---@field session Neoagent.Session
---@field model? Neoagent.Model
---@field component Neoagent.CompactionComponent
---@field configured Neoagent.CompactionOptions|false
---@field request Neoagent.CompactionRequest

---@class Neoagent.AgentCheckpointOperation: Neoagent.AgentCheckpointContext
---@field parent Neoagent.AgentRun
---@field inputs? Neoagent.CompactionPlanningOptions
---@field instructions? string
---@field reason string
---@field report fun(diagnostic: Neoagent.AsyncDiagnostic)
---@field close_unmatched_calls fun(): true?, Neoagent.Error?
---@field is_current fun(): boolean
---@field on_start fun()
---@field execute async fun(call: Neoagent.CompactionRunOptions): Neoagent.CompactionResult
---@field on_commit fun()
---@field publish_messages fun()

---@param err unknown
---@param kind? string
---@return Neoagent.AsyncFailure
local function failed_result(err, kind)
  return { ok = false, error = util.normalize_error(err, kind or "compaction") }
end

---@param options Neoagent.AgentCheckpointContext
---@param force? boolean
---@param messages? Neoagent.RequestMessage[]
---@return Neoagent.CompactionEvaluation?, Neoagent.Error?, Neoagent.CompactionPlanningOptions?
---@async
function M.evaluate(options, force, messages)
  local request = options.request
  local model = options.model
  if options.configured == false or not model then
    return nil
  end
  local source_leaf = options.session:leaf_id()
  if not messages then
    local message_err
    messages, message_err = options.session:context_messages()
    if not messages then
      return nil, message_err
    end
  end
  local path, path_err = options.session:path()
  if not path then
    return nil, path_err
  end
  local inputs = {
    configured = options.configured,
    model = model,
    messages = assert(messages),
    path = path,
    system_prompt = request.system_prompt,
    tools = request.tools,
    force = force,
    model_options = request.model_options,
  }
  local evaluated, evaluation = pcall(options.component.evaluate, inputs)
  if not evaluated then
    return nil, util.normalize_error(evaluation, "model")
  end
  if options.session:leaf_id() ~= source_leaf then
    return nil, util.error("compaction", "Session changed while preparing its checkpoint")
  end
  inputs.budget = evaluation
  return evaluation, nil, inputs
end

---@param options Neoagent.AgentCheckpointOperation
---@return Neoagent.AnyCompactionPreparation?, Neoagent.Error?
---@async
local function prepare(options)
  local inputs = options.inputs
  if not inputs then
    local evaluation, err
    evaluation, err, inputs = M.evaluate(options, true)
    if not evaluation then
      return nil, err
    end
  end
  return options.component.prepare(assert(inputs))
end

-- The Agent owns this transaction. Lifecycle callbacks publish activity and
-- transcript state; strategies only generate and fit checkpoint candidates.
---@param options Neoagent.AgentCheckpointOperation
---@return_overload Neoagent.CompactionResult, nil, true
---@return_overload nil, Neoagent.Error?, false
---@async
function M.run(options)
  local request = options.request
  local component = options.component
  local started = false
  local completed, result, prepare_err = pcall(
    ---@async
    ---@return Neoagent.CompactionResult?, Neoagent.Error?
    function()
      local closed, close_err = options.close_unmatched_calls()
      if not closed then
        return nil, close_err
      end
      local source_leaf = options.session:leaf_id()
      local preparation, prepare_err = prepare(options)
      if not preparation then
        return nil, prepare_err
      end
      started = true
      options.on_start()
      ---@type Neoagent.CompactionRunOptions
      local call = {
        preparation = preparation,
        model = assert(options.model),
        model_options = request_preparation.copy(request.model_options),
        system_prompt = request.system_prompt,
        tools = request.tools,
        instructions = options.instructions,
        reason = options.reason,
        report = options.report,
      }
      local generated = options.execute(call)
      local result = generated

      if generated.ok == true then
        ---@cast generated Neoagent.CompactionSuccess
        local acceptance = {
          model = call.model,
          settings = preparation.settings,
          system_prompt = call.system_prompt,
          tools = call.tools,
          model_options = call.model_options,
          project = function(payload)
            return options.session:preview_compaction(payload)
          end,
        }
        ---@type Neoagent.CompactionSuccess?, Neoagent.Error?
        local candidate, acceptance_err = generated, nil
        if component.fit then
          candidate, acceptance_err = component.fit(assert(candidate), acceptance)
        end
        if candidate then
          candidate, acceptance_err = checkpoint.accept(candidate, acceptance)
        end
        result = candidate or failed_result(acceptance_err, "compaction")
      end
      if result.ok and (options.parent:is_cancelled() or not options.is_current()) then
        result = failed_result(async.cancelled_error)
      end
      if result.ok and options.session:leaf_id() ~= source_leaf then
        result = failed_result(util.error("compaction", "Session changed while preparing its checkpoint"))
      end
      if result.ok == true then
        local appended, append_err = options.session:append_compaction(checkpoint.payload(result))
        if not appended then
          result = failed_result(append_err, "compaction")
        else
          options.on_commit()
        end
      end
      if result.ok == true then
        local projected, projection_err = options.session:context_messages()
        if projected then
          if options.is_current() then
            options.publish_messages()
          end
        else
          result = failed_result(projection_err, "compaction")
        end
      end
      return result, nil
    end
  )
  if not completed then
    result = failed_result(result, "compaction")
  end
  if not started then
    local err = result and result.error or prepare_err
    if err then
      err = util.normalize_error(err, "compaction")
      err.operation = "compaction"
    end
    return nil, err, false
  end
  assert(result, "Started compaction must return a result")
  if not result.ok then
    result.error.operation = "compaction"
  end
  return result, nil, true
end

return M
