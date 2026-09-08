local source = require("applet.image.source")
local util = require("applet.util")

---@class Applet.ImageBackend
---@field name? string
---@field available boolean
---@field cell_dimensions fun(self: Applet.ImageBackend): Applet.CellDimensions
---@field replace fun(self: Applet.ImageBackend, owner: Applet.ImageOwner, requests: Applet.ImageRequest[])
---@field clear fun(self: Applet.ImageBackend, owner: Applet.ImageOwner): boolean?
---@field release fun(self: Applet.ImageBackend, resource: Applet.ImageContent)
---@field redraw fun(self: Applet.ImageBackend, owner: Applet.ImageOwner): boolean?
---@field destroy fun(self: Applet.ImageBackend)
---@field set_error_handler? fun(self: Applet.ImageBackend, callback: fun(err: string))

---@class Applet.ImageOptions
---@field backend? "kitty"|Applet.ImageBackend
---@field kitty? Applet.KittyOptions
---@field max_source_bytes? integer
---@field max_pixels? integer
---@field max_cache_bytes? integer
---@field read_file? fun(path: string, maximum: integer): string?, string?

---@class Applet.ImageDiagnosticsOptions: Applet.ImageDetectionOptions
---@field backend? "kitty"
---@field kitty? Applet.KittyOptions

---@class Applet.ImageInternalOptions: Applet.ImageOptions
---@field _backend? Applet.ImageBackend
---@field _load_source? fun(source: Applet.ImageSource, limits: Applet.ImageLoadOptions, done: Applet.ImageLoadDone): Applet.CancelOutput?

---@class Applet.ImageSlotPlacement
---@field key string
---@field width integer
---@field height integer
---@field fit? Applet.ImageFit
---@field viewport? Applet.Rectangle
---@field screen_row? integer
---@field screen_col? integer
---@field cell_width? number
---@field cell_height? number

---@class Applet.ImagePresentation
---@field slots? table<string, string>
---@field placements? Applet.ImageSlotPlacement[]

---@class Applet.ResolvedImagePresentation
---@field slots table<string, string>
---@field placements Applet.ImageRequest[]
---@field signature Applet.ImagePresentation

---@alias Applet.ImageStatus "available"|"unavailable"

---@class Applet.ImageState
---@field status Applet.ImageStatus
---@field generation integer
---@field cell_width? number
---@field cell_height? number
---@field resources table<string, Applet.ImageMetadata>
---@field presented? table<string, string>

---@class Applet.ImageSnapshot: Applet.ImageState
---@field backend string
---@field status Applet.ImageStatus
---@field generation integer
---@field cell_width number
---@field cell_height number
---@field resources table<string, Applet.ImageMetadata>
---@field presented table<string, string>

---@class Applet.ImageCounters
---@field preparations integer
---@field releases integer
---@field cancelled_preparations integer
---@field presentation_changes integer
---@field backend_errors integer

---@class Applet.ImageStats: Applet.ImageCounters
---@field cached_bytes integer
---@field prepared_resources integer
---@field pending_preparations integer
---@field failed_resources integer
---@field active_presentations integer
---@field backend string
---@field status Applet.ImageStatus

---@class Applet.ImageSystem
---@field backend Applet.ImageBackend
---@field backend_name string
---@field backend_generation integer
---@field backend_destroyed boolean
---@field status Applet.ImageStatus
---@field generation integer
---@field resources table<string, Applet.ImageResource>
---@field pending table<string, Applet.OutputOperation>
---@field failures table<string, string>
---@field references table<Applet.ImageOwner, table<string, true>>
---@field presentations table<Applet.ImageOwner, Applet.ResolvedImagePresentation>
---@field callbacks table<fun(system: Applet.ImageSystem), true>
---@field max_bytes integer
---@field max_pixels integer
---@field max_cache_bytes integer
---@field cache_bytes integer
---@field read_file? fun(path: string, maximum: integer): string?, string?
---@field load_source fun(source: Applet.ImageSource, limits: Applet.ImageLoadOptions, done: Applet.ImageLoadDone): Applet.CancelOutput?
---@field destroyed boolean
---@field counters Applet.ImageCounters
---@field last_backend_error? string
local ImageSystem = {}
ImageSystem.__index = ImageSystem

---@param opts {kitty?: Applet.KittyOptions}
---@return Applet.KittyOptions
local function kitty_options(opts)
  local configured = opts.kitty or {}
  assert(type(configured) == "table",
    "kitty image backend options must be a table")
  local result = {}
  for key, value in pairs(configured) do result[key] = value end
  return result
end

---@param opts Applet.ImageOptions
---@return Applet.ImageBackend, string
local function select_backend(opts)
  if type(opts.backend) == "table" then
    return opts.backend, opts.backend.name or "custom"
  end
  local name = opts.backend or "kitty"
  assert(name == "kitty", "unknown image backend: " .. tostring(name))
  return require("applet.image.kitty").new(kitty_options(opts)), name
end

---@param value Applet.ImageBackend
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

---@param opts? Applet.ImageDiagnosticsOptions
---@return Applet.ImageDiagnostic[]
local function diagnostics(opts)
  opts = opts or {}
  local name = opts.backend or "kitty"
  assert(name == "kitty", "unknown image backend: " .. tostring(name))
  local result = require("applet.image.detect").diagnostics(opts)
  kitty_options(opts)
  vim.list_extend(result, require("applet.image.kitty").diagnostics())
  return result
end

---@param value integer
---@param name string
---@return integer
local function positive(value, name)
  assert(type(value) == "number" and value > 0,
    name .. " must be positive")
  return value
end

---@param opts? Applet.ImageInternalOptions
---@return Applet.ImageSystem
local function create(opts)
  opts = opts or {}
  local backend = opts._backend
  local backend_name
  if backend then
    backend_name = backend.name or "custom"
  else
    backend, backend_name = select_backend(opts)
  end
  validate_backend(backend)
  local load_source = opts._load_source or source.load_async
  assert(type(load_source) == "function", "_load_source must be a function")
  ---@type Applet.ImageSystem
  local value = setmetatable({
    backend = backend,
    backend_name = backend_name,
    backend_generation = 0,
    backend_destroyed = false,
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
    local installed, install_err = pcall(backend.set_error_handler, backend, function(err)
      value:_backend_failure(err)
    end)
    if not installed then value:_backend_failure(install_err) end
  end
  return value
end

---@param opts? Applet.ImageOptions
---@return Applet.ImageSystem
function ImageSystem.new(opts)
  return create(opts or {})
end

---@param opts? Applet.ImageDiagnosticsOptions
---@return Applet.ImageDiagnostic[]
function ImageSystem.diagnostics(opts)
  return diagnostics(opts or {})
end

---@param opts? Applet.ImageInternalOptions
---@return Applet.ImageSystem
function ImageSystem._new(opts)
  return create(opts)
end

---@param opts? Applet.ImageDiagnosticsOptions
---@return Applet.ImageDiagnostic[]
function ImageSystem._diagnostics(opts)
  return diagnostics(opts)
end

function ImageSystem:_changed()
  self.generation = self.generation + 1
  for callback in pairs(self.callbacks) do pcall(callback, self) end
end

---@return boolean
function ImageSystem:_destroy_backend()
  if self.backend_destroyed then return false end
  self.backend_destroyed = true
  pcall(self.backend.destroy, self.backend)
  return true
end

---@param err unknown
function ImageSystem:_backend_failure(err)
  if self.destroyed or self.status == "unavailable" then return end
  self.status = "unavailable"
  self.backend_generation = self.backend_generation + 1
  self.last_backend_error = tostring(err or "image backend failed")
  self.counters.backend_errors = self.counters.backend_errors + 1
  for id, operation in pairs(self.pending) do
    self.pending[id] = nil
    if operation.cancel then pcall(operation.cancel) end
  end
  self:_destroy_backend()
  self.resources = {}
  self.failures = {}
  self.presentations = {}
  self.cache_bytes = 0
  self:_changed()
end

---@generic T
---@param invoke fun(backend: Applet.ImageBackend): T
---@return T?, boolean
function ImageSystem:_backend_call(invoke)
  if self.destroyed or self.status ~= "available"
      or self.backend_destroyed then
    return nil, false
  end
  local backend = self.backend
  local generation = self.backend_generation
  local ok, result = pcall(invoke, backend)
  if not ok then
    self:_backend_failure(result)
    return nil, false
  end
  if self.destroyed or self.status ~= "available"
      or self.backend ~= backend
      or self.backend_generation ~= generation
      or self.backend_destroyed then
    return nil, false
  end
  return result, true
end

---@param callback fun(system: Applet.ImageSystem)
---@return fun()
function ImageSystem:subscribe(callback)
  assert(type(callback) == "function", "image callback must be a function")
  self.callbacks[callback] = true
  return function() self.callbacks[callback] = nil end
end

---@param presentation? Applet.ResolvedImagePresentation
---@param id string
---@return boolean
local function presentation_references(presentation, id)
  if not presentation then return false end
  for _, source_identity in pairs(presentation.slots) do
    if source_identity == id then return true end
  end
  return false
end

---@param id string
---@return boolean
function ImageSystem:_wanted(id)
  for _, identities in pairs(self.references) do
    if identities[id] then return true end
  end
  for _, presentation in pairs(self.presentations) do
    if presentation_references(presentation, id) then return true end
  end
  return false
end

---@return boolean
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
      local _, current = self:_backend_call(function(backend)
        return backend:release(resource)
      end)
      if not current then return false end
      self.resources[id] = nil
      self.cache_bytes = self.cache_bytes - resource.bytes
      self.counters.releases = self.counters.releases + 1
    end
  end
  return true
end

---@param id string
---@param resource unknown
---@param limits Applet.ImageLoadOptions
---@return Applet.ImageResource
---@return_overload nil, string
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

---@param id string
---@param operation Applet.OutputOperation
---@param resource? Applet.ImageResource
---@param err unknown
---@param limits Applet.ImageLoadOptions
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

---@param value Applet.ImageSource
---@return Applet.ImageResource?, string?
function ImageSystem:request(value)
  if self.destroyed then return nil, "image system is destroyed" end
  local id = source.identity(value)
  if self.resources[id] then return self.resources[id] end
  if self.failures[id] then return nil, self.failures[id] end
  if self.pending[id] or self.status ~= "available" then return nil end
  ---@type Applet.OutputOperation
  local operation = {}
  self.pending[id] = operation
  local limits = {
    read_file = self.read_file,
    max_bytes = self.max_bytes,
    max_pixels = self.max_pixels,
  }
  local invoking = true
  ---@type {resource?: Applet.ImageResource, err?: string}?
  local completion
  ---@param resource? Applet.ImageResource
  ---@param err? string
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

---@param owner Applet.ImageOwner
---@param identities? table<string, unknown>
function ImageSystem:set_references(owner, identities)
  if self.destroyed then return end
  assert(owner ~= nil, "image reference owner is required")
  local copied = {}
  for id in pairs(identities or {}) do copied[id] = true end
  self.references[owner] = next(copied) and copied or nil
  self:_release_unused()
end

---@param resource Applet.ImageResource
---@return Applet.ImageMetadata
local function resource_metadata(resource)
  return {
    id = resource.id,
    width = resource.width,
    height = resource.height,
  }
end

---@param system Applet.ImageSystem
---@param value Applet.ImagePresentation
---@return Applet.ResolvedImagePresentation
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
    ---@type Applet.ImageRequest
    local request = util.copy(placement)
    request.resource = system.resources[id]
    result.placements[index] = request
    result.signature.placements[index] = util.copy(placement)
  end
  return result
end

---@param owner Applet.ImageOwner
---@param value Applet.ImagePresentation
---@return boolean
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
  local _, current_generation = self:_backend_call(function(backend)
    return backend:replace(owner, presentation.placements)
  end)
  if not current_generation then return false end
  self.presentations[owner] = next(presentation.slots)
      and presentation or nil
  self.counters.presentation_changes =
    self.counters.presentation_changes + 1
  self:_release_unused()
  return true
end

---@param owner? Applet.ImageOwner
---@return boolean
function ImageSystem:clear(owner)
  if self.destroyed or owner == nil then return false end
  local changed = self.presentations[owner] ~= nil
  local backend_changed, current_generation = self:_backend_call(function(backend)
    return backend:clear(owner)
  end)
  self.presentations[owner] = nil
  self.references[owner] = nil
  if not current_generation then return false end
  self:_release_unused()
  return changed or backend_changed == true
end

---@param owner? Applet.ImageOwner
---@return Applet.ImageSnapshot
function ImageSystem:snapshot(owner)
  local cells = { width = 1, height = 1 }
  if self.status == "available" then
    local selected, current_generation = self:_backend_call(function(backend)
      return backend:cell_dimensions()
    end)
    if current_generation and type(selected) == "table" then cells = selected end
  end
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

---@param owner Applet.ImageOwner
---@return boolean
function ImageSystem:redraw(owner)
  if self.destroyed or self.status ~= "available" then return false end
  local redrawn, current_generation = self:_backend_call(function(backend)
    return backend:redraw(owner)
  end)
  return current_generation and redrawn == true or false
end

---@return Applet.ImageStats
function ImageSystem:_stats()
  ---@type Applet.ImageStats
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
  self.backend_generation = self.backend_generation + 1
  for _, operation in pairs(self.pending) do
    if operation.cancel then pcall(operation.cancel) end
  end
  self:_destroy_backend()
  self.resources = {}
  self.pending = {}
  self.failures = {}
  self.references = {}
  self.presentations = {}
  self.callbacks = {}
  self.cache_bytes = 0
end

---@class Applet.ImageModule
local module = {
  new = ImageSystem.new,
  diagnostics = ImageSystem.diagnostics,
  _new = ImageSystem._new,
  _diagnostics = ImageSystem._diagnostics,
  png_info = source.png_info,
}

return setmetatable(module, {
  __call = function(_, opts) return ImageSystem.new(opts) end,
})
