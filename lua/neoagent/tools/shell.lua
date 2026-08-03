local common = require("neoagent.tools.common")
local truncate = require("neoagent.tools.truncate")
local util = require("neoagent.util")

local DEFAULT_TIMEOUT_SECONDS = 300
local ESCAPE = "\27"

local function shell_argv(command)
  local argv = vim.fn.split(vim.o.shell)
  vim.list_extend(argv, vim.fn.split(vim.o.shellcmdflag))
  argv[#argv + 1] = command
  return argv
end

local function text_preserving_escape(value)
  local parts = {}
  local escaped = 0
  local start = 1
  while start <= #value do
    local position = value:find(ESCAPE, start, true)
    local finish = position and position - 1 or #value
    if finish >= start then
      local text, count = util.text_from_bytes(value:sub(start, finish))
      parts[#parts + 1] = text
      escaped = escaped + count
    end
    if not position then break end
    parts[#parts + 1] = ESCAPE
    start = position + 1
  end
  return table.concat(parts), escaped
end

local function output_capture(filesystem)
  local tail = ""
  local total_bytes = 0
  local completed_lines = 0
  local has_open_line = false
  local output_path
  local spill_error

  local function total_lines()
    return completed_lines + (has_open_line and 1 or 0)
  end

  local function is_truncated()
    return total_bytes > truncate.MAX_BYTES or total_lines() > truncate.MAX_LINES
  end

  local function count_lines(data)
    local newlines = 0
    local last_newline
    local start = 1
    while true do
      local position = data:find("\n", start, true)
      if not position then break end
      newlines = newlines + 1
      last_newline = position
      start = position + 1
    end
    completed_lines = completed_lines + newlines
    if last_newline then
      has_open_line = last_newline < #data
    elseif data ~= "" then
      has_open_line = true
    end
  end

  local function spill(data)
    local flags = output_path and "a" or "w"
    if not output_path then
      local err
      output_path, err = filesystem.create_temp("neoagent-shell-")
      if not output_path then
        spill_error = err
        return
      end
      data = tail
    end
    local ok, err = filesystem.write_all(output_path, data, flags, 384)
    if not ok then
      output_path = nil
      spill_error = err
    end
  end

  local function trim_tail()
    local max_bytes = truncate.MAX_BYTES * 2
    if #tail > max_bytes then tail = tail:sub(#tail - max_bytes + 1) end
  end

  local function append(data)
    total_bytes = total_bytes + #data
    count_lines(data)
    tail = tail .. data
    if not spill_error then
      if output_path then
        spill(data)
      elseif is_truncated() then
        spill(tail)
      end
    end
    if output_path or spill_error then trim_tail() end
  end

  local function snapshot(options)
    local text, escaped = util.text_from_bytes(tail)
    local result = truncate.tail(text, options)
    result.escapedBytes = escaped
    local ansi
    if tail:find(ESCAPE, 1, true) then
      local display_text, display_escaped = text_preserving_escape(tail)
      ansi = truncate.tail(display_text, options)
      ansi.escapedBytes = display_escaped
    end
    if not options then
      result.totalBytes = total_bytes
      result.totalLines = total_lines()
      result.truncated = is_truncated() or result.truncated
      if result.truncated and result.truncatedBy == nil then
        result.truncatedBy = total_bytes > truncate.MAX_BYTES and "bytes" or "lines"
      end
      if result.truncated and not output_path and not spill_error then spill(tail) end
    end
    return result, ansi
  end

  return {
    append = append,
    snapshot = snapshot,
    output_path = function() return output_path end,
    spill_error = function() return spill_error end,
  }
end

local function display(snapshot)
  local text = snapshot.content
  if snapshot.escapedBytes > 0 then text = "[Non-text output escaped]\n" .. text end
  return text
end

local function prefixed(prefix, text)
  return prefix .. "\n" .. text
end

local function valid_timeout(value)
  return type(value) == "number" and value > 0 and value < math.huge
end

local function new(options)
  options = options or {}
  assert(type(options) == "table", "shell options must be a table")
  local default_timeout = options.default_timeout
  if default_timeout == nil then default_timeout = DEFAULT_TIMEOUT_SECONDS end
  assert(default_timeout == false or valid_timeout(default_timeout),
    "shell default_timeout must be false or a positive finite number")
  local timeout_description = default_timeout == false
      and "Optional positive timeout in seconds"
    or "Positive timeout in seconds. Defaults to " .. default_timeout
  return {
    name = "shell",
    description = "Run a shell command in the workspace cwd. Returns combined text output, escaping non-text bytes and keeping the most recent 2,000 lines or 50 KiB.",
    input_schema = {
      type = "object",
      properties = {
        command = { type = "string", description = "Shell command to run" },
        timeout = { type = "number", description = timeout_description },
      },
      required = { "command" },
      additionalProperties = false,
    },
    execute = function(arguments, ctx)
      local command = common.require_string(arguments, "command")
      local timeout = arguments.timeout
      if timeout ~= nil and not valid_timeout(timeout) then
        error("timeout must be a positive finite number")
      end
      if timeout == nil then timeout = default_timeout end
      local capture = output_capture(common.fs(ctx))
      local last_update = 0
      local result = common.process(ctx, shell_argv(command), {
        capture = false,
        cwd = common.workspace(ctx).cwd,
        timeout_ms = timeout and math.floor(timeout * 1000) or nil,
        on_output = function(data)
          capture.append(data)
          local now = vim.uv.hrtime()
          if ctx.on_update and now - last_update >= 100 * 1000 * 1000 then
            last_update = now
            local snapshot, ansi = capture.snapshot({ max_lines = 12, max_bytes = 8 * 1024 })
            local update = { content = { { type = "text", text = display(snapshot) } } }
            if ansi then update.details = { ansi = ansi.content } end
            ctx.on_update(update)
          end
        end,
      })
      local shortened, ansi = capture.snapshot()
      local text = shortened.content == "" and "(no output)" or display(shortened)
      local ansi_text = ansi and ansi.content or nil
      local details = { exit_code = result.code, signal = result.signal, truncation = shortened }
      if shortened.truncated then
        local path = capture.output_path()
        if path then
          details.output_path = path
          local prefix = string.format("[Output truncated; full output: %s]", path)
          text = prefixed(prefix, text)
          if ansi_text then ansi_text = prefixed(prefix, ansi_text) end
        else
          local prefix = string.format("[Output truncated; could not save full output: %s]",
            tostring(capture.spill_error()))
          text = prefixed(prefix, text)
          if ansi_text then ansi_text = prefixed(prefix, ansi_text) end
        end
      end
      local is_error = result.timed_out or result.code ~= 0
      if result.timed_out then
        text = prefixed("[Command timed out]", text)
        if ansi_text then ansi_text = prefixed("[Command timed out]", ansi_text) end
      end
      if result.code ~= 0 and not result.timed_out then
        local prefix = "[Command exited with status " .. result.code .. "]"
        text = prefixed(prefix, text)
        if ansi_text then ansi_text = prefixed(prefix, ansi_text) end
      end
      if ansi_text then details.ansi = ansi_text end
      if ctx.on_update then
        local update = { content = { { type = "text", text = text } } }
        if ansi_text then update.details = { ansi = ansi_text } end
        ctx.on_update(update)
      end
      return { content = { { type = "text", text = text } }, details = details, isError = is_error }
    end,
  }
end

local M = new()
M.new = new
return M
