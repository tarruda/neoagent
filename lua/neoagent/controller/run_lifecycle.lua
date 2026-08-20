local context_metrics = require("neoagent.controller.context")
local util = require("neoagent.util")

local M = {}

local non_retryable_error_patterns = {
  "insufficient_quota", "quota exceeded", "usage limit", "usage_limit",
  "available balance", "out of budget", "billing",
}

local retryable_error_patterns = {
  "overloaded", "rate limit", "rate_limit", "too many requests",
  "service unavailable", "server error", "internal error", "provider returned error",
  "network error", "connection error", "connection refused", "connection lost",
  "connection reset", "other side closed", "fetch failed", "getaddrinfo",
  "enotfound", "eai_again", "upstream connect", "reset before headers",
  "socket hang up", "socket connection was closed", "timed out", "timeout",
  "terminated", "websocket closed", "websocket error", "transfer closed",
  "empty reply from server", "broken pipe", "failure when receiving data",
  "unexpected eof", "premature close", "ended without", "stream ended before",
  "request did not get a response", "you can retry your request",
  "try your request again", "please retry your request", "resourceexhausted",
}

local retryable_status = {
  [408] = true, [409] = true, [429] = true, [500] = true, [502] = true,
  [503] = true, [504] = true, [524] = true,
}

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
  local response = type(err.response) == "table" and err.response or {}
  local status = tonumber(err.status) or tonumber(response.status)
    or tonumber(text:match("http%s+(%d%d%d)"))
  if status and status >= 400 then return retryable_status[status] == true end
  if err.kind == "transport" then return true end
  return has_pattern(text, retryable_error_patterns)
end

local function retry_delay(milliseconds)
  return require("neoagent.async").await(function(done)
    local timer = vim.uv.new_timer()
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

local function default_interaction(options)
  return require("neoagent.chat").run(options.session, options.prompt, {
    model = options.model,
    system_prompt = options.system_prompt,
    tools = options.tools,
    context = options.context,
    execute_tool = options.execute_tool,
    get_steering_messages = options.get_steering_messages,
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
    on_event = options.on_event,
    on_done = options.on_done,
  })
end

function M.new(opts)
  local state = opts.state
  local config = opts.config
  local lifecycle = {}

  local function release_provider()
    local release = state.provider_usage_release
    state.provider_usage_release = nil
    if release then release() end
  end

  local function close_unmatched_calls()
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
          content = { { type = "text", text = "Tool execution was interrupted; side effects may already have occurred." } },
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
    if selected == false or not state.model then return nil end
    return require("neoagent.compaction").settings(selected, state.model.context_window)
  end

  local function needs_compaction()
    local settings = compaction_settings()
    if not settings or not settings.auto or not state.session then return false end
    local messages = state.session:context_messages()
    if not messages then return false end
    local estimate = require("neoagent.compaction").estimate_context(messages)
    return require("neoagent.compaction").should_compact(
      estimate.tokens, state.model.context_window or 0, settings)
  end

  local submit
  local schedule_steering

  local function start_compaction(reason, instructions, run_id, after)
    local settings = compaction_settings()
    if not settings or not state.session then return nil end
    local path, path_err = state.session:path()
    if not path then return nil, path_err end
    local preparation, prepare_err = require("neoagent.compaction").prepare(path, settings)
    if not preparation then return nil, prepare_err end

    local selected = config.compaction.run or require("neoagent.compaction").run
    local previous_status = state.status
    local previous_run = state.run
    local previous_events = state.pending_events
    state.status = "compacting"
    state.pending_events = {}
    opts.publish({ type = "event", event = { type = "compaction_start", reason = reason } })
    opts.update_context()

    local callbacks = {}
    local active = false
    local discarded = false
    local function on_event(event)
      if discarded then return end
      if not active then
        callbacks[#callbacks + 1] = { kind = "event", value = event }
        return
      end
      if run_id ~= state.run_id then return end
      if event.type == "provider_status" then
        state.provider_status = type(event.text) == "string" and event.text or nil
        opts.update_context()
      end
      opts.publish({ type = "event", event = event })
    end
    local function on_done(done)
      if discarded then return end
      if not active then
        callbacks[#callbacks + 1] = { kind = "done", value = done }
        return
      end
      if run_id ~= state.run_id then return end
      local result = util.copy(done)
      if done.ok then
        local ok, err = state.session:append_entry("compaction", {
          summary = done.summary,
          firstKeptEntryId = done.first_kept_entry_id,
          tokensBefore = done.tokens_before,
          usage = done.usage,
          details = done.details,
          fromHook = selected ~= require("neoagent.compaction").run or nil,
        })
        if not ok then result = { ok = false, error = err } end
      end
      if result.ok then
        local projected = assert(state.session:context_messages())
        result.estimated_tokens_after = context_metrics.tokens(state.session, projected)
        opts.publish_messages(opts.transcript_messages(state.session))
      end
      state.run = nil
      state.status = "idle"
      state.live_usage = nil
      if not after then release_provider() end
      opts.update_context()
      opts.publish({ type = "event", event = {
        type = "compaction_end", reason = reason, result = result,
      } })
      if after then after(result) end
      if result.ok then schedule_steering() end
    end

    local started, run = pcall(selected, {
      preparation = preparation,
      model = state.model,
      model_options = {
        request_opts = require("neoagent.thinking").request_opts(state.model, state.thinking_level),
      },
      instructions = instructions,
      reason = reason,
      session = state.session,
      on_event = on_event,
      on_done = on_done,
    })
    local start_err
    if not started then
      start_err = util.normalize_error(run, "compaction")
    elseif type(run) ~= "table" or type(run.cancel) ~= "function" then
      start_err = util.error("compaction", "compaction.run must return a Run")
    end
    if start_err then
      discarded = true
      callbacks = {}
      state.status = previous_status
      state.run = previous_run
      state.pending_events = previous_events
      opts.update_context()
      opts.publish({ type = "event", event = {
        type = "compaction_end", reason = reason,
        result = { ok = false, error = start_err },
      } })
      return nil, start_err
    end

    state.run = run
    active = true
    local queued_callbacks = callbacks
    callbacks = {}
    for _, callback in ipairs(queued_callbacks) do
      if callback.kind == "event" then on_event(callback.value) else on_done(callback.value) end
    end
    return run
  end

  schedule_steering = function()
    if state.destroyed or state.status ~= "idle" or #state.steering == 0 then return end
    local message = state.steering[1]
    vim.schedule(function()
      if state.destroyed or state.status ~= "idle" or state.steering[1] ~= message then return end
      table.remove(state.steering, 1)
      opts.update_context()
      local run = submit(message.text)
      if not run then
        table.insert(state.steering, 1, message)
        opts.update_context()
      end
    end)
  end

  local function completion_failure(err, original)
    local cause = util.normalize_error(err, "controller")
    return {
      ok = false,
      error = util.error("controller", "Controller completion failed", cause.message),
      new_messages = original and util.copy(original.new_messages) or nil,
      message = original and util.copy(original.message) or nil,
    }
  end

  local function finish_interaction(done)
    release_provider()
    state.run = nil
    state.status = "idle"
    state.live_usage = nil
    state.last_result = util.copy(done)
    opts.update_context()
    opts.publish({ type = "finish", result = done })
    if done.ok then schedule_steering() end
  end

  submit = function(prompt)
    if util.trim(prompt) == "" then return nil end
    if state.status ~= "idle" then opts.notify("the agent is busy", vim.log.levels.WARN) return nil end
    local ok, result = pcall(function()
      opts.require_workspace_trust()
      opts.ensure_session()
      opts.ensure_model()
      state.provider_usage_release = opts.acquire_provider()
      local closed, close_err = close_unmatched_calls()
      if not closed then error(close_err, 0) end
      local toolset = opts.copy_toolset(state.toolset)
      local tools = toolset.tools
      local run_id = state.run_id + 1
      state.run_id = run_id
      state.pending_events = {}
      state.last_result = nil
      local overflow_retried = false
      local length_continued = false
      local stream_retries = 0
      local base = {
        session = state.session,
        prompt = prompt,
        model = state.model,
        system_prompt = opts.system_prompt(prompt, tools),
        tools = tools,
        workspace = state.workspace,
        context = {
          workspace = state.workspace,
          controller = config.name,
          session_id = state.session_id,
        },
        execute_tool = toolset.execute_tool,
        get_steering_messages = function()
          if #state.steering == 0 then return {} end
          local message = table.remove(state.steering, 1)
          opts.update_context()
          return { {
            role = "user",
            content = message.text,
            timestamp = message.timestamp,
          } }
        end,
        thinking_level = state.thinking_level,
        model_options = {
          request_opts = require("neoagent.thinking").request_opts(state.model, state.thinking_level),
        },
      }
      local function on_event(event)
        if run_id ~= state.run_id then return end
        if event.type == "usage" then
          state.live_usage = {
            tokens = context_metrics.usage_tokens(event.usage) or 0,
            message_count = #assert(state.session:context_messages()) + 1,
          }
          opts.update_context()
        elseif event.type == "provider_status" then
          state.provider_status = type(event.text) == "string" and event.text or nil
          opts.update_context()
        elseif event.type == "message_end" then
          opts.sync_tools()
          opts.update_context()
        end
        if event.type == "message_end" then
          state.pending_events = {}
        elseif event.type ~= "usage" and event.type ~= "provider_status" then
          state.pending_events[#state.pending_events + 1] = util.copy(event)
        end
        if type(opts.provider_event) == "function" then
          opts.provider_event(event)
        end
        opts.publish({ type = "event", event = event })
        if event.type == "tool_end" and not event.message.isError then
          local details = type(event.message.details) == "table" and event.message.details or {}
          local changed_paths = details.changed_paths
          if type(changed_paths) == "table" and util.is_list(changed_paths) then
            for _, path in ipairs(changed_paths) do
              if type(path) == "string" and path ~= "" then opts.refresh_buffer(path) end
            end
          end
        end
      end

      local launch
      local function abandon_failed_message()
        local path = assert(state.session:path())
        local last = path[#path]
        if last and last.type == "message" and last.message.role == "assistant"
            and last.message.stopReason == "error" then
          local parent = last.parentId == vim.NIL and nil or last.parentId
          local moved, move_err = state.session:move_to(parent)
          if not moved then error(move_err, 0) end
          opts.publish_messages(opts.transcript_messages(state.session))
        end
      end

      local function transition_done(done)
        local can_continue = config.continuation ~= nil or config.interaction == nil
        if not overflow_retried and can_continue and is_context_overflow(done) then
          overflow_retried = true
          abandon_failed_message()
          local compacted = start_compaction("overflow", nil, run_id, function(compacted_result)
            if compacted_result.ok then launch(true) else finish_interaction(done) end
          end)
          if compacted then return end
        end
        if not length_continued and can_continue and is_length_limited(done) then
          length_continued = true
          if needs_compaction() then
            local compacted = start_compaction("threshold", nil, run_id,
              function(compacted_result)
                if compacted_result.ok then
                  launch(true)
                else
                  finish_interaction(done)
                end
              end)
            if compacted then return end
            finish_interaction(done)
            return
          end
          launch(true)
          return
        end
        local retry_settings = config.retry
        local retry_limit = retry_settings.enabled and retry_settings.max_retries or 0
        local provider_limit = done.error and tonumber(done.error.stream_max_retries)
        if provider_limit then retry_limit = math.min(retry_limit, provider_limit) end
        if can_continue and done.error and is_retryable_error(done.error)
            and stream_retries < retry_limit then
          stream_retries = stream_retries + 1
          abandon_failed_message()
          state.pending_events = {}
          state.live_usage = nil
          local wait = tonumber(done.error.retry_after_ms)
            or retry_settings.base_delay_ms * (2 ^ (stream_retries - 1))
          wait = math.max(0, math.min(60000, wait))
          state.provider_status = string.format("Reconnecting… %d/%d", stream_retries, retry_limit)
          opts.update_context()
          local waiting
          waiting = require("neoagent.async").run(function()
            retry_delay(wait)
            return { ok = true }
          end, {
            on_done = function(wait_result)
              if run_id ~= state.run_id then return end
              state.provider_status = nil
              if not wait_result.ok then
                finish_interaction(wait_result)
                return
              end
              local launched, launch_err = pcall(launch, true)
              if not launched then
                finish_interaction({
                  ok = false,
                  error = util.normalize_error(launch_err, "controller"),
                })
              end
            end,
            error_kind = "controller",
          })
          state.run = waiting
          return
        end
        if needs_compaction() then
          local compacted = start_compaction("threshold", nil, run_id, function()
            finish_interaction(done)
          end)
          if compacted then return end
        end
        finish_interaction(done)
      end

      local function on_done(done)
        if run_id ~= state.run_id then return end
        if type(opts.provider_event) == "function"
            and type(done.error) == "table"
            and (type(done.error.provider_status) == "string"
              or type(done.error.provider_status_details) == "table") then
          opts.provider_event({
            type = "provider_status",
            text = done.error.provider_status,
            details = util.copy(done.error.provider_status_details),
          })
        end
        local transitioned, transition_err = pcall(transition_done, done)
        if not transitioned then
          finish_interaction(completion_failure(transition_err, done))
        end
      end

      launch = function(continuing)
        local call = vim.tbl_extend("force", {}, base)
        call.model_options = util.copy(base.model_options)
        call.model_options.retry_attempt = stream_retries
        call.on_event, call.on_done = on_event, on_done
        local selected = continuing and (config.continuation or default_continuation)
          or (config.interaction or default_interaction)
        local run = selected(call)
        assert(type(run) == "table" and type(run.cancel) == "function", "interaction must return a Run")
        state.run = run
        state.status = "running"
        state.pending_events = {}
        opts.publish_messages(opts.transcript_messages(state.session))
        opts.update_context()
        return run
      end

      if needs_compaction() then
        local compacted = start_compaction("threshold", nil, run_id, function() launch(false) end)
        if compacted then return compacted end
      end
      return launch(false)
    end)
    if not ok then
      release_provider()
      local err = util.normalize_error(result, "session")
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    return result
  end

  function lifecycle.send(text)
    if state.status == "running" or state.status == "compacting" then
      return lifecycle.steer(text)
    end
    return submit(text)
  end

  function lifecycle.steer(text)
    if util.trim(text) == "" then return nil end
    if state.status ~= "running" and state.status ~= "compacting" then
      opts.notify("cannot steer while the agent is idle", vim.log.levels.WARN)
      return nil
    end
    state.steering[#state.steering + 1] = { text = text, timestamp = util.now_ms() }
    opts.update_context()
    return true
  end

  function lifecycle.dequeue_steering()
    local messages = vim.tbl_map(function(message) return message.text end, state.steering)
    state.steering = {}
    opts.update_context()
    return messages
  end

  function lifecycle.compact(instructions)
    if state.run then opts.notify("cannot compact while the agent is running", vim.log.levels.WARN) return nil end
    if config.compaction == false then opts.notify("compaction is disabled") return nil end
    if not state.session then opts.notify("no active session") return nil end
    local ok, err = pcall(opts.ensure_model)
    if not ok then
      err = util.normalize_error(err, "compaction")
      opts.notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    local acquired, release = pcall(opts.acquire_provider)
    if not acquired then
      local acquire_err = util.normalize_error(release, "provider")
      opts.notify(acquire_err.message, vim.log.levels.WARN)
      return nil, acquire_err
    end
    local run_id = state.run_id + 1
    state.run_id = run_id
    state.last_result = nil
    state.provider_usage_release = release
    local run, compact_err = start_compaction("manual", instructions, run_id)
    if not run then
      release_provider()
      compact_err = compact_err or util.error("compaction", "Nothing to compact")
      opts.notify(compact_err.message, vim.log.levels.WARN)
      return nil, compact_err
    end
    return run
  end

  function lifecycle.stop()
    if not state.run then return false end
    state.status = "stopping"
    opts.update_context()
    state.run:cancel()
    return true
  end

  return lifecycle
end

return M
