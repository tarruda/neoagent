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

  local sections = {
    "You are Neo, an expert coding agent operating inside a Neovim. You help users by explaining things, reading files, executing commands, editing code, and writing new files.",
    "Available tools:\n" .. table.concat(available, "\n"),
    "Guidelines:\n" .. table.concat(guidelines, "\n"),
  }
  if context.model and context.model.api == "openai-codex-responses" then
    sections[#sections + 1] = table.concat({
      "Working with the user:",
      "- Share concise progress updates in the `commentary` channel while you work.",
      "- End each turn with a self-contained answer in the `final` channel.",
      "- When a task uses tools or takes multiple steps, start with a commentary update and continue updating the user during ongoing work.",
    }, "\n")
  end
  sections[#sections + 1] = "Current working directory: " .. context.workspace.cwd
  return table.concat(sections, "\n\n")
end

function M.compose(prompt, context)
  local sections = { prompt }
  local agents = require("neoagent.agents").format(context.agents)
  local skills = require("neoagent.skills").format(context.skills)
  if agents ~= "" then sections[#sections + 1] = agents end
  if skills ~= "" then sections[#sections + 1] = skills end
  return table.concat(sections, "\n\n")
end

return M
