local util = require("neoagent.util")

local M = {}

function M.default(context)
  local available = {}
  local names = {}
  for _, tool in ipairs(context.tools or {}) do
    names[tool.name] = true
    local description = type(tool.description) == "string" and util.trim(tool.description:gsub("%s+", " ")) or ""
    available[#available + 1] = "- " .. tool.name .. (description ~= "" and ": " .. description or "")
  end
  if #available == 0 then available[1] = "(none)" end

  local guidelines = {}
  if names.shell and not names.grep and not names.find then
    guidelines[#guidelines + 1] = "- Use shell for file operations such as ls, rg, and fd"
  end
  guidelines[#guidelines + 1] = "- Be concise in your responses"
  guidelines[#guidelines + 1] = "- Show file paths clearly when working with files"

  return table.concat({
    "You are Neo, an expert coding agent operating inside a Neovim. You help users by explaining things, reading files, executing commands, editing code, and writing new files.",
    "Available tools:\n" .. table.concat(available, "\n"),
    "Guidelines:\n" .. table.concat(guidelines, "\n"),
    "Current working directory: " .. context.workspace.cwd,
  }, "\n\n")
end

return M
