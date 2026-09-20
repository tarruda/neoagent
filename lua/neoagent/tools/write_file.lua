local common = require("neoagent.tools.common")

local identities = require("neoagent.tools.identities")

---@class Neoagent.WriteFileDependencies
---@field fs Neoagent.ToolFilesystem

---@class Neoagent.WriteFileRequest
---@field path string
---@field resolved_path string
---@field content string

---@param options? Neoagent.ToolDependencyOverrides
---@return Neoagent.WriteFileDependencies
local function dependencies(options)
  options = options or {}
  local fs = options.fs
  if fs == nil then
    fs = require("neoagent.fs")
  end
  assert(type(fs) == "table", "Tool filesystem is required")
  return {
    fs = fs,
  }
end

---@param value unknown
---@return Neoagent.WriteFileRequest
local function validate_request(value)
  assert(common.object(value), "write_file request must be an object")
  ---@cast value table
  common.fields(value, { path = true, resolved_path = true, content = true }, "write_file request")
  return common.request({
    path = common.path(value.path, "write_file path"),
    resolved_path = common.absolute_path(value.resolved_path, "write_file resolved path"),
    content = common.string(value.content, "write_file content", true),
  }, "write_file request")
end

---@param arguments Neoagent.JsonObject
---@param _settings table
---@param call Neoagent.ToolOperationCall
---@return Neoagent.WriteFileRequest
local function prepare(arguments, _settings, call)
  local path = common.require_string(arguments, "path")
  return validate_request({
    path = path,
    resolved_path = common.resolve_path(path, call),
    content = common.require_string(arguments, "content", true),
  })
end

---@async
---@param request Neoagent.WriteFileRequest
---@param _call Neoagent.ToolOperationCall
---@param dependencies Neoagent.WriteFileDependencies
---@return Neoagent.ToolResult
local function run(request, _call, dependencies)
  local absolute = request.resolved_path
  local ok, err = dependencies.fs.mkdirp(vim.fs.dirname(absolute))
  if not ok then
    common.filesystem_error("Could not create parent directory for " .. request.path, err)
  end
  ok, err = dependencies.fs.atomic_replace(absolute, request.content, {
    preserve_mode = true,
    new_mode = 420,
  })
  if not ok then
    common.filesystem_error("Could not write file " .. request.path, err)
  end
  return {
    content = {
      { type = "text", text = "Successfully wrote " .. #request.content .. " bytes to " .. request.path },
    },
    details = { changed_paths = { absolute } },
  }
end

---@return Neoagent.Tool<unknown>
local function new()
  local presentation = require("neoagent.tools.activity_presentation")
  local deps = dependencies()
  local tool = {
    name = "write_file",
    description = "Write content to a file. Creates missing parent directories and completely overwrites the file.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to the file to write (relative or absolute)" },
        content = { type = "string", description = "Complete content to write" },
      },
      required = { "path", "content" },
      additionalProperties = false,
    },
    ---@async
    execute = function(arguments, ctx)
      local call = common.call(ctx)
      return run(prepare(arguments, {}, call), call, deps)
    end,
    render = presentation.write,
  }
  return identities.bind(tool, {
    token = identities.write_file,
    settings = {},
    prepare = prepare,
  })
end

local M = {}
M.new = new
M.prepare = prepare
M.validate_request = validate_request
M.run = run
M._dependencies = dependencies
return M
