local common = require("neoagent.tools.common")
local truncate = require("neoagent.tools.truncate")

local identities = require("neoagent.tools.identities")

---@class Neoagent.GrepDependencies
---@field process async fun(command: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult

---@class Neoagent.GrepRequest
---@field pattern string
---@field path? string
---@field resolved_path string
---@field glob? string
---@field ignore_case boolean
---@field literal boolean
---@field context? integer
---@field limit integer

---@param options? Neoagent.ToolDependencyOverrides
---@return Neoagent.GrepDependencies
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
---@return Neoagent.GrepRequest
local function validate_request(value)
  assert(common.object(value), "grep request must be an object")
  ---@cast value table
  common.fields(value, {
    pattern = true,
    path = true,
    resolved_path = true,
    glob = true,
    ignore_case = true,
    literal = true,
    context = true,
    limit = true,
  }, "grep request")
  assert(type(value.ignore_case) == "boolean", "grep ignore_case must be a boolean")
  assert(type(value.literal) == "boolean", "grep literal must be a boolean")
  local result = {
    pattern = common.string(value.pattern, "grep pattern", true),
    resolved_path = common.absolute_path(value.resolved_path, "grep resolved path"),
    ignore_case = value.ignore_case,
    literal = value.literal,
    limit = common.integer(value.limit, "grep limit"),
  }
  if value.path ~= nil then
    result.path = common.path(value.path, "grep path")
  end
  if value.glob ~= nil then
    result.glob = common.string(value.glob, "grep glob", true)
  end
  if value.context ~= nil then
    result.context = common.integer(value.context, "grep context", true)
  end
  return common.request(result, "grep request")
end

---@param arguments Neoagent.JsonObject
---@param _settings table
---@param call Neoagent.ToolOperationCall
---@return Neoagent.GrepRequest
local function prepare(arguments, _settings, call)
  return validate_request({
    pattern = common.require_string(arguments, "pattern", true),
    path = arguments.path and common.require_string(arguments, "path") or nil,
    resolved_path = arguments.path and common.resolve_path(common.require_string(arguments, "path"), call)
      or call.workspace.cwd,
    glob = arguments.glob,
    ignore_case = arguments.ignoreCase == true,
    literal = arguments.literal == true,
    context = arguments.context,
    limit = arguments.limit or 100,
  })
end

---@async
---@param request Neoagent.GrepRequest
---@param call Neoagent.ToolOperationCall
---@param dependencies Neoagent.GrepDependencies
---@return Neoagent.ToolResult
local function run(request, call, dependencies)
  local command = { "rg", "--line-number", "--with-filename", "--no-heading", "--color", "never", "--hidden" }
  if request.ignore_case then
    command[#command + 1] = "--ignore-case"
  end
  if request.literal then
    command[#command + 1] = "--fixed-strings"
  end
  if request.glob ~= nil then
    command[#command + 1] = "--glob"
    command[#command + 1] = request.glob
  end
  if request.context ~= nil then
    command[#command + 1] = "--context"
    command[#command + 1] = tostring(request.context)
  end
  command[#command + 1] = "--"
  command[#command + 1] = request.pattern
  command[#command + 1] = request.path == nil and "." or request.resolved_path
  local result, captured, captured_stderr = common.capture_process(dependencies.process, command, {
    process = { cwd = request.path == nil and request.resolved_path or call.workspace.cwd },
    stdout = {
      max_lines = request.limit,
      max_bytes = truncate.MAX_BYTES,
      max_line_bytes = truncate.GREP_LINE_LENGTH * 4 + 1,
      transform = function(line)
        return truncate.line(line)
      end,
    },
  })
  if result.code ~= 0 and result.code ~= 1 then
    error("rg exited with status " .. result.code .. ": " .. captured_stderr.content)
  end
  if result.code == 1 or captured.totalLines == 0 then
    return { content = { { type = "text", text = "No matches found" } } }
  end
  local text = captured.content
  if captured.truncated then
    text = text
      .. string.format(
        "\n\n[Results truncated: showing %d of at least %d lines]",
        captured.outputLines,
        captured.totalLines
      )
  end
  return {
    content = { { type = "text", text = text } },
    details = { truncation = captured, lines_truncated = captured.linesTruncated },
  }
end

---@return Neoagent.Tool<unknown>
local function new()
  local presentation = require("neoagent.tools.activity_presentation")
  local deps = dependencies()
  local tool = {
    name = "grep",
    description = "Search file contents with ripgrep. Returns path:line: text matches and respects ignore files.",
    input_schema = {
      type = "object",
      properties = {
        pattern = { type = "string" },
        path = { type = "string" },
        glob = { type = "string" },
        ignoreCase = { type = "boolean" },
        literal = { type = "boolean" },
        context = { type = "number" },
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
    render = presentation.grep,
  }
  return identities.bind(tool, {
    token = identities.grep,
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
