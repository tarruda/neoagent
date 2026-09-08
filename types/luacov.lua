---@meta luacov.runner

-- The pinned LuaCov runner surface used by the test bootstrap and report target.
---@class LuaCov.Configuration
---@field statsfile? string
---@field reportfile? string
---@field include? string[]
---@field exclude? string[]
---@field modules? table<string, string>
---@field includeuntestedfiles? boolean

---@class LuaCov.Runner
---@overload fun(configuration?: string|LuaCov.Configuration)
local runner = {}

---@param configuration? string|LuaCov.Configuration
function runner.init(configuration) end

function runner.shutdown() end

---@param configuration? string|LuaCov.Configuration
function runner.run_report(configuration) end

return runner
