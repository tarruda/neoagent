local thinking = require("neoagent.thinking")
local util = require("neoagent.util")

local M = {}

local function failure(provider_id, model_id, message, detail)
  local prefix = "Invalid model catalog for " .. tostring(provider_id)
  if model_id then prefix = prefix .. "/" .. tostring(model_id) end
  return nil, util.error("model", prefix .. ": " .. message, detail)
end

function M.safe_id(value)
  return type(value) == "string" and value ~= "" and #value <= 512
    and util.is_valid_utf8(value)
    and value:find("[%z\1-\31\127]") == nil
end

function M.safe_provider_id(value)
  return M.safe_id(value) and value:find("[/\\]") == nil
end

local function safe_name(value, maximum)
  return type(value) == "string" and value ~= "" and #value <= maximum
    and util.is_valid_utf8(value)
    and value:find("[%z\1-\31\127]") == nil
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
    and value ~= math.huge
end

function M.validate(provider_id, model_id, value)
  local model = util.copy(value)
  if model.id ~= nil and model.id ~= model_id then
    return failure(provider_id, model_id, "configuration id must match its key")
  end
  model.id = model_id
  if model.api ~= nil and not safe_name(model.api, 128) then
    return failure(provider_id, model_id,
      "api must be safe non-empty text of at most 128 bytes")
  end
  if model.name ~= nil and not safe_name(model.name, 256) then
    return failure(provider_id, model_id,
      "name must be safe non-empty text of at most 256 bytes")
  end
  if model.hidden ~= nil and type(model.hidden) ~= "boolean" then
    return failure(provider_id, model_id, "hidden must be boolean")
  end
  if model.input ~= nil then
    if not util.is_list(model.input) or #model.input == 0 then
      return failure(provider_id, model_id, "input must be a non-empty list")
    end
    local seen = {}
    for _, modality in ipairs(model.input) do
      if (modality ~= "text" and modality ~= "image") or seen[modality] then
        return failure(provider_id, model_id,
          "input must contain unique text or image entries")
      end
      seen[modality] = true
    end
  end
  for _, field in ipairs({
    "context_window", "max_output_tokens", "request_timeout_ms",
  }) do
    if model[field] ~= nil and not positive_integer(model[field]) then
      return failure(provider_id, model_id,
        field .. " must be a positive integer")
    end
  end
  if model.thinking ~= nil and model.thinking ~= false then
    if type(model.thinking) ~= "table"
        or next(model.thinking) ~= nil and util.is_list(model.thinking) then
      return failure(provider_id, model_id,
        "thinking must be an object or false")
    end
    for level, request_opts in pairs(model.thinking) do
      if not thinking.is_level(level) then
        return failure(provider_id, model_id,
          "unknown thinking level " .. tostring(level))
      end
      if request_opts ~= false and type(request_opts) ~= "table"
          and type(request_opts) ~= "function" then
        return failure(provider_id, model_id,
          "thinking levels must contain request options or false")
      end
    end
  end
  if model.reasoning == true and model.thinking ~= nil
      and model.thinking ~= false then
    return failure(provider_id, model_id,
      "thinking and static reasoning are mutually exclusive")
  end
  if model.request_opts ~= nil and type(model.request_opts) ~= "table"
      and type(model.request_opts) ~= "function" then
    return failure(provider_id, model_id,
      "request_opts must be a table or function")
  end
  for _, field in ipairs({
    "reasoning", "responses_lite",
  }) do
    if model[field] ~= nil and type(model[field]) ~= "boolean" then
      return failure(provider_id, model_id, field .. " must be boolean")
    end
  end
  for _, field in ipairs({
    "reasoning_effort", "reasoning_summary", "reasoning_context",
    "text_verbosity",
  }) do
    if model[field] ~= nil and not safe_name(model[field], 128) then
      return failure(provider_id, model_id,
        field .. " must be safe non-empty text")
    end
  end
  return model
end

function M.normalize_discoveries(provider_id, values)
  if type(values) ~= "table" or not util.is_list(values) then
    return failure(provider_id, nil, "discovery must return a model list")
  end
  local result, seen = {}, {}
  for _, value in ipairs(values) do
    local entry = type(value) == "string" and { id = value } or value
    if type(entry) ~= "table" or util.is_list(entry) then
      return failure(provider_id, nil, "discovery entries must be objects")
    end
    local id = entry.id
    if not M.safe_id(id) then
      return failure(provider_id, nil,
        "discovered ids must be safe non-empty text of at most 512 bytes")
    end
    if seen[id] then
      return failure(provider_id, id, "duplicate discovered id")
    end
    seen[id] = true
    result[#result + 1] = util.copy(entry)
  end
  table.sort(result, function(left, right) return left.id < right.id end)
  return result
end

return M
