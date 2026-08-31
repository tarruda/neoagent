local util = require("applet.util")

local M = {}

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

local function revision(source)
  local kind = type(source.revision)
  util.expect(kind == "number" or kind == "string",
    "image.source.revision", "must be a number or string", 4)
  if kind == "number" then
    util.expect(source.revision == source.revision
        and source.revision ~= math.huge and source.revision ~= -math.huge,
      "image.source.revision", "must be finite", 4)
  end
  local value = tostring(source.revision)
  return kind == "number" and "number:" .. value or "string:" .. value
end

local function component(value)
  return tostring(#value) .. ":" .. value
end

function M.identity(source)
  util.expect(type(source) == "table", "image.source", "must be a table", 3)
  local rev = revision(source)
  if source.kind == "png_bytes" then
    util.expect(util.nonempty_string(source.id), "image.source.id",
      "must be a non-empty string", 3)
    util.expect(type(source.data) == "string", "image.source.data", "must be a string", 3)
    return "bytes:" .. component(source.id) .. component(rev)
  end
  util.expect(source.kind == "png_file", "image.source.kind",
    "must be png_bytes or png_file", 3)
  util.expect(util.nonempty_string(source.path), "image.source.path",
    "must be a non-empty string", 3)
  return "file:" .. component(source.path) .. component(rev)
end

local function uint32(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

function M.png_info(data, limits)
  limits = limits or {}
  util.expect(type(data) == "string", "PNG data", "must be a string", 3)
  util.expect(#data <= (limits.max_bytes or 20 * 1024 * 1024),
    "PNG data", "exceeds the byte limit", 3)
  util.expect(data:sub(1, 8) == PNG_SIGNATURE, "PNG data", "has an invalid signature", 3)
  util.expect(data:sub(13, 16) == "IHDR", "PNG data", "has no IHDR header", 3)
  local width, height = uint32(data, 17), uint32(data, 21)
  util.expect(width and width > 0 and height and height > 0,
    "PNG data", "has invalid dimensions", 3)
  util.expect(width * height <= (limits.max_pixels or 40 * 1000 * 1000),
    "PNG data", "exceeds the pixel limit", 3)
  return { width = width, height = height, bytes = #data }
end

local function default_read(path, maximum)
  local handle, err = io.open(path, "rb")
  if not handle then return nil, err end
  local data = handle:read(maximum + 1)
  handle:close()
  if #data > maximum then return nil, "file exceeds the byte limit" end
  return data
end

function M.load(source, opts)
  opts = opts or {}
  local identity = M.identity(source)
  local maximum = opts.max_bytes or 20 * 1024 * 1024
  local data, err
  if source.kind == "png_bytes" then
    data = source.data
  else
    data, err = (opts.read_file or default_read)(source.path, maximum)
  end
  if not data then return nil, err or "could not read image" end
  local ok, info = pcall(M.png_info, data, {
    max_bytes = maximum,
    max_pixels = opts.max_pixels,
  })
  if not ok then return nil, info end
  return {
    id = identity,
    data = data,
    width = info.width,
    height = info.height,
    bytes = info.bytes,
  }
end

function M.load_async(value, opts, done)
  opts = opts or {}
  assert(type(done) == "function", "image load callback must be a function")
  local cancelled, completed = false, false
  local function finish(resource, err)
    if cancelled or completed then return end
    completed = true
    done(resource, err)
  end
  local function later(callback)
    vim.schedule(function()
      if not cancelled and not completed then callback() end
    end)
  end
  local function cancel()
    if not completed then cancelled = true end
  end
  local ok, identity = pcall(M.identity, value)
  if not ok then
    later(function() finish(nil, identity) end)
    return cancel
  end
  if value.kind == "png_bytes" then
    later(function()
      local resource, err = M.load(value, opts)
      finish(resource, err)
    end)
    return cancel
  end
  if opts.read_file then
    later(function()
      local resource, err = M.load(value, opts)
      finish(resource, err)
    end)
    return cancel
  end
  local uv = opts.uv or vim.uv or vim.loop
  local handle
  local function close(after)
    local open = handle
    handle = nil
    if not open then
      if after and not cancelled then after() end
      return
    end
    uv.fs_close(open, function(err)
      if after and not cancelled then after(err) end
    end)
  end
  uv.fs_open(value.path, "r", 438, function(open_err, opened)
    handle = opened
    if cancelled then close() return end
    if open_err or not handle then
      finish(nil, open_err or "could not open image")
      return
    end
    uv.fs_fstat(handle, function(stat_err, stat)
      if cancelled then close() return end
      if stat_err or not stat then
        close(function()
          finish(nil, stat_err or "could not inspect image")
        end)
        return
      end
      local maximum = opts.max_bytes or 20 * 1024 * 1024
      if stat.size > maximum then
        close(function()
          finish(nil, "file exceeds the byte limit")
        end)
        return
      end
      uv.fs_read(handle, maximum + 1, 0, function(read_err, data)
        if cancelled then close() return end
        close(function(close_err)
          if close_err then
            finish(nil, close_err)
            return
          end
          if read_err or not data then
            finish(nil, read_err or "could not read image")
            return
          end
          local info_ok, info = pcall(M.png_info, data, {
            max_bytes = maximum,
            max_pixels = opts.max_pixels,
          })
          if not info_ok then
            finish(nil, info)
            return
          end
          finish({
            id = identity,
            data = data,
            width = info.width,
            height = info.height,
            bytes = info.bytes,
          })
        end)
      end)
    end)
  end)
  return cancel
end

return M
