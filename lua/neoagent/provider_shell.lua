local Applet = require("applet")
local async = require("neoagent.async")
local provider_service = require("neoagent.provider_service")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}
local ProviderShell = {}
ProviderShell.__index = ProviderShell

local LOGIN = "neoagent.auth.login"
local LOGOUT = "neoagent.auth.logout"
local CANCEL_LOGIN = "neoagent.auth.cancel"
local REFRESH_CATALOG = "neoagent.catalog.refresh"
local CHOOSE_PRESENTATION = "neoagent.presentation.choose:"
local CANCEL_PRESENTATION = "neoagent.presentation.cancel"

local function feedback_text(value)
  local text = util.text_from_bytes(value):gsub("%s+", " ")
  text = util.trim(text):gsub("^neoagent:%s*", "")
  if text == "" then text = "Provider notification" end
  if #text <= 512 then return text end
  text = text:sub(1, 509)
  while not util.is_valid_utf8(text) do text = text:sub(1, -2) end
  return text .. "…"
end

local function feedback_level(level)
  if level == vim.log.levels.ERROR then return "error" end
  if level == vim.log.levels.WARN then return "warn" end
  return "info"
end

local function external_credential(provider)
  local source = provider and provider.api_key
  if source == nil then return false end
  local ok, value = pcall(function()
    return type(source) == "function" and source() or source
  end)
  if not ok then
    return nil, util.error("auth",
      "Failed to resolve the provider environment credential", value)
  end
  if type(value) ~= "string" or util.trim(value) == "" then return false end
  return type(source) == "string" and "configured" or "environment"
end

local function valid_artifact(artifact)
  return type(artifact) == "table" and not util.is_list(artifact)
    and artifact.kind == "document"
    and type(artifact.name) == "string" and artifact.name ~= ""
    and #artifact.name <= 128 and util.is_valid_utf8(artifact.name)
    and type(artifact.filetype) == "string"
    and artifact.filetype:match("^[%w_.+-]*$") ~= nil
    and #artifact.filetype <= 64
    and type(artifact.content) == "string"
    and #artifact.content <= 1024 * 1024
    and util.is_valid_utf8(artifact.content)
end

function ProviderShell.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "Provider Shell config is required")
  assert(type(opts.auth) == "table"
      and type(opts.auth.has_credentials) == "function"
      and type(opts.auth.resolve) == "function",
    "Provider Shell authentication manager is invalid")
  assert(type(opts.runtimes) == "table"
      and (next(opts.runtimes) == nil or not util.is_list(opts.runtimes)),
    "Provider Shell runtimes must be a keyed table")
  assert(opts.host_effects == nil or type(opts.host_effects) == "table"
      and type(opts.host_effects.open_document) == "function",
    "Provider Shell host effects are invalid")

  local self = setmetatable({
    _neoagent_provider_shell = true,
    config = opts.config,
    auth = opts.auth,
    runtimes = opts.runtimes,
    selected_id = nil,
    operation = nil,
    operation_run = nil,
    operation_passive = false,
    pending_provider_id = nil,
    pending_focus_provider_id = nil,
    operation_id = 0,
    subscriptions = {},
    refresh_scheduled = false,
    presentation = nil,
    presenter_unsubscribe = nil,
    feedback = nil,
    destroyed = false,
    host_effects = opts.host_effects or Applet.host_effects,
    owns_presenter = opts.presenter == nil,
  }, ProviderShell)

  local view_factory = opts.view or require("neoagent.ui.provider_shell").new
  self.view_value = view_factory({
    config = opts.config.ui,
    renderer = opts.config.ui.renderer,
    host = opts.host,
    on_action = function(id) return self:run(id) end,
    on_select = function(id) return self:select(id) end,
    on_previous = function() return self:cycle(-1) end,
    on_next = function() return self:cycle(1) end,
    on_presentation_resolve = function(id, value)
      return self.presenter_value:resolve(id, value)
    end,
    on_presentation_cancel = function(id)
      return self.presenter_value:cancel(id)
    end,
    on_close = function() end,
  })
  assert(type(self.view_value) == "table"
      and type(self.view_value.set) == "function"
      and type(self.view_value.open) == "function"
      and type(self.view_value.close) == "function"
      and type(self.view_value.is_open) == "function"
      and type(self.view_value.destroy) == "function",
    "Provider Shell View is invalid")

  local fallback = Applet.Presenter
  self.presenter_value = opts.presenter or require("neoagent.presenter").new({
    host = {
      select = fallback.select,
      input = fallback.input,
      notice = fallback.notice,
      notify = function(message, level)
        if type(self.view_value.notify) == "function" then
          return self.view_value:notify(message, level)
        end
        return fallback.notify(message, level)
      end,
      open_uri = function(uri)
        if type(self.view_value.open_uri) == "function" then
          return self.view_value:open_uri(uri)
        end
        return fallback.open_uri(uri)
      end,
    },
  })
  self.authentication = require("neoagent.authentication").new({
    config = opts.config,
    auth = opts.auth,
    runtimes = opts.runtimes,
    presenter = self.presenter_value,
    on_activity = function() self:_schedule_refresh() end,
  })

  local providers = self:providers()
  local preferred = opts.config.default_model
    and opts.config.default_model.provider or nil
  self.selected_id = self.runtimes[preferred] and preferred
    or providers[1] and providers[1].id or nil
  if self.owns_presenter and type(self.view_value.set_presentation) == "function" then
    self.presenter_unsubscribe = self.presenter_value:attach({
      present = function(snapshot) return self:_present(snapshot) end,
      notify = function(message, level)
        return self:_feedback(message, level)
      end,
    })
  end
  for _, entry in ipairs(providers) do
    local runtime = self.runtimes[entry.id]
    local service = runtime.service
    self.subscriptions[#self.subscriptions + 1] =
      provider_service.subscribe(service, function()
        self:_schedule_refresh()
      end, {
        report = function(message, level)
          return self:report(message, level)
        end,
      })
    if type(service.subscribe) == "function" then
      local ok, unsubscribe = pcall(service.subscribe, service, function()
        self:_schedule_refresh()
      end)
      if ok and type(unsubscribe) == "function" then
        self.subscriptions[#self.subscriptions + 1] = unsubscribe
      elseif not ok then
        self:_notify("provider subscription failed: " .. tostring(unsubscribe),
          vim.log.levels.ERROR)
      end
    end
    self.subscriptions[#self.subscriptions + 1] =
      runtime.catalog:subscribe(function() self:_schedule_refresh() end)
  end
  self:_refresh()
  return self
end

function ProviderShell:report(message, level)
  if self.destroyed then return false end
  return self.presenter_value:notify({
    message = message,
    level = level or vim.log.levels.INFO,
  })
end

function ProviderShell:_notify(message, level)
  return self:report("neoagent: " .. message, level)
end

function ProviderShell:_feedback(message, level)
  local next_feedback = {
    text = feedback_text(message),
    level = feedback_level(level),
  }
  if vim.deep_equal(self.feedback, next_feedback) then return true end
  self.feedback = next_feedback
  self:_schedule_refresh()
  return true
end

function ProviderShell:_schedule_refresh()
  if self.destroyed or self.refresh_scheduled then return end
  self.refresh_scheduled = true
  util.schedule(function()
    self.refresh_scheduled = false
    if not self.destroyed then
      self:_refresh()
      self:_maybe_focus_refresh()
    end
  end)
end

function ProviderShell:_present(snapshot)
  if self.destroyed then error("Provider Shell is destroyed", 0) end
  local active = snapshot and snapshot.active or nil
  self.presentation = active and util.copy(snapshot) or nil
  local modal = active and active.kind ~= "select" and snapshot or nil
  local shown, err = self.view_value:set_presentation(modal)
  if shown == false or err ~= nil then
    error(err or util.error("ui", "Provider presentation failed"), 0)
  end
  self:_refresh()
  if active and not self.view_value:is_open() then
    local opened, open_err = self.view_value:open()
    if not opened then error(open_err, 0) end
  end
  return true
end

function ProviderShell:providers()
  local result = {}
  for id, runtime in pairs(self.runtimes) do
    local service = type(runtime) == "table" and runtime.service or nil
    local ok, value = pcall(provider_service.validate, service)
    if ok and value then
      result[#result + 1] = { id = id, name = value.name }
    end
  end
  table.sort(result, function(left, right)
    if left.name == right.name then return left.id < right.id end
    return left.name < right.name
  end)
  return result
end

function ProviderShell:_auth_state(provider_id)
  local provider = self.config.providers[provider_id]
  local method_id = provider and provider.auth or nil
  if not method_id then
    return { usable = true, kind = "none" }
  end
  local method = self.config.auth.methods[method_id]
  local optional = provider and provider.auth_optional == true or false
  local stored, stored_err = self.auth:has_credentials(method_id)
  if stored == nil then
    return {
      usable = optional,
      kind = "error",
      method_id = method_id,
      method_name = method and method.name or method_id,
      error = stored_err,
    }
  end
  if stored then
    return {
      usable = true,
      kind = "stored",
      method_id = method_id,
      method_name = method and method.name or method_id,
    }
  end
  local external, external_err = external_credential(provider)
  if external == nil then
    return {
      usable = optional,
      kind = "error",
      method_id = method_id,
      method_name = method and method.name or method_id,
      error = external_err,
    }
  end
  if external then
    return {
      usable = true,
      kind = external,
      method_id = method_id,
      method_name = method and method.name or method_id,
    }
  end
  return {
    usable = optional,
    kind = optional and "optional" or "logged_out",
    method_id = method_id,
    method_name = method and method.name or method_id,
  }
end

local function auth_block(auth)
  if auth.kind == "none" then return nil end
  if auth.kind == "stored" then
    return { type = "field", label = "Authentication",
      value = auth.method_name, level = "success" }
  end
  if auth.kind == "environment" then
    return { type = "field", label = "Authentication",
      value = "Environment credential", level = "success" }
  end
  if auth.kind == "configured" then
    return { type = "field", label = "Authentication",
      value = "Configured credential", level = "success" }
  end
  if auth.kind == "optional" then
    return { type = "field", label = "Authentication",
      value = "Optional", level = "muted" }
  end
  if auth.kind == "error" then
    return { type = "field", label = "Authentication",
      value = auth.error and auth.error.message or "Unavailable",
      level = "error" }
  end
  return { type = "field", label = "Authentication",
    value = "Logged out", level = "warn" }
end

local credential_sources = {
  stored = "stored",
  environment = "environment",
  configured = "configured",
}

local function provider_authentication(auth)
  if auth.kind == "none" then return nil end
  local source = credential_sources[auth.kind]
  return {
    connected = auth.usable == true and auth.kind ~= "error",
    source = source,
    error = auth.kind == "error",
  }
end

function ProviderShell:_service_state(service)
  local ok, value = pcall(service.state, service)
  if not ok then
    self:_notify("provider state failed: " .. tostring(value),
      vim.log.levels.ERROR)
    return { blocks = { { type = "status",
      text = "Provider state is unavailable", level = "error" } } }
  end
  if value == false then return false end
  local normalized, err = provider_state.normalize(value)
  if normalized then return normalized end
  self:_notify("provider state is invalid: "
      .. (err and err.message or "invalid value"), vim.log.levels.ERROR)
  return { blocks = { { type = "status",
    text = "Provider state is unavailable", level = "error" } } }
end

function ProviderShell:_operations(runtime, auth)
  local selection = self.presentation and self.presentation.active or nil
  if selection and selection.kind == "select" then
    local result = {}
    for index, item in ipairs(selection.items or {}) do
      result[#result + 1] = {
        id = CHOOSE_PRESENTATION .. selection.id .. ":" .. tostring(index),
        label = item.label,
        description = item.detail,
        enabled = item.disabled ~= true,
      }
    end
    local login = self.authentication:activity_kind() == "login"
    result[#result + 1] = {
      id = login and CANCEL_LOGIN or CANCEL_PRESENTATION,
      label = login and "Cancel login" or "Cancel",
    }
    return result
  end
  local service = runtime.service
  local activity = self.authentication:activity_kind()
  if activity == "login" or activity == "presentation" then
    return { { id = CANCEL_LOGIN, label = "Cancel login" } }
  end
  if auth.kind == "logged_out" or auth.kind == "error" then
    return { {
      id = LOGIN,
      label = "Log in",
      description = auth.method_name,
      enabled = activity == nil and self.operation_run == nil,
    } }
  end
  local blocked = activity ~= nil or self.operation_run ~= nil
  local operations = provider_service.operations(service)
  for _, operation in ipairs(operations) do
    operation.enabled = not blocked and provider_service.operation_enabled(
      service, service.operations[operation.id])
  end
  table.insert(operations, 1, {
    id = REFRESH_CATALOG,
    label = "Refresh model catalog",
    description = "Discover the provider's current models",
    enabled = not blocked,
  })
  if auth.kind == "optional" then
    table.insert(operations, 1, {
      id = LOGIN,
      label = "Log in",
      description = auth.method_name,
      enabled = not blocked,
    })
  elseif auth.kind == "stored" then
    operations[#operations + 1] = {
      id = LOGOUT,
      label = "Log out",
      description = auth.method_name,
      enabled = not blocked,
    }
  end
  return operations
end

function ProviderShell:_snapshot()
  local runtime = self.selected_id and self.runtimes[self.selected_id] or nil
  if not runtime then return nil end
  local service = runtime.service
  local auth = self:_auth_state(self.selected_id)
  local state = self:_service_state(service)
  local catalog = runtime.catalog:snapshot()
  state = state == false and { blocks = {} } or util.copy(state)
  state.blocks[#state.blocks + 1] = {
    type = "field",
    label = "Models",
    value = tostring(vim.tbl_count(catalog.models)) .. " available",
  }
  state.blocks[#state.blocks + 1] = {
    type = "field",
    label = "Catalog",
    value = catalog.source .. (catalog.stale and " · stale" or " · fresh"),
    level = catalog.refresh.state == "failed" and "error"
      or catalog.stale and "warn" or "success",
  }
  if catalog.refresh.error then
    state.blocks[#state.blocks + 1] = {
      type = "status",
      text = catalog.refresh.error.message,
      level = "error",
    }
  end
  local block = auth_block(auth)
  if block then
    table.insert(state.blocks, 1, block)
  end
  if self.feedback then
    table.insert(state.blocks, 1, {
      type = "status",
      text = self.feedback.text,
      level = self.feedback.level,
    })
  end
  if self.operation then
    state.operation = util.copy(self.operation)
  end
  return {
    id = self.selected_id,
    name = service.name,
    state = state,
    operations = self:_operations(runtime, auth),
    operation_prompt = self.presentation and self.presentation.active
        and self.presentation.active.kind == "select"
        and self.presentation.active.prompt or nil,
  }, auth
end

function ProviderShell:_provider_list()
  local blocked = (self.operation_run ~= nil and not self.operation_passive)
    or self.authentication:is_active()
  local result = self:providers()
  for _, provider in ipairs(result) do
    local auth = self:_auth_state(provider.id)
    provider.selected = provider.id == self.selected_id
    provider.enabled = not blocked
    provider.authentication = provider_authentication(auth)
  end
  return result
end

function ProviderShell:_refresh()
  if self.destroyed then return false end
  local snapshot = self:_snapshot()
  if not snapshot then return false end
  local ok, err = self.view_value:set(snapshot, self:_provider_list())
  if not ok and err then
    self:_notify(util.normalize_error(err, "ui").message,
      vim.log.levels.ERROR)
  end
  return ok
end

function ProviderShell:_bridge(kind, request, done)
  local run = self.presenter_value[kind](self.presenter_value, request)
  local tracked = async.run(function() return run:await() end, {
    error_kind = "presentation",
    on_done = function(result)
      if result.ok then done.resolve(result.value)
      else done.reject(result.error) end
    end,
  })
  return function() tracked:cancel() end
end

function ProviderShell:_interact()
  return {
    select = function(options, done)
      local items = type(options) == "table" and options.items or nil
      if type(items) ~= "table" or not util.is_list(items) or #items == 0 then
        done.reject(util.error("provider", "Select requires items"))
        return
      end
      return self:_bridge("select", {
        prompt = type(options.prompt) == "string" and options.prompt or "Select",
        items = items,
      }, done)
    end,
    input = function(options, done)
      options = type(options) == "table" and options or {}
      return self:_bridge("input", {
        prompt = type(options.prompt) == "string" and options.prompt or "Input",
        default = type(options.default) == "string" and options.default or "",
        secret = options.secret == true,
        multiline = options.multiline == true,
        allow_empty = options.allow_empty == true,
      }, done)
    end,
    confirm = function(options, done)
      options = type(options) == "table" and options or {}
      return self:_bridge("confirm", {
        prompt = type(options.prompt) == "string" and options.prompt or "Confirm",
      }, done)
    end,
    progress = function(snapshot)
      local normalized, err = provider_state.normalize_operation(snapshot)
      if not normalized then
        self:_notify("provider progress is invalid: "
          .. (err and err.message or "invalid value"), vim.log.levels.ERROR)
        return
      end
      self.operation = normalized
      self:_schedule_refresh()
    end,
    notify = function(message, level)
      self:_notify(type(message) == "string" and message or tostring(message),
        level)
    end,
  }
end

function ProviderShell:_open_artifact(artifact)
  if artifact == nil then return end
  if not valid_artifact(artifact) then
    self:_notify("provider operation returned an invalid document artifact",
      vim.log.levels.ERROR)
    return
  end
  local ok, opened, err = pcall(self.host_effects.open_document, {
    name = artifact.name,
    filetype = artifact.filetype,
    content = artifact.content,
  })
  if not ok or not opened then
    self:_notify("failed to open provider document: "
      .. tostring(ok and err or opened), vim.log.levels.ERROR)
  end
end

function ProviderShell:select(provider_id)
  if self.destroyed then
    return nil, util.error("provider", "Provider Shell is destroyed")
  end
  if not self.runtimes[provider_id] then
    return nil, util.error("provider",
      "Unknown provider: " .. tostring(provider_id))
  end
  if provider_id == self.selected_id
      and self.pending_provider_id == nil then
    return provider_id
  end
  if self.authentication:is_active() then
    local err = util.error("provider",
      "Finish the active provider action before changing providers")
    self:_notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  if self.operation_run then
    if self.operation_passive then
      self.pending_provider_id = provider_id
      self.operation_run:cancel()
      return provider_id
    end
    local err = util.error("provider",
      "Finish the active provider action before changing providers")
    self:_notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  self.selected_id = provider_id
  self.pending_provider_id = nil
  self.operation = nil
  self.feedback = nil
  self:_refresh()
  self:_request_focus_refresh()
  return provider_id
end

function ProviderShell:cycle(step)
  if step ~= -1 and step ~= 1 then
    return nil, util.error("provider",
      "Provider cycle step must be -1 or 1")
  end
  local providers = self:providers()
  if #providers == 0 then
    return nil, util.error("provider", "No Provider Shell is available")
  end
  local selected = self.pending_provider_id or self.selected_id
  local index = 1
  for candidate, provider in ipairs(providers) do
    if provider.id == selected then
      index = candidate
      break
    end
  end
  local target = providers[(index - 1 + step) % #providers + 1]
  return self:select(target.id)
end

function ProviderShell:_run(operation_id, args, passive)
  if self.destroyed then
    return nil, util.error("provider", "Provider Shell is destroyed")
  end
  local runtime = self.selected_id and self.runtimes[self.selected_id] or nil
  if not runtime then
    return nil, util.error("provider", "No provider is selected")
  end
  local service = runtime.service
  local auth = self:_auth_state(self.selected_id)
  local selection = self.presentation and self.presentation.active or nil
  if selection and selection.kind == "select" then
    for index, item in ipairs(selection.items or {}) do
      local id = CHOOSE_PRESENTATION .. selection.id .. ":" .. tostring(index)
      if operation_id == id then
        return self.presenter_value:resolve(selection.id, item.id)
      end
    end
    if operation_id == CANCEL_PRESENTATION then
      return self.presenter_value:cancel(selection.id)
    end
  end
  if operation_id == LOGIN then
    if not auth.method_id or not (auth.kind == "logged_out"
        or auth.kind == "optional" or auth.kind == "error") then
      return nil, util.error("auth",
        "Login is unavailable for the selected provider")
    end
    self.feedback = nil
    local run, err = self.authentication:login(auth.method_id)
    self:_refresh()
    return run, err
  elseif operation_id == LOGOUT then
    if auth.kind ~= "stored" then
      return nil, util.error("auth",
        "Logout is unavailable for the selected provider")
    end
    self.feedback = nil
    local run, err = self.authentication:logout(auth.method_id)
    self:_refresh()
    return run, err
  elseif operation_id == CANCEL_LOGIN then
    local cancelled = self.authentication:cancel()
    self:_refresh()
    return cancelled
  end
  if not auth.usable then
    local err = util.error("auth", "Log in before running provider actions")
    self:_notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  if self.operation_run or provider_service.busy(service) then
    local err = util.error("provider", "A provider operation is already active")
    self:_notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  local descriptor = operation_id == REFRESH_CATALOG and {
    label = "Refresh model catalog",
  } or service.operations[operation_id]
  if not descriptor then
    local err = util.error("provider",
      "Unknown provider operation: " .. tostring(operation_id))
    self:_notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  local provider = self.config.providers[self.selected_id]
  self.feedback = nil
  self.operation_id = self.operation_id + 1
  local token = self.operation_id
  self.operation = {
    id = operation_id,
    label = descriptor.label,
    state = "running",
    message = descriptor.label,
  }
  self.operation_passive = passive == true
  self:_refresh()
  local function completed(result)
    if self.destroyed or token ~= self.operation_id then return end
    self.operation_run = nil
    self.operation_passive = false
    local pending_provider_id = self.pending_provider_id
    if pending_provider_id then
      self.pending_provider_id = nil
      self.selected_id = pending_provider_id
      self.operation = nil
      self:_refresh()
      self:_request_focus_refresh()
      return
    end
    local operation = self.operation and util.copy(self.operation)
      or { id = operation_id, label = descriptor.label }
    if result.ok then
      operation.state = "succeeded"
      self:_open_artifact(result.artifact)
    elseif result.error and result.error.kind == "cancelled" then
      operation.state = "cancelled"
    else
      operation.state = "failed"
      operation.detail = result.error and result.error.message or nil
    end
    self.operation = operation
    self:_refresh()
  end
  local operation_opts = {
    args = args or "",
    auth = self.auth,
    auth_method = provider and provider.auth or nil,
    optional_auth = provider and (provider.auth_optional == true
      or provider.api_key ~= nil) or false,
    provider = provider,
    interact = self:_interact(),
    on_done = completed,
  }
  local run, err
  if operation_id == REFRESH_CATALOG then
    run = async.run(function()
      operation_opts.interact.progress({
        id = REFRESH_CATALOG,
        label = descriptor.label,
        state = "running",
        message = "Discovering models",
      })
      local refreshed = runtime.catalog:refresh({ force = true }):await()
      if refreshed.ok == false then error(refreshed.error, 0) end
      return { ok = true }
    end, { on_done = completed, error_kind = "provider" })
  else
    run, err = provider_service.run(service, operation_id, operation_opts)
  end
  if not run then
    self.operation = nil
    self.operation_passive = false
    self:_refresh()
    if err then self:_notify(err.message, vim.log.levels.ERROR) end
    return nil, err
  end
  self.operation_run = run:is_done() and nil or run
  if not self.operation_run then self.operation_passive = false end
  return run
end

function ProviderShell:run(operation_id, args)
  return self:_run(operation_id, args, false)
end

function ProviderShell:_maybe_focus_refresh()
  local provider_id = self.pending_focus_provider_id
  if self.destroyed or not provider_id or not self.view_value:is_open()
      or provider_id ~= self.selected_id then return false end
  local runtime = self.runtimes[provider_id]
  local service = runtime and runtime.service or nil
  local refresh = service and service.operations.refresh or nil
  local operation_id = refresh and refresh.mutating ~= true and "refresh" or nil
  if not operation_id then
    self.pending_focus_provider_id = nil
    return false
  end
  if self.operation_run then
    if self.operation and self.operation.id == operation_id then
      self.pending_focus_provider_id = nil
      return true
    end
    return false
  end
  if self.authentication:is_active()
      or provider_service.busy(service)
      or not self:_auth_state(provider_id).usable then return false end
  self.pending_focus_provider_id = nil
  return self:_run(operation_id, nil, true)
end

function ProviderShell:_request_focus_refresh()
  if self.destroyed or not self.view_value:is_open() then return false end
  self.pending_focus_provider_id = self.selected_id
  return self:_maybe_focus_refresh()
end

function ProviderShell:operations()
  local runtime = self.selected_id and self.runtimes[self.selected_id] or nil
  if not runtime then return {} end
  local service = runtime.service
  local auth = self:_auth_state(self.selected_id)
  if not auth.usable then return {} end
  local blocked = self.operation_run ~= nil or self.authentication:is_active()
  local operations = provider_service.operations(service)
  for _, operation in ipairs(operations) do
    operation.enabled = not blocked and provider_service.operation_enabled(
      service, service.operations[operation.id])
  end
  table.insert(operations, 1, {
    id = REFRESH_CATALOG,
    label = "Refresh model catalog",
    description = "Discover the provider's current models",
    enabled = not blocked,
  })
  return operations
end

function ProviderShell:completion(operation_id, arg_lead, args)
  local runtime = self.selected_id and self.runtimes[self.selected_id] or nil
  local service = runtime and runtime.service or nil
  local descriptor = service and service.operations[operation_id] or nil
  if not descriptor or type(descriptor.complete) ~= "function" then return {} end
  local ok, values = pcall(descriptor.complete, arg_lead or "", args or "")
  if not ok or type(values) ~= "table" or not util.is_list(values) then return {} end
  local result = {}
  for _, value in ipairs(values) do
    if type(value) == "string" and value ~= "" and #value <= 512
        and util.is_valid_utf8(value)
        and not value:find("[%z\1-\31\127]")
        and (arg_lead == "" or vim.startswith(value, arg_lead)) then
      result[#result + 1] = value
    end
  end
  table.sort(result)
  return result
end

function ProviderShell:info()
  local snapshot = self:_snapshot()
  return snapshot and util.copy(snapshot) or nil
end

function ProviderShell:open(origin)
  if self.destroyed then
    return nil, util.error("ui", "Provider Shell is destroyed")
  end
  if not self.selected_id then
    local err = util.error("provider", "No Provider Shell is available")
    self:_notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  self:_refresh()
  local opened, err = self.view_value:open(origin)
  if not opened then return nil, err end
  self:_request_focus_refresh()
  return true
end

function ProviderShell:close()
  self.pending_focus_provider_id = nil
  return self.view_value:close()
end

function ProviderShell:toggle(origin)
  if self.view_value:is_open() then self:close() return false end
  return self:open(origin)
end

function ProviderShell:is_open()
  return not self.destroyed and self.view_value:is_open()
end

function ProviderShell:cancel()
  if self.operation_run then
    self.operation_run:cancel()
    return true
  end
  return self.authentication:cancel()
end

function ProviderShell:login(provider_id)
  if provider_id then
    local selected, err = self:select(provider_id)
    if not selected then return nil, err end
  end
  return self:run(LOGIN)
end

function ProviderShell:logout(provider_id)
  if provider_id then
    local selected, err = self:select(provider_id)
    if not selected then return nil, err end
  end
  return self:run(LOGOUT)
end

function ProviderShell:cancel_login()
  return self.authentication:cancel()
end

function ProviderShell:is_authenticating()
  return self.authentication:is_active()
end

function ProviderShell:presenter()
  return self.presenter_value
end

function ProviderShell:view()
  return self.view_value
end

function ProviderShell:is_active()
  return self.operation_run ~= nil or self.authentication:is_active()
end

function ProviderShell:destroy()
  if self.destroyed then return end
  self.destroyed = true
  self.operation_id = self.operation_id + 1
  if self.operation_run then self.operation_run:cancel() end
  if self.presenter_unsubscribe then
    self.presenter_unsubscribe("Provider Shell was destroyed")
  end
  self.presenter_unsubscribe = nil
  for _, unsubscribe in ipairs(self.subscriptions) do pcall(unsubscribe) end
  self.subscriptions = {}
  self.authentication:destroy()
  if self.owns_presenter then self.presenter_value:destroy() end
  self.view_value:destroy()
  self.operation_run = nil
  self.operation_passive = false
  self.pending_provider_id = nil
  self.pending_focus_provider_id = nil
  self.presentation = nil
  self.feedback = nil
end

M.new = ProviderShell.new
M.ProviderShell = ProviderShell

return M
