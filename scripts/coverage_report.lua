-- LuaCov remains the coverage measure. Its official C extension identifies
-- executable lines from bytecode, including nested functions, without running
-- shipped modules merely to make them appear in the report.
package.path = ".deps/coverage-native/cluacov/src/?.lua;.deps/luacov/src/?.lua;.deps/luacov/src/?/init.lua;"
  .. package.path
package.cpath = ".deps/coverage-native/lib/?.so;" .. package.cpath
assert(require("cluacov.deepactivelines"), "run make coverage-deps before generating coverage reports")
local config = dofile("scripts/luacov_config.lua")
config.statsfile = ".coverage/luacov.stats.out"
require("luacov.runner").run_report(config)
