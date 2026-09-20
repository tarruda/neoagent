local common = require("neoagent.tools.common")
local truncate = require("neoagent.tools.truncate")

local identities = require("neoagent.tools.identities")

---@class Neoagent.FindDependencies
---@field process async fun(command: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult

---@class Neoagent.FindRequest
---@field pattern string
---@field path? string
---@field resolved_path string
---@field limit integer

---@param options? Neoagent.ToolDependencyOverrides
---@return Neoagent.FindDependencies
local function dependencies(options)
  options = options or {}
  local process = options.process
  if process == nil then
    process = require("neoagent.process").run
  end
  assert(type(process) == "function", "Tool process runner is required")
  return {
    process = process,
  }
end

---@param value unknown
---@return Neoagent.FindRequest
local function validate_request(value)
  assert(common.object(value), "find request must be an object")
  ---@cast value table
  common.fields(value, { pattern = true, path = true, resolved_path = true, limit = true }, "find request")
  local result = {
    pattern = common.string(value.pattern, "find pattern", true),
    resolved_path = common.absolute_path(value.resolved_path, "find resolved path"),
    limit = common.integer(value.limit, "find limit"),
  }
  if value.path ~= nil then
    result.path = common.path(value.path, "find path")
  end
  return common.request(result, "find request")
end

---@param arguments Neoagent.JsonObject
---@param _settings table
---@param call Neoagent.ToolOperationCall
---@return Neoagent.FindRequest
local function prepare(arguments, _settings, call)
  return validate_request({
    pattern = common.require_string(arguments, "pattern", true),
    path = arguments.path and common.require_string(arguments, "path") or nil,
    resolved_path = arguments.path and common.resolve_path(common.require_string(arguments, "path"), call)
      or call.workspace.cwd,
    limit = arguments.limit or 1000,
  })
end

---@async
---@param request Neoagent.FindRequest
---@param _call Neoagent.ToolOperationCall
---@param dependencies Neoagent.FindDependencies
---@return Neoagent.ToolResult
local function run(request, _call, dependencies)
  local search = request.resolved_path
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
  local presentation = require("neoagent.tools.activity_presentation")
  local deps = dependencies()
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
      local call = common.call(ctx)
      return run(prepare(arguments, {}, call), call, deps)
    end,
    render = presentation.find,
  }
  return identities.bind(tool, {
    token = identities.find,
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
