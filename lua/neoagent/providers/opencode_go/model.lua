local async = require("neoagent.async")
local contract = require("neoagent.model")
local util = require("neoagent.util")

local M = {}
local followup = "Your previous response indicated tool use but contained no tool call. "
  .. "Supply the intended tool call, or finish your answer."

local function add_usage(left, right)
  local result = util.copy(left or {})
  for key, value in pairs(right or {}) do
    if type(value) == "table" then
      result[key] = add_usage(result[key], value)
    else
      result[key] = (result[key] or 0) + value
    end
  end
  return result
end

local function combine(first, result)
  local message = util.copy(result.message or first)
  message.content = util.copy(first.content)
  for _, block in ipairs(result.message and result.message.content or {}) do
    local copied = util.copy(block)
    -- Anthropic text/thinking deltas have no index. Give the continuation a
    -- separate identity so live rendering agrees with the committed blocks.
    if copied.type == "text" or copied.type == "thinking" then copied.index = 1 end
    message.content[#message.content + 1] = copied
  end
  message.usage = add_usage(first.usage, result.message and result.message.usage)
  if not result.ok then
    message.stopReason = result.error.kind == "cancelled" and "aborted" or "error"
    message.errorMessage = result.error.message
  end
  result = util.copy(result)
  result.message = message
  result.text = util.text_content(message.content)
  return result
end

function M.wrap(model)
  if model.id ~= "qwen3.8-flash" or model.api ~= "anthropic-messages" then return model end
  local wrapped = assert(contract.capabilities(model))
  function wrapped:stream(opts)
    opts = opts or {}
    return async.run(function(run)
      local call = util.copy(opts)
      call.on_done = nil
      call.on_event = function(event) run:emit(event) end
      local first = contract.await_result(model:stream(call))
      if first.ok or not first.error or first.error.kind ~= "protocol"
          or first.error.code ~= "missing_tool_call"
          or not first.message or run:is_cancelled() then return first end

      run:emit({ type = "warning", message = "Provider bug: OpenCode Go's qwen3.8-flash "
        .. "declared tool use without a tool call. Trying one follow-up request." })
      call.messages = util.copy(opts.messages)
      local previous = util.copy(first.message)
      previous.stopReason, previous.errorMessage = "stop", nil
      call.messages[#call.messages + 1] = previous
      call.messages[#call.messages + 1] = { role = "user", content = followup }
      call.on_event = function(event)
        local emitted = util.copy(event)
        if emitted.type == "text_delta" or emitted.type == "thinking_delta" then
          emitted.index = 1
        elseif emitted.type == "usage" then
          emitted.usage = add_usage(first.message.usage, emitted.usage)
        end
        run:emit(emitted)
      end
      local ok, result = pcall(function()
        return contract.await_result(model:stream(call))
      end)
      if not ok then result = { ok = false, error = util.normalize_error(result, "model") } end
      return combine(first.message, result)
    end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
  end
  return contract.assert(wrapped, "OpenCode Go Model wrapper")
end

return M
