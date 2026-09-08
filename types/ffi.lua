---@meta

-- Zero-based native arrays and pointers, with element types supplied at
-- allocation/cast boundaries. Unlike Lua tables, allocated slots are present.
---@class Neoagent.FfiArray<T>: ffi.cdata*
---@field [integer] T
