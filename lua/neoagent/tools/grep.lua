local common = require("neoagent.tools.common")
local truncate = require("neoagent.tools.truncate")

local function new()
  return {
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
    execute = function(arguments, ctx)
      local pattern = common.require_string(arguments, "pattern", true)
      local workspace = common.workspace(ctx)
      local limit = arguments.limit or 100
      if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then error("limit must be a positive integer") end
      local context = arguments.context
      if context ~= nil and (type(context) ~= "number" or context < 0 or context % 1 ~= 0) then
        error("context must be a non-negative integer")
      end
      local command = { "rg", "--line-number", "--with-filename", "--no-heading", "--color", "never", "--hidden" }
      if arguments.ignoreCase == true then command[#command + 1] = "--ignore-case" end
      if arguments.literal == true then command[#command + 1] = "--fixed-strings" end
      if arguments.glob ~= nil then
        if type(arguments.glob) ~= "string" then error("glob must be a string") end
        command[#command + 1] = "--glob"
        command[#command + 1] = arguments.glob
      end
      if context ~= nil then
        command[#command + 1] = "--context"
        command[#command + 1] = tostring(context)
      end
      command[#command + 1] = "--"
      command[#command + 1] = pattern
      command[#command + 1] = arguments.path and workspace:resolve(common.require_string(arguments, "path")) or "."
      local result = common.process(command, { cwd = workspace.cwd })
      if result.code ~= 0 and result.code ~= 1 then error("rg exited with status " .. result.code .. ": " .. result.stderr) end
      if result.code == 1 or result.stdout == "" then
        return { content = { { type = "text", text = "No matches found" } } }
      end
      local source = vim.split(result.stdout, "\n", { plain = true, trimempty = true })
      local output = {}
      local line_truncated = 0
      for index = 1, math.min(limit, #source) do
        local line, was_truncated = truncate.line(source[index])
        output[#output + 1] = line
        if was_truncated then line_truncated = line_truncated + 1 end
      end
      local text = table.concat(output, "\n")
      local shortened = truncate.head(text, { max_lines = limit, max_bytes = truncate.MAX_BYTES })
      text = shortened.content
      if #source > #output or shortened.truncated then
        text = text .. string.format("\n\n[Results truncated: showing %d of at least %d lines]", shortened.outputLines, #source)
      end
      return { content = { { type = "text", text = text } }, details = { truncation = shortened, lines_truncated = line_truncated } }
    end,
  }
end

local M = new()
M.new = new
return M
