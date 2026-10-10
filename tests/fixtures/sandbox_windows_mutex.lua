-- Hold the real authority mutex until the test releases stdin. No sandbox
-- token or ACL behavior is substituted in the contending runtime.
local ffi = require("ffi")
ffi.cdef([[
void * __stdcall CreateMutexW(void *, int, const unsigned short *);
unsigned long __stdcall WaitForSingleObject(void *, unsigned long);
int __stdcall ReleaseMutex(void *);
int __stdcall CloseHandle(void *);
]])
local kernel = ffi.load("kernel32")
local checkout = assert(vim.uv.cwd())
local coordinator = dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_coordinator.lua"))
local objects = dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_objects.lua"))
local file = assert(io.open(vim.fs.joinpath(assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json"), "rb"))
local state = vim.json.decode((file:read("*a")))
file:close()
---@param text string
local function wide(text)
  local value = ffi.new("unsigned short[?]", #text + 1) --[[@as Neoagent.FfiArray<integer>]]
  for index = 1, #text do value[index - 1] = text:byte(index) end
  return value
end
local namespace = objects.new(coordinator.namespace, {
  identity = state.owner_sid, wide = wide,
  failure = function(stage, code) error(stage .. ": " .. tostring(code)) end,
})
namespace:join(vim.uv.hrtime() + 10000000000)
local mutex = kernel.CreateMutexW(nil, 0, wide(namespace:path("journal")))
assert(mutex ~= nil)
local status = kernel.WaitForSingleObject(mutex, 10000)
assert(status == 0 or status == 0x80)
local input = assert(vim.uv.new_pipe(false))
assert(input:open(0))
local released = false
input:read_start(function() released = true end)
io.stdout:write("LOCKED\n")
io.stdout:flush()
local observed = vim.wait(30000, function() return released end, 10)
input:read_stop()
input:close()
assert(kernel.ReleaseMutex(mutex) ~= 0)
kernel.CloseHandle(mutex)
namespace:close(false)
assert(observed, "authority contention test did not release its mutex")
