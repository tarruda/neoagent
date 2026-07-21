local fs = require("neoagent.fs")
local common = require("neoagent.tools.common")

local function new()
  return {
    name = "write_file",
    description = "Write content to a file. Creates missing parent directories and completely overwrites the file.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to the file to write (relative or absolute)" },
        content = { type = "string", description = "Complete content to write" },
      },
      required = { "path", "content" },
      additionalProperties = false,
    },
    execute = function(arguments, ctx)
      local path = common.require_string(arguments, "path")
      local content = common.require_string(arguments, "content", true)
      local absolute = common.workspace(ctx):resolve(path)
      local ok, err = fs.mkdirp(vim.fs.dirname(absolute))
      if not ok then
        error("Could not create parent directory for " .. path .. ": " .. tostring(err))
      end
      ok, err = fs.write_all(absolute, content, "w", 420)
      if not ok then
        error("Could not write file " .. path .. ": " .. tostring(err))
      end
      return { content = { { type = "text", text = "Successfully wrote " .. #content .. " bytes to " .. path } } }
    end,
  }
end

local M = new()
M.new = new
return M
