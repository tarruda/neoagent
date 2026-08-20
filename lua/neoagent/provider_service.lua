local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local RUNTIME_KEY = "_neoagent_provider_runtime"

local function failure(message)
  return nil, util.error("provider", message)
end

local function valid_text(value, name, maximum)
  if type(value) ~= "string" then
    return failure(name .. " must be a string")
  end
  if value == "" then
    return failure(name .. " must not be empty")
  end
  if #value > maximum then
    return failure(name .. " exceeds " .. tostring(maximum) .. " bytes")
  end
  if not util.is_valid_utf8(value) then
    return failure(name .. " must contain valid UTF-8")
  end
  if value:find("[%z\1-\31\127]") then
    return failure(name .. " must not contain control characters")
  end
  return value
end

local function validate_operation(id, value)
  local ok, err = valid_text(id, "operation id", 128)
  if not ok then return nil, err end
  if type(value) ~= "table" or util.is_list(value) then
    return failure("operation " .. id .. " must be an object")
  end
  local ok_label, err_label = valid_text(value.label, "operation " .. id .. " label", 128)
  if not ok_label then return nil, err_label end
  if value.description ~= nil then
    local ok_description, err_description = valid_text(
      value.description, "operation " .. id .. " description", 512)
    if not ok_description then return nil, err_description end
  end
  if value.mutating ~= nil and type(value.mutating) ~= "boolean" then
    return failure("operation " .. id .. " mutating must be a boolean")
  end
  if value.complete ~= nil and type(value.complete) ~= "function" then
    return failure("operation " .. id .. " complete must be a function")
  end
  if type(value.run) ~= "function" then
    return failure("operation " .. id .. " requires a run function")
  end
  return value
end

function M.validate(value)
  if type(value) ~= "table" or util.is_list(value) then
    return failure("Provider Service must be an object")
  end
  local ok, err = valid_text(value.id, "Provider Service id", 128)
  if not ok then return nil, err end
  ok, err = valid_text(value.name, "Provider Service name", 128)
  if not ok then return nil, err end
  if type(value.state) ~= "function" then
    return failure("Provider Service " .. value.id .. " requires a state function")
  end
  if type(value.operations) ~= "table"
      or (next(value.operations) ~= nil and util.is_list(value.operations)) then
    return failure("Provider Service " .. value.id .. " operations must be a keyed table")
  end
  for id, operation in pairs(value.operations) do
    local validated, validate_err = validate_operation(id, operation)
    if not validated then return nil, validate_err end
  end
  for _, method in ipairs({
    "get_models", "refresh_models", "refresh_catalog", "subscribe",
    "on_event", "destroy", "wrap_model",
  }) do
    if value[method] ~= nil and type(value[method]) ~= "function" then
      return failure("Provider Service " .. value.id .. " " .. method
        .. " must be a function")
    end
  end
  return value
end

function M.assert(value)
  local service, err = M.validate(value)
  assert(service, err and err.message or "invalid Provider Service")
  return service
end

function M.operations(service)
  service = M.assert(service)
  local ids = {}
  for id in pairs(service.operations) do ids[#ids + 1] = id end
  table.sort(ids)
  local result = {}
  for _, id in ipairs(ids) do
    local operation = service.operations[id]
    result[#result + 1] = {
      id = id,
      label = operation.label,
      description = operation.description,
      mutating = operation.mutating == true,
    }
  end
  return result
end

local function runtime(service)
  local value = rawget(service, RUNTIME_KEY)
  if value then return value end
  value = { users = 0, operation = nil }
  rawset(service, RUNTIME_KEY, value)
  return value
end

function M.busy(service)
  service = M.assert(service)
  return runtime(service).operation ~= nil
end

function M.operation_enabled(service, operation)
  service = M.assert(service)
  local state = runtime(service)
  return state.operation == nil
    and not (operation.mutating == true and state.users > 0)
end

function M.acquire(service)
  service = M.assert(service)
  local state = runtime(service)
  if state.operation and state.operation.mutating then
    return failure("Cannot start a model run during a mutating provider operation")
  end
  state.users = state.users + 1
  local active = true
  return function()
    if not active then return false end
    active = false
    state.users = math.max(0, state.users - 1)
    return true
  end
end

function M.public_config(provider)
  local result = {}
  if type(provider) ~= "table" then return result end
  if type(provider.api) == "string" then result.api = provider.api end
  if type(provider.base_url) == "string" then
    result.base_url = provider.base_url
  end
  if type(provider.service_opts) == "table" then
    result.service_opts = util.copy(provider.service_opts)
  end
  if type(provider.auth_optional) == "boolean" then
    result.auth_optional = provider.auth_optional
  end
  return result
end

function M.resolve_auth(opts)
  opts = opts or {}
  return async.run(function()
    if opts.method == nil then
      return { ok = true, configured = false }
    end
    assert(type(opts.manager) == "table"
        and type(opts.manager.resolve) == "function",
      "provider operation auth manager is invalid")
    return opts.manager:resolve(opts.method, {
      optional = opts.optional == true,
    }):await()
  end, { error_kind = "auth" })
end

function M.no_interact()
  local function unavailable(_, done)
    done.reject(util.error("provider",
      "Provider interaction is unavailable"))
  end
  return {
    select = unavailable,
    input = unavailable,
    confirm = unavailable,
    progress = function() end,
    notify = function() end,
  }
end

function M.run(service, operation_id, opts)
  service = M.assert(service)
  opts = opts or {}
  local descriptor = service.operations[operation_id]
  if not descriptor then
    return failure("Unknown provider operation: " .. tostring(operation_id))
  end
  local state = runtime(service)
  if state.operation ~= nil then
    return failure("A provider operation is already active")
  end
  if descriptor.mutating == true and state.users > 0 then
    return failure("Cannot run a mutating provider operation during an active model run")
  end
  if opts.args ~= nil and type(opts.args) ~= "string" then
    return failure("provider operation args must be a string")
  end
  if type(opts.args) == "string" and (#opts.args > 16384
      or not util.is_valid_utf8(opts.args)
      or opts.args:find("[%z\1-\31\127]")) then
    return failure("provider operation args must be safe text of at most 16384 bytes")
  end
  local model = opts.model
  if model ~= nil and (type(model) ~= "table" or util.is_list(model)
      or type(model.provider) ~= "string" or type(model.model) ~= "string") then
    return failure("provider operation model must identify provider and model")
  end
  local interact = opts.interact or M.no_interact()
  if type(interact) ~= "table" then
    return failure("provider operation interact must be a table")
  end
  for _, method in ipairs({ "select", "input", "confirm", "progress", "notify" }) do
    if type(interact[method]) ~= "function" then
      return failure("provider operation interact requires " .. method)
    end
  end

  local token = { mutating = descriptor.mutating == true }
  state.operation = token
  local run = async.run(function()
    local ctx = {
      provider = {
        id = service.id,
        name = service.name,
        config = M.public_config(opts.provider or {}),
      },
      args = opts.args or "",
      model = model and util.copy(model) or nil,
      agent_running = opts.agent_running == true,
      resolve_auth = function()
        if type(opts.resolve_auth) == "function" then
          return opts.resolve_auth()
        end
        return M.resolve_auth({
          manager = opts.auth,
          method = opts.auth_method,
          optional = opts.optional_auth == true,
        })
      end,
      interact = interact,
    }
    local ok, value = pcall(descriptor.run, ctx)
    if not ok then
      error(util.normalize_error(value, "provider"), 0)
    end
    if type(value) ~= "table" or type(value.cancel) ~= "function" then
      error(util.error("provider",
        "Provider operation " .. operation_id .. " must return a Run"), 0)
    end
    return value:await()
  end, {
    on_event = opts.on_event,
    on_done = function(result)
      if state.operation == token then state.operation = nil end
      if opts.on_done then opts.on_done(result) end
    end,
    error_kind = "provider",
  })
  token.run = run
  if run:is_done() and state.operation == token then state.operation = nil end
  return run
end

return M
