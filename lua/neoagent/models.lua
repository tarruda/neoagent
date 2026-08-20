local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}

local function invalid_dynamic(provider_id, message, detail)
  return nil, util.error("model",
    "Invalid dynamic model catalog for " .. provider_id .. ": " .. message,
    detail)
end

local function validate_dynamic_model(provider_id, entry)
  if type(entry) ~= "table" or util.is_list(entry) then
    return invalid_dynamic(provider_id, "entries must be objects")
  end
  if type(entry.id) ~= "string" or entry.id == "" or #entry.id > 512
      or not util.is_valid_utf8(entry.id)
      or entry.id:find("[%z\1-\31\127]") then
    return invalid_dynamic(provider_id,
      "dynamic model id must be safe non-empty text of at most 512 bytes")
  end
  if entry.api ~= nil and (type(entry.api) ~= "string"
      or entry.api == "" or #entry.api > 128
      or not util.is_valid_utf8(entry.api)
      or entry.api:find("[%z\1-\31\127]")) then
    return invalid_dynamic(provider_id,
      entry.id .. " api must be safe non-empty text of at most 128 bytes")
  end
  if entry.input ~= nil then
    if not util.is_list(entry.input) or #entry.input == 0 then
      return invalid_dynamic(provider_id, entry.id .. " input must be a non-empty list")
    end
    local seen = {}
    for _, modality in ipairs(entry.input) do
      if (modality ~= "text" and modality ~= "image") or seen[modality] then
        return invalid_dynamic(provider_id,
          entry.id .. " input must contain unique text or image entries")
      end
      seen[modality] = true
    end
  end
  for _, field in ipairs({
    "context_window", "max_output_tokens", "request_timeout_ms",
  }) do
    local value = entry[field]
    if value ~= nil and (type(value) ~= "number" or value <= 0
        or value % 1 ~= 0 or value == math.huge) then
      return invalid_dynamic(provider_id,
        entry.id .. " " .. field .. " must be a positive integer")
    end
  end
  if entry.thinking ~= nil and entry.thinking ~= false
      and type(entry.thinking) ~= "table" then
    return invalid_dynamic(provider_id, entry.id .. " thinking must be a table or false")
  end
  if entry.request_opts ~= nil and type(entry.request_opts) ~= "table"
      and type(entry.request_opts) ~= "function" then
    return invalid_dynamic(provider_id,
      entry.id .. " request_opts must be a table or function")
  end
  return entry
end

local function merged_models(provider, services, provider_id)
  local result = util.copy(provider.models or {})
  local removals = provider._model_removals
  local service = services and services[provider_id]
  if not service or type(service.get_models) ~= "function" then
    return result
  end
  local ok, discovered = pcall(service.get_models, service)
  if not ok then
    return invalid_dynamic(provider_id, "model catalog failed", discovered)
  end
  if type(discovered) ~= "table" or not util.is_list(discovered) then
    return invalid_dynamic(provider_id, "model catalog must be a list")
  end
  local seen = {}
  for _, entry in ipairs(discovered) do
    local valid, valid_err = validate_dynamic_model(provider_id, entry)
    if not valid then return nil, valid_err end
    if seen[entry.id] then
      return invalid_dynamic(provider_id,
        "duplicate dynamic model id " .. entry.id)
    end
    seen[entry.id] = true
    if not (removals and removals[entry.id]) then
      local existing = result[entry.id]
      if existing == nil then
        result[entry.id] = util.copy(entry)
      elseif type(existing) == "table" then
        result[entry.id] = util.deep_merge(util.copy(entry), existing)
      end
    end
  end
  return result
end

function M.available(configured, manager, services)
  configured = configured or config.get()
  manager = manager or require("neoagent.auth").configured(configured)
  local result = {}
  for provider_id, provider in pairs(configured.providers) do
    local available = true
    if provider.auth then
      local err
      available, err = manager:has_credentials(provider.auth)
      if available == nil then return nil, err end
      if provider.auth_optional == true then available = true end
    end
    if provider.api_key ~= nil and (provider.auth == nil or not available) then
      local ok, key = pcall(function()
        if type(provider.api_key) == "function" then return provider.api_key() end
        return provider.api_key
      end)
      if not ok then
        return nil, util.error("model", "Failed to resolve API key for " .. provider_id, key)
      end
      available = type(key) == "string" and util.trim(key) ~= ""
    end
    if available then
      local models, models_err = merged_models(provider, services, provider_id)
      if not models then return nil, models_err end
      for model_id, model in pairs(models) do
        if type(model) == "table" then
          result[#result + 1] = provider_id .. "/" .. model_id
        end
      end
    end
  end
  table.sort(result)
  return result
end

local function api_factory(module, resolved)
  local layers = {}
  if resolved.provider.request_opts ~= nil then layers[#layers + 1] = resolved.provider.request_opts end
  if resolved.model.request_opts ~= nil then layers[#layers + 1] = resolved.model.request_opts end
  local on_diagnostic
  if module == "neoagent.api.openai_codex_responses" and resolved.provider.diagnostics ~= false then
    local logger = require("neoagent.provider_log")
    local selected = resolved.provider.diagnostics
    local path = type(selected) == "table" and selected.path or logger.codex_path()
    on_diagnostic = logger.callback(path)
  end
  return require(module).new({
    provider = resolved.provider_id,
    model = resolved.model_id,
    base_url = resolved.provider.base_url,
    api_key = resolved.provider.api_key,
    input = resolved.model.input,
    context_window = resolved.model.context_window,
    max_output_tokens = resolved.model.max_output_tokens,
    timeout_ms = resolved.model.request_timeout_ms,
    reasoning = resolved.model.reasoning,
    reasoning_effort = resolved.model.reasoning_effort,
    reasoning_summary = resolved.model.reasoning_summary,
    reasoning_context = resolved.model.reasoning_context,
    responses_lite = resolved.model.responses_lite,
    text_verbosity = resolved.model.text_verbosity,
    thinking = resolved.model.thinking,
    request_opts_layers = layers,
    on_diagnostic = on_diagnostic,
  })
end

function M.resolve(provider_id, model_id, configured, manager, services)
  configured = configured or config.get()
  if provider_id == nil or model_id == nil then
    local default = configured.default_model
    if not default then error("No default_model is configured") end
    provider_id = provider_id or default.provider
    model_id = model_id or default.model
  end
  local provider = configured.providers[provider_id]
  if not provider then error("Unknown provider: " .. tostring(provider_id)) end
  local models, models_err = merged_models(provider, services, provider_id)
  if not models then error(models_err, 0) end
  local model = models[model_id]
  if not model then error("Unknown model: " .. tostring(provider_id) .. "/" .. tostring(model_id)) end
  local api = model.api or provider.api
  local resolved = {
    api = api,
    provider_id = provider_id,
    model_id = model_id,
    provider = util.copy(provider),
    model = util.copy(model),
  }
  local factory = configured.apis[api]
  if not factory and api == "openai-completions" then
    factory = function(value) return api_factory("neoagent.api.openai_completions", value) end
  elseif not factory and api == "openai-responses" then
    factory = function(value) return api_factory("neoagent.api.openai_responses", value) end
  elseif not factory and api == "openai-codex-responses" then
    factory = function(value) return api_factory("neoagent.api.openai_codex_responses", value) end
  elseif not factory and api == "anthropic-messages" then
    factory = function(value) return api_factory("neoagent.api.anthropic_messages", value) end
  end
  if not factory then error("Unknown API: " .. tostring(api)) end
  if provider.auth then
    manager = manager or require("neoagent.auth").configured(configured)
    if provider.api_key ~= nil then
      local ambient = provider.api_key
      resolved.provider.api_key = function()
        local stored, err = manager:has_credentials(provider.auth)
        if stored == nil then error(err, 0) end
        if stored then return nil end
        if type(ambient) == "function" then return ambient() end
        return ambient
      end
    end
  end
  local concrete = factory(resolved)
  assert(type(concrete) == "table" and type(concrete.stream) == "function", "API factory must return a Model")
  if concrete.context_window == nil then concrete.context_window = resolved.model.context_window end
  if concrete.input == nil then
    concrete.input = util.copy(resolved.model.input or { "text", "image" })
  end
  if concrete.thinking == nil then concrete.thinking = util.copy(resolved.model.thinking) end
  if provider.auth then
    concrete = manager:wrap(concrete, provider.auth, {
      optional = provider.auth_optional == true or provider.api_key ~= nil,
    })
  end
  local service = services and services[provider_id]
  if service and type(service.wrap_model) == "function" then
    concrete = service:wrap_model(concrete)
  end
  return concrete
end

return M
