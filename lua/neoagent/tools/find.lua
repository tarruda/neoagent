local common = require("neoagent.tools.common")
local presentation = require("neoagent.tools.activity_presentation")
local truncate = require("neoagent.tools.truncate")

local IMPLEMENTATION = {}

---@class Neoagent.FindRequest
---@field pattern string
---@field path? string
---@field limit integer

---@param value unknown
---@return Neoagent.FindRequest
local function validate_request(value)
  assert(common.object(value), "find request must be an object")
  ---@cast value table
  common.fields(value, { pattern = true, path = true, limit = true }, "find request")
  local result = {
    pattern = common.string(value.pattern, "find pattern", true),
    limit = common.integer(value.limit, "find limit"),
  }
  if value.path ~= nil then
    result.path = common.path(value.path, "find path")
  end
  return common.request(result, "find request")
end

---@param arguments Neoagent.JsonObject
---@return Neoagent.FindRequest
local function prepare(arguments)
  local limit = arguments.limit or 1000
  if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then
    error("limit must be a positive integer")
  end
  ---@cast limit integer
  return validate_request({
    pattern = common.require_string(arguments, "pattern", true),
    path = arguments.path and common.require_string(arguments, "path") or nil,
    limit = limit,
  })
end

---@async
---@param request Neoagent.FindRequest
---@param call Neoagent.ToolOperationCall
---@param dependencies Neoagent.ToolDependencies
---@return Neoagent.ToolResult
local function run(request, call, dependencies)
  local workspace = dependencies.workspace(call.workspace)
  local search = request.path and workspace:resolve(request.path) or workspace.cwd
  local result, captured, captured_stderr = common.capture_process(dependencies.process, {
    "fd",
    "--hidden",
    "--glob",
    "--",
    request.pattern,
    ".",
  }, {
    process = { cwd = search },
    stdout = {
      max_lines = request.limit,
      max_bytes = truncate.MAX_BYTES,
      max_line_bytes = truncate.MAX_BYTES + 1,
      transform = function(line)
        return (line:gsub("\\", "/"):gsub("^%./", "")), false
      end,
    },
  })
  if result.code ~= 0 then
    error("find path is not a directory or fd exited with status " .. result.code .. ": " .. captured_stderr.content)
  end
  if captured.totalLines == 0 then
    return { content = { { type = "text", text = "No files found" } } }
  end
  local text = captured.content
  if captured.truncated then
    text = text
      .. string.format(
        "\n\n[Results truncated: showing %d of at least %d entries]",
        captured.outputLines,
        captured.totalLines
      )
  end
  return { content = { { type = "text", text = text } }, details = { truncation = captured } }
end

---@return Neoagent.Tool<unknown>
local function new()
  local dependencies = common.dependencies()
  local tool = {
    name = "find",
    description = "Find files and directories with fd using a glob pattern, including hidden non-ignored entries.",
    input_schema = {
      type = "object",
      properties = {
        pattern = { type = "string" },
        path = { type = "string" },
        limit = { type = "number" },
      },
      required = { "pattern" },
      additionalProperties = false,
    },
    ---@async
    execute = function(arguments, ctx)
      return run(prepare(arguments), common.call(ctx), common.context_dependencies(ctx, dependencies))
    end,
    render = presentation.find,
  }
  return common.bind(tool, {
    token = IMPLEMENTATION,
    settings = {},
    prepare = prepare,
  })
end

---@class Neoagent.FindTool: Neoagent.Tool<unknown>
---@field execute async fun(arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<unknown>): Neoagent.ToolResult
---@field render? fun(options: Neoagent.ToolPresentationOptions): unknown
local M = new()
M.new = new
M.prepare = prepare
M.validate_request = validate_request
M.run = run
M._implementation = IMPLEMENTATION
return M
