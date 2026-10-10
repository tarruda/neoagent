local script = assert(debug.getinfo(1, "S")).source:sub(2)
local root = assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(script))))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("neoagent.subprocess.posix_child")
local ffi = require("ffi")
local C = ffi.C --[[@as Neoagent.ChildWaitApi]]
local gate = assert(vim.env.NEOAGENT_TEST_REAP_GATE)
local api = setmetatable({
  waitpid = function(pid, status, flags)
    if vim.uv.fs_stat(gate) then
      local _ = ffi.errno(1)
      return -1
    end
    return C.waitpid(pid, status, flags)
  end,
}, { __index = ffi.C })
package.loaded.ffi = setmetatable({ C = api, cdef = function() end }, { __index = ffi })
package.loaded["neoagent.subprocess.posix_child"] = nil
require("neoagent.subprocess.posix_child")
package.loaded.ffi = ffi
dofile(root .. "/scripts/tool_worker.lua")
