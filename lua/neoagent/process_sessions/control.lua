local util = require("neoagent.util")
local validate = require("neoagent.subprocess.validate")
local M = {}

---@class Neoagent.ProcessTargetState
---@field done boolean
---@field stdin_writable boolean
---@field resize_supported boolean
---@field outcome? Neoagent.SubprocessOutcome
---@field error? Neoagent.Error
---@field cleanup_error? Neoagent.Error

---@class Neoagent.ProcessControllerState: Neoagent.ProcessTargetState
---@field cleanup_done boolean Target and controller cleanup outcomes are known, independently of native release.
---@field released boolean
---@field release_error? Neoagent.Error Release cannot be confirmed; capacity must remain quarantined.

---@class Neoagent.ProcessTargetCollection: Neoagent.ProcessTargetState
---@field released boolean
---@field events Neoagent.SubprocessOutputEvent[]
---@field dropped_bytes integer

---@class Neoagent.ProcessCollection: Neoagent.ProcessControllerState, Neoagent.ProcessTargetCollection

---@class Neoagent.ProcessControl
---@field kind "write"|"close_stdin"|"resize"|"interrupt"|"terminate"
---@field data? string
---@field columns? integer
---@field rows? integer
---@field reason? string

-- Controllers reserve ownership before start and receive controls validated
-- by the session manager or the worker's RPC decoder. Remote controls are
-- acknowledged asynchronously without changing the local subprocess API.
---@class Neoagent.ProcessController
---@field start async fun(self: Neoagent.ProcessController): true
---@field state fun(self: Neoagent.ProcessController): Neoagent.ProcessControllerState
---@field collect async fun(self: Neoagent.ProcessController, wait_ms: integer, until_exit?: boolean): Neoagent.ProcessCollection
---@field control async fun(self: Neoagent.ProcessController, command: Neoagent.ProcessControl): true
---@field wait_cleanup async fun(self: Neoagent.ProcessController): true
---@field dispose fun(self: Neoagent.ProcessController, reason: string)

---@alias Neoagent.ProcessControllerFactory fun(spec: Neoagent.SubprocessSpec, output_bytes: integer, on_cleanup: fun(error: Neoagent.Error), on_released?: fun()): Neoagent.ProcessController

---@param command unknown
---@return Neoagent.ProcessControl
function M.validate(command)
  local fields = {
    write = { kind = true, data = true },
    close_stdin = { kind = true },
    resize = { kind = true, columns = true, rows = true },
    interrupt = { kind = true },
    terminate = { kind = true, reason = true },
  }
  if type(command) ~= "table" or not fields[command.kind] then
    error(validate.error("process_validation", "Invalid process control"), 0)
  end
  validate.fields(command, fields[command.kind], "Process control")
  if command.kind == "write" then
    if type(command.data) ~= "string" or #command.data > validate.WRITE_BYTES then
      error(validate.error("process_validation", "Process input must be a string of at most 65536 bytes"), 0)
    end
  elseif command.kind == "resize" then
    validate.dimensions(command.columns, command.rows)
  end
  ---@cast command Neoagent.ProcessControl
  local result = util.copy(command)
  if command.kind == "terminate" then
    result.reason = validate.reason(command.reason)
  end
  return result
end

return M
