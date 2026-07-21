local common = require("neoagent.tools.common")
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
      local stat = vim.uv.fs_stat(search)
      if not stat or stat.type ~= "directory" then error("find path is not a directory: " .. tostring(arguments.path or ".")) end
      local result = common.process({ "fd", "--hidden", "--glob", "--", pattern, "." }, { cwd = search })
      if result.code ~= 0 then error("fd exited with status " .. result.code .. ": " .. result.stderr) end
      local source = vim.split(result.stdout, "\n", { plain = true, trimempty = true })
      if #source == 0 then return { content = { { type = "text", text = "No files found" } } } end
      local output = {}
      for index = 1, math.min(limit, #source) do
        output[#output + 1] = source[index]:gsub("\\", "/"):gsub("^%./", "")
      end
      local shortened = truncate.head(table.concat(output, "\n"), { max_lines = limit, max_bytes = truncate.MAX_BYTES })
      local text = shortened.content
      if #source > #output or shortened.truncated then
        text = text .. string.format("\n\n[Results truncated: showing %d of at least %d entries]", shortened.outputLines, #source)
      end
      return { content = { { type = "text", text = text } }, details = { truncation = shortened } }
    end,
  }
end

local M = new()
M.new = new
return M
