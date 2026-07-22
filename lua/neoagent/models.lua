local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}

function M.available(configured, manager)
  configured = configured or config.get()
  manager = manager or require("neoagent.auth").configured(configured)
  local result = {}
  for provider_id, provider in pairs(configured.providers) do
    local available = true
    if provider.auth then
      local err
      available, err = manager:has_credentials(provider.auth)
      if available == nil then return nil, err end
    elseif provider.api_key ~= nil then
      local ok, key = pcall(function()
        return type(provider.api_key) == "function" and provider.api_key() or provider.api_key
      end)
      if not ok then
        return nil, util.error("model", "Failed to resolve API key for " .. provider_id, key)
      end
      available = type(key) == "string" and util.trim(key) ~= ""
    end
    if available then
      for model_id in pairs(provider.models) do
        result[#result + 1] = provider_id .. "/" .. model_id
      end
    end
  end
  table.sort(result)
  return result
end

local function openai_factory(module, resolved)
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
    context_window = resolved.model.context_window,
    max_output_tokens = resolved.model.max_output_tokens,
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

function M.resolve(provider_id, model_id, configured, manager)
  configured = configured or config.get()
  if provider_id == nil or model_id == nil then
    local default = configured.default_model
    if not default then error("No default_model is configured") end
    provider_id = provider_id or default.provider
    model_id = model_id or default.model
  end
  local provider = configured.providers[provider_id]
  if not provider then error("Unknown provider: " .. tostring(provider_id)) end
  local model = provider.models[model_id]
  if not model then error("Unknown model: " .. tostring(provider_id) .. "/" .. tostring(model_id)) end
  local factory = configured.apis[provider.api]
  if not factory and provider.api == "openai-completions" then
    factory = function(value) return openai_factory("neoagent.api.openai_completions", value) end
  elseif not factory and provider.api == "openai-responses" then
    factory = function(value) return openai_factory("neoagent.api.openai_responses", value) end
  elseif not factory and provider.api == "openai-codex-responses" then
    factory = function(value) return openai_factory("neoagent.api.openai_codex_responses", value) end
  end
  if not factory then error("Unknown API: " .. tostring(provider.api)) end
  local resolved = {
    provider_id = provider_id,
    model_id = model_id,
    provider = util.copy(provider),
    model = util.copy(model),
  }
  local concrete = factory(resolved)
  assert(type(concrete) == "table" and type(concrete.stream) == "function", "API factory must return a Model")
  if concrete.context_window == nil then concrete.context_window = resolved.model.context_window end
  if concrete.thinking == nil then concrete.thinking = util.copy(resolved.model.thinking) end
  if provider.auth then
    manager = manager or require("neoagent.auth").configured(configured)
    concrete = manager:wrap(concrete, provider.auth)
  end
  return concrete
end

return M
