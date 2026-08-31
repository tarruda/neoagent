local util = require("neoagent.util")

local M = {}

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

function M.openai_responses(levels, opts)
  local result = {}
  for _, level in ipairs(levels) do
    local effort = level == "off" and "none" or level
    result[level] = M.openai_response(effort, opts)
  end
  return result
end

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

function M.copy(value)
  return util.copy(value)
end

return M
