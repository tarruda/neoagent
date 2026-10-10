-- Loaded only by native worker tests during coverage collection. Keep test
-- instrumentation out of the production worker bootstrap and environment.
local script = assert(debug.getinfo(1, "S")).source:sub(2)
local root = assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(script))))))
package.path = table.concat({
  root .. "/?.lua",
  root .. "/.deps/coverage-native/cluacov/src/?.lua",
  root .. "/.deps/luacov/src/?.lua",
  root .. "/.deps/luacov/src/?/init.lua",
  package.path,
}, ";")
package.cpath = root .. "/.deps/coverage-native/lib/?.so;" .. package.cpath
local config = dofile(root .. "/scripts/luacov_config.lua")
config.statsfile = root .. "/.coverage/raw/" .. vim.uv.os_getpid() .. ".out"
local runner = require("luacov.runner")
runner(config)
require("tests.helpers.work_coverage").install(config)
vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function() runner.shutdown() end,
})
