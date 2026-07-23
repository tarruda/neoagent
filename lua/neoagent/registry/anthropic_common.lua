local util = require("neoagent.util")

local M = {}

local CACHE_CONTROL = { type = "ephemeral" }
local INTERLEAVED_THINKING = "interleaved-thinking-2025-05-14"

local function budget_thinking(tokens)
  return {
    body = { thinking = {
      type = "enabled",
      budget_tokens = tokens,
      display = "summarized",
    } },
  }
end

local budget_profiles = {
  off = { body = { thinking = { type = "disabled" } } },
  minimal = budget_thinking(1024),
  low = budget_thinking(2048),
  medium = budget_thinking(8192),
  high = budget_thinking(16384),
}

local function adaptive_profiles(efforts)
  local result = {}
  for _, effort in ipairs(efforts) do
    result[effort] = { body = {
      thinking = { type = "adaptive", display = "summarized" },
      output_config = { effort = effort },
    } }
  end
  return result
end

local model_specs = {
  ["claude-opus-4-8"] = {
    context_window = 1000000,
    max_output_tokens = 128000,
    efforts = { "low", "medium", "high", "xhigh", "max" },
  },
  ["claude-opus-4-7"] = {
    context_window = 1000000,
    max_output_tokens = 128000,
    efforts = { "low", "medium", "high", "xhigh", "max" },
  },
  ["claude-opus-4-6"] = {
    context_window = 1000000,
    max_output_tokens = 128000,
    efforts = { "low", "medium", "high", "max" },
  },
  ["claude-sonnet-5"] = {
    context_window = 1000000,
    max_output_tokens = 128000,
    efforts = { "low", "medium", "high", "xhigh", "max" },
  },
  ["claude-fable-5"] = {
    context_window = 1000000,
    max_output_tokens = 128000,
    efforts = { "low", "medium", "high", "xhigh", "max" },
  },
  ["claude-sonnet-4-6"] = {
    context_window = 1000000,
    max_output_tokens = 128000,
    efforts = { "low", "medium", "high", "max" },
  },
  ["claude-haiku-4-5"] = { context_window = 200000, max_output_tokens = 64000 },
  ["claude-haiku-4-5-20251001"] = { context_window = 200000, max_output_tokens = 64000 },
  ["claude-opus-4-5"] = { context_window = 200000, max_output_tokens = 64000 },
  ["claude-opus-4-5-20251101"] = { context_window = 200000, max_output_tokens = 64000 },
  ["claude-sonnet-4-5"] = { context_window = 1000000, max_output_tokens = 64000 },
  ["claude-sonnet-4-5-20250929"] = { context_window = 1000000, max_output_tokens = 64000 },
  ["claude-opus-4-1"] = { context_window = 200000, max_output_tokens = 32000 },
  ["claude-opus-4-1-20250805"] = { context_window = 200000, max_output_tokens = 32000 },
}

function M.models()
  local result = {}
  for id, spec in pairs(model_specs) do
    result[id] = {
      context_window = spec.context_window,
      max_output_tokens = spec.max_output_tokens,
      thinking = spec.efforts and adaptive_profiles(spec.efforts) or util.copy(budget_profiles),
    }
  end
  return result
end

local function cache_system(system_prompt, identity)
  local result = {}
  if identity then
    result[#result + 1] = {
      type = "text",
      text = "You are Claude Code, Anthropic's official CLI for Claude.",
      cache_control = util.copy(CACHE_CONTROL),
    }
  end
  if type(system_prompt) == "string" and system_prompt ~= "" then
    result[#result + 1] = {
      type = "text",
      text = system_prompt,
      cache_control = util.copy(CACHE_CONTROL),
    }
  end
  return result
end

local function cache_messages(messages)
  local result = util.copy(messages)
  local last = result[#result]
  if not last or last.role ~= "user" then return result end
  if type(last.content) == "string" then
    last.content = { {
      type = "text",
      text = last.content,
      cache_control = util.copy(CACHE_CONTROL),
    } }
  elseif type(last.content) == "table" and #last.content > 0 then
    local block = last.content[#last.content]
    if block.type == "text" or block.type == "image" or block.type == "tool_result" then
      block.cache_control = util.copy(CACHE_CONTROL)
    end
  end
  return result
end

local function cache_tools(tools)
  local result = util.copy(tools)
  for _, tool in ipairs(result) do tool.eager_input_streaming = true end
  if #result > 0 then result[#result].cache_control = util.copy(CACHE_CONTROL) end
  return result
end

function M.request_opts(opts)
  opts = opts or {}
  return function(context)
    local body = context.request.body
    local override = { messages = cache_messages(body.messages) }
    if body.tools then override.tools = cache_tools(body.tools) end
    local identity = opts.claude_code_identity == true
    local system = cache_system(context.system_prompt, identity)
    if #system > 0 then override.system = system end
    local headers
    if identity then
      headers = {
        Accept = "application/json",
        ["anthropic-beta"] = table.concat({
          "claude-code-20250219",
          "oauth-2025-04-20",
          INTERLEAVED_THINKING,
        }, ","),
        ["anthropic-dangerous-direct-browser-access"] = "true",
        ["User-Agent"] = "claude-cli/2.1.75",
        ["x-app"] = "cli",
      }
    else
      local spec = model_specs[context.model.id]
      if spec and not spec.efforts then
        headers = { ["anthropic-beta"] = INTERLEAVED_THINKING }
      end
    end
    return { headers = headers or {}, body = override }
  end
end

M.interleaved_thinking = INTERLEAVED_THINKING

return M
