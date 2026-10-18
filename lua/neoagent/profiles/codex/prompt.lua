-- Instructions adapted from OpenAI Codex 90f00bd89e (Apache-2.0).
local M = {}
---@type string?
local cached

---@return string
local function instructions()
  if not cached then
    local source = assert(debug.getinfo(1, "S")).source:gsub("^@", "")
    local path = vim.fs.joinpath(assert(vim.fs.dirname(source)), "instructions.md")
    local value, err = require("neoagent.fs").read(path)
    assert(value, "Failed to read Codex instructions: " .. tostring(err))
    cached = value
  end
  return cached
end

---@param context Neoagent.ProfilePromptContext
---@return Neoagent.PreparedProfilePrompt
function M.prepare(context)
  local prompt = context.base_prompt or instructions()
  if context.base_prompt == nil then
    for _, tool in ipairs(context.tools) do
      if tool.name == "update_plan" then
        prompt = prompt
          .. "\n\nUse update_plan to communicate a concise sequence of steps for substantial work. Keep at most one step in progress, update it as work advances, and mark completed steps accurately. Skip a plan for straightforward tasks."
        break
      end
    end
  end
  return {
    system_prompt = prompt,
    prepare_request = require("neoagent.profiles.codex.context").prepare(
      context,
      assert(require("neoagent.tools.command").argv("")[1])
    ),
  }
end

return M
