local thinking = require("neoagent.thinking")
local util = require("neoagent.util")

local M = {}

local function failure(message)
  return nil, util.error("model", message)
end

local function safe_text(value, name, maximum)
  if type(value) ~= "string" or value == "" or #value > maximum
      or not util.is_valid_utf8(value)
      or value:find("[%z\1-\31\127]") then
    return failure(name .. " must be safe non-empty text of at most "
      .. tostring(maximum) .. " bytes")
  end
  return value
end

local function positive_finite(value)
  return type(value) == "number" and value > 0 and value == value
    and value ~= math.huge and value ~= -math.huge
end

function M.capabilities(value)
  if type(value) ~= "table" or util.is_list(value) then
    return failure("Model must be an object")
  end
  local api, err = safe_text(value.api, "Model api", 128)
  if not api then return nil, err end
  local provider
  provider, err = safe_text(value.provider, "Model provider", 512)
  if not provider then return nil, err end
  local id
  id, err = safe_text(value.id, "Model id", 512)
  if not id then return nil, err end
  if type(value.stream) ~= "function" then
    return failure("Model requires a stream function")
  end
  if type(value.input) ~= "table" or not util.is_list(value.input)
      or #value.input == 0 then
    return failure("Model input must be a non-empty modality list")
  end
  local input, seen = {}, {}
  for _, modality in ipairs(value.input) do
    if (modality ~= "text" and modality ~= "image") or seen[modality] then
      return failure("Model input must contain unique text or image modalities")
    end
    seen[modality] = true
    input[#input + 1] = modality
  end
  if not seen.text then return failure("Model input must include text") end
  for _, name in ipairs({ "context_window", "timeout_ms" }) do
    if value[name] ~= nil and not positive_finite(value[name]) then
      return failure("Model " .. name .. " must be a positive finite number")
    end
  end
  local declared_thinking
  if value.thinking ~= nil then
    if type(value.thinking) ~= "table"
        or next(value.thinking) ~= nil and util.is_list(value.thinking) then
      return failure("Model thinking must be an object")
    end
    declared_thinking = {}
    for level, layer in pairs(value.thinking) do
      if not thinking.is_level(level) then
        return failure("Model thinking contains an unknown level: "
          .. tostring(level))
      end
      if layer ~= false and type(layer) ~= "table"
          and type(layer) ~= "function" then
        return failure("Model thinking levels must contain request-option layers")
      end
      if layer ~= false then declared_thinking[level] = util.copy(layer) end
    end
  end
  local result = {
    api = api,
    provider = provider,
    id = id,
    stream = value.stream,
    input = input,
  }
  if value.context_window ~= nil then result.context_window = value.context_window end
  if value.timeout_ms ~= nil then result.timeout_ms = value.timeout_ms end
  if declared_thinking ~= nil then result.thinking = declared_thinking end
  return result
end

function M.validate(value)
  local capabilities, err = M.capabilities(value)
  if not capabilities then return nil, err end
  value.input = capabilities.input
  value.thinking = capabilities.thinking
  return value
end

function M.assert(value, owner)
  local validated, err = M.validate(value)
  assert(validated, (owner or "Model") .. " must return a complete Model: "
    .. (err and err.message or "invalid Model"))
  return validated
end

return M
