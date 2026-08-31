local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local Authentication = {}
Authentication.__index = Authentication

local function assert_presenter(value)
  assert(type(value) == "table"
      and type(value.select) == "function"
      and type(value.input) == "function"
      and type(value.notify) == "function"
      and type(value.open_uri) == "function",
    "authentication Presenter is invalid")
end

function Authentication.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "authentication config is required")
  assert(type(opts.auth) == "table"
      and type(opts.auth.login) == "function"
      and type(opts.auth.logout) == "function"
      and type(opts.auth.list_credentials) == "function",
    "authentication manager is invalid")
  assert_presenter(opts.presenter)
  assert(opts.runtimes == nil or type(opts.runtimes) == "table",
    "authentication provider runtimes must be a table")
  assert(opts.on_activity == nil or type(opts.on_activity) == "function",
    "authentication on_activity must be a function")
  assert(opts.report == nil or type(opts.report) == "function",
    "authentication report must be a function")
  return setmetatable({
    config = opts.config,
    auth = opts.auth,
    runtimes = opts.runtimes or {},
    presenter = opts.presenter,
    report = opts.report,
    on_activity = opts.on_activity,
    login_operation = nil,
    logout_operation = nil,
    catalog_runs = {},
    presentation_runs = {},
    login_notice = nil,
    destroyed = false,
  }, Authentication)
end

function Authentication:_notify(message, level)
  if self.report then return self.report(message, level) end
  return self.presenter:notify({
    message = "neoagent: " .. message,
    level = level or vim.log.levels.INFO,
  })
end

function Authentication:_publish()
  if self.on_activity then self.on_activity(self:is_active()) end
end

function Authentication:_track_presentation(run, callback)
  local token = {}
  local tracked = async.run(function() return run:await() end, {
    error_kind = "presentation",
    on_done = function(result)
      local owned = self.presentation_runs[token] ~= nil
      self.presentation_runs[token] = nil
      callback(result)
      if owned then self:_publish() end
    end,
  })
  if not tracked:is_done() then
    self.presentation_runs[token] = tracked
    self:_publish()
  end
  return tracked
end

function Authentication:_present(kind, request, callback)
  local run = self.presenter[kind](self.presenter, request)
  local function completed(result)
    if self.destroyed then return end
    if result.ok then
      callback(result.value)
    elseif result.error.kind ~= "cancelled" then
      self:_notify(result.error.message, vim.log.levels.ERROR)
    end
  end
  if run:is_done() then
    completed(run:result())
    return run
  end
  return self:_track_presentation(run, completed)
end

function Authentication:_bridge(kind, request, done)
  local run = self.presenter[kind](self.presenter, request)
  local function completed(result)
    if result.ok then done.resolve(result.value)
    else done.reject(result.error) end
  end
  if run:is_done() then
    completed(run:result())
    return function() end
  end
  local tracked = self:_track_presentation(run, completed)
  return function() tracked:cancel() end
end

function Authentication:_prompt(prompt, done)
  self:_close_login_notice()
  if prompt.type == "select" then
    return self:_bridge("select", {
      prompt = prompt.message,
      items = prompt.options,
    }, done)
  end
  if prompt.type == "secret" then
    return self:_bridge("input", {
      prompt = prompt.message,
      default = "",
      secret = true,
    }, done)
  end
  if prompt.type == "text" or prompt.type == "manual_code" then
    return self:_bridge("input", {
      prompt = prompt.message,
      default = "",
      allow_empty = true,
    }, done)
  end
  done.reject(util.error("auth",
    "Unsupported login prompt: " .. tostring(prompt.type)))
end

function Authentication:_close_login_notice()
  local run = self.login_notice
  self.login_notice = nil
  if not run then return false end
  if type(run.is_done) == "function" and not run:is_done()
      and type(run.cancel) == "function" then
    run:cancel()
  end
  return true
end

function Authentication:_show_login_notice(request)
  self:_close_login_notice()
  if type(self.presenter.notice) == "function" then
    local ok, run = pcall(self.presenter.notice, self.presenter, request)
    if ok and type(run) == "table"
        and type(run.is_done) == "function"
        and type(run.cancel) == "function"
        and type(run.result) == "function" then
      local done = run:is_done()
      local result = done and run:result() or nil
      if not done or type(result) == "table" and result.ok then
        self.login_notice = run
        return true
      end
    end
  end
  return false
end

function Authentication:_show_device_code(event)
  local body = table.concat({
    "Open this page:",
    event.verificationUri,
    "",
    "Enter this code:",
    event.userCode,
    "",
    "Neoagent is waiting for authorization.",
  }, "\n")
  if self:_show_login_notice({
    prompt = "OpenAI device login · <C-c> close",
    body = body,
  }) then return end
  self:_notify("Open " .. event.verificationUri .. " and enter code "
    .. event.userCode)
end

function Authentication:_show_auth_url(event)
  local instructions = event.instructions or "Open this URL to authenticate:"
  local body = table.concat({
    instructions,
    event.url,
    "",
    "Neoagent is waiting for authorization.",
  }, "\n")
  if not self:_show_login_notice({
    prompt = "Browser login · <C-c> close",
    body = body,
  }) then
    self:_notify(instructions .. "\n" .. event.url)
  end
  pcall(self.presenter.open_uri, self.presenter, { uri = event.url })
end

function Authentication:_event(event)
  if event.type == "auth_url" then
    self:_show_auth_url(event)
  elseif event.type == "device_code" then
    self:_show_device_code(event)
  elseif event.message then
    self:_notify(event.message)
  end
end

function Authentication:_method_id(id)
  if self.config.auth.methods[id] then return id end
  local provider = self.config.providers[id]
  return type(provider) == "table" and provider.auth or id
end

function Authentication:_refresh_after_login(method_id)
  for provider_id, runtime in pairs(self.runtimes) do
    local provider = self.config.providers[provider_id]
    local catalog = type(runtime) == "table" and runtime.catalog or nil
    if provider and provider.auth == method_id and catalog then
      local started, run = pcall(catalog.refresh, catalog, { force = true })
      if not started or type(run) ~= "table"
          or type(run.await) ~= "function" then
        self:_notify("failed to refresh " .. provider_id
          .. " catalog after login", vim.log.levels.ERROR)
      else
        local token = {}
        local owned
        owned = async.run(function()
          local result = run:await()
          if result.ok == false then error(result.error, 0) end
          return result
        end, {
          on_done = function(result)
            self.catalog_runs[token] = nil
            self:_publish()
            if not result.ok and result.error.kind ~= "cancelled"
                and not self.destroyed then
              self:_notify("failed to refresh " .. provider_id
                .. " catalog: " .. result.error.message,
                vim.log.levels.ERROR)
            end
          end,
          error_kind = "provider",
        })
        if not owned:is_done() then
          self.catalog_runs[token] = owned
          self:_publish()
        end
      end
    end
  end
end

function Authentication:is_active()
  return self.login_operation ~= nil or self.logout_operation ~= nil
    or next(self.catalog_runs) ~= nil or next(self.presentation_runs) ~= nil
end

function Authentication:activity_kind()
  if self.login_operation then return "login" end
  if self.logout_operation then return "logout" end
  if next(self.catalog_runs) ~= nil then return "catalog" end
  if next(self.presentation_runs) ~= nil then return "presentation" end
end

function Authentication:set_activity_callback(callback)
  assert(callback == nil or type(callback) == "function",
    "authentication activity callback must be a function")
  self.on_activity = callback
  return callback
end

function Authentication:login(method_id)
  if self.destroyed then
    return nil, util.error("auth", "Authentication is destroyed")
  end
  if self.login_operation or self.logout_operation then
    self:_notify("an authentication operation is already active",
      vim.log.levels.WARN)
    return nil
  end
  local methods = self.config.auth.methods
  if method_id == nil or method_id == "" then
    local choices = {}
    for id, method in pairs(methods) do
      choices[#choices + 1] = { id = id, label = method.name }
    end
    table.sort(choices, function(a, b) return a.label < b.label end)
    if #choices == 0 then self:_notify("no login methods configured") return nil end
    self:_present("select", {
      prompt = "Select login:",
      items = choices,
    }, function(id) self:login(id) end)
    return true
  end
  method_id = self:_method_id(method_id)
  if not methods[method_id] then
    self:_notify("unknown login method: " .. tostring(method_id),
      vim.log.levels.ERROR)
    return nil
  end
  local operation = {}
  self.login_operation = operation
  self:_publish()
  local ok, run = pcall(self.auth.login, self.auth, method_id, {
    prompt = function(prompt, done) return self:_prompt(prompt, done) end,
    notify = function(event) self:_event(event) end,
    on_done = function(result)
      self:_close_login_notice()
      if self.login_operation == operation then
        self.login_operation = nil
        self:_publish()
      end
      if self.destroyed then return end
      if result.ok then
        self:_refresh_after_login(method_id)
        self:_notify("logged in with " .. methods[method_id].name
          .. "; credentials saved to " .. self.config.auth.path)
      elseif result.error.kind ~= "cancelled" then
        self:_notify(result.error.message, vim.log.levels.ERROR)
      end
    end,
  })
  if not ok then
    self:_close_login_notice()
    self.login_operation = nil
    self:_publish()
    error(run, 0)
  end
  operation.run = run
  if run:is_done() and self.login_operation == operation then
    self:_close_login_notice()
    self.login_operation = nil
    self:_publish()
  end
  return run
end

function Authentication:cancel()
  local operation = self.login_operation
  local cancelled = operation ~= nil
  if self:_close_login_notice() then cancelled = true end
  if operation and operation.run then operation.run:cancel() end
  for _, run in pairs(self.presentation_runs) do
    cancelled = true
    run:cancel()
  end
  return cancelled
end

function Authentication:logout(method_id)
  if self.destroyed then
    return nil, util.error("auth", "Authentication is destroyed")
  end
  if self.login_operation or self.logout_operation then
    self:_notify("an authentication operation is already active",
      vim.log.levels.WARN)
    return nil
  end
  local credentials, err = self.auth:list_credentials()
  if not credentials then
    self:_notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  if method_id == nil or method_id == "" then
    if #credentials == 0 then
      self:_notify("no stored credentials to remove; environment API keys are unchanged")
      return nil
    end
    local choices = {}
    for _, item in ipairs(credentials) do
      local kind = item.type == "api_key" and "API key"
        or item.type == "oauth" and "OAuth" or "invalid"
      choices[#choices + 1] = {
        id = item.id,
        label = item.name .. " (" .. kind .. ")",
        fallback = item,
      }
    end
    self:_present("select", {
      prompt = "Select credential to remove:",
      items = choices,
    }, function(id) self:logout(id) end)
    return true
  end
  method_id = self:_method_id(method_id)
  local selected
  for _, credential in ipairs(credentials) do
    if credential.id == method_id then selected = credential break end
  end
  if not selected then
    self:_notify("no stored credential for " .. tostring(method_id),
      vim.log.levels.WARN)
    return nil
  end
  local operation = {}
  self.logout_operation = operation
  self:_publish()
  local ok, run = pcall(self.auth.logout, self.auth, method_id, {
    on_done = function(result)
      if self.logout_operation == operation then
        self.logout_operation = nil
        self:_publish()
      end
      if self.destroyed then return end
      if result.ok then
        if selected.type == "api_key" then
          self:_notify("removed stored " .. selected.name
            .. "; environment API keys are unchanged")
        else
          self:_notify("logged out of " .. selected.name)
        end
      elseif result.error.kind ~= "cancelled" then
        self:_notify(result.error.message, vim.log.levels.ERROR)
      end
    end,
  })
  if not ok then
    self.logout_operation = nil
    self:_publish()
    error(run, 0)
  end
  operation.run = run
  if run:is_done() and self.logout_operation == operation then
    self.logout_operation = nil
    self:_publish()
  end
  return run
end

function Authentication:destroy()
  if self.destroyed then return end
  self.destroyed = true
  self:_close_login_notice()
  if self.login_operation and self.login_operation.run then
    self.login_operation.run:cancel()
  end
  if self.logout_operation and self.logout_operation.run then
    self.logout_operation.run:cancel()
  end
  for _, run in pairs(self.catalog_runs) do run:cancel() end
  for _, run in pairs(self.presentation_runs) do run:cancel() end
  self.login_operation = nil
  self.logout_operation = nil
  self.catalog_runs = {}
  self.presentation_runs = {}
  self:_publish()
end

M.new = Authentication.new
M.Authentication = Authentication

return M
