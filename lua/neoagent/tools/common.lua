local files = require("neoagent.files")
local semantic_message = require("neoagent.semantic_message")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.ToolWorkspace
---@field root string
---@field cwd string

---@class Neoagent.ToolOperationCall
---@field workspace Neoagent.ToolWorkspace
---@field artifacts? Neoagent.ToolArtifactPublisher
---@field on_update fun(update: Neoagent.ToolResult)

---@class Neoagent.ToolDependencies
---@field fs Neoagent.ToolFilesystem
---@field process async fun(command: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult
---@field workspace fun(value: Neoagent.ToolWorkspace): Neoagent.Workspace
---@field executable fun(name: string): boolean
---@field hrtime fun(): number
---@field artifact_publisher fun(call: Neoagent.ToolOperationCall): Neoagent.ToolArtifactPublisher
---@field fingerprint fun(data: string): string
---@field observe_output? fun(output: string)

---@class Neoagent.ToolDependencyOverrides
---@field fs? Neoagent.ToolFilesystem
---@field process? async fun(command: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult
---@field workspace? fun(value: Neoagent.ToolWorkspace): Neoagent.Workspace
---@field executable? fun(name: string): boolean
---@field hrtime? fun(): number
---@field artifact_publisher? fun(call: Neoagent.ToolOperationCall): Neoagent.ToolArtifactPublisher
---@field fingerprint? fun(data: string): string
---@field observe_output? fun(output: string)

---@class Neoagent.ToolArtifactPublisher
---@field put async fun(data: string): Neoagent.LocalFile?, Neoagent.Error?

---@class Neoagent.ToolLineCaptureOptions
---@field offset? number
---@field select_lines? number
---@field max_lines? number
---@field max_bytes? number
---@field max_line_bytes? number
---@field transform? fun(line: string, overflow: boolean, bytes: integer): string, boolean

---@class Neoagent.ToolLineCaptureResult: Neoagent.TruncationResult
---@field firstLineBytes? integer
---@field linesTruncated integer
---@field selectionMore boolean

---@class Neoagent.ToolLineCapture
---@field append fun(data: string)
---@field finish fun(trailing_empty?: boolean): Neoagent.ToolLineCaptureResult

---@class Neoagent.ToolProcessCaptureOptions
---@field stdout Neoagent.ToolLineCaptureOptions
---@field stderr? Neoagent.ToolLineCaptureOptions
---@field process? Neoagent.ProcessOptions

---@class Neoagent.ToolImplementationIdentity
---@field token table
---@field settings table
---@field prepare fun(arguments: Neoagent.JsonObject, settings: table): table

---@type table<function, Neoagent.ToolImplementationIdentity>
local implementations = setmetatable({}, { __mode = "k" })

---@param value unknown
---@return boolean
function M.object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

---@param value table
---@param allowed table<string, boolean>
---@param label string
function M.fields(value, allowed, label)
  for key in pairs(value) do
    assert(type(key) == "string" and allowed[key], label .. " has unsupported field " .. tostring(key))
  end
end

---@param value unknown
---@param label string
---@param allow_empty? boolean
---@return string
function M.string(value, label, allow_empty)
  assert(type(value) == "string" and (allow_empty or value ~= ""), label .. " must be a string")
  return value
end

---@param value unknown
---@param label string
---@return string
function M.path(value, label)
  local path = M.string(value, label)
  return path
end

---@param value unknown
---@param label string
---@param allow_zero? boolean
---@return integer
function M.integer(value, label, allow_zero)
  assert(
    type(value) == "number" and value % 1 == 0 and (allow_zero and value >= 0 or value > 0),
    label .. " must be " .. (allow_zero and "a non-negative" or "a positive") .. " integer"
  )
  ---@cast value integer
  return value
end

---@param arguments Neoagent.JsonObject
---@param key string
---@param allow_empty? boolean
---@return string
function M.require_string(arguments, key, allow_empty)
  local value = arguments[key]
  if type(value) ~= "string" or not allow_empty and value == "" then
    error(util.error("tool", key .. " must be " .. (allow_empty and "a string" or "a non-empty string")), 0)
  end
  return value
end

---@param value unknown
---@return Neoagent.ToolOperationCall
function M.validate_call(value)
  assert(M.object(value), "Tool operation call must be an object")
  ---@cast value table
  M.fields(value, { workspace = true, artifacts = true, on_update = true }, "Tool operation call")
  assert(M.object(value.workspace), "Tool workspace must be an object")
  M.fields(value.workspace, { root = true, cwd = true }, "Tool workspace")
  local root = M.path(value.workspace.root, "Tool workspace root")
  local cwd = M.path(value.workspace.cwd, "Tool workspace cwd")
  if value.artifacts ~= nil then
    assert(
      type(value.artifacts) == "table" and type(value.artifacts.put) == "function",
      "Tool artifacts must provide put"
    )
  end
  assert(type(value.on_update) == "function", "Tool on_update must be a function")
  return {
    workspace = { root = root, cwd = cwd },
    artifacts = value.artifacts and { put = value.artifacts.put } or nil,
    on_update = value.on_update,
  }
end

---@generic C
---@param ctx Neoagent.ToolContext<C>
---@return Neoagent.ToolOperationCall
function M.call(ctx)
  local composition = ctx and ctx.context
  local workspace = type(composition) == "table" and rawget(composition, "workspace") or composition
  if type(workspace) ~= "table" or type(workspace.root) ~= "string" or type(workspace.cwd) ~= "string" then
    error("Tool requires a workspace in ctx.context.workspace", 0)
  end
  local storage = type(composition) == "table" and rawget(composition, "files") or nil
  return M.validate_call({
    workspace = { root = workspace.root, cwd = workspace.cwd },
    artifacts = files.writable(storage) and { put = storage.put } or nil,
    on_update = ctx and ctx.on_update or function() end,
  })
end

---@param value unknown
---@return Neoagent.ToolResult
function M.result(value)
  local normalized, err = semantic_message.normalize_tool_result(value)
  assert(normalized, err)
  return normalized
end

---@param value unknown
---@return Neoagent.ToolResult
function M.update(value)
  local normalized, err = semantic_message.normalize_tool_result(value, { transient = true })
  assert(normalized, err)
  return normalized
end

---@param overrides? Neoagent.ToolDependencyOverrides
---@return Neoagent.ToolDependencies
function M.dependencies(overrides)
  overrides = overrides or {}
  local dependencies = {
    fs = overrides.fs or require("neoagent.fs"),
    process = overrides.process or require("neoagent.process").run,
    workspace = overrides.workspace or function(value)
      return require("neoagent.workspace").new(value)
    end,
    executable = overrides.executable or function(name)
      return vim.fn.executable(name) == 1
    end,
    hrtime = overrides.hrtime or vim.uv.hrtime,
    artifact_publisher = overrides.artifact_publisher or function(call)
      local publisher = call.artifacts
      if not publisher then
        error("Tool image result requires a writable attachment store", 0)
      end
      return publisher
    end,
    fingerprint = overrides.fingerprint or require("neoagent.fs").content_fingerprint,
    observe_output = overrides.observe_output,
  }
  assert(type(dependencies.fs) == "table", "Tool filesystem is required")
  assert(type(dependencies.process) == "function", "Tool process runner is required")
  assert(type(dependencies.workspace) == "function", "Tool workspace constructor is required")
  assert(type(dependencies.executable) == "function", "Tool executable lookup is required")
  assert(type(dependencies.hrtime) == "function", "Tool clock is required")
  assert(type(dependencies.artifact_publisher) == "function", "Tool artifact publisher is required")
  assert(type(dependencies.fingerprint) == "function", "Tool content fingerprint is required")
  assert(
    dependencies.observe_output == nil or type(dependencies.observe_output) == "function",
    "Tool output observer must be a function"
  )
  return dependencies
end

---@generic C
---@param tool Neoagent.Tool<C>
---@param identity Neoagent.ToolImplementationIdentity
---@return Neoagent.Tool<C>
function M.bind(tool, identity)
  assert(type(tool.execute) == "function", "Tool implementation requires execute")
  assert(type(identity) == "table" and type(identity.token) == "table", "Tool implementation token is required")
  assert(type(identity.settings) == "table", "Tool implementation settings are required")
  assert(type(identity.prepare) == "function", "Tool implementation prepare is required")
  implementations[tool.execute] = {
    token = identity.token,
    settings = util.copy(identity.settings),
    prepare = identity.prepare,
  }
  return tool
end

---@generic C
---@param tool Neoagent.Tool<C>
---@return Neoagent.ToolImplementationIdentity?
function M.identity(tool)
  local identity = type(tool) == "table" and implementations[tool.execute] or nil
  if not identity then
    return nil
  end
  return {
    token = identity.token,
    settings = util.copy(identity.settings),
    prepare = identity.prepare,
  }
end

---@param options? Neoagent.ToolLineCaptureOptions
---@return Neoagent.ToolLineCapture
function M.line_capture(options)
  options = options or {}
  local offset = options.offset or 1
  local select_lines = options.select_lines or math.huge
  local max_lines = options.max_lines or math.huge
  local max_bytes = options.max_bytes or math.huge
  local max_line_bytes = options.max_line_bytes or max_bytes + 1
  local transform = options.transform or function(line)
    return line, false
  end
  local kept = {}
  local output_bytes = 0
  local total_bytes = 0
  local total_lines = 0
  local current = ""
  local current_bytes = 0
  local current_overflow = false
  local had_data = false
  local ended_with_newline = false
  local truncated = false
  ---@type Neoagent.TruncationReason?
  local truncated_by
  local first_line_exceeds = false
  ---@type integer?
  local first_line_bytes
  local lines_truncated = 0
  local selection_more = false
  local finished = false

  ---@return boolean
  local function current_is_candidate()
    local relative = total_lines + 2 - offset
    return relative >= 1 and relative <= select_lines and relative <= max_lines and not truncated
  end

  ---@param fragment string
  local function append_fragment(fragment)
    current_bytes = current_bytes + #fragment
    if not current_is_candidate() then
      return
    end
    local remaining = max_line_bytes - #current
    if remaining > 0 then
      current = current .. fragment:sub(1, math.floor(remaining))
    end
    if #fragment > remaining then
      current_overflow = true
    end
  end

  local function finish_line()
    total_lines = total_lines + 1
    local relative = total_lines - offset + 1
    if relative >= 1 then
      if relative > select_lines then
        selection_more = true
      elseif relative > max_lines then
        truncated = true
        truncated_by = truncated_by or "lines"
      elseif not truncated then
        local line, line_was_truncated = transform(current, current_overflow, current_bytes)
        if line_was_truncated then
          lines_truncated = lines_truncated + 1
        end
        local extra = #line + (#kept > 0 and 1 or 0)
        if output_bytes + extra > max_bytes then
          truncated = true
          truncated_by = "bytes"
          if #kept == 0 then
            first_line_exceeds = true
            first_line_bytes = current_bytes
          end
        else
          kept[#kept + 1] = line
          output_bytes = output_bytes + extra
        end
      end
    end
    current = ""
    current_bytes = 0
    current_overflow = false
  end

  local capture = {}

  ---@param data string
  function capture.append(data)
    assert(not finished, "line capture is finished")
    if data == "" then
      return
    end
    had_data = true
    total_bytes = total_bytes + #data
    local start = 1
    while start <= #data do
      local newline = data:find("\n", start, true)
      append_fragment(data:sub(start, newline and newline - 1 or #data))
      if not newline then
        ended_with_newline = false
        break
      end
      finish_line()
      ended_with_newline = true
      start = newline + 1
    end
  end

  ---@param trailing_empty? boolean
  ---@return Neoagent.ToolLineCaptureResult
  function capture.finish(trailing_empty)
    assert(not finished, "line capture is finished")
    finished = true
    if trailing_empty or current_bytes > 0 or had_data and not ended_with_newline then
      finish_line()
    end
    local content = table.concat(kept, "\n")
    return {
      content = content,
      truncated = truncated,
      truncatedBy = truncated_by,
      totalLines = total_lines,
      totalBytes = total_bytes,
      outputLines = #kept,
      outputBytes = #content,
      maxLines = max_lines,
      maxBytes = max_bytes,
      firstLineExceedsLimit = first_line_exceeds,
      firstLineBytes = first_line_bytes,
      lastLinePartial = false,
      linesTruncated = lines_truncated,
      selectionMore = selection_more,
    }
  end

  return capture
end

---@async
---@param process async fun(command: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult
---@param command string[]
---@param options Neoagent.ToolProcessCaptureOptions
---@return Neoagent.ProcessResult, Neoagent.ToolLineCaptureResult, Neoagent.ToolLineCaptureResult
function M.capture_process(process, command, options)
  local stdout = M.line_capture(assert(options.stdout, "stdout capture options are required"))
  local stderr = M.line_capture(options.stderr or {
    max_lines = 100,
    max_bytes = 50 * 1024,
    max_line_bytes = 50 * 1024 + 1,
  })
  local process_options = util.copy(options.process or {})
  process_options.capture = false
  process_options.on_output = function(data, is_stderr)
    if is_stderr then
      stderr.append(data)
    else
      stdout.append(data)
    end
  end
  local result = process(command, process_options)
  return result, stdout.finish(false), stderr.finish(false)
end

---@alias Neoagent.ToolCapabilities {
---  context?: unknown,
---  fs?: Neoagent.ToolFilesystem,
---  process?: (fun(command: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult),
---}

---@param ctx? Neoagent.ToolCapabilities
---@return Neoagent.ToolFilesystem
function M.fs(ctx)
  return ctx and ctx.fs or require("neoagent.fs")
end

---@async
---@param ctx? Neoagent.ToolCapabilities
---@param command string[]
---@param opts? Neoagent.ProcessOptions
---@return Neoagent.ProcessResult
function M.process(ctx, command, opts)
  local run = ctx and ctx.process or require("neoagent.process").run
  return run(command, opts)
end

---@param ctx? Neoagent.ToolCapabilities
---@param defaults Neoagent.ToolDependencies
---@return Neoagent.ToolDependencies
function M.context_dependencies(ctx, defaults)
  if not ctx or not ctx.fs and not ctx.process then
    return defaults
  end
  return M.dependencies({
    fs = ctx.fs or defaults.fs,
    process = ctx.process or defaults.process,
  })
end

return M
