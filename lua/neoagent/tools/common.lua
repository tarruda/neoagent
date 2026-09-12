local fs = require("neoagent.fs")
local process = require("neoagent.process")
local util = require("neoagent.util")

---@alias Neoagent.ToolWorkspace {
---  cwd: string,
---  resolve: (fun(self: Neoagent.ToolWorkspace, path: string): string),
---}

---@alias Neoagent.ToolFilesystem {
---  create_temp: (fun(prefix?: string, directory?: string): string?, string?),
---  read: (fun(path: string): string?, string?),
---  read_chunks?: (fun(path: string, on_chunk: fun(data: string, offset: integer), chunk_size?: integer): true?, unknown),
---  mkdirp: (fun(path?: string): true?, unknown),
---  write_all: (fun(path: string, data: string, flags?: string, mode?: integer): true?, string?),
---  atomic_replace: (fun(path: string, data: string, policy: Neoagent.AtomicPolicy): true?, Neoagent.FileIdentity|string|nil, Neoagent.AtomicFailureStage?),
---}

---@alias Neoagent.ToolCapabilities {
---  context?: unknown,
---  fs?: Neoagent.ToolFilesystem,
---  process?: (fun(command: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult),
---}

---@class Neoagent.LineCaptureOptions
---@field offset? number
---@field select_lines? number
---@field max_lines? number
---@field max_bytes? number
---@field max_line_bytes? number
---@field transform? fun(line: string, overflow: boolean, bytes: integer): string, boolean

---@class Neoagent.LineCaptureResult: Neoagent.TruncationResult
---@field firstLineBytes? integer
---@field linesTruncated integer
---@field selectionMore boolean

---@class Neoagent.LineCapture
---@field append fun(data: string)
---@field finish fun(trailing_empty?: boolean): Neoagent.LineCaptureResult

---@class Neoagent.CapturedProcessOptions: Neoagent.ProcessOptions
---@field on_output? fun(data: string, is_stderr: boolean)

---@class Neoagent.ProcessCaptureOptions
---@field stdout Neoagent.LineCaptureOptions
---@field stderr? Neoagent.LineCaptureOptions
---@field process? Neoagent.CapturedProcessOptions

local M = {}

---@param ctx? Neoagent.ToolCapabilities
---@return Neoagent.ToolWorkspace
function M.workspace(ctx)
  local context = ctx and ctx.context
  local workspace = type(context) == "table" and rawget(context, "workspace") or context
  if type(workspace) ~= "table" or type(workspace.resolve) ~= "function" then
    error(util.error("workspace", "Tool requires a workspace in ctx.context.workspace"), 0)
  end
  ---@cast workspace Neoagent.ToolWorkspace
  return workspace
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

---@param ctx? Neoagent.ToolCapabilities
---@return Neoagent.ToolFilesystem
function M.fs(ctx)
  return ctx and ctx.fs or fs
end

---@async
---@param ctx? Neoagent.ToolCapabilities
---@param command string[]
---@param opts? Neoagent.ProcessOptions
---@return Neoagent.ProcessResult
function M.process(ctx, command, opts)
  local run = ctx and ctx.process or process.run
  return run(command, opts)
end

---@param options? Neoagent.LineCaptureOptions
---@return Neoagent.LineCapture
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
  ---@return Neoagent.LineCaptureResult
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
---@param ctx? Neoagent.ToolCapabilities
---@param command string[]
---@param options Neoagent.ProcessCaptureOptions
---@return Neoagent.ProcessResult, Neoagent.LineCaptureResult, Neoagent.LineCaptureResult
function M.capture_process(ctx, command, options)
  options = options or {}
  local stdout = M.line_capture(assert(options.stdout, "stdout capture options are required"))
  local stderr = M.line_capture(options.stderr or {
    max_lines = 100,
    max_bytes = 50 * 1024,
    max_line_bytes = 50 * 1024 + 1,
  })
  local process_options = util.copy(options.process or {})
  local on_output = process_options.on_output
  process_options.capture = false
  process_options.on_output = function(data, is_stderr)
    if is_stderr then
      stderr.append(data)
    else
      stdout.append(data)
    end
    if on_output then
      on_output(data, is_stderr)
    end
  end
  local result = M.process(ctx, command, process_options)
  return result, stdout.finish(false), stderr.finish(false)
end

return M
