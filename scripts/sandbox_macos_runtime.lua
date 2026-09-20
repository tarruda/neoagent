local exit = os.exit --[[@as fun(status?: integer): never]]

---@param message string
---@return never
local function fail(message)
  io.stderr:write("neoagent macOS sandbox runtime: ", message, "\n")
  return exit(70)
end

if jit.os ~= "OSX" then
  fail("macOS is required")
end

local source = assert(debug.getinfo(1, "S")).source:sub(2)
local root = assert(vim.fs.dirname(assert(vim.fs.dirname(source))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local protocol = require("neoagent.sandbox.protocol")
local ffi = require("ffi")

ffi.cdef([[
typedef struct { uint32_t val[8]; } neoagent_audit_token;
typedef struct {
  uint8_t uuid[16];
  uint64_t uniqueid, parent_uniqueid;
  uint32_t idversion, parent_idversion;
  uint64_t reserved[2];
} neoagent_proc_identity;
typedef struct {
  uint32_t pid, ppid, pgid, status;
  char command[16];
  uint32_t flags, uid, gid, ruid, rgid, svuid, svgid, reserved;
} neoagent_proc_status;
int proc_listallpids(void *, int);
int proc_pidinfo(int, int, uint64_t, void *, int);
int proc_signal_with_audittoken(neoagent_audit_token *, int);
int sandbox_check_by_audit_token(neoagent_audit_token, const char *, int, ...);
extern int SANDBOX_CHECK_NO_REPORT;
]])

local proc = ffi.load("/usr/lib/libproc.dylib")
local sandbox = ffi.load("/usr/lib/libsandbox.dylib")
local available = pcall(function()
  assert(proc.proc_signal_with_audittoken)
  assert(sandbox.sandbox_check_by_audit_token)
end)
if not available then
  fail("stable process identity APIs are unavailable")
end

local encoded = vim.env.NEOAGENT_MACOS_SANDBOX_SPEC
vim.env.NEOAGENT_MACOS_SANDBOX_SPEC = nil
if type(encoded) ~= "string" or #encoded > 1024 * 1024 then
  fail("invalid specification")
end
local decoded, spec = pcall(vim.json.decode, encoded)
if not decoded or type(spec) ~= "table" then
  fail("invalid specification")
end
if spec.mode ~= "run" and spec.mode ~= "cleanup" and spec.mode ~= "probe" then
  fail("invalid mode")
end
if
  spec.mode ~= "probe"
  and (type(spec.scope) ~= "string" or not spec.scope:match("^neoagent%.sandbox%.%x+$") or #spec.scope ~= 49)
then
  fail("invalid scope")
end

local MAX_PROCESSES = 65536
local CLEANUP_MS = 5000
local MAX_QUEUED_BYTES = 24 * 1024 * 1024
local pids = ffi.new("int[?]", MAX_PROCESSES) --[[@as Neoagent.FfiArray<integer>]]
local identity = ffi.new("neoagent_proc_identity") --[[@as {idversion: integer}]]
local status = ffi.new("neoagent_proc_status") --[[@as {status: integer}]]
local token = ffi.new("neoagent_audit_token") --[[@as {val: Neoagent.FfiArray<integer>}]]
local lookup_filter = bit.bor(2, assert(tonumber(sandbox.SANDBOX_CHECK_NO_REPORT)) --[[@as integer]])

local self_pid = vim.fn.getpid()
local usable = pcall(function()
  assert(proc.proc_pidinfo(self_pid, 17, 0, identity, 56) == 56)
  token.val[5], token.val[7] = self_pid, identity.idversion
  assert(sandbox.sandbox_check_by_audit_token(token, nil, 0) == 0)
  assert(proc.proc_signal_with_audittoken(token, 0) == 22) -- EINVAL; no signal is sent.
end)
if not usable then
  fail("protected process supervision is unavailable")
end
if spec.mode == "probe" then
  exit(0)
end

-- The scope is an inert, unique Mach lookup grant in the worker's immutable
-- policy. Audit tokens bind both the policy query and signal to one process
-- incarnation, including descendants that changed session or parent.
---@param pid integer
---@return boolean? Nil requests another scan after an exit or exec race.
local function in_scope(pid)
  if pid <= 0 then
    return false
  end
  if proc.proc_pidinfo(pid, 13, 1, status, 64) == 64 and status.status == 5 then
    return false -- SZOMB has no remaining effects.
  end
  if proc.proc_pidinfo(pid, 17, 0, identity, 56) ~= 56 then
    if ffi.errno() == 3 then
      return nil
    end
    return false
  end
  local version = identity.idversion
  token.val[5], token.val[7] = pid, identity.idversion
  -- A definitive policy mismatch already excludes this incarnation. Its
  -- subsequent exec or exit must not keep this invocation's cleanup pending.
  -- Unclassified disappearances still require another scan: their children
  -- may have been created after the process list was captured.
  local sandboxed = sandbox.sandbox_check_by_audit_token(token, nil, 0)
  if sandboxed == 0 then
    return false
  end
  local permitted = sandboxed == 1
      and sandbox.sandbox_check_by_audit_token(
        token,
        "mach-lookup",
        lookup_filter,
        ffi.cast("const char *", spec.scope)
      )
    or nil
  if permitted == 1 then
    return false
  end
  local absent = permitted == 0
      and sandbox.sandbox_check_by_audit_token(
        token,
        "mach-lookup",
        lookup_filter,
        ffi.cast("const char *", spec.scope .. ".absent")
      )
    or nil
  if absent == 0 then
    return false
  end
  if proc.proc_pidinfo(pid, 17, 0, identity, 56) ~= 56 or identity.idversion ~= version then
    return nil
  end
  return absent == 1
end

---@return boolean
local function terminate_scope()
  local count = tonumber(proc.proc_listallpids(pids, ffi.sizeof(pids)))
  if not count or count <= 0 or count >= MAX_PROCESSES then
    fail("could not enumerate processes")
  end
  local remaining = false
  for index = 0, count - 1 do
    local pid = pids[index]
    local selected = in_scope(pid)
    if selected == nil then
      remaining = true
    elseif selected then
      remaining = true
      local err = tonumber(proc.proc_signal_with_audittoken(token, 9))
      if err ~= 0 and err ~= 3 then
        fail("could not terminate sandbox process")
      end -- ESRCH
    end
  end
  return not remaining
end

---@return boolean
local function cleanup()
  return (vim.wait(CLEANUP_MS, terminate_scope, 10))
end

if spec.mode == "cleanup" then
  if not cleanup() then
    fail("sandbox process cleanup timed out")
  end
  exit(0)
end
if type(spec.argv) ~= "table" or #spec.argv == 0 or type(spec.env) ~= "table" or type(spec.cwd) ~= "string" then
  fail("invalid worker specification")
end

local failed = false
local stop_signal
local pending_bytes = 0
local stdout = assert(vim.uv.new_pipe(false))
stdout:open(1)
local sequence = 0
---@param event table
local function send(event)
  if failed then
    return
  end
  event.v = 1
  local bytes = protocol.encode(event)
  if pending_bytes + #bytes > MAX_QUEUED_BYTES then
    failed = true
    return
  end
  pending_bytes = pending_bytes + #bytes
  stdout:write(bytes, function(err)
    pending_bytes = pending_bytes - #bytes
    if err then
      failed = true
    end
  end)
end

---@type uv.uv_signal_t[]
local signals = {}
for _, signal in ipairs({ 1, 2, 15 }) do
  local watcher = assert(vim.uv.new_signal())
  watcher:start(signal, function()
    stop_signal = stop_signal or signal
  end)
  signals[#signals + 1] = watcher
end

local input = assert(vim.uv.new_pipe(false))
local child_input = assert(vim.uv.new_pipe(false))
local child_stdout = assert(vim.uv.new_pipe(false))
local child_stderr = assert(vim.uv.new_pipe(false))
local admission = assert(vim.uv.new_pipe(false))
local environment = {}
for name, value in pairs(spec.env) do
  environment[#environment + 1] = name .. "=" .. value
end
---@type {code: integer, signal: integer}?
local completed
local child_options = {
  args = vim.list_slice(spec.argv, 2),
  cwd = spec.cwd,
  env = environment,
  detached = false,
  stdio = { child_input, child_stdout, child_stderr, admission },
}
local child = vim.uv.spawn(spec.argv[1], child_options --[[@as uv.spawn.options]], function(code, signal)
  completed = { code = code, signal = signal }
end)
if not child then
  send({ type = "error", stage = "worker-start", errno = 0 })
  failed = true
else
  local ready = ""
  local admission_closed = false
  admission:read_start(function(err, data)
    if err or not data then
      admission_closed = true
    else
      ready = (ready .. data):sub(1, 7)
    end
  end)
  local admitted = vim.wait(5000, function()
    return ready == "ready\n" or #ready > 6 or admission_closed or stop_signal ~= nil
  end, 10)
  admission:read_stop()
  if not admitted or ready ~= "ready\n" or stop_signal then
    failed = true
  else
    send({ type = "ready" })
  end
end
admission:close()

local streams = 2
---@param pipe uv.uv_pipe_t
---@param stream string
local function read_output(pipe, stream)
  pipe:read_start(function(err, data)
    if err then
      failed = true
    end
    if data then
      sequence = sequence + 1
      send({ type = "output", stream = stream, seq = sequence, data = data })
    else
      streams = streams - 1
      pipe:read_stop()
      pipe:close()
    end
  end)
end
if child then
  read_output(child_stdout, "stdout")
  read_output(child_stderr, "stderr")
  local input_decoder = protocol.input_decoder(function(data)
    child_input:write(data, function(err)
      if err then
        failed = true
      end
    end)
  end, function()
    child_input:shutdown(function()
      if not child_input:is_closing() then
        child_input:close()
      end
    end)
  end)
  input:open(0)
  input:read_start(function(err, data)
    if failed then
      return
    end
    if err then
      failed = true
    end
    if data then
      local accepted = pcall(input_decoder.feed, input_decoder, data)
      if not accepted then
        failed = true
      end
    else
      input:read_stop()
      input:close()
      -- The owner keeps this control pipe open after logical stdin closure.
      -- Its physical EOF revokes the lease independently of the RPC session.
      if not input_decoder:finish() then
        failed = true
      end
      stop_signal = stop_signal or 15
    end
  end)
end

while child and not completed and not failed and not stop_signal do
  vim.wait(100, function()
    return completed ~= nil or failed or stop_signal ~= nil
  end, 10)
end
if child and not completed then
  child:kill(9)
end
local cleaned = cleanup()
if child then
  local drained = vim.wait(CLEANUP_MS, function()
    return completed ~= nil and streams == 0
  end, 10)
  if not drained then
    failed = true
  end
end
if not cleaned then
  failed = true
end
for _, watcher in ipairs(signals) do
  watcher:stop()
  watcher:close()
end
for _, pipe in ipairs({ input, child_input, child_stdout, child_stderr }) do
  if not pipe:is_closing() then
    pipe:close()
  end
end
if child and not child:is_closing() then
  child:close()
end
if not failed then
  local result = assert(completed)
  send({ type = "exit", code = result.signal ~= 0 and 128 + result.signal or result.code, signal = result.signal })
end
local flushed = vim.wait(CLEANUP_MS, function()
  return pending_bytes == 0
end, 10)
stdout:close()
if failed or not flushed then
  fail("worker or cleanup failed")
end
exit(0)
