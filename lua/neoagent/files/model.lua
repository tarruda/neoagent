local async = require("neoagent.async")
local contract = require("neoagent.model")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")
local M = {}

-- Acquire before Authentication resolves credentials, including direct use of
-- a resolved Model without an Agent's activity lease.
---@param model Neoagent.Model
---@param service Neoagent.ProviderService
---@return Neoagent.Model
function M.wrap(model, service)
  local result = {
    _model = model,
    api = model.api,
    provider = model.provider,
    id = model.id,
    input = util.copy(model.input),
    context_window = model.context_window,
    timeout_ms = model.timeout_ms,
    thinking = util.copy(model.thinking),
  }
  ---@param opts Neoagent.StreamOptions
  function result:stream(opts)
    opts = util.copy(opts)
    return async.run(
      ---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
      ---@return Neoagent.ModelResult
      function(run)
        contract.require_files(opts)
        local lease, err = provider_service.acquire_use(service)
        if not lease then
          error(err, 0)
        end
        ---@type Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>?
        local child
        local ok, value = pcall(function()
          local call = util.copy(opts)
          call.on_done = nil
          call.on_event = function(event)
            run:emit(event)
          end
          child = self._model:stream(call)
          return contract.await_result(child)
        end)
        if child and not child:is_done() then
          child:_listen(function()
            lease:release()
          end)
        else
          lease:release()
        end
        if not ok then
          error(value, 0)
        end
        return value
      end,
      { on_done = opts.on_done, on_event = opts.on_event, error_kind = "model" }
    )
  end
  return contract.assert(result, "File-capable provider Model")
end

return M
