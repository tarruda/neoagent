local async = require("neoagent.async")
local common = require("neoagent.tools.common")
local limits = require("neoagent.tools.limits")
local truncate = require("neoagent.tools.truncate")
local util = require("neoagent.util")

---@class Neoagent.ReadFileOptions
---@field max_image_input_bytes? integer
---@field max_image_pixels? integer
---@field max_image_output_bytes? integer

---@class Neoagent.ReadFileSettings
---@field max_image_input_bytes integer
---@field max_image_pixels integer
---@field max_image_output_bytes integer

---@class Neoagent.ReadFileRequest
---@field path string
---@field resolved_path string
---@field offset integer
---@field limit? integer
---@field max_image_input_bytes integer
---@field max_image_pixels integer
---@field max_image_output_bytes integer

---@alias Neoagent.FileImageMime "image/png"|"image/jpeg"|"image/gif"|"image/webp"|"image/bmp"

---@class Neoagent.ProcessedImage
---@field data string
---@field mime_type Neoagent.FileImageMime
---@field note string

local M = {}
local identities = require("neoagent.tools.identities")

---@class Neoagent.ReadFileDependencies
---@field fs Neoagent.ToolFilesystem
---@field process async fun(command: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult
---@field executable fun(name: string): boolean
---@field artifact_publisher fun(call: Neoagent.ToolOperationCall): Neoagent.ToolArtifactPublisher

---@param options? Neoagent.ToolDependencyOverrides
---@return Neoagent.ReadFileDependencies
local function dependencies(options)
  options = options or {}
  local fs = options.fs
  local process = options.process
  local executable = options.executable
  local artifact_publisher = options.artifact_publisher
  if fs == nil then
    fs = require("neoagent.fs")
  end
  if process == nil then
    process = require("neoagent.process").run
  end
  if executable == nil then
    executable = common.executable
  end
  if artifact_publisher == nil then
    artifact_publisher = common.artifact_publisher
  end
  assert(type(fs) == "table", "Tool filesystem is required")
  assert(type(process) == "function", "Tool process runner is required")
  assert(type(executable) == "function", "Tool executable lookup is required")
  assert(type(artifact_publisher) == "function", "Tool artifact publisher is required")
  return {
    fs = fs,
    process = process,
    executable = executable,
    artifact_publisher = artifact_publisher,
  }
end

local DEFAULT_MAX_IMAGE_INPUT_BYTES = 20 * 1024 * 1024
local DEFAULT_MAX_IMAGE_PIXELS = 40 * 1000 * 1000
local DEFAULT_MAX_IMAGE_OUTPUT_BYTES = 4.5 * 1024 * 1024 / 4 * 3

---@param value unknown
---@param name string
---@return integer
local function positive_integer(value, name)
  assert(type(value) == "number" and value > 0 and value % 1 == 0, name .. " must be a positive integer")
  ---@cast value integer
  return value
end

---@param value unknown
---@return Neoagent.ReadFileRequest
local function validate_request(value)
  assert(common.object(value), "read_file request must be an object")
  ---@cast value table
  common.fields(value, {
    path = true,
    resolved_path = true,
    offset = true,
    limit = true,
    max_image_input_bytes = true,
    max_image_pixels = true,
    max_image_output_bytes = true,
  }, "read_file request")
  local result = {
    path = common.path(value.path, "read_file path"),
    resolved_path = common.absolute_path(value.resolved_path, "read_file resolved path"),
    offset = common.integer(value.offset, "read_file offset"),
    max_image_input_bytes = common.integer(value.max_image_input_bytes, "read_file max_image_input_bytes"),
    max_image_pixels = common.integer(value.max_image_pixels, "read_file max_image_pixels"),
    max_image_output_bytes = common.integer(value.max_image_output_bytes, "read_file max_image_output_bytes"),
  }
  assert(
    result.max_image_output_bytes <= limits.MAX_ARTIFACT_BYTES,
    "read_file max_image_output_bytes must not exceed " .. limits.MAX_ARTIFACT_BYTES
  )
  if value.limit ~= nil then
    result.limit = common.integer(value.limit, "read_file limit")
  end
  return common.request(result, "read_file request")
end

---@param arguments Neoagent.JsonObject
---@param settings Neoagent.ReadFileSettings
---@param call Neoagent.ToolOperationCall
---@return Neoagent.ReadFileRequest
local function prepare(arguments, settings, call)
  local path = common.require_string(arguments, "path")
  return validate_request({
    path = path,
    resolved_path = common.resolve_path(path, call),
    offset = arguments.offset or 1,
    limit = arguments.limit,
    max_image_input_bytes = settings.max_image_input_bytes,
    max_image_pixels = settings.max_image_pixels,
    max_image_output_bytes = settings.max_image_output_bytes,
  })
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

---@async
---@param data string
---@param mime Neoagent.FileImageMime
---@param note string
---@param max_output_bytes integer
---@param publisher Neoagent.ToolArtifactPublisher
---@param filename string
---@return Neoagent.ToolResult
local function image_result(data, mime, note, max_output_bytes, publisher, filename)
  if #data > max_output_bytes then
    error("image output exceeds " .. max_output_bytes .. " bytes")
  end
  local stored, err = publisher.put(data)
  if not stored then
    error(err, 0)
  end
  local display_filename = #filename <= 512 and util.is_valid_utf8(filename) and not filename:find("[%c]") and filename
    or nil
  return {
    content = {
      { type = "text", text = note },
      {
        type = "image",
        file_id = stored.file_id,
        bytes = stored.bytes,
        mime_type = mime,
        filename = display_filename,
      },
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

---@param request Neoagent.ReadFileRequest
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
---@param request Neoagent.ReadFileRequest
---@param deps Neoagent.ReadFileDependencies
---@param operation? string
---@param arguments string[]
---@param max_capture_bytes integer
---@return string
local function process_magick(data, request, deps, operation, arguments, max_capture_bytes)
  local result = deps.process(magick_command(request, operation, arguments), {
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
---@param request Neoagent.ReadFileRequest
---@param deps Neoagent.ReadFileDependencies
---@return Neoagent.ProcessedImage?, string?, boolean?
local function run_magick(data, mime, request, deps)
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
    ---@type Neoagent.FileImageMime
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

---@async
---@param request Neoagent.ReadFileRequest
---@param call Neoagent.ToolOperationCall
---@param deps Neoagent.ReadFileDependencies
---@return Neoagent.ToolResult
local function run(request, call, deps)
  local absolute = request.resolved_path
  local filename = assert(vim.fs.basename(absolute))
  local text = common.line_capture({
    offset = request.offset,
    select_lines = request.limit or math.huge,
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
    if image_bytes > request.max_image_input_bytes then
      error("image input exceeds " .. request.max_image_input_bytes .. " bytes")
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
      mime = M.detect_mime(undecided)
      mode = mime and "image" or "text"
      data, undecided = undecided, ""
    end
    if mode == "image" then
      append_image(data)
    else
      text.append(data)
    end
  end
  local read, err = stream(deps.fs, absolute, consume)
  if not read then
    common.filesystem_error("Could not read file " .. request.path, err)
  end
  if not mode then
    mime = M.detect_mime(undecided)
    mode = mime and "image" or "text"
    if mode == "image" then
      append_image(undecided)
    else
      text.append(undecided)
    end
  end
  if mime then
    local data = table.concat(image_chunks)
    local publisher = deps.artifact_publisher(call)
    if deps.executable("magick") and async.current() then
      local processed, process_err, allow_original = run_magick(data, mime, request, deps)
      if processed then
        local name = filename
        if processed.mime_type ~= mime then
          name = filename:gsub("%.[^.]+$", "") .. (processed.mime_type == MIME.jpeg and ".jpg" or ".png")
        end
        return image_result(
          processed.data,
          processed.mime_type,
          processed.note,
          request.max_image_output_bytes,
          publisher,
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
        request.max_image_output_bytes,
        publisher,
        filename
      )
    end
    local note = "Read image file [" .. mime .. "]"
    if not deps.executable("magick") then
      note = note .. "\n[ImageMagick is unavailable; sending original image]"
    end
    return image_result(data, mime, note, request.max_image_output_bytes, publisher, filename)
  end

  local shortened = text.finish(true)
  if request.offset > shortened.totalLines then
    error(string.format("Offset %d is beyond end of file (%d lines total)", request.offset, shortened.totalLines))
  end
  local last = request.limit and math.min(shortened.totalLines, request.offset + request.limit - 1)
    or shortened.totalLines
  local content
  if shortened.firstLineExceedsLimit then
    content = string.format(
      "[Line %d is %s, exceeds %s limit. Use shell to inspect it in chunks.]",
      request.offset,
      truncate.format_size(assert(shortened.firstLineBytes)),
      truncate.format_size(truncate.MAX_BYTES)
    )
  elseif shortened.truncated then
    local ending = request.offset + shortened.outputLines - 1
    content = shortened.content
      .. string.format(
        "\n\n[Showing lines %d-%d of %d. Use offset=%d to continue.]",
        request.offset,
        ending,
        shortened.totalLines,
        ending + 1
      )
  elseif request.limit and last < shortened.totalLines then
    content = shortened.content
      .. string.format("\n\n[%d more lines in file. Use offset=%d to continue.]", shortened.totalLines - last, last + 1)
  else
    content = shortened.content
  end
  return { content = { { type = "text", text = content } }, details = { truncation = shortened } }
end

---@param options? Neoagent.ReadFileOptions
---@return Neoagent.Tool<unknown>
local function new(options)
  local presentation = require("neoagent.tools.activity_presentation")
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
  assert(
    settings.max_image_output_bytes <= limits.MAX_ARTIFACT_BYTES,
    "max_image_output_bytes must not exceed " .. limits.MAX_ARTIFACT_BYTES
  )
  local deps = dependencies()
  local tool = {
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
      local call = common.call(ctx)
      return run(prepare(arguments, settings, call), call, deps)
    end,
    render = presentation.read,
  }
  return identities.bind(tool, {
    token = identities.read_file,
    settings = settings,
    prepare = prepare,
  })
end

M.new = new
M.prepare = prepare
M.validate_request = validate_request
M.run = run
M._dependencies = dependencies
return M
