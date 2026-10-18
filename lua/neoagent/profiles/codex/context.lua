-- Model-facing context adapted from OpenAI Codex 90f00bd89e (Apache-2.0).
local util = require("neoagent.util")

local M = {}

local skills_intro =
  "A skill is a set of instructions provided through a `SKILL.md` source. Below is the list of skills that can be used. Each entry includes a name, description, and source locator. `file` locators are on the host filesystem."

local skills_usage =
  [[- Discovery: The list above is the skills available in this session (name + description + source locator). `file` entries live on the host filesystem.
- Trigger rules: If the user names a skill (with `$SkillName` or plain text) OR the task clearly matches a skill's description shown above, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.
- Missing/blocked: If a named skill isn't in the list or the path can't be read, say so briefly and continue with the best fallback.
- How to use a skill:
  1) After deciding to use a skill, open and read its `SKILL.md` completely before taking task actions.
  2) When `SKILL.md` references another file, resolve relative paths against the directory containing `SKILL.md`.
  3) If `SKILL.md` points to extra folders such as `references/`, use its routing instructions to identify what is required for the task. Read each required instruction or reference before acting.
  4) Prefer running or patching scripts supplied by the skill instead of retyping large code blocks.
  5) Reuse supplied assets or templates instead of recreating them.
- Coordination and sequencing:
  - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.
  - Announce which skill(s) you're using and why. If you skip an obvious skill, say why.
- Context hygiene:
  - Progressive disclosure applies to selecting relevant files, not partially reading a selected instruction file. Do not load unrelated references, scripts, or assets.
  - Avoid deep reference-chasing: prefer files directly linked from `SKILL.md` unless blocked.
  - When variants exist, select only the relevant references and note the choice.
- Safety and fallback: If a skill can't be applied cleanly, state the issue, choose the best alternative, and continue.]]

---@param value string
---@return string
local function escape_xml(value)
  return (value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

---@param context Neoagent.ProfilePromptContext
---@param shell string
---@return string
local function environment(context, shell)
  local name = vim.fs.basename(shell) or shell
  local lines = {
    "<environment_context>",
    "  <cwd>" .. escape_xml(context.workspace.cwd) .. "</cwd>",
    "  <shell>" .. escape_xml(name) .. "</shell>",
    "  <current_date>" .. os.date("%Y-%m-%d") .. "</current_date>",
  }
  local timezone = os.date("%Z")
  if timezone ~= "" then
    lines[#lines + 1] = "  <timezone>" .. escape_xml(timezone) .. "</timezone>"
  end
  lines[#lines + 1] = "</environment_context>"
  return table.concat(lines, "\n")
end

---@param context Neoagent.ProfilePromptContext
---@return string?
local function skills(context)
  local values = context.skills or {}
  if #values == 0 then
    return nil
  end
  local lines = { "<skills_instructions>", "## Skills", skills_intro, "### Available skills" }
  for _, skill in ipairs(values) do
    lines[#lines + 1] = "- " .. skill.name .. ": " .. skill.description .. " (file: " .. skill.path .. ")"
  end
  lines[#lines + 1] = "### How to use skills"
  lines[#lines + 1] = skills_usage
  lines[#lines + 1] = "</skills_instructions>"
  return table.concat(lines, "\n")
end

---@param context Neoagent.ProfilePromptContext
---@param default_shell string
---@return Neoagent.PrepareRequest
function M.prepare(context, default_shell)
  assert(type(default_shell) == "string" and default_shell ~= "", "Codex context requires a default shell")
  local developer = {}
  local policy = #context.tools > 0
      and require("neoagent.profiles.execution").describe(context.execution_policy, context.tools)
    or ""
  if policy ~= "" then
    developer[#developer + 1] = policy
  end
  local skill_catalog = skills(context)
  if skill_catalog then
    developer[#developer + 1] = skill_catalog
  end
  if context.execution_guidance and context.execution_guidance ~= "" then
    developer[#developer + 1] = context.execution_guidance
  end
  local user = {}
  local instructions = require("neoagent.agent_instructions").format(context.agent_instructions)
  if instructions ~= "" then
    user[#user + 1] = instructions
  end
  user[#user + 1] = environment(context, default_shell)

  return function(request)
    local additions = {}
    if #developer > 0 then
      additions[#additions + 1] = { role = "developer", content = table.concat(developer, "\n\n") }
    end
    additions[#additions + 1] = { role = "userContext", content = table.concat(user, "\n\n") }
    vim.list_extend(additions, util.copy(request.messages))
    return {
      messages = additions,
      system_prompt = request.system_prompt,
    }
  end
end

return M
