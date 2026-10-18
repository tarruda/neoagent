local common = require("neoagent.tools.common")
local images = require("neoagent.tools.common.images")
local identities = require("neoagent.tools.identities")
local M = {}

---@param model Neoagent.Model
---@param detail? unknown
function M.check_model(model, detail)
  assert(vim.tbl_contains(model.input, "image"), "view_image requires image-capable Models")
  assert(
    detail ~= "original" or model.supports_image_detail_original == true,
    "The selected Model does not support original image detail"
  )
end

---@class Neoagent.ViewImageRequest: Neoagent.ImageFileSettings
---@field path string
---@field resolved_path string
---@field detail 'high'|'original'

---@param value unknown
---@return Neoagent.ViewImageRequest
function M.validate_request(value)
  assert(common.object(value), "view_image request must be an object")
  common.fields(value, {
    path = true,
    resolved_path = true,
    detail = true,
    max_image_input_bytes = true,
    max_image_pixels = true,
    max_image_output_bytes = true,
  }, "view_image request")
  assert(value.detail == "high" or value.detail == "original", "view_image detail must be high or original")
  local request = {
    path = common.path(value.path, "view_image path"),
    resolved_path = common.absolute_path(value.resolved_path, "view_image resolved path"),
    max_image_input_bytes = common.integer(value.max_image_input_bytes, "view_image max_image_input_bytes"),
    max_image_pixels = common.integer(value.max_image_pixels, "view_image max_image_pixels"),
    max_image_output_bytes = common.integer(value.max_image_output_bytes, "view_image max_image_output_bytes"),
    detail = value.detail,
  }
  assert(
    request.max_image_output_bytes <= require("neoagent.tools.limits").MAX_ARTIFACT_BYTES,
    "view_image output limit exceeds the artifact bound"
  )
  return common.request(request, "view_image request")
end

---@param arguments Neoagent.JsonObject
---@param _ table
---@param call Neoagent.ToolOperationCall
---@return Neoagent.ViewImageRequest
function M.prepare(arguments, _, call)
  local path = common.require_string(arguments, "path")
  return M.validate_request({
    path = path,
    resolved_path = common.resolve_path(path, call),
    detail = arguments.detail or "high",
    max_image_input_bytes = require("neoagent.tools.limits").MAX_ARTIFACT_BYTES,
    max_image_pixels = 40000000,
    max_image_output_bytes = require("neoagent.tools.limits").MAX_ARTIFACT_BYTES,
  })
end

---@async
---@param request Neoagent.ViewImageRequest
---@param call Neoagent.ToolOperationCall
---@param deps Neoagent.ImageFileDependencies
---@return Neoagent.ToolResult
function M.run(request, call, deps)
  assert(deps.executable("magick"), "view_image requires ImageMagick's magick executable")
  local data, err = deps.fs.read(request.resolved_path, request.max_image_input_bytes)
  assert(data, err)
  local mime = images.detect_mime(data)
  assert(mime and mime ~= "image/bmp", "invalid or unsupported image data")
  if request.detail == "original" then
    images.inspect(data, mime, request, deps)
  else
    local processed, process_err = images.process(data, mime, request, deps)
    assert(processed, process_err)
    data, mime = processed.data, processed.mime_type
  end
  local stored, store_err = deps.artifact_publisher(call).put(data)
  assert(stored, store_err and store_err.message)
  local filename = images.display_filename(vim.fs.basename(request.resolved_path))
  return {
    content = {
      {
        type = "image",
        file_id = stored.file_id,
        bytes = stored.bytes,
        mime_type = mime,
        filename = filename,
        detail = request.detail,
      },
    },
    details = { path = request.path, detail = request.detail },
  }
end

---@return Neoagent.Tool<unknown>
function M.new()
  local deps = images.dependencies()
  ---@type Neoagent.ToolSchema
  local input = {
    type = "object",
    properties = {
      path = { type = "string", description = "Local filesystem path to an image file." },
      detail = {
        type = "string",
        enum = { "high", "original" },
        description = "Defaults to high; original preserves exact resolution when supported by the Model.",
      },
    },
    required = { "path" },
    additionalProperties = false,
  }
  return identities.bind({
    name = "view_image",
    description = "View a local image file from the filesystem when visual inspection is needed. Use this for images already available on disk.",
    input_schema = input,
    input_schema_for_model = function(model)
      local schema = require("neoagent.util").copy(input)
      if not model.supports_image_detail_original then
        local detail = assert(assert(schema.properties).detail)
        detail.enum = { "high" }
        detail.description = "Defaults to high."
      end
      return schema
    end,
    render = function(options)
      if not options then
        return nil
      end
      return {
        kind = "activity",
        operation = "read",
        ongoing = "Viewing",
        complete = "Viewed",
        subject = options.arguments.path,
      }
    end,
  }, {
    token = identities.view_image,
    settings = {},
    prepare = identities.workspace_prepare(M.prepare),
    check_context = function(ctx, arguments)
      M.check_model(ctx.model, arguments.detail)
    end,
    run = function(request, _, ctx)
      return M.run(request, common.call(ctx), deps)
    end,
  })
end

return M
