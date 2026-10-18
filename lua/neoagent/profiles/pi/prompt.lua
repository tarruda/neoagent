-- Prompt composition adapted from Pi 3390bd9363 (MIT).
local util = require("neoagent.util")
local M = {}

---@param value string
---@return string
local function xml(value)
  return (value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

---@param context Neoagent.ProfilePromptContext
---@return Neoagent.PreparedProfilePrompt
function M.prepare(context)
  local names, available, rules, seen = {}, {}, {}, {}
  for _, tool in ipairs(context.tools) do
    names[tool.name] = true
    available[#available + 1] = "- " .. tool.name .. ": " .. (tool.prompt_snippet or tool.description)
  end
  local function add(rule)
    rule = util.trim(rule)
    if rule ~= "" and not seen[rule] then
      seen[rule] = true
      rules[#rules + 1] = "- " .. rule
    end
  end
  if not names.grep and not names.find and not names.ls then
    local shells = {}
    for _, name in ipairs({ "bash", "powershell", "shell" }) do
      if names[name] then
        shells[#shells + 1] = name
      end
    end
    if #shells > 0 then
      add("Use " .. table.concat(shells, " or ") .. " for file operations like listing, searching, and finding files")
    end
  end
  for _, tool in ipairs(context.tools) do
    for _, rule in ipairs(tool.prompt_guidelines or {}) do
      add(rule)
    end
  end
  add("Be concise in your responses")
  add("Show file paths clearly when working with files")
  local parts = {
    context.base_prompt
      or "You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.",
  }
  local function section(name, value)
    if value ~= "" then
      parts[#parts + 1] = "<" .. name .. ">\n" .. value .. "\n</" .. name .. ">"
    end
  end
  if context.base_prompt == nil then
    section(
      "tools",
      (#available > 0 and table.concat(available, "\n") or "(none)")
        .. "\n\nIn addition to the tools above, you may have access to other custom tools depending on the project."
    )
    section("rules", table.concat(rules, "\n"))
    local source = assert(debug.getinfo(1, "S")).source:gsub("^@", "")
    local root = assert(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))))))
    section(
      "docs",
      "For Neoagent configuration, provider access, or Lua APIs, read "
        .. vim.fs.joinpath(root, "doc", "neoagent.txt")
        .. "."
    )
  end
  local base = table.concat(parts, "\n\n")
  parts = {}
  local policy = #context.tools > 0
      and require("neoagent.profiles.execution").describe(context.execution_policy, context.tools)
    or ""
  section(
    "addendum",
    table.concat(
      vim.tbl_filter(function(value)
        return value ~= ""
      end, { policy, context.execution_guidance or "" }),
      "\n\n"
    )
  )
  local project = require("neoagent.agent_instructions").format(context.agent_instructions)
  if project ~= "" then
    parts[#parts + 1] = project
  end
  local read = names.read and "read" or names.bash and "bash" or nil
  if not read then
    for _, tool in ipairs(context.tools) do
      if tool.capabilities and tool.capabilities.read_files then
        read = tool.name
        break
      end
    end
  end
  if read and #context.skills > 0 then
    local lines = {
      "The following skills provide specialized instructions for specific tasks.",
      "Use the " .. read .. " tool to load a skill's file when the task matches its description.",
      "When a skill file references a relative path, resolve it against the skill directory and use that absolute path in tool commands.",
      "<available_skills>",
    }
    for _, skill in ipairs(context.skills) do
      lines[#lines + 1] = "<skill>\n<name>"
        .. xml(skill.name)
        .. "</name>\n<description>"
        .. xml(skill.description)
        .. "</description>\n<location>"
        .. xml(skill.path)
        .. "</location>\n</skill>"
    end
    lines[#lines + 1] = "</available_skills>"
    section("skills", table.concat(lines, "\n"))
  end
  section("cwd", context.workspace.cwd:gsub("\\", "/"))
  local environment = table.concat(parts, "\n\n")
  return {
    system_prompt = base,
    -- Context belongs to the retained turn environment, even when a request
    -- substitutes its own task instructions (for example summarization).
    prepare_request = function(request)
      return {
        messages = request.messages,
        system_prompt = (request.system_prompt or "") .. "\n\n" .. environment,
      }
    end,
  }
end

return M
