local common = require("neoagent.tools.common")
local M = {}

---@param filename string
---@return string?
function M.display_filename(filename)
  if #filename <= 512 and require("neoagent.util").is_valid_utf8(filename) and not filename:find("[%c]") then
    return filename
  end
end

---@class Neoagent.ImageFileSettings
---@field max_image_input_bytes integer
---@field max_image_pixels integer
---@field max_image_output_bytes integer

---@alias Neoagent.FileImageMime "image/png"|"image/jpeg"|"image/gif"|"image/webp"|"image/bmp"

---@class Neoagent.ProcessedImage
---@field data string
---@field mime_type 'image/png'|'image/jpeg'
---@field original_width number
---@field original_height number
---@field width? number
---@field height? number

---@class Neoagent.ImageFileDependencies
---@field fs Neoagent.ToolFilesystem
---@field subprocesses Neoagent.ToolSubprocesses
---@field executable fun(name: string): boolean
---@field artifact_publisher fun(call: Neoagent.ToolOperationCall): Neoagent.ToolArtifactPublisher

---@param options? Neoagent.ToolDependencyOverrides
---@return Neoagent.ImageFileDependencies
function M.dependencies(options)
  options = options or {}
  local fs = options.fs
  local executable = options.executable
  local artifact_publisher = options.artifact_publisher
  if fs == nil then
    fs = require("neoagent.fs")
  end
  if executable == nil then
    executable = common.executable
  end
  if artifact_publisher == nil then
    artifact_publisher = common.artifact_publisher
  end
  assert(type(fs) == "table", "Tool filesystem is required")
  assert(type(executable) == "function", "Tool executable lookup is required")
  assert(type(artifact_publisher) == "function", "Tool artifact publisher is required")
  return {
    fs = fs,
    subprocesses = common.subprocesses(options.subprocesses),
    executable = executable,
    artifact_publisher = artifact_publisher,
  }
end

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

local IMAGE_TIMEOUT_MS = 30000
local IDENTIFY_CAPTURE_BYTES = 64 * 1024

---@param data string
---@return Neoagent.FileImageMime?
function M.detect_mime(data)
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

---@param request Neoagent.ImageFileSettings
---@param operation? string
---@param arguments string[]
---@return string[]
local function magick_command(request, operation, arguments)
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
    tostring(request.max_image_pixels),
  })
  return vim.list_extend(command, arguments)
end

---@async
---@param data string
---@param request Neoagent.ImageFileSettings
---@param deps Neoagent.ImageFileDependencies
---@param operation? string
---@param arguments string[]
---@param max_capture_bytes integer
---@return string
local function process_magick(data, request, deps, operation, arguments, max_capture_bytes)
  local result = deps.subprocesses.run({
    argv = magick_command(request, operation, arguments),
    cwd = assert(vim.uv.cwd()),
    environment = common.process_environment(),
    stdio = { kind = "pipes", stdin = "open" },
    timeout_ms = IMAGE_TIMEOUT_MS,
    kill_grace_ms = 100,
  }, {
    input = { chunks = { data }, close = true, allow_early_close = true },
    capture = { max_bytes = max_capture_bytes },
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
---@param request Neoagent.ImageFileSettings
---@param deps Neoagent.ImageFileDependencies
---@return Neoagent.ProcessedImage?, string?, boolean?
function M.process(data, mime, request, deps)
  local input_format = assert(MAGICK_FORMAT[mime])
  local input = input_format .. ":-[0]"
  local inspected, dimensions = pcall(process_magick, data, request, deps, "identify", {
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
  if ow * oh > request.max_image_pixels then
    return nil, "image dimensions exceed " .. request.max_image_pixels .. " pixels", false
  end

  local ok, result = pcall(function()
    local output_format = mime == MIME.jpeg and "jpeg" or "png"
    local converted, bytes = pcall(process_magick, data, request, deps, nil, {
      input,
      "-auto-orient",
      "-resize",
      "2000x2000>",
      output_format .. ":-",
    }, request.max_image_output_bytes + 1)
    if not converted and (type(bytes) ~= "table" or bytes.code ~= "output_limit") then
      error(bytes, 0)
    end
    ---@type 'image/png'|'image/jpeg'
    local transmitted_mime = output_format == "jpeg" and MIME.jpeg or MIME.png
    if not converted or #bytes > request.max_image_output_bytes then
      output_format = "jpeg"
      bytes = process_magick(data, request, deps, nil, {
        input,
        "-auto-orient",
        "-resize",
        "1600x1600>",
        "-quality",
        "80",
        output_format .. ":-",
      }, request.max_image_output_bytes + 1)
      transmitted_mime = MIME.jpeg
    end
    ---@cast bytes string

    local final_ok, final_dimensions = pcall(process_magick, bytes, request, deps, "identify", {
      "-format",
      "%w %h",
      output_format .. ":-[0]",
    }, IDENTIFY_CAPTURE_BYTES)
    local tw, th
    if final_ok then
      tw, th = final_dimensions:match("(%d+)%s+(%d+)")
      tw, th = tonumber(tw), tonumber(th)
    end
    return {
      data = bytes,
      mime_type = transmitted_mime,
      original_width = ow,
      original_height = oh,
      width = tw,
      height = th,
    }
  end)
  if not ok then
    return nil, tostring(result), true
  end
  return result
end

---@async
---@param data string
---@param mime Neoagent.FileImageMime
---@param request Neoagent.ImageFileSettings
---@param deps Neoagent.ImageFileDependencies
function M.inspect(data, mime, request, deps)
  local dimensions = process_magick(data, request, deps, "identify", {
    "-format",
    "%w %h",
    assert(MAGICK_FORMAT[mime]) .. ":-[0]",
  }, IDENTIFY_CAPTURE_BYTES)
  local width, height = dimensions:match("(%d+)%s+(%d+)")
  local w, h = tonumber(width), tonumber(height)
  assert(w and h and w * h <= request.max_image_pixels, "invalid or oversized image dimensions")
end

return M
