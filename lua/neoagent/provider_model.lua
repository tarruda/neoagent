local request_preparation = require("neoagent.api.request_preparation")
local async = require("neoagent.async")
local contract = require("neoagent.model")
local provider_service = require("neoagent.provider_service")
local M = {}

---@async
---@generic R
---@param service Neoagent.ProviderService
---@param start fun(): Neoagent.Run<R, Neoagent.ModelEvent>
---@param consume async fun(child: Neoagent.Run<R, Neoagent.ModelEvent>): R
---@return R
local function await_leased(service, start, consume)
  local lease, err = provider_service.acquire_use(service)
  if not lease then
    error(err, 0)
  end
  ---@type Neoagent.Run<R, Neoagent.ModelEvent>?
  local child
  local ok, value = pcall(function()
    child = start()
    return consume(child)
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
end

-- Acquire before Authentication resolves credentials, including direct use of
-- a resolved Model without an Agent's activity lease.
---@param model Neoagent.Model
---@param service Neoagent.ProviderService
---@return Neoagent.Model
function M.wrap(model, service)
  ---@class Neoagent.ProviderModel: Neoagent.Model
  ---@field _model Neoagent.Model
  local result = assert(contract.capabilities(model)) --[[@as Neoagent.ProviderModel]]
  result._model = model
  ---@param opts Neoagent.StreamOptions
  function result:stream(opts)
    opts = request_preparation.copy(opts)
    return async.run(
      ---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
      ---@return Neoagent.ModelResult
      function(run)
        contract.require_files(opts)
        return await_leased(service, function()
          local call = request_preparation.copy(opts)
          call.on_done = nil
          call.on_event = function(event)
            run:emit(event)
          end
          return result._model:stream(call)
        end, contract.await_result)
      end,
      { on_done = opts.on_done, on_event = opts.on_event, error_kind = "model" }
    )
  end
  if model.estimate_request then
    ---@param opts Neoagent.RequestOptions
    ---@param operation? "compact"
    ---@async
    function result:estimate_request(opts, operation)
      return await_leased(service, function()
        return async.run(function()
          return model:estimate_request(opts, operation)
        end)
      end, function(child)
        local value = child:await()
        if type(value) ~= "number" then
          error(value.error, 0)
        end
        return value
      end)
    end
  end
  local compact = model.compact
  if compact then
    ---@param opts Neoagent.NativeCompactionOptions
    ---@return Neoagent.Run<Neoagent.NativeCompactionResult, Neoagent.ModelEvent>
    function result:compact(opts)
      opts = request_preparation.copy(opts)
      return async.run(
        ---@param run Neoagent.Run<Neoagent.NativeCompactionResult, Neoagent.ModelEvent>
        ---@return Neoagent.NativeCompactionResult
        function(run)
          contract.require_files(opts)
          return await_leased(service, function()
            local call = request_preparation.copy(opts)
            call.on_done = nil
            call.on_event = function(event)
              run:emit(event)
            end
            return compact(result._model, call)
          end, function(child)
            return child:await()
          end)
        end,
        { on_done = opts.on_done, on_event = opts.on_event, error_kind = "model" }
      )
    end
  end
  return contract.assert(result, "Provider Model")
end

return M
