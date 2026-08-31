local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}

local function assert_runtimes(runtimes)
  assert(type(runtimes) == "table"
      and (next(runtimes) == nil or not util.is_list(runtimes)),
    "provider runtimes must be a keyed table")
  return runtimes
end

local function usable(provider_id, provider, manager)
  local available = true
  if provider.auth then
    local err
    available, err = manager:has_credentials(provider.auth)
    if available == nil then return nil, err end
    if provider.auth_optional == true then available = true end
  end
  if provider.api_key ~= nil and (provider.auth == nil or not available) then
    local ok, key = pcall(function()
      return type(provider.api_key) == "function"
          and provider.api_key() or provider.api_key
    end)
    if not ok then
      return nil, util.error("model",
        "Failed to resolve API key for " .. provider_id, key)
    end
    available = type(key) == "string" and util.trim(key) ~= ""
  end
  return available
end

function M.available(configured, manager, runtimes)
  configured = configured or config.get()
  runtimes = assert_runtimes(runtimes)
  manager = manager or require("neoagent.auth").configured(configured)
  local result = {}
  for provider_id, runtime in pairs(runtimes) do
    local provider = runtime.definition
    local available, available_err = usable(provider_id, provider, manager)
    if available == nil then return nil, available_err end
    if available then
      for model_id, model in pairs(runtime.catalog:snapshot().models) do
        if model.hidden ~= true then
          result[#result + 1] = provider_id .. "/" .. model_id
        end
      end
    end
  end
  table.sort(result)
  return result
end

function M.first_available(configured, manager, runtimes)
  local available, err = M.available(configured, manager, runtimes)
  if not available then return nil, err end
  local selected = available[1]
  if not selected then return nil end
  local provider, model = selected:match("^([^/]+)/(.+)$")
  return { provider = provider, model = model }
end

function M.subscribe_available(configured, manager, runtimes, listener)
  runtimes = assert_runtimes(runtimes)
  assert(type(listener) == "function",
    "available-model subscriber must be a function")
  local active = true
  local unsubscribes = {}
  local previous
  local function publish()
    if not active then return end
    local choices, err = M.available(configured, manager, runtimes)
    local value = choices and { choices = choices }
      or { error = util.copy(err) }
    if previous and vim.deep_equal(previous, value) then return end
    previous = util.copy(value)
    listener(choices and util.copy(choices) or nil, util.copy(err))
  end
  local ids = vim.tbl_keys(runtimes)
  table.sort(ids)
  for _, provider_id in ipairs(ids) do
    local catalog = runtimes[provider_id].catalog
    assert(type(catalog) == "table" and type(catalog.subscribe) == "function",
      "provider runtime catalog must support subscriptions")
    unsubscribes[#unsubscribes + 1] = catalog:subscribe(publish)
  end
  if #ids == 0 then publish() end
  return function()
    if not active then return false end
    active = false
    for _, unsubscribe in ipairs(unsubscribes) do pcall(unsubscribe) end
    unsubscribes = {}
    return true
  end
end

local function api_factory(module, resolved)
  local layers = {}
  if resolved.provider.request_opts ~= nil then
    layers[#layers + 1] = resolved.provider.request_opts
  end
  if resolved.model.request_opts ~= nil then
    layers[#layers + 1] = resolved.model.request_opts
  end
  local on_diagnostic
  if module == "neoagent.api.openai_codex_responses"
      and resolved.provider.diagnostics ~= false then
    local logger = require("neoagent.provider_log")
    local selected = resolved.provider.diagnostics
    local path = type(selected) == "table" and selected.path
      or logger.codex_path()
    on_diagnostic = logger.callback(path, { report = resolved.report })
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

function M.resolve(provider_id, model_id, configured, manager, runtimes)
  configured = configured or config.get()
  runtimes = assert_runtimes(runtimes)
  if provider_id == nil or model_id == nil then
    local default = configured.default_model
    if not default then error("No default_model is configured") end
    provider_id = provider_id or default.provider
    model_id = model_id or default.model
  end
  local runtime = runtimes[provider_id]
  if not runtime then error("Unknown provider: " .. tostring(provider_id)) end
  local provider = runtime.definition
  local model = runtime.catalog:snapshot().models[model_id]
  if not model then
    error("Unknown model: " .. tostring(provider_id) .. "/"
      .. tostring(model_id))
  end
  local api = model.api or provider.api
  local resolved = {
    api = api,
    provider_id = provider_id,
    model_id = model_id,
    provider = util.copy(provider),
    model = util.copy(model),
    report = runtime.report,
  }
  local factory = configured._apis[api]
  if not factory and api == "openai-completions" then
    factory = function(value)
      return api_factory("neoagent.api.openai_completions", value)
    end
  elseif not factory and api == "openai-responses" then
    factory = function(value)
      return api_factory("neoagent.api.openai_responses", value)
    end
  elseif not factory and api == "openai-codex-responses" then
    factory = function(value)
      return api_factory("neoagent.api.openai_codex_responses", value)
    end
  elseif not factory and api == "anthropic-messages" then
    factory = function(value)
      return api_factory("neoagent.api.anthropic_messages", value)
    end
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
        return type(ambient) == "function" and ambient() or ambient
      end
    end
  end
  local concrete = factory(resolved)
  assert(type(concrete) == "table" and type(concrete.stream) == "function",
    "API factory must return a Model")
  if concrete.context_window == nil then
    concrete.context_window = resolved.model.context_window
  end
  if concrete.input == nil then
    concrete.input = util.copy(resolved.model.input or { "text" })
  end
  if concrete.thinking == nil then
    concrete.thinking = util.copy(resolved.model.thinking)
  end
  if provider.auth then
    concrete = manager:wrap(concrete, provider.auth, {
      optional = provider.auth_optional == true or provider.api_key ~= nil,
    })
  end
  local service = runtime.service
  if type(service.wrap_model) == "function" then
    concrete = service:wrap_model(concrete)
  end
  return concrete
end

return M
