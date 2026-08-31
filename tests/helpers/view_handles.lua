local M = {}

function M.native(view, key)
  local pane = view and view:pane(key) or nil
  return pane and pane:native() or nil
end

function M.buffer(view, key)
  local native = M.native(view, key)
  return native and native.buffer or nil
end

function M.window(view, key)
  local native = M.native(view, key)
  return native and native.window or nil
end

return M
