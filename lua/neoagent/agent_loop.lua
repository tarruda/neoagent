local request_preparation = require("neoagent.api.request_preparation")
local async = require("neoagent.async")
local semantic_message = require("neoagent.semantic_message")
local tool_schema = require("neoagent.api.tool_schema")
local util = require("neoagent.util")

local M = {}

---@param model Neoagent.Model
---@param messages unknown
---@param files? Neoagent.Files
---@return Neoagent.RequestMessage[]?, Neoagent.Error?
function M.validate_request_messages(model, messages, files)
  local normalized, message_err = semantic_message.normalize_request_list(messages)
  if not normalized then
    return nil, util.error("context", "Invalid prepared request messages", message_err)
  end
  local compatible, compatibility_err = require("neoagent.model").compatible_context(model, normalized)
  if not compatible then
    return nil, util.normalize_error(compatibility_err, "model")
  end
  require("neoagent.model").require_files({ messages = normalized, files = files })
  return normalized
end

---@class Neoagent.Tool<C>: Neoagent.ToolDefinition
---@field execute async fun(arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult
---@field capabilities? {read_files?: boolean}
---@field on_messages? fun(messages: Neoagent.ProjectionMessage[], context: C)
---@field current? fun(context: C): unknown
---@field render? fun(options: Neoagent.ToolPresentationOptions): unknown

---@class Neoagent.ToolPresentationOptions
---@field arguments Neoagent.JsonObject
---@field result? Neoagent.ToolResult|Neoagent.ToolResultMessage
---@field state? string

---@alias Neoagent.ToolExecutor<C> async fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): Neoagent.ToolResult

---@class Neoagent.ToolContext<C>
---@field model Neoagent.Model
---@field run Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>
---@field execute_tool Neoagent.ToolExecutor<C>
---@field context? C
---@field call Neoagent.ToolCallBlock
---@field on_update fun(update: Neoagent.ToolResult)

---@class Neoagent.ObservedUserMessage: Neoagent.UserMessage
---@field _neoagent_entry_id? string

---@class Neoagent.ObservedAssistantMessage: Neoagent.AssistantMessage
---@field _neoagent_entry_id? string

---@class Neoagent.ObservedToolResultMessage: Neoagent.ToolResultMessage
---@field _neoagent_entry_id? string

---@alias Neoagent.ObservedMessage Neoagent.ObservedUserMessage|Neoagent.ObservedAssistantMessage|Neoagent.ObservedToolResultMessage
---@alias Neoagent.MessageCommit fun(message: Neoagent.Message): boolean?, unknown?, Neoagent.ObservedMessage?
---@alias Neoagent.SteeringAcknowledgement fun(committed: boolean, observation?: Neoagent.ObservedMessage)
---@alias Neoagent.SteeringMessages fun(): Neoagent.UserMessage[], Neoagent.SteeringAcknowledgement?
---@alias Neoagent.RequestAcknowledgement fun()
---@alias Neoagent.PrepareRequestMessages async fun(messages: Neoagent.RequestMessage[], options: Neoagent.StreamOptions): Neoagent.RequestMessage[]?, Neoagent.Error?, Neoagent.RequestAcknowledgement?

---@class Neoagent.MessageEndEvent
---@field type "message_end"
---@field message Neoagent.ObservedMessage

---@class Neoagent.ToolStartEvent
---@field type "tool_start"
---@field call Neoagent.ToolCallBlock

---@class Neoagent.ToolUpdateEvent
---@field type "tool_update"
---@field call Neoagent.ToolCallBlock
---@field result Neoagent.ToolResult

---@class Neoagent.ToolEndEvent
---@field type "tool_end"
---@field call Neoagent.ToolCallBlock
---@field message Neoagent.ObservedToolResultMessage

---@alias Neoagent.AgentLoopEvent Neoagent.ModelEvent|Neoagent.MessageEndEvent|Neoagent.ToolStartEvent|Neoagent.ToolUpdateEvent|Neoagent.ToolEndEvent

---@class Neoagent.AgentLoopSuccess
---@field ok true
---@field new_messages Neoagent.Message[]
---@field message Neoagent.AssistantMessage
---@field text string

---@class Neoagent.AgentLoopFailure: Neoagent.AsyncFailure
---@field new_messages? Neoagent.Message[]
---@field message? Neoagent.Message

---@alias Neoagent.AgentLoopResult Neoagent.AgentLoopSuccess|Neoagent.AgentLoopFailure

---@class Neoagent.Toolset<C>
---@field tools Neoagent.Tool<C>[]
---@field lookup table<string, Neoagent.Tool<C>>
---@field execute_tool Neoagent.ToolExecutor<C>

---@class Neoagent.AgentLoopOptions<C>: Neoagent.RunOptions<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>
---@field model Neoagent.Model
---@field messages Neoagent.RequestMessage[]
---@field system_prompt? string
---@field tools? Neoagent.Tool<C>[]
---@field execute_tool? Neoagent.ToolExecutor<C>
---@field context? C
---@field model_options? Neoagent.StreamOverrides
---@field get_steering_messages? Neoagent.SteeringMessages
---@field prepare_request_messages? Neoagent.PrepareRequestMessages
---@field commit_message Neoagent.MessageCommit

---@class Neoagent.PreparedAgentLoop<C>: Neoagent.RunOptions<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>
---@field model Neoagent.Model
---@field messages Neoagent.RequestMessage[]
---@field system_prompt? string
---@field context? C
---@field commit_message Neoagent.MessageCommit
---@field tools Neoagent.Tool<C>[]
---@field tool_schemas Neoagent.ToolDefinition[]
---@field tool_lookup table<string, Neoagent.Tool<C>>
---@field execute_tool Neoagent.ToolExecutor<C>
---@field model_options Neoagent.StreamOverrides
---@field get_steering_messages Neoagent.SteeringMessages
---@field prepare_request_messages? Neoagent.PrepareRequestMessages

---@generic C
---@param tool Neoagent.Tool<C>
---@param arguments Neoagent.JsonObject
---@param ctx Neoagent.ToolContext<C>
---@return Neoagent.ToolResult
---@async
local function default_execute(tool, arguments, ctx)
  return tool.execute(arguments, ctx)
end

---@param value unknown
---@return boolean
local function object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

---@param value unknown
---@return TypeGuard<string>
local function safe_tool_name(value)
  return type(value) == "string"
    and value ~= ""
    and #value <= 512
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

---@type table<string, boolean>
local tool_fields = {
  name = true,
  description = true,
  input_schema = true,
  execute = true,
  capabilities = true,
  on_messages = true,
  current = true,
  render = true,
}

---@generic C
---@param tools Neoagent.Tool<C>[]
---@param execute_tool? Neoagent.ToolExecutor<C>
---@return Neoagent.Toolset<C>
function M.validate_toolset(tools, execute_tool)
  assert(type(tools) == "table" and util.is_list(tools), "tools must be a list")
  assert(execute_tool == nil or type(execute_tool) == "function", "execute_tool must be a function")

  local copied = util.copy(tools)
  local lookup = {}
  for index, tool in ipairs(copied) do
    local label = "tool[" .. index .. "]"
    assert(object(tool), label .. " must be an object")
    for key in pairs(tool) do
      assert(tool_fields[key], label .. " has unsupported field " .. tostring(key))
    end
    assert(safe_tool_name(tool.name), label .. ".name must be safe non-empty UTF-8 text of at most 512 bytes")
    assert(not lookup[tool.name], "duplicate tool name: " .. tool.name)
    assert(
      type(tool.description) == "string" and util.is_valid_utf8(tool.description),
      label .. ".description must be a UTF-8 string"
    )
    local schema, schema_err = tool_schema.validate_definition(tool.input_schema)
    if not schema then
      error(label .. "." .. schema_err, 0)
    end
    tool.input_schema = schema
    assert(type(tool.execute) == "function", label .. ".execute must be a function")
    assert(tool.capabilities == nil or object(tool.capabilities), label .. ".capabilities must be an object")
    for key in pairs(tool.capabilities or {}) do
      assert(key == "read_files", label .. ".capabilities has unsupported field " .. tostring(key))
    end
    assert(
      tool.capabilities == nil or tool.capabilities.read_files == nil or type(tool.capabilities.read_files) == "boolean",
      label .. ".capabilities.read_files must be a boolean"
    )
    assert(tool.on_messages == nil or type(tool.on_messages) == "function", label .. ".on_messages must be a function")
    assert(tool.current == nil or type(tool.current) == "function", label .. ".current must be a function")
    assert(tool.render == nil or type(tool.render) == "function", label .. ".render must be a function")
    lookup[tool.name] = tool
  end
  return {
    tools = copied,
    lookup = lookup,
    execute_tool = execute_tool or default_execute,
  }
end

---@generic C
---@param opts Neoagent.AgentLoopOptions<C>
---@return Neoagent.PreparedAgentLoop<C>
function M.prepare(opts)
  opts = opts or {}
  assert(type(opts.model) == "table" and type(opts.model.stream) == "function", "model is required")
  assert(opts.system_prompt == nil or type(opts.system_prompt) == "string", "system_prompt must be a string")
  assert(opts.model_options == nil or object(opts.model_options), "model_options must be an object")
  local messages, message_err =
    M.validate_request_messages(opts.model, opts.messages, opts.model_options and opts.model_options.files)
  assert(messages, message_err)
  assert(opts.on_event == nil or type(opts.on_event) == "function", "on_event must be a function")
  assert(opts.on_done == nil or type(opts.on_done) == "function", "on_done must be a function")
  assert(opts.report == nil or type(opts.report) == "function", "report must be a function")
  assert(type(opts.commit_message) == "function", "commit_message must be a function")
  local steering = opts.get_steering_messages or function()
    return {}
  end
  assert(type(steering) == "function", "get_steering_messages must be a function")
  assert(
    opts.prepare_request_messages == nil or type(opts.prepare_request_messages) == "function",
    "prepare_request_messages must be a function"
  )
  local toolset = M.validate_toolset(opts.tools or {}, opts.execute_tool)
  return {
    model = opts.model,
    messages = messages,
    system_prompt = opts.system_prompt,
    tools = toolset.tools,
    tool_schemas = tool_schema.definitions(toolset.tools),
    tool_lookup = toolset.lookup,
    execute_tool = toolset.execute_tool,
    context = opts.context,
    model_options = util.copy(opts.model_options or {}),
    get_steering_messages = steering,
    prepare_request_messages = opts.prepare_request_messages,
    commit_message = opts.commit_message,
    on_event = opts.on_event,
    on_done = opts.on_done,
    report = opts.report,
  }
end

---@param tool Neoagent.ToolDefinition
---@param arguments unknown
---@return boolean, string?, Neoagent.JsonObject?
---@return_overload true, nil, Neoagent.JsonObject
---@return_overload false, string
local function validate_arguments(tool, arguments)
  local valid, message = tool_schema.validate(tool.input_schema or {}, arguments)
  if not valid then
    return false, message
  end
  ---@cast arguments Neoagent.JsonObject
  return true, nil, arguments
end

---@param message Neoagent.AssistantMessage
---@return Neoagent.ToolCallBlock[]
local function tool_calls(message)
  local result = {}
  for _, block in ipairs(message.content or {}) do
    if block.type == "toolCall" then
      result[#result + 1] = block
    end
  end
  return result
end

---@param message Neoagent.AssistantMessage
---@return boolean
local function has_visible_text(message)
  return util.trim(util.text_content(message.content)) ~= ""
end

---@param message Neoagent.AssistantMessage
---@return boolean
local function thinking_only_stop(message)
  if message.stopReason ~= "stop" or has_visible_text(message) then
    return false
  end
  local has_thinking = false
  for _, block in ipairs(message.content) do
    if
      block.type == "thinking"
      and (block.thinking ~= "" or block.thinkingSignature and block.thinkingSignature ~= "" or block.redacted)
    then
      has_thinking = true
    end
  end
  return has_thinking
end

---@param err unknown
---@return Neoagent.ToolResult
local function error_result(err)
  err = util.normalize_error(err, "tool")
  local detail = rawget(err, "detail")
  local result = {
    content = { { type = "text", text = util.text_from_bytes(err.message) } },
    isError = true,
    details = detail and { detail = detail } or nil,
  }
  return (assert(semantic_message.normalize_tool_result(result)))
end

---@param result unknown
---@param transient? boolean
---@return Neoagent.ToolResult
local function validate_tool_result(result, transient)
  local normalized, err = semantic_message.normalize_tool_result(result, {
    transient = transient == true,
  })
  if not normalized then
    error(util.error("tool", err), 0)
  end
  return normalized
end

---@generic C
---@param opts Neoagent.AgentLoopOptions<C>
---@return Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>
function M.run(opts)
  local prepared = M.prepare(opts)
  local tools = prepared.tools
  local lookup = prepared.tool_lookup
  local execute = prepared.execute_tool
  local get_steering_messages = prepared.get_steering_messages
  return async.run(
    ---@param run Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>
    ---@return Neoagent.AgentLoopResult
    function(run)
      local working = util.copy(prepared.messages)
      ---@type Neoagent.Message[]
      local generated = {}
      ---@type Neoagent.Message?
      local last_message
      ---@type table<string, boolean>
      local seen_calls = {}
      local retrying_thinking_stop = false
      local recovering_model = false
      ---@param messages Neoagent.RequestMessage[]
      local function call_ids(messages)
        local ids = {}
        for _, message in ipairs(messages) do
          if message.role == "assistant" then
            for _, block in ipairs(message.content) do
              if block.type == "toolCall" then
                ids[block.id] = true
              end
            end
          end
        end
        return ids
      end
      seen_calls = call_ids(working)

      ---@param message unknown
      ---@param expected_role "assistant"|"user"|"toolResult"
      ---@param owner string
      ---@return Neoagent.Message
      local function normalize_candidate(message, expected_role, owner)
        local normalize = owner == "model" and semantic_message.normalize_model_response or semantic_message.normalize
        local normalized, err = normalize(message)
        if not normalized then
          error(util.normalize_error(err, owner), 0)
        end
        if normalized.role ~= expected_role then
          error(util.error(owner, expected_role .. " message is required"), 0)
        end
        if normalized.role == "assistant" then
          for _, block in ipairs(normalized.content) do
            if block.type == "toolCall" and seen_calls[block.id] then
              error(util.error(owner, "duplicate conversation toolCall id: " .. block.id), 0)
            end
          end
        end
        return normalized
      end

      ---@param normalized Neoagent.Message
      local function record(normalized)
        if normalized.role == "assistant" then
          ---@cast normalized Neoagent.AssistantMessage
          for _, block in ipairs(normalized.content) do
            if block.type == "toolCall" then
              seen_calls[block.id] = true
            end
          end
        end
        working[#working + 1] = normalized
        generated[#generated + 1] = normalized
      end

      ---@param normalized Neoagent.Message
      ---@param observation? Neoagent.ObservedMessage
      ---@return Neoagent.ObservedMessage?, Neoagent.Error?
      ---@return_overload Neoagent.ObservedMessage
      ---@return_overload nil, Neoagent.Error
      local function observation_message(normalized, observation)
        if observation == nil then
          return util.copy(normalized)
        end
        if type(observation) ~= "table" then
          return nil, util.error("session", "commit_message observation must be a message")
        end
        local copied = util.copy(observation)
        local entry_id = copied._neoagent_entry_id
        copied._neoagent_entry_id = nil
        local semantic, semantic_err = semantic_message.normalize(copied)
        if not semantic or not vim.deep_equal(semantic, normalized) then
          return nil, util.error("session", "commit_message observation must match the committed message", semantic_err)
        end
        if
          entry_id ~= nil
          and (
            type(entry_id) ~= "string"
            or entry_id == ""
            or #entry_id > 512
            or not util.is_valid_utf8(entry_id)
            or entry_id:find("[%z\1-\31\127]")
          )
        then
          return nil, util.error("session", "commit_message observation entry id is invalid")
        end
        ---@type Neoagent.ObservedMessage
        local observed = semantic
        observed._neoagent_entry_id = entry_id
        return observed
      end

      ---@param message unknown
      ---@param expected_role "assistant"|"user"|"toolResult"
      ---@param owner string
      ---@param before_observe? fun(observation: Neoagent.ObservedMessage)
      ---@param on_committed? fun(observation?: Neoagent.ObservedMessage)
      ---@return Neoagent.Message?, Neoagent.Error?, Neoagent.Message?
      ---@return_overload Neoagent.Message
      ---@return_overload nil, Neoagent.Error, Neoagent.Message?
      local function commit(message, expected_role, owner, before_observe, on_committed)
        local normalized = normalize_candidate(message, expected_role, owner)
        local called, committed, err, observation = pcall(prepared.commit_message, util.copy(normalized))
        if not called then
          return nil, util.normalize_error(committed, "session"), normalized
        end
        if not committed then
          return nil,
            err and util.normalize_error(err, "session") or util.error("session", "Message commit failed"),
            normalized
        end
        if on_committed then
          local acknowledged, acknowledge_err = pcall(on_committed, util.copy(observation))
          if not acknowledged then
            return nil, util.normalize_error(acknowledge_err, "session"), normalized
          end
        end

        local observed, observation_err = observation_message(normalized, observation)
        record(normalized)
        if not observed then
          return nil, observation_err, nil
        end
        if run:is_cancelled() then
          error(async.cancelled_error, 0)
        end
        if before_observe then
          before_observe(observed)
        end
        run:emit({
          type = "message_end",
          message = util.copy(observed),
        })
        return normalized
      end

      ---@param candidate? Neoagent.Message
      ---@param err Neoagent.Error
      ---@return Neoagent.AgentLoopFailure
      local function commit_failure(candidate, err)
        return {
          ok = false,
          new_messages = util.copy(generated),
          message = candidate and util.copy(candidate) or nil,
          error = err,
        }
      end

      ---@return integer, Neoagent.AgentLoopFailure?
      local function commit_steering()
        local steering, acknowledge = get_steering_messages()
        assert(type(steering) == "table" and util.is_list(steering), "get_steering_messages must return a list")
        assert(
          acknowledge == nil or type(acknowledge) == "function",
          "get_steering_messages acknowledgement must be a function"
        )
        assert(acknowledge == nil or #steering <= 1, "acknowledged steering must contain at most one message")
        assert(acknowledge == nil or #steering == 1, "steering acknowledgement requires one message")
        local acknowledged = false
        ---@param committed boolean
        ---@param observation? Neoagent.ObservedMessage
        local function settle(committed, observation)
          if not acknowledge or acknowledged then
            return
          end
          acknowledged = true
          local ok, err = pcall(acknowledge, committed, observation)
          if not ok then
            error(util.normalize_error(err, "session"), 0)
          end
        end
        for _, message in ipairs(steering) do
          local called, committed, commit_err, candidate = pcall(
            commit,
            message,
            "user",
            "message",
            nil,
            function(observation)
              settle(true, observation)
            end
          )
          if not called then
            settle(false)
            error(committed, 0)
          end
          if not committed then
            settle(false)
            return 0, commit_failure(candidate, util.normalize_error(commit_err, "session"))
          end
        end
        return #steering
      end

      ---@async
      ---@param model_opts Neoagent.StreamOptions
      ---@return Neoagent.AgentLoopFailure?, Neoagent.RequestAcknowledgement?
      local function prepare_request(model_opts)
        model_opts.messages = util.copy(working)
        local replacement, err, acknowledge =
          assert(prepared.prepare_request_messages)(util.copy(working), request_preparation.copy(model_opts))
        if run:is_cancelled() then
          return commit_failure(nil, async.cancelled_error)
        end
        if not replacement then
          return commit_failure(nil, util.normalize_error(err, "context"))
        end
        local normalized, message_err =
          M.validate_request_messages(prepared.model, replacement, prepared.model_options.files)
        if not normalized then
          return commit_failure(nil, assert(message_err))
        end
        assert(
          acknowledge == nil or type(acknowledge) == "function",
          "prepare_request_messages acknowledgement must be a function"
        )
        working = normalized
        seen_calls = call_ids(working)
        return nil, acknowledge
      end

      while true do
        local model_opts = request_preparation.copy(prepared.model_options)
        ---@cast model_opts Neoagent.StreamOptions
        model_opts._preparation = request_preparation.new()
        model_opts.system_prompt = prepared.system_prompt
        model_opts.tools = util.copy(prepared.tool_schemas)
        local acknowledge
        if prepared.prepare_request_messages then
          local _, steering_err = commit_steering()
          if steering_err then
            return steering_err
          end
          if run:is_cancelled() then
            return commit_failure(nil, async.cancelled_error)
          end
          local prepare_err
          prepare_err, acknowledge = prepare_request(model_opts)
          if prepare_err then
            return prepare_err
          end
          local additional, additional_err = commit_steering()
          if additional_err then
            return additional_err
          end
          if additional > 0 then
            prepare_err, acknowledge = prepare_request(model_opts)
            if prepare_err then
              return prepare_err
            end
          end
        end
        if run:is_cancelled() then
          return commit_failure(nil, async.cancelled_error)
        end
        model_opts.messages = util.copy(working)
        model_opts.on_event = function(event)
          run:emit(event)
        end
        if acknowledge then
          acknowledge()
          if run:is_cancelled() then
            return commit_failure(nil, async.cancelled_error)
          end
        end
        local model_run = prepared.model:stream(model_opts)
        local model_result = require("neoagent.model").await_result(model_run)
        if not model_result.ok then
          if model_result.message then
            local commit_err, candidate
            last_message, commit_err, candidate = commit(model_result.message, "assistant", "model")
            if not last_message then
              return commit_failure(candidate, commit_err)
            end
          end
          local recovery = model_result.recovery
          if not recovery or recovering_model or not model_result.message or run:is_cancelled() then
            return {
              ok = false,
              new_messages = generated,
              message = last_message,
              error = assert(model_result.error),
            }
          end
          assert(type(recovery.warning) == "string", "Model recovery warning must be a string")
          run:emit({ type = "warning", message = recovery.warning })
          local committed, commit_err, candidate = commit(recovery.message, "user", "recovery")
          if not committed then
            return commit_failure(candidate, commit_err)
          end
          recovering_model = true
        else
          local commit_err, candidate
          last_message, commit_err, candidate = commit(model_result.message, "assistant", "model")
          if not last_message then
            return commit_failure(candidate, commit_err)
          end
          ---@cast last_message Neoagent.AssistantMessage
          local calls = tool_calls(last_message)
          if
            recovering_model
            and #calls == 0
            and not has_visible_text(last_message)
            and last_message.stopReason ~= "length"
          then
            return commit_failure(
              last_message,
              util.error("model", "Model recovery produced no visible answer or tool call")
            )
          end
          recovering_model = false
          for _, call in ipairs(calls) do
            run:emit({ type = "tool_start", call = util.copy(call) })
            ---@type Neoagent.ToolResult
            local result
            local tool = lookup[call.name]
            if type(call.argumentsError) == "string" and call.argumentsError ~= "" then
              result = error_result(util.error("tool", call.argumentsError))
            elseif not tool then
              result = error_result(util.error("tool", "Unknown tool: " .. tostring(call.name)))
            else
              local valid_arguments, arguments_error, arguments = validate_arguments(tool, call.arguments)
              if not valid_arguments then
                result = error_result(util.error("tool", arguments_error))
              else
                local active = true
                ---@param update Neoagent.ToolResult
                local function on_update(update)
                  if not active or run:is_cancelled() or run:is_done() then
                    return
                  end
                  local valid, normalized = pcall(validate_tool_result, update, true)
                  if valid then
                    run:emit({ type = "tool_update", call = util.copy(call), result = util.copy(normalized) })
                  end
                end
                ---@type Neoagent.ToolContext<C>
                local ctx = {
                  model = prepared.model,
                  run = run,
                  execute_tool = execute,
                  context = prepared.context,
                  call = util.copy(call),
                  on_update = on_update,
                }
                ctx.call.arguments = util.copy(arguments)
                local executed, value = pcall(function()
                  return execute(tool, util.copy(arguments), ctx)
                end)
                active = false
                if executed then
                  local valid, normalized = pcall(validate_tool_result, value)
                  if valid then
                    -- Returning a final result acknowledges completed work.
                    -- Commit it before cancellation stops further observation.
                    result = normalized
                  elseif run:is_cancelled() then
                    error(async.cancelled_error, 0)
                  else
                    result = error_result(normalized)
                  end
                elseif run:is_cancelled() then
                  error(async.cancelled_error, 0)
                else
                  local err = util.normalize_error(value, "tool")
                  if err.kind == "cancelled" then
                    error(err, 0)
                  end
                  result = error_result(err)
                end
              end
            end

            ---@type Neoagent.ToolResultMessage
            local message = {
              role = "toolResult",
              toolCallId = call.id,
              toolName = call.name,
              content = util.copy(result.content),
              isError = result.isError == true or result.is_error == true,
              timestamp = util.now_ms(),
            }
            if result.details ~= nil then
              message.details = util.copy(result.details)
            end
            if result.execution ~= nil then
              message.execution = util.copy(result.execution)
            end
            if result.usage ~= nil then
              message.usage = util.copy(result.usage)
            end
            local committed
            committed, commit_err, candidate = commit(message, "toolResult", "tool", function(observed)
              ---@cast observed Neoagent.ObservedToolResultMessage
              run:emit({
                type = "tool_end",
                call = util.copy(call),
                message = util.copy(observed),
              })
            end)
            if not committed then
              return commit_failure(candidate, commit_err)
            end
          end

          local count, steering_failure = commit_steering()
          if steering_failure then
            return steering_failure
          end
          if retrying_thinking_stop then
            if #calls == 0 and not has_visible_text(last_message) and last_message.stopReason ~= "length" then
              return commit_failure(last_message, util.error("model", "Model stopped during reasoning after one retry"))
            end
            retrying_thinking_stop = false
          end
          if #calls == 0 and thinking_only_stop(last_message) then
            retrying_thinking_stop = true
          end
          if #calls == 0 and count == 0 then
            if not retrying_thinking_stop then
              return {
                ok = true,
                new_messages = generated,
                message = last_message,
                text = util.text_content(last_message.content),
              }
            end
          end
        end
      end
    end,
    {
      on_event = prepared.on_event,
      on_done = prepared.on_done,
      report = prepared.report,
      error_kind = "tool",
    }
  )
end

return M
