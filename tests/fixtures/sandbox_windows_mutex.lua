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
local name = dofile(vim.fs.joinpath(assert(vim.uv.cwd()), "scripts", "sandbox_windows_coordinator.lua")).mutex
local wide = (ffi.new("unsigned short[?]", #name + 1) --[[@as Neoagent.FfiArray<integer>]])
for index = 1, #name do wide[index - 1] = name:byte(index) end
local mutex = kernel.CreateMutexW(nil, 0, wide)
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
assert(observed, "authority contention test did not release its mutex")
