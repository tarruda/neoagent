local util = require("neoagent.util")

local M = {}

---@class Neoagent.LlamaDefinition: Neoagent.ModelConfigInput
---@field id string
---@field router_id string
---@field hf_repo? string
---@field quantization? string
---@field load? table<string, string|number|boolean>
---@field input? ("text"|"image")[]
---@field context_window? integer
---@field max_output_tokens? integer
---@field request_timeout_ms? integer

---@param value string
---@return string, string?
function M.parse_source(value)
  local slash = value:find("/")
  if not slash then return value end
  local colon = value:find(":", slash + 1)
  if not colon then return value end
  return value:sub(1, colon - 1), value:sub(colon + 1)
end

-- Model definitions are plain tables under
-- `providers["llama.cpp"].catalog.additions`.
-- Each definition may name an HF source, recommended router load parameters,
-- and the inference parameters the openai-completions model entries accept.
local LOAD_LABELS = {
  ctx_size = "ctx",
  gpu_layers = "gpu-layers",
  threads = "threads",
  flash_attn = "flash-attn",
}

local LOAD_ORDER = { "ctx_size", "gpu_layers", "threads", "flash_attn" }
local LOAD_INDEX = {}
for index, name in ipairs(LOAD_ORDER) do LOAD_INDEX[name] = index end

---@param load? table<string, string|number|boolean>
---@return string[]
local function load_names(load)
  local names = {}
  for name in pairs(load or {}) do names[#names + 1] = name end
  table.sort(names, function(left, right)
    local left_index = LOAD_INDEX[left]
    local right_index = LOAD_INDEX[right]
    if left_index or right_index then
      if not left_index then return false end
      if not right_index then return true end
      return left_index < right_index
    end
    return left < right
  end)
  return names
end

---@param id string
---@param message string
---@return string
local function definition_error(id, message)
  return "llama.cpp model definition " .. id .. ": " .. message
end

---@param id string
---@param value unknown
---@return table<string, string|number|boolean>?
local function validate_load(id, value)
  if value == nil then return nil end
  assert(type(value) == "table" and not util.is_list(value),
    definition_error(id, "load must be an object"))
  local result = {}
  for name, entry in pairs(value) do
    assert(type(name) == "string" and name:match("^[%a][%w_-]*$"),
      definition_error(id, "load parameter names must contain letters, numbers, _ or -"))
    assert(name ~= "model" and name ~= "hf_repo" and name ~= "hf-repo",
      definition_error(id, "load parameter " .. name .. " is managed by the definition"))
    local kind = type(entry)
    assert(kind == "boolean" or kind == "string" or kind == "number",
      definition_error(id, "load " .. name .. " must be a string, number, or boolean"))
    if kind == "string" then
      assert(entry ~= "" and #entry <= 4096 and util.is_valid_utf8(entry)
          and not entry:find("[%z\1-\31\127]"),
        definition_error(id, "load " .. name .. " must be safe non-empty text"))
    elseif kind == "number" then
      assert(entry > -math.huge and entry < math.huge,
        definition_error(id, "load " .. name .. " must be finite"))
    end
    if name == "ctx_size" or name == "threads" then
      assert(kind == "number" and entry % 1 == 0 and entry > 0,
        definition_error(id, "load " .. name .. " must be positive"))
    elseif name == "gpu_layers" then
      assert(kind == "number" and entry % 1 == 0 and entry >= 0,
        definition_error(id, "load gpu_layers must be a non-negative integer"))
    elseif name == "flash_attn" then
      assert(kind == "boolean",
        definition_error(id, "load flash_attn must be a boolean"))
    end
    result[name] = entry
  end
  return result
end

---@param id string
---@param value unknown
---@return ("text"|"image")[]?
local function validate_input(id, value)
  if value == nil then return nil end
  assert(util.is_list(value) and #value > 0,
    definition_error(id, "input must be a non-empty list"))
  local seen = {}
  for _, modality in ipairs(value) do
    assert(modality == "text" or modality == "image",
      definition_error(id, "input entries must be text or image"))
    assert(not seen[modality],
      definition_error(id, "input entries must be unique"))
    seen[modality] = true
  end
  ---@cast value ("text"|"image")[]
  return util.copy(value)
end

---@param id string
---@param value unknown
---@return Neoagent.LlamaDefinition
local function model_definition(id, value)
  assert(type(id) == "string" and id ~= "" and #id <= 512
      and util.is_valid_utf8(id) and not id:find("[%z\1-\31\127]"),
    "llama.cpp model ids must be safe non-empty strings of at most 512 bytes")
  assert(type(value) == "table" and not util.is_list(value),
    definition_error(id, "must be an object"))
  local hf_repo, quantization
  if value.hf_repo ~= nil then
    assert(type(value.hf_repo) == "string" and value.hf_repo ~= ""
        and #value.hf_repo <= 512 and util.is_valid_utf8(value.hf_repo)
        and not value.hf_repo:find("[%z\1-\31\127]"),
      definition_error(id, "hf_repo must be safe non-empty text"))
    hf_repo, quantization = M.parse_source(value.hf_repo)
    assert(hf_repo:find("/") ~= nil,
      definition_error(id, "hf_repo must use the org/repo form"))
  end
  if value.quantization ~= nil then
    assert(type(value.quantization) == "string"
      and value.quantization:match("^[%w._-]+$")
      and #value.quantization <= 64,
      definition_error(id, "quantization must be a non-empty tag"))
    assert(quantization == nil or quantization == value.quantization,
      definition_error(id, "quantization conflicts with hf_repo"))
    quantization = value.quantization
  end
  if value.context_window ~= nil then
    assert(type(value.context_window) == "number"
      and value.context_window > 0 and value.context_window % 1 == 0,
      definition_error(id, "context_window must be a positive integer"))
  end
  if value.max_output_tokens ~= nil then
    assert(type(value.max_output_tokens) == "number"
      and value.max_output_tokens > 0 and value.max_output_tokens % 1 == 0,
      definition_error(id, "max_output_tokens must be a positive integer"))
  end
  if value.request_timeout_ms ~= nil then
    assert(type(value.request_timeout_ms) == "number"
      and value.request_timeout_ms > 0 and value.request_timeout_ms % 1 == 0,
      definition_error(id, "request_timeout_ms must be a positive integer"))
  end
  if value.thinking ~= nil and value.thinking ~= false then
    assert(type(value.thinking) == "table",
      definition_error(id, "thinking must be a table or false"))
  end
  if value.request_opts ~= nil then
    assert(type(value.request_opts) == "table"
      or type(value.request_opts) == "function",
      definition_error(id, "request_opts must be a table or function"))
  end
  local router_id = id
  if hf_repo then
    router_id = hf_repo .. (quantization and ":" .. quantization or "")
  end
  local definition = {
    id = id,
    router_id = router_id,
    hf_repo = hf_repo,
    quantization = quantization,
    load = validate_load(id, value.load),
    input = validate_input(id, value.input),
    context_window = value.context_window,
    max_output_tokens = value.max_output_tokens,
    request_timeout_ms = value.request_timeout_ms,
    thinking = value.thinking,
    request_opts = value.request_opts,
  }
  if definition.router_id ~= id
      and type(definition.request_opts) == "function" then
    error(definition_error(id,
      "request_opts must be a table when the id aliases an HF source"), 0)
  end
  ---@cast definition Neoagent.LlamaDefinition
  return definition
end

---@param models? table<string, unknown>
---@return table<string, Neoagent.LlamaDefinition>, string[], Neoagent.LlamaDefinition[]
function M.collect(models)
  local result = {}
  local order = {}
  local aliases = {}
  for id, value in pairs(models or {}) do
    if value ~= false then
      local definition = model_definition(id, value)
      result[id] = definition
      order[#order + 1] = id
      if definition.router_id ~= id then aliases[#aliases + 1] = definition end
    end
  end
  table.sort(order)
  return result, order, aliases
end

---@param definition Neoagent.LlamaDefinition
---@return string?
local function load_summary(definition)
  local parts = {}
  for _, name in ipairs(load_names(definition.load)) do
    local load = definition.load
    local value
    if load ~= nil then value = load[name] end
    if value ~= nil then
      local label = LOAD_LABELS[name] or name:gsub("_", "-")
      if value == true then
        parts[#parts + 1] = label
      elseif value == false then
        parts[#parts + 1] = "no-" .. label
      else
        parts[#parts + 1] = label .. " " .. tostring(value)
      end
    end
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

---@param definition Neoagent.LlamaDefinition
---@return string?
function M.summary(definition)
  local parts = {}
  if definition.router_id ~= definition.id then
    parts[#parts + 1] = definition.router_id
  end
  local load = load_summary(definition)
  if load then parts[#parts + 1] = load end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

-- The router applies load parameters through its own server-side preset, so
-- defined load values render as the matching `--models-preset` INI section.
---@param definitions table<string, Neoagent.LlamaDefinition>
---@param order string[]
---@return string
function M.preset_ini(definitions, order)
  local lines = { "version = 1", "" }
  local sections = 0
  for _, id in ipairs(order) do
    local definition = definitions[id]
    if definition.load and next(definition.load) ~= nil then
      sections = sections + 1
      lines[#lines + 1] = "[" .. definition.router_id .. "]"
      if definition.hf_repo then
        lines[#lines + 1] = "hf-repo = " .. definition.router_id
      end
      local load = definition.load
      for _, name in ipairs(load_names(load)) do
        local key = LOAD_LABELS[name] or name:gsub("_", "-")
        if name == "ctx_size" then key = "c" end
        if name == "gpu_layers" then key = "n-gpu-layers" end
        if name == "threads" then key = "t" end
        local value = load[name]
        if name == "flash_attn" then value = value and "on" or "off" end
        lines[#lines + 1] = key .. " = " .. tostring(value)
      end
      lines[#lines + 1] = ""
    end
  end
  return sections > 0 and table.concat(lines, "\n") or ""
end

return M
