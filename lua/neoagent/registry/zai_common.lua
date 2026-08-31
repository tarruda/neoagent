local util = require("neoagent.util")

local M = {}

local specs = {
  ["glm-4.5"] = { 131072, 98304 },
  ["glm-4.5-air"] = { 131072, 98304 },
  ["glm-4.5-flash"] = { 131072, 98304 },
  ["glm-4.5v"] = { 64000, 16384 },
  ["glm-4.6"] = { 204800, 131072 },
  ["glm-4.6v"] = { 128000, 32768 },
  ["glm-4.7"] = { 204800, 131072 },
  ["glm-4.7-flash"] = { 200000, 131072 },
  ["glm-4.7-flashx"] = { 200000, 131072 },
  ["glm-5"] = { 204800, 131072 },
  ["glm-5-turbo"] = { 200000, 131072 },
  ["glm-5.1"] = { 200000, 131072 },
  ["glm-5.2"] = { 1000000, 131072 },
  ["glm-5.3"] = { 1000000, 131072 },
  ["glm-5.3-flash"] = { 1000000, 131072 },
  ["glm-5v-turbo"] = { 200000, 131072 },
}

local tool_stream_unsupported = {
  ["glm-4.5"] = true,
  ["glm-4.5-air"] = true,
  ["glm-4.5-flash"] = true,
  ["glm-4.5v"] = true,
}

local function thinking(enabled, effort, preserve)
  local selected = { type = enabled and "enabled" or "disabled" }
  if preserve and enabled then selected.clear_thinking = false end
  local body = { thinking = selected }
  if effort then body.reasoning_effort = effort end
  return { body = body }
end

local function thinking_levels(levels, preserve)
  local result = {}
  for _, level in ipairs(levels) do
    result[level] = thinking(level ~= "off", level ~= "off" and level or nil,
      preserve)
  end
  return result
end

local function toggle_levels(preserve)
  return {
    off = thinking(false, nil, preserve),
    high = thinking(true, nil, preserve),
  }
end

local function tool_stream(context)
  if #context.tools == 0 then return {} end
  return { body = { tool_stream = true } }
end

function M.transform(model, ctx)
  local spec = specs[model.id]
  local preserve = ctx.provider_id == "zai-coding-plan"
  local result = util.copy(model)
  result.input = (model.id:match("^glm%-.+v")
      or model.id == "glm-5.3-flash")
      and { "text", "image" } or { "text" }
  if spec then
    result.context_window = result.context_window or spec[1]
    result.max_output_tokens = result.max_output_tokens or spec[2]
  end
  if model.id:match("^glm%-5%.3") then
    result.thinking = thinking_levels({ "low", "high", "max" }, preserve)
  elseif model.id:match("^glm%-5%.2") then
    result.thinking = thinking_levels({ "off", "high", "max" }, preserve)
  elseif spec and model.id:match("^glm%-[45]") then
    result.thinking = toggle_levels(preserve)
  end
  if not tool_stream_unsupported[model.id] then
    result.request_opts = tool_stream
  end
  return result
end

function M.seed(ids)
  local result = {}
  for _, id in ipairs(ids) do result[#result + 1] = { id = id } end
  return result
end

return M
