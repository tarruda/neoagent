local request_preparation = require("neoagent.api.request_preparation")
local async = require("neoagent.async")
local contract = require("neoagent.model")

local M = {}

---@param model Neoagent.Model
---@return Neoagent.Model
function M.wrap(model)
  if model.id ~= "qwen3.8-flash" or model.api ~= "anthropic-messages" then
    return model
  end
  local wrapped = assert(contract.capabilities(model))
  if model.estimate_request then
    ---@param opts Neoagent.RequestOptions
    ---@param operation? "compact"
    ---@async
    function wrapped:estimate_request(opts, operation)
      return model:estimate_request(opts, operation)
    end
  end
  ---@param opts Neoagent.StreamOptions
  ---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
  function wrapped:stream(opts)
    return async.run(function(run)
      local call = request_preparation.copy(opts)
      call.on_done = nil
      call.on_event = function(event)
        run:emit(event)
      end
      local result = contract.await_result(model:stream(call))
      if
        not result.ok
        and result.error
        and result.error.kind == "protocol"
        and result.error.code == "missing_tool_call"
        and result.message
        and not run:is_cancelled()
      then
        -- The provider identifies its recovery policy. The Loop owns the
        -- committed follow-up, request gate, and bounded continuation.
        result.recovery = {
          message = {
            role = "user",
            content = "Your previous response indicated tool use but contained no tool call. "
              .. "Supply the intended tool call, or finish your answer.",
          },
          warning = "Provider bug: OpenCode Go's qwen3.8-flash declared tool use without a tool call. Trying one follow-up request.",
        }
      end
      return result
    end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
  end
  return contract.assert(wrapped, "OpenCode Go Model wrapper")
end

return M
