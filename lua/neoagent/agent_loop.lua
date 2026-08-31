local async = require("neoagent.async")
local tool_schema = require("neoagent.api.tool_schema")
local util = require("neoagent.util")

local M = {}

local function default_execute(tool, arguments, ctx)
  return tool.execute(arguments, ctx)
end

local function schemas(tools)
  local result = {}
  for _, tool in ipairs(tools) do
    result[#result + 1] = {
      name = tool.name,
      description = tool.description,
      input_schema = util.copy(tool.input_schema),
    }
  end
  return result
end

local function validate_arguments(tool, arguments)
  local valid, message = tool_schema.validate({ type = "object" }, arguments)
  if not valid then return false, message end
  return tool_schema.validate(tool.input_schema or {}, arguments)
end

local function tool_calls(message)
  local result = {}
  for _, block in ipairs(message.content or {}) do
    if block.type == "toolCall" then
      result[#result + 1] = block
    end
  end
  return result
end

local function error_result(err)
  err = util.normalize_error(err, "tool")
  return {
    content = { { type = "text", text = err.message } },
    isError = true,
    details = err.detail and { detail = err.detail } or nil,
  }
end

local function invalid_result(message)
  error(util.error("tool", message), 0)
end

local function validate_semantic_string(value, field, maximum)
  if type(value) ~= "string" or value == "" then
    invalid_result("Tool returned an image with an invalid " .. field)
  end
  if not util.is_valid_utf8(value) then
    invalid_result("Tool returned an image " .. field .. " that is not valid UTF-8")
  end
  if #value > maximum then
    invalid_result("Tool returned an image " .. field .. " that exceeds "
      .. maximum .. " bytes")
  end
  if value:find("%c") then
    invalid_result("Tool returned an image " .. field .. " with control characters")
  end
end

local function validate_image(block, transient, ids)
  if type(block.data) ~= "string" then
    invalid_result("Tool returned an image without string data")
  end
  if block.mimeType ~= nil and type(block.mimeType) ~= "string" then
    invalid_result("Tool returned an image with an invalid mimeType")
  end
  if transient and block.id == nil then
    invalid_result("Transient tool images require an id")
  end
  if block.id ~= nil then
    validate_semantic_string(block.id, "id", 512)
    if ids[block.id] then
      invalid_result("Tool returned duplicate image id: " .. block.id)
    end
    ids[block.id] = true
  end
  if transient and block.revision == nil then
    invalid_result("Transient tool images require a revision")
  end
  if block.revision ~= nil then
    local kind = type(block.revision)
    if kind == "number" then
      if block.revision ~= block.revision
          or block.revision == math.huge or block.revision == -math.huge then
        invalid_result("Tool returned an image revision that is not finite")
      end
    elseif kind == "string" then
      validate_semantic_string(block.revision, "revision", 128)
    else
      invalid_result("Tool returned an image with an invalid revision")
    end
  end
end

local function validate_tool_result(result, transient)
  if type(result) ~= "table" or type(result.content) ~= "table" then
    error(util.error("tool", "Tool must return a result with content blocks"), 0)
  end
  local image_ids = {}
  for _, block in ipairs(result.content) do
    if type(block) ~= "table" or (block.type ~= "text" and block.type ~= "image") then
      error(util.error("tool", "Tool returned an unsupported content block"), 0)
    end
    if block.type == "text" and type(block.text) ~= "string" then
      error(util.error("tool", "Tool returned text without a string value"), 0)
    end
    if block.type == "text" and not util.is_valid_utf8(block.text) then
      error(util.error("tool", "Tool returned text that is not valid UTF-8"), 0)
    end
    if block.type == "image" then
      validate_image(block, transient, image_ids)
    end
  end
  return result
end

function M.run(opts)
  opts = opts or {}
  assert(type(opts.model) == "table" and type(opts.model.stream) == "function", "model is required")
  assert(type(opts.messages) == "table", "messages are required")
  assert(opts.report == nil or type(opts.report) == "function",
    "report must be a function")
  local tools = opts.tools or {}
  local lookup = {}
  for _, tool in ipairs(tools) do
    assert(type(tool.name) == "string" and tool.name ~= "", "tool.name is required")
    assert(not lookup[tool.name], "duplicate tool name: " .. tool.name)
    lookup[tool.name] = tool
  end
  local execute = opts.execute_tool or default_execute
  local get_steering_messages = opts.get_steering_messages or function() return {} end
  assert(type(get_steering_messages) == "function", "get_steering_messages must be a function")
  return async.run(function(run)
    local working = util.copy(opts.messages)
    local generated = {}
    local last_message

    local function add(message)
      working[#working + 1] = message
      generated[#generated + 1] = message
      run:emit({ type = "message_end", message = util.copy(message) })
    end

    while true do
      local model_opts = util.copy(opts.model_options or {})
      model_opts.messages = util.copy(working)
      model_opts.system_prompt = opts.system_prompt
      model_opts.tools = schemas(tools)
      model_opts.on_event = function(event)
        run:emit(event)
      end
      local model_run = opts.model:stream(model_opts)
      local model_result = model_run:await()
      if not model_result.ok then
        if model_result.message then
          add(model_result.message)
          last_message = model_result.message
        end
        return {
          ok = false,
          new_messages = generated,
          message = model_result.message,
          error = model_result.error,
        }
      end

      last_message = model_result.message
      add(last_message)
      local calls = tool_calls(last_message)
      for _, call in ipairs(calls) do
        run:emit({ type = "tool_start", call = util.copy(call) })
        local result
        local tool = lookup[call.name]
        if type(call.argumentsError) == "string" and call.argumentsError ~= "" then
          result = error_result(util.error("tool", call.argumentsError))
        elseif not tool then
          result = error_result(util.error("tool", "Unknown tool: " .. tostring(call.name)))
        else
          local valid_arguments, arguments_error = validate_arguments(
            tool, call.arguments)
          if not valid_arguments then
            result = error_result(util.error("tool", arguments_error))
          else
            local active = true
            local ctx = {
              model = opts.model,
              run = run,
              execute_tool = execute,
              context = opts.context,
              call = util.copy(call),
            }
            ctx.on_update = function(update)
              if not active or run:is_cancelled() or run:is_done() then
                return
              end
              local valid, normalized = pcall(validate_tool_result, update, true)
              if valid then
                run:emit({ type = "tool_update", call = util.copy(call), result = util.copy(normalized) })
              end
            end
            local executed, value = pcall(execute, tool, util.copy(call.arguments), ctx)
            active = false
            if run:is_cancelled() then error(async.cancelled_error, 0) end
            if executed then
              local valid, normalized = pcall(validate_tool_result, value)
              result = valid and normalized or error_result(normalized)
            else
              local err = util.normalize_error(value, "tool")
              if err.kind == "cancelled" then error(err, 0) end
              result = error_result(err)
            end
          end
        end

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
        if result.usage ~= nil then
          message.usage = util.copy(result.usage)
        end
        run:emit({ type = "tool_end", call = util.copy(call), message = util.copy(message) })
        add(message)
      end

      local steering = get_steering_messages()
      assert(type(steering) == "table" and util.is_list(steering),
        "get_steering_messages must return a list")
      for _, message in ipairs(steering) do
        assert(type(message) == "table" and message.role == "user",
          "steering messages must be user messages")
        add(util.copy(message))
      end

      if #calls == 0 and #steering == 0 then
        return {
          ok = true,
          new_messages = generated,
          message = last_message,
          text = util.text_content(last_message.content),
        }
      end
    end
  end, {
    on_event = opts.on_event,
    on_done = opts.on_done,
    report = opts.report,
    error_kind = "tool",
  })
end

return M
