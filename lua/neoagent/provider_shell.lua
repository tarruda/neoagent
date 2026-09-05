local Applet = require("applet")
local async = require("neoagent.async")
local provider_auth = require("neoagent.provider_auth")
local provider_credentials = require("neoagent.provider_credentials")
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

local function valid_artifact(artifact)
  return type(artifact) == "table" and not util.is_list(artifact)
    and artifact.kind == "document"
    and type(artifact.name) == "string" and artifact.name ~= ""
    and #artifact.name <= 128 and util.is_valid_utf8(artifact.name)
    and not artifact.name:find("[/\\]")
    and not artifact.name:find("[%z\1-\31\127]")
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
    action = nil,
    action_id = 0,
    pending_transition = nil,
    transition_revision = 0,
    pending_focus_provider_id = nil,
    subscriptions = {},
    refresh_scheduled = false,
    presentation = nil,
    presenter_unsubscribe = nil,
    feedback = nil,
    destroyed = false,
    host_effects = opts.host_effects or Applet.host_effects,
    owns_presenter = opts.presenter == nil,
  }, ProviderShell)
  for provider_id, runtime in pairs(self.runtimes) do
    if runtime.credentials == nil then
      local provider = self.config.providers[provider_id]
        or runtime.definition or {}
      runtime.credentials = provider_credentials.new({
        provider_id = provider_id,
        provider = provider,
        authentication = self.auth,
        method = self.config.auth.methods[provider.auth],
      })
    end
  end

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
    refresh_after_auth_change = false,
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
  local runtime = self.runtimes[provider_id]
  local selected = runtime and runtime.credentials:state()
    or { usable = false, source = "error", error = util.error(
      "auth", "Provider credential state is unavailable") }
  return {
    usable = selected.usable,
    kind = selected.source,
    method_id = selected.method_id,
    method_name = selected.method_name,
    error = util.copy(selected.error),
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

function ProviderShell:_auth_services(runtime, method_id)
  local candidates = type(runtime.auth_services) == "table"
      and runtime.auth_services[method_id] or nil
  local services, seen = {}, {}
  for _, service in ipairs(candidates or {}) do
    if type(service) == "table" and not seen[service] then
      seen[service] = true
      services[#services + 1] = service
    end
  end
  if #services == 0 then
    for provider_id, candidate in pairs(self.runtimes) do
      local provider = self.config.providers[provider_id]
      local service = type(candidate) == "table" and candidate.service or nil
      if provider and provider_auth.uses(provider, method_id) and service
          and not seen[service] then
        seen[service] = true
        services[#services + 1] = service
      end
    end
  end
  table.sort(services, function(left, right)
    return tostring(left.id) < tostring(right.id)
  end)
  return services
end

function ProviderShell:_authentication_enabled(runtime, method_id)
  if self.action then return false end
  for _, service in ipairs(self:_auth_services(runtime, method_id)) do
    if not provider_service.operation_enabled(service, { mutating = true }) then
      return false
    end
  end
  return true
end

function ProviderShell:_begin_auth_coordination(runtime, method_id)
  local tokens = {}
  for _, service in ipairs(self:_auth_services(runtime, method_id)) do
    local token, err = provider_service.begin_operation(service, {
      mutating = true,
    })
    if not token then
      for index = #tokens, 1, -1 do tokens[index]:finish() end
      return nil, err
    end
    tokens[#tokens + 1] = token
  end
  local group = { active = true }
  function group:finish()
    if not self.active then return false end
    self.active = false
    for index = #tokens, 1, -1 do tokens[index]:finish() end
    return true
  end
  return group
end

function ProviderShell:_refresh_method_catalogs(method_id, action)
  if action.coordination then
    action.coordination:finish()
    action.coordination = nil
  end
  local result = self.authentication:refresh_catalogs(method_id):await()
  if not result.ok and result.error.kind == "cancelled" then
    error(result.error, 0)
  end
end

function ProviderShell:_finish_action(action, result)
  if action.finalized then return false end
  action.finalized = true
  if action.coordination then
    pcall(action.coordination.finish, action.coordination)
    action.coordination = nil
  end
  if self.action == action then self.action = nil end
  if self.destroyed then return true end
  local transition = self.pending_transition
  if transition and transition.revision == self.transition_revision then
    self.pending_transition = nil
    self.selected_id = transition.provider_id
    self.operation = nil
    self.feedback = nil
    self.pending_focus_provider_id = nil
    self:_refresh()
    if transition.action then
      local started, start_err = self:_run(
        transition.action.operation_id, transition.action.args, false)
      if not started and start_err then
        self:_notify(start_err.message, vim.log.levels.ERROR)
      end
    else
      self:_request_focus_refresh()
    end
    return true
  end
  if action.operation then
    local operation = self.operation and util.copy(self.operation)
      or { id = action.operation.id, label = action.operation.label }
    if type(result) == "table" and result.ok == true then
      operation.state = "succeeded"
      self:_open_artifact(result.artifact)
    elseif type(result) == "table" and result.error
        and result.error.kind == "cancelled" then
      operation.state = "cancelled"
    else
      operation.state = "failed"
      operation.detail = type(result) == "table" and result.error
          and result.error.message or "Provider action failed"
    end
    self.operation = operation
  end
  self:_refresh()
  self:_maybe_focus_refresh()
  return true
end

function ProviderShell:_start_action(opts)
  if self.action then
    if opts.coordination then opts.coordination:finish() end
    return nil, util.error("provider", "A provider action is already active")
  end
  self.action_id = self.action_id + 1
  local action = {
    id = self.action_id,
    kind = opts.kind,
    provider_id = opts.provider_id,
    run = nil,
    coordination = opts.coordination,
    passive = opts.passive == true,
    finalized = false,
    operation = opts.operation,
  }
  self.action = action
  if opts.operation then
    self.operation = {
      id = opts.operation.id,
      label = opts.operation.label,
      state = "running",
      message = opts.operation.label,
    }
  else
    self.operation = nil
  end
  self:_refresh()
  local run
  run = async.run(function()
    local ok, child, err = pcall(opts.start, action)
    if not ok then
      error(util.normalize_error(child, opts.error_kind or "provider"), 0)
    end
    if not child then
      error(util.normalize_error(err or "Provider action did not start",
        opts.error_kind or "provider"), 0)
    end
    if type(child) ~= "table" or type(child.await) ~= "function"
        or type(child.cancel) ~= "function"
        or type(child.is_done) ~= "function"
        or type(child.result) ~= "function" then
      error(util.error(opts.error_kind or "provider",
        "Provider action must return a Run"), 0)
    end
    local result = child:await()
    if type(result) ~= "table" or type(result.ok) ~= "boolean" then
      error(util.error(opts.error_kind or "provider",
        "Provider action returned an invalid result"), 0)
    end
    if not result.ok then error(result.error, 0) end
    if opts.after then opts.after(action, result) end
    return result
  end, {
    error_kind = opts.error_kind or "provider",
    on_done = function(result) self:_finish_action(action, result) end,
  })
  action.run = run
  if run:is_done() then self:_finish_action(action, run:result()) end
  return run
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
    local login = self.action and self.action.kind == "login"
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
  if (auth.kind == "logged_out" or auth.kind == "error")
      and auth.method_id then
    return { {
      id = LOGIN,
      label = "Log in",
      description = auth.method_name,
      enabled = activity == nil
        and self:_authentication_enabled(runtime, auth.method_id),
    } }
  elseif not auth.usable then return {} end
  local blocked = activity ~= nil
    or self.action ~= nil and not self.action.passive
  local operations = provider_service.operations(service)
  for _, operation in ipairs(operations) do
    operation.enabled = not blocked and provider_service.operation_enabled(
      service, service.operations[operation.id])
  end
  table.insert(operations, 1, {
    id = REFRESH_CATALOG,
    label = "Refresh model catalog",
    description = "Discover the provider's current models",
    enabled = not blocked and provider_service.operation_enabled(
      service, { mutating = false }),
  })
  if auth.kind == "optional" then
    table.insert(operations, 1, {
      id = LOGIN,
      label = "Log in",
      description = auth.method_name,
      enabled = not blocked
        and self:_authentication_enabled(runtime, auth.method_id),
    })
  elseif auth.kind == "stored" then
    operations[#operations + 1] = {
      id = LOGOUT,
      label = "Log out",
      description = auth.method_name,
      enabled = not blocked
        and self:_authentication_enabled(runtime, auth.method_id),
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
  local persistence = catalog.persistence
  if auth.usable and persistence and persistence.configured
      and not persistence.enabled then
    state.blocks[#state.blocks + 1] = {
      type = "status",
      text = "Model catalog cache is unavailable: "
        .. (persistence.error and persistence.error.message
          or "source identity is unavailable"),
      level = "warn",
    }
  end
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
  local blocked = (self.action ~= nil and not self.action.passive)
    or (self.action == nil and self.authentication:is_active())
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
  local built, snapshot = pcall(self._snapshot, self)
  if not built then
    self:_notify(util.normalize_error(snapshot, "provider").message,
      vim.log.levels.ERROR)
    return nil
  end
  if not snapshot then return false end
  local called, ok, err = pcall(function()
    return self.view_value:set(snapshot, self:_provider_list())
  end)
  if not called then err, ok = ok, nil end
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

function ProviderShell:_interact(action)
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
      if action and (action.finalized or self.action ~= action) then return end
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
      and self.pending_transition == nil then
    return provider_id
  end
  if self.authentication:is_active() and not self.action then
    local err = util.error("provider",
      "Finish the active provider action before changing providers")
    self:_notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  if self.action then
    if self.action.passive then
      self.transition_revision = self.transition_revision + 1
      self.pending_transition = {
        provider_id = provider_id,
        revision = self.transition_revision,
      }
      self.action.run:cancel()
      return provider_id
    end
    local err = util.error("provider",
      "Finish the active provider action before changing providers")
    self:_notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  self.selected_id = provider_id
  self.pending_transition = nil
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
  local selected = self.pending_transition
      and self.pending_transition.provider_id or self.selected_id
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
    local coordination, err = self:_begin_auth_coordination(
      runtime, auth.method_id)
    if not coordination then return nil, err end
    self.feedback = nil
    return self:_start_action({
      kind = "login",
      error_kind = "auth",
      provider_id = self.selected_id,
      coordination = coordination,
      start = function()
        return self.authentication:login(auth.method_id)
      end,
      after = function(action)
        self:_refresh_method_catalogs(auth.method_id, action)
      end,
    })
  elseif operation_id == LOGOUT then
    if auth.kind ~= "stored" then
      return nil, util.error("auth",
        "Logout is unavailable for the selected provider")
    end
    local coordination, err = self:_begin_auth_coordination(
      runtime, auth.method_id)
    if not coordination then return nil, err end
    self.feedback = nil
    return self:_start_action({
      kind = "logout",
      error_kind = "auth",
      provider_id = self.selected_id,
      coordination = coordination,
      start = function()
        return self.authentication:logout(auth.method_id)
      end,
      after = function(action)
        self:_refresh_method_catalogs(auth.method_id, action)
      end,
    })
  elseif operation_id == CANCEL_LOGIN then
    local cancelled = self:cancel()
    self:_refresh()
    return cancelled
  end
  if not auth.usable then
    local err = util.error("auth", "Log in before running provider actions")
    self:_notify(err.message, vim.log.levels.WARN)
    return nil, err
  end
  if self.action then
    local err = util.error("provider", "A provider action is already active")
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
  local coordination
  local coordination_err
  if operation_id ~= REFRESH_CATALOG then
    coordination, coordination_err = provider_service.begin_operation(
      service, { mutating = descriptor.mutating == true })
    if not coordination then return nil, coordination_err end
  elseif not provider_service.operation_enabled(
      service, { mutating = false }) then
    return nil, util.error("provider",
      "A mutating provider operation is already active")
  end
  local function start(action)
    local interact = self:_interact(action)
    if operation_id == REFRESH_CATALOG then
      interact.progress({
        id = REFRESH_CATALOG,
        label = descriptor.label,
        state = "running",
        message = "Discovering models",
      })
      return runtime.catalog:refresh({ force = true })
    end
    return provider_service.run(service, operation_id, {
      args = args or "",
      auth = self.auth,
      auth_method = provider and provider.auth or nil,
      optional_auth = provider and (provider.auth_optional == true
        or provider.api_key ~= nil) or false,
      provider = provider,
      interact = interact,
      coordination = coordination,
    })
  end
  return self:_start_action({
    kind = operation_id == REFRESH_CATALOG and "catalog" or "service",
    error_kind = "provider",
    provider_id = self.selected_id,
    coordination = coordination,
    passive = passive == true,
    operation = { id = operation_id, label = descriptor.label },
    start = start,
  })
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
  if self.action then
    if self.operation and self.operation.id == operation_id then
      self.pending_focus_provider_id = nil
      return true
    end
    return false
  end
  if self.authentication:is_active()
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
  local blocked = self.action ~= nil or self.authentication:is_active()
  local operations = provider_service.operations(service)
  for _, operation in ipairs(operations) do
    operation.enabled = not blocked and provider_service.operation_enabled(
      service, service.operations[operation.id])
  end
  table.insert(operations, 1, {
    id = REFRESH_CATALOG,
    label = "Refresh model catalog",
    description = "Discover the provider's current models",
    enabled = not blocked and provider_service.operation_enabled(
      service, { mutating = false }),
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
  if self.action and self.action.run then
    self.action.run:cancel()
    return true
  end
  return self.authentication:cancel()
end

function ProviderShell:login(provider_id)
  if self.destroyed then
    return nil, util.error("provider", "Provider Shell is destroyed")
  end
  if provider_id and not self.runtimes[provider_id] then
    return nil, util.error("provider",
      "Unknown provider: " .. tostring(provider_id))
  end
  if self.action and self.action.passive then
    local target = provider_id or self.selected_id
    self.transition_revision = self.transition_revision + 1
    self.pending_transition = {
      provider_id = target,
      action = { operation_id = LOGIN },
      revision = self.transition_revision,
    }
    self.action.run:cancel()
    return true
  end
  if provider_id then
    local selected, err = self:select(provider_id)
    if not selected then return nil, err end
  end
  return self:run(LOGIN)
end

function ProviderShell:logout(provider_id)
  if self.destroyed then
    return nil, util.error("provider", "Provider Shell is destroyed")
  end
  if provider_id and not self.runtimes[provider_id] then
    return nil, util.error("provider",
      "Unknown provider: " .. tostring(provider_id))
  end
  if self.action and self.action.passive then
    local target = provider_id or self.selected_id
    self.transition_revision = self.transition_revision + 1
    self.pending_transition = {
      provider_id = target,
      action = { operation_id = LOGOUT },
      revision = self.transition_revision,
    }
    self.action.run:cancel()
    return true
  end
  if provider_id then
    local selected, err = self:select(provider_id)
    if not selected then return nil, err end
  end
  return self:run(LOGOUT)
end

function ProviderShell:cancel_login()
  return self:cancel()
end

function ProviderShell:is_authenticating()
  return (self.action ~= nil and (self.action.kind == "login"
      or self.action.kind == "logout"))
    or self.authentication:is_active()
end

function ProviderShell:presenter()
  return self.presenter_value
end

function ProviderShell:view()
  return self.view_value
end

function ProviderShell:is_active()
  return self.action ~= nil or self.authentication:is_active()
end

function ProviderShell:destroy()
  if self.destroyed then return end
  self.destroyed = true
  self.action_id = self.action_id + 1
  if self.action and self.action.run then self.action.run:cancel() end
  if self.presenter_unsubscribe then
    self.presenter_unsubscribe("Provider Shell was destroyed")
  end
  self.presenter_unsubscribe = nil
  for _, unsubscribe in ipairs(self.subscriptions) do pcall(unsubscribe) end
  self.subscriptions = {}
  self.authentication:destroy()
  if self.owns_presenter then self.presenter_value:destroy() end
  self.view_value:destroy()
  self.pending_transition = nil
  self.pending_focus_provider_id = nil
  self.presentation = nil
  self.feedback = nil
end

M.new = ProviderShell.new
M.ProviderShell = ProviderShell

return M
