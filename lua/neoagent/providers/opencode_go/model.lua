local async = require("neoagent.async")
local contract = require("neoagent.model")
local util = require("neoagent.util")

local M = {}
local followup = "Your previous response indicated tool use but contained no tool call. "
  .. "Supply the intended tool call, or finish your answer."

---@param left? Neoagent.UsageCost
---@param right Neoagent.UsageCost
---@return Neoagent.UsageCost
local function add_cost(left, right)
  local result = util.copy(left or {})
  for key, value in pairs(right) do
    result[key] = (result[key] or 0) + value
  end
  return result
end

---@param left? Neoagent.Usage
---@param right? Neoagent.Usage
---@return Neoagent.Usage
local function add_usage(left, right)
  local result = util.copy(left or {})
  for _, key in ipairs({
    "input", "output", "cacheRead", "cacheWrite", "reasoning", "totalTokens",
  }) do
    local value = right and right[key]
    if value ~= nil then result[key] = (result[key] or 0) + value end
  end
  if right and right.cost then result.cost = add_cost(result.cost, right.cost) end
  return result
end

---@param err Neoagent.Error
---@return boolean
local function missing_tool_call(err)
  return err.kind == "protocol" and rawget(err, "code") == "missing_tool_call"
end

---@param first Neoagent.AssistantMessage
---@param result Neoagent.ModelResult
---@return Neoagent.ModelResult
local function combine(first, result)
  local failure = result.ok == false and result.error or nil
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
  if failure then
    message.stopReason = failure.kind == "cancelled" and "aborted" or "error"
    message.errorMessage = failure.message
  end
  local combined = util.copy(result)
  combined.message = message
  combined.text = util.text_content(message.content)
  return combined
end

---@param model Neoagent.Model
---@return Neoagent.Model
function M.wrap(model)
  if model.id ~= "qwen3.8-flash" or model.api ~= "anthropic-messages" then return model end
  local wrapped = assert(contract.capabilities(model))
  ---@param opts Neoagent.StreamOptions
  ---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
  function wrapped:stream(opts)
    opts = opts or {}
    return async.run(
    ---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
    ---@return Neoagent.ModelResult
    function(run)
      local call = util.copy(opts)
      call.on_done = nil
      call.on_event = function(event) run:emit(event) end
      local first = contract.await_result(model:stream(call))
      if first.ok or not first.error or not missing_tool_call(first.error)
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
