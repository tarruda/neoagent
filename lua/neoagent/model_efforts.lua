local util = require("neoagent.util")

local M = {}

---@class Neoagent.OpenAIReasoningOptions
---@field summary? string|false
---@field encrypted? boolean

---@alias Neoagent.ResponseEffort { body: { reasoning: { effort: string, summary?: string }, include?: string[] } }
---@alias Neoagent.CompletionEffort { body: { reasoning_effort: string } }
---@class Neoagent.ThinkingEffortBody: Neoagent.JsonObject
---@field thinking {type: "enabled"|"disabled"}
---@field reasoning_effort? string

---@class Neoagent.ThinkingEffort: Neoagent.RequestOverride
---@field body Neoagent.ThinkingEffortBody
---@alias Neoagent.AdaptiveEffort { body: { thinking: { type: 'adaptive', display: 'summarized' }, output_config: { effort: Neoagent.ThinkingLevel } } }

---@param effort string
---@param opts? Neoagent.OpenAIReasoningOptions
---@return Neoagent.ResponseEffort
function M.openai_response(effort, opts)
  opts = opts or {}
  local reasoning = { effort = effort }
  if opts.summary ~= false then reasoning.summary = opts.summary or "auto" end
  local body = { reasoning = reasoning }
  if opts.encrypted ~= false then
    body.include = { "reasoning.encrypted_content" }
  end
  return { body = body }
end

---@param levels Neoagent.ThinkingLevel[]
---@param opts? Neoagent.OpenAIReasoningOptions
---@return table<Neoagent.ThinkingLevel, Neoagent.ResponseEffort>
function M.openai_responses(levels, opts)
  local result = {}
  for _, level in ipairs(levels) do
    local effort = level == "off" and "none" or level
    result[level] = M.openai_response(effort, opts)
  end
  return result
end

---@param levels Neoagent.ThinkingLevel[]
---@param mapping? table<Neoagent.ThinkingLevel, string>
---@return table<Neoagent.ThinkingLevel, Neoagent.CompletionEffort>
function M.openai_completions(levels, mapping)
  local result = {}
  mapping = mapping or {}
  for _, level in ipairs(levels) do
    result[level] = {
      body = { reasoning_effort = mapping[level]
        or (level == "off" and "none" or level) },
    }
  end
  return result
end

---@param levels Neoagent.ThinkingLevel[]
---@param mapping? table<Neoagent.ThinkingLevel, string>
---@return table<Neoagent.ThinkingLevel, Neoagent.ThinkingEffort>
function M.thinking_completions(levels, mapping)
  local result = {}
  mapping = mapping or {}
  for _, level in ipairs(levels) do
    local effort = mapping[level] or level
    if effort == "off" or effort == "none" then
      result[level] = { body = { thinking = { type = "disabled" } } }
    else
      result[level] = { body = {
        thinking = { type = "enabled" },
        reasoning_effort = effort,
      } }
    end
  end
  return result
end

---@param levels Neoagent.ThinkingLevel[]
---@return table<Neoagent.ThinkingLevel, Neoagent.AdaptiveEffort>
function M.anthropic_adaptive(levels)
  local result = {}
  for _, level in ipairs(levels) do
    result[level] = { body = {
      thinking = { type = "adaptive", display = "summarized" },
      output_config = { effort = level },
    } }
  end
  return result
end

---@generic T
---@param value T
---@return T
function M.copy(value)
  return util.copy(value)
end

return M
