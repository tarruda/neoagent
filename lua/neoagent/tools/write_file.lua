local common = require("neoagent.tools.common")
local presentation = require("neoagent.tools.activity_presentation")

local IMPLEMENTATION = {}

---@class Neoagent.WriteFileRequest
---@field path string
---@field content string

---@param value unknown
---@return Neoagent.WriteFileRequest
local function validate_request(value)
  assert(common.object(value), "write_file request must be an object")
  ---@cast value table
  common.fields(value, { path = true, content = true }, "write_file request")
  return {
    path = common.path(value.path, "write_file path"),
    content = common.string(value.content, "write_file content", true),
  }
end

---@param arguments Neoagent.JsonObject
---@return Neoagent.WriteFileRequest
local function prepare(arguments)
  return validate_request({
    path = common.require_string(arguments, "path"),
    content = common.require_string(arguments, "content", true),
  })
end

---@async
---@param request Neoagent.WriteFileRequest
---@param call Neoagent.ToolOperationCall
---@param dependencies Neoagent.ToolDependencies
---@return Neoagent.ToolResult
local function run(request, call, dependencies)
  local workspace = dependencies.workspace(call.workspace)
  local absolute = workspace:resolve(request.path)
  local ok, err = dependencies.fs.mkdirp(vim.fs.dirname(absolute))
  if not ok then
    error("Could not create parent directory for " .. request.path .. ": " .. tostring(err))
  end
  ok, err = dependencies.fs.atomic_replace(absolute, request.content, {
    preserve_mode = true,
    new_mode = 420,
  })
  if not ok then
    error("Could not write file " .. request.path .. ": " .. tostring(err))
  end
  return {
    content = {
      { type = "text", text = "Successfully wrote " .. #request.content .. " bytes to " .. request.path },
    },
    details = { changed_paths = { request.path } },
  }
end

---@return Neoagent.Tool<unknown>
local function new()
  local dependencies = common.dependencies()
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
      return run(prepare(arguments), common.call(ctx), common.context_dependencies(ctx, dependencies))
    end,
    render = presentation.write,
  }
  return common.bind(tool, {
    token = IMPLEMENTATION,
    settings = {},
    prepare = prepare,
  })
end

---@class Neoagent.WriteFileTool: Neoagent.Tool<unknown>
---@field execute async fun(arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<unknown>): Neoagent.ToolResult
---@field render? fun(options: Neoagent.ToolPresentationOptions): unknown
local M = new()
M.new = new
M.prepare = prepare
M.validate_request = validate_request
M.run = run
M._implementation = IMPLEMENTATION
return M
