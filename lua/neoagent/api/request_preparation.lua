local util = require("neoagent.util")

local semantic = require("neoagent.semantic_message")
local M = {}

---@class Neoagent.PreparedRequest
---@field owner Neoagent.Model
---@field options table
---@field operation "compact"|false
---@field credentials table
---@field plan Neoagent.RequestPlan
---@field identity? Neoagent.RequestIdentity

---@class Neoagent.PreparedRequestLayer
---@field options table
---@field dependency? table
---@field value table

---@class Neoagent.RequestBudget
---@field owner Neoagent.Model Borrowed Model whose request was budgeted.
---@field options table
---@field operation "compact"|false

---@class Neoagent.RequestPreparation
---@field request? Neoagent.PreparedRequest Latest shaped candidate.
---@field estimated? Neoagent.PreparedRequest Candidate acknowledged by estimation.
---@field layers table<table, Neoagent.PreparedRequestLayer>
---@field projection? {callback?: Neoagent.PrepareRequest, inputs: Neoagent.InferenceRequest, value: Neoagent.RequestProjection}
---@field budget? Neoagent.RequestBudget

-- The request owner retains this value through estimation and execution.
-- Each boundary retains only its latest candidate; Models never retain it.
---@return Neoagent.RequestPreparation
function M.new()
  return { layers = {} }
end

-- Request options are copied semantic input; preparation is an explicit,
-- shared dependency belonging to the current request owner.
---@generic T: Neoagent.RequestOverrides
---@param call T
---@return T
function M.copy(call)
  local preparation = call._preparation
  return util.copy(call, preparation and { [preparation] = preparation } or nil)
end

---@param call Neoagent.RequestOptions
---@return table
local function inputs(call)
  local result = {}
  for key, value in pairs(call) do
    if key ~= "_preparation" and key ~= "on_event" and key ~= "on_done" then
      result[key] = value
    end
  end
  return util.copy(result)
end

---@generic T: table
---@param owner table
---@param call Neoagent.RequestOptions
---@param prepare fun(): T
---@param dependency? table
---@return T
function M.reuse(owner, call, prepare, dependency)
  local scope = call._preparation
  if not scope then
    return prepare()
  end
  local options = inputs(call)
  local previous = scope.layers[owner]
  if previous and vim.deep_equal(previous.options, options) and vim.deep_equal(previous.dependency, dependency) then
    return M.copy(previous.value) --[[@as T]]
  end
  local value = prepare()
  scope.layers[owner] = { options = options, dependency = util.copy(dependency), value = M.copy(value) }
  return value
end

---@param owner Neoagent.Model
---@param call Neoagent.RequestOptions
---@param operation "compact"|false
---@param prepare fun(api_key?: string): Neoagent.RequestPlan, Neoagent.RequestIdentity?
---@param api_key? string|fun(): string?
---@return Neoagent.RequestPlan, Neoagent.RequestIdentity?
function M.plan(owner, call, operation, prepare, api_key)
  -- Callable keys are credentials too. Resolve before consulting a prepared
  -- request, just as the Authentication boundary revalidates its credentials.
  local resolved = api_key
  if type(resolved) == "function" then
    resolved = resolved()
  end
  local scope = call._preparation
  if not scope then
    return prepare(resolved)
  end
  local options, credentials = inputs(call), { api_key = resolved }
  local previous = scope.request
  if
    previous
    and previous.owner == owner
    and previous.operation == operation
    and vim.deep_equal(previous.options, options)
    and vim.deep_equal(previous.credentials, credentials)
  then
    return util.copy(previous.plan), util.copy(previous.identity)
  end
  local plan, identity = prepare(resolved)
  scope.request = {
    owner = owner,
    options = options,
    operation = operation,
    credentials = credentials,
    plan = util.copy(plan),
    identity = util.copy(identity),
  }
  return plan, identity
end

-- The estimated candidate is an explicit value, separate from a later
-- credential refresh. Rebuilding a cache entry cannot approve new content.
---@param call Neoagent.RequestOptions
---@param plan Neoagent.RequestPlan
---@return integer
function M.estimate(call, plan)
  local scope = call._preparation
  if scope then
    scope.estimated = scope.request
  end
  return plan.input_tokens
end

---@param owner Neoagent.Model
---@param call Neoagent.RequestOptions
---@param operation? "compact"
function M.record_budget(owner, call, operation)
  local scope = call._preparation
  if scope then
    scope.budget = {
      owner = owner,
      options = inputs(call),
      operation = operation or false,
    }
  end
end

---@param call Neoagent.RequestOptions
---@param owner? Neoagent.Model
---@param operation? "compact"
function M.validate_candidate(call, owner, operation)
  local scope = call._preparation
  local estimated = scope and scope.estimated
  local budget = scope and scope.budget
  local valid = true
  if budget then
    valid = (owner == nil or budget.owner == owner)
      and budget.operation == (operation or false)
      and vim.deep_equal(inputs(call), budget.options)
  end
  if estimated then
    valid = valid
      and vim.deep_equal(call.messages, estimated.options.messages)
      and call.system_prompt == estimated.options.system_prompt
      and vim.deep_equal(call.tools, estimated.options.tools)
  end
  if not valid then
    local err = util.error("model", "Request content changed after budget validation; prepare the request again")
    err.code, err.retryable = "stale_request_preparation", false
    error(err, 0)
  end
end

-- Callers supply the final projection. This gate owns the decision to estimate
-- a new candidate or validate an earlier estimate before inference begins.
---@async
---@param owner Neoagent.Model
---@param call Neoagent.RequestOptions
---@param operation? "compact"
function M.finalize(owner, call, operation)
  local scope = assert(call._preparation, "Request preparation is required")
  if not scope.estimated and not scope.budget then
    require("neoagent.api.request_estimate").request(owner, call, operation)
  end
  M.validate_candidate(call, owner, operation)
end

---@param call Neoagent.RequestOptions
---@param plan Neoagent.RequestPlan
function M.validate_execution(call, plan)
  local scope = call._preparation
  local estimated = scope and scope.estimated
  if not estimated then
    return
  end
  local current = assert(assert(scope).request)
  local previous = estimated.plan
  if
    current.owner ~= estimated.owner
    or current.operation ~= estimated.operation
    or current.options.system_prompt ~= estimated.options.system_prompt
    or plan.api ~= previous.api
    or not vim.deep_equal(plan.messages, previous.messages)
    or not vim.deep_equal(plan.request.body, previous.request.body)
    or not vim.deep_equal(plan.prompt_prefix, previous.prompt_prefix)
    or plan.input_tokens ~= previous.input_tokens
  then
    local err = util.error("model", "Request content changed after budget validation; prepare the request again")
    err.code = "stale_request_preparation"
    err.retryable = false
    error(err, 0)
  end
end

---@class Neoagent.RequestProjection
---@field messages Neoagent.RequestMessage[]
---@field system_prompt? string

---@class Neoagent.InferenceRequest: Neoagent.RequestProjection
---@field tools Neoagent.ToolDefinition[]

---@alias Neoagent.PrepareRequest async fun(request: Neoagent.InferenceRequest): Neoagent.RequestProjection?

---@async
---@param callback? Neoagent.PrepareRequest
---@param messages Neoagent.RequestMessage[]
---@param system_prompt? string
---@param tools Neoagent.ToolDefinition[]
---@param files? Neoagent.FileSource
---@param preparation? Neoagent.RequestPreparation
---@return Neoagent.RequestProjection
function M.project(callback, messages, system_prompt, tools, files, preparation)
  local inputs = { messages = messages, system_prompt = system_prompt, tools = tools }
  local previous = preparation and preparation.projection
  if previous and previous.callback == callback and vim.deep_equal(previous.inputs, inputs) then
    return util.copy(previous.value)
  end
  local projection
  if callback then
    projection = callback({
      messages = util.copy(messages),
      system_prompt = system_prompt,
      tools = util.copy(tools),
    })
  end
  if projection == nil then
    projection = { messages = util.copy(messages), system_prompt = system_prompt }
  end
  assert(type(projection) == "table" and not util.is_list(projection), "prepare_request must return a projection")
  for key in pairs(projection) do
    assert(key == "messages" or key == "system_prompt", "unsupported request projection field: " .. tostring(key))
  end
  assert(
    projection.system_prompt == nil
      or type(projection.system_prompt) == "string" and util.is_valid_utf8(projection.system_prompt),
    "invalid projected system prompt"
  )
  local normalized, err = semantic.normalize_request_list(projection.messages)
  assert(normalized, "invalid request projection: " .. tostring(err))
  if callback then
    require("neoagent.model").require_files({ messages = normalized, files = files })
  end
  local result = { messages = normalized, system_prompt = projection.system_prompt }
  if preparation then
    preparation.projection = { callback = callback, inputs = util.copy(inputs), value = util.copy(result) }
  end
  return result
end

return M
