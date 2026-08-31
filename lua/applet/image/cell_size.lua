local M = {}

local requests = {
  Linux = 0x5413,
  OSX = 0x40087468,
  BSD = 0x40087468,
}

local request = requests[jit and jit.os or ""]
local ffi
if request then
  local loaded, value = pcall(require, "ffi")
  if loaded and pcall(value.cdef, [[
    struct applet_winsize {
      unsigned short ws_row;
      unsigned short ws_col;
      unsigned short ws_xpixel;
      unsigned short ws_ypixel;
    };
    int ioctl(int fd, unsigned long request, ...);
  ]]) then
    ffi = value
  end
end

function M.get()
  if not ffi then return nil end
  local measured, value = pcall(function()
    local size = ffi.new("struct applet_winsize[1]")
    if ffi.C.ioctl(1, request, size) ~= 0 then return nil end
    local result = size[0]
    if result.ws_row == 0 or result.ws_col == 0
        or result.ws_xpixel == 0 or result.ws_ypixel == 0 then
      return nil
    end
    return {
      width = result.ws_xpixel / result.ws_col,
      height = result.ws_ypixel / result.ws_row,
      screen_width = tonumber(result.ws_xpixel),
      screen_height = tonumber(result.ws_ypixel),
      columns = tonumber(result.ws_col),
      rows = tonumber(result.ws_row),
    }
  end)
  return measured and value or nil
end

return M
