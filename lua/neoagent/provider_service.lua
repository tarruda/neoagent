local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.ProviderAuthContext
---@field resolve_auth fun(scope?: string): Neoagent.Run<Neoagent.AuthResolution, nil>

---@class Neoagent.ProviderServiceConfig
---@field api? string
---@field base_url? string
---@field service_opts? table<string, unknown>
---@field auth_optional? boolean

---@class Neoagent.ProviderServiceResources
---@field provider_id? string
---@field transport? Neoagent.ByteBackend
---@field ambient_api_key? fun(): string?
---@field report? fun(message: string, level: integer)
---@field now? fun(): number
---@field new_id? fun(): string

---@class Neoagent.ProviderDocument
---@field kind "document"
---@field name string
---@field filetype string
---@field content string

---@class Neoagent.ProviderOperationSuccess
---@field ok true
---@field artifact? Neoagent.ProviderDocument
---@field [string] unknown

---@alias Neoagent.ProviderOperationResult Neoagent.ProviderOperationSuccess|Neoagent.AsyncFailure
---@alias Neoagent.ProviderOperationRun Neoagent.Run<Neoagent.ProviderOperationResult, unknown>

---@class Neoagent.ProviderInteraction
---@field select fun(request: Neoagent.SelectRequest, done: Neoagent.AwaitCallbacks<unknown>): fun()?
---@field input fun(request: Neoagent.InputRequest, done: Neoagent.AwaitCallbacks<string>): fun()?
---@field confirm fun(request: Neoagent.ConfirmRequest, done: Neoagent.AwaitCallbacks<boolean>): fun()?
---@field progress fun(status: Neoagent.ProviderOperationStatus)
---@field notify fun(request: Neoagent.NotificationRequest|string, level?: integer)

---@class Neoagent.ProviderOperationContext: Neoagent.ProviderAuthContext
---@field provider {id: string, name: string, config: Neoagent.ProviderServiceConfig}
---@field args string
---@field interact Neoagent.ProviderInteraction

---@class Neoagent.ProviderOperation
---@field label string
---@field description? string
---@field mutating? boolean
---@field auth_scope? string
---@field complete? fun(arg_lead: string, args: string): string[]
---@field run fun(ctx: Neoagent.ProviderOperationContext): Neoagent.ProviderOperationRun

---@class Neoagent.ProviderOperationInfo
---@field id string
---@field label string
---@field description? string
---@field mutating boolean
---@field auth_scope? string

---@class Neoagent.ProviderService
---@field id string
---@field name string
---@field operations table<string, Neoagent.ProviderOperation>
---@field state fun(self: Neoagent.ProviderService): Neoagent.ProviderState|false
---@field subscribe? fun(self: Neoagent.ProviderService, listener: fun(state: Neoagent.ProviderState)): fun()
---@field on_event? fun(self: Neoagent.ProviderService, event: Neoagent.ModelEvent)
---@field wrap_model? fun(self: Neoagent.ProviderService, model: Neoagent.Model): Neoagent.Model
---@field destroy? fun(self: Neoagent.ProviderService)

---@class Neoagent.ProviderServiceSnapshot
---@field users integer
---@field operations integer
---@field busy boolean
---@field mutating boolean

---@class Neoagent.ProviderServiceSubscription
---@field listener fun(state: Neoagent.ProviderServiceSnapshot)
---@field report? fun(message: string, level: integer)

---@class Neoagent.ProviderServiceRuntime
---@field users integer
---@field operations table<integer, Neoagent.ProviderOperationToken>
---@field operation_count integer
---@field mutating? Neoagent.ProviderOperationToken
---@field next_operation_id integer
---@field listeners table<integer, Neoagent.ProviderServiceSubscription>
---@field next_listener_id integer
---@field retiring boolean
---@field destroy? fun()
---@field destroyed boolean

---@class Neoagent.ProviderResolveAuthOptions
---@field method? string
---@field manager? Neoagent.AuthManager
---@field optional? boolean
---@field scope? string

---@class Neoagent.ProviderOperationOptions
---@field args? string
---@field interact? Neoagent.ProviderInteraction
---@field coordination? Neoagent.ProviderOperationToken
---@field provider? Neoagent.ProviderServiceConfig
---@field resolve_auth? fun(scope?: string): Neoagent.Run<Neoagent.AuthResolution, nil>
---@field auth? Neoagent.AuthManager
---@field auth_method? string
---@field optional_auth? boolean
---@field on_event? fun(event: unknown)
---@field on_done? fun(result: Neoagent.ProviderOperationResult)

---@type table<Neoagent.ProviderService, Neoagent.ProviderServiceRuntime>
local default_runtimes = setmetatable({}, { __mode = "k" })
local MAX_DIAGNOSTIC_CHARACTERS = 512

---@param message string
---@return nil, Neoagent.Error
local function failure(message)
  return nil, util.error("provider", message)
end

---@param value unknown
---@param name string
---@param maximum integer
---@return string?, Neoagent.Error?
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

---@param id unknown
---@param value unknown
---@return Neoagent.ProviderOperation?, Neoagent.Error?
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
  if value.auth_scope ~= nil then
    local ok_scope, err_scope = valid_text(
      value.auth_scope, "operation " .. id .. " auth_scope", 128)
    if not ok_scope then return nil, err_scope end
    if not value.auth_scope:match("^[%w_.-]+$") then
      return failure("operation " .. id .. " auth_scope must be safe text")
    end
  end
  if value.complete ~= nil and type(value.complete) ~= "function" then
    return failure("operation " .. id .. " complete must be a function")
  end
  if type(value.run) ~= "function" then
    return failure("operation " .. id .. " requires a run function")
  end
  return value
end

---@param value unknown
---@return Neoagent.ProviderService?, Neoagent.Error?
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

---@param value unknown
---@return Neoagent.ProviderService
function M.assert(value)
  local service, err = M.validate(value)
  assert(service, err and err.message or "invalid Provider Service")
  return service
end

---@param service Neoagent.ProviderService
---@return Neoagent.ProviderOperationInfo[]
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
      auth_scope = operation.auth_scope,
    }
  end
  return result
end

---@return Neoagent.ProviderServiceRuntime
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

---@param service Neoagent.ProviderService
---@return Neoagent.ProviderServiceRuntime
local function runtime(service)
  local value = default_runtimes[service]
  if not value then
    value = new_runtime()
    default_runtimes[service] = value
  end
  return value
end

---@param err unknown
---@return string
local function subscriber_failure(err)
  local message = util.text_from_bytes(
    util.normalize_error(err, "provider").message)
  if vim.fn.strchars(message) > MAX_DIAGNOSTIC_CHARACTERS then
    message = vim.fn.strcharpart(message, 0, MAX_DIAGNOSTIC_CHARACTERS)
      .. "…"
  end
  return "neoagent: provider runtime subscriber failed: " .. message
end

---@param state Neoagent.ProviderServiceRuntime
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

---@param state Neoagent.ProviderServiceRuntime
---@return boolean
local function finish_retirement(state)
  if not state.retiring or state.destroyed or state.users > 0
      or state.operation_count > 0 then return false end
  state.destroyed = true
  local destroy = state.destroy
  state.destroy = nil
  if destroy then pcall(destroy) end
  return true
end

---@param service Neoagent.ProviderService
---@param listener fun(state: Neoagent.ProviderServiceSnapshot)
---@param opts? {report?: fun(message: string, level: integer)}
---@return fun(): boolean
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

---@param service Neoagent.ProviderService
---@return boolean
function M.busy(service)
  service = M.assert(service)
  return runtime(service).operation_count > 0
end

---@param service Neoagent.ProviderService
---@param operation Neoagent.ProviderOperation|Neoagent.ProviderOperationInfo
---@return boolean
function M.operation_enabled(service, operation)
  service = M.assert(service)
  local state = runtime(service)
  if state.retiring then return false end
  if operation.mutating == true then
    return state.users == 0 and state.operation_count == 0
  end
  return state.mutating == nil
end

---@param service Neoagent.ProviderService
---@return Neoagent.ProviderUseLease?, Neoagent.Error?
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
  ---@class Neoagent.ProviderUseLease
  ---@field active boolean
  local lease = { active = true }
  ---@return boolean
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

---@param service Neoagent.ProviderService
---@return (fun(): boolean)?, Neoagent.Error?
function M.acquire(service)
  local lease, err = M.acquire_use(service)
  if not lease then return nil, err end
  return function() return lease:release() end
end

---@param service Neoagent.ProviderService
---@param opts? {mutating?: boolean}
---@return Neoagent.ProviderOperationToken?, Neoagent.Error?
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
  ---@class Neoagent.ProviderOperationToken
  ---@field active boolean
  ---@field mutating boolean
  ---@field _service Neoagent.ProviderService
  ---@field _operation_id integer
  ---@field _phase "available"|"claimed"|"finished"
  ---@field _run? Neoagent.ProviderOperationRun
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
  ---@return boolean
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

---@param token Neoagent.ProviderOperationToken
---@param service Neoagent.ProviderService
---@param mutating boolean
---@return Neoagent.ProviderOperationToken?, Neoagent.Error?
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

---@param service Neoagent.ProviderService
---@param destroy fun()
---@return boolean
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

---@param provider unknown
---@return Neoagent.ProviderServiceConfig
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

---@param opts? Neoagent.ProviderResolveAuthOptions
---@return Neoagent.Run<Neoagent.AuthResolution, nil>
function M.resolve_auth(opts)
  opts = opts or {}
  return async.run(
  ---@return Neoagent.AuthResolution
  function()
    if opts.method == nil then
      return { ok = true, configured = false }
    end
    assert(type(opts.manager) == "table"
        and type(opts.manager.resolve) == "function",
      "provider operation auth manager is invalid")
    return opts.manager:resolve(opts.method, {
      optional = opts.optional == true,
      scope = opts.scope,
    }):await()
  end, { error_kind = "auth" })
end

---@return Neoagent.ProviderInteraction
function M.no_interact()
  ---@param _ unknown
  ---@param done Neoagent.AwaitCallbacks<unknown>
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

---@param service Neoagent.ProviderService
---@param operation_id string
---@param opts? Neoagent.ProviderOperationOptions
---@return Neoagent.ProviderOperationRun?, Neoagent.Error?
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

  local constructed, run = pcall(async.run,
  ---@return Neoagent.ProviderOperationResult
  function()
    ---@type Neoagent.ProviderOperationContext
    local ctx = {
      provider = {
        id = service.id,
        name = service.name,
        config = M.public_config(opts.provider or {}),
      },
      args = opts.args or "",
      resolve_auth = function(scope)
        if type(opts.resolve_auth) == "function" then
          return opts.resolve_auth(scope)
        end
        return M.resolve_auth({
          manager = opts.auth,
          method = opts.auth_method,
          optional = opts.optional_auth == true,
          scope = scope,
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
