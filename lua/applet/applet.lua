local compiler = require("applet.layout.compile")
local host_api = require("applet.host")
local Base = require("applet.host.base")
local Domain = require("applet.interaction_domain")
local util = require("applet.util")
local applet_expect = util.expect

---@class Applet.Counters
---@field requested_generations integer
---@field renders integer
---@field frame_compilations integer
---@field frame_commits integer
---@field host_publications integer
---@field host_snapshot_refreshes integer
---@field observation_batches integer
---@field external_changes integer
---@field default_external_handlers integer
---@field tab_opens integer
---@field tab_closes integer
---@field topology_rebuilds integer
---@field pane_mounts integer
---@field pane_unmounts integer
---@field buffer_creations integer
---@field window_opens integer
---@field window_closes integer
---@field window_config_changes integer
---@field split_size_changes integer
---@field focus_changes integer
---@field mapping_scope_changes integer
---@field measurement_passes integer
---@field surface_invalidations integer
---@field rollbacks integer
---@field observer_activations integer
---@field observer_releases integer
---@field observer_callbacks integer
---@field observer_relevant_callbacks integer
---@field observer_record_scans integer

---@class Applet.Error
---@field applet string
---@field phase string
---@field generation integer
---@field pane? string
---@field message string

---@class Applet.Frame: Applet.CompiledLayout
---@field generation integer

---@class Applet.RenderEnvironment
---@field editor {width: integer, height: integer}
---@field host {kind: 'floating'|'tab', visible: boolean, bounds: Applet.Rectangle, container: Applet.LayoutContainer, capabilities: {native_splits: boolean, overlays: boolean}}
---@field origin Applet.ContainerGeometry
---@field open boolean
---@field reopening boolean
---@field focused_pane? string
---@field layout_generation integer
---@field measurements table<string, Applet.LayoutMeasurement>

---@class Applet.CapturedNative
---@field events string[]
---@field window? integer
---@field buffer? integer
---@field tab? integer
---@field match? string
---@field pane? string

---@alias Applet.ObservationKind 'resize'|'layout_change'|'pane_buffer_change'|'pane_close'|'pane_options_change'|'mode_change'|'host_close'
---@alias Applet.ObservationValue Applet.PaneObservation|Applet.HostSnapshot|Applet.ObservedLayout|Applet.HostState

---@class Applet.ObservationFields
---@field panes? table<string, Applet.Rectangle>
---@field scope? 'window'|'buffer'
---@field option? string
---@field value? Applet.OptionValue

---@class Applet.ExternalEvent: Applet.ObservationFields
---@field applet Applet.Applet
---@field source 'neovim'
---@field kind Applet.ObservationKind
---@field reason string
---@field revision integer
---@field request_generation integer
---@field pane? Applet.Pane
---@field before Applet.ObservationValue
---@field after Applet.ObservationValue
---@field native fun(): Applet.CapturedNative

---@class Applet.ObservationChange
---@field kind Applet.ObservationKind
---@field key? string
---@field before Applet.ObservationValue
---@field after? Applet.ObservationValue
---@field native Applet.CapturedNative
---@field reason string
---@field fields? Applet.ObservationFields

---@class Applet.Callbacks
---@field on_focus? fun(key: string, previous?: string)
---@field on_resize? fun(event: Applet.ExternalEvent, default: fun(): boolean)
---@field on_pane_buffer_change? fun(event: Applet.ExternalEvent, default: fun(): boolean)
---@field on_pane_close? fun(event: Applet.ExternalEvent, default: fun(): boolean)
---@field on_error? fun(error: Applet.Error)

---@class Applet.AppletActionEvent<S = unknown>: Applet.ActionEvent<Applet.Pane>
---@field applet Applet.Applet<S>

---@alias Applet.HostSource<S> Applet.HostInput|fun(state: S): Applet.HostInput

---@class Applet.AppletOptions<S>: Applet.Callbacks
---@field name string
---@field host Applet.HostSource<S>
---@field render? fun(state: S, env: Applet.RenderEnvironment): Applet.LayoutTree
---@field handlers? table<string, fun(event: Applet.AppletActionEvent<S>): unknown>
---@field domain? Applet.InteractionDomain
---@field critical? fun(): boolean
---@field notify? fun(message: string, level?: integer)
---@field open_uri? fun(uri: string): vim.SystemObj?, string?

---@class Applet.RecordCheckpoint
---@field records table<string, Applet.HostRecord>
---@field states table<Applet.HostRecord, Applet.HostRecord>
---@field measurements table<string, Applet.LayoutMeasurement>

---@class Applet.OpenOptions
---@field origin_window? integer
---@field origin? integer

---@class Applet.ToggleOptions: Applet.OpenOptions, Applet.CloseOptions

---@class Applet.CloseOptions
---@field restore_origin? boolean

---@class Applet.FocusMove
---@field direction? 'up'|'down'|'left'|'right'
---@field wrap? boolean

---@class Applet.Stats: Applet.Counters
---@field observer_scope? 'live'|'retained'
---@field interaction Applet.DomainStats

---@class Applet.Applet<S = unknown>: Applet.DomainMember
---@field host_source Applet.HostSource<S>
---@field selected_host? Applet.Host
---@field requested_host? Applet.Host
---@field active_host? Applet.Host
---@field queued_host? Applet.Host
---@field render? fun(state: S, env: Applet.RenderEnvironment): Applet.LayoutTree
---@field handlers table<string, fun(event: Applet.AppletActionEvent<S>): unknown>
---@field known_handlers table<string, true>
---@field callbacks Applet.Callbacks
---@field notify_effect fun(message: string, level?: integer)
---@field open_uri_effect fun(uri: string): vim.SystemObj?, string?
---@field owns_domain boolean
---@field generation integer
---@field committed_generation integer
---@field request_pending boolean
---@field pending_state S?
---@field pending_tree? Applet.LayoutTree
---@field direct_tree? boolean
---@field has_submission? boolean
---@field frame? Applet.Frame
---@field pending_frame? Applet.Frame
---@field origin? Applet.NativeOrigin
---@field measurements table<string, Applet.LayoutMeasurement>
---@field overrides table<string, Applet.SplitOverride>
---@field layer_focus table<string, string>
---@field focused? string
---@field applied_focus_intent? string
---@field pane_replacements? Applet.MountDescriptor[]
---@field host_transaction? boolean
---@field has_opened? boolean
---@field measuring? boolean
---@field observing? boolean
---@field observation_kinds? table<string, true>
---@field observation_native? Applet.NativeObservation[]
---@field observation_scheduled? boolean
---@field deferred_open? Applet.OpenOptions|integer
---@field deferred_close? Applet.CloseOptions
---@field deferred_focus? string
---@field deferred_destroy? boolean
---@field adopted_layout? Applet.ObservedLayout
---@field name string
---@field id integer
---@field _windows table<integer, string>
---@field records table<string, Applet.HostRecord>
---@field domain Applet.InteractionDomain
---@field lifecycle 'open'|'opening'|'closing'|'closed'|'destroyed'
---@field mutating? boolean
---@field driver? Applet.HostDriver
---@field observed_snapshot Applet.HostSnapshot
---@field augroup? integer
---@field observer_scope? 'live'|'retained'
---@field counters Applet.Counters
---@field _content_committed fun(self: Applet.Applet, record: Applet.HostRecord, info?: Applet.PaneCommit): boolean
---@field _surface_interaction fun(self: Applet.Applet, record: Applet.HostRecord): Applet.HostInteraction
---@field _schedule_observe fun(self: Applet.Applet, kind: string, native: Applet.NativeObservation)
local Applet = {}
Applet.__index = Applet

local built_in_actions = {
  ["applet.close"] = true,
  ["applet.focus"] = true,
  ["applet.focus.move"] = true,
  ["applet.focus.restore"] = true,
}

local callback_names = {
  "on_focus", "on_resize", "on_pane_buffer_change", "on_pane_close",
  "on_error",
}

local counter_names = {
  "requested_generations", "renders", "frame_compilations", "frame_commits",
  "host_publications", "host_snapshot_refreshes", "observation_batches",
  "external_changes",
  "default_external_handlers", "tab_opens", "tab_closes",
  "topology_rebuilds", "pane_mounts", "pane_unmounts", "buffer_creations",
  "window_opens", "window_closes", "window_config_changes",
  "split_size_changes", "focus_changes", "mapping_scope_changes",
  "measurement_passes", "surface_invalidations", "rollbacks",
  "observer_activations", "observer_releases", "observer_callbacks",
  "observer_relevant_callbacks", "observer_record_scans",
}

local sequence = 0

---@generic T
---@param value T
---@param seen? table<table, table>
---@return T
local function copy_owned(value, seen)
  if type(value) ~= "table" then return value end
  if getmetatable(value) ~= nil then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    result[copy_owned(key, seen)] = copy_owned(item, seen)
  end
  return result
end

---@generic T
---@param value T
---@param seen? table<table, table>
---@return T
local function copy_semantic(value, seen)
  if type(value) ~= "table" then return value end
  local source = value
  ---@cast source table<unknown, unknown>
  seen = seen or {}
  if seen[source] then return seen[source] --[[@as T]] end
  ---@type table<unknown, unknown>
  local result = {}
  seen[source] = result
  for key, item in pairs(source) do
    if type(item) ~= "function" and type(key) ~= "function" then
      local copied_key = copy_semantic(key, seen)
      result[copied_key] = copy_semantic(item, seen)
    end
  end
  return result --[[@as T]]
end

local drivers = {
  floating = require("applet.host.float"),
  tab = require("applet.host.tab"),
}

---@param kind "tab"|"floating"
---@return Applet.HostDriverModule
local function driver_for(kind)
  return (assert(drivers[kind], "unknown Applet Host kind"))
end

---@param record? Applet.HostRecord
---@return boolean
local function mounted(record)
  return record ~= nil and Base.valid_window(record.window)
    and Base.valid_buffer(record.buffer)
    and vim.api.nvim_win_get_buf(record.window) == record.buffer
end

---@param descriptor Applet.MountDescriptor
---@return string
local function buffer_token(descriptor)
  local transient = descriptor.lifecycle == "transient"
  local sensitive = descriptor.buffer.sensitive == true
  return table.concat({
    tostring(descriptor.buffer.name),
    tostring(descriptor.buffer.uri),
    tostring(descriptor.lifecycle),
    tostring(transient and descriptor.mount_revision or nil),
    tostring(sensitive),
    tostring((transient or sensitive) and descriptor.pane or nil),
  }, "\0")
end

---@param descriptor Applet.MountDescriptor
---@return string
local function mount_token(descriptor)
  return table.concat({ tostring(descriptor.pane), buffer_token(descriptor),
    tostring(descriptor.mount_revision) }, "\0")
end

---@param left? Applet.LayoutMeasurement
---@param right? Applet.LayoutMeasurement
---@return boolean
local function same_measurement(left, right)
  return util.equal(left or {}, right or {})
end

---@param left? Applet.LayoutRectangleInput|Applet.Rectangle
---@param right? Applet.LayoutRectangleInput|Applet.Rectangle
---@return boolean
local function same_rect(left, right)
  return (left and left.row) == (right and right.row)
    and (left and left.col) == (right and right.col)
    and (left and left.width) == (right and right.width)
    and (left and left.height) == (right and right.height)
end

---@generic S
---@param opts Applet.AppletOptions<S>
---@return Applet.Applet<S>
function Applet.new(opts)
  opts = opts or {}
  applet_expect(type(opts) == "table", "Applet", "options must be a table", 3)
  applet_expect(util.nonempty_string(opts.name), "Applet.name",
    "must be a non-empty string", 3)
  applet_expect(type(opts.host) == "table" or type(opts.host) == "function",
    "Applet.host", "must be a Host or resolver", 3)
  applet_expect(opts.render == nil or type(opts.render) == "function",
    "Applet.render", "must be a function", 3)
  applet_expect(opts.handlers == nil or type(opts.handlers) == "table",
    "Applet.handlers", "must be a table", 3)
  applet_expect(opts.domain == nil or type(opts.domain) == "table",
    "Applet.domain", "must be an InteractionDomain", 3)
  applet_expect(opts.critical == nil or type(opts.critical) == "function",
    "Applet.critical", "must be a function", 3)
  applet_expect(opts.notify == nil or type(opts.notify) == "function",
    "Applet.notify", "must be a function", 3)
  applet_expect(opts.open_uri == nil or type(opts.open_uri) == "function",
    "Applet.open_uri", "must be a function", 3)
  for _, name in ipairs(callback_names) do
    applet_expect(opts[name] == nil or type(opts[name]) == "function",
      "Applet." .. name, "must be a function", 3)
  end
  local handlers, known_handlers = {}, {}
  for name, handler in pairs(opts.handlers or {}) do
    applet_expect(util.nonempty_string(name) and not name:match("^applet%."),
      "Applet.handlers", "names must be non-empty and outside the applet namespace", 3)
    applet_expect(type(handler) == "function", "Applet.handlers." .. name,
      "must be a function", 3)
    handlers[name], known_handlers[name] = handler, true
  end
  local selected_host
  if type(opts.host) == "table" then selected_host = host_api.validate(opts.host --[[@as Applet.HostInput]]) end
  applet_expect(type(opts.host) ~= "function" or opts.render ~= nil,
    "Applet.host", "a resolver requires state-driven rendering", 3)
  sequence = sequence + 1
  local counters = {}
  for _, name in ipairs(counter_names) do counters[name] = 0 end
  local domain = opts.domain or Domain.new({ critical = opts.critical })
  ---@type Applet.Applet<S>
  local self = setmetatable({
    id = sequence,
    name = opts.name,
    host_source = opts.host,
    selected_host = selected_host,
    render = opts.render,
    handlers = handlers,
    known_handlers = known_handlers,
    callbacks = {},
    notify_effect = opts.notify or Base.default_notify,
    open_uri_effect = opts.open_uri or Base.default_open_uri,
    domain = domain,
    owns_domain = opts.domain == nil,
    lifecycle = "closed",
    generation = 0,
    committed_generation = 0,
    request_pending = false,
    records = {},
    measurements = {},
    overrides = {},
    layer_focus = {},
    applied_focus_intent = nil,
    _windows = {},
    counters = counters,
    observed_snapshot = {
      revision = 0,
      request_generation = 0,
      host = { kind = selected_host and selected_host.kind or nil,
        open = false, visible = false },
      layout = { kind = "closed" },
      panes = {},
      foreign_windows = 0,
    },
  }, Applet)
  for _, name in ipairs(callback_names) do self.callbacks[name] = opts[name] end
  domain:add(self, { phase = "frame" })
  return self
end

function Applet:_assert_alive()
  assert(self.lifecycle ~= "destroyed", "Applet is destroyed")
end

---@return boolean
function Applet:is_destroyed()
  return self.lifecycle == "destroyed"
end

---@param scope? "live"|"retained"
---@return boolean
function Applet:_set_observer_scope(scope)
  if self.observer_scope == scope then return false end
  if self.observer_scope ~= nil then
    Base.clear_observers(self)
    self.counters.observer_releases = self.counters.observer_releases + 1
  end
  if scope ~= nil then
    Base.install_observers(self, scope)
    self.counters.observer_activations = self.counters.observer_activations + 1
  end
  return true
end

---@return "retained"?
function Applet:_closed_observer_scope()
  for _, record in pairs(self.records) do
    if Base.loaded_buffer(record.buffer) then return "retained" end
  end
end

---@param phase string
---@param value unknown
---@param pane? string
---@return nil, Applet.Error
function Applet:_report(phase, value, pane)
  local source = type(value) == "table" and type(value.message) == "string"
      and value.message or tostring(value)
  local message = source:gsub("\nstack traceback:.*", "")
    :gsub("[\r\n].*", "")
  if #message > 512 then message = message:sub(1, 509) .. "..." end
  local err = {
    applet = self.name,
    phase = phase,
    generation = self.generation,
    pane = pane,
    message = message,
  }
  local callback = self.callbacks.on_error
  if callback then pcall(callback, copy_semantic(err)) end
  return nil, err
end

function Applet:_request_flush()
  if self.lifecycle ~= "destroyed" then self.domain:request(self) end
end

---@return boolean
function Applet:_refresh_observations()
  if not self.observation_kinds or self.observing or self.mutating
      or self.lifecycle == "destroyed" then return false end
  local kinds = self.observation_kinds
  local native = self.observation_native
  self.observation_kinds = nil
  self.observation_native = nil
  self:_observe(kinds, native)
  return true
end

---@param state S
---@return integer
function Applet:set_state(state)
  self:_assert_alive()
  assert(self.render, "Applet has no render function")
  self.generation = self.generation + 1
  self.counters.requested_generations = self.counters.requested_generations + 1
  self.pending_state = state
  self.pending_tree = nil
  self.direct_tree = false
  self.has_submission = true
  self.request_pending = true
  self:_request_flush()
  return self.generation
end

---@param tree Applet.LayoutTree
---@return integer
function Applet:update(tree)
  self:_assert_alive()
  self.generation = self.generation + 1
  self.counters.requested_generations = self.counters.requested_generations + 1
  self.pending_tree = tree
  self.pending_state = nil
  self.direct_tree = true
  self.has_submission = true
  self.request_pending = true
  self:_request_flush()
  return self.generation
end

---@param value Applet.HostSource<S>
---@return self
function Applet:set_host(value)
  self:_assert_alive()
  applet_expect(type(value) == "table" or type(value) == "function",
    "Applet Host", "must be a Host or resolver", 3)
  applet_expect(type(value) ~= "function" or self.render ~= nil,
    "Applet Host", "a resolver requires state-driven rendering", 3)
  if type(value) == "table" then value = host_api.validate(value --[[@as Applet.HostInput]]) end
  self.host_source = value
  if type(value) == "table" and self.lifecycle ~= "open" then
    self.selected_host = value
  end
  if self.has_submission then
    self.generation = self.generation + 1
    self.counters.requested_generations = self.counters.requested_generations + 1
    self.request_pending = true
    self:_request_flush()
  end
  return self
end

---@return Applet.Host?, Applet.Error?
function Applet:_resolved_host()
  local requested
  if type(self.host_source) == "function" then
    local ok, value = pcall(self.host_source, self.pending_state)
    if not ok then return self:_report("host", value) end
    local validated, result = pcall(host_api.validate, value)
    if not validated then return self:_report("host", result) end
    requested = result
  else
    requested = host_api.validate(self.host_source --[[@as Applet.HostInput]])
  end
  self.requested_host = requested
  if self.lifecycle == "open" and self.active_host
      and requested.kind ~= self.active_host.kind then
    self.queued_host = requested
    return self.active_host
  end
  self.queued_host = nil
  return requested
end

---@param host Applet.Host
---@param reopening? boolean
---@return Applet.RenderEnvironment, Applet.HostEnvironment
function Applet:_render_environment(host, reopening)
  local native = Base.environment(host, self.origin, self, reopening)
  local projected = compiler.environment({
    host = host,
    editor = native.editor,
    container = native.container,
  })
  return {
    editor = {
      width = native.editor.width,
      height = native.editor.height,
    },
    host = {
      kind = host.kind,
      visible = self.driver and self.driver:is_visible() or false,
      bounds = projected.bounds,
      container = {
        available = true,
        row = projected.container.row,
        col = projected.container.col,
        width = projected.container.width,
        height = projected.container.height,
      },
      capabilities = projected.capabilities,
    },
    origin = native.origin,
    open = self.lifecycle == "open",
    reopening = reopening == true,
    focused_pane = self.focused,
    layout_generation = self.generation,
    measurements = copy_semantic(self.measurements),
  }, native
end

---@param reopening? boolean
---@return Applet.Frame?, Applet.Error?
function Applet:_prepare_frame(reopening)
  if not self.has_submission then return self:_report("render", "Applet has no Tree") end
  if self.direct_tree and type(self.host_source) == "function" then
    return self:_report("host", "a Host resolver requires state-driven rendering")
  end
  local host, host_error = self:_resolved_host()
  if not host then return nil, host_error end
  local environment_ok, environment, native = pcall(
    self._render_environment, self, host, reopening)
  if not environment_ok then return self:_report("host", environment) end
  assert(native)
  local tree = self.pending_tree
  if not self.direct_tree then
    self.counters.renders = self.counters.renders + 1
    local rendered, value = pcall(function()
      return assert(self.render)(self.pending_state --[[@as S]],
        copy_semantic(environment))
    end)
    if not rendered then return self:_report("render", value) end
    if value == nil then return self:_report("render", "render returned nil") end
    tree = value
  end
  self.counters.frame_compilations = self.counters.frame_compilations + 1
  local compiled, frame = pcall(compiler.compile, {
    tree = tree --[[@as Applet.LayoutTree]],
    host = host,
    editor = native.editor,
    container = native.container,
    measurements = self.measurements,
    overrides = self.overrides,
    handlers = self.known_handlers,
  })
  if not compiled then return self:_report("compile", frame) end
  ---@cast frame Applet.Frame
  frame.generation = self.generation
  return frame
end

---@param record Applet.HostRecord
---@param destroy_pane? boolean
function Applet:_dispose_record(record, destroy_pane)
  local descriptor = record.descriptor
  local pane = descriptor and descriptor.pane
  local active_elsewhere = false
  if pane then
    for _, current in pairs(self.records) do
      if current ~= record and current.descriptor
          and current.descriptor.pane == pane then
        active_elsewhere = true
        break
      end
    end
  end
  -- Replaced records are disconnected while their candidate is prepared, so
  -- finalization releases native ownership and optional Pane ownership.
  record.surface = nil
  if self.driver and record.window then self.driver:detach(record) end
  Base.delete_buffer(record)
  if destroy_pane and descriptor and descriptor.owns_pane
      and not active_elsewhere and not pane.destroyed then
    pane:destroy()
  end
  if pane and not active_elsewhere then pane:_unbind(self) end
  record.active = false
end

---@param frame Applet.Frame
function Applet:_prepare_records(frame)
  local desired = {}
  for _, key in ipairs(frame.pane_order) do
    desired[key] = true
    local descriptor = frame.panes[key]
    local record = self.records[key]
    if not record then
      record = { key = key, applet = self, descriptor = descriptor }
      self.records[key] = record
    elseif record.descriptor and record.buffer_token ~= buffer_token(descriptor) then
      local previous = record.descriptor
      if previous.pane.surface then previous.pane:_disconnect() end
      record = { key = key, applet = self, descriptor = descriptor }
      if previous.buffer.name == descriptor.buffer.name
          and previous.buffer.uri == descriptor.buffer.uri then
        record.buffer_name_generation = frame.generation
      end
      self.records[key] = record
      self.measurements[key] = nil
    end
    if record.descriptor and record.descriptor.pane ~= descriptor.pane then
      local previous = record.descriptor
      if previous.pane.surface then previous.pane:_disconnect() end
      record.surface = nil
      record.view_policy_revision = nil
      assert(self.pane_replacements)[#self.pane_replacements + 1] = previous
    end
    local token = mount_token(descriptor)
    if record.mount_token ~= token then
      record.suppressed = nil
      record.detach_reason = nil
      self.measurements[key] = nil
    elseif record.declared == false then
      -- Leaving and re-entering the Tree is an explicit new mount request.
      record.suppressed = nil
      record.detach_reason = nil
    end
    local requested_window = {
      options = descriptor.window.options,
      host_options = descriptor.window.host_options,
    }
    if not util.equal(record.requested_window_descriptor, requested_window) then
      record.adopted_window_options = {}
      record.requested_window_descriptor = copy_semantic(requested_window)
    end
    record.buffer_token = buffer_token(descriptor)
    record.mount_token = token
    record.descriptor = descriptor
    descriptor.pane:_bind(self)
    if record.view_policy_revision == nil then
      record.view_policy_revision = descriptor.pane:_view_policy_revision()
    end
    record.declared = true
    record.active = true
    local _, created = Base.ensure_buffer(self, record, descriptor)
    if created then self.counters.buffer_creations = self.counters.buffer_creations + 1 end
  end
  for key, record in pairs(self.records) do
    if record.active and not desired[key] then
      Base.save_view(record)
      if record.descriptor.pane.surface then record.descriptor.pane:_disconnect() end
      record.surface = nil
      record.active = false
      record.declared = false
      self.counters.pane_unmounts = self.counters.pane_unmounts + 1
    end
  end
end

---@return Applet.RecordCheckpoint
function Applet:_record_checkpoint()
  local result = {
    records = {},
    states = {},
    measurements = copy_owned(self.measurements),
  }
  for key, record in pairs(self.records) do
    result.records[key] = record
    local state = {}
    for field, value in pairs(record) do
      if type(value) == "table" and field ~= "applet"
          and field ~= "descriptor" and field ~= "surface"
          and field ~= "chrome" then
        state[field] = copy_owned(value)
      else
        state[field] = value
      end
    end
    result.states[record] = state
  end
  return result
end

---@param checkpoint Applet.RecordCheckpoint
function Applet:_discard_candidate_records(checkpoint)
  local candidate_panes = {}
  for key, current in pairs(util.copy(self.records)) do
    local previous = checkpoint.records[key]
    if current ~= previous then
      if current.descriptor then candidate_panes[current.descriptor.pane] = true end
      if current.descriptor and current.descriptor.pane.surface then
        current.descriptor.pane:_disconnect()
      end
      current.surface = nil
      if self.driver and current.window then self.driver:detach(current) end
      Base.delete_buffer(current)
      self.records[key] = previous
    elseif current.descriptor ~= checkpoint.states[current].descriptor
        and current.descriptor.pane.surface then
      candidate_panes[current.descriptor.pane] = true
      current.descriptor.pane:_disconnect()
    end
  end
  for key, previous in pairs(checkpoint.records) do self.records[key] = previous end
  for record, state in pairs(checkpoint.states) do
    local destination = record --[[@as table<string, unknown>]]
    for field in pairs(destination) do destination[field] = nil end
    for field, value in pairs(state --[[@as table<string, unknown>]]) do
      destination[field] = value
    end
    if record.owns_buffer and Base.loaded_buffer(record.buffer) then
      record.reproject_buffer_options = true
      Base.configure_buffer(record, record.descriptor)
    end
    if record.descriptor then record.descriptor.pane:_bind(self) end
  end
  local restored_panes = {}
  for _, record in pairs(self.records) do
    if record.descriptor then restored_panes[record.descriptor.pane] = true end
  end
  for pane in pairs(candidate_panes) do
    if not restored_panes[pane] then pane:_unbind(self) end
  end
  self.measurements = copy_owned(checkpoint.measurements)
end

---@param checkpoint Applet.RecordCheckpoint
function Applet:_finalize_replaced_records(checkpoint)
  for key, previous in pairs(checkpoint.records) do
    if self.records[key] ~= previous then self:_dispose_record(previous, true) end
  end
  local finalized = {}
  for _, descriptor in ipairs(self.pane_replacements or {}) do
    if not finalized[descriptor.pane] then
      if descriptor.owns_pane and not descriptor.pane.destroyed then
        descriptor.pane:destroy()
      end
      descriptor.pane:_unbind(self)
      finalized[descriptor.pane] = true
    end
  end
end

---@param record Applet.HostRecord
---@return Applet.HostInteraction
function Applet:_surface_interaction(record)
  local descriptor = record.descriptor
  local interaction = {
    revision = self.generation,
    scopes = descriptor.scopes,
  }
  ---@param name string
  ---@return boolean
  interaction.has_action = function(name)
    return built_in_actions[name] == true or self.known_handlers[name] == true
  end
  ---@param event Applet.ActionEvent<Applet.Pane>
  ---@return unknown
  interaction.dispatch = function(event)
    self:_refresh_observations()
    if self.lifecycle ~= "open" then return false end
    -- Enrich the same event so pass requests retain their identity.
    ---@cast event Applet.AppletActionEvent<S>
    event.applet = self
    event.pane = record.descriptor.pane
    event.generation = self.committed_generation
    if event.action == "applet.close" then
      return (self:close())
    elseif event.action == "applet.focus" then
      local payload = event.payload --[[@as {pane?: string}?]]
      return self:focus(payload and payload.pane)
    elseif event.action == "applet.focus.move" then
      return self:_focus_move(event.payload --[[@as Applet.FocusMove?]] or {})
    elseif event.action == "applet.focus.restore" then
      return self:_restore_focus()
    end
    local handler = self.handlers[event.action]
    if not handler then return false end
    local ok, result = pcall(handler, event)
    if not ok then
      self:_report("action", result, record.key)
      return false
    end
    return result
  end
  ---@param event Applet.ActionEvent<Applet.Pane>
  ---@return boolean
  interaction.pass = function(event) return Base.pass(record, event) end
  return interaction
end

---@param frame Applet.Frame
---@param opening boolean
---@param opts? {preserve_connected?: boolean}
function Applet:_mount_content(frame, opening, opts)
  local driver = assert(self.driver)
  opts = opts or {}
  for _, key in ipairs(frame.pane_order) do
    local record = self.records[key]
    if record and record.active and not record.suppressed and mounted(record) then
      local pane = record.descriptor.pane
      local was_connected = pane.surface ~= nil
      local ok, err = pcall(function()
        if not was_connected then
          pane:_connect(Base.surface(self, driver, record))
          self.counters.pane_mounts = self.counters.pane_mounts + 1
        else
          Base.update_surface(self, driver, record)
          assert(pane.surface_changed)(pane, { chrome = true })
        end
        if pane.has_submission
            and not (opts.preserve_connected and was_connected) then
          local committed, commit_error = pane:flush()
          if not committed then error(commit_error and commit_error.message
            or "Pane commit failed", 0) end
        end
      end)
      if not ok then
        if record.descriptor.required and not was_connected then error(err, 0) end
        if was_connected then
          self:_report("commit", err, key)
          Base.restore_view(record)
        else
          if pane.surface then pane:_disconnect() end
          record.surface = nil
          record.suppressed = record.mount_token
          driver:detach(record)
          if driver.adopt_detach then
            driver:adopt_detach(frame, self.records)
          end
          self:_report("commit", err, key)
        end
      elseif record.view_policy_revision ~= pane:_view_policy_revision() then
        record.view_policy_revision = pane:_view_policy_revision()
        Base.save_view(record)
      else
        Base.restore_view(record)
      end
    elseif opening and record and record.descriptor.required then
      error("required Pane could not be mounted: " .. key, 0)
    end
  end
end

function Applet:_cleanup_inactive()
  for key, record in pairs(self.records) do
    if not record.active and record.descriptor.lifecycle == "transient" then
      Base.delete_buffer(record)
      local pane = record.descriptor.pane
      if record.descriptor.owns_pane then pane:destroy() end
      pane:_unbind(self)
      self.records[key] = nil
      self.measurements[key] = nil
    end
  end
end

---@param previous? Applet.Frame
---@param frame Applet.Frame
---@param opening boolean
function Applet:_focus_after_commit(previous, frame, opening)
  local previous_layers = {}
  for _, layer in ipairs(previous and previous.layers or {}) do previous_layers[layer.key] = true end
  local current_layers = {}
  local target
  for _, layer in ipairs(frame.layers) do
    current_layers[layer.key] = true
    if not previous_layers[layer.key] and layer.restore_focus then
      self.layer_focus[layer.key] = target or self.focused
    end
    if not previous_layers[layer.key] and layer.enter and layer.panes[1] then
      target = layer.panes[1]
    end
  end
  for index = #(previous and previous.layers or {}), 1, -1 do
    local layer = assert(assert(previous).layers[index])
    if not current_layers[layer.key] then
      if not target or not frame.panes[target] then
        target = self.layer_focus[layer.key]
      end
      self.layer_focus[layer.key] = nil
    end
  end
  local intent = frame.focus.intent
  local token
  if intent then
    token = intent.key .. "\0" .. tostring(intent.revision)
    if token ~= self.applied_focus_intent then
      target = intent.key
    end
  end
  self.applied_focus_intent = token
  target = target or frame.focus.layer_entry
  if opening or not self.focused or not frame.panes[self.focused] then
    target = target or frame.focus.initial
  end
  if target and self.records[target] and mounted(self.records[target]) then
    self:focus(target)
  end
end

---@param previous? Applet.Frame
---@param frame Applet.Frame
---@param opening boolean
---@return boolean
function Applet:_commit_frame(previous, frame, opening)
  assert(self.driver)
  -- A frame transaction may resize, replace, or reconnect several windows.
  -- Capture every live Pane immediately before that transaction so restoration
  -- reflects the user's current view at the transaction boundary.
  for _, record in pairs(self.records) do
    if record.active and mounted(record) then Base.save_view(record) end
  end
  for _, key in ipairs(frame.pane_order) do
    local before = previous and previous.panes[key]
    if not before or not util.equal(before.scopes, frame.panes[key].scopes) then
      self.counters.mapping_scope_changes =
        self.counters.mapping_scope_changes + 1
    end
  end
  self:_prepare_records(frame)
  local reconciled, reconcile_error = pcall(
    self.driver.reconcile, self.driver, previous, frame, self.records)
  if not reconciled then error(reconcile_error, 0) end
  self:_mount_content(frame, opening)
  self.frame = frame
  self.active_host = frame.host
  self.selected_host = frame.host
  self.committed_generation = frame.generation
  self.counters.frame_commits = self.counters.frame_commits + 1
  self.domain:surfaces_changed()
  self.counters.surface_invalidations = self.counters.surface_invalidations + 1
  return true
end

---@return boolean
function Applet:_measure()
  local changed = false
  for _, layer in ipairs(self.frame and self.frame.layers or {}) do
    if layer.width_request or layer.height_request then
      for _, key in ipairs(layer.panes) do
        local record = self.records[key]
        local measured = record and Base.measure(record)
        if measured and not same_measurement(self.measurements[key], measured) then
          self.measurements[key] = measured
          changed = true
        end
      end
    end
  end
  return changed
end

---@param record Applet.HostRecord
---@param info? Applet.PaneCommit
---@return boolean
function Applet:_content_committed(record, info)
  if self.lifecycle ~= "open" or self.mutating or self.measuring
      or not record.active or not self.frame then return false end
  if info and info.chrome then
    self:_refresh_observations()
    if self.lifecycle ~= "open" or self.mutating or self.measuring
        or not record.active or not self.frame then return false end
    self:_sync_observed()
  end
  local requested = false
  for _, layer in ipairs(self.frame.layers) do
    if (layer.width_request or layer.height_request) then
      for _, key in ipairs(layer.panes) do
        if key == record.key then requested = true break end
      end
    end
    if requested then break end
  end
  if not requested then return false end
  local measured = Base.measure(record)
  if not measured or same_measurement(self.measurements[record.key], measured) then
    return false
  end
  local generation = info and info.generation or 0
  if record.measurement_generation ~= generation then
    record.measurement_generation = generation
    record.measurement_updates = 0
  end
  record.measurement_updates = assert(record.measurement_updates) + 1
  if record.measurement_updates > 2 then
    self:_report("measure", "content measurement exceeded two recompilations",
      record.key)
    return false
  end
  self.measurements[record.key] = measured
  self.counters.measurement_passes = self.counters.measurement_passes + 1
  self.request_pending = true
  self:_request_flush()
  return true
end

---@return boolean?, Applet.Error?
function Applet:_settle_measurements()
  if self.measuring then return true end
  self.measuring = true
  local ok, result, result_error = pcall(function()
    local signatures = {}
    for _ = 1, 2 do
      if not self:_measure() then return true end
      self.counters.measurement_passes = self.counters.measurement_passes + 1
      local frame, err = self:_prepare_frame(false)
      if not frame then return nil, err end
      local dimensions = {}
      for _, layer in ipairs(frame.layers) do
        dimensions[#dimensions + 1] = table.concat({ layer.key, layer.rect.row,
          layer.rect.col, layer.rect.width, layer.rect.height }, ":")
      end
      local signature = table.concat(dimensions, "|")
      if signatures[signature] then
        return self:_report("measure", "content measurement did not settle")
      end
      signatures[signature] = true
      local previous = self.frame
      self:_commit_frame(previous, frame, false)
    end
    if self:_measure() then
      return self:_report("measure", "content measurement exceeded two recompilations")
    end
    return true
  end)
  self.measuring = false
  if not ok then return self:_report("measure", result) end
  return result, result_error
end

---@param previous Applet.Frame
---@param checkpoint Applet.RecordCheckpoint
---@return boolean?, Applet.Error?
function Applet:_rollback_update(previous, checkpoint)
  self.counters.rollbacks = self.counters.rollbacks + 1
  local restored, restore_error = pcall(function()
    local driver = assert(self.driver)
    if driver.rollback then driver:rollback(self.records) end
    self:_discard_candidate_records(checkpoint)
    self:_mount_content(previous, false, { preserve_connected = true })
    self.frame = previous
    self.active_host = previous.host
    self.selected_host = previous.host
    self.committed_generation = previous.generation
  end)
  self.host_transaction = false
  self.mutating = false
  self.pane_replacements = nil
  if restored then return true end

  pcall(self.close, self, { restore_origin = false })
  return self:_report("commit", "rollback failed: " .. tostring(restore_error))
end

---@param previous Applet.Frame
---@param checkpoint Applet.RecordCheckpoint
---@param failure unknown
---@param structured? boolean
---@return nil, Applet.Error
function Applet:_recover_update(previous, checkpoint, failure, structured)
  local restored, restore_error = self:_rollback_update(previous, checkpoint)
  if not restored then return nil, assert(restore_error) end
  if structured then return nil, failure --[[@as Applet.Error]] end
  return self:_report("commit", failure)
end

---@return boolean?, Applet.Error?
function Applet:_flush_requested()
  if self.observing then return true end
  self:_refresh_observations()
  if self.lifecycle == "destroyed" or not self.has_submission
      or not self.request_pending then return false end
  local frame, err = self:_prepare_frame(false)
  if not frame then return nil, err end
  self.pending_frame = frame
  if self.lifecycle ~= "open" then
    self.request_pending = false
    return true
  end
  local previous = assert(self.frame)
  assert(self.driver)
  local record_checkpoint = self:_record_checkpoint()
  self.pane_replacements = {}
  self.host_transaction = true
  self.mutating = true
  local begun, begin_error = true, nil
  if self.driver.begin then
    begun, begin_error = pcall(self.driver.begin, self.driver, self.records)
  end
  if not begun then
    return self:_recover_update(previous, record_checkpoint, begin_error)
  end
  local committed, commit_error = pcall(self._commit_frame, self, previous, frame, false)
  if not committed then
    return self:_recover_update(previous, record_checkpoint, commit_error)
  end
  local measured, measurement_error = self:_settle_measurements()
  if not measured then
    return self:_recover_update(previous, record_checkpoint,
      measurement_error, true)
  end
  local driver = assert(self.driver)
  local published, publication_error = pcall(
    driver.publish, driver, self.frame, self.records)
  if not published then
    return self:_recover_update(previous, record_checkpoint, publication_error)
  end
  self:_cleanup_inactive()
  self:_finalize_replaced_records(record_checkpoint)
  self.pane_replacements = nil
  self.host_transaction = false
  self:_focus_after_commit(previous, assert(self.frame), false)
  self.domain:surfaces_changed({ chrome = true })
  self.domain:flush()
  self:_sync_observed()
  self.request_pending = false
  self.mutating = false
  return true
end

---@param previous? Applet.Frame
---@param checkpoint Applet.RecordCheckpoint
---@return boolean?, string?
function Applet:_abort_open(previous, checkpoint)
  local errors = {}
  for _, record in pairs(self.records) do
    if record.descriptor and record.descriptor.pane.surface then
      local disconnected, disconnect_error = pcall(
        record.descriptor.pane._disconnect, record.descriptor.pane)
      if not disconnected then errors[#errors + 1] = disconnect_error end
    end
    record.surface = nil
  end
  if self.driver then
    local released, release_error = pcall(
      self.driver.destroy, self.driver, self.records)
    if not released then errors[#errors + 1] = release_error end
  end
  local restored, restore_error = pcall(
    self._discard_candidate_records, self, checkpoint)
  if not restored then errors[#errors + 1] = restore_error end
  for _, record in pairs(self.records) do
    record.window, record.surface = nil, nil
  end
  self.driver, self.active_host, self.frame = nil, nil, previous
  self.committed_generation = previous and previous.generation or 0
  self.host_transaction = false
  self.pane_replacements = nil
  self.mutating = false
  self.lifecycle = "closed"
  local synced, sync_error = pcall(self._sync_closed_observed, self)
  if not synced then errors[#errors + 1] = sync_error end
  local observed, observer_error = pcall(
    self._set_observer_scope, self, self:_closed_observer_scope())
  if not observed then errors[#errors + 1] = observer_error end
  local focused, focus_error = pcall(Base.restore_origin, self.origin, self)
  if not focused then errors[#errors + 1] = focus_error end
  if #errors > 0 then return nil, table.concat(errors, "; ") end
  return true
end

---@param previous? Applet.Frame
---@param checkpoint Applet.RecordCheckpoint
---@param failure unknown
---@param structured? boolean
---@return nil, Applet.Error
function Applet:_abort_open_failure(previous, checkpoint, failure, structured)
  local aborted, abort_error = self:_abort_open(previous, checkpoint)
  if not aborted then
    return self:_report("commit", "open rollback failed: " .. assert(abort_error))
  end
  if structured then return nil, failure --[[@as Applet.Error]] end
  return self:_report("commit", failure)
end

---@param opts? Applet.OpenOptions|integer
---@return boolean?, Applet.Error?
function Applet:open(opts)
  self:_assert_alive()
  if self.observing then
    self.deferred_open = copy_owned(opts or {})
    return true
  end
  self:_refresh_observations()
  if self.lifecycle == "open" then
    local target = self.focused or self.frame and self.frame.focus.initial
    if target then self:focus(target) end
    return true
  end
  assert(self.lifecycle == "closed", "Applet lifecycle transition is active")
  opts = opts or {}
  local origin_window
  if type(opts) == "number" then origin_window = opts
  elseif type(opts) == "table" then origin_window = opts.origin_window or opts.origin end
  self.origin = Base.capture_origin(origin_window)
  self.lifecycle = "opening"
  local frame, prepare_error = self:_prepare_frame(self.has_opened == true)
  if not frame then
    self.lifecycle = "closed"
    return nil, prepare_error
  end
  local previous = self.frame
  local record_checkpoint = self:_record_checkpoint()
  self.pane_replacements = {}
  self.host_transaction = true
  self.mutating = true
  local observing, observer_error = pcall(self._set_observer_scope, self, "live")
  if not observing then
    self.host_transaction = false
    self.pane_replacements = nil
    self.mutating = false
    self.lifecycle = "closed"
    return self:_report("host", observer_error)
  end
  local opened, open_error = pcall(function()
    self.driver = driver_for(frame.host.kind).new(self, self.origin)
    self.active_host = frame.host
    self:_commit_frame(previous, frame, true)
  end)
  if not opened then
    return self:_abort_open_failure(previous, record_checkpoint, open_error)
  end
  local measured, measurement_error = self:_settle_measurements()
  if not measured then
    return self:_abort_open_failure(previous, record_checkpoint,
      measurement_error, true)
  end
  local driver = assert(self.driver)
  local published, publication_error = pcall(
    driver.publish, driver, self.frame, self.records)
  if not published then
    return self:_abort_open_failure(previous, record_checkpoint,
      publication_error)
  end
  self.lifecycle = "open"
  self.has_opened = true
  self.request_pending = false
  self.counters.host_publications = self.counters.host_publications + 1
  self:_cleanup_inactive()
  self:_finalize_replaced_records(record_checkpoint)
  self.pane_replacements = nil
  self.host_transaction = false
  self:_focus_after_commit(nil, assert(self.frame), true)
  self.domain:surfaces_changed({ chrome = true })
  self.domain:flush()
  self:_sync_observed()
  self.mutating = false
  return true
end

---@param opts? Applet.CloseOptions
---@return boolean
function Applet:close(opts)
  if self.lifecycle == "destroyed" or self.lifecycle == "closed" then return true end
  if self.lifecycle == "closing" then return true end
  if self.observing then
    self.deferred_close = copy_owned(opts or {})
    return true
  end
  opts = opts or {}
  self.mutating = true
  self.lifecycle = "closing"
  local current = vim.api.nvim_get_current_win()
  local restore = opts.restore_origin ~= false and self._windows[current] ~= nil
  local transient = {}
  for _, record in pairs(self.records) do
    if record.active then
      Base.save_view(record)
      if record.descriptor.pane.surface then record.descriptor.pane:_disconnect() end
      record.surface = nil
      if record.descriptor.lifecycle == "transient" then
        transient[#transient + 1] = record.key
      end
      record.active = false
    end
  end
  if self.driver then self.driver:release(self.records) end
  for _, key in ipairs(transient) do
    local record = self.records[key]
    if record then
      Base.delete_buffer(record)
      if record.descriptor.owns_pane
          and not record.descriptor.pane.destroyed then
        record.descriptor.pane:destroy()
      end
      record.descriptor.pane:_unbind(self)
      self.records[key], self.measurements[key] = nil, nil
    end
  end
  for _, record in pairs(self.records) do
    record.window, record.surface = nil, nil
    record.adopted_window_options = {}
    record.adopted_float_config = nil
    record.requested_float_config = nil
  end
  self.driver, self.active_host, self.focused = nil, nil, nil
  self.overrides = {}
  self.lifecycle = "closed"
  self:_sync_closed_observed()
  self:_set_observer_scope(self:_closed_observer_scope())
  self.mutating = false
  if restore then Base.restore_origin(self.origin, self) end
  return true
end

---@param opts? Applet.ToggleOptions
---@return boolean?, Applet.Error?
function Applet:toggle(opts)
  if self:is_open() then return self:close(opts) end
  return self:open(opts)
end

---@return boolean
function Applet:is_open()
  return self.lifecycle == "open"
end

---@return boolean
function Applet:is_visible()
  return self.lifecycle == "open" and self.driver and self.driver:is_visible() or false
end

---@return Applet.HostInput|{kind?: nil}
function Applet:host()
  local value = self.active_host or self.queued_host or self.requested_host or self.selected_host
  return copy_semantic(value or {})
end

---@return Applet.HostSnapshot
function Applet:observed()
  return copy_semantic(self.observed_snapshot)
end

---@param key string
---@return Applet.Pane?
function Applet:pane(key)
  self:_assert_alive()
  local record = self.records[key]
  return record and record.descriptor and record.descriptor.pane or nil
end

---@param key string
---@return boolean
function Applet:remount(key)
  self:_assert_alive()
  self:_refresh_observations()
  local record = assert(self.records[key], "unknown Pane " .. tostring(key))
  record.suppressed = nil
  record.detach_reason = nil
  if self.lifecycle == "open" then
    self.request_pending = true
    self:_request_flush()
  end
  return true
end

---@param key string
---@return boolean
function Applet:_modal_allows(key)
  local boundary = self.frame and self.frame.modal_boundary or {}
  local active = false
  for _, candidate in ipairs(boundary) do
    if mounted(self.records[candidate]) then
      active = true
      if candidate == key then return true end
    end
  end
  if not active then return true end
  return false
end

---@param key? string
---@return boolean
function Applet:focus(key)
  self:_assert_alive()
  if not key then return false end
  if self.observing then
    self.deferred_focus = key
    return true
  end
  self:_refresh_observations()
  local record = self.records[key]
  if (self.lifecycle ~= "open" and self.lifecycle ~= "opening")
      or not record or not record.active
      or not mounted(record) or not self:_modal_allows(key) then return false end
  local previous = self.focused
  if previous and self.records[previous] then Base.save_view(self.records[previous]) end
  if not assert(self.driver):focus(record) then return false end
  self.focused = key
  if previous ~= key then
    self.counters.focus_changes = self.counters.focus_changes + 1
    local callback = self.callbacks.on_focus
    if callback then
      local ok, err = pcall(callback, key, previous)
      if not ok then self:_report("action", err, key) end
    end
  end
  -- WinLeave runs while Neovim still exposes the departing window as current.
  -- Publish the completed focus transition to every connected Applet and
  -- reconcile focus decorations before focus() returns.
  self.domain:surfaces_changed()
  self.domain:flush()
  self:_sync_observed()
  return true
end

---@return string?
function Applet:focused_pane()
  return self.focused
end

---@param rect Applet.Rectangle
---@return number, number
local function center(rect)
  return rect.col + rect.width / 2, rect.row + rect.height / 2
end

---@param opts Applet.FocusMove
---@return boolean
function Applet:_focus_move(opts)
  local frame = self.frame
  local current = frame and frame.panes[self.focused]
  if not current then return false end
  assert(frame)
  local direction = opts.direction
  if direction ~= "left" and direction ~= "right"
      and direction ~= "up" and direction ~= "down" then return false end
  local current_x, current_y = center(current.outer)
  local candidates = {}
  for _, key in ipairs(frame.pane_order) do
    local pane = frame.panes[key]
    if key ~= self.focused and pane.focusable and self:_modal_allows(key)
        and self.records[key] and mounted(self.records[key]) then
      local x, y = center(pane.outer)
      local primary = direction == "left" and current_x - x
        or direction == "right" and x - current_x
        or direction == "up" and current_y - y
        or y - current_y
      if primary > 0 then
        local secondary = (direction == "left" or direction == "right")
            and math.abs(y - current_y) or math.abs(x - current_x)
        candidates[#candidates + 1] = { key = key, primary = primary, secondary = secondary }
      end
    end
  end
  table.sort(candidates, function(left, right)
    if left.primary == right.primary then return left.secondary < right.secondary end
    return left.primary < right.primary
  end)
  if candidates[1] then return self:focus(candidates[1].key) end
  if opts.wrap then
    local order = frame.pane_order
    local target = (direction == "left" or direction == "up")
        and order[#order] or order[1]
    return self:focus(target)
  end
  return false
end

---@return boolean
function Applet:_restore_focus()
  for index = #(self.frame and self.frame.layers or {}), 1, -1 do
    local key = self.layer_focus[assert(assert(self.frame).layers[index]).key]
    if key and self:focus(key) then return true end
  end
  return false
end

---@param message string
---@param level? integer
function Applet:notify(message, level)
  self:_assert_alive()
  applet_expect(type(message) == "string", "notification", "must be a string", 3)
  return self.notify_effect(message, level)
end

---@param uri string
---@return vim.SystemObj?, string?
function Applet:open_uri(uri)
  self:_assert_alive()
  applet_expect(util.nonempty_string(uri), "URI", "must be a non-empty string", 3)
  return self.open_uri_effect(uri)
end

---@return boolean?, Applet.Error?
function Applet:flush()
  self:_assert_alive()
  if self.observing then return true end
  local observed = self:_refresh_observations()
  self.domain.dirty[self] = nil
  local committed, err = self:_flush_requested()
  if committed == false and observed then return true end
  return committed, err
end

---@param opts? {host?: boolean, reset_sizes?: boolean}
---@return integer
function Applet:invalidate(opts)
  self:_assert_alive()
  opts = opts or {}
  applet_expect(type(opts) == "table", "Applet.invalidate",
    "options must be a table", 3)
  for key in pairs(opts) do
    applet_expect(key == "host" or key == "reset_sizes",
      "Applet.invalidate." .. tostring(key), "is not recognized", 3)
  end
  applet_expect(opts.host == nil or type(opts.host) == "boolean",
    "Applet.invalidate.host", "must be a boolean", 3)
  applet_expect(opts.reset_sizes == nil or type(opts.reset_sizes) == "boolean",
    "Applet.invalidate.reset_sizes", "must be a boolean", 3)
  if opts.host then self:_schedule_observe("Explicit", { event = "explicit" }) end
  if opts.reset_sizes then self.overrides = {} end
  if not opts.host or opts.reset_sizes then
    self.generation = self.generation + 1
    self.counters.requested_generations = self.counters.requested_generations + 1
    if self.has_submission then
      self.request_pending = true
      self:_request_flush()
    end
  end
  return self.generation
end

---@return Applet.Stats
function Applet:_stats()
  local result = util.copy(self.counters) --[[@as Applet.Stats]]
  result.observer_scope = self.observer_scope
  result.interaction = self.domain:_stats()
  return result
end

---@param value Applet.HostSnapshot
---@return table
local function snapshot_facts(value)
  local result = copy_semantic(value) --[[@as {revision?: integer}]]
  result.revision = nil
  return result
end

---@generic S
---@param applet Applet.Applet<S>
---@return string[]
local function sorted_record_keys(applet)
  local result, present = {}, {}
  for _, key in ipairs(applet.frame and applet.frame.pane_order or {}) do
    result[#result + 1], present[key] = key, true
  end
  local retained = {}
  for key in pairs(applet.records) do
    if not present[key] then retained[#retained + 1] = key end
  end
  table.sort(retained)
  for _, key in ipairs(retained) do result[#result + 1] = key end
  return result
end

---@return Applet.HostSnapshot
function Applet:_closed_snapshot()
  local panes = {}
  for _, key in ipairs(sorted_record_keys(self)) do
    local record = self.records[key]
    if record then
      local buffer = record.buffer
      panes[key] = {
        mounted = false,
        visible = false,
        buffer = {
          ownership = record.owns_buffer and "owned" or "none",
          loaded = Base.loaded_buffer(buffer),
          displayed = #Base.buffer_windows(buffer) > 0,
        },
        mode = record.mode,
        detach_reason = record.detach_reason,
        buffer_options = {},
        window_options = {},
      }
    end
  end
  return {
    revision = 0,
    request_generation = self.committed_generation,
    host = { kind = self:host().kind, open = false, visible = false },
    layout = { kind = "closed" },
    panes = panes,
    focused_pane = nil,
    foreign_windows = 0,
  }
end

---@param candidate Applet.HostSnapshot
---@param external? boolean
---@return boolean
function Applet:_publish_snapshot(candidate, external)
  local before = self.observed_snapshot
  if util.equal(snapshot_facts(before), snapshot_facts(candidate)) then
    candidate.revision = before.revision or 0
    self.observed_snapshot = candidate
    return false
  end
  candidate.revision = (before.revision or 0) + 1
  self.observed_snapshot = candidate
  if external then
    self.counters.observation_batches = self.counters.observation_batches + 1
  end
  return true
end

function Applet:_sync_observed()
  if self.lifecycle ~= "open" or not self.driver or not self.frame then return end
  local candidate = Base.snapshot(self.driver, self.records, self.frame, 0,
    self.committed_generation)
  self.counters.host_snapshot_refreshes = self.counters.host_snapshot_refreshes + 1
  self:_publish_snapshot(candidate, false)
end

function Applet:_sync_closed_observed()
  self:_publish_snapshot(self:_closed_snapshot(), false)
end

---@param kind string
---@param native Applet.NativeObservation
function Applet:_schedule_observe(kind, native)
  if self.lifecycle == "destroyed" then return end
  self.observation_kinds = self.observation_kinds or {}
  self.observation_kinds[kind] = true
  self.observation_native = self.observation_native or {}
  self.observation_native[#self.observation_native + 1] = copy_semantic(native or {})
  if self.observation_scheduled then return end
  self.observation_scheduled = true
  vim.schedule(function()
    self.observation_scheduled = false
    local kinds = self.observation_kinds
    local captured = self.observation_native
    self.observation_kinds = nil
    self.observation_native = nil
    if kinds and self.lifecycle ~= "destroyed" then self:_observe(kinds, captured) end
  end)
end

---@param kind Applet.ObservationKind
---@param key string?
---@param before Applet.ObservationValue
---@param after Applet.ObservationValue
---@param native Applet.CapturedNative
---@param reason string
---@param fields? Applet.ObservationFields
function Applet:_event(kind, key, before, after, native, reason, fields)
  local called, active = false, true
  ---@type Applet.ExternalEvent
  local event = {
    applet = self,
    source = "neovim",
    kind = kind,
    reason = reason,
    revision = self.observed_snapshot.revision,
    request_generation = self.committed_generation,
    pane = key and self:pane(key) or nil,
    before = copy_semantic(before),
    after = copy_semantic(after),
    native = function() return copy_semantic(native or {}) end,
  }
  for name, value in pairs(fields or {}) do event[name] = copy_semantic(value) end
  local default = function()
    if called or not active then return false end
    called = true
    self.counters.default_external_handlers =
      self.counters.default_external_handlers + 1
    if kind == "resize" then
      for pane_key in pairs(fields and fields.panes or {}) do
        local record = self.records[pane_key]
        if record and record.descriptor.projection.kind == "floating"
            and Base.valid_window(record.window) then
          record.adopted_float_config = vim.api.nvim_win_get_config(record.window)
        end
      end
      if self.active_host and self.active_host.kind == "tab" then
        self:_adopt_sizes()
      end
      if self.has_submission and self.lifecycle == "open"
          and (assert(self.active_host).kind == "tab"
            or reason == "container_resized" or reason == "editor_resized") then
        self.request_pending = true
        self:_request_flush()
      end
    elseif kind == "layout_change" then
      self.adopted_layout = copy_semantic(after --[[@as Applet.ObservedLayout]])
    elseif (kind == "pane_buffer_change" or kind == "pane_close")
        and key and self.records[key] then
      local record = self.records[key]
      record.suppressed = record.mount_token
      if self.driver and self.driver.adopt_detach then
        self.driver:adopt_detach(self.frame, self.records)
      end
    elseif kind == "pane_options_change" and key and self.records[key] then
      local record = self.records[key]
      if fields and fields.scope == "window" then
        record.adopted_window_options = record.adopted_window_options or {}
        record.adopted_window_options[fields.option] = fields.value
        if record.surface and self.driver then
          Base.update_surface(self, assert(self.driver), record)
        end
      else
        record.adopted_buffer_options = record.adopted_buffer_options or {}
        assert(fields)
        record.adopted_buffer_options[assert(fields.option)] = fields.value
      end
    elseif kind == "mode_change" and key and self.records[key]
        and self.records[key].descriptor.focus.mode == "preserve" then
      self.records[key].mode = (after --[[@as Applet.PaneObservation]]).mode
    end
    return true
  end
  local callback = self.callbacks["on_" .. kind]
  if callback then
    local ok, err = pcall(callback, event, default)
    if not ok then self:_report("action", err, key) end
  else
    default()
  end
  active = false
end

---@generic S
---@param applet Applet.Applet<S>
---@param topology Applet.LayoutTopology
---@return Applet.Rectangle?
local function topology_bounds(applet, topology)
  if topology.type == "pane" then
    local record = applet.records[topology.key]
    return record and Base.window_geometry(record.window) or nil
  end
  if topology.type == "scope" then
    return topology_bounds(applet, (topology --[[@as Applet.ScopeTopology]]).child)
  end
  ---@cast topology Applet.SplitTopology
  ---@type Applet.Rectangle?
  local result
  for _, child in ipairs(topology.children) do
    local rect = topology_bounds(applet, child.child)
    if rect then
      if not result then result = copy_semantic(rect) else
        local right = math.max(result.col + result.width, rect.col + rect.width)
        local bottom = math.max(result.row + result.height, rect.row + rect.height)
        result.row = math.min(result.row, rect.row)
        result.col = math.min(result.col, rect.col)
        result.width = right - result.col
        result.height = bottom - result.row
      end
    end
  end
  return result
end

function Applet:_adopt_sizes()
  ---@param topology Applet.LayoutTopology
  local function visit(topology)
    if topology.type == "pane" then return end
    if topology.type == "scope" then
      return visit((topology --[[@as Applet.ScopeTopology]]).child)
    end
    ---@cast topology Applet.SplitTopology
    ---@type integer[]
    local sizes = {}
    for _, child in ipairs(topology.children) do
      local rect = topology_bounds(self, child.child)
      sizes[#sizes + 1] = rect and (topology.axis == "vertical"
        and rect.height or rect.width) or child.size
      visit(child.child)
    end
    local bounds = topology_bounds(self, topology)
    local total = bounds and (topology.axis == "vertical"
        and bounds.height or bounds.width) or nil
    local used = 0
    for _, size in ipairs(sizes) do used = used + size end
    if total and used ~= total then sizes[#sizes] = assert(sizes[#sizes]) + total - used end
    self.overrides[topology.key] = { signature = topology.signature, sizes = sizes }
  end
  if self.frame then visit(self.frame.topology) end
end

---@param captured? Applet.NativeObservation[]
---@param key? string
---@param record? Applet.HostRecord
---@return Applet.CapturedNative
local function captured_native(captured, key, record)
  local result = { events = {} }
  for _, value in ipairs(captured or {}) do
    result.events[#result.events + 1] = value.event
    if value.window ~= nil then result.window = value.window end
    if value.tab ~= nil then result.tab = value.tab end
    if value.buffer ~= nil then result.buffer = value.buffer end
    if value.match ~= nil then result.match = value.match end
  end
  if record then
    result.window = record.window or result.window
    result.buffer = record.buffer or result.buffer
  end
  result.pane = key
  return result
end

---@param kinds table<string, true>
---@return string?
local function buffer_reason(kinds)
  if kinds.BufWipeout then return "buffer_wiped" end
  if kinds.BufDelete then return "buffer_deleted" end
  if kinds.BufUnload then return "buffer_unloaded" end
end

---@param key string
---@param reason string
function Applet:_mandatory_detach(key, reason)
  local record = self.records[key]
  if not record then return end
  local window, buffer = record.window, record.buffer
  Base.save_view(record)
  if record.descriptor.pane.surface then
    record.descriptor.pane:_disconnect(reason == "buffer_wiped")
  end
  record.surface = nil
  if window then self._windows[window] = nil end
  record.window = nil
  record.detach_reason = reason
  self.counters.pane_unmounts = self.counters.pane_unmounts + 1
  if reason == "buffer_unloaded" or reason == "buffer_deleted"
      or reason == "buffer_wiped" then
    if record.descriptor.lifecycle == "transient" and Base.valid_buffer(buffer) then
      Base.delete_buffer(record)
    else
      record.buffer, record.owns_buffer = nil, false
      record.buffer_option_states = {}
      record.requested_buffer_options = nil
    end
  elseif record.descriptor.lifecycle == "transient" then
    Base.delete_buffer(record)
  end
end

function Applet:_finish_observation()
  self.observing = false
  if self.deferred_destroy then
    self.deferred_destroy = nil
    self.deferred_close = nil
    self:destroy()
    return
  end
  if self.deferred_close then
    local opts = self.deferred_close
    self.deferred_close = nil
    self:close(opts)
  end
  if self.deferred_open then
    local opts = self.deferred_open
    self.deferred_open = nil
    self:open(opts)
  end
  if self.deferred_focus then
    local key = self.deferred_focus
    self.deferred_focus = nil
    self:focus(key)
  end
end

---@param before Applet.HostSnapshot
---@param reason string
---@param captured? Applet.NativeObservation[]
function Applet:_external_host_close(before, reason, captured)
  local active_host = self.active_host or self.selected_host
  local driver = self.driver
  local transient = {}
  for key, record in pairs(self.records) do
    if record.descriptor and record.descriptor.pane.surface then
      record.descriptor.pane:_disconnect()
    end
    if record.window then self._windows[record.window] = nil end
    record.surface, record.window, record.active = nil, nil, false
    if record.descriptor.lifecycle == "transient" then transient[#transient + 1] = key end
  end
  for _, key in ipairs(transient) do
    local record = self.records[key]
    Base.delete_buffer(record)
    if record.descriptor.owns_pane and not record.descriptor.pane.destroyed then
      record.descriptor.pane:destroy()
    end
    record.descriptor.pane:_unbind(self)
    self.records[key], self.measurements[key] = nil, nil
  end
  if driver then pcall(driver.release, driver, self.records) end
  self.driver, self.active_host, self.focused = nil, nil, nil
  self.selected_host = active_host or self.selected_host
  self.overrides, self.adopted_layout = {}, nil
  self.lifecycle = "closed"
  self:_set_observer_scope(self:_closed_observer_scope())
  local after = self:_closed_snapshot()
  after.host.kind = before.host.kind
  self:_publish_snapshot(after, true)
  self.observing = true
  self.counters.external_changes = self.counters.external_changes + 1
  self:_event("host_close", nil, before.host, self.observed_snapshot.host,
    captured_native(captured), reason)
  self:_finish_observation()
end

---@param before Applet.HostSnapshot
---@param after Applet.HostSnapshot
---@return string
local function layout_change_reason(before, after)
  if before.foreign_windows < after.foreign_windows then return "window_added" end
  if before.foreign_windows > after.foreign_windows then return "window_removed" end
  return "window_reordered"
end

---@param key string
---@param old Applet.PaneObservation
---@param new Applet.PaneObservation
---@param native Applet.CapturedNative
---@return Applet.ObservationChange[]
local function option_changes(key, old, new, native)
  ---@type Applet.ObservationChange[]
  local result = {}
  for _, scope in ipairs({ "buffer", "window" }) do
    local field = scope .. "_options"
    local names = {}
    for name in pairs(old[field] or {}) do names[name] = true end
    for name in pairs(new[field] or {}) do names[name] = true end
    local ordered = {}
    for name in pairs(names) do ordered[#ordered + 1] = name end
    table.sort(ordered)
    for _, name in ipairs(ordered) do
      local before_value, after_value = (old[field] or {})[name], (new[field] or {})[name]
      if not util.equal(before_value, after_value) then
        result[#result + 1] = {
          kind = "pane_options_change",
          key = key,
          before = old,
          after = new,
          native = native,
          reason = scope .. "_option",
          fields = { scope = scope, option = name, value = after_value },
        }
      end
    end
  end
  return result
end

---@param kinds table<string, true>
---@param captured? Applet.NativeObservation[]
function Applet:_observe_closed(kinds, captured)
  local before = self.observed_snapshot
  ---@type Applet.ObservationChange[]
  local events = {}
  local loss = buffer_reason(kinds)
  if loss then
    for _, key in ipairs(sorted_record_keys(self)) do
      local record = self.records[key]
      local old = before.panes[key] or {}
      if record and record.owns_buffer and (not Base.valid_buffer(record.buffer)
          or not Base.loaded_buffer(record.buffer)) then
        local native = captured_native(captured, key, record)
        self:_mandatory_detach(key, loss)
        events[#events + 1] = {
          kind = "pane_buffer_change", key = key, before = old,
          native = native, reason = loss,
        }
      end
    end
  end
  self:_set_observer_scope(self:_closed_observer_scope())
  local candidate = self:_closed_snapshot()
  self.counters.host_snapshot_refreshes = self.counters.host_snapshot_refreshes + 1
  local changed = self:_publish_snapshot(candidate, #events > 0)
  if not changed or #events == 0 then return end
  self.observing = true
  for _, event in ipairs(events) do
    event.after = self.observed_snapshot.panes[event.key] or {}
    self:_event(event.kind, event.key, event.before, assert(event.after),
      event.native, event.reason)
  end
  self.counters.external_changes = self.counters.external_changes + #events
  self:_finish_observation()
end

---@param kinds? table<string, true>
---@param captured? Applet.NativeObservation[]
function Applet:_observe(kinds, captured)
  kinds = kinds or {}
  if self.lifecycle ~= "open" or not self.driver or not self.frame then
    return self:_observe_closed(kinds, captured)
  end
  local before = self.observed_snapshot
  if not self.driver:is_open() then
    return self:_external_host_close(before, "tab_closed", captured)
  end

  local environment_changed, environment_reason, observed_environment = false, nil, nil
  if kinds.VimResized or kinds.WinResized or kinds.WinNew
      or kinds.WinClosed or kinds.TabEnter or kinds.TabLeave
      or kinds.Explicit then
    local ok, environment = pcall(self._render_environment,
      self, assert(self.active_host), false)
    if ok and environment then
      observed_environment = environment
      environment_changed = not same_rect(environment.host.bounds,
        self.frame and self.frame.bounds or {})
        or not same_rect(environment.host.container,
          self.frame and self.frame.plan.container or {})
      environment_reason = kinds.VimResized and "editor_resized"
        or "container_resized"
    end
  end

  local candidate = Base.snapshot(self.driver, self.records, self.frame, 0,
    self.committed_generation)
  if self.mutating then self:_publish_snapshot(candidate, false) return end

  ---@type Applet.ObservationChange[]
  local detachments = {}
  local loss = buffer_reason(kinds)
  for _, key in ipairs(sorted_record_keys(self)) do
    local record = self.records[key]
    local old, new = before.panes[key] or {}, candidate.panes[key] or {}
    local reason, kind
    if old.mounted and not new.mounted then
      if loss and (not Base.valid_buffer(record.buffer)
          or not Base.loaded_buffer(record.buffer)) then
        kind, reason = "pane_buffer_change", loss
      elseif Base.valid_window(record.window)
          and Base.valid_buffer(record.buffer)
          and vim.api.nvim_win_get_buf(record.window) ~= record.buffer then
        kind, reason = "pane_buffer_change", "buffer_replaced"
      else
        kind, reason = "pane_close", "window_closed"
      end
    elseif loss and old.buffer and old.buffer.loaded
        and (not new.buffer or not new.buffer.loaded) then
      kind, reason = "pane_buffer_change", loss
    end
    if kind then
      detachments[#detachments + 1] = {
        kind = kind, key = key, before = old, reason = assert(reason),
        native = captured_native(captured, key, record),
      }
      self:_mandatory_detach(key, assert(reason))
    end
  end

  local host_lost = false
  if kinds.WinClosed and #detachments > 0 then
    host_lost = true
    for _, record in pairs(self.records) do
      if record.window and self.driver:owns_window(record.window, record)
          and Base.window_displays(record.window, record.buffer) then
        host_lost = false
        break
      end
    end
  end
  if host_lost then
    return self:_external_host_close(before, "last_host_window_closed", captured)
  end

  local after = Base.snapshot(self.driver, self.records, self.frame, 0,
    self.committed_generation)
  if observed_environment and after.layout.kind == "floating" then
    after.layout.container = copy_semantic(observed_environment.host.container) --[[@as Applet.Rectangle]]
  end
  self.counters.host_snapshot_refreshes = self.counters.host_snapshot_refreshes + 1
  ---@type Applet.ObservationChange[]
  local events = {}
  for _, event in ipairs(detachments) do
    event.after = after.panes[event.key] or {}
    events[#events + 1] = event
  end

  if not util.equal(before.layout, after.layout) then
    events[#events + 1] = {
      kind = "layout_change", before = before.layout, after = after.layout,
      native = captured_native(captured),
      reason = layout_change_reason(before, after),
    }
  end

  local changed_geometries = {}
  for _, key in ipairs(sorted_record_keys(self)) do
    local old, new = before.panes[key], after.panes[key]
    if old and new and old.mounted and new.mounted
        and not util.equal(old.geometry, new.geometry) then
      changed_geometries[key] = copy_semantic(new.geometry)
    end
  end
  if next(changed_geometries) or environment_changed then
    events[#events + 1] = {
      kind = "resize", before = before, after = after,
      native = captured_native(captured),
      reason = environment_reason or "pane_resized",
      fields = { panes = changed_geometries },
    }
  end

  for _, key in ipairs(sorted_record_keys(self)) do
    local old, new = before.panes[key] or {}, after.panes[key] or {}
    local changes = option_changes(key, old, new,
      captured_native(captured, key, self.records[key]))
    for _, event in ipairs(changes) do
      events[#events + 1] = event
    end
  end

  for _, key in ipairs(sorted_record_keys(self)) do
    local old, new = before.panes[key], after.panes[key]
    if old and new and old.mode ~= new.mode and new.mounted then
      events[#events + 1] = {
        kind = "mode_change", key = key, before = old, after = new,
        native = captured_native(captured, key, self.records[key]),
        reason = "mode_changed",
      }
    end
  end

  local previous_focus = self.focused
  local current_focus = after.focused_pane
  local focus_changed = current_focus and current_focus ~= previous_focus
  local redirect = current_focus and not self:_modal_allows(current_focus)
  if redirect then focus_changed = false end

  local facts_changed = self:_publish_snapshot(after, true)
  if not facts_changed then return end
  if #events == 0 and not focus_changed then
    self.counters.external_changes = self.counters.external_changes + 1
  else
    self.counters.external_changes = self.counters.external_changes
      + #events + (focus_changed and 1 or 0)
  end
  self.observing = true
  for _, event in ipairs(events) do
    self:_event(event.kind, event.key, event.before, assert(event.after),
      event.native, event.reason, event.fields)
  end
  if focus_changed then
    self.focused = current_focus
    local callback = self.callbacks.on_focus
    if callback then
      local ok, err = pcall(callback, assert(current_focus), previous_focus)
      if not ok then self:_report("action", err, current_focus) end
    end
  end
  if focus_changed and not redirect then
    local record = self.records[current_focus]
    if record then Base.apply_mode(record) end
  end
  if before.host.visible ~= after.host.visible then
    self.domain:surfaces_changed()
  end
  if redirect and self.frame.modal_boundary[1] then
    self.deferred_focus = self.frame.modal_boundary[1]
  end
  self:_finish_observation()
end

function Applet:destroy()
  if self.lifecycle == "destroyed" then return end
  if self.observing then
    self.deferred_close = { restore_origin = false }
    self.deferred_destroy = true
    return
  end
  self:close()
  for key, record in pairs(self.records) do
    Base.delete_buffer(record)
    if record.descriptor and record.descriptor.owns_pane
        and not record.descriptor.pane.destroyed then
      record.descriptor.pane:destroy()
    end
    if record.descriptor then record.descriptor.pane:_unbind(self) end
    self.records[key] = nil
  end
  self:_set_observer_scope(nil)
  self.observation_kinds, self.observation_native = nil, nil
  self.domain:remove(self)
  if self.owns_domain then self.domain:destroy() end
  self.lifecycle = "destroyed"
  self._windows = {}
end

---@class Applet.Factory
---@field new fun<S>(opts: Applet.AppletOptions<S>): Applet.Applet<S>
local module = { new = Applet.new }

return setmetatable(module, {
  __call = function(_, opts) return Applet.new(opts) end,
}) --[[@as Applet.Factory]]
