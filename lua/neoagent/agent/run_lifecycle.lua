---@class Neoagent.AgentActivity
---@field id integer
---@field kind string
---@field phase string
---@field accepted boolean
---@field finalized boolean
---@field provider_lease? fun(): boolean?, Neoagent.Error?
---@field run? Neoagent.AgentRun
---@field steering_claim? Neoagent.SteeringClaim
---@field submission_id? integer
---@field base? Neoagent.AgentInteractionOptions
---@field observed_leaf? string
---@field compaction_epoch? integer
---@field last_length_epoch? integer
---@field length_continuation? boolean

local async = require("neoagent.async")
local context_metrics = require("neoagent.agent.context")
local request_preparation = require("neoagent.api.request_preparation")
local tool_schema = require("neoagent.api.tool_schema")
local util = require("neoagent.util")

---@alias Neoagent.AgentRunResult Neoagent.ChatResult|Neoagent.CompactionResult
---@alias Neoagent.AgentRun Neoagent.Run<Neoagent.AgentRunResult, nil>
---@alias Neoagent.ProviderRelease fun(): boolean?, Neoagent.Error?

---@class Neoagent.AgentToolEnvironment
---@field files Neoagent.Files
---@field workspace? Neoagent.Workspace
---@field agent? string
---@field session_id table

---@class Neoagent.AgentToolset<C = Neoagent.AgentToolEnvironment>: Neoagent.SandboxToolset<C>
---@field system_prompt? string

---@class Neoagent.AgentInteractionOptions: Neoagent.ChatOptions<Neoagent.AgentToolEnvironment>
---@field session Neoagent.Session
---@field prompt string
---@field workspace? Neoagent.Workspace
---@field thinking_level? Neoagent.ThinkingLevel
---@field activity? Neoagent.AgentActivity
---@field model_options Neoagent.StreamOverrides

---@class Neoagent.AgentCompactionSuccess: Neoagent.CompactionSuccess
---@field estimated_tokens_after? number

---@class Neoagent.AgentSubmissionAccepted
---@field type 'submission_accepted'
---@field submission_id integer
---@field prompt string
---@field entry_id? string

---@class Neoagent.AgentEventPublication
---@field type 'event'
---@field event Neoagent.AgentEvent

---@class Neoagent.AgentFinishPublication
---@field type 'finish'
---@field result Neoagent.AgentCompletion

---@alias Neoagent.AgentRunPublication Neoagent.AgentSubmissionAccepted|Neoagent.AgentEventPublication|Neoagent.AgentFinishPublication

---@class Neoagent.RunLifecycleOptions
---@field state Neoagent.AgentState
---@field config Neoagent.Config<Neoagent.AgentToolEnvironment>
---@field notify fun(message: string, level?: integer)
---@field publish fun(publication: Neoagent.AgentRunPublication)
---@field publish_messages fun(messages: Neoagent.TranscriptMessage[])
---@field update_context fun()
---@field sync_tools fun()
---@field transcript_messages fun(session: Neoagent.Session): Neoagent.TranscriptMessage[]
---@field require_workspace_trust fun()
---@field ensure_session fun()
---@field ensure_model fun(): unknown
---@field commit_model_preference fun(): boolean?, Neoagent.Error?
---@field copy_toolset fun(value: Neoagent.AgentToolset): Neoagent.AgentToolset
---@field system_prompt fun(prompt: string, tools: Neoagent.Tool<Neoagent.AgentToolEnvironment>[]): string
---@field refresh_buffer fun(path: string)
---@field provider_event? fun(event: Neoagent.AgentEvent)
---@field interaction? fun(options: Neoagent.AgentInteractionOptions): Neoagent.ChatRun
---@field compaction_run? fun(options: Neoagent.CompactionRunOptions): Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
---@field compaction_component? Neoagent.CompactionComponent
---@field acquire_provider fun(): Neoagent.ProviderRelease

---@class Neoagent.RunLifecycle
---@field send fun(text: string): Neoagent.AgentRun|true|nil, Neoagent.Error?, integer?, ('turn'|'steering')?
---@field steer fun(text: string): true?, Neoagent.Error?, integer?, 'steering'?
---@field resubmit_steering fun(submission_id: integer): Neoagent.AgentRun?, Neoagent.Error?, integer?, 'turn'?
---@field dequeue_steering fun(): string[], integer[]
---@field compact fun(instructions?: string): Neoagent.AgentRun?, Neoagent.Error?
---@field stop fun(): boolean

local M = {}

local non_retryable_error_patterns = {
  "insufficient_quota",
  "quota exceeded",
  "usage limit",
  "usage_limit",
  "available balance",
  "out of budget",
  "billing",
}

local retryable_error_patterns = {
  "overloaded",
  "rate limit",
  "rate_limit",
  "too many requests",
  "service unavailable",
  "server error",
  "internal error",
  "provider returned error",
  "network error",
  "connection error",
  "connection refused",
  "connection lost",
  "connection reset",
  "other side closed",
  "fetch failed",
  "getaddrinfo",
  "enotfound",
  "eai_again",
  "upstream connect",
  "reset before headers",
  "socket hang up",
  "socket connection was closed",
  "timed out",
  "timeout",
  "terminated",
  "websocket closed",
  "websocket error",
  "transfer closed",
  "empty reply from server",
  "broken pipe",
  "failure when receiving data",
  "unexpected eof",
  "premature close",
  "ended without",
  "stream ended before",
  "request did not get a response",
  "you can retry your request",
  "try your request again",
  "please retry your request",
  "resourceexhausted",
}

local retryable_status = {
  [408] = true,
  [409] = true,
  [429] = true,
  [500] = true,
  [502] = true,
  [503] = true,
  [504] = true,
  [524] = true,
}

local PROMPT_STATS_DELAY_MS = 2000
local COMPLETION_ERROR_CHARACTERS = 512
local COMPLETION_DETAIL_CHARACTERS = 1024

---@param value unknown
---@param maximum integer
---@return string
local function bounded_text(value, maximum)
  if type(value) ~= "string" then
    local ok, rendered = pcall(tostring, value)
    value = ok and rendered or "unprintable value"
  end
  value = util.text_from_bytes(value)
  if vim.fn.strchars(value) <= maximum then
    return value
  end
  return vim.fn.strcharpart(value, 0, maximum) .. "…"
end

---@param value unknown
---@return Neoagent.Error?
local function completion_error(value)
  if value == nil then
    return nil
  end
  local source = util.normalize_error(value, "agent")
  local result = {
    kind = bounded_text(source.kind, 64),
    message = bounded_text(source.message, COMPLETION_ERROR_CHARACTERS),
  }
  local detail = source["detail"]
  if type(detail) == "table" and type(detail.message) == "string" then
    detail = detail.message
  end
  if type(detail) == "string" or type(detail) == "number" or type(detail) == "boolean" then
    result["detail"] = bounded_text(detail, COMPLETION_DETAIL_CHARACTERS)
  end
  for _, field in ipairs({ "code", "status", "retry_after_ms" }) do
    local selected = source[field]
    if type(selected) == "number" and selected == selected and selected ~= math.huge and selected ~= -math.huge then
      result[field] = selected
    elseif type(selected) == "string" then
      result[field] = bounded_text(selected, 128)
    end
  end
  result.retry_exhausted = source.retry_exhausted
  result.operation = source.operation
  result.context_overflow = source.context_overflow
  local retryable = rawget(source, "retryable")
  if type(retryable) == "boolean" then
    result.retryable = retryable
  end
  return result
end

---@param value unknown
---@return Neoagent.Usage?
local function completion_usage(value)
  if type(value) ~= "table" then
    return nil
  end
  local result = {}
  for _, field in ipairs({
    "input",
    "output",
    "reasoning",
    "cacheRead",
    "cacheWrite",
    "totalTokens",
  }) do
    local selected = value[field]
    if type(selected) == "number" and selected == selected and selected >= 0 and selected ~= math.huge then
      result[field] = selected
    end
  end
  return next(result) and result or nil
end

---@param done Neoagent.AgentRunResult
---@return Neoagent.AgentCompletion
local function completion_value(done)
  local failure = completion_error(done.error)
  local message = type(done.message) == "table" and done.message or nil
  local ok = done.ok == true
  local result = {
    ok = ok,
    status = ok and "succeeded" or failure and failure.kind == "cancelled" and "cancelled" or "failed",
    message_count = type(done.new_messages) == "table" and #done.new_messages or 0,
  }
  if failure then
    result.error = failure
  end
  if message and type(message.stopReason) == "string" then
    result.stop_reason = bounded_text(message.stopReason, 128)
  end
  local usage = completion_usage(done.usage or message and message.usage)
  if usage then
    result.usage = usage
  end
  return result
end

---@param value unknown
---@return number?
local function inference_rate(value)
  if type(value) ~= "number" or value <= 0 or value ~= value or value == math.huge then
    return nil
  end
  return value
end

---@param state Neoagent.AgentState
---@param event Neoagent.ModelInferenceStats
---@return {prompt_tokens_per_second?: number, generation_tokens_per_second?: number}?
local function apply_inference_stats(state, event)
  local prompt = inference_rate(event.prompt_tokens_per_second)
  local generation = inference_rate(event.generation_tokens_per_second)
  if prompt and (type(event.elapsed_ms) ~= "number" or event.elapsed_ms < PROMPT_STATS_DELAY_MS) then
    prompt = nil
  end
  if not prompt and not generation then
    return nil
  end
  state.inference_stats = generation and {
    generation_tokens_per_second = generation,
  } or {
    prompt_tokens_per_second = prompt,
  }
  return state.inference_stats
end

---@param state Neoagent.AgentState
---@param event Neoagent.ModelInferenceStats
---@param update fun()
local function publish_inference_stats(state, event, update)
  local stats = apply_inference_stats(state, event)
  if stats then
    update()
  end
end

---@param state Neoagent.AgentState
local function retain_completed_inference_stats(state)
  local stats = state.inference_stats
  if type(stats) == "table" and not inference_rate(stats.generation_tokens_per_second) then
    state.inference_stats = nil
  end
end

---@param err Neoagent.Error
---@return string
local function error_text(err)
  local parts = { type(err.message) == "string" and err.message or "" }
  if err["detail"] ~= nil then
    local ok, encoded = pcall(vim.json.encode, err["detail"])
    parts[#parts + 1] = ok and encoded or tostring(err["detail"])
  end
  return table.concat(parts, " "):lower()
end

---@param text string
---@param patterns string[]
---@return boolean
local function has_pattern(text, patterns)
  for _, pattern in ipairs(patterns) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

---@param err Neoagent.Error
---@return boolean
local function is_retryable_error(err)
  if err.kind == "cancelled" or err.retry_exhausted or err.operation == "compaction" then
    return false
  end
  local retryable = rawget(err, "retryable")
  if type(retryable) == "boolean" then
    return retryable
  end
  local text = error_text(err)
  if has_pattern(text, non_retryable_error_patterns) then
    return false
  end
  if has_pattern(text, retryable_error_patterns) then
    return true
  end
  local response = rawget(err, "response")
  response = type(response) == "table" and response or {}
  local status = tonumber(rawget(err, "status")) or tonumber(response.status) or tonumber(text:match("http%s+(%d%d%d)"))
  if status and status >= 400 then
    return retryable_status[status] == true
  end
  if err.kind == "transport" then
    return true
  end
  return false
end

---@async
---@param milliseconds number
---@return boolean
local function retry_delay(milliseconds)
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    if not timer then
      done.reject(util.error("agent", "Failed to create retry timer"))
      return
    end
    timer:start(math.max(1, math.floor(milliseconds)), 0, function()
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      done.resolve(true)
    end)
    return function()
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
  end)
end

---@param result Neoagent.AgentRunResult?
---@return boolean
local function is_context_overflow(result)
  if not result or result.ok or not result.error or result.error.operation == "compaction" then
    return false
  end
  return require("neoagent.model").is_context_overflow(result.error)
end

---@param result Neoagent.AgentRunResult?
---@return boolean?
local function is_length_limited(result)
  return result and result.ok and result.message and result.message.stopReason == "length"
end

---@return Neoagent.AsyncFailure
local function cancelled_result()
  return { ok = false, error = util.copy(async.cancelled_error) }
end

---@param err unknown
---@param kind string?
---@return Neoagent.AsyncFailure
local function failed_result(err, kind)
  return { ok = false, error = util.normalize_error(err, kind or "agent") }
end

---@param err unknown
---@return Neoagent.AsyncFailure
local function completion_failure(err)
  local cause = util.normalize_error(err, "agent")
  return {
    ok = false,
    error = util.error("agent", "Agent completion failed", cause.message),
  }
end

---@generic R
---@param value Neoagent.RunResult<R>
---@param label string
---@return Neoagent.RunResult<R>
local function operation_result(value, label)
  assert(type(value) == "table" and type(value.ok) == "boolean", label .. " returned an invalid result")
  return value
end

---@param options Neoagent.AgentInteractionOptions
---@return Neoagent.ChatRun
local function default_interaction(options)
  ---@type Neoagent.ChatOptions<Neoagent.AgentToolEnvironment>
  local call = {
    model = options.model,
    system_prompt = options.system_prompt,
    tools = options.tools,
    context = options.context,
    execute_tool = options.execute_tool,
    get_steering_messages = options.get_steering_messages,
    prepare_request_messages = options.prepare_request_messages,
    session_state = options.session_state,
    on_accept = options.on_accept,
    report = options.report,
    model_options = options.model_options,
    on_event = options.on_event,
    on_done = options.on_done,
  }
  return require("neoagent.chat").run(options.session, options.prompt, call)
end

---@param options Neoagent.AgentInteractionOptions
---@return Neoagent.ChatRun
local function default_continuation(options)
  ---@type Neoagent.ChatOptions<Neoagent.AgentToolEnvironment>
  local call = {
    model = options.model,
    system_prompt = options.system_prompt,
    tools = options.tools,
    context = options.context,
    execute_tool = options.execute_tool,
    get_steering_messages = options.get_steering_messages,
    prepare_request_messages = options.prepare_request_messages,
    model_options = options.model_options,
    report = options.report,
    on_event = options.on_event,
    on_done = options.on_done,
  }
  return require("neoagent.chat").continue(options.session, call)
end

---@param opts Neoagent.RunLifecycleOptions
---@return Neoagent.RunLifecycle
function M.new(opts)
  local state = opts.state
  local config = opts.config
  local component = opts.compaction_component or require("neoagent.compaction").for_config(config.compaction)
  local selection = state.request_selection
  local lifecycle = {}
  ---@type fun(prompt: string, claim?: Neoagent.SteeringClaim, id?: integer): Neoagent.AgentRun?, Neoagent.Error?
  local submit
  ---@type fun()
  local schedule_steering

  ---@return integer
  local function next_submission_id()
    state.next_submission_id = state.next_submission_id + 1
    return state.next_submission_id
  end

  ---@param diagnostic Neoagent.AsyncDiagnostic
  local function report_callback(diagnostic)
    opts.notify("callback failed during " .. diagnostic.phase .. ": " .. diagnostic.message, vim.log.levels.ERROR)
  end

  ---@param activity Neoagent.AgentActivity
  ---@return boolean
  local function current(activity)
    return state.activity == activity and not activity.finalized
  end

  ---@param activity Neoagent.AgentActivity
  ---@param phase string
  local function set_phase(activity, phase)
    activity.phase = phase
    if not state.destroyed then
      opts.update_context()
    end
  end

  ---@param activity Neoagent.AgentActivity
  local function release_provider(activity)
    local release = assert(activity.provider_lease, "Agent activity has no provider lease")
    activity.provider_lease = nil
    local called, released, release_err = pcall(release)
    if not called or released == nil or released == false then
      local err = called and release_err or released
      pcall(
        opts.notify,
        "failed to release provider use: " .. util.normalize_error(err, "provider").message,
        vim.log.levels.ERROR
      )
    end
  end

  ---@return boolean
  local function destroy_runtimes_if_ready()
    if not state.destroyed or state.activity ~= nil then
      return false
    end
    local destroy = state.destroy_runtimes
    state.destroy_runtimes = nil
    if destroy then
      pcall(destroy)
    end
    return destroy ~= nil
  end

  ---@return true?, Neoagent.Error?
  local function close_unmatched_calls()
    if state.destroyed then
      return nil, util.error("agent", "Agent is destroyed")
    end
    local messages = state.session:messages()
    local pending = {}
    local order = {}
    for _, message in ipairs(messages) do
      if message.role == "compactionSummary" or message.role == "compactionCheckpoint" then
        pending = {}
        order = {}
      elseif message.role == "assistant" then
        for _, block in ipairs(message.content or {}) do
          if block.type == "toolCall" then
            pending[block.id] = block
            order[#order + 1] = block.id
          end
        end
      elseif message.role == "toolResult" then
        pending[message.toolCallId] = nil
      end
    end
    for _, id in ipairs(order) do
      local call = pending[id]
      if call then
        local ok, err = state.session:append({
          role = "toolResult",
          toolCallId = call.id,
          toolName = call.name,
          content = {
            {
              type = "text",
              text = "Tool execution was interrupted; side effects may already have occurred.",
            },
          },
          isError = true,
          timestamp = util.now_ms(),
        })
        if not ok then
          return nil, err
        end
        pending[id] = nil
      end
    end
    return true
  end

  -- Recovery and manual operations construct the same semantic request inputs
  -- that Chat and the Loop provide at the inference gate.
  ---@param system_prompt? string
  ---@param tools Neoagent.Tool<Neoagent.AgentToolEnvironment>[]
  ---@param model_options? Neoagent.StreamOverrides
  ---@return Neoagent.CompactionRequest
  local function compaction_request(system_prompt, tools, model_options)
    local call = request_preparation.copy(model_options or {})
    call._preparation = request_preparation.new()
    call.files = state.session:files()
    call.file_cache = state.session:file_cache()
    call.thinking_level = selection:thinking_level()
    call.request_context =
      require("neoagent.api.request_context").resolve({ session_id = state.session:id() }, call.request_context)
    return { system_prompt = system_prompt, tools = tool_schema.definitions(tools), model_options = call }
  end

  ---@param request Neoagent.CompactionRequest
  ---@param force? boolean
  ---@param messages? Neoagent.RequestMessage[]
  ---@return Neoagent.CompactionEvaluation?, Neoagent.Error?, Neoagent.CompactionPlanningOptions?
  ---@async
  local function evaluate_compaction(request, force, messages)
    return require("neoagent.agent.checkpoint").evaluate({
      session = state.session,
      model = selection:model(),
      component = component,
      configured = config.compaction,
      request = request,
    }, force, messages)
  end

  ---@param activity Neoagent.AgentActivity
  ---@param submission_id integer?
  ---@param prompt string
  ---@param entry_id string?
  ---@return boolean
  local function publish_submission(activity, submission_id, prompt, entry_id)
    if not current(activity) or state.destroyed then
      return false
    end
    local record = {
      type = "submission_accepted",
      submission_id = assert(submission_id),
      prompt = prompt,
      entry_id = entry_id,
    }
    opts.publish(record)
    return true
  end

  ---@param message Neoagent.ToolResultMessage
  local function refresh_result(message)
    if message.isError then
      return
    end
    local details = type(message.details) == "table" and message.details or {}
    local changed_paths = details.changed_paths
    if type(changed_paths) == "table" and util.is_list(changed_paths) then
      for _, path in ipairs(changed_paths) do
        if type(path) == "string" and path ~= "" then
          opts.refresh_buffer(path)
        end
      end
    end
  end

  ---@param activity Neoagent.AgentActivity
  ---@param event Neoagent.AgentEvent
  ---@return boolean
  local function handle_event(activity, event)
    if not current(activity) or state.destroyed then
      return false
    end
    if event.type == "usage" then
      state.live_usage = {
        tokens = context_metrics.usage_tokens(event.usage) or 0,
        message_count = #assert(state.session:context_messages()) + 1,
      }
      opts.update_context()
    elseif event.type == "provider_status" then
      state.provider_status = type(event.text) == "string" and event.text or nil
      opts.update_context()
    elseif event.type == "inference_stats" then
      publish_inference_stats(state, event --[[@as Neoagent.ModelInferenceStats]], opts.update_context)
    elseif event.type == "message_end" then
      opts.sync_tools()
      opts.update_context()
    end
    if event.type == "message_end" then
      state.pending_events = {}
    elseif event.type ~= "usage" and event.type ~= "provider_status" and event.type ~= "inference_stats" then
      state.pending_events[#state.pending_events + 1] = util.copy(event)
    end
    if type(opts.provider_event) == "function" then
      opts.provider_event(event)
    end
    opts.publish({ type = "event", event = event })
    if event.type == "tool_end" then
      ---@cast event Neoagent.ToolEndEvent
      refresh_result(event.message)
      activity.observed_leaf = event.message._neoagent_entry_id or activity.observed_leaf
    elseif event.type == "message_end" then
      ---@cast event Neoagent.MessageEndEvent
      activity.observed_leaf = event.message._neoagent_entry_id or activity.observed_leaf
    end
    return true
  end

  ---@async
  ---@generic R, E, O: table
  ---@param outer Neoagent.AgentRun
  ---@param activity Neoagent.AgentActivity
  ---@param factory fun(call: O): Neoagent.Run<R, E>
  ---@param call O
  ---@param label string
  ---@param installed? fun(run: Neoagent.Run<R, E>)
  ---@return Neoagent.RunResult<R>
  local function await_operation(outer, activity, factory, call, label, installed)
    local buffered = {}
    local active = false
    local finished = false
    call.on_event = function(event)
      if finished then
        return
      end
      if not active then
        buffered[#buffered + 1] = util.copy(event)
      else
        handle_event(activity, event)
      end
    end
    call.on_done = function() end

    local started, child = pcall(function()
      return factory(call)
    end)
    if not started then
      finished = true
      return failed_result(child, "agent")
    end
    ---@cast child Neoagent.Run<R, E>
    assert(
      type(child) == "table"
        and type(child.cancel) == "function"
        and type(child.is_done) == "function"
        and type(child.result) == "function"
        and type(child.await) == "function",
      label .. " must return a Run"
    )
    local completed = child:is_done()
    active = true
    if installed then
      local ok, err = pcall(installed, child)
      if not ok then
        pcall(child.cancel, child)
        finished = true
        return failed_result(err, "agent")
      end
    end
    for _, event in ipairs(buffered) do
      if not current(activity) then
        break
      end
      handle_event(activity, event)
    end
    buffered = {}
    if outer:is_cancelled() then
      pcall(child.cancel, child)
      finished = true
      return cancelled_result()
    end
    if completed then
      finished = true
      return operation_result(child:result(), label)
    end

    local awaited, result = pcall( ---@async
      function()
        return child:await()
      end
    )
    finished = true
    if not awaited then
      assert(outer:is_cancelled(), result)
      return cancelled_result()
    end
    ---@cast result Neoagent.RunResult<R>
    return operation_result(result, label)
  end

  ---@param activity Neoagent.AgentActivity
  ---@param reason string
  ---@param result Neoagent.CompactionResult
  local function publish_compaction(activity, reason, result)
    if not current(activity) or state.destroyed then
      return
    end
    opts.publish({
      type = "event",
      event = {
        type = "compaction_end",
        reason = reason,
        result = result,
      },
    })
  end

  ---@async
  ---@param outer Neoagent.AgentRun
  ---@param activity Neoagent.AgentActivity
  ---@param request Neoagent.CompactionRequest
  ---@param reason string
  ---@param instructions string?
  ---@param inputs Neoagent.CompactionPlanningOptions?
  ---@return_overload Neoagent.CompactionResult, nil, true
  ---@return_overload nil, Neoagent.Error?, false
  local function run_compaction(outer, activity, request, reason, instructions, inputs)
    local result, err, started = require("neoagent.agent.checkpoint").run({
      session = state.session,
      model = selection:model(),
      component = component,
      configured = config.compaction,
      request = request,
      parent = outer,
      inputs = inputs,
      instructions = instructions,
      reason = reason,
      report = report_callback,
      close_unmatched_calls = close_unmatched_calls,
      is_current = function()
        return current(activity) and not state.destroyed
      end,
      on_start = function()
        set_phase(activity, "compacting")
        state.pending_events = {}
        state.inference_stats = nil
        if current(activity) and not state.destroyed then
          opts.publish({ type = "event", event = { type = "compaction_start", reason = reason } })
          opts.update_context()
        end
      end,
      execute = function(call)
        return await_operation(outer, activity, opts.compaction_run or component.run, call, "compaction Run")
      end,
      on_commit = function()
        activity.compaction_epoch = (activity.compaction_epoch or 0) + 1
      end,
      publish_messages = function()
        opts.publish_messages(opts.transcript_messages(state.session))
      end,
    })
    if not started then
      return nil, err, false
    end
    state.live_usage = nil
    retain_completed_inference_stats(state)
    publish_compaction(activity, reason, result)
    return result, nil, true
  end

  ---@async
  ---@param parent Neoagent.AgentRun
  ---@param owner Neoagent.AgentActivity
  ---@param request Neoagent.CompactionRequest
  ---@return Neoagent.RequestMessage[]?, Neoagent.Error?
  local function prepare_context(parent, owner, request)
    local messages, message_err = state.session:context_messages()
    if not messages then
      return nil, util.normalize_error(message_err, "session")
    end
    ---@type Neoagent.Model
    local model = assert(selection:model())
    local compatible, compatibility_err = require("neoagent.model").compatible_context(model, messages)
    if not compatible then
      return nil, compatibility_err
    end
    if component.require_native and type(model.compact) ~= "function" then
      return nil, util.error("compaction", "Profile requires a compatible Model with native compaction")
    end
    local evaluation, err, inputs = evaluate_compaction(request, false, messages)
    if err then
      return nil, err
    end
    if not evaluation or not evaluation.needed then
      return messages
    end
    local compacted, planning_err = run_compaction(parent, owner, request, "threshold", nil, inputs)
    if not compacted then
      return nil, planning_err or util.error("compaction", "Required compaction has no valid cut point")
    end
    if not compacted.ok then
      return nil, compacted.error
    end
    async.yield()
    set_phase(owner, "running")
    local refreshed, projection_err = state.session:context_messages()
    if not refreshed then
      return nil, util.normalize_error(projection_err, "session")
    end
    evaluation, err = evaluate_compaction(request, false, refreshed)
    if err then
      return nil, err
    end
    if evaluation and evaluation.needed then
      return nil, util.error("compaction", "Context still exceeds the request limit after compaction")
    end
    return refreshed
  end

  ---@param result Neoagent.AgentRunResult
  local function provider_result_event(result)
    if type(opts.provider_event) ~= "function" or type(result.error) ~= "table" then
      return
    end
    local status = rawget(result.error, "provider_status")
    local details = rawget(result.error, "provider_status_details")
    if type(status) ~= "string" and type(details) ~= "table" then
      return
    end
    opts.provider_event({
      type = "provider_status",
      text = status,
      details = util.copy(details),
    })
  end

  ---@async
  ---@param outer Neoagent.AgentRun
  ---@param activity Neoagent.AgentActivity
  ---@param base Neoagent.AgentInteractionOptions
  ---@param continuing boolean
  ---@param retry_attempt integer
  ---@return Neoagent.ChatResult
  local function run_interaction(outer, activity, base, continuing, retry_attempt)
    set_phase(activity, "running")
    state.inference_stats = nil
    ---@type Neoagent.AgentInteractionOptions
    local call = vim.tbl_extend("force", {}, base)
    call.model_options = request_preparation.copy(base.model_options)
    call.model_options.retry_attempt = retry_attempt
    local selected = continuing and default_continuation or (opts.interaction or default_interaction)
    local result = await_operation(outer, activity, selected, call, "interaction Run", function()
      if not current(activity) or state.destroyed then
        return
      end
      state.pending_events = {}
      if continuing or not activity.accepted then
        opts.publish_messages(opts.transcript_messages(state.session))
        activity.observed_leaf = state.session:leaf_id()
      end
      opts.update_context()
    end)
    if current(activity) and not state.destroyed then
      provider_result_event(result)
    end
    return result
  end

  ---@return true?, Neoagent.Error?
  local function abandon_failed_message()
    local path, path_err = state.session:path()
    if not path then
      return nil, path_err
    end
    -- Stores may supply message projections without a journal.
    local last = path[#path]
    if not last or last.type ~= "message" then
      return true
    end
    ---@cast last Neoagent.MessageEntry
    if last.message.role == "assistant" and last.message.stopReason == "error" then
      local parent = last.parent_id
      if parent == vim.NIL then
        parent = nil
      end
      local moved, move_err = state.session:move_to(parent)
      if not moved then
        return nil, move_err
      end
      if not state.destroyed then
        opts.publish_messages(opts.transcript_messages(state.session))
      end
    end
    return true
  end

  ---@param activity Neoagent.AgentActivity
  ---@param prompt string
  ---@param entry Neoagent.JournalEntry?
  ---@return boolean?, Neoagent.Error?
  local function accepted(activity, prompt, entry)
    if not current(activity) or state.destroyed then
      return false
    end
    assert(not activity.accepted, "Agent interaction accepted its prompt more than once")
    activity.accepted = true
    if activity.steering_claim then
      activity.steering_claim:commit()
      activity.steering_claim = nil
    end
    opts.publish_messages(opts.transcript_messages(state.session))
    activity.observed_leaf = state.session:leaf_id()
    opts.update_context()
    publish_submission(activity, activity.submission_id, prompt, type(entry) == "table" and entry.id or nil)
    local committed, commit_err = opts.commit_model_preference()
    if not committed then
      opts.notify(
        "the message was accepted but the workspace model preference was not saved: "
          .. util.normalize_error(commit_err, "storage").message,
        vim.log.levels.WARN
      )
    end
    return committed, commit_err
  end

  ---@async
  ---@param outer Neoagent.AgentRun
  ---@param activity Neoagent.AgentActivity
  ---@param base Neoagent.AgentInteractionOptions
  ---@return Neoagent.AgentRunResult
  local function interaction_pipeline(outer, activity, base)
    local overflow_retried = false
    local stream_retries = 0

    local done = run_interaction(outer, activity, base, false, stream_retries)

    while true do
      if outer:is_cancelled() then
        return cancelled_result()
      end
      if not overflow_retried and not (done.error and done.error.retry_exhausted) and is_context_overflow(done) then
        overflow_retried = true
        local abandoned, abandon_err = abandon_failed_message()
        if not abandoned then
          return completion_failure(abandon_err)
        end
        local request = compaction_request(base.system_prompt, base.tools or {}, base.model_options)
        local compacted, compaction_err, started = run_compaction(outer, activity, request, "overflow")
        if not started then
          if compaction_err and compaction_err.kind == "cancelled" then
            return failed_result(compaction_err)
          end
          return done
        end
        if not compacted.ok then
          if compacted.error and compacted.error.kind == "cancelled" then
            return compacted
          end
          return done
        end
        done = run_interaction(outer, activity, base, true, stream_retries)
      elseif is_length_limited(done) then
        if activity.last_length_epoch == (activity.compaction_epoch or 0) then
          local request = compaction_request(base.system_prompt, base.tools or {}, base.model_options)
          local evaluation, budget_err = evaluate_compaction(request, false)
          if budget_err then
            return failed_result(budget_err, "compaction")
          end
          if not evaluation or not evaluation.needed then
            return done
          end
        end
        activity.length_continuation = true
        done = run_interaction(outer, activity, base, true, stream_retries)
      else
        local retry_settings = config.retry
        ---@type number
        local retry_limit = retry_settings.enabled and retry_settings.max_retries or 0
        local provider_limit = done.error and tonumber(rawget(done.error, "stream_max_retries"))
        if provider_limit then
          retry_limit = math.min(retry_limit, provider_limit)
        end
        if done.error and is_retryable_error(done.error) and stream_retries < retry_limit then
          stream_retries = stream_retries + 1
          local abandoned, abandon_err = abandon_failed_message()
          if not abandoned then
            return completion_failure(abandon_err)
          end
          state.pending_events = {}
          state.live_usage = nil
          state.inference_stats = nil
          local wait = tonumber(rawget(done.error, "retry_after_ms"))
            or retry_settings.base_delay_ms * (2 ^ (stream_retries - 1))
          wait = math.max(0, math.min(60000, wait))
          state.provider_status = string.format("Reconnecting… %d/%d", stream_retries, retry_limit)
          set_phase(activity, "retrying")
          local waited, wait_err = pcall(retry_delay, wait)
          state.provider_status = nil
          if outer:is_cancelled() then
            return cancelled_result()
          end
          if not waited then
            return failed_result(wait_err, "agent")
          end
          done = run_interaction(outer, activity, base, true, stream_retries)
        else
          return done
        end
      end
    end
  end

  schedule_steering = function()
    if state.destroyed or state.activity ~= nil or state.steering:count() == 0 then
      return
    end
    local message = assert(state.steering:first())
    vim.schedule(function()
      local head = state.steering:first()
      if state.destroyed or state.activity ~= nil or not head or head.id ~= message.id then
        return
      end
      local claim = assert(state.steering:claim(message.id))
      opts.update_context()
      submit(message.message.content, claim, message.id)
    end)
  end

  ---@param activity Neoagent.AgentActivity
  local function reconcile_cancelled(activity)
    if state.session:leaf_id() == activity.observed_leaf then
      return
    end
    -- Completed effects can be committed after cancellation has stopped event
    -- delivery. Reconcile the unobserved suffix while this activity still owns
    -- the Session, before publishing its final state or accepting new work.
    local path, path_err = state.session:path()
    if not path then
      error(path_err, 0)
    end
    for index = #path, 1, -1 do
      local entry = path[index]
      if entry.id == activity.observed_leaf then
        break
      end
      if entry.type == "message" then
        ---@cast entry Neoagent.MessageEntry
        local message = entry.message
        if message.role == "toolResult" then
          ---@cast message Neoagent.ToolResultMessage
          refresh_result(message)
        end
      end
    end
    state.pending_events = {}
    opts.publish_messages(opts.transcript_messages(state.session))
  end

  ---@param activity Neoagent.AgentActivity
  ---@param result Neoagent.AgentRunResult
  ---@return boolean
  local function finalize(activity, result)
    if activity.finalized then
      return false
    end
    activity.finalized = true
    activity.phase = "finalizing"
    local projected, completion = pcall(completion_value, result)
    if not projected then
      completion = completion_value(failed_result(completion, "agent"))
    end
    local owned = state.activity == activity
    if not activity.accepted and activity.steering_claim then
      local restored = activity.steering_claim:rollback()
      activity.steering_claim = nil
      if restored and not state.destroyed then
        opts.update_context()
      end
    end
    if owned then
      state.live_usage = nil
      state.provider_status = nil
      retain_completed_inference_stats(state)
      state.last_result = completion
      if not state.destroyed then
        local published, publish_err = pcall(function()
          if completion.status == "cancelled" then
            reconcile_cancelled(activity)
          end
          opts.update_context()
          opts.publish({ type = "finish", result = completion })
        end)
        if not published then
          pcall(
            opts.notify,
            "failed to publish Agent completion: " .. util.normalize_error(publish_err, "agent").message,
            vim.log.levels.ERROR
          )
        end
      end
    end
    release_provider(activity)
    if state.activity == activity then
      state.activity = nil
    end
    destroy_runtimes_if_ready()
    if owned and not state.destroyed and completion.ok and activity.accepted then
      schedule_steering()
    end
    return true
  end

  ---@param kind string
  ---@param release Neoagent.ProviderRelease
  ---@param pipeline async fun(run: Neoagent.AgentRun, activity: Neoagent.AgentActivity): Neoagent.AgentRunResult
  ---@param activity_values? {steering_claim?: Neoagent.SteeringClaim, submission_id?: integer, base?: Neoagent.AgentInteractionOptions}
  ---@return Neoagent.AgentRun
  local function install_activity(kind, release, pipeline, activity_values)
    state.run_id = state.run_id + 1
    ---@type Neoagent.AgentActivity
    local activity = {
      id = state.run_id,
      kind = kind,
      phase = "preparing",
      accepted = false,
      provider_lease = release,
      finalized = false,
      observed_leaf = state.session:leaf_id(),
    }
    for key, value in pairs(activity_values or {}) do
      activity[key] = value
    end
    if activity.base then
      activity.base.activity = activity
      activity.base = nil
    end
    local open_gate
    local outer = async.run(function(run)
      async.await(function(done)
        open_gate = done.resolve
        return function() end
      end)
      local completed, result = pcall(pipeline, run, activity)
      if not completed then
        result = failed_result(result, "agent")
      end
      finalize(activity, result)
      return result
    end, {
      on_done = function(result)
        finalize(activity, result)
      end,
      report = report_callback,
      error_kind = "agent",
    })
    activity.run = outer
    state.activity = activity
    state.pending_events = {}
    state.last_result = nil
    if not state.destroyed then
      opts.update_context()
    end
    assert(type(open_gate) == "function", "Agent activity gate was not installed")
    open_gate(true)
    return outer
  end

  ---@param prompt string
  ---@return Neoagent.AgentInteractionOptions, Neoagent.ProviderRelease
  local function prepare_submission(prompt)
    opts.require_workspace_trust()
    opts.ensure_session()
    opts.ensure_model()
    local release = opts.acquire_provider()
    assert(type(release) == "function", "provider acquisition must return a release function")
    local prepared, value = pcall(function()
      local toolset = opts.copy_toolset(state.toolset)
      local tools = toolset.tools
      ---@type Neoagent.Model
      local model = assert(selection:model())
      local thinking_level = selection:thinking_level()
      ---@type Neoagent.AgentInteractionOptions
      local base = {
        session = state.session,
        prompt = prompt,
        model = model,
        system_prompt = opts.system_prompt(prompt, tools),
        tools = tools,
        workspace = state.workspace,
        context = {
          files = state.session:files(),
          workspace = state.workspace,
          agent = config.name,
          session_id = state.session_id,
        },
        execute_tool = toolset.execute_tool,
        thinking_level = thinking_level,
        session_state = selection:snapshot({ persisted = true }),
        report = opts.notify,
        model_options = {
          thinking_level = thinking_level,
          files = state.session:files(),
          file_cache = state.session:file_cache(),
        },
      }
      base.get_steering_messages = function()
        local message, settle = state.steering:offer()
        if not message then
          return {}
        end
        local owner = base.activity
        local function acknowledge(committed, observation)
          local selected = assert(assert(settle)(committed == true))
          ---@cast selected Neoagent.SteeringRecord
          opts.update_context()
          if committed and owner then
            local entry_id = type(observation) == "table"
                and type(observation._neoagent_entry_id) == "string"
                and observation._neoagent_entry_id ~= ""
                and observation._neoagent_entry_id
              or nil
            publish_submission(owner, selected.id, selected.message.content, entry_id)
          end
          return true
        end
        return { util.copy(message.message) }, acknowledge
      end
      ---@async
      base.prepare_request_messages = function(_, model_options)
        local parent = assert(async.current(), "request preparation requires an active Run")
        local owner = assert(base.activity)
        local prepared_context, messages, prepare_err = pcall(prepare_context, parent, owner, {
          system_prompt = model_options.system_prompt,
          tools = model_options.tools or {},
          model_options = model_options,
        })
        if not prepared_context or not messages then
          local err = util.normalize_error(prepared_context and prepare_err or messages, "model")
          if err.kind == "compaction" then
            err.operation = "compaction"
          end
          return nil, err
        end
        return messages,
          nil,
          function()
            if owner.length_continuation then
              owner.last_length_epoch = owner.compaction_epoch or 0
              owner.length_continuation = nil
            end
          end
      end
      local closed, close_err = close_unmatched_calls()
      if not closed then
        error(close_err, 0)
      end
      return base
    end)
    if not prepared then
      pcall(release)
      error(value, 0)
    end
    return value, release
  end

  ---@param prompt string
  ---@param steering_claim Neoagent.SteeringClaim?
  ---@param submission_id integer?
  ---@return Neoagent.AgentRun?, Neoagent.Error?
  submit = function(prompt, steering_claim, submission_id)
    local owned_claim = steering_claim
    local function rollback_claim()
      if not owned_claim then
        return false
      end
      local restored = owned_claim:rollback()
      owned_claim = nil
      if restored and not state.destroyed then
        opts.update_context()
      end
      return restored
    end
    if type(prompt) ~= "string" or util.trim(prompt) == "" then
      rollback_claim()
      return nil
    end
    local prepared, base, release = pcall(prepare_submission, prompt)
    if not prepared then
      rollback_claim()
      local err = util.normalize_error(base, "session")
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    local outer = install_activity("interaction", release, function(run, activity)
      base.on_accept = function(entry)
        accepted(activity, prompt, entry)
      end
      return interaction_pipeline(run, activity, base)
    end, {
      steering_claim = owned_claim,
      submission_id = submission_id,
      base = base,
    })
    owned_claim = nil
    return outer
  end

  ---@param text string
  ---@return Neoagent.AgentRun|true|nil, Neoagent.Error?, integer?, ("turn"|"steering")?
  function lifecycle.send(text)
    if state.destroyed then
      return nil, util.error("agent", "Agent is destroyed")
    end
    if state.activity then
      return lifecycle.steer(text)
    end
    local submission_id = next_submission_id()
    local run, err = submit(text, nil, submission_id)
    return run, err, run and submission_id or nil, "turn"
  end

  ---@param text string
  ---@return true?, Neoagent.Error?, integer?, "steering"?
  function lifecycle.steer(text)
    if state.destroyed then
      return nil, util.error("agent", "Agent is destroyed")
    end
    if not state.activity then
      opts.notify("cannot steer while the agent is idle", vim.log.levels.WARN)
      return nil
    end
    local submission_id = state.next_submission_id + 1
    local record, err = state.steering:enqueue(submission_id, text, util.now_ms())
    if not record then
      return nil, err
    end
    state.next_submission_id = submission_id
    opts.update_context()
    return true, nil, submission_id, "steering"
  end

  ---@param submission_id integer
  ---@return Neoagent.AgentRun?, Neoagent.Error?, integer?, "turn"?
  function lifecycle.resubmit_steering(submission_id)
    if state.destroyed then
      return nil, util.error("agent", "Agent is destroyed")
    end
    if state.activity then
      return nil, util.error("steering", "The Agent is busy")
    end
    local claim, err = state.steering:claim(submission_id)
    if not claim then
      return nil, err
    end
    opts.update_context()
    local run, submit_err = submit(claim.record.message.content, claim, claim.record.id)
    return run, submit_err, run and claim.record.id or nil, "turn"
  end

  ---@return string[], integer[]
  function lifecycle.dequeue_steering()
    local records = state.steering:dequeue_all()
    local messages, ids = {}, {}
    for _, record in ipairs(records) do
      messages[#messages + 1] = record.message.content
      ids[#ids + 1] = record.id
    end
    opts.update_context()
    return messages, ids
  end

  ---@param instructions string?
  ---@return Neoagent.AgentRun?, Neoagent.Error?
  function lifecycle.compact(instructions)
    if state.destroyed then
      return nil, util.error("agent", "Agent is destroyed")
    end
    if state.activity then
      opts.notify("cannot compact while the agent is running", vim.log.levels.WARN)
      return nil
    end
    if config.compaction == false then
      opts.notify("compaction is disabled")
      return nil
    end
    local ensured, ensure_err = pcall(opts.ensure_model)
    if not ensured then
      local err = util.normalize_error(ensure_err, "compaction")
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    local acquired, release = pcall(opts.acquire_provider)
    if not acquired then
      local err = util.normalize_error(release, "provider")
      opts.notify(err.message, vim.log.levels.WARN)
      return nil, err
    end
    local outer = install_activity("manual_compaction", release, function(run, activity)
      local request = compaction_request(opts.system_prompt("", state.toolset.tools), state.toolset.tools)
      local result, err = run_compaction(run, activity, request, "manual", instructions)
      return result or failed_result(err or util.error("compaction", "Nothing to compact"), "compaction")
    end)
    return outer
  end

  ---@return boolean
  function lifecycle.stop()
    local activity = state.activity
    if not activity or activity.finalized then
      return false
    end
    activity.phase = "stopping"
    if not state.destroyed then
      opts.update_context()
    end
    assert(activity.run):cancel()
    return true
  end

  return lifecycle
end

return M
