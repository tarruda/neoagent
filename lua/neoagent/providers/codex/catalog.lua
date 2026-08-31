local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local model_config = require("neoagent.model_config")
local util = require("neoagent.util")

local M = {}
-- Neoagent validates the supported Codex model metadata locally. Request the
-- complete account inventory independently from Codex CLI release gates.
local CATALOG_CLIENT_VERSION = "99.99.99"
local DEFAULT_TIMEOUT_MS = 15 * 1000
local DEFAULT_MAX_RESPONSE_BYTES = 1024 * 1024

local known_efforts = {
  none = "off",
  minimal = "minimal",
  low = "low",
  medium = "medium",
  high = "high",
  xhigh = "xhigh",
  max = "max",
  ultra = "ultra",
}

local function safe_text(value, maximum)
  return type(value) == "string" and value ~= "" and #value <= maximum
    and util.is_valid_utf8(value)
    and value:find("[%z\1-\31\127]") == nil
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
    and value ~= math.huge
end

local function model_entry(value)
  if type(value) ~= "table" or util.is_list(value)
      or not model_config.safe_id(value.slug) then
    return nil
  end
  local result = { id = value.slug }
  if safe_text(value.display_name, 256) then result.name = value.display_name end
  if value.visibility == "hide" or value.visibility == "none" then
    result.hidden = true
  elseif value.visibility ~= nil and value.visibility ~= "list" then
    return nil
  end
  if type(value.input_modalities) == "table"
      and util.is_list(value.input_modalities) then
    local input = {}
    for _, modality in ipairs(value.input_modalities) do
      if modality == "text" or modality == "image" then
        if not vim.tbl_contains(input, modality) then input[#input + 1] = modality end
      elseif modality ~= "audio" then
        return nil
      end
    end
    if #input > 0 then result.input = input end
  end
  local context_window = value.context_window or value.max_context_window
  if context_window ~= nil then
    if not positive_integer(context_window) then return nil end
    result.context_window = context_window
  end
  if value.use_responses_lite ~= nil then
    if type(value.use_responses_lite) ~= "boolean" then return nil end
    result.responses_lite = value.use_responses_lite
  end
  if safe_text(value.default_verbosity, 128) then
    result.text_verbosity = value.default_verbosity
  end
  local reasoning = value.supported_reasoning_levels
  if type(reasoning) ~= "table" or not util.is_list(reasoning) then return nil end
  result.reasoning_levels = {}
  local seen = {}
  for _, preset in ipairs(reasoning) do
    local effort = type(preset) == "table" and preset.effort or preset
    local level = known_efforts[effort]
    if level then
      if seen[level] then return nil end
      seen[level] = true
      result.reasoning_levels[#result.reasoning_levels + 1] = level
    end
  end
  local tiers = value.service_tiers
  if tiers ~= nil then
    if type(tiers) ~= "table" or not util.is_list(tiers) then return nil end
    result.service_tiers = {}
    for _, tier in ipairs(tiers) do
      local id = type(tier) == "table" and tier.id or tier
      if not safe_text(id, 128) then return nil end
      result.service_tiers[#result.service_tiers + 1] = id
    end
  end
  return result
end

local function parse(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.models) ~= "table" or not util.is_list(value.models)
      or #value.models > 256 then
    return nil
  end
  local result, seen = {}, {}
  for _, raw in ipairs(value.models) do
    local model = model_entry(raw)
    if not model or seen[model.id] then return nil end
    seen[model.id] = true
    result[#result + 1] = model
  end
  table.sort(result, function(left, right) return left.id < right.id end)
  return result
end

local function header(headers, selected)
  for key, value in pairs(type(headers) == "table" and headers or {}) do
    if type(key) == "string" and key:lower() == selected then
      if type(value) == "table" then value = value[#value] end
      return safe_text(value, 1024) and value or nil
    end
  end
end

local function base_url(value)
  value = value:gsub("/+$", "")
  return value:gsub("/codex/responses$", ""):gsub("/codex$", "")
end

function M.discover(ctx)
  local provider = ctx.provider
  local service_opts = provider.service_opts or {}
  local timeout_ms = service_opts.timeout_ms or DEFAULT_TIMEOUT_MS
  local maximum = service_opts.max_response_bytes or DEFAULT_MAX_RESPONSE_BYTES
  local transport = ctx.transport or curl
  return async.run(function()
    local resolved = ctx.resolve_auth():await()
    if resolved.ok == false then error(resolved.error, 0) end
    if resolved.configured ~= true or resolved.credential_type ~= "oauth" then
      error(util.error("auth",
        "ChatGPT subscription login is required to load Codex models"), 0)
    end
    local headers = util.copy(type(resolved.request_opts) == "table"
      and resolved.request_opts.headers or {})
    headers.Accept = "application/json"
    if ctx.validator and ctx.validator.etag then
      headers["If-None-Match"] = ctx.validator.etag
    end
    local fetched = transport.fetch({ request = {
      url = base_url(provider.base_url) .. "/codex/models?client_version="
        .. CATALOG_CLIENT_VERSION,
      method = "GET",
      headers = headers,
      timeout_ms = timeout_ms,
      max_response_bytes = maximum,
    } }):await()
    if fetched.ok == false then error(fetched.error, 0) end
    local etag = header(fetched.headers, "etag")
    if fetched.status == 304 then
      return {
        ok = true,
        unchanged = true,
        validator = etag and { etag = etag } or ctx.validator,
      }
    end
    if type(fetched.status) ~= "number" or fetched.status < 200
        or fetched.status >= 300 then
      local err = util.error("provider", "Codex model catalog request failed"
        .. (fetched.status and " (HTTP " .. fetched.status .. ")" or ""))
      err.status = fetched.status
      error(err, 0)
    end
    if type(fetched.body) ~= "string" or #fetched.body > maximum then
      error(util.error("provider",
        "Codex model catalog response is invalid"), 0)
    end
    local ok, decoded = pcall(vim.json.decode, fetched.body)
    local models = ok and parse(decoded) or nil
    if not models then
      error(util.error("provider",
        "Codex returned an invalid model catalog"), 0)
    end
    return {
      ok = true,
      models = models,
      validator = etag and { etag = etag } or nil,
    }
  end, { error_kind = "provider" })
end

M.parse = parse

return M
