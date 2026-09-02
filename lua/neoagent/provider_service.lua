local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local default_runtimes = setmetatable({}, { __mode = "k" })
local MAX_DIAGNOSTIC_CHARACTERS = 512

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
  local fields = {
    destroy = true,
    id = true,
    name = true,
    on_event = true,
    operations = true,
    state = true,
    subscribe = true,
    wrap_model = true,
  }
  for name in pairs(value) do
    if not fields[name] then
      return failure("unsupported Provider Service field " .. tostring(name))
    end
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
    "subscribe", "on_event", "destroy", "wrap_model",
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

local function new_runtime()
  return {
    users = 0,
    operations = {},
    operation_count = 0,
    mutating = nil,
    next_operation_id = 0,
    listeners = {},
    next_listener_id = 0,
    retiring = false,
    destroy = nil,
    destroyed = false,
  }
end

local function runtime(service)
  local value = default_runtimes[service]
  if not value then
    value = new_runtime()
    default_runtimes[service] = value
  end
  return value
end

local function subscriber_failure(err)
  local message = util.text_from_bytes(
    util.normalize_error(err, "provider").message)
  if vim.fn.strchars(message) > MAX_DIAGNOSTIC_CHARACTERS then
    message = vim.fn.strcharpart(message, 0, MAX_DIAGNOSTIC_CHARACTERS)
      .. "…"
  end
  return "neoagent: provider runtime subscriber failed: " .. message
end

local function publish_runtime(state)
  local snapshot = {
    users = state.users,
    operations = state.operation_count,
    busy = state.operation_count > 0,
    mutating = state.mutating ~= nil,
  }
  for _, subscription in pairs(state.listeners) do
    local ok, err = pcall(subscription.listener, util.copy(snapshot))
    if not ok and subscription.report then
      local message = subscriber_failure(err)
      util.schedule(function()
        pcall(subscription.report, message, vim.log.levels.ERROR)
      end)
    end
  end
end

local function finish_retirement(state)
  if not state.retiring or state.destroyed or state.users > 0
      or state.operation_count > 0 then return false end
  state.destroyed = true
  local destroy = state.destroy
  state.destroy = nil
  if destroy then pcall(destroy) end
  return true
end

function M.subscribe(service, listener, opts)
  service = M.assert(service)
  assert(type(listener) == "function",
    "Provider Service runtime listener must be a function")
  opts = opts or {}
  assert(type(opts) == "table"
      and (next(opts) == nil or not util.is_list(opts)),
    "Provider Service runtime subscription options must be an object")
  assert(opts.report == nil or type(opts.report) == "function",
    "Provider Service runtime subscription report must be a function")
  local state = runtime(service)
  state.next_listener_id = state.next_listener_id + 1
  local id = state.next_listener_id
  state.listeners[id] = { listener = listener, report = opts.report }
  local active = true
  return function()
    if not active then return false end
    active = false
    state.listeners[id] = nil
    return true
  end
end

function M.busy(service)
  service = M.assert(service)
  return runtime(service).operation_count > 0
end

function M.operation_enabled(service, operation)
  service = M.assert(service)
  local state = runtime(service)
  if state.retiring then return false end
  if operation.mutating == true then
    return state.users == 0 and state.operation_count == 0
  end
  return state.mutating == nil
end

function M.acquire_use(service)
  service = M.assert(service)
  local state = runtime(service)
  if state.retiring then
    return failure("Provider Service is retiring")
  end
  if state.mutating then
    return failure(
      "Cannot acquire provider use during a mutating provider operation")
  end
  state.users = state.users + 1
  publish_runtime(state)
  local lease = { active = true }
  function lease:release()
    if not self.active then return false end
    self.active = false
    state.users = math.max(0, state.users - 1)
    publish_runtime(state)
    finish_retirement(state)
    return true
  end
  return lease
end

function M.acquire(service)
  local lease, err = M.acquire_use(service)
  if not lease then return nil, err end
  return function() return lease:release() end
end

function M.begin_operation(service, opts)
  service = M.assert(service)
  opts = opts or {}
  assert(type(opts) == "table"
      and (next(opts) == nil or not util.is_list(opts)),
    "provider operation lease options must be an object")
  assert(opts.mutating == nil or type(opts.mutating) == "boolean",
    "provider operation mutating must be a boolean")
  local state = runtime(service)
  if state.retiring then return failure("Provider Service is retiring") end
  local mutating = opts.mutating == true
  if mutating then
    if state.users > 0 then
      return failure(
        "Cannot run a mutating provider operation during active provider use")
    end
    if state.operation_count > 0 then
      return failure("A provider operation is already active")
    end
  elseif state.mutating then
    return failure("A mutating provider operation is already active")
  end
  state.next_operation_id = state.next_operation_id + 1
  local id = state.next_operation_id
  local token = {
    active = true,
    mutating = mutating,
    _service = service,
    _operation_id = id,
    _phase = "available",
    _run = nil,
  }
  state.operations[id] = token
  state.operation_count = state.operation_count + 1
  if mutating then state.mutating = token end
  publish_runtime(state)
  function token:finish()
    if not self.active then return false end
    if state.operations[id] ~= self then return false end
    self.active = false
    state.operations[id] = nil
    state.operation_count = state.operation_count - 1
    if state.mutating == self then state.mutating = nil end
    self._phase = "finished"
    self._run = nil
    publish_runtime(state)
    finish_retirement(state)
    return true
  end
  return token
end

local function claim_operation(token, service, mutating)
  if type(token) ~= "table"
      or type(token.finish) ~= "function"
      or token.active ~= true
      or token._service ~= service
      or token.mutating ~= mutating
      or token._phase ~= "available" then
    return failure("provider operation coordination token is invalid")
  end
  local state = runtime(service)
  if state.operations[token._operation_id] ~= token then
    return failure("provider operation coordination token is invalid")
  end
  token._phase = "claimed"
  return token
end

function M.retire(service, destroy)
  service = M.assert(service)
  assert(type(destroy) == "function",
    "Provider Service retirement requires a destroy callback")
  local state = runtime(service)
  if state.retiring then return false end
  state.retiring = true
  state.destroy = destroy
  finish_retirement(state)
  return true
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
  if opts.args ~= nil and type(opts.args) ~= "string" then
    return failure("provider operation args must be a string")
  end
  if type(opts.args) == "string" and (#opts.args > 16384
      or not util.is_valid_utf8(opts.args)
      or opts.args:find("[%z\1-\31\127]")) then
    return failure("provider operation args must be safe text of at most 16384 bytes")
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

  local token = opts.coordination
  local token_err
  if token == nil then
    token, token_err = M.begin_operation(service, {
      mutating = descriptor.mutating == true,
    })
  end
  if not token then return nil, token_err end
  token, token_err = claim_operation(
    token, service, descriptor.mutating == true)
  if not token then return nil, token_err end

  local constructed, run = pcall(async.run, function()
    local ctx = {
      provider = {
        id = service.id,
        name = service.name,
        config = M.public_config(opts.provider or {}),
      },
      args = opts.args or "",
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
      token:finish()
      if opts.on_done then opts.on_done(result) end
    end,
    error_kind = "provider",
  })
  if not constructed then
    token:finish()
    return failure("Failed to construct provider operation Run: "
      .. util.normalize_error(run, "provider").message)
  end
  token._run = run
  if run:is_done() then token:finish() end
  return run
end

return M
