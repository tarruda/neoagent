local source = require("applet.image.source")
local util = require("applet.util")

local ImageSystem = {}
ImageSystem.__index = ImageSystem

local function kitty_options(opts)
  local configured = opts.kitty or {}
  assert(type(configured) == "table",
    "kitty image backend options must be a table")
  local result = {}
  for key, value in pairs(configured) do result[key] = value end
  return result
end

local function select_backend(opts)
  if type(opts.backend) == "table" then
    return opts.backend, opts.backend.name or "custom"
  end
  local name = opts.backend or "kitty"
  assert(name == "kitty", "unknown image backend: " .. tostring(name))
  return require("applet.image.kitty").new(kitty_options(opts)), name
end

local function validate_backend(value)
  assert(type(value) == "table", "image backend must be a table")
  assert(value.name == nil or util.nonempty_string(value.name),
    "image backend name must be a non-empty string")
  assert(type(value.available) == "boolean",
    "image backend available must be a boolean")
  for _, method in ipairs({
    "cell_dimensions", "replace", "clear", "release", "redraw", "destroy",
  }) do
    assert(type(value[method]) == "function",
      "image backend must implement " .. method)
  end
  assert(value.set_error_handler == nil
      or type(value.set_error_handler) == "function",
    "image backend set_error_handler must be a function")
end

local function diagnostics(opts)
  opts = opts or {}
  local name = opts.backend or "kitty"
  assert(name == "kitty", "unknown image backend: " .. tostring(name))
  local result = require("applet.image.detect").diagnostics(opts)
  vim.list_extend(result,
    require("applet.image.kitty").diagnostics(kitty_options(opts)))
  return result
end

local function positive(value, name)
  assert(type(value) == "number" and value > 0,
    name .. " must be positive")
  return value
end

local function create(opts)
  opts = opts or {}
  local backend, backend_name
  if opts._backend then
    backend = opts._backend
    backend_name = backend.name or "custom"
  else
    backend, backend_name = select_backend(opts)
  end
  validate_backend(backend)
  local load_source = opts._load_source or source.load_async
  assert(type(load_source) == "function", "_load_source must be a function")
  local value = setmetatable({
    backend = backend,
    backend_name = backend_name,
    status = backend.available and "available" or "unavailable",
    generation = 0,
    resources = {},
    pending = {},
    failures = {},
    references = {},
    presentations = {},
    callbacks = {},
    max_bytes = positive(
      opts.max_source_bytes or 20 * 1024 * 1024, "max_source_bytes"),
    max_pixels = positive(
      opts.max_pixels or 40 * 1000 * 1000, "max_pixels"),
    max_cache_bytes = positive(
      opts.max_cache_bytes or 80 * 1024 * 1024, "max_cache_bytes"),
    cache_bytes = 0,
    read_file = opts.read_file,
    load_source = load_source,
    destroyed = false,
    counters = {
      preparations = 0,
      releases = 0,
      cancelled_preparations = 0,
      presentation_changes = 0,
      backend_errors = 0,
    },
  }, ImageSystem)
  if backend.set_error_handler then
    backend:set_error_handler(function(err)
      value:_backend_failure(err)
    end)
  end
  return value
end

function ImageSystem.new(opts)
  return create(opts or {})
end

function ImageSystem.diagnostics(opts)
  return diagnostics(opts or {})
end

function ImageSystem._new(opts)
  return create(opts)
end

function ImageSystem._diagnostics(opts)
  return diagnostics(opts)
end

function ImageSystem:_changed()
  self.generation = self.generation + 1
  for callback in pairs(self.callbacks) do pcall(callback, self) end
end

function ImageSystem:_backend_failure(err)
  if self.destroyed or self.status == "unavailable" then return end
  self.status = "unavailable"
  self.last_backend_error = tostring(err or "image backend failed")
  self.counters.backend_errors = self.counters.backend_errors + 1
  for id, operation in pairs(self.pending) do
    self.pending[id] = nil
    if operation.cancel then pcall(operation.cancel) end
  end
  pcall(self.backend.destroy, self.backend)
  self.resources = {}
  self.failures = {}
  self.presentations = {}
  self.cache_bytes = 0
  self:_changed()
end

function ImageSystem:subscribe(callback)
  assert(type(callback) == "function", "image callback must be a function")
  self.callbacks[callback] = true
  return function() self.callbacks[callback] = nil end
end

local function presentation_references(presentation, id)
  if not presentation then return false end
  for _, source_identity in pairs(presentation.slots) do
    if source_identity == id then return true end
  end
  return false
end

function ImageSystem:_wanted(id)
  for _, identities in pairs(self.references) do
    if identities[id] then return true end
  end
  for _, presentation in pairs(self.presentations) do
    if presentation_references(presentation, id) then return true end
  end
  return false
end

function ImageSystem:_release_unused()
  for id, operation in pairs(self.pending) do
    if not self:_wanted(id) then
      self.pending[id] = nil
      if operation.cancel then pcall(operation.cancel) end
      self.counters.cancelled_preparations =
        self.counters.cancelled_preparations + 1
    end
  end
  for id in pairs(self.failures) do
    if not self:_wanted(id) then self.failures[id] = nil end
  end
  for id, resource in pairs(self.resources) do
    if not self:_wanted(id) then
      self.resources[id] = nil
      self.cache_bytes = self.cache_bytes - resource.bytes
      self.backend:release(resource)
      self.counters.releases = self.counters.releases + 1
    end
  end
end

local function loaded_resource(id, resource, limits)
  if type(resource) ~= "table" or resource.id ~= id
      or type(resource.data) ~= "string" then
    return nil, "image source loader returned an invalid resource"
  end
  local ok, info = pcall(source.png_info, resource.data, limits)
  if not ok or type(info) ~= "table" or resource.width ~= info.width
      or resource.height ~= info.height or resource.bytes ~= info.bytes then
    return nil, "image source loader returned an invalid resource"
  end
  return {
    id = id,
    data = resource.data,
    width = info.width,
    height = info.height,
    bytes = info.bytes,
  }
end

function ImageSystem:_complete(id, operation, resource, err, limits)
  if self.destroyed or self.pending[id] ~= operation then return end
  self.pending[id] = nil
  if not self:_wanted(id) then return end
  if resource then resource, err = loaded_resource(id, resource, limits) end
  if not resource then
    self.failures[id] = tostring(err or "image preparation failed")
    self:_changed()
    return
  end
  if self.cache_bytes + resource.bytes > self.max_cache_bytes then
    self.failures[id] = "image cache is full"
    self:_changed()
    return
  end
  self.resources[id] = resource
  self.cache_bytes = self.cache_bytes + resource.bytes
  self.counters.preparations = self.counters.preparations + 1
  self:_changed()
end

function ImageSystem:request(value)
  if self.destroyed then return nil, "image system is destroyed" end
  local id = source.identity(value)
  if self.resources[id] then return self.resources[id] end
  if self.failures[id] then return nil, self.failures[id] end
  if self.pending[id] or self.status ~= "available" then return nil end
  local operation = {}
  self.pending[id] = operation
  local limits = {
    read_file = self.read_file,
    max_bytes = self.max_bytes,
    max_pixels = self.max_pixels,
  }
  local invoking, completion = true, nil
  local function done(resource, err)
    if invoking then
      completion = completion or { resource = resource, err = err }
      return
    end
    self:_complete(id, operation, resource, err, limits)
  end
  local ok, cancel = pcall(self.load_source, value, limits, done)
  invoking = false
  if not ok then
    self:_complete(id, operation, nil, cancel, limits)
    return nil
  end
  if cancel ~= nil and type(cancel) ~= "function" then
    self:_complete(id, operation, nil,
      "load_source must return a cancellation function or nil", limits)
    return nil
  end
  operation.cancel = cancel
  if completion then
    self:_complete(id, operation,
      completion.resource, completion.err, limits)
  end
  return nil
end

function ImageSystem:set_references(owner, identities)
  if self.destroyed then return end
  assert(owner ~= nil, "image reference owner is required")
  local copied = {}
  for id in pairs(identities or {}) do copied[id] = true end
  self.references[owner] = next(copied) and copied or nil
  self:_release_unused()
end

local function resource_metadata(resource)
  return {
    id = resource.id,
    width = resource.width,
    height = resource.height,
  }
end

local function resolve_presentation(system, value)
  assert(type(value) == "table", "image presentation must be a table")
  local slots = value.slots
  if slots == nil then slots = {} end
  local placements = value.placements
  if placements == nil then placements = {} end
  assert(type(slots) == "table", "image presentation slots must be a table")
  assert(type(placements) == "table" and vim.islist(placements),
    "image presentation placements must be a list")
  local result = { slots = {}, placements = {}, signature = {
    slots = {}, placements = {},
  } }
  for key, id in pairs(slots) do
    assert(util.nonempty_string(key) and util.nonempty_string(id),
      "image presentation slots must map string keys to source identities")
    assert(system.resources[id],
      "image presentation references an unknown resource")
    result.slots[key] = id
    result.signature.slots[key] = id
  end
  for index, placement in ipairs(placements) do
    assert(type(placement) == "table"
        and util.nonempty_string(placement.key),
      "image presentation placements require a string key")
    local id = assert(result.slots[placement.key],
      "image presentation placement must reference a slot")
    local request = util.copy(placement)
    request.resource = system.resources[id]
    result.placements[index] = request
    result.signature.placements[index] = util.copy(placement)
  end
  return result
end

function ImageSystem:present(owner, value)
  if self.destroyed or self.status ~= "available" then return false end
  assert(owner ~= nil, "image presentation owner is required")
  local presentation = resolve_presentation(self, value)
  local current = self.presentations[owner]
  if current and util.equal(current.signature, presentation.signature) then
    return false
  end
  if not current and not next(presentation.slots)
      and #presentation.placements == 0 then return false end
  self.backend:replace(owner, presentation.placements)
  self.presentations[owner] = next(presentation.slots)
      and presentation or nil
  self.counters.presentation_changes =
    self.counters.presentation_changes + 1
  self:_release_unused()
  return true
end

function ImageSystem:clear(owner)
  if self.destroyed or owner == nil then return false end
  local changed = self.presentations[owner] ~= nil
  self.presentations[owner] = nil
  self.references[owner] = nil
  local backend_changed = self.backend:clear(owner)
  self:_release_unused()
  return changed or backend_changed == true
end

function ImageSystem:snapshot(owner)
  local cells = self.backend:cell_dimensions()
  local resources = {}
  for key, value in pairs(self.resources) do
    resources[key] = resource_metadata(value)
  end
  local current = owner and self.presentations[owner] or nil
  return {
    backend = self.backend_name,
    status = self.status,
    generation = self.generation,
    cell_width = cells.width,
    cell_height = cells.height,
    resources = resources,
    presented = util.copy(current and current.slots or {}),
  }
end

function ImageSystem:redraw(owner)
  if self.destroyed or self.status ~= "available" then return false end
  return self.backend:redraw(owner) == true
end

function ImageSystem:_stats()
  local result = util.copy(self.counters)
  result.cached_bytes = self.cache_bytes
  result.prepared_resources = vim.tbl_count(self.resources)
  result.pending_preparations = vim.tbl_count(self.pending)
  result.failed_resources = vim.tbl_count(self.failures)
  result.active_presentations = vim.tbl_count(self.presentations)
  result.backend = self.backend_name
  result.status = self.status
  return result
end

function ImageSystem:destroy()
  if self.destroyed then return end
  self.destroyed = true
  for _, operation in pairs(self.pending) do
    if operation.cancel then pcall(operation.cancel) end
  end
  self.backend:destroy()
  self.resources = {}
  self.pending = {}
  self.failures = {}
  self.references = {}
  self.presentations = {}
  self.callbacks = {}
  self.cache_bytes = 0
end

return setmetatable({
  new = ImageSystem.new,
  diagnostics = ImageSystem.diagnostics,
  _new = ImageSystem._new,
  _diagnostics = ImageSystem._diagnostics,
  png_info = source.png_info,
}, {
  __call = function(_, opts) return ImageSystem.new(opts) end,
})
