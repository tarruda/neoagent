local async = require("neoagent.async")
local local_process = require("neoagent.process_sessions.local")
local codec = require("neoagent.rpc.process_codec")
local validation = require("neoagent.validation")
local M = {}

---@return Neoagent.RpcServerDomain
function M.new()
  ---@type Neoagent.ProcessController?
  local controller
  ---@type fun(name: string, value: table)
  local send_complete
  local closed = false
  local started = false
  local completion_sent = false
  return {
    error_kind = "process",
    -- One completion and, if native resources remain, one later release.
    max_pending_events = 2,
    events = function(send)
      send_complete = send
    end,
    open = function(context)
      assert(validation.object(context) and next(context) == nil, "process connection requires an empty context")
    end,
    request = function(method, payload)
      return {
        ---@async
        execute = function()
          if method == "process_start" then
            assert(not started, "process connection already admitted a target")
            started = true
            local spec, maximum = codec.start(payload)
            -- Publish ownership before any native allocation or startup wait.
            local owner = local_process.new(spec, maximum, nil, function()
              if completion_sent and not closed then
                send_complete(codec.RELEASED, {})
              end
            end)
            controller = owner
            local started, err = pcall(owner.start, owner)
            async.run(function()
              owner:wait()
              if not closed then
                send_complete(codec.COMPLETE, codec.encode(owner:collect(0)))
                completion_sent = true
              end
            end)
            if not started then
              error(err, 0)
            end
            return {}
          end
          if method == "process_dispose" then
            assert(validation.object(payload) and next(payload) == nil, "invalid process disposal")
            if controller then
              controller:dispose("Retained process owner disposed the target")
            end
            return {}
          end
          local owner = assert(controller, "process connection has no target")
          if method == "process_collect" then
            local wait_ms, until_exit = codec.collect(payload)
            return codec.encode(owner:collect(wait_ms, until_exit))
          elseif method == "process_ping" then
            assert(validation.object(payload) and next(payload) == nil, "invalid process liveness probe")
            return {}
          elseif method == "process_control" then
            owner:control(codec.control(payload))
            return {}
          end
          error("unknown process RPC method", 0)
        end,
        finish = function(result)
          if method == "process_start" and result.ok == false and not controller and not completion_sent then
            -- Rejection before construction owns no native resources. Publish
            -- that fact through the same completion/release boundary as a
            -- failed native start whose controller must continue cleanup.
            completion_sent = true
            send_complete(
              codec.COMPLETE,
              codec.encode({
                done = true,
                released = true,
                stdin_writable = false,
                resize_supported = false,
                error = result.error,
                events = {},
                dropped_bytes = 0,
              })
            )
          end
          return result
        end,
      }
    end,
    close = function(reason)
      closed = true
      if controller then
        controller:dispose(reason)
      end
    end,
    is_quiescent = function()
      return not controller or controller:state().released
    end,
  }
end

return M
