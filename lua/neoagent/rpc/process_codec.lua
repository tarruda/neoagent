local util = require("neoagent.util")
local validation = require("neoagent.validation")
local native = require("neoagent.subprocess.validate")
local protocol = require("neoagent.rpc.protocol")
local M = {}
M.COMPLETE = "process_complete"
M.RELEASED = "process_released"

local function object(value, fields, label)
  assert(validation.object(value), label .. " must be an object")
  validation.exact(value, fields, label)
end
local function integer(value, maximum)
  assert(native.integer(value, 0, maximum), "invalid process RPC integer")
end

-- Neovim marks decoded MessagePack maps, including nonempty ones, with its
-- dictionary metatable. Remove only that wire marker before calling the
-- stricter local API; do not weaken its plain-table contract.
local function plain(value)
  assert(type(value) == "table", "process RPC value must be a table")
  local mt = getmetatable(value)
  assert(mt == nil or mt == getmetatable(vim.empty_dict()), "invalid process RPC table")
  local result = {}
  for key, item in pairs(value) do
    result[key] = item
  end
  return result
end

---@param err Neoagent.Error
---@return Neoagent.Error
local function wire_error(err)
  return protocol.error({
    kind = err.kind,
    code = err.code,
    message = util.safe_message(err.message, { max_source_bytes = protocol.MAX_ERROR_BYTES, max_characters = 1000 }),
    detail = err.detail
        and util.safe_message(err.detail, { max_source_bytes = protocol.MAX_ERROR_BYTES, max_characters = 1000 })
      or nil,
  })
end

---@param result Neoagent.ProcessTargetCollection
---@return table
function M.encode(result)
  -- Only target facts cross this boundary. The parent owns its controller's
  -- worker cleanup independently of the worker-local target observation.
  local value = {
    done = result.done,
    released = result.released,
    stdin_writable = result.stdin_writable,
    resize_supported = result.resize_supported,
    outcome = util.copy(result.outcome),
    error = util.copy(result.error),
    cleanup_error = util.copy(result.cleanup_error),
    events = util.copy(result.events),
    dropped_bytes = result.dropped_bytes,
  }
  if value.error then
    value.error = wire_error(value.error)
  end
  if value.cleanup_error then
    value.cleanup_error = wire_error(value.cleanup_error)
  end
  return value
end

---@param value unknown
---@param maximum integer
---@return Neoagent.ProcessTargetCollection
function M.collection(value, maximum)
  object(value, {
    done = true,
    released = true,
    stdin_writable = true,
    resize_supported = true,
    outcome = false,
    error = false,
    cleanup_error = false,
    events = true,
    dropped_bytes = true,
  }, "Process collection")
  for _, field in ipairs({ "done", "released", "stdin_writable", "resize_supported" }) do
    assert(type(value[field]) == "boolean", "invalid process RPC state")
  end
  integer(value.dropped_bytes, 9007199254740991)
  assert(
    type(value.events) == "table" and util.is_list(value.events) and #value.events <= 128,
    "invalid process output events"
  )
  local bytes = 0
  for _, event in ipairs(value.events) do
    object(event, { stream = true, data = true }, "Process output event")
    assert(event.stream == "stdout" or event.stream == "stderr" or event.stream == "pty", "invalid process stream")
    assert(type(event.data) == "string", "process output must contain bytes")
    bytes = bytes + #event.data
    assert(bytes <= maximum, "process output exceeded its budget")
  end
  if value.outcome ~= nil then
    local outcome = value.outcome
    object(outcome, {
      code = true,
      signal = true,
      timed_out = true,
      started_at_ns = true,
      finished_at_ns = true,
      duration_ms = true,
      termination_reason = false,
    }, "Process outcome")
    integer(outcome.code, 4294967295)
    integer(outcome.signal, 127)
    for _, field in ipairs({ "started_at_ns", "finished_at_ns", "duration_ms" }) do
      assert(
        type(outcome[field]) == "number" and outcome[field] >= 0 and outcome[field] < math.huge,
        "invalid process outcome time"
      )
    end
    assert(outcome.finished_at_ns >= outcome.started_at_ns, "invalid process outcome interval")
    assert(type(outcome.timed_out) == "boolean", "invalid process timeout state")
    if outcome.termination_reason ~= nil then
      assert(
        type(outcome.termination_reason) == "string"
          and #outcome.termination_reason <= 4096
          and util.is_valid_utf8(outcome.termination_reason),
        "invalid process termination reason"
      )
    end
  end
  if value.error ~= nil then
    value.error = protocol.error(value.error)
  end
  if value.cleanup_error ~= nil then
    value.cleanup_error = protocol.error(value.cleanup_error)
  end
  assert(not value.done or value.outcome or value.error or value.cleanup_error, "completed process has no outcome")
  assert(
    not value.done or not value.stdin_writable and not value.resize_supported,
    "completed process accepts controls"
  )
  return util.copy(value)
end

---@param value unknown
---@return Neoagent.SubprocessSpec, integer
function M.start(value)
  object(value, { spec = true, output_bytes = true }, "Process start")
  assert(native.integer(value.output_bytes, 1, 262144), "invalid process output budget")
  local spec = plain(value.spec)
  if type(spec.stdio) == "table" then
    spec.stdio = plain(spec.stdio)
  end
  if type(spec.environment) == "table" then
    spec.environment = plain(spec.environment)
    if type(spec.environment.set) == "table" then
      spec.environment.set = plain(spec.environment.set)
    end
  end
  return native.spec(spec), value.output_bytes
end

---@param value unknown
---@return Neoagent.ProcessControl
function M.control(value)
  return require("neoagent.process_sessions.control").validate(plain(value))
end

---@param value unknown
---@return integer, boolean
function M.collect(value)
  object(value, { wait_ms = true, until_exit = true }, "Process collect")
  integer(value.wait_ms, 30000)
  assert(type(value.until_exit) == "boolean", "invalid process collection mode")
  return value.wait_ms, value.until_exit
end

return M
