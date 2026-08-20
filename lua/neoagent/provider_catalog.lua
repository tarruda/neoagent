local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local Catalog = {}
Catalog.__index = Catalog
local DEFAULT_TTL_MS = 7 * 24 * 60 * 60 * 1000

function Catalog:models()
  if type(self._service.get_models) ~= "function" then return {} end
  local ok, value = pcall(self._service.get_models, self._service)
  if not ok or type(value) ~= "table" or not util.is_list(value) then
    return {}
  end
  return util.copy(value)
end

local function validate_publication(value)
  if type(value) ~= "table" or util.is_list(value)
      or type(value.update) ~= "function" then
    return nil, util.error("provider",
      "catalog publication requires an update function")
  end
  if value.persist ~= nil and value.persist ~= false
      and (type(value.persist) ~= "table" or util.is_list(value.persist)) then
    return nil, util.error("provider",
      "catalog persist must be an object or false")
  end
  return value
end

function Catalog:_publish(publication, generation)
  local selected, err = validate_publication(publication)
  if not selected then return nil, err end
  if generation ~= self._generation then return false end
  if selected.persist ~= nil and self._store then
    local saved, save_err
    if selected.persist == false then
      saved, save_err = self._store:delete(self._service.id)
    else
      saved, save_err = self._store:write(
        self._service.id, selected.persist)
    end
    if not saved then return nil, save_err end
  end
  if generation ~= self._generation then return false end
  local ok, update_err = pcall(selected.update)
  if not ok then
    return nil, util.normalize_error(update_err, "provider")
  end
  return true
end

function Catalog:publish(publication)
  local selected, err = validate_publication(publication)
  if not selected then return nil, err end
  self._generation = self._generation + 1
  return self:_publish(selected, self._generation)
end

function Catalog:refresh(opts)
  opts = opts or {}
  local service = self._service
  if type(service.refresh_models) ~= "function" then
    return nil, util.error("provider",
      "Provider Service " .. tostring(service.id) .. " has no catalog refresh")
  end
  return async.run(function()
    local stored
    if self._store then
      local ok, value, read_err = pcall(
        self._store.read, self._store, service.id)
      if not ok then
        if opts.force ~= true then
          error(util.error("state_store", "failed to read provider catalog",
            value), 0)
        end
        value = nil
      end
      if not value and read_err and opts.force ~= true then error(read_err, 0) end
      stored = value
    end
    local fresh = type(stored) == "table"
      and type(stored.checked_at) == "number"
      and self._now() - stored.checked_at <= self._ttl_ms
    local allow_network = opts.allow_network ~= false
      and (opts.force == true or not fresh)
    self._generation = self._generation + 1
    local generation = self._generation
    local publish = function(publication)
      local published, publish_err = self:_publish(publication, generation)
      if published == nil then error(publish_err, 0) end
      return published
    end

    local started, run = pcall(service.refresh_models, service, {
      stored = stored,
      allow_network = allow_network,
      force = opts.force == true,
      publish = publish,
      resolve_auth = opts.resolve_auth,
    })
    if not started then
      error(util.normalize_error(run, "provider"), 0)
    end
    if type(run) ~= "table" or type(run.cancel) ~= "function" then
      error(util.error("provider",
        "Provider Service catalog refresh must return a Run"), 0)
    end
    local result = run:await()
    if result.ok then
      return { ok = true, models = self:models() }
    end
    return result
  end, {
    on_done = opts.on_done,
    error_kind = "provider",
  })
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.service) == "table",
    "provider catalog service is required")
  local ttl_ms = opts.ttl_ms
  if ttl_ms == nil then ttl_ms = DEFAULT_TTL_MS end
  assert(type(ttl_ms) == "number" and ttl_ms >= 0 and ttl_ms % 1 == 0,
    "provider catalog ttl_ms must be a non-negative integer")
  local now = opts.now or util.now_ms
  assert(type(now) == "function",
    "provider catalog now must be a function")
  return setmetatable({
    _service = opts.service,
    _store = opts.store or nil,
    _generation = 0,
    _ttl_ms = ttl_ms,
    _now = now,
  }, Catalog)
end

return M
