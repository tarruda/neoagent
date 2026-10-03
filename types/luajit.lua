---@meta

-- LuaJIT also accepts the hook-first form. A hook registered directly with
-- lua_sethook is reported as "external hook", not as a callable Lua value.
---@class debuglib
---@field gethook fun(thread?: thread): function|string|nil, string, integer
---@field sethook fun(hook?: function, mask?: string, count?: integer)
