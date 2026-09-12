local async = require("neoagent.async")
local common = require("neoagent.tools.common")
local presentation = require("neoagent.tools.activity_presentation")
local truncate = require("neoagent.tools.truncate")
local util = require("neoagent.util")

---@alias Neoagent.FileImageMime "image/png"|"image/jpeg"|"image/gif"|"image/webp"|"image/bmp"

---@class Neoagent.ReadFileOptions
---@field max_image_input_bytes? integer
---@field max_image_pixels? integer
---@field max_image_output_bytes? integer

---@class Neoagent.ReadFileSettings
---@field max_image_input_bytes integer
---@field max_image_pixels integer
---@field max_image_output_bytes integer

---@class Neoagent.ProcessedImage
---@field data string
---@field mime_type Neoagent.FileImageMime
---@field note string

local MIME = {
  png = "image/png",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  bmp = "image/bmp",
}

local MAGICK_FORMAT = {
  [MIME.png] = "png",
  [MIME.jpeg] = "jpeg",
  [MIME.gif] = "gif",
  [MIME.webp] = "webp",
  [MIME.bmp] = "bmp",
}

---@param data string
---@return Neoagent.FileImageMime?
local function detect(data)
  if data:sub(1, 8) == "\137PNG\r\n\26\n" then
    return MIME.png
  end
  if data:sub(1, 3) == "\255\216\255" then
    return MIME.jpeg
  end
  if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
    return MIME.gif
  end
  if data:sub(1, 2) == "BM" then
    return MIME.bmp
  end
  if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
    return MIME.webp
  end
end

local DEFAULT_MAX_IMAGE_INPUT_BYTES = 20 * 1024 * 1024
local DEFAULT_MAX_IMAGE_PIXELS = 40 * 1000 * 1000
-- Retained snapshots must also fit inline requests after uploads are disabled.
-- This binary budget leaves room for base64 within a 4.5 MiB payload.
local DEFAULT_MAX_IMAGE_OUTPUT_BYTES = 4.5 * 1024 * 1024 / 4 * 3
local IMAGE_TIMEOUT_MS = 30000
local IDENTIFY_CAPTURE_BYTES = 64 * 1024

---@async
---@param data string
---@param mime Neoagent.FileImageMime
---@param note string
---@param max_output_bytes integer
---@param files Neoagent.Files
---@param filename string
---@return Neoagent.ToolResult
local function image_result(data, mime, note, max_output_bytes, files, filename)
  if #data > max_output_bytes then
    error("image output exceeds " .. max_output_bytes .. " bytes")
  end
  local stored, err = files.put(data)
  if not stored then
    error(err, 0)
  end
  -- Filesystem names need not be safe semantic metadata. The snapshot remains
  -- usable even when its optional display filename cannot be retained.
  local display_filename = #filename <= 512 and util.is_valid_utf8(filename) and not filename:find("[%c]") and filename
    or nil
  return {
    content = {
      { type = "text", text = note },
      { type = "image", file_id = stored.file_id, bytes = stored.bytes, mime_type = mime, filename = display_filename },
    },
  }
end

---@param filesystem Neoagent.ToolFilesystem
---@param path string
---@param on_chunk fun(data: string)
---@return true?, unknown
local function stream(filesystem, path, on_chunk)
  if type(filesystem.read_chunks) == "function" then
    return filesystem.read_chunks(path, on_chunk)
  end
  local data, err = filesystem.read(path)
  if not data then
    return nil, err
  end
  on_chunk(data)
  return true
end

---@param settings Neoagent.ReadFileSettings
---@param operation? string
---@param arguments string[]
---@return string[]
local function magick_command(settings, operation, arguments)
  local command = { "magick" }
  if operation then
    command[#command + 1] = operation
  end
  vim.list_extend(command, {
    "-limit",
    "memory",
    "128MiB",
    "-limit",
    "map",
    "256MiB",
    "-limit",
    "disk",
    "0",
    "-limit",
    "area",
    tostring(settings.max_image_pixels),
  })
  return vim.list_extend(command, arguments)
end

---@async
---@param data string
---@param ctx Neoagent.ToolCapabilities
---@param settings Neoagent.ReadFileSettings
---@param operation? string
---@param arguments string[]
---@param max_capture_bytes integer
---@return string
local function process_magick(data, ctx, settings, operation, arguments, max_capture_bytes)
  local result = common.process(ctx, magick_command(settings, operation, arguments), {
    stdin = data,
    timeout_ms = IMAGE_TIMEOUT_MS,
    kill_grace_ms = 100,
    max_capture_bytes = max_capture_bytes,
  })
  if result.timed_out then
    error("ImageMagick timed out")
  end
  local code = tonumber(result.code) or -1
  if code ~= 0 then
    local stderr = type(result.stderr) == "string" and result.stderr or ""
    error(stderr ~= "" and stderr or "ImageMagick exited with " .. code)
  end
  return result.stdout or ""
end

---@async
---@param data string
---@param mime Neoagent.FileImageMime
---@param ctx Neoagent.ToolCapabilities
---@param settings Neoagent.ReadFileSettings
---@return Neoagent.ProcessedImage?, string?, boolean?
local function run_magick(data, mime, ctx, settings)
  local input_format = assert(MAGICK_FORMAT[mime])
  local input = input_format .. ":-[0]"
  local inspected, dimensions = pcall(process_magick, data, ctx, settings, "identify", {
    "-format",
    "%w %h",
    input,
  }, IDENTIFY_CAPTURE_BYTES)
  if not inspected then
    return nil, "could not inspect image dimensions: " .. tostring(dimensions), false
  end
  local width, height = dimensions:match("(%d+)%s+(%d+)")
  local ow, oh = tonumber(width), tonumber(height)
  if not ow or not oh then
    return nil, "could not inspect image dimensions: invalid output", false
  end
  if ow * oh > settings.max_image_pixels then
    return nil, "image dimensions exceed " .. settings.max_image_pixels .. " pixels", false
  end

  local ok, result = pcall(function()
    local output_format = mime == MIME.jpeg and "jpeg" or "png"
    local converted, bytes = pcall(process_magick, data, ctx, settings, nil, {
      input,
      "-auto-orient",
      "-resize",
      "2000x2000>",
      output_format .. ":-",
    }, settings.max_image_output_bytes + 1)
    if not converted and (type(bytes) ~= "table" or bytes.code ~= "output_limit") then
      error(bytes, 0)
    end
    ---@type Neoagent.FileImageMime
    local transmitted_mime = output_format == "jpeg" and MIME.jpeg or MIME.png
    if not converted or #bytes > settings.max_image_output_bytes then
      output_format = "jpeg"
      bytes = process_magick(data, ctx, settings, nil, {
        input,
        "-auto-orient",
        "-resize",
        "1600x1600>",
        "-quality",
        "80",
        output_format .. ":-",
      }, settings.max_image_output_bytes + 1)
      transmitted_mime = MIME.jpeg
    end
    ---@cast bytes string

    local final_ok, final_dimensions = pcall(process_magick, bytes, ctx, settings, "identify", {
      "-format",
      "%w %h",
      output_format .. ":-[0]",
    }, IDENTIFY_CAPTURE_BYTES)
    local tw, th
    if final_ok then
      tw, th = final_dimensions:match("(%d+)%s+(%d+)")
      tw, th = tonumber(tw), tonumber(th)
    end
    local note = "Read image file [" .. transmitted_mime .. "]"
    if tw and th and (ow ~= tw or oh ~= th) then
      note = note
        .. string.format(
          "\n[Resized from %dx%d to %dx%d; coordinate scale %.4f x %.4f]",
          ow,
          oh,
          tw,
          th,
          ow / tw,
          oh / th
        )
    end
    return { data = bytes, mime_type = transmitted_mime, note = note }
  end)
  if not ok then
    return nil, tostring(result), true
  end
  return result
end

---@param value unknown
---@param name string
---@return integer
local function positive_integer(value, name)
  assert(type(value) == "number" and value > 0 and value % 1 == 0, name .. " must be a positive integer")
  ---@cast value integer
  return value
end

---@param options? Neoagent.ReadFileOptions
---@return Neoagent.Tool<unknown>
local function new(options)
  options = options or {}
  for key in pairs(options) do
    assert(
      key == "max_image_input_bytes" or key == "max_image_pixels" or key == "max_image_output_bytes",
      "unsupported read_file option: " .. tostring(key)
    )
  end
  ---@type Neoagent.ReadFileSettings
  local settings = {
    max_image_input_bytes = positive_integer(
      options.max_image_input_bytes or DEFAULT_MAX_IMAGE_INPUT_BYTES,
      "max_image_input_bytes"
    ),
    max_image_pixels = positive_integer(options.max_image_pixels or DEFAULT_MAX_IMAGE_PIXELS, "max_image_pixels"),
    max_image_output_bytes = positive_integer(
      options.max_image_output_bytes or DEFAULT_MAX_IMAGE_OUTPUT_BYTES,
      "max_image_output_bytes"
    ),
  }
  return {
    name = "read_file",
    capabilities = { read_files = true },
    description = "Read a text file or image from disk. Text is limited to 2,000 lines or 50 KiB; use offset and limit to continue.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to the file to read (relative or absolute)" },
        offset = { type = "number", description = "Line number to start reading from (1-indexed)" },
        limit = { type = "number", description = "Maximum number of lines to read" },
      },
      required = { "path" },
      additionalProperties = false,
    },
    ---@async
    execute = function(arguments, ctx)
      local path = common.require_string(arguments, "path")
      local offset = arguments.offset or 1
      local limit = arguments.limit
      if type(offset) ~= "number" or offset < 1 or offset % 1 ~= 0 then
        error("offset must be a positive integer")
      end
      if limit ~= nil and (type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0) then
        error("limit must be a positive integer")
      end
      local files = common.files(ctx)
      local filesystem = common.fs(ctx)
      local absolute = common.workspace(ctx):resolve(path)
      local filename = assert(vim.fs.basename(absolute))
      local text = common.line_capture({
        offset = offset,
        select_lines = limit or math.huge,
        max_lines = truncate.MAX_LINES,
        max_bytes = truncate.MAX_BYTES,
        max_line_bytes = truncate.MAX_BYTES + 1,
      })
      local undecided = ""
      ---@type "image"|"text"|nil
      local mode
      ---@type Neoagent.FileImageMime?
      local mime
      local image_chunks = {}
      local image_bytes = 0
      ---@param data string
      local function append_image(data)
        image_bytes = image_bytes + #data
        if image_bytes > settings.max_image_input_bytes then
          error("image input exceeds " .. settings.max_image_input_bytes .. " bytes")
        end
        image_chunks[#image_chunks + 1] = data
      end
      ---@param data string
      local function consume(data)
        if not mode then
          undecided = undecided .. data
          if #undecided < 12 then
            return
          end
          mime = detect(undecided)
          mode = mime and "image" or "text"
          data, undecided = undecided, ""
        end
        if mode == "image" then
          append_image(data)
        else
          text.append(data)
        end
      end
      local read, err = stream(filesystem, absolute, consume)
      if not read then
        error("Could not read file " .. path .. ": " .. tostring(err))
      end
      if not mode then
        mime = detect(undecided)
        mode = mime and "image" or "text"
        if mode == "image" then
          append_image(undecided)
        else
          text.append(undecided)
        end
      end
      if mime then
        local data = table.concat(image_chunks)
        if vim.fn.executable("magick") == 1 and async.current() then
          local processed, process_err, allow_original = run_magick(data, mime, ctx, settings)
          if processed then
            local name = filename
            if processed.mime_type ~= mime then
              name = filename:gsub("%.[^.]+$", "") .. (processed.mime_type == MIME.jpeg and ".jpg" or ".png")
            end
            return image_result(
              processed.data,
              processed.mime_type,
              processed.note,
              settings.max_image_output_bytes,
              files,
              name
            )
          end
          if not allow_original then
            error(process_err)
          end
          return image_result(
            data,
            mime,
            "Read image file ["
              .. mime
              .. "]\n[ImageMagick resize failed: "
              .. tostring(process_err)
              .. "; sending original]",
            settings.max_image_output_bytes,
            files,
            filename
          )
        end
        local note = "Read image file [" .. mime .. "]"
        if vim.fn.executable("magick") ~= 1 then
          note = note .. "\n[ImageMagick is unavailable; sending original image]"
        end
        return image_result(data, mime, note, settings.max_image_output_bytes, files, filename)
      end

      local shortened = text.finish(true)
      if offset > shortened.totalLines then
        error(string.format("Offset %d is beyond end of file (%d lines total)", offset, shortened.totalLines))
      end
      local last = limit and math.min(shortened.totalLines, offset + limit - 1) or shortened.totalLines
      local text
      if shortened.firstLineExceedsLimit then
        text = string.format(
          "[Line %d is %s, exceeds %s limit. Use shell to inspect it in chunks.]",
          offset,
          truncate.format_size(assert(shortened.firstLineBytes)),
          truncate.format_size(truncate.MAX_BYTES)
        )
      elseif shortened.truncated then
        local ending = offset + shortened.outputLines - 1
        text = shortened.content
          .. string.format(
            "\n\n[Showing lines %d-%d of %d. Use offset=%d to continue.]",
            offset,
            ending,
            shortened.totalLines,
            ending + 1
          )
      elseif limit and last < shortened.totalLines then
        text = shortened.content
          .. string.format(
            "\n\n[%d more lines in file. Use offset=%d to continue.]",
            shortened.totalLines - last,
            last + 1
          )
      else
        text = shortened.content
      end
      return { content = { { type = "text", text = text } }, details = { truncation = shortened } }
    end,
    render = presentation.read,
  }
end

local M = new()
M.new = new
M.detect_mime = detect
return M
