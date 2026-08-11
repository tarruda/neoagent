local common = require("neoagent.tools.common")
local presentation = require("neoagent.tools.activity_presentation")
local truncate = require("neoagent.tools.truncate")

local function new()
  return {
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
    execute = function(arguments, ctx)
      local pattern = common.require_string(arguments, "pattern", true)
      local workspace = common.workspace(ctx)
      local limit = arguments.limit or 1000
      if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then error("limit must be a positive integer") end
      local search = arguments.path and workspace:resolve(common.require_string(arguments, "path")) or workspace.cwd
      local result, captured, captured_stderr = common.capture_process(ctx, {
        "fd", "--hidden", "--glob", "--", pattern, ".",
      }, {
        process = { cwd = search },
        stdout = {
          max_lines = limit,
          max_bytes = truncate.MAX_BYTES,
          max_line_bytes = truncate.MAX_BYTES + 1,
          transform = function(line)
            return line:gsub("\\", "/"):gsub("^%./", "")
          end,
        },
      })
      if result.code ~= 0 then
        error("find path is not a directory or fd exited with status "
          .. result.code .. ": " .. captured_stderr.content)
      end
      if captured.totalLines == 0 then
        return { content = { { type = "text", text = "No files found" } } }
      end
      local text = captured.content
      if captured.truncated then
        text = text .. string.format("\n\n[Results truncated: showing %d of at least %d entries]", captured.outputLines, captured.totalLines)
      end
      return { content = { { type = "text", text = text } }, details = { truncation = captured } }
    end,
    render = presentation.find,
  }
end

local M = new()
M.new = new
return M
