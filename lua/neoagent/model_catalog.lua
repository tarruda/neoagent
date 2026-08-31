local async = require("neoagent.async")
local model_config = require("neoagent.model_config")
local util = require("neoagent.util")

local M = {}
local Catalog = {}
Catalog.__index = Catalog

local DEFAULT_TTL_MS = 14 * 24 * 60 * 60 * 1000
local RETRY_BASE_MS = 30 * 1000
local RETRY_MAX_MS = 60 * 60 * 1000
local MAX_DIAGNOSTIC_CHARACTERS = 1024
local DEFINITION_FIELDS = {
  discover = true,
  seed = true,
  transform_model = true,
  ttl_ms = true,
}
local CACHE_FIELDS = {
  models = true,
  validated_at = true,
  validator = true,
  version = true,
}
local VALIDATOR_FIELDS = {
  etag = true,
  last_modified = true,
}

local function close_timer(timer)
  if not timer then return end
  local closing = false
  if type(timer.is_closing) == "function" then
    local ok, value = pcall(timer.is_closing, timer)
    closing = ok and value == true
  end
  if closing then return end
  if type(timer.stop) == "function" then pcall(timer.stop, timer) end
  if type(timer.close) == "function" then pcall(timer.close, timer) end
end

local function finite_timestamp(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
    and value == value and value ~= math.huge
end

local function validator(value)
  if value == nil then return nil end
  if type(value) ~= "table" or util.is_list(value) then return nil end
  for key in pairs(value) do
    if not VALIDATOR_FIELDS[key] then return nil end
  end
  local result = {}
  for _, key in ipairs({ "etag", "last_modified" }) do
    local entry = value[key]
    if entry ~= nil then
      if type(entry) ~= "string" or entry == "" or #entry > 1024
          or not util.is_valid_utf8(entry)
          or entry:find("[%z\1-\31\127]") then
        return nil
      end
      result[key] = entry
    end
  end
  return next(result) and result or nil
end

local function cache_record(provider_id, value)
  if type(value) ~= "table" or util.is_list(value) then return nil end
  for key in pairs(value) do
    if not CACHE_FIELDS[key] then return nil end
  end
  if value.version ~= 1 then return nil end
  local timestamp = value.validated_at
  if not finite_timestamp(timestamp) then return nil end
  local models = model_config.normalize_discoveries(provider_id, value.models)
  if not models then return nil end
  local selected_validator = validator(value.validator)
  if value.validator ~= nil and not selected_validator then return nil end
  return {
    models = models,
    validated_at = timestamp,
    validator = selected_validator,
  }
end

local function source_projection(provider)
  local result = {}
  for _, key in ipairs({
    "api", "base_url", "auth", "auth_optional", "service_opts",
  }) do
    if provider[key] ~= nil then result[key] = util.copy(provider[key]) end
  end
  return result
end

local function callback_error(provider_id, model_id, value)
  return util.error("model", "Model transform failed for "
    .. provider_id .. "/" .. model_id, value)
end

local function bounded_error(err, kind)
  local selected = util.normalize_error(err, kind)
  local message = util.text_from_bytes(selected.message)
  if vim.fn.strchars(message) > MAX_DIAGNOSTIC_CHARACTERS then
    message = vim.fn.strcharpart(message, 0, MAX_DIAGNOSTIC_CHARACTERS)
      .. "…"
  end
  return { kind = selected.kind, message = message }
end

function Catalog:_build(discoveries)
  local normalized, normalize_err = model_config.normalize_discoveries(
    self._provider_id, discoveries)
  if not normalized then return nil, normalize_err end
  local sources = {}
  for _, entry in ipairs(normalized) do sources[entry.id] = entry end
  for model_id, override in pairs(self._overrides) do
    if type(override) == "table" and not sources[model_id] then
      sources[model_id] = { id = model_id }
    end
  end
  local ids = vim.tbl_keys(sources)
  table.sort(ids)
  local result = {}
  for _, model_id in ipairs(ids) do
    local source = util.copy(sources[model_id])
    local model = util.copy(source)
    if self._transform then
      local ok, transformed = pcall(self._transform, util.copy(model), {
        provider_id = self._provider_id,
        source_model = util.copy(source),
      })
      if not ok then
        return nil, callback_error(self._provider_id, model_id, transformed)
      end
      if transformed == false then
        model = false
      elseif type(transformed) ~= "table" or util.is_list(transformed) then
        return nil, callback_error(self._provider_id, model_id,
          "callback must return a model table or false")
      else
        model = util.copy(transformed)
      end
    end
    if model ~= false and not self._removals[model_id] then
      local override = self._overrides[model_id]
      if type(override) == "table" then
        model = util.deep_merge(model, override)
      end
      local valid, valid_err = model_config.validate(
        self._provider_id, model_id, model)
      if not valid then return nil, valid_err end
      result[model_id] = valid
    end
  end
  return result, nil, normalized
end

function Catalog:_report_diagnostic(message, err, level)
  local selected = bounded_error(err, "provider")
  pcall(self._report, "neoagent: " .. message .. ": "
    .. selected.message, level or vim.log.levels.WARN)
  return selected
end

function Catalog:_record_error(err)
  local selected = bounded_error(err, "provider")
  self._last_error = selected
  return selected
end

function Catalog:_diagnose(message, err, level)
  local selected = self:_report_diagnostic(message, err, level)
  self._last_error = selected
end

function Catalog:_notify()
  local snapshot = self:snapshot()
  for listener in pairs(self._listeners) do
    local ok, err = pcall(listener, util.copy(snapshot))
    if not ok then
      self:_report_diagnostic("model catalog subscriber failed for "
        .. self._provider_id, err, vim.log.levels.ERROR)
    end
  end
end

function Catalog:_publish(discoveries, opts)
  opts = opts or {}
  local models, err, normalized = self:_build(discoveries)
  if not models then return nil, err end
  if next(models) == nil and opts.allow_empty ~= true then
    return nil, util.error("provider",
      "Model catalog discovery returned an empty effective inventory")
  end
  self._discoveries = normalized
  self._models = models
  self._validated_at = opts.validated_at or self._validated_at
  if opts.validator_set then self._validator = util.copy(opts.validator) end
  self._source = opts.source or self._source
  self._last_error = opts.error and bounded_error(opts.error, "provider") or nil
  self._revision = self._revision + 1
  self:_notify()
  return true
end

function Catalog:_cache_value()
  return {
    version = 1,
    validated_at = self._validated_at,
    validator = util.copy(self._validator),
    models = util.copy(self._discoveries),
  }
end

function Catalog:_persist()
  if not self._store then return nil end
  local called, saved, err = pcall(
    self._store.write, self._store, self._provider_id, self:_cache_value())
  if called and saved then return nil end
  local failure = called and err or saved
  if failure == nil or failure == false then
    failure = util.error("state_store", "state store write failed")
  end
  return self:_report_diagnostic("failed to persist " .. self._provider_id
    .. " model catalog", failure)
end

function Catalog:_cancel_timer()
  close_timer(self._timer)
  self._timer = nil
end

function Catalog:_schedule(milliseconds, retry)
  self:_cancel_timer()
  if self._destroyed or not self._started or not self._discover then return end
  local created, timer = pcall(self._new_timer)
  local timer_type = type(timer)
  if not created
      or (timer_type ~= "table" and timer_type ~= "userdata")
      or type(timer.start) ~= "function"
      or type(timer.stop) ~= "function"
      or type(timer.close) ~= "function"
      or type(timer.is_closing) ~= "function" then
    self:_diagnose("failed to create model catalog timer",
      created and util.error("provider", "timer allocation failed") or timer,
      vim.log.levels.ERROR)
    return
  end
  self._timer = timer
  local started, start_err = pcall(timer.start, timer,
    math.max(1, math.floor(milliseconds)), 0,
    vim.schedule_wrap(function()
      if self._timer == timer then self._timer = nil end
      close_timer(timer)
      if self._destroyed then return end
      self:refresh({ retry = retry == true })
    end))
  if not started then
    self._timer = nil
    close_timer(timer)
    self:_diagnose("failed to start model catalog timer", start_err,
      vim.log.levels.ERROR)
  end
end

function Catalog:_schedule_validation()
  local base = self._validated_at or self._now()
  self:_schedule(math.max(1, base + self._ttl_ms - self._now()), false)
end

function Catalog:_schedule_retry(err)
  if err and err.kind == "auth" then return end
  self._retry_attempt = math.min(self._retry_attempt + 1, 8)
  local delay = math.min(RETRY_MAX_MS,
    RETRY_BASE_MS * 2 ^ (self._retry_attempt - 1))
  self:_schedule(delay, true)
end

function Catalog:_resolve_auth()
  if type(self._provider.auth) ~= "string" then
    return async.run(function()
      return { ok = true, configured = false }
    end, { error_kind = "auth" })
  end
  return self._auth:resolve(self._provider.auth, {
    optional = self._provider.auth_optional == true
      or self._provider.api_key ~= nil,
  })
end

function Catalog:_resolve_api_key()
  local source = self._provider.api_key
  if type(source) == "function" then return source() end
  return source
end

function Catalog:snapshot()
  local stale = self._discover ~= nil and (self._last_error ~= nil
    or self._validated_at == nil
    or self._now() - self._validated_at > self._ttl_ms) or false
  return {
    revision = self._revision,
    models = util.copy(self._models),
    validated_at = self._validated_at,
    stale = stale,
    source = self._source,
    refresh = {
      state = self._active and not self._active:is_done()
          and "refreshing" or self._last_error and "failed" or "idle",
      error = util.copy(self._last_error),
    },
  }
end

function Catalog:discoveries()
  return util.copy(self._discoveries)
end

function Catalog:subscribe(listener)
  assert(type(listener) == "function",
    "model catalog subscriber must be a function")
  if self._destroyed then return function() return false end end
  self._listeners[listener] = true
  local ok, err = pcall(listener, self:snapshot())
  if not ok then
    self:_report_diagnostic("model catalog subscriber failed for "
      .. self._provider_id, err, vim.log.levels.ERROR)
  end
  local active = true
  return function()
    if not active then return false end
    active = false
    self._listeners[listener] = nil
    return true
  end
end

function Catalog:start()
  if self._destroyed or self._started then return false end
  self._started = true
  if not self._discover then return true end
  local fresh = self._validated_at ~= nil
    and self._now() - self._validated_at <= self._ttl_ms
  if fresh then
    self:_schedule_validation()
  else
    self:refresh()
  end
  return true
end

function Catalog:refresh(opts)
  opts = opts or {}
  if self._destroyed then
    return async.run(function()
      error(util.error("provider", "ModelCatalog is destroyed"), 0)
    end, { on_done = opts.on_done, error_kind = "provider" })
  end
  if not self._discover then
    return async.run(function()
      return { ok = true, changed = false, snapshot = self:snapshot() }
    end, { on_done = opts.on_done, error_kind = "provider" })
  end
  self:_cancel_timer()
  self._generation = self._generation + 1
  local generation = self._generation
  if self._active and not self._active:is_done() then self._active:cancel() end
  local previous = util.copy(self._discoveries)
  local run
  run = async.run(function()
    local source_run = self._discover({
      provider_id = self._provider_id,
      provider = source_projection(self._provider),
      transport = self._transport,
      validator = util.copy(self._validator),
      force = opts.force == true,
      now = self._now,
      resolve_auth = function() return self:_resolve_auth() end,
      resolve_api_key = function() return self:_resolve_api_key() end,
    })
    if type(source_run) ~= "table" or type(source_run.await) ~= "function"
        or type(source_run.cancel) ~= "function" then
      error(util.error("provider",
        "Model catalog discover callback must return a Run"), 0)
    end
    local discovered = source_run:await()
    if type(discovered) == "table" and discovered.ok == false then
      error(discovered.error or util.error("provider",
        "Model catalog discovery failed"), 0)
    end
    if type(discovered) ~= "table" or discovered.ok ~= true then
      error(util.error("provider",
        "Model catalog discover callback returned an invalid result"), 0)
    end
    if discovered.unchanged ~= nil
        and type(discovered.unchanged) ~= "boolean" then
      error(util.error("provider",
        "Model catalog discover callback returned an invalid result"), 0)
    end
    if discovered.unchanged == true and discovered.models ~= nil then
      error(util.error("provider",
        "Unchanged model catalog discovery must not return models"), 0)
    end
    if generation ~= self._generation or self._destroyed then
      error(async.cancelled_error, 0)
    end
    local selected
    if discovered.unchanged == true then
      if #self._discoveries == 0 then
        error(util.error("provider",
          "Model catalog cannot be unchanged without prior discoveries"), 0)
      end
      selected = self._discoveries
    else
      selected = discovered.models
    end
    local timestamp = self._now()
    local next_validator
    if discovered.validator ~= nil then
      next_validator = validator(discovered.validator)
    elseif discovered.unchanged == true then
      next_validator = self._validator
    end
    if discovered.validator ~= nil and not next_validator then
      error(util.error("provider",
        "Model catalog returned an invalid validator"), 0)
    end
    local published, publish_err = self:_publish(selected, {
      validated_at = timestamp,
      validator = next_validator,
      validator_set = true,
      source = "source",
    })
    if not published then error(publish_err, 0) end
    self._retry_attempt = 0
    local persistence_error = self:_persist()
    self:_schedule_validation()
    return {
      ok = true,
      changed = not vim.deep_equal(previous, self._discoveries),
      persistence_error = persistence_error,
      snapshot = self:snapshot(),
    }
  end, {
    error_kind = "provider",
    report = function(diagnostic)
      self._report("neoagent callback failed during " .. diagnostic.phase
        .. ": " .. diagnostic.message, vim.log.levels.ERROR)
    end,
    on_done = function(result)
      if generation == self._generation then
        local was_active = run ~= nil and self._active == run
        if was_active then self._active = nil end
        if not result.ok and result.error.kind ~= "cancelled"
            and not self._destroyed then
          if result.error.kind == "auth" then
            self:_record_error(result.error)
          else
            self:_diagnose("model catalog refresh failed for "
              .. self._provider_id, result.error)
          end
          self._revision = self._revision + 1
          self:_notify()
          self:_schedule_retry(result.error)
        elseif result.ok and was_active and not self._destroyed then
          self._revision = self._revision + 1
          self:_notify()
        end
      end
      if opts.on_done then opts.on_done(result) end
    end,
  })
  self._active = run:is_done() and nil or run
  if self._active then
    self._revision = self._revision + 1
    self:_notify()
  end
  return run
end

function Catalog:publish_discoveries(discoveries, opts)
  opts = opts or {}
  if self._destroyed then
    return nil, util.error("provider", "ModelCatalog is destroyed")
  end
  self._generation = self._generation + 1
  if self._active and not self._active:is_done() then self._active:cancel() end
  self._active = nil
  local published, err = self:_publish(discoveries, {
    allow_empty = true,
    validated_at = opts.validated_at or self._now(),
    validator = opts.validator,
    validator_set = true,
    source = opts.source or "provider operation",
  })
  if not published then return nil, err end
  self._retry_attempt = 0
  local persistence_error = self:_persist()
  if self._started then self:_schedule_validation() end
  return true, persistence_error
end

function Catalog:destroy()
  if self._destroyed then return false end
  self._destroyed = true
  self._generation = self._generation + 1
  self:_cancel_timer()
  if self._active and not self._active:is_done() then self._active:cancel() end
  self._active = nil
  self._listeners = {}
  return true
end

function M.new(opts)
  opts = opts or {}
  assert(model_config.safe_provider_id(opts.provider_id),
    "ModelCatalog provider_id must be safe text without path separators")
  local definition = opts.definition or {}
  assert(type(definition) == "table"
      and (next(definition) == nil or not util.is_list(definition)),
    "ModelCatalog definition must be an object")
  for name in pairs(definition) do
    assert(DEFINITION_FIELDS[name],
      "unsupported ModelCatalog definition field " .. tostring(name))
  end
  local ttl_ms = definition.ttl_ms or DEFAULT_TTL_MS
  assert(type(ttl_ms) == "number" and ttl_ms > 0 and ttl_ms % 1 == 0
      and ttl_ms < math.huge,
    "ModelCatalog ttl_ms must be a positive integer")
  assert(definition.discover == nil or type(definition.discover) == "function",
    "ModelCatalog discover must be a function")
  assert(definition.transform_model == nil
      or type(definition.transform_model) == "function",
    "ModelCatalog transform_model must be a function")
  local provider = opts.provider or {}
  assert(type(provider) == "table"
      and (next(provider) == nil or not util.is_list(provider)),
    "ModelCatalog provider must be an object")
  assert(opts.store == nil or type(opts.store) == "table"
      and type(opts.store.read) == "function"
      and type(opts.store.write) == "function",
    "ModelCatalog store must provide read and write")
  assert(opts.report == nil or type(opts.report) == "function",
    "ModelCatalog report must be a function")
  local overrides, removals = {}, {}
  assert(opts.models == nil or type(opts.models) == "table"
      and (next(opts.models) == nil or not util.is_list(opts.models)),
    "ModelCatalog models must be a keyed table")
  for model_id, model in pairs(opts.models or {}) do
    assert(model_config.safe_id(model_id),
      "ModelCatalog model ids must be safe non-empty text")
    assert(model == false or type(model) == "table"
        and (next(model) == nil or not util.is_list(model)),
      "ModelCatalog models must contain objects or false")
    if model == false then removals[model_id] = true
    else overrides[model_id] = util.copy(model) end
  end
  local self = setmetatable({
    _provider_id = opts.provider_id,
    _provider = util.copy(provider),
    _discover = definition.discover,
    _transform = definition.transform_model,
    _overrides = overrides,
    _removals = removals,
    _store = opts.store,
    _auth = opts.authentication or {
      resolve = function()
        return async.run(function()
          return { ok = true, configured = false }
        end, { error_kind = "auth" })
      end,
    },
    _transport = opts.transport,
    _report = opts.report or function() end,
    _now = opts.now or util.now_ms,
    _new_timer = opts.new_timer or vim.uv.new_timer,
    _ttl_ms = ttl_ms,
    _models = {},
    _discoveries = {},
    _validated_at = nil,
    _validator = nil,
    _source = "empty",
    _revision = 0,
    _generation = 0,
    _retry_attempt = 0,
    _listeners = {},
    _started = false,
    _destroyed = false,
  }, Catalog)
  assert(type(self._auth) == "table"
      and type(self._auth.resolve) == "function",
    "ModelCatalog authentication manager is invalid")
  assert(type(self._now) == "function", "ModelCatalog now must be a function")
  assert(type(self._new_timer) == "function",
    "ModelCatalog new_timer must be a function")

  local restored
  if self._store then
    local ok, value, read_err = pcall(
      self._store.read, self._store, self._provider_id)
    if ok and value then
      restored = cache_record(self._provider_id, value)
      if not restored then
        self:_diagnose("ignored invalid model catalog cache for "
          .. self._provider_id,
          util.error("state_store", "cache record is invalid"))
      elseif self._discover and #restored.models == 0 then
        self:_diagnose("ignored empty model catalog cache for "
          .. self._provider_id,
          util.error("state_store", "cache record contains no models"))
        restored = nil
      end
    elseif not ok or read_err then
      self:_diagnose("failed to read model catalog cache for "
        .. self._provider_id, ok and read_err or value)
    end
  end
  local initial = restored and restored.models or definition.seed or {}
  local initial_source = restored and "cache"
    or #initial > 0 and "packaged"
    or next(overrides) and "configured" or "empty"
  local published, publish_err = self:_publish(initial, {
    allow_empty = true,
    validated_at = restored and restored.validated_at or nil,
    validator = restored and restored.validator or nil,
    validator_set = true,
    source = initial_source,
  })
  if not published and restored then
    self:_diagnose("ignored unusable model catalog cache for "
      .. self._provider_id, publish_err)
    published, publish_err = self:_publish(definition.seed or {}, {
      allow_empty = true,
      source = #(definition.seed or {}) > 0 and "packaged"
        or next(overrides) and "configured" or "empty",
    })
  end
  if not published then error(publish_err, 0) end
  return self
end

M.Catalog = Catalog
M.DEFAULT_TTL_MS = DEFAULT_TTL_MS

return M
