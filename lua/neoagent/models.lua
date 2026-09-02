local config = require("neoagent.config")
local model_contract = require("neoagent.model")
local provider_credentials = require("neoagent.provider_credentials")
local util = require("neoagent.util")

local M = {}

local function bind_transport(transport, context)
  if type(transport) == "table"
      and type(transport.with_context) == "function" then
    return transport.with_context(context)
  end
  return transport
end

local function validated_model(value, owner)
  return model_contract.assert(value, owner)
end

local function assert_runtimes(runtimes)
  assert(type(runtimes) == "table"
      and (next(runtimes) == nil or not util.is_list(runtimes)),
    "provider runtimes must be a keyed table")
  return runtimes
end

local function credentials(provider_id, provider, configured, manager, runtime)
  if manager == nil and runtime and runtime.credentials then
    return runtime.credentials
  end
  return provider_credentials.new({
    provider_id = provider_id,
    provider = provider,
    authentication = manager,
    method = configured.auth and configured.auth.methods
        and configured.auth.methods[provider.auth] or nil,
  })
end

function M.available(configured, manager, runtimes)
  configured = configured or config.get()
  runtimes = assert_runtimes(runtimes)
  manager = manager or require("neoagent.auth").configured(configured)
  local result = {}
  for provider_id, runtime in pairs(runtimes) do
    local provider = runtime.definition
    local credential_state = credentials(
      provider_id, provider, configured, manager, runtime):state()
    if credential_state.source == "error" then
      return nil, credential_state.error
    end
    if credential_state.usable then
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
    transport = resolved.transport,
  })
end

function M.resolve(provider_id, model_id, configured, manager, runtimes,
    http_context)
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
    transport = bind_transport(runtime.transport, util.deep_merge({
      provider = provider_id,
      model = model_id,
      origin = "model",
    }, http_context or {})),
  }
  if provider.auth and manager == nil then
    manager = require("neoagent.auth").configured(configured)
  end
  local provider_credential = credentials(
    provider_id, provider, configured, manager, runtime)
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
  if provider.api_key ~= nil then
    resolved.provider.api_key = function()
      return provider_credential:ambient_api_key()
    end
  end
  local concrete = validated_model(factory(resolved), "API factory")
  if concrete.context_window == nil then
    concrete.context_window = resolved.model.context_window
  end
  if concrete.thinking == nil then
    concrete.thinking = util.copy(resolved.model.thinking)
  end
  concrete = validated_model(concrete, "API factory")
  if provider.auth then
    concrete = validated_model(manager:wrap(concrete, provider.auth, {
      optional = provider.auth_optional == true or provider.api_key ~= nil,
    }), "Authentication Model wrapper")
  end
  local service = runtime.service
  if type(service.wrap_model) == "function" then
    concrete = validated_model(service:wrap_model(concrete),
      "Provider Service Model wrapper")
  end
  return concrete
end

return M
