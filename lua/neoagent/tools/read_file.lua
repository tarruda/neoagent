local async = require("neoagent.async")
local common = require("neoagent.tools.common")
local images = require("neoagent.tools.common.images")
local limits = require("neoagent.tools.limits")
local truncate = require("neoagent.tools.truncate")
local util = require("neoagent.util")

---@class Neoagent.ReadFileOptions
---@field max_image_input_bytes? integer
---@field max_image_pixels? integer
---@field max_image_output_bytes? integer

---@class Neoagent.ReadFileRequest: Neoagent.ImageFileSettings
---@field path string
---@field resolved_path string
---@field offset integer
---@field limit? integer

local M = {}
local identities = require("neoagent.tools.identities")

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
---@param settings Neoagent.ImageFileSettings
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

---@param image Neoagent.ProcessedImage
---@return string
local function image_note(image)
  local note = "Read image file [" .. image.mime_type .. "]"
  local width, height = image.width, image.height
  if width and height and (width ~= image.original_width or height ~= image.original_height) then
    note = note
      .. string.format(
        "\n[Resized from %dx%d to %dx%d; coordinate scale %.4f x %.4f]",
        image.original_width,
        image.original_height,
        width,
        height,
        image.original_width / width,
        image.original_height / height
      )
  end
  return note
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
  local display_filename = images.display_filename(filename)
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

---@async
---@param request Neoagent.ReadFileRequest
---@param call Neoagent.ToolOperationCall
---@param deps Neoagent.ImageFileDependencies
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
      mime = images.detect_mime(undecided)
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
    mime = images.detect_mime(undecided)
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
      local processed, process_err, allow_original = images.process(data, mime, request, deps)
      if processed then
        local name = filename
        if processed.mime_type ~= mime then
          name = filename:gsub("%.[^.]+$", "") .. (processed.mime_type == "image/jpeg" and ".jpg" or ".png")
        end
        return image_result(
          processed.data,
          processed.mime_type,
          image_note(processed),
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
  ---@type Neoagent.ImageFileSettings
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
  local deps = images.dependencies()
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
    render = presentation.read,
  }
  return identities.bind(tool, {
    token = identities.read_file,
    settings = settings,
    prepare = identities.workspace_prepare(prepare),
    run = function(request, _, ctx)
      return run(request, common.call(ctx), deps)
    end,
  })
end

M.new = new
M.prepare = prepare
M.validate_request = validate_request
M.run = run
M._dependencies = images.dependencies

return M
