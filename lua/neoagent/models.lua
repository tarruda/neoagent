local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}

local function openai_factory(resolved)
  local layers = {}
  if resolved.provider.request_opts ~= nil then layers[#layers + 1] = resolved.provider.request_opts end
  if resolved.model.request_opts ~= nil then layers[#layers + 1] = resolved.model.request_opts end
  return require("neoagent.api.openai_completions").new({
    provider = resolved.provider_id,
    model = resolved.model_id,
    base_url = resolved.provider.base_url,
    api_key = resolved.provider.api_key,
    max_output_tokens = resolved.model.max_output_tokens,
    request_opts_layers = layers,
  })
end

function M.resolve(provider_id, model_id)
  local configured = config.get()
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
  if not factory and provider.api == "openai-completions" then factory = openai_factory end
  if not factory then error("Unknown API: " .. tostring(provider.api)) end
  local resolved = {
    provider_id = provider_id,
    model_id = model_id,
    provider = util.copy(provider),
    model = util.copy(model),
  }
  local concrete = factory(resolved)
  assert(type(concrete) == "table" and type(concrete.stream) == "function", "API factory must return a Model")
  return concrete
end

return M
