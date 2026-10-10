local util = require("neoagent.util")

local M = {}

M.WRITE_BYTES = 64 * 1024
M.PENDING_BYTES = 1024 * 1024
M.PENDING_WRITES = 64
M.OUTPUT_BYTES = 64 * 1024
M.REAP_MS = 2000
M.START_MS = 5000
M.KILL_GRACE_MS = 1000
M.MAX_TIMEOUT_MS = 2147483647

---@param code string
---@param message string
---@return Neoagent.Error
function M.error(code, message)
  return { kind = code, code = code, message = message }
end

---@param condition unknown
---@param message string
---@param code? string
local function check(condition, message, code)
  if not condition then
    error(M.error(code or "process_validation", message), 0)
  end
end

---@param value unknown
---@param fields table<string, boolean>
---@param name string
function M.fields(value, fields, name)
  check(type(value) == "table" and getmetatable(value) == nil, name .. " must be a plain table")
  for key in pairs(value) do
    check(fields[key], name .. " contains an unknown field")
  end
end

---@param value unknown
---@param minimum integer
---@param maximum integer
---@return boolean
function M.integer(value, minimum, maximum)
  return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

---@param value unknown
---@param empty? boolean
---@return boolean
function M.string(value, empty)
  return type(value) == "string" and (empty or value ~= "") and not value:find("\0", 1, true)
end

---@param columns unknown
---@param rows unknown
function M.dimensions(columns, rows)
  local maximum = jit.os == "Windows" and 32767 or 65535
  check(
    M.integer(columns, 1, maximum) and M.integer(rows, 1, maximum),
    "Terminal dimensions must be integers from 1 to " .. maximum,
    "invalid_terminal_size"
  )
end

---@param value unknown
---@return string
function M.reason(value)
  check(M.string(value), "A non-empty termination reason is required")
  return util.safe_message(value, { max_characters = 256, max_source_bytes = 1024 })
end

---@class Neoagent.SubprocessEnvironment
---@field inherit boolean
---@field set table<string, string>

---@alias Neoagent.SubprocessStdio {kind: "pipes", stdin?: "closed"|"open"}|{kind: "pty", columns: integer, rows: integer}

---@class Neoagent.SubprocessSpec
---@field argv string[]
---@field cwd string
---@field environment? Neoagent.SubprocessEnvironment
---@field stdio Neoagent.SubprocessStdio
---@field timeout_ms? integer
---@field kill_grace_ms? integer

---@class Neoagent.ValidatedSubprocessSpec: Neoagent.SubprocessSpec
---@field kill_grace_ms integer

---@param value unknown
---@return Neoagent.ValidatedSubprocessSpec
function M.spec(value)
  M.fields(
    value,
    { argv = true, cwd = true, environment = true, stdio = true, timeout_ms = true, kill_grace_ms = true },
    "Process spec"
  )
  check(
    type(value.argv) == "table" and util.is_list(value.argv) and #value.argv > 0,
    "Process argv must be a non-empty list"
  )
  for index, argument in ipairs(value.argv) do
    check(M.string(argument, index > 1), "Process argv must contain NUL-free strings")
  end
  check(M.string(value.cwd), "Process cwd must be a non-empty NUL-free string")
  local stat = vim.uv.fs_stat(value.cwd)
  check(stat and stat.type == "directory", "Process cwd must identify a directory")
  if value.environment ~= nil then
    M.fields(value.environment, { inherit = true, set = true }, "Process environment")
    check(type(value.environment.inherit) == "boolean", "Process environment inherit must be boolean")
    check(
      type(value.environment.set) == "table" and getmetatable(value.environment.set) == nil,
      "Process environment set must be a plain table"
    )
    for name, entry in pairs(value.environment.set) do
      check(
        M.string(name) and (not name:find("=", 1, true) or jit.os == "Windows" and name:match("^=[A-Za-z]:$") ~= nil),
        "Invalid process environment name"
      )
      check(M.string(entry, true), "Process environment values must be NUL-free strings")
    end
  end
  check(type(value.stdio) == "table", "Process stdio is required")
  if value.stdio.kind == "pipes" then
    M.fields(value.stdio, { kind = true, stdin = true }, "Pipe stdio")
    check(
      value.stdio.stdin == nil or value.stdio.stdin == "closed" or value.stdio.stdin == "open",
      "Pipe stdin must be closed or open"
    )
  else
    M.fields(value.stdio, { kind = true, columns = true, rows = true }, "PTY stdio")
    check(value.stdio.kind == "pty", "Process stdio kind must be pipes or pty")
    M.dimensions(value.stdio.columns, value.stdio.rows)
  end
  check(
    value.timeout_ms == nil or M.integer(value.timeout_ms, 1, M.MAX_TIMEOUT_MS),
    "Process timeout must be a positive integer no greater than 2147483647"
  )
  check(
    value.kill_grace_ms == nil or M.integer(value.kill_grace_ms, 0, 60000),
    "Process kill grace must be an integer from 0 to 60000"
  )
  ---@cast value Neoagent.SubprocessSpec
  local result = util.copy(value)
  result.kill_grace_ms = result.kill_grace_ms or M.KILL_GRACE_MS
  return result
end

---@class Neoagent.SubprocessOutputEvent
---@field stream "stdout"|"stderr"|"pty"
---@field data string

---@class Neoagent.SubprocessObserver
---@field on_output? fun(event: Neoagent.SubprocessOutputEvent)

---@param value? Neoagent.SubprocessObserver
---@return Neoagent.SubprocessObserver
function M.observer(value)
  value = value or {}
  M.fields(value, { on_output = true }, "Process observer")
  check(value.on_output == nil or type(value.on_output) == "function", "Process output observer must be a function")
  return { on_output = value.on_output }
end

---@class Neoagent.SubprocessRunOptions
---@field capture false|{max_bytes: integer}
---@field input? Neoagent.SubprocessInput
---@field on_output? fun(event: Neoagent.SubprocessOutputEvent)

---@class Neoagent.SubprocessInput
---@field chunks string[]
---@field close boolean
---@field allow_early_close? boolean Accept partial input consumption and await the process outcome.

---@param spec Neoagent.SubprocessSpec
---@param value Neoagent.SubprocessRunOptions
---@return Neoagent.SubprocessRunOptions
function M.run(spec, value)
  M.fields(value, { capture = true, input = true, on_output = true }, "Process run options")
  if value.capture ~= false then
    M.fields(value.capture, { max_bytes = true }, "Process capture")
    check(M.integer(value.capture.max_bytes, 1, 2147483647), "Process capture requires a positive byte limit")
  end
  M.observer({ on_output = value.on_output })
  if value.input ~= nil then
    M.fields(value.input, { chunks = true, close = true, allow_early_close = true }, "Process input")
    check(
      type(value.input.chunks) == "table" and util.is_list(value.input.chunks),
      "Process input chunks must be a list"
    )
    for _, chunk in ipairs(value.input.chunks) do
      check(type(chunk) == "string", "Process input chunks must be strings")
    end
    check(type(value.input.close) == "boolean", "Process input close must be boolean")
    check(
      value.input.allow_early_close == nil or type(value.input.allow_early_close) == "boolean",
      "Process input allow_early_close must be boolean"
    )
    check(spec.stdio.kind == "pty" or spec.stdio.stdin == "open", "Initial input requires writable stdin")
    check(spec.stdio.kind ~= "pty" or not value.input.close, "PTY input cannot close stdin")
  end
  return util.copy(value)
end

return M
