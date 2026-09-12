local compile = require("applet.pane.compile")
local reconcile = require("applet.pane.reconcile")
local input = require("applet.pane.input")
local Domain = require("applet.interaction_domain")
local Theme = require("applet.theme")
local util = require("applet.util")
local applet_expect = util.expect
local ImageSource = require("applet.image.source")
local Scene = require("applet.pane.scene")
local Base = require("applet.host.base")
local Mode = require("applet.mode")

---@class Applet.PaneError
---@field pane string
---@field phase string
---@field generation integer
---@field message string

---@class Applet.PaneRenderEnvironment
---@field extent Applet.PaneExtent
---@field width integer
---@field height? integer
---@field focused boolean
---@field theme_generation integer
---@field layout_generation integer
---@field images {status: Applet.ImageStatus, generation: integer}

---@class Applet.PaneOptions<S>
---@field key string
---@field extent? Applet.PaneExtent
---@field buffer_mode? 'managed'|'editable'
---@field render? fun(state: S, env: Applet.PaneRenderEnvironment): Applet.Tree|Applet.Node
---@field handlers? table<string, fun(event: Applet.ActionEvent<Applet.Pane<S>>): unknown>
---@field theme? Applet.Theme|Applet.ThemeOptions
---@field image_system? Applet.ImageSystem
---@field read_image_resource? Applet.ImageResourceReader
---@field frame_interval_ms? integer
---@field on_error? fun(error: Applet.PaneError)

---@class Applet.PaneInteraction<P>: Applet.InputInteraction<P>
---@field scopes Applet.LayoutScope[]
---@field revision? integer

---@class Applet.PaneSurface<P>: Applet.InputSurface<P, Applet.PaneInteraction<P>>, Applet.ReconcileSurface
---@field buffer integer
---@field window? fun(): integer?
---@field owns_buffer? boolean
---@field domain? Applet.InteractionDomain
---@field buffer_options? Applet.Options
---@field window_options? Applet.Options
---@field visible? fun(): boolean
---@field on_commit? fun(info: Applet.PaneCommit)
---@field chrome? Applet.WindowChrome

---@class Applet.ConnectedPaneSurface<P>: Applet.PaneSurface<P>
---@field buffer integer
---@field window fun(): integer?
---@field buffer_options Applet.Options
---@field window_options Applet.Options
---@field runtime_record Applet.FocusRecord

---@class Applet.AmbientTreeCache
---@field root Applet.Node
---@field wrapped Applet.Node
---@field revision integer
---@field scopes Applet.LayoutScope[]

---@class Applet.PaneImageSource
---@field identity string
---@field value Applet.ImageSource

---@class Applet.PaneImageRegion
---@field revision? string|number
---@field sources Applet.PaneImageSource[]

---@class Applet.PaneCounters: Applet.ReconcileCounters, Applet.PaneCompileStats
---@field requested_generations integer
---@field renders integer
---@field commits integer
---@field document_reuses integer
---@field layer_compilations integer
---@field layer_reuses integer
---@field composed_cells integer
---@field mapping_changes integer
---@field position_updates integer

---@class Applet.PaneGeometry
---@field host 'direct'|'tab'|'floating'
---@field row integer
---@field col integer
---@field content_width integer
---@field content_height integer
---@field outer_width integer
---@field outer_height integer
---@field screen_row integer
---@field screen_col integer
---@field screen_width integer
---@field screen_height integer
---@field zindex? integer

---@class Applet.Pane<S = unknown>: Applet.InputPane<Applet.Pane<S>, Applet.PaneLayout, Applet.ConnectedPaneSurface<Applet.Pane<S>>>, Applet.DomainMember
---@field id integer
---@field handlers table<string, fun(event: Applet.ActionEvent<Applet.Pane<S>>): unknown>
---@field committed_generation integer
---@field mapping_description? string
---@field saved_mappings? table<string, Applet.SavedMapping>
---@field installed_mappings? table<string, Applet.MappingPair>
---@field _key string
---@field buffer_mode 'managed'|'editable'
---@field extent Applet.PaneExtent
---@field render? fun(state: S, env: Applet.PaneRenderEnvironment): Applet.Tree|Applet.Node
---@field pending_state S
---@field pending_tree? Applet.Tree|Applet.Node
---@field tree? Applet.Tree|Applet.Node
---@field direct_tree boolean
---@field theme Applet.Theme
---@field theme_generation integer
---@field compile_theme Applet.CompileTheme
---@field image_system? Applet.ImageSystem
---@field read_image_resource? Applet.ImageResourceReader
---@field on_error? fun(error: Applet.PaneError)
---@field generation integer
---@field _owner? Applet.Applet
---@field domain? Applet.InteractionDomain
---@field owned_domain? Applet.InteractionDomain
---@field destroyed boolean
---@field has_submission? boolean
---@field reconcile_state Applet.ReconcileState
---@field compile_cache Applet.PaneCompileCache
---@field image_region_cache table<string, Applet.PaneImageRegion>
---@field ambient_tree_cache? Applet.AmbientTreeCache
---@field pending_scene? Applet.CompiledScene
---@field current_scene? Applet.CompiledScene
---@field position_overrides table<string, Applet.ScenePosition>
---@field owned_buffers table<integer, true>
---@field requested_image_references? table<string, true>
---@field image_errors? table<string, true>
---@field deferred_images? boolean
---@field unsubscribe_images? fun()
---@field counters Applet.PaneCounters
---@field frame_interval_ns? number
---@field last_flush_ns? number
---@field frame_timer? uv.uv_timer_t
---@field resize_timer? uv.uv_timer_t
---@field last_width? integer
---@field last_height? integer
---@field last_window? integer
---@field last_focused? boolean
---@field last_image_geometry? string
---@field force_images? boolean
---@field force_chrome? boolean
---@field initial_target_applied boolean
---@field applied_target_intent? string|number
---@field view_policy_revision integer
---@field interaction_revision integer
---@field focus_signature? string
---@field mask_signature? string
---@field surface_option_states? table<string, Applet.WrittenOption>
---@field requested_surface_options? Applet.Options
---@field augroup? integer
---@field known_changedtick? integer
---@field observed_edit_changedtick? integer
---@field attached? boolean
---@field committing? boolean
---@field edit_revision? string|number
---@field namespace integer
---@field virtual_namespace integer
---@field image_namespace integer
---@field scene_namespace integer
---@field focus_namespace integer
---@field region_namespace integer
---@field cursor_namespace integer
---@field mask_namespace integer
local Pane = {}
Pane.__index = Pane

---@generic S
---@param self Applet.Pane<S>
---@return Applet.HostRecord?, Applet.Applet?
local function owner_record(self)
  local owner = self._owner
  local record = owner and owner.records and owner.records[self._key] or nil
  if record and record.descriptor and record.descriptor.pane == self then
    return record, owner
  end
end

---@overload fun(cursor: Applet.Cursor|[integer, integer]): Applet.Cursor
---@param cursor? Applet.Cursor|[integer, integer]
---@return Applet.Cursor?
local function semantic_cursor(cursor)
  if cursor == nil then
    return nil
  end
  applet_expect(type(cursor) == "table", "Pane cursor", "must be a table", 4)
  local line = cursor.line or cursor[1]
  local column = cursor.column
  if column == nil then
    column = cursor[2]
  end
  applet_expect(
    type(line) == "number" and type(column) == "number",
    "Pane cursor",
    "must contain numeric line and column fields",
    4
  )
  return { line = line, column = column }
end

---@overload fun(cursor: Applet.Cursor|[integer, integer]): [integer, integer]
---@param cursor? Applet.Cursor|[integer, integer]
---@return [integer, integer]?
local function native_cursor(cursor)
  cursor = semantic_cursor(cursor)
  return cursor and { cursor.line, cursor.column } or nil
end

local built_in_actions = {
  ["applet.target.move"] = true,
  ["applet.target.activate"] = true,
  ["applet.target.reveal"] = true,
}

local sequence = 0
local RESIZE_DEBOUNCE_MS = 40
local NANOSECONDS_PER_MILLISECOND = 1000000

---@param surface? Applet.SceneSurface
---@return integer?
local function valid_window(surface)
  if not surface then
    return nil
  end
  local window = surface.window and surface.window()
  if window and vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_buf(window) == surface.buffer then
    return window
  end
end

---@generic S
---@param self Applet.Pane<S>
local function stop_frame_timer(self)
  local timer = self.frame_timer
  if not timer then
    return
  end
  self.frame_timer = nil
  timer:stop()
  if not timer:is_closing() then
    timer:close()
  end
end

---@generic S
---@param self Applet.Pane<S>
---@return Applet.FocusRecord, Applet.Applet?
local function runtime_record(self)
  local record, owner = owner_record(self)
  if record then
    return record, owner
  end
  local surface = self.surface
  if surface and Base.loaded_buffer(surface.buffer) then
    local direct = surface.runtime_record
    direct.buffer = surface.buffer
    direct.window = valid_window(surface)
    return direct
  end
  error("Pane is unavailable", 3)
end

---@param surface? Applet.PaneSurface<Applet.Pane>
---@return boolean
local function surface_visible(surface)
  if not surface then
    return false
  end
  if surface.visible then
    local ok, visible = pcall(surface.visible)
    return ok and visible == true
  end
  return valid_window(surface) ~= nil
end

---@generic S
---@param pane Applet.Pane<S>
---@param surface Applet.PaneSurface<Applet.Pane<S>>
---@return Applet.ConnectedPaneSurface<Applet.Pane<S>>
local function connected_surface(pane, surface)
  return {
    buffer = surface.buffer,
    window = surface.window or function()
      return nil
    end,
    owns_buffer = surface.owns_buffer == true,
    domain = surface.domain,
    visible = surface.visible,
    chrome = surface.chrome,
    on_commit = surface.on_commit,
    interaction = surface.interaction,
    buffer_options = util.copy(surface.buffer_options or {}),
    window_options = util.copy(surface.window_options or {}),
    runtime_record = {
      buffer = surface.buffer,
      descriptor = {
        pane = pane,
        buffer_mode = pane.buffer_mode,
        focus = { mode = "normal" },
      },
    },
  }
end

---@param differences Applet.LayoutChanges
function Pane:_publish_commit(differences)
  self.force_chrome = false
  self:_refresh_mask()
  local callback = self.surface and self.surface.on_commit
  if not callback then
    return
  end
  local ok, err = pcall(callback, {
    generation = self.committed_generation,
    content = differences.content,
    chrome = differences.chrome,
    view = differences.view,
  })
  if not ok then
    self:_report("surface", err, self.committed_generation)
  end
end

---@generic S
---@param pane Applet.Pane<S>
---@return integer, integer?, boolean, integer?
local function dimensions(pane)
  local window = valid_window(pane.surface)
  if window then
    return math.max(1, vim.api.nvim_win_get_width(window)),
      math.max(1, vim.api.nvim_win_get_height(window)),
      surface_visible(pane.surface) and vim.api.nvim_get_current_win() == window,
      window
  end
  return math.max(1, vim.o.columns), nil, false, nil
end

---@generic S
---@param pane Applet.Pane<S>
---@param tree Applet.Tree|Applet.Node
---@return Applet.Tree|Applet.Node
local function ambient_tree(pane, tree)
  local interaction = pane.surface and pane.surface.interaction
  local scopes = interaction and interaction.scopes or nil
  if not scopes or #scopes == 0 then
    return tree
  end
  local root = tree.type and tree or tree.root
  local revision = assert(interaction).revision or 0
  local cached = pane.ambient_tree_cache
  local wrapped
  if cached and cached.root == root and cached.revision == revision and cached.scopes == scopes then
    wrapped = cached.wrapped
  else
    wrapped = root
    for index = #scopes, 1, -1 do
      local scope = scopes[index]
      wrapped = {
        type = "scope",
        key = ("@applet:%d:%d:%s"):format(pane.id, index, tostring(scope.key or index)),
        modal = scope.modal == true,
        bindings = scope.bindings or {},
        child = wrapped,
      }
    end
    pane.ambient_tree_cache = {
      root = root,
      revision = revision,
      scopes = scopes,
      wrapped = wrapped,
    }
  end
  if tree.type then
    return wrapped
  end
  local value = util.copy(tree)
  value.root = wrapped
  return value
end

---@param node unknown
---@param callback fun(source: Applet.ImageSource)
---@param seen table<table, boolean>
local function walk_images(node, callback, seen)
  if type(node) ~= "table" or seen[node] then
    return
  end
  seen[node] = true
  if node.type == "image" then
    callback(node.source)
  end
  for key, value in pairs(node) do
    if key ~= "source" or node.type ~= "image" then
      if type(value) == "table" then
        if value.type then
          walk_images(value, callback, seen)
        else
          for _, child in ipairs(value) do
            if type(child) == "table" then
              walk_images(child.node or child, callback, seen)
            end
          end
        end
      end
    end
  end
  seen[node] = nil
end

---@param root Applet.Node
---@return Applet.RegionNode[]?
local function region_document(root)
  while type(root) == "table" and root.type == "scope" do
    root = root.child
  end
  if type(root) ~= "table" then
    return nil
  end
  if root.type == "region" and root.revision ~= nil then
    return { root }
  end
  if root.type ~= "column" then
    return nil
  end
  local regions = root.children or {}
  if #regions == 0 then
    return nil
  end
  for _, region in ipairs(regions) do
    if type(region) ~= "table" or region.type ~= "region" or region.revision == nil then
      return nil
    end
  end
  return regions --[[@as Applet.RegionNode[] ]]
end

---@generic S
---@param pane Applet.Pane<S>
---@return Applet.ImageState
local function image_snapshot(pane)
  if pane.image_system then
    return util.copy(pane.image_system:snapshot(pane))
  end
  return {
    status = "unavailable",
    generation = 0,
    cell_width = 1,
    cell_height = 1,
    resources = {},
    presented = {},
  }
end

---@param value? Applet.Theme|Applet.ThemeOptions
---@return Applet.Theme
local function normalize_theme(value)
  if value == nil then
    return Theme.new()
  end
  if type(value) == "table" and type(value.group) == "function" and type(value.define) == "function" then
    return value --[[@as Applet.Theme]]
  end
  return Theme.new(value --[[@as Applet.ThemeOptions]])
end

---@param layout Applet.PaneLayout
---@param overrides table<string, Applet.ScenePosition>
---@return Applet.PaneLayout
local function apply_position_overrides(layout, overrides)
  if not layout.scene then
    return layout
  end
  local current = layout.scene
  for key, position in pairs(overrides) do
    if current.positions[key] then
      current = Scene.reposition(current, key, position)
    end
  end
  if current == layout.scene then
    return layout
  end
  return compile.project_scene({ layout = layout, scene = current })
end

---@generic S
---@param opts Applet.PaneOptions<S>
---@return Applet.Pane<S>
function Pane.new(opts)
  opts = opts or {}
  applet_expect(type(opts) == "table", "Pane", "options must be a table", 3)
  applet_expect(util.nonempty_string(opts.key), "Pane.key", "must be a non-empty string", 3)
  local extent = opts.extent or "document"
  applet_expect(extent == "document" or extent == "viewport", "Pane.extent", "must be document or viewport", 3)
  local buffer_mode = opts.buffer_mode or "managed"
  applet_expect(
    buffer_mode == "managed" or buffer_mode == "editable",
    "Pane.buffer_mode",
    "must be managed or editable",
    3
  )
  applet_expect(opts.render == nil or type(opts.render) == "function", "Pane.render", "must be a function", 3)
  applet_expect(opts.handlers == nil or type(opts.handlers) == "table", "Pane.handlers", "must be a table", 3)
  applet_expect(
    opts.frame_interval_ms == nil
      or (
        type(opts.frame_interval_ms) == "number"
        and opts.frame_interval_ms == opts.frame_interval_ms
        and opts.frame_interval_ms > 0
        and opts.frame_interval_ms < math.huge
        and opts.frame_interval_ms % 1 == 0
      ),
    "Pane.frame_interval_ms",
    "must be a positive integer",
    3
  )
  local handlers = {}
  for name, handler in pairs(opts.handlers or {}) do
    applet_expect(
      util.nonempty_string(name) and not name:match("^applet%."),
      "Pane.handlers",
      "names must be non-empty and outside the applet namespace",
      3
    )
    applet_expect(type(handler) == "function", "Pane.handlers." .. name, "must be a function", 3)
    handlers[name] = handler
  end
  if opts.on_error ~= nil then
    applet_expect(type(opts.on_error) == "function", "Pane.on_error", "must be a function", 3)
  end
  applet_expect(
    opts.read_image_resource == nil or type(opts.read_image_resource) == "function",
    "Pane.read_image_resource",
    "must be a function",
    3
  )
  if opts.image_system ~= nil then
    applet_expect(type(opts.image_system) == "table", "Pane.image_system", "must be a table", 3)
    for _, method in ipairs({
      "subscribe",
      "snapshot",
      "request",
      "set_references",
      "present",
      "clear",
    }) do
      applet_expect(
        type(opts.image_system[method]) == "function",
        "Pane.image_system." .. method,
        "must be a function",
        3
      )
    end
  end
  sequence = sequence + 1
  local key = opts.key
  local frame_interval_ns
  if opts.frame_interval_ms then
    frame_interval_ns = opts.frame_interval_ms * NANOSECONDS_PER_MILLISECOND
  end
  ---@type Applet.Pane<S>
  local self = setmetatable({
    _key = key,
    id = sequence,
    extent = extent,
    buffer_mode = buffer_mode,
    render = opts.render,
    handlers = handlers,
    theme = normalize_theme(opts.theme),
    image_system = opts.image_system,
    read_image_resource = opts.read_image_resource,
    on_error = opts.on_error,
    frame_interval_ns = frame_interval_ns,
    namespace = vim.api.nvim_create_namespace("applet-pane-" .. key .. "-" .. sequence),
    virtual_namespace = vim.api.nvim_create_namespace("applet-pane-virtual-" .. key .. "-" .. sequence),
    image_namespace = vim.api.nvim_create_namespace("applet-pane-image-" .. key .. "-" .. sequence),
    scene_namespace = vim.api.nvim_create_namespace("applet-pane-scene-" .. key .. "-" .. sequence),
    focus_namespace = vim.api.nvim_create_namespace("applet-pane-focus-" .. key .. "-" .. sequence),
    region_namespace = vim.api.nvim_create_namespace("applet-pane-region-" .. key .. "-" .. sequence),
    cursor_namespace = vim.api.nvim_create_namespace("applet-pane-cursor-" .. key .. "-" .. sequence),
    mask_namespace = vim.api.nvim_create_namespace("applet-pane-mask-" .. key .. "-" .. sequence),
    generation = 0,
    committed_generation = 0,
    pending_state = nil,
    pending_tree = nil,
    direct_tree = false,
    destroyed = false,
    reconcile_state = {},
    applied_target_intent = nil,
    view_policy_revision = 0,
    owned_buffers = {},
    initial_target_applied = false,
    interaction_revision = 0,
    position_overrides = {},
    compile_cache = {},
    image_region_cache = {},
    counters = {
      requested_generations = 0,
      renders = 0,
      commits = 0,
      region_compilations = 0,
      region_reuses = 0,
      document_reuses = 0,
      layer_compilations = 0,
      layer_reuses = 0,
      composed_cells = 0,
      line_splices = 0,
      full_rebuilds = 0,
      extmark_writes = 0,
      mapping_changes = 0,
      image_presentation_changes = 0,
      position_updates = 0,
    },
  }, Pane)
  self.theme_generation = self.theme.generation or 0
  self.compile_theme = {
    generation = self.theme_generation,
    ---@param style string
    group = function(_, style)
      return self.theme:group(style)
    end,
  }
  if self.image_system then
    self.unsubscribe_images = self.image_system:subscribe(function()
      if self.surface and not self.destroyed then
        self.force_images = true
        self:_request_flush()
      end
    end)
  end
  return self
end

---@param value unknown
---@return TypeGuard<Applet.Pane>
function Pane.is(value)
  return getmetatable(value) == Pane
end

---@return string
function Pane:key()
  return self._key
end

---@return boolean
function Pane:is_destroyed()
  return self.destroyed == true
end

---@return boolean
function Pane:is_editable()
  return self.buffer_mode == "editable"
end

---@return boolean
function Pane:is_connected()
  return self.surface ~= nil and Base.loaded_buffer(self.surface.buffer) == true
end

---@return boolean
function Pane:is_settled()
  return self.committed_generation == self.generation
end

---@param owner Applet.Applet
function Pane:_bind(owner)
  assert(self._owner == nil or self._owner == owner, "Pane is already mounted by another Applet")
  self._owner = owner
end

---@param owner Applet.Applet
function Pane:_unbind(owner)
  if self._owner == owner then
    self._owner = nil
  end
end

---@return boolean
function Pane:is_mounted()
  local record = owner_record(self)
  if record then
    return Base.valid_window(record.window)
      and Base.valid_buffer(record.buffer)
      and vim.api.nvim_win_get_buf(record.window) == record.buffer
  end
  return valid_window(self.surface) ~= nil
end

---@return boolean
function Pane:is_visible()
  local record, owner = owner_record(self)
  if record then
    local driver = assert(owner).driver
    return driver ~= nil and driver:pane_visible(record)
  end
  return surface_visible(self.surface)
end

---@return boolean
function Pane:is_focused()
  local record, owner = owner_record(self)
  if record then
    return assert(owner):focused_pane() == self._key and self:is_visible()
  end
  local window = valid_window(self.surface)
  return window ~= nil and vim.api.nvim_get_current_win() == window
end

---@return Applet.PaneGeometry
function Pane:geometry()
  local record, owner = runtime_record(self)
  local actual = Base.window_geometry(record.window)
  assert(actual, "Pane is unavailable")
  if not owner then
    local config = vim.api.nvim_win_get_config((assert(record.window)))
    return {
      host = "direct",
      row = actual.row,
      col = actual.col,
      content_width = actual.width,
      content_height = actual.height,
      outer_width = actual.width,
      outer_height = actual.height,
      screen_row = actual.row,
      screen_col = actual.col,
      screen_width = actual.width,
      screen_height = actual.height,
      zindex = config.relative ~= "" and config.zindex or nil,
    }
  end
  local descriptor = assert(owner.records[self._key]).descriptor
  local projection = descriptor.projection
  return {
    host = assert(owner.driver).kind,
    row = descriptor.outer.row,
    col = descriptor.outer.col,
    content_width = descriptor.content.width,
    content_height = descriptor.content.height,
    outer_width = descriptor.outer.width,
    outer_height = descriptor.outer.height,
    screen_row = actual and actual.row or nil,
    screen_col = actual and actual.col or nil,
    screen_width = actual and actual.width or nil,
    screen_height = actual and actual.height or nil,
    zindex = projection.kind == "floating" and (projection --[[@as Applet.FloatingProjection]]).config.zindex or nil,
  }
end

---@return boolean
function Pane:focus()
  local _, owner = owner_record(self)
  if owner then
    return owner:focus(self._key)
  end
  local window = valid_window(self.surface)
  if not window then
    return false
  end
  vim.api.nvim_set_current_win(window)
  return true
end

---@return Applet.Mode|"preserve"
function Pane:mode()
  local record = owner_record(self)
  if record then
    if self:is_focused() then
      if Mode.semantic() == "insert" then
        return "insert"
      end
      return record.mode or "normal"
    end
    return record.mode or record.descriptor.focus.mode
  end
  if self:is_focused() and Mode.semantic() == "insert" then
    return "insert"
  end
  return "normal"
end

---@param phase string
---@param value unknown
---@param generation? integer
---@return nil, Applet.PaneError
function Pane:_report(phase, value, generation)
  local source = type(value) == "table" and type(value.message) == "string" and value.message or tostring(value)
  local err = {
    pane = self._key,
    phase = phase,
    generation = generation or self.generation,
    message = source:gsub("\nstack traceback:.*", ""),
  }
  if self.on_error then
    local ok = pcall(self.on_error, err)
    if ok then
      return nil, err
    end
  end
  return nil, err
end

function Pane:_request_resize()
  if self.destroyed or not self.surface then
    return
  end
  if not self.resize_timer then
    self.resize_timer = assert(vim.uv.new_timer())
  end
  self.resize_timer:stop()
  self.resize_timer:start(
    RESIZE_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if self.destroyed or not self.surface then
        return
      end
      local width, height, focused = dimensions(self)
      if width ~= self.last_width or height ~= self.last_height or focused ~= self.last_focused then
        self:_request_flush()
      end
    end)
  )
end

---@return boolean
function Pane:_surface_options()
  assert(self.surface)
  local buffer = self.surface.buffer
  local desired = util.copy(self.surface.buffer_options or {})
  for option, value in pairs({
    swapfile = false,
    modifiable = self.buffer_mode == "editable",
    readonly = self.buffer_mode == "managed",
  }) do
    desired[option] = value
  end
  self.surface_option_states = self.surface_option_states or {}
  if util.equal(self.requested_surface_options, desired) then
    return false
  end
  for option, state in pairs(util.copy(self.surface_option_states)) do
    if desired[option] == nil then
      local current = vim.api.nvim_get_option_value(option, { buf = buffer })
      if util.equal(current, state.written) then
        pcall(vim.api.nvim_set_option_value, option, state.original, { buf = buffer })
      end
      self.surface_option_states[option] = nil
    end
  end
  for option, value in pairs(desired) do
    local state = self.surface_option_states[option]
    if not state then
      state = {
        original = vim.api.nvim_get_option_value(option, { buf = buffer }),
      }
      self.surface_option_states[option] = state
    end
    if not util.equal(vim.api.nvim_get_option_value(option, { buf = buffer }), value) then
      vim.api.nvim_set_option_value(option, value, { buf = buffer })
    end
    state.written = util.copy_value(value)
  end
  self.requested_surface_options = util.copy(desired)
  return true
end

function Pane:_install_autocmds()
  assert(self.surface)
  local pane = self
  self.augroup = vim.api.nvim_create_augroup("AppletPane" .. self.id .. self._key, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.augroup,
    buffer = self.surface.buffer,
    callback = function()
      if pane.surface then
        pane:_disconnect(true)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = self.augroup,
    callback = function()
      if not pane.surface then
        return
      end
      local width, height, focused = dimensions(pane)
      if width ~= pane.last_width or height ~= pane.last_height or focused ~= pane.last_focused then
        pane:_request_resize()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "WinLeave" }, {
    group = self.augroup,
    buffer = self.surface.buffer,
    callback = function()
      if pane.buffer_mode == "managed" then
        Mode.apply("normal")
      end
      pane:_draw_focus()
      pane:_request_flush()
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = self.augroup,
    callback = function()
      if not pane.surface or not pane.image_system then
        return
      end
      pane.force_images = true
      pane:_request_flush()
    end,
  })
  vim.api.nvim_create_autocmd({
    "WinNew",
    "WinClosed",
    "TabEnter",
    "CompleteChanged",
    "CompleteDone",
    "VimResume",
  }, {
    group = self.augroup,
    callback = function()
      if pane.surface and pane.image_system then
        pane.force_images = true
        pane:_request_flush()
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.augroup,
    callback = function()
      if not pane.surface then
        return
      end
      pane.theme_generation = pane.theme_generation + 1
      pane.compile_theme.generation = pane.theme_generation
      pane.theme:define()
      pane:_request_flush()
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "ModeChanged" }, {
    group = self.augroup,
    buffer = self.surface.buffer,
    callback = function()
      pane:_draw_focus()
    end,
  })
  if self.buffer_mode == "managed" then
    vim.api.nvim_create_autocmd("InsertEnter", {
      group = self.augroup,
      buffer = self.surface.buffer,
      callback = function()
        if pane.surface then
          Mode.apply("normal")
        end
      end,
    })
  else
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = self.augroup,
      buffer = self.surface.buffer,
      callback = function()
        pane:_text_changed()
      end,
    })
  end
end

function Pane:_attach_buffer()
  assert(self.surface)
  local pane = self
  self.known_changedtick = vim.api.nvim_buf_get_changedtick(self.surface.buffer)
  self.observed_edit_changedtick = self.known_changedtick
  self.attached = vim.api.nvim_buf_attach(self.surface.buffer, false, {
    on_lines = function(_, _, changedtick)
      if not pane.surface or pane.buffer_mode ~= "managed" then
        return
      end
      if pane.committing or changedtick == pane.known_changedtick then
        return
      end
      pane.reconcile_state.unknown = true
      pane:_request_flush()
    end,
    on_detach = function(_, buffer)
      if not pane.surface or pane.surface.buffer ~= buffer then
        return
      end
      pane.attached = nil
      vim.schedule(function()
        if pane.surface and pane.surface.buffer == buffer then
          pane:_disconnect(true)
        end
      end)
    end,
  })
end

---@param surface Applet.PaneSurface<Applet.Pane<S>>
---@return self
function Pane:_connect(surface)
  assert(not self.destroyed, "Pane is destroyed")
  applet_expect(type(surface) == "table", "surface", "must be a table", 3)
  applet_expect(
    type(surface.buffer) == "number"
      and vim.api.nvim_buf_is_valid(surface.buffer)
      and vim.api.nvim_buf_is_loaded(surface.buffer),
    "surface.buffer",
    "must be a valid loaded buffer",
    3
  )
  applet_expect(surface.window == nil or type(surface.window) == "function", "surface.window", "must be a function", 3)
  applet_expect(
    surface.visible == nil or type(surface.visible) == "function",
    "surface.visible",
    "must be a function",
    3
  )
  applet_expect(
    surface.buffer_options == nil or type(surface.buffer_options) == "table",
    "surface.buffer_options",
    "must be a table",
    3
  )
  applet_expect(
    surface.window_options == nil or type(surface.window_options) == "table",
    "surface.window_options",
    "must be a table",
    3
  )
  applet_expect(
    surface.owns_buffer == nil or type(surface.owns_buffer) == "boolean",
    "surface.owns_buffer",
    "must be a boolean",
    3
  )
  if surface.chrome ~= nil then
    applet_expect(type(surface.chrome) == "table", "surface.chrome", "must be a table", 3)
    for _, method in ipairs({ "apply", "measure", "restore" }) do
      applet_expect(type(surface.chrome[method]) == "function", "surface.chrome." .. method, "must be a function", 3)
    end
  end
  if surface.interaction ~= nil then
    applet_expect(type(surface.interaction) == "table", "surface.interaction", "must be a table", 3)
    applet_expect(type(surface.interaction.scopes) == "table", "surface.interaction.scopes", "must be a table", 3)
    applet_expect(
      type(surface.interaction.has_action) == "function",
      "surface.interaction.has_action",
      "must be a function",
      3
    )
    applet_expect(
      type(surface.interaction.dispatch) == "function",
      "surface.interaction.dispatch",
      "must be a function",
      3
    )
  end
  if surface.domain ~= nil then
    applet_expect(type(surface.domain) == "table", "surface.domain", "must be a table", 3)
    for _, method in ipairs({ "add", "remove", "activate", "deactivate", "request" }) do
      applet_expect(type(surface.domain[method]) == "function", "surface.domain." .. method, "must be a function", 3)
    end
  end
  if self.surface and self.surface.buffer == surface.buffer then
    local previous_window = valid_window(self.surface)
    local previous_options = self.surface.window_options
    self.surface.window = surface.window or self.surface.window
    self.surface.visible = surface.visible or self.surface.visible
    self.surface.chrome = surface.chrome or self.surface.chrome
    self.surface.interaction = surface.interaction or self.surface.interaction
    self.surface.on_commit = surface.on_commit or self.surface.on_commit
    self.surface.buffer_options = util.copy(surface.buffer_options or {})
    self.surface.window_options = util.copy(surface.window_options or {})
    self:_surface_options()
    local current_window = valid_window(self.surface)
    if previous_window ~= current_window or not util.equal(previous_options, self.surface.window_options) then
      self.last_window = nil
      self:_request_flush()
    end
    return self
  end
  if self.surface then
    self:_disconnect()
  end
  self.surface = connected_surface(self, surface)
  if self.image_system and type(self.image_system.redraw) == "function" then
    reconcile.set_image_redraw_handler({
      surface = self.surface,
      state = self.reconcile_state,
      image_namespace = self.image_namespace,
      callback = function()
        if self.destroyed or not self.surface then
          return false
        end
        return assert(self.image_system):redraw(self)
      end,
    })
  end
  if self.surface.owns_buffer then
    self.owned_buffers[self.surface.buffer] = true
  end
  self:_surface_options()
  self.theme:define()
  self.domain = self.surface.domain
  if not self.domain then
    self.owned_domain = self.owned_domain or Domain.new()
    self.domain = self.owned_domain
  end
  assert(self.domain):add(self)
  assert(self.domain):activate(self)
  self:_install_autocmds()
  self:_attach_buffer()
  if self.has_submission then
    self:_request_submission()
  end
  return self
end

---@param state S
---@param opts? {eager?: boolean}
---@return integer
function Pane:set_state(state, opts)
  assert(not self.destroyed, "Pane is destroyed")
  opts = opts or {}
  applet_expect(type(opts) == "table", "Pane.set_state", "options must be a table", 3)
  for key in pairs(opts) do
    applet_expect(key == "eager", "Pane.set_state." .. tostring(key), "is not recognized", 3)
  end
  applet_expect(opts.eager == nil or type(opts.eager) == "boolean", "Pane.set_state.eager", "must be a boolean", 3)
  self.generation = self.generation + 1
  self.counters.requested_generations = self.counters.requested_generations + 1
  self.pending_state = state
  self.pending_scene = nil
  self.position_overrides = {}
  self.has_submission = true
  self.direct_tree = false
  if opts.eager then
    self:_request_flush()
  else
    self:_request_submission()
  end
  return self.generation
end

---@param interaction Applet.PaneInteraction<Applet.Pane<S>>
---@return boolean
function Pane:set_surface_interaction(interaction)
  assert(not self.destroyed, "Pane is destroyed")
  assert(self.surface, "Pane is not connected")
  applet_expect(type(interaction) == "table", "surface.interaction", "must be a table", 3)
  applet_expect(type(interaction.scopes) == "table", "surface.interaction.scopes", "must be a table", 3)
  applet_expect(type(interaction.has_action) == "function", "surface.interaction.has_action", "must be a function", 3)
  applet_expect(type(interaction.dispatch) == "function", "surface.interaction.dispatch", "must be a function", 3)
  if self.surface.interaction == interaction and self.surface.interaction.revision == interaction.revision then
    return false
  end
  self.surface.interaction = interaction
  self.ambient_tree_cache = nil
  self.interaction_revision = self.interaction_revision + 1
  if self.has_submission then
    self:_request_flush()
  end
  return true
end

---@param theme? Applet.Theme|Applet.ThemeOptions
---@return Applet.Theme
function Pane:set_theme(theme)
  assert(not self.destroyed, "Pane is destroyed")
  self.theme = normalize_theme(theme)
  self.theme_generation = self.theme_generation + 1
  self.compile_theme.generation = self.theme_generation
  self.compile_cache = {}
  self.pending_scene = nil
  self.focus_signature = nil
  if self.surface then
    self.theme:define()
  end
  if self.has_submission then
    self:_request_flush()
  end
  return self.theme
end

---@param tree Applet.Tree|Applet.Node
---@return integer
function Pane:update(tree)
  assert(not self.destroyed, "Pane is destroyed")
  self.generation = self.generation + 1
  self.counters.requested_generations = self.counters.requested_generations + 1
  self.pending_tree = tree
  self.pending_scene = nil
  self.position_overrides = {}
  self.has_submission = true
  self.direct_tree = true
  self:_request_submission()
  return self.generation
end

---@param key string
---@param position Applet.ScenePosition
---@return boolean
function Pane:set_position(key, position)
  assert(not self.destroyed, "Pane is destroyed")
  applet_expect(util.nonempty_string(key), "Pane.set_position.key", "must be a non-empty string", 3)
  applet_expect(type(position) == "table", "Pane.set_position.position", "must be a table", 3)
  local current = self.pending_scene or self.current_scene
  applet_expect(current ~= nil, "Pane.set_position", "requires a committed retained container", 3)
  self.pending_scene = Scene.reposition(current, key, position)
  local override = util.copy(self.position_overrides[key] or {})
  for _, field in ipairs({ "row", "col", "zindex" }) do
    if position[field] ~= nil then
      override[field] = position[field]
    end
  end
  self.position_overrides[key] = override
  self:_request_flush()
  return true
end

function Pane:_request_flush()
  if not self.surface or not self.domain then
    return
  end
  stop_frame_timer(self)
  self.domain:request(self)
end

function Pane:_request_submission()
  if not self.surface or not self.domain then
    return
  end
  local interval = self.frame_interval_ns
  local last = self.last_flush_ns
  if not interval or not last then
    self:_request_flush()
    return
  end
  local remaining = interval - (vim.uv.hrtime() - last)
  if remaining <= 0 then
    self:_request_flush()
    return
  end
  if self.frame_timer then
    return
  end
  local timer = assert(vim.uv.new_timer())
  self.frame_timer = timer
  timer:start(
    math.max(1, math.ceil(remaining / NANOSECONDS_PER_MILLISECOND)),
    0,
    vim.schedule_wrap(function()
      if self.frame_timer ~= timer then
        return
      end
      stop_frame_timer(self)
      if not self.destroyed and self.surface and self.domain then
        self.domain:request(self)
      end
    end)
  )
end

---@param opts? Applet.SurfaceChange
---@return boolean
function Pane:surface_changed(opts)
  if self.destroyed or not self.surface then
    return false
  end
  opts = opts or {}
  applet_expect(type(opts) == "table", "Pane.surface_changed", "options must be a table", 3)
  for key in pairs(opts) do
    applet_expect(key == "chrome", "Pane.surface_changed." .. tostring(key), "is not recognized", 3)
  end
  applet_expect(
    opts.chrome == nil or type(opts.chrome) == "boolean",
    "Pane.surface_changed.chrome",
    "must be a boolean",
    3
  )
  if opts.chrome then
    self.force_chrome = true
  end
  self.force_images = true
  if self.has_submission then
    self:_request_flush()
  end
  return true
end

---@param width integer
---@param height integer?
---@param focused boolean
---@param generation integer
---@return Applet.Tree|Applet.Node
function Pane:_render_tree(width, height, focused, generation)
  if self.direct_tree then
    return ambient_tree(self, assert(self.pending_tree))
  end
  if not self.render then
    error("Pane has no render function", 0)
  end
  local images = image_snapshot(self)
  local tree = self.render(self.pending_state, {
    extent = self.extent,
    width = width,
    height = height,
    focused = focused,
    theme_generation = self.theme_generation,
    layout_generation = generation,
    images = { status = images.status, generation = images.generation },
  })
  return ambient_tree(self, tree)
end

---@param layout Applet.PaneLayout
function Pane:_validate_actions(layout)
  ---@param action? Applet.Action
  ---@param path string
  local function validate(action, path)
    if not action then
      return
    end
    local interaction = self.surface and self.surface.interaction
    if
      not built_in_actions[action.action]
      and not self.handlers[action.action]
      and not (interaction and interaction.has_action(action.action))
    then
      error(("%s: unknown action %q"):format(path, action.action), 0)
    end
  end
  local document = layout.region_document
  local first = document and document.changed_first
  if document then
    if first then
      for index = first, #layout.regions do
        local region = layout.regions[index]
        for key, target in pairs(region.targets or {}) do
          validate(target.action, "target " .. key)
        end
        for key, scope in pairs(region.scopes or {}) do
          for binding_index, binding in ipairs(scope.bindings) do
            validate(binding.action, ("scope %s binding %d"):format(key, binding_index))
          end
        end
      end
      for key, scope in pairs(layout.scopes) do
        if scope.root then
          for index, binding in ipairs(scope.bindings) do
            validate(binding.action, ("scope %s binding %d"):format(key, index))
          end
        end
      end
    end
  else
    for key, target in pairs(layout.targets) do
      validate(target.action, "target " .. key)
    end
    for key, scope in pairs(layout.scopes) do
      for index, binding in ipairs(scope.bindings) do
        validate(binding.action, ("scope %s binding %d"):format(key, index))
      end
    end
  end
  if layout.edit then
    validate(layout.edit.on_change, "edit.on_change")
  end
end

---@param tree? Applet.Tree|Applet.Node
---@param images? Applet.ImageState
function Pane:_prepare_images(tree, images)
  if not self.image_system or not tree then
    return
  end
  images = images or image_snapshot(self)
  local root = tree.type and tree or tree.root
  local requested, sources = {}, {}
  local paintable = surface_visible(self.surface)
  local regions = region_document(root)
  if regions then
    local active = {}
    for _, region in ipairs(regions) do
      active[region.key] = true
      local cached = self.image_region_cache[region.key]
      if not cached or cached.revision ~= region.revision then
        cached = { revision = region.revision, sources = {} }
        walk_images(region.child, function(value)
          local identity_ok, identity = pcall(ImageSource.identity, value)
          if identity_ok then
            cached.sources[#cached.sources + 1] = {
              identity = identity,
              value = value,
            }
          end
        end, {})
        self.image_region_cache[region.key] = cached
      end
      for _, source in ipairs(cached.sources) do
        requested[source.identity] = true
        sources[#sources + 1] = source
      end
    end
    for key in pairs(self.image_region_cache) do
      if not active[key] then
        self.image_region_cache[key] = nil
      end
    end
  else
    self.image_region_cache = {}
    walk_images(root, function(value)
      local identity_ok, identity = pcall(ImageSource.identity, value)
      if identity_ok then
        requested[identity] = true
        sources[#sources + 1] = { identity = identity, value = value }
      end
    end, {})
  end
  self.requested_image_references = requested
  self.deferred_images = not paintable and #sources > 0
  self.image_system:set_references(self, requested)
  local resources = images.resources or {}
  if paintable then
    for _, source_value in ipairs(sources) do
      local identity, value = source_value.identity, source_value.value
      if not resources[identity] then
        local ok, resource, err = pcall(self.image_system.request, self.image_system, value, self.read_image_resource)
        if not ok then
          self:_report("image", resource, self.generation)
        elseif err then
          self.image_errors = self.image_errors or {}
          if not self.image_errors[identity] then
            self.image_errors[identity] = true
            self:_report("image", err, self.generation)
          end
        elseif resource ~= nil then
          resources[identity] = resource
        end
      end
    end
  end
  if self.image_errors then
    local active = {}
    for identity in pairs(requested) do
      if self.image_errors[identity] then
        active[identity] = true
      end
    end
    self.image_errors = next(active) and active or nil
  end
end

---@param keep_requested? boolean
function Pane:_sync_image_references(keep_requested)
  if not self.image_system then
    return
  end
  local references = {}
  if keep_requested ~= false then
    for identity in pairs(self.requested_image_references or {}) do
      references[identity] = true
    end
  else
    self.requested_image_references = nil
  end
  if self.image_errors then
    local active = {}
    for identity in pairs(references) do
      if self.image_errors[identity] then
        active[identity] = true
      end
    end
    self.image_errors = next(active) and active or nil
  end
  self.image_system:set_references(self, references)
end

---@return boolean?, Applet.PaneError?
function Pane:_flush_requested()
  if
    self.destroyed
    or not self.surface
    or not vim.api.nvim_buf_is_valid(self.surface.buffer)
    or not vim.api.nvim_buf_is_loaded(self.surface.buffer)
  then
    return false
  end
  stop_frame_timer(self)
  if self.frame_interval_ns then
    self.last_flush_ns = vim.uv.hrtime()
  end
  local generation = self.generation
  local width, height, focused, window = dimensions(self)
  local window_changed = self.last_window ~= window or self.force_chrome == true
  if self.image_system then
    local position = window and vim.fn.win_screenpos(window) or { 0, 0 }
    local image_geometry = table.concat({
      tostring(window or false),
      tostring(width),
      tostring(height),
      tostring(position[1]),
      tostring(position[2]),
    }, ":")
    if self.last_image_geometry ~= image_geometry then
      self.force_images = true
    end
    self.last_image_geometry = image_geometry
  end
  self.last_window = window
  self.last_width, self.last_height, self.last_focused = width, height, focused
  if self.pending_scene then
    if
      self.layout
      and width == self.layout.width
      and height == self.layout.height
      and (not self.image_system or self.layout.image_generation == self.image_system:snapshot(self).generation)
    then
      local current_scene = self.pending_scene
      self.pending_scene = nil
      local previous = self.layout
      local layout = current_scene.spatial
          and compile.project_scene({
            layout = previous,
            scene = current_scene,
          })
        or previous
      local differences
      if not current_scene.spatial then
        differences = {
          any = true,
          content = false,
          decorations = false,
          interaction = false,
          images = false,
          regions = false,
          sources = false,
          virtuals = false,
          scene = true,
          chrome = false,
          view = false,
        }
      else
        differences = reconcile.changes(previous, layout)
      end
      local applied, state = pcall(reconcile.retain, {
        surface = self.surface,
        layout = layout,
        state = self.reconcile_state,
        window_changed = window_changed,
        changes = differences,
        namespace = self.namespace,
        scene_namespace = self.scene_namespace,
        scene = current_scene,
      })
      if not applied then
        return self:_report("commit", state, generation)
      end
      self.reconcile_state = state
      local refresh_images = self.image_system and (self.force_images or differences.images or differences.content)
      if refresh_images then
        local image_changes, presented = reconcile.refresh_images({
          surface = self.surface,
          state = self.reconcile_state,
          image_system = self.image_system,
          image_owner = self,
          image_namespace = self.image_namespace,
        })
        self.counters.image_presentation_changes = self.counters.image_presentation_changes + image_changes
        layout = presented or layout
        differences = reconcile.changes(previous, layout)
      end
      self.force_images = false
      self.layout = layout
      self.current_scene = current_scene
      if differences.interaction then
        self.interaction_revision = self.interaction_revision + 1
      end
      self.counters.position_updates = self.counters.position_updates + 1
      self.counters.commits = self.counters.commits + 1
      if differences.view then
        self:_apply_target_policy()
      end
      if differences.interaction then
        self:_draw_focus()
      end
      self:_publish_commit(differences)
      return true
    end
  end
  self.pending_scene = nil
  self.counters.renders = self.counters.renders + 1
  local ok, tree = pcall(self._render_tree, self, width, height, focused, generation)
  if not ok then
    return self:_report("render", tree, generation)
  end
  if tree == nil then
    return self:_report("render", "render returned nil", generation)
  end
  local images = image_snapshot(self)
  local previous = self.layout
  local previous_root = self.tree and (self.tree.type and self.tree or self.tree.root)
  local root = tree.type and tree or tree.root
  local prepare_deferred_images = self.deferred_images == true and surface_visible(self.surface)
  local retained = previous ~= nil
    and previous_root == root
    and previous.width == width
    and previous.height == height
    and previous.extent == self.extent
    and previous.theme_generation == self.theme_generation
    and previous.image_generation == images.generation
    and previous.image_cell_width == images.cell_width
    and previous.image_cell_height == images.cell_height
    and not self.reconcile_state.unknown
    and not prepare_deferred_images
  if not retained then
    self:_prepare_images(tree, images)
    images = image_snapshot(self)
  end
  local compile_layout = retained and compile.reuse or compile.compile
  local compiled, layout = pcall(function()
    return apply_position_overrides(
      compile_layout({
        tree = tree,
        previous = previous,
        width = width,
        height = height,
        extent = self.extent,
        theme = self.compile_theme,
        images = images,
        cache = self.compile_cache,
        stats = self.counters,
        retain_scene = true,
      }),
      self.position_overrides
    )
  end)
  if not compiled then
    self:_sync_image_references(false)
    return self:_report("compile", layout, generation)
  end
  local differences = reconcile.changes(previous, layout)
  local actions_ok, actions_error = true, nil
  if not retained or differences.interaction then
    actions_ok, actions_error = pcall(self._validate_actions, self, layout)
  end
  if not actions_ok then
    self:_sync_image_references(false)
    return self:_report("compile", actions_error, generation)
  end
  if retained then
    local changed = differences.any
    if changed or window_changed then
      local applied, state = pcall(reconcile.retain, {
        surface = self.surface,
        layout = layout,
        state = self.reconcile_state,
        window_changed = window_changed,
        changes = differences,
        namespace = self.namespace,
        scene_namespace = self.scene_namespace,
      })
      if not applied then
        return self:_report("commit", state, generation)
      end
      self.reconcile_state = state
    end
    if self.force_images then
      local image_changes, presented = reconcile.refresh_images({
        surface = self.surface,
        state = self.reconcile_state,
        image_system = self.image_system,
        image_owner = self,
        image_namespace = self.image_namespace,
      })
      self.counters.image_presentation_changes = self.counters.image_presentation_changes + image_changes
      layout = presented or layout
      differences = reconcile.changes(previous, layout)
      self.force_images = false
    end
    self.layout, self.tree, self.committed_generation = layout, tree, generation
    self.current_scene = layout.scene
    if changed then
      self.counters.commits = self.counters.commits + 1
    end
    self:_apply_target_policy()
    self:_draw_focus()
    self:_publish_commit(differences)
    return true
  end
  if previous and not self.reconcile_state.unknown and not differences.any then
    if window_changed then
      reconcile.refresh_chrome({
        surface = self.surface,
        state = self.reconcile_state,
      })
    end
    if self.force_images then
      local image_changes, presented = reconcile.refresh_images({
        surface = self.surface,
        state = self.reconcile_state,
        image_system = self.image_system,
        image_owner = self,
        image_namespace = self.image_namespace,
      })
      self.counters.image_presentation_changes = self.counters.image_presentation_changes + image_changes
      layout = presented or layout
      differences = reconcile.changes(previous, layout)
      self.force_images = false
    end
    self.layout, self.tree, self.committed_generation = layout, tree, generation
    self.current_scene = layout.scene
    self:_sync_image_references()
    self:_apply_target_policy()
    self:_draw_focus()
    self:_publish_commit(differences)
    return true
  end
  self.committing = true
  local applied, state, changes, presented = pcall(reconcile.apply, {
    surface = self.surface,
    layout = layout,
    state = self.reconcile_state,
    namespace = self.namespace,
    virtual_namespace = self.virtual_namespace,
    region_namespace = self.region_namespace,
    cursor_namespace = self.cursor_namespace,
    buffer_mode = self.buffer_mode,
    image_system = self.image_system,
    image_owner = self,
    image_namespace = self.image_namespace,
    force_images = self.force_images,
    window_changed = window_changed,
    changes = differences,
    scene_namespace = self.scene_namespace,
  })
  if self.surface and vim.api.nvim_buf_is_valid(self.surface.buffer) then
    self.known_changedtick = vim.api.nvim_buf_get_changedtick(self.surface.buffer)
  end
  self.committing = false
  self.force_images = false
  if not applied then
    self:_sync_image_references(false)
    return self:_report("commit", state, generation)
  end
  self.reconcile_state = state
  layout = presented or state.layout or layout
  differences = reconcile.changes(previous, layout)
  local mapped, mapping_changes = pcall(input.update_mappings, self, previous, layout)
  if not mapped then
    input.clear_mappings(self)
    self.reconcile_state.unknown = true
    self:_sync_image_references(false)
    return self:_report("commit", mapping_changes, generation)
  end
  self.counters.mapping_changes = self.counters.mapping_changes + mapping_changes
  for key, value in pairs(changes) do
    self.counters[key] = (self.counters[key] or 0) + value
  end
  self.layout = layout
  self.current_scene = layout.scene
  self.tree = tree
  if differences.interaction then
    self.interaction_revision = self.interaction_revision + 1
  end
  self:_sync_image_references()
  self.committed_generation = generation
  self.counters.commits = self.counters.commits + 1
  self:_apply_target_policy()
  self:_draw_focus()
  self:_publish_commit(differences)
  return true
end

---@return boolean?, Applet.PaneError?
function Pane:flush()
  if not self.surface then
    return false
  end
  stop_frame_timer(self)
  assert(self.domain).dirty[self] = nil
  return self:_flush_requested()
end

function Pane:_apply_target_policy()
  local view = assert(self.layout).view
  local applied = false
  if not self.initial_target_applied and view.initial_target then
    self.initial_target_applied = input.reveal(self, view.initial_target)
    applied = self.initial_target_applied
  end
  local intent = view.target_intent
  local key = intent and intent.key or nil
  if key ~= self.applied_target_intent then
    if not intent then
      self.applied_target_intent = nil
    elseif input.apply_target_intent(self, intent) then
      self.applied_target_intent = key
      applied = true
    end
  end
  if applied then
    self.view_policy_revision = self.view_policy_revision + 1
  end
end

---@return integer
function Pane:_view_policy_revision()
  return self.view_policy_revision
end

function Pane:_draw_focus()
  if not self.surface or not vim.api.nvim_buf_is_valid(self.surface.buffer) then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  local selecting = mode == "v" or mode == "V" or mode == "\22" or mode == "s" or mode == "S" or mode == "\19"
  local _, _, focused = dimensions(self)
  local active = not selecting and focused and input.focus_target(self) or nil
  ---@cast active Applet.CompiledTarget?
  local signature = table.concat({
    tostring(self.interaction_revision),
    selecting and "selecting" or "normal",
    active and active.key or "",
  }, "\0")
  if signature == self.focus_signature then
    return
  end
  self.focus_signature = signature
  vim.api.nvim_buf_clear_namespace(self.surface.buffer, self.focus_namespace, 0, -1)
  if selecting then
    return
  end
  for _, key in ipairs(self.layout and self.layout.target_order or {}) do
    local target = assert(self.layout).targets[key]
    local state = target == active and "active" or "inactive"
    for _, decoration in ipairs(target.focus and target.focus[state] or {}) do
      local text = vim.api.nvim_buf_get_lines(self.surface.buffer, decoration.row, decoration.row + 1, false)[1]
      if text then
        local width = vim.fn.strdisplaywidth(text)
        local options = {
          virt_text = decoration.chunks,
          priority = decoration.priority,
        }
        if decoration.win_col ~= nil then
          options.virt_text_win_col = decoration.win_col
        else
          options.virt_text_pos = decoration.position or "overlay"
        end
        vim.api.nvim_buf_set_extmark(
          self.surface.buffer,
          self.focus_namespace,
          decoration.row,
          util.byte_col(text, math.min(decoration.col, width)),
          options
        )
      end
    end
  end
  if not active or not active.focus_style then
    return
  end
  for _, rect in ipairs(active.rectangles) do
    for row = rect.row, rect.row + rect.height - 1 do
      ---@cast row integer
      local text = vim.api.nvim_buf_get_lines(self.surface.buffer, row, row + 1, false)[1]
      if text then
        local start_col = util.byte_col(text, math.min(rect.col, vim.fn.strdisplaywidth(text)))
        local end_display = math.min(rect.col + rect.width, vim.fn.strdisplaywidth(text))
        local end_col = util.byte_col(text, end_display)
        vim.api.nvim_buf_set_extmark(self.surface.buffer, self.focus_namespace, row, start_col, {
          end_row = row,
          end_col = math.max(start_col, end_col),
          hl_group = active.focus_style,
          priority = 200,
          hl_eol = rect.col + rect.width >= vim.fn.strdisplaywidth(text),
        })
      end
    end
  end
end

---@return integer
function Pane:_refresh_mask()
  local surface = self.surface
  if not surface or not vim.api.nvim_buf_is_valid(surface.buffer) or not vim.api.nvim_buf_is_loaded(surface.buffer) then
    return 0
  end
  local mask = self.layout and self.layout.edit and self.layout.edit.mask or nil
  local changedtick = vim.api.nvim_buf_get_changedtick(surface.buffer)
  local signature = tostring(mask) .. "\0" .. tostring(changedtick)
  if self.mask_signature == signature then
    return 0
  end
  self.mask_signature = signature
  vim.api.nvim_buf_clear_namespace(surface.buffer, self.mask_namespace, 0, -1)
  if not mask then
    return 0
  end
  local writes = 0
  for row, line in ipairs(vim.api.nvim_buf_get_lines(surface.buffer, 0, -1, false)) do
    local column = 0
    for _, character in ipairs(util.characters(line, "editable text")) do
      vim.api.nvim_buf_set_extmark(surface.buffer, self.mask_namespace, row - 1, column, {
        end_row = row - 1,
        end_col = column + #character,
        conceal = mask,
        priority = 250,
      })
      column = column + #character
      writes = writes + 1
    end
  end
  self.counters.extmark_writes = self.counters.extmark_writes + writes
  return writes
end

function Pane:_text_changed()
  assert(self.surface)
  local changedtick = vim.api.nvim_buf_get_changedtick(self.surface.buffer)
  if changedtick == self.observed_edit_changedtick then
    return
  end
  self.observed_edit_changedtick = changedtick
  self.counters.extmark_writes = self.counters.extmark_writes
    + reconcile.refresh_virtuals({
      surface = self.surface,
      state = self.reconcile_state,
      virtual_namespace = self.virtual_namespace,
    })
  self:_refresh_mask()
  local action = self.layout and self.layout.edit and self.layout.edit.on_change
  if not action then
    return
  end
  input.dispatch_action(self, action, nil, 1, vim.api.nvim_get_mode().mode, 0, 0)
end

---@param text string
---@param cursor? Applet.Cursor|[integer, integer]
---@param revision? string|number
---@return boolean
function Pane:replace_text(text, cursor, revision)
  assert(self.buffer_mode == "editable", "replace_text is available only for editable Panes")
  local record = owner_record(self)
  if not self.surface then
    assert(record, "Pane is not connected")
    applet_expect(type(text) == "string", "Pane text", "must be a string", 3)
    if revision ~= nil and revision == self.edit_revision then
      return false
    end
    self.edit_revision = revision
    record.edit_revision = revision
    return Base.replace_text(record, text, semantic_cursor(cursor))
  end
  assert(vim.api.nvim_buf_is_valid(self.surface.buffer), "Pane is not connected")
  applet_expect(type(text) == "string", "Pane text", "must be a string", 3)
  if revision ~= nil and revision == self.edit_revision then
    return false
  end
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(self.surface.buffer, 0, -1, false, lines)
  self.observed_edit_changedtick = vim.api.nvim_buf_get_changedtick(self.surface.buffer)
  self.counters.extmark_writes = self.counters.extmark_writes
    + reconcile.refresh_virtuals({
      surface = self.surface,
      state = self.reconcile_state,
      virtual_namespace = self.virtual_namespace,
    })
  self:_refresh_mask()
  self.edit_revision = revision
  local window = valid_window(self.surface)
  if window and cursor then
    pcall(vim.api.nvim_win_set_cursor, window, native_cursor(cursor))
  end
  return true
end

---@return string
function Pane:text()
  local record = owner_record(self)
  if not self.surface then
    return record and Base.buffer_text(record) or ""
  end
  if not vim.api.nvim_buf_is_valid(self.surface.buffer) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(self.surface.buffer, 0, -1, false), "\n")
end

---@return Applet.Cursor
function Pane:cursor()
  return Base.cursor(runtime_record(self))
end

---@param cursor Applet.Cursor|[integer, integer]
---@return boolean
function Pane:set_cursor(cursor)
  return Base.set_cursor(runtime_record(self), semantic_cursor(cursor))
end

---@return boolean
function Pane:at_start()
  local cursor = self:cursor()
  return cursor.line == 1 and cursor.column == 0
end

---@return boolean
function Pane:at_end()
  local cursor = self:cursor()
  local lines = vim.split(self:text(), "\n", { plain = true })
  local line = lines[#lines] or ""
  local column = #line
  if self:mode() ~= "insert" and column > 0 then
    local characters = util.characters(line, "Pane text")
    column = column - #(characters[#characters] or "")
  end
  return cursor.line == #lines and cursor.column >= column
end

---@param direction "up"|"previous"|"down"|"next"|"start"|"end"
---@param count? integer
---@return boolean
function Pane:move_cursor(direction, count)
  return Base.move_cursor(runtime_record(self), direction, count)
end

---@param opts? Applet.ScrollOptions
---@return boolean
function Pane:scroll(opts)
  return Base.scroll(runtime_record(self), opts)
end

---@return boolean
function Pane:completion_visible()
  runtime_record(self)
  assert(self.buffer_mode == "editable", "Pane completion requires an editable Pane")
  return Base.completion_visible()
end

---@return boolean
function Pane:complete()
  local record = runtime_record(self)
  assert(self.buffer_mode == "editable", "Pane completion requires an editable Pane")
  return Base.complete(record)
end

---@param direction "next"|"previous"
---@return boolean
function Pane:completion_move(direction)
  local record = runtime_record(self)
  assert(self.buffer_mode == "editable", "Pane completion requires an editable Pane")
  return Base.completion_move(record, direction)
end

---@return boolean
function Pane:completion_accept()
  local record = runtime_record(self)
  assert(self.buffer_mode == "editable", "Pane completion requires an editable Pane")
  return Base.completion_accept(record)
end

---@return {buffer?: integer, window?: integer}
function Pane:native()
  local record = owner_record(self)
  if record then
    return {
      buffer = Base.valid_buffer(record.buffer) and record.buffer or nil,
      window = Base.valid_window(record.window) and record.window or nil,
    }
  end
  return {
    buffer = self.surface and Base.valid_buffer(self.surface.buffer) and self.surface.buffer or nil,
    window = valid_window(self.surface),
  }
end

---@return Applet.CompiledTarget?
function Pane:focused_target()
  return input.focus_target(self) --[[@as Applet.CompiledTarget?]]
end

---@param opts? {group?: string}
---@return Applet.CompiledTarget[]
function Pane:targets(opts)
  if opts == nil then
    opts = {}
  end
  applet_expect(type(opts) == "table", "Pane.targets", "options must be a table", 3)
  applet_expect(opts.group == nil or type(opts.group) == "string", "Pane.targets.group", "must be a string", 3)
  local result = {}
  for _, key in ipairs(self.layout and self.layout.target_order or {}) do
    local target = assert(self.layout).targets[key]
    if target and (opts.group == nil or target.group == opts.group) then
      local value = util.copy(target)
      value.key = key
      result[#result + 1] = value
    end
  end
  return result
end

---@param opts? Applet.TargetMove
---@param count? integer
---@return boolean
function Pane:move_target(opts, count)
  return input.move(self, opts or {}, count)
end

---@param key string
---@return boolean
function Pane:reveal_target(key)
  return input.reveal(self, key)
end

---@return boolean
function Pane:focus_target_intent()
  local intent = self.layout and self.layout.view and self.layout.view.target_intent
  if not intent or not self:focus() then
    return false
  end
  return input.apply_target_intent(self, intent)
end

---@return Applet.PaneCounters
function Pane:_stats()
  return util.copy(self.counters)
end

---@param wiped? boolean
function Pane:_disconnect(wiped)
  if not self.surface then
    return
  end
  stop_frame_timer(self)
  if self.resize_timer then
    self.resize_timer:stop()
  end
  local surface = self.surface
  if vim.api.nvim_buf_is_valid(surface.buffer) and vim.api.nvim_buf_is_loaded(surface.buffer) then
    input.clear_mappings(self)
  else
    self.saved_mappings, self.installed_mappings = {}, {}
  end
  reconcile.clear({
    surface = surface,
    state = self.reconcile_state,
    namespace = self.namespace,
    virtual_namespace = self.virtual_namespace,
    region_namespace = self.region_namespace,
    cursor_namespace = self.cursor_namespace,
    mask_namespace = self.mask_namespace,
    image_namespace = self.image_namespace,
    image_system = self.image_system,
    image_owner = self,
  })
  if self.attached and not wiped and vim.api.nvim_buf_is_valid(surface.buffer) then
    pcall(vim.api.nvim_buf_detach, surface.buffer)
  end
  self.attached = nil
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  if self.domain then
    self.domain:deactivate(self)
    self.domain:remove(self)
  end
  if self.image_system then
    self.image_system:set_references(self, {})
  end
  if not wiped and vim.api.nvim_buf_is_valid(surface.buffer) and vim.api.nvim_buf_is_loaded(surface.buffer) then
    vim.api.nvim_buf_clear_namespace(surface.buffer, self.focus_namespace, 0, -1)
    for option, state in pairs(self.surface_option_states or {}) do
      local current = vim.api.nvim_get_option_value(option, { buf = surface.buffer })
      if util.equal(current, state.written) then
        pcall(vim.api.nvim_set_option_value, option, state.original, { buf = surface.buffer })
      end
    end
  end
  self.surface, self.domain, self.augroup = nil, nil, nil
  self.layout, self.reconcile_state = nil, {}
  self.requested_image_references = nil
  self.pending_scene, self.current_scene = nil, nil
  self.focus_signature = nil
  self.last_width, self.last_height, self.last_focused = nil, nil, nil
  self.last_window = nil
  self.last_flush_ns = nil
  self.force_chrome = false
  self.last_image_geometry = nil
  self.deferred_images = nil
  self.ambient_tree_cache = nil
  self.mask_signature = nil
  self.surface_option_states, self.requested_surface_options = {}, nil
end

function Pane:destroy()
  if self.destroyed then
    return
  end
  self:_disconnect()
  self.destroyed = true
  if self.resize_timer and not self.resize_timer:is_closing() then
    self.resize_timer:close()
  end
  self.resize_timer = nil
  if self.unsubscribe_images then
    self.unsubscribe_images()
  end
  if self.owned_domain then
    self.owned_domain:destroy()
  end
  for buffer in pairs(self.owned_buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  self.owned_buffers = {}
end

---@class Applet.PaneModule
---@field new fun<S>(opts: Applet.PaneOptions<S>): Applet.Pane<S>
---@field is fun(value: unknown): boolean
local module = {
  new = Pane.new,
  is = Pane.is,
  nodes = require("applet.pane.nodes"),
  widgets = require("applet.pane.widgets"),
  text = require("applet.pane.text"),
  compile = require("applet.pane.compile").compile,
}

return setmetatable(module, {
  __call = function(_, opts)
    return Pane.new(opts)
  end,
}) --[[@as Applet.PaneModule]]
