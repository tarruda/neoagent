local common = require("neoagent.tools.common")
local fs = require("neoagent.fs")
local truncate = require("neoagent.tools.truncate")

local function new()
  return {
    name = "shell",
    description = "Run a shell command in the workspace cwd. Returns combined output, keeping the most recent 2,000 lines or 50 KiB.",
    input_schema = {
      type = "object",
      properties = {
        command = { type = "string", description = "Shell command to run" },
        timeout = { type = "number", description = "Optional positive timeout in seconds" },
      },
      required = { "command" },
      additionalProperties = false,
    },
    execute = function(arguments, ctx)
      local command = common.require_string(arguments, "command")
      local timeout = arguments.timeout
      if timeout ~= nil and (type(timeout) ~= "number" or timeout <= 0) then
        error("timeout must be a positive number")
      end
      local last_update = 0
      local result = common.process({ vim.o.shell, vim.o.shellcmdflag, command }, {
        cwd = common.workspace(ctx).cwd,
        timeout_ms = timeout and math.floor(timeout * 1000) or nil,
        on_output = function(_, _, _, _, output)
          local now = vim.uv.hrtime()
          if ctx.on_update and now - last_update >= 100 * 1000 * 1000 then
            last_update = now
            local snapshot = truncate.tail(output, { max_lines = 12, max_bytes = 8 * 1024 })
            ctx.on_update({ content = { { type = "text", text = snapshot.content } } })
          end
        end,
      })
      local output = result.output
      if output == "" then output = "(no output)" end
      local shortened = truncate.tail(output)
      local text = shortened.content
      local details = { exit_code = result.code, signal = result.signal, truncation = shortened }
      if shortened.truncated then
        local path = vim.fn.tempname() .. "-neoagent-shell.log"
        local ok, err = fs.write_all(path, output, "w", 384)
        if ok then
          details.output_path = path
          text = string.format("[Output truncated; full output: %s]\n%s", path, text)
        else
          text = string.format("[Output truncated; could not save full output: %s]\n%s", tostring(err), text)
        end
      end
      local is_error = result.timed_out or result.code ~= 0
      if result.timed_out then text = "[Command timed out]\n" .. text end
      if result.code ~= 0 and not result.timed_out then text = "[Command exited with status " .. result.code .. "]\n" .. text end
      if ctx.on_update then ctx.on_update({ content = { { type = "text", text = text } } }) end
      return { content = { { type = "text", text = text } }, details = details, isError = is_error }
    end,
  }
end

local M = new()
M.new = new
return M
