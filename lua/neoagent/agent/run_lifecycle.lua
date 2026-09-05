local agent_loop = require("neoagent.agent_loop")
local async = require("neoagent.async")
local context_metrics = require("neoagent.agent.context")
local semantic_message = require("neoagent.semantic_message")
local util = require("neoagent.util")

local M = {}

local non_retryable_error_patterns = {
  "insufficient_quota", "quota exceeded", "usage limit", "usage_limit",
  "available balance", "out of budget", "billing",
}

local retryable_error_patterns = {
  "overloaded", "rate limit", "rate_limit", "too many requests",
  "service unavailable", "server error", "internal error",
  "provider returned error", "network error", "connection error",
  "connection refused", "connection lost", "connection reset",
  "other side closed", "fetch failed", "getaddrinfo", "enotfound",
  "eai_again", "upstream connect", "reset before headers",
  "socket hang up", "socket connection was closed", "timed out", "timeout",
  "terminated", "websocket closed", "websocket error", "transfer closed",
  "empty reply from server", "broken pipe", "failure when receiving data",
  "unexpected eof", "premature close", "ended without",
  "stream ended before", "request did not get a response",
  "you can retry your request", "try your request again",
  "please retry your request", "resourceexhausted",
}

local retryable_status = {
  [408] = true, [409] = true, [429] = true, [500] = true, [502] = true,
  [503] = true, [504] = true, [524] = true,
}

local PROMPT_STATS_DELAY_MS = 2000
local COMPLETION_ERROR_CHARACTERS = 512
local COMPLETION_DETAIL_CHARACTERS = 1024

local function bounded_text(value, maximum)
  if type(value) ~= "string" then
    local ok, rendered = pcall(tostring, value)
    value = ok and rendered or "unprintable value"
  end
  value = util.text_from_bytes(value)
  if vim.fn.strchars(value) <= maximum then return value end
  return vim.fn.strcharpart(value, 0, maximum) .. "…"
end

local function completion_error(value)
  if value == nil then return nil end
  local source = util.normalize_error(value, "agent")
  local result = {
    kind = bounded_text(source.kind, 64),
    message = bounded_text(source.message, COMPLETION_ERROR_CHARACTERS),
  }
  local detail = source.detail
  if type(detail) == "table" and type(detail.message) == "string" then
    detail = detail.message
  end
  if type(detail) == "string" or type(detail) == "number"
      or type(detail) == "boolean" then
    result.detail = bounded_text(detail, COMPLETION_DETAIL_CHARACTERS)
  end
  for _, field in ipairs({ "code", "status", "retry_after_ms" }) do
    local selected = source[field]
    if type(selected) == "number" and selected == selected
        and selected ~= math.huge and selected ~= -math.huge then
      result[field] = selected
    elseif type(selected) == "string" then
      result[field] = bounded_text(selected, 128)
    end
  end
  if type(source.retryable) == "boolean" then
    result.retryable = source.retryable
  end
  return result
end

local function completion_usage(value)
  if type(value) ~= "table" then return nil end
  local result = {}
  for _, field in ipairs({
    "input", "output", "reasoning", "cacheRead", "cacheWrite",
    "totalTokens",
  }) do
    local selected = value[field]
    if type(selected) == "number" and selected == selected
        and selected >= 0 and selected ~= math.huge then
      result[field] = selected
    end
  end
  return next(result) and result or nil
end

local function completion_value(done)
  if type(done) ~= "table" then
    done = {
      ok = false,
      error = util.error("agent", "Activity returned an invalid result"),
    }
  end
  local failure = completion_error(done.error)
  local message = type(done.message) == "table" and done.message or nil
  local ok = done.ok == true
  local result = {
    ok = ok,
    status = ok and "succeeded"
      or failure and failure.kind == "cancelled" and "cancelled"
      or "failed",
    message_count = type(done.new_messages) == "table"
        and #done.new_messages or 0,
  }
  if failure then result.error = failure end
  if message and type(message.stopReason) == "string" then
    result.stop_reason = bounded_text(message.stopReason, 128)
  end
  local usage = completion_usage(done.usage or message and message.usage)
  if usage then result.usage = usage end
  return result
end

local function inference_rate(value)
  if type(value) ~= "number" or value <= 0 or value ~= value
      or value == math.huge then
    return nil
  end
  return value
end

local function apply_inference_stats(state, event)
  local prompt = inference_rate(event.prompt_tokens_per_second)
  local generation = inference_rate(event.generation_tokens_per_second)
  if prompt and (type(event.elapsed_ms) ~= "number"
      or event.elapsed_ms < PROMPT_STATS_DELAY_MS) then
    prompt = nil
  end
  if not prompt and not generation then return nil end
  state.inference_stats = generation and {
    generation_tokens_per_second = generation,
  } or {
    prompt_tokens_per_second = prompt,
  }
  return state.inference_stats
end

local function publish_inference_stats(state, event, update)
  local stats = apply_inference_stats(state, event)
  if stats then update() end
end

local function retain_completed_inference_stats(state)
  local stats = state.inference_stats
  if type(stats) == "table"
      and not inference_rate(stats.generation_tokens_per_second) then
    state.inference_stats = nil
  end
end

local function error_text(err)
  local parts = { type(err.message) == "string" and err.message or "" }
  if err.detail ~= nil then
    local ok, encoded = pcall(vim.json.encode, err.detail)
    parts[#parts + 1] = ok and encoded or tostring(err.detail)
  end
  return table.concat(parts, " "):lower()
end

local function has_pattern(text, patterns)
  for _, pattern in ipairs(patterns) do
    if text:find(pattern, 1, true) then return true end
  end
  return false
end

local function is_retryable_error(err)
  if type(err) ~= "table" or err.kind == "cancelled" then return false end
  if type(err.retryable) == "boolean" then return err.retryable end
  local text = error_text(err)
  if has_pattern(text, non_retryable_error_patterns) then return false end
  if has_pattern(text, retryable_error_patterns) then return true end
  local response = type(err.response) == "table" and err.response or {}
  local status = tonumber(err.status) or tonumber(response.status)
    or tonumber(text:match("http%s+(%d%d%d)"))
  if status and status >= 400 then return retryable_status[status] == true end
  if err.kind == "transport" then return true end
  return false
end

local function retry_delay(milliseconds)
  return async.await(function(done)
    local timer = vim.uv.new_timer()
    if not timer then
      done.reject(util.error("agent", "Failed to create retry timer"))
      return
    end
    timer:start(math.max(1, milliseconds), 0, function()
      timer:stop()
      if not timer:is_closing() then timer:close() end
      done.resolve(true)
    end)
    return function()
      timer:stop()
      if not timer:is_closing() then timer:close() end
    end
  end)
end

local function is_context_overflow(result)
  if not result or result.ok or not result.error then return false end
  local parts = { result.error.message or "" }
  if result.error.detail ~= nil then
    local ok, encoded = pcall(vim.json.encode, result.error.detail)
    parts[#parts + 1] = ok and encoded or tostring(result.error.detail)
  end
  local text = table.concat(parts, " "):lower()
  for _, pattern in ipairs({ "rate limit", "too many requests" }) do
    if text:find(pattern, 1, true) then return false end
  end
  for _, pattern in ipairs({
    "context_length_exceeded", "model_context_window_exceeded",
    "request_too_large", "prompt is too long", "prompt too long",
    "input is too long for requested model", "exceeds the context window",
    "maximum context length", "maximum prompt length",
    "reduce the length of the messages", "maximum allowed input length",
    "longer than the model's context length",
    "exceeds the available context size", "greater than the context length",
    "context window exceeds limit", "exceeded model token limit",
    "token limit exceeded", "too many tokens", "too large for model",
    "configured context size", "range of input length should be",
    "request too large",
  }) do
    if text:find(pattern, 1, true) then return true end
  end
  return false
end

local function is_length_limited(result)
  return result and result.ok and result.message
    and result.message.stopReason == "length"
end

local function cancelled_result()
  return { ok = false, error = util.copy(async.cancelled_error) }
end

local function failed_result(err, kind)
  return { ok = false, error = util.normalize_error(err, kind or "agent") }
end

local function completion_failure(err)
  local cause = util.normalize_error(err, "agent")
  return {
    ok = false,
    error = util.error("agent", "Agent completion failed", cause.message),
  }
end

local function operation_result(value, label)
  if type(value) ~= "table" or type(value.ok) ~= "boolean" then
    return failed_result(
      util.error("agent", label .. " returned an invalid result"))
  end
  return value
end

local function inspect_run(run, label)
  if type(run) ~= "table" or type(run.cancel) ~= "function"
      or type(run.is_done) ~= "function"
      or type(run.result) ~= "function" then
    return nil, util.error("agent", label .. " must return a Run")
  end
  local checked, done = pcall(run.is_done, run)
  if not checked then return nil, util.normalize_error(done, "agent") end
  if not done then
    if type(run.await) ~= "function" then
      return nil, util.error("agent", label .. " must return a Run")
    end
    return { run = run, completed = false }
  end
  local read, result = pcall(run.result, run)
  if not read then return nil, util.normalize_error(result, "agent") end
  return {
    run = run,
    completed = true,
    result = operation_result(result, label),
  }
end

local function default_interaction(options)
  return require("neoagent.chat").run(options.session, options.prompt, {
    model = options.model,
    system_prompt = options.system_prompt,
    tools = options.tools,
    context = options.context,
    execute_tool = options.execute_tool,
    get_steering_messages = options.get_steering_messages,
    session_state = options.session_state,
    on_accept = options.on_accept,
    report = options.report,
    model_options = options.model_options,
    on_event = options.on_event,
    on_done = options.on_done,
  })
end

local function default_continuation(options)
  return require("neoagent.chat").continue(options.session, {
    model = options.model,
    system_prompt = options.system_prompt,
    tools = options.tools,
    context = options.context,
    execute_tool = options.execute_tool,
    get_steering_messages = options.get_steering_messages,
    model_options = options.model_options,
    report = options.report,
    on_event = options.on_event,
    on_done = options.on_done,
  })
end

function M.new(opts)
  local state = opts.state
  local config = opts.config
  local selection = state.request_selection
  local lifecycle = {}
  local submit
  local schedule_steering

  local function next_submission_id()
    state.next_submission_id = state.next_submission_id + 1
    return state.next_submission_id
  end

  local function report_callback(diagnostic)
    opts.notify("callback failed during " .. diagnostic.phase .. ": "
      .. diagnostic.message, vim.log.levels.ERROR)
  end

  local function current(activity)
    return state.activity == activity and not activity.finalized
  end

  local function set_phase(activity, phase)
    if not current(activity) then return false end
    activity.phase = phase
    if not state.destroyed then opts.update_context() end
    return true
  end

  local function release_provider(activity)
    local release = activity.provider_lease
    activity.provider_lease = nil
    if not release then return false end
    local called, released, release_err = pcall(release)
    if not called or released == nil or released == false then
      local err = called and release_err or released
      pcall(opts.notify, "failed to release provider use: "
        .. util.normalize_error(err, "provider").message,
        vim.log.levels.ERROR)
    end
    return true
  end

  local function destroy_runtimes_if_ready()
    if not state.destroyed or state.activity ~= nil then return false end
    local destroy = state.destroy_runtimes
    state.destroy_runtimes = nil
    if destroy then pcall(destroy) end
    return destroy ~= nil
  end

  local function close_unmatched_calls()
    if state.destroyed then return nil, util.error("agent", "Agent is destroyed") end
    local messages = state.session:messages()
    local pending = {}
    local order = {}
    for _, message in ipairs(messages) do
      if message.role == "assistant" then
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
          content = { { type = "text", text =
            "Tool execution was interrupted; side effects may already have occurred." } },
          isError = true,
          timestamp = util.now_ms(),
        })
        if not ok then return nil, err end
      end
    end
    return true
  end

  local function compaction_settings()
    local selected = config.compaction
    local model = selection:model()
    if selected == false or not model then return nil end
    return require("neoagent.compaction").settings(
      selected, model.context_window)
  end

  local function needs_compaction()
    local settings = compaction_settings()
    if not settings or not settings.auto or not state.session then return false end
    local messages = state.session:context_messages()
    if not messages then return false end
    local estimate = require("neoagent.compaction").estimate_context(messages)
    return require("neoagent.compaction").should_compact(
      estimate.tokens, selection:model().context_window or 0, settings)
  end

  local function prepare_compaction()
    local settings = compaction_settings()
    if not settings or not state.session then return nil end
    local closed, close_err = close_unmatched_calls()
    if not closed then return nil, close_err end
    local path, path_err = state.session:path()
    if not path then return nil, path_err end
    return require("neoagent.compaction").prepare(path, settings)
  end

  local function publish_submission(
      activity, submission_id, prompt, entry_id)
    if not current(activity) or state.destroyed then return false end
    if type(submission_id) ~= "number" or submission_id < 1
        or submission_id % 1 ~= 0 then
      return false
    end
    local message = semantic_message.normalize({
      role = "user",
      content = prompt,
    })
    if not message or util.trim(message.content) == "" then return false end
    if type(entry_id) ~= "string" or entry_id == "" or #entry_id > 512
        or not util.is_valid_utf8(entry_id)
        or entry_id:find("[%z\1-\31\127]") then
      entry_id = nil
    end
    local record = {
      type = "submission_accepted",
      submission_id = submission_id,
      prompt = message.content,
      entry_id = entry_id,
    }
    opts.publish(record)
    return true
  end

  local function handle_event(activity, event)
    if not current(activity) or state.destroyed then return false end
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
      publish_inference_stats(state, event, opts.update_context)
    elseif event.type == "message_end" then
      opts.sync_tools()
      opts.update_context()
    end
    if event.type == "message_end" then
      state.pending_events = {}
    elseif event.type ~= "usage" and event.type ~= "provider_status"
        and event.type ~= "inference_stats" then
      state.pending_events[#state.pending_events + 1] = util.copy(event)
    end
    if type(opts.provider_event) == "function" then
      opts.provider_event(event)
    end
    opts.publish({ type = "event", event = event })
    if event.type == "tool_end" and not event.message.isError then
      local details = type(event.message.details) == "table"
          and event.message.details or {}
      local changed_paths = details.changed_paths
      if type(changed_paths) == "table" and util.is_list(changed_paths) then
        for _, path in ipairs(changed_paths) do
          if type(path) == "string" and path ~= "" then
            opts.refresh_buffer(path)
          end
        end
      end
    end
    return true
  end

  local function await_operation(
      outer, activity, factory, call, label, installed)
    local buffered = {}
    local active = false
    local finished = false
    call.on_event = function(event)
      if finished then return end
      if not active then
        buffered[#buffered + 1] = util.copy(event)
      else
        handle_event(activity, event)
      end
    end
    call.on_done = function() end

    local started, child = pcall(factory, call)
    if not started then
      finished = true
      return failed_result(child, "agent")
    end
    local inspected, inspect_err = inspect_run(child, label)
    if not inspected then
      finished = true
      return failed_result(inspect_err, "agent")
    end
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
      if not current(activity) then break end
      handle_event(activity, event)
    end
    buffered = {}
    if outer:is_cancelled() then
      pcall(child.cancel, child)
      finished = true
      return cancelled_result()
    end
    if inspected.completed then
      finished = true
      return inspected.result
    end

    local awaited, result = pcall(child.await, child)
    finished = true
    if outer:is_cancelled() then return cancelled_result() end
    if not awaited then return failed_result(result, "agent") end
    local final, final_err = inspect_run(child, label)
    if not final then return failed_result(final_err, "agent") end
    if final.completed then result = final.result end
    return operation_result(result, label)
  end

  local function publish_compaction(activity, reason, result)
    if not current(activity) or state.destroyed then return end
    opts.publish({ type = "event", event = {
      type = "compaction_end",
      reason = reason,
      result = result,
    } })
  end

  local function run_compaction(
      outer, activity, reason, instructions, preparation)
    local prepare_err
    if not preparation then preparation, prepare_err = prepare_compaction() end
    if not preparation then return nil, prepare_err, false end
    set_phase(activity, "compacting")
    state.pending_events = {}
    state.inference_stats = nil
    if current(activity) and not state.destroyed then
      opts.publish({ type = "event", event = {
        type = "compaction_start", reason = reason,
      } })
      opts.update_context()
    end
    local selected = opts.compaction_run or require("neoagent.compaction").run
    local result = await_operation(outer, activity, selected, {
      preparation = preparation,
      model = selection:model(),
      model_options = {
        request_opts = require("neoagent.thinking").request_opts(
          selection:model(), selection:thinking_level()),
      },
      instructions = instructions,
      reason = reason,
      session = state.session,
      report = report_callback,
    }, "compaction Run")

    if result.ok then
      local appended, append_err = state.session:append_compaction({
        summary = result.summary,
        firstKeptEntryId = result.first_kept_entry_id,
        tokensBefore = result.tokens_before,
      })
      if not appended then result = failed_result(append_err, "compaction") end
    end
    if result.ok then
      local projected, projection_err = state.session:context_messages()
      if projected then
        result.estimated_tokens_after = context_metrics.tokens(
          state.session, projected)
        if current(activity) and not state.destroyed then
          opts.publish_messages(opts.transcript_messages(state.session))
        end
      else
        result = failed_result(projection_err, "compaction")
      end
    end
    state.live_usage = nil
    retain_completed_inference_stats(state)
    publish_compaction(activity, reason, result)
    return result, nil, true
  end

  local function provider_result_event(result)
    if type(opts.provider_event) ~= "function"
        or type(result.error) ~= "table"
        or (type(result.error.provider_status) ~= "string"
          and type(result.error.provider_status_details) ~= "table") then
      return
    end
    opts.provider_event({
      type = "provider_status",
      text = result.error.provider_status,
      details = util.copy(result.error.provider_status_details),
    })
  end

  local function run_interaction(
      outer, activity, base, continuing, retry_attempt)
    set_phase(activity, "running")
    state.inference_stats = nil
    local call = vim.tbl_extend("force", {}, base)
    call.model_options = util.copy(base.model_options)
    call.model_options.retry_attempt = retry_attempt
    local selected = continuing and default_continuation
      or (opts.interaction or default_interaction)
    local result = await_operation(
      outer, activity, selected, call, "interaction Run", function()
        if not current(activity) or state.destroyed then return end
        state.pending_events = {}
        opts.publish_messages(opts.transcript_messages(state.session))
        opts.update_context()
      end)
    if current(activity) and not state.destroyed then provider_result_event(result) end
    return result
  end

  local function abandon_failed_message()
    local path, path_err = state.session:path()
    if not path then return nil, path_err end
    local last = path[#path]
    if last and last.type == "message" and last.message.role == "assistant"
        and last.message.stopReason == "error" then
      local parent = last.parentId == vim.NIL and nil or last.parentId
      local moved, move_err = state.session:move_to(parent)
      if not moved then return nil, move_err end
      if not state.destroyed then
        opts.publish_messages(opts.transcript_messages(state.session))
      end
    end
    return true
  end

  local function accepted(activity, prompt, entry)
    if activity.accepted then return true end
    activity.accepted = true
    if activity.steering_claim then
      activity.steering_claim:commit()
      activity.steering_claim = nil
    end
    publish_submission(activity, activity.submission_id, prompt,
      type(entry) == "table" and entry.id or nil)
    local called, committed, commit_err = pcall(opts.commit_model_preference)
    if not called then
      commit_err = util.normalize_error(committed, "storage")
      committed = nil
    end
    if not committed then
      opts.notify(
        "the message was accepted but the workspace model preference was not saved: "
          .. util.normalize_error(commit_err, "storage").message,
        vim.log.levels.WARN)
    end
    return committed, commit_err
  end

  local function interaction_pipeline(outer, activity, base)
    local overflow_retried = false
    local length_continued = false
    local stream_retries = 0

    if needs_compaction() then
      local compacted, _, started = run_compaction(
        outer, activity, "threshold")
      if started and not compacted.ok then return compacted end
    end
    if outer:is_cancelled() then return cancelled_result() end
    local done = run_interaction(outer, activity, base, false, stream_retries)

    while true do
      if outer:is_cancelled() then return cancelled_result() end
      if not overflow_retried and is_context_overflow(done) then
        overflow_retried = true
        local abandoned, abandon_err = abandon_failed_message()
        if not abandoned then return completion_failure(abandon_err) end
        local compacted, _, started = run_compaction(
          outer, activity, "overflow")
        if started and not compacted.ok then
          if compacted.error and compacted.error.kind == "cancelled" then
            return compacted
          end
          return done
        end
        done = run_interaction(
          outer, activity, base, true, stream_retries)
      elseif not length_continued and is_length_limited(done) then
        length_continued = true
        if needs_compaction() then
          local compacted, _, started = run_compaction(
            outer, activity, "threshold")
          if started and not compacted.ok then
            if compacted.error and compacted.error.kind == "cancelled" then
              return compacted
            end
            return done
          end
        end
        done = run_interaction(
          outer, activity, base, true, stream_retries)
      else
        local retry_settings = config.retry
        local retry_limit = retry_settings.enabled and retry_settings.max_retries or 0
        local provider_limit = done.error and tonumber(
          done.error.stream_max_retries)
        if provider_limit then
          retry_limit = math.min(retry_limit, provider_limit)
        end
        if done.error and is_retryable_error(done.error)
            and stream_retries < retry_limit then
          stream_retries = stream_retries + 1
          local abandoned, abandon_err = abandon_failed_message()
          if not abandoned then return completion_failure(abandon_err) end
          state.pending_events = {}
          state.live_usage = nil
          state.inference_stats = nil
          local wait = tonumber(done.error.retry_after_ms)
            or retry_settings.base_delay_ms * (2 ^ (stream_retries - 1))
          wait = math.max(0, math.min(60000, wait))
          state.provider_status = string.format(
            "Reconnecting… %d/%d", stream_retries, retry_limit)
          set_phase(activity, "retrying")
          local waited, wait_err = pcall(retry_delay, wait)
          state.provider_status = nil
          if outer:is_cancelled() then return cancelled_result() end
          if not waited then return failed_result(wait_err, "agent") end
          done = run_interaction(
            outer, activity, base, true, stream_retries)
        else
          if needs_compaction() then
            local compacted, _, started = run_compaction(
              outer, activity, "threshold")
            if started and not compacted.ok and compacted.error
                and compacted.error.kind == "cancelled" then
              return compacted
            end
          end
          return done
        end
      end
    end
  end

  schedule_steering = function()
    if state.destroyed or state.activity ~= nil
        or state.steering:count() == 0 then
      return
    end
    local message = state.steering:first()
    vim.schedule(function()
      local head = state.steering:first()
      if state.destroyed or state.activity ~= nil
          or not head or head.id ~= message.id then return end
      local claim = state.steering:claim(message.id)
      if not claim then return end
      opts.update_context()
      submit(message.message.content, claim, message.id)
    end)
  end

  local function finalize(activity, result)
    if activity.finalized then return false end
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
      if restored and not state.destroyed then opts.update_context() end
    end
    if owned then
      state.live_usage = nil
      state.provider_status = nil
      retain_completed_inference_stats(state)
      state.last_result = completion
      if not state.destroyed then
        local published, publish_err = pcall(function()
          opts.update_context()
          opts.publish({ type = "finish", result = completion })
        end)
        if not published then
          pcall(opts.notify, "failed to publish Agent completion: "
            .. util.normalize_error(publish_err, "agent").message,
            vim.log.levels.ERROR)
        end
      end
    end
    release_provider(activity)
    if state.activity == activity then state.activity = nil end
    destroy_runtimes_if_ready()
    if owned and not state.destroyed and completion.ok and activity.accepted then
      schedule_steering()
    end
    return true
  end

  local function install_activity(kind, release, pipeline, activity_values)
    state.run_id = state.run_id + 1
    local activity = {
      id = state.run_id,
      kind = kind,
      phase = "preparing",
      accepted = false,
      provider_lease = release,
      finalized = false,
    }
    for key, value in pairs(activity_values or {}) do activity[key] = value end
    if activity.base then
      activity.base.activity = activity
      activity.base = nil
    end
    local open_gate
    local outer = async.run(function(run)
      local opened, gate_err = pcall(async.await, function(done)
        open_gate = done.resolve
        return function() end
      end)
      local result
      if not opened or run:is_cancelled() then
        result = run:is_cancelled()
            and cancelled_result() or failed_result(gate_err, "agent")
      else
        local completed
        completed, result = pcall(pipeline, run, activity)
        if not completed then result = failed_result(result, "agent") end
      end
      finalize(activity, result)
      return result
    end, {
      on_done = function(result) finalize(activity, result) end,
      report = report_callback,
      error_kind = "agent",
    })
    activity.run = outer
    state.activity = activity
    state.pending_events = {}
    state.last_result = nil
    if not state.destroyed then opts.update_context() end
    assert(type(open_gate) == "function", "Agent activity gate was not installed")
    open_gate(true)
    return outer
  end

  local function prepare_submission(prompt)
    opts.require_workspace_trust()
    opts.ensure_session()
    opts.ensure_model()
    local release = opts.acquire_provider()
    assert(type(release) == "function",
      "provider acquisition must return a release function")
    local prepared, value = pcall(function()
      local toolset = opts.copy_toolset(state.toolset)
      local tools = toolset.tools
      local model = selection:model()
      local thinking_level = selection:thinking_level()
      local request_opts = require("neoagent.thinking").request_opts(
        model, thinking_level)
      local base = {
        session = state.session,
        prompt = prompt,
        model = model,
        system_prompt = opts.system_prompt(prompt, tools),
        tools = tools,
        workspace = state.workspace,
        context = {
          workspace = state.workspace,
          agent = config.name,
          session_id = state.session_id,
        },
        execute_tool = toolset.execute_tool,
        thinking_level = thinking_level,
        session_state = selection:snapshot({ persisted = true }),
        report = opts.notify,
        model_options = { request_opts = request_opts },
      }
      base.get_steering_messages = function()
        local message, settle = state.steering:offer()
        if not message then return {} end
        local owner = base.activity
        local function acknowledge(committed, observation)
          local selected = settle(committed == true)
          if not selected then return false end
          opts.update_context()
          if committed and owner then
            local entry_id = type(observation) == "table"
                and type(observation._neoagent_entry_id) == "string"
                and observation._neoagent_entry_id ~= ""
                and observation._neoagent_entry_id or nil
            publish_submission(owner, selected.id,
              selected.message.content, entry_id)
          end
          return true
        end
        return { util.copy(message.message) }, acknowledge
      end
      agent_loop.prepare({
        model = base.model,
        messages = {},
        system_prompt = base.system_prompt,
        tools = base.tools,
        model_options = base.model_options,
        context = base.context,
        execute_tool = base.execute_tool,
        get_steering_messages = base.get_steering_messages,
        commit_message = function() return true end,
      })
      local closed, close_err = close_unmatched_calls()
      if not closed then error(close_err, 0) end
      return base
    end)
    if not prepared then
      pcall(release)
      error(value, 0)
    end
    return value, release
  end

  submit = function(prompt, steering_claim, submission_id)
    local owned_claim = steering_claim
    local function rollback_claim()
      if not owned_claim then return false end
      local restored = owned_claim:rollback()
      owned_claim = nil
      if restored and not state.destroyed then opts.update_context() end
      return restored
    end
    if state.destroyed then
      rollback_claim()
      return nil, util.error("agent", "Agent is destroyed")
    end
    if type(prompt) ~= "string" or util.trim(prompt) == "" then
      rollback_claim()
      return nil
    end
    if state.activity then
      rollback_claim()
      opts.notify("the agent is busy", vim.log.levels.WARN)
      return nil
    end
    local prepared, base, release = pcall(prepare_submission, prompt)
    if not prepared then
      rollback_claim()
      local err = util.normalize_error(base, "session")
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    local installed, outer = pcall(install_activity,
      "interaction", release, function(run, activity)
        base.on_accept = function(entry)
          return accepted(activity, prompt, entry)
        end
        return interaction_pipeline(run, activity, base)
      end, {
        steering_claim = owned_claim,
        submission_id = submission_id,
        base = base,
      })
    if not installed then
      pcall(release)
      rollback_claim()
      local err = util.normalize_error(outer, "agent")
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    if state.activity and state.activity.run == outer then
      owned_claim = nil
    else
      rollback_claim()
      pcall(outer.cancel, outer)
      return nil, util.error("agent", "Agent activity installation was lost")
    end
    return outer
  end

  function lifecycle.send(text)
    if state.destroyed then return nil, util.error("agent", "Agent is destroyed") end
    if state.activity then return lifecycle.steer(text) end
    local submission_id = next_submission_id()
    local run, err = submit(text, nil, submission_id)
    return run, err, run and submission_id or nil, "turn"
  end

  function lifecycle.steer(text)
    if state.destroyed then return nil, util.error("agent", "Agent is destroyed") end
    if not state.activity then
      opts.notify("cannot steer while the agent is idle", vim.log.levels.WARN)
      return nil
    end
    local submission_id = state.next_submission_id + 1
    local record, err = state.steering:enqueue(
      submission_id, text, util.now_ms())
    if not record then return nil, err end
    state.next_submission_id = submission_id
    opts.update_context()
    return true, nil, submission_id, "steering"
  end

  function lifecycle.resubmit_steering(submission_id)
    if state.destroyed then return nil, util.error("agent", "Agent is destroyed") end
    if state.activity then
      return nil, util.error("steering", "The Agent is busy")
    end
    local claim, err = state.steering:claim(submission_id)
    if not claim then return nil, err end
    opts.update_context()
    local run, submit_err = submit(
      claim.record.message.content, claim, claim.record.id)
    return run, submit_err, run and claim.record.id or nil, "turn"
  end

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

  function lifecycle.compact(instructions)
    if state.destroyed then return nil, util.error("agent", "Agent is destroyed") end
    if state.activity then
      opts.notify("cannot compact while the agent is running", vim.log.levels.WARN)
      return nil
    end
    if config.compaction == false then
      opts.notify("compaction is disabled")
      return nil
    end
    if not state.session then opts.notify("no active session") return nil end
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
    local preparation, prepare_err = prepare_compaction()
    if not preparation then
      pcall(release)
      local err = prepare_err or util.error(
        "compaction", "Nothing to compact")
      opts.notify(err.message, vim.log.levels.WARN)
      return nil, err
    end
    local installed, outer = pcall(install_activity,
      "manual_compaction", release, function(run, activity)
        local result = run_compaction(
          run, activity, "manual", instructions, preparation)
        return result
      end)
    if not installed then
      pcall(release)
      local err = util.normalize_error(outer, "compaction")
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    return outer
  end

  function lifecycle.stop()
    local activity = state.activity
    if not activity or activity.finalized then return false end
    activity.phase = "stopping"
    if not state.destroyed then opts.update_context() end
    activity.run:cancel()
    return true
  end

  return lifecycle
end

return M
