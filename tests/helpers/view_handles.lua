local M = {}

---@param view? Neoagent.View|Neoagent.ProviderShellView
---@param key string
---@return {buffer?: integer, window?: integer}?
function M.native(view, key)
  local pane = view and view:pane(key) or nil
  return pane and pane:native() or nil
end

---@param view? Neoagent.View|Neoagent.ProviderShellView
---@param key string
---@return integer?
function M.buffer(view, key)
  local native = M.native(view, key)
  return native and native.buffer or nil
end

---@param view? Neoagent.View|Neoagent.ProviderShellView
---@param key string
---@return integer?
function M.window(view, key)
  local native = M.native(view, key)
  return native and native.window or nil
end

return M
