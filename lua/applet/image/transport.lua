local M = {}

---@alias Applet.ImageCommand table<string, string|number>
---@alias Applet.OutputCallback fun(err?: string)
---@alias Applet.CancelOutput fun()
---@alias Applet.ScheduleOutput fun(callback: Applet.OutputCallback): Applet.CancelOutput?

---@class Applet.OutputStream
---@field write fun(self: Applet.OutputStream, data: string): unknown, string?
---@field flush fun(self: Applet.OutputStream): unknown, string?

---@class Applet.TerminalNative
---@field ffi ffilib
---@field bits bitlib
---@field nonblocking integer

---@class Applet.TerminalConnection: Applet.TerminalNative
---@field fd integer

---@type Applet.TerminalNative?
local native
local O_WRONLY = 1
local F_SETFD = 2
local F_GETFL = 3
local F_SETFL = 4
local FD_CLOEXEC = 1
local nonblocking = ({
  Linux = 0x800,
  OSX = 0x4,
  BSD = 0x4,
})[jit and jit.os or ""]
if nonblocking then
  local loaded, value = pcall(require, "ffi")
  if loaded and pcall(value.cdef, [[
    int open(const char *path, int flags, ...);
    int close(int fd);
    int dup(int oldfd);
    int isatty(int fd);
    long write(int fd, const void *buffer, unsigned long count);
    int fcntl(int fd, int command, ...);
  ]]) then
    ---@cast value ffilib
    native = { ffi = value, bits = require("bit"), nonblocking = nonblocking }
  end
end

---@type Applet.TerminalConnection|false|nil
local terminal

---@return Applet.TerminalConnection?
local function terminal_descriptor()
  if terminal ~= nil then
    return terminal ~= false and terminal or nil
  end
  if not native then
    terminal = false
    return nil
  end
  local ffi = native.ffi
  local descriptor = ffi.C.open("/dev/tty", O_WRONLY)
  if descriptor < 0 then
    for _, candidate in ipairs({ 1, 2, 0 }) do
      if ffi.C.isatty(candidate) == 1 then
        descriptor = ffi.C.dup(candidate)
        break
      end
    end
  end
  if descriptor < 0
      or ffi.C.fcntl(descriptor, F_SETFD, FD_CLOEXEC) < 0 then
    if descriptor >= 0 then ffi.C.close(descriptor) end
    terminal = false
    return nil
  end
  terminal = {
    fd = descriptor, ffi = native.ffi, bits = native.bits,
    nonblocking = native.nonblocking,
  }
  return terminal
end

---@return integer?
local function builtin_tui_channel()
  local listed, uis = pcall(vim.api.nvim_list_uis)
  if not listed or type(uis) ~= "table" then return nil end
  for _, ui in ipairs(uis) do
    if type(ui.chan) == "number" and ui.stdin_tty == true
        and ui.stdout_tty == true then
      -- Neovim channel handles are integral, including those listed by the UI API.
      local id = ui.chan
      ---@cast id integer
      local inspected, channel = pcall(vim.api.nvim_get_chan_info, id)
      if inspected and type(channel) == "table"
          and channel.mode == "rpc" and channel.stream == "stdio" then
        return id
      end
    end
  end
end

---@return true?
---@return_overload false, string
local function synchronize_builtin_tui()
  local channel = builtin_tui_channel()
  if not channel then return nil end
  -- The built-in TUI acknowledges this request after processing earlier UI
  -- notifications. Its defined rejection provides an ordered output barrier.
  local acknowledged, result = pcall(vim.rpcrequest, channel, "redraw")
  if acknowledged or tostring(result):find(
      "'redraw' cannot be sent as a request", 1, true) then
    return true
  end
  return false, tostring(result)
end

---@return boolean
function M.available()
  return type(vim.api.nvim_ui_send) == "function"
    or (builtin_tui_channel() ~= nil and terminal_descriptor() ~= nil)
end

---@param data string
---@return boolean
local function descriptor_write(data)
  local connection = terminal_descriptor()
  if not connection then return false end
  local descriptor, ffi, bits = connection.fd, connection.ffi, connection.bits
  local synchronized, synchronize_error = synchronize_builtin_tui()
  if synchronized == nil then return false end
  if synchronized == false then
    error("terminal UI synchronization failed: " .. synchronize_error, 0)
  end
  local flags = ffi.C.fcntl(descriptor, F_GETFL)
  if flags < 0 then return false end
  local blocking_flags = bits.band(flags, bits.bnot(connection.nonblocking))
  if blocking_flags ~= flags
      and ffi.C.fcntl(descriptor, F_SETFL, blocking_flags) < 0 then
    return false
  end
  local pointer = ffi.cast("const unsigned char *", data)
  local interrupted = ({ Linux = 4, OSX = 4, BSD = 4 })[jit.os]
  ---@type number
  local offset = 0
  local failure
  while offset < #data do
    local count = tonumber(ffi.C.write(
      descriptor, pointer + offset, #data - offset))
    if count and count > 0 then
      offset = offset + count
    elseif count == -1 and ffi.errno() == interrupted then
      -- Retry a write interrupted before it transferred any bytes.
    else
      failure = "terminal output write failed"
      break
    end
  end
  if blocking_flags ~= flags
      and ffi.C.fcntl(descriptor, F_SETFL, flags) < 0 then
    failure = failure or "terminal output flags could not be restored"
  end
  if failure then error(failure, 0) end
  return true
end

---@param data string
---@return string
function M.base64(data)
  return vim.base64.encode(data)
end

---@param parameters? Applet.ImageCommand
---@param payload? string
---@return string
function M.command(parameters, payload)
  parameters = parameters or {}
  local keys = {}
  for key in pairs(parameters) do keys[#keys + 1] = key end
  table.sort(keys)
  local values = {}
  for _, key in ipairs(keys) do values[#values + 1] = key .. "=" .. tostring(parameters[key]) end
  return "\27_G" .. table.concat(values, ",") .. ";" .. (payload or "") .. "\27\\"
end

---@param command string
---@param kind? "tmux"
---@return string
function M.envelope(command, kind)
  if kind == "tmux" then
    return "\27Ptmux;" .. command:gsub("\27", "\27\27") .. "\27\\"
  end
  return command
end

---@param data string
---@param callback? Applet.OutputCallback
---@param stream? Applet.OutputStream
---@return true?
function M.write(data, callback, stream)
  if not stream and vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(data)
    return true
  end
  if not stream and descriptor_write(data) then return true end
  if not stream then error("serialized terminal output is unavailable", 0) end
  local written, write_error = stream:write(data)
  if not written then error(write_error or "terminal output write failed", 0) end
  local flushed, flush_error = stream:flush()
  if not flushed then error(flush_error or "terminal output flush failed", 0) end
end

---@param callback Applet.OutputCallback
---@return Applet.CancelOutput
function M.after_redraw(callback)
  assert(type(callback) == "function", "terminal output callback is required")
  local active = true
  vim.schedule(function()
    if not active then return end
    if type(vim.api.nvim_ui_send) == "function" then
      callback()
      return
    end
    local synchronized, synchronize_error = synchronize_builtin_tui()
    if synchronized ~= nil then
      if synchronized then
        callback()
      else
        callback("terminal UI synchronization failed: " .. synchronize_error)
      end
      return
    end
    callback("serialized terminal output is unavailable")
  end)
  return function() active = false end
end

---@param callback Applet.OutputCallback
---@return Applet.CancelOutput
function M.schedule(callback)
  assert(type(callback) == "function", "terminal output callback is required")
  local active = true
  ---@type Applet.CancelOutput?
  local cancel_wait
  vim.schedule(function()
    if not active then return end
    local redrawn, redraw_error = pcall(function() vim.cmd("redraw") end)
    if not redrawn then
      callback("terminal UI flush failed: " .. tostring(redraw_error))
      return
    end
    cancel_wait = M.after_redraw(function(err)
      if active then callback(err) end
    end)
  end)
  return function()
    active = false
    if cancel_wait then cancel_wait() end
  end
end

---@param data string
---@param size? integer
---@return string[]
function M.chunks(data, size)
  size = size or 4096
  local encoded, result = M.base64(data), {}
  if encoded == "" then return { "" } end
  for offset = 1, #encoded, size do
    result[#result + 1] = encoded:sub(offset, offset + size - 1)
  end
  return result
end

return M
