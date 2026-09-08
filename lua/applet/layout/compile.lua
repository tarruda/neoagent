local host_api = require("applet.host")
local Pane = require("applet.pane")
local util = require("applet.util")
local applet_expect = util.expect

---@class Applet.LayoutMeasurement
---@field screen_lines? integer
---@field content_lines? integer
---@field screen_width? integer
---@field content_width? integer
---@field chrome? Applet.Insets

---@class Applet.SplitOverride
---@field signature string
---@field sizes integer[]

---@class Applet.LayoutRectangleInput
---@field row? integer
---@field col? integer
---@field width integer
---@field height integer

---@class Applet.LayoutContainer: Applet.LayoutRectangleInput
---@field available? true

---@alias Applet.ContainerGeometry Applet.LayoutContainer|Applet.Rectangle|{available: false}

---@class Applet.LayoutEnvironmentOptions
---@field host Applet.HostInput
---@field editor? Applet.LayoutRectangleInput
---@field container? Applet.ContainerGeometry

---@class Applet.LayoutEnvironment
---@field bounds Applet.Rectangle
---@field container Applet.Rectangle
---@field capabilities {native_splits: boolean, overlays: boolean}

---@class Applet.LayoutCompileOptions: Applet.LayoutEnvironmentOptions
---@field tree Applet.LayoutTree
---@field measurements? table<string, Applet.LayoutMeasurement>
---@field overrides? table<string, Applet.SplitOverride>
---@field handlers? table<string, function>
---@field has_action? fun(action: string): boolean

---@class Applet.LayoutBinding: Applet.Binding
---@field mode string
---@field nowait boolean
---@field silent boolean

---@class Applet.LayoutScope
---@field key string
---@field kind 'root'|'layout'|'modal'|'pane'
---@field modal? boolean
---@field bindings Applet.LayoutBinding[]

---@class Applet.MountBuffer: Applet.MountBufferOptions
---@field name string
---@field sensitive boolean
---@field options Applet.Options

---@class Applet.MountWindow: Applet.MountWindowOptions
---@field options Applet.Options
---@field host_options {floating: Applet.Options, tab: Applet.Options}

---@class Applet.MountFocus: Applet.MountFocusOptions
---@field mode 'normal'|'insert'|'preserve'
---@field cursor 'preserve'|'start'|'end'

---@class Applet.FloatingProjection
---@field kind 'floating'
---@field config vim.api.keyset.win_config

---@class Applet.SplitProjection
---@field kind 'split'
---@field width integer
---@field height integer

---@alias Applet.MountProjection Applet.FloatingProjection|Applet.SplitProjection

---@class Applet.MountDescriptor
---@field key string
---@field pane Applet.Pane
---@field lifecycle Applet.MountLifecycle
---@field owns_pane boolean
---@field required boolean
---@field mount_revision? number|string
---@field buffer Applet.MountBuffer
---@field window Applet.MountWindow
---@field focus Applet.MountFocus
---@field bindings Applet.LayoutBinding[]
---@field scopes Applet.LayoutScope[]
---@field outer Applet.Rectangle
---@field content Applet.Rectangle
---@field chrome Applet.Insets
---@field projection Applet.MountProjection
---@field layer? string
---@field modal boolean
---@field focusable boolean

---@class Applet.PaneTopology
---@field type 'pane'
---@field key string

---@class Applet.ScopeTopology
---@field type 'scope'
---@field key string
---@field child Applet.LayoutTopology

---@class Applet.SplitTopologyChild
---@field key string
---@field size integer
---@field min integer
---@field max? integer
---@field child Applet.LayoutTopology

---@class Applet.SplitTopology
---@field type 'split'
---@field key string
---@field axis Applet.LayoutAxis
---@field revision? string|number
---@field signature string
---@field children Applet.SplitTopologyChild[]

---@alias Applet.LayoutTopology Applet.PaneTopology|Applet.ScopeTopology|Applet.SplitTopology

---@class Applet.LayoutSplit: Applet.SplitOverride
---@field key string
---@field axis Applet.LayoutAxis
---@field revision? string|number

---@class Applet.LayoutLayer
---@field key string
---@field container string
---@field anchor Applet.LayerAnchor
---@field rect Applet.Rectangle
---@field zindex integer
---@field modal boolean
---@field enter boolean
---@field restore_focus boolean
---@field panes string[]
---@field order integer
---@field width_request boolean
---@field height_request boolean
---@field child Applet.LayoutTopology

---@class Applet.LayoutFocus: Applet.LayoutFocusOptions
---@field layer_entry? string

---@class Applet.CompiledLayout
---@field host Applet.Host
---@field plan {kind: 'floating'|'tab', bounds: Applet.Rectangle, container: Applet.Rectangle, topology: Applet.LayoutTopology}
---@field frame {key: string}
---@field bounds Applet.Rectangle
---@field topology Applet.LayoutTopology
---@field panes table<string, Applet.MountDescriptor>
---@field pane_order string[]
---@field splits table<string, Applet.LayoutSplit>
---@field split_order string[]
---@field layers Applet.LayoutLayer[]
---@field modal_boundary string[]
---@field bindings Applet.LayoutBinding[]
---@field focus Applet.LayoutFocus

---@class Applet.LayoutCompileContext
---@field host Applet.Host
---@field editor Applet.Rectangle
---@field bounds Applet.Rectangle
---@field container Applet.Rectangle
---@field measurements table<string, Applet.LayoutMeasurement>
---@field overrides table<string, Applet.SplitOverride>
---@field handlers table<string, function>
---@field has_action? fun(action: string): boolean
---@field active table<table, boolean>
---@field node_keys table<string, string>
---@field pane_keys table<string, string>
---@field child_keys table<string, string>
---@field mounted_panes table<Applet.Pane, string>
---@field panes table<string, Applet.MountDescriptor>
---@field pane_order string[]
---@field splits table<string, Applet.LayoutSplit>
---@field split_order string[]
---@field layers Applet.LayoutLayer[]
---@field root_scopes Applet.LayoutScope[]

---@class Applet.LayoutWalkState
---@field scopes Applet.LayoutScope[]
---@field layer? string
---@field layer_panes? string[]
---@field modal boolean
---@field zindex? integer
---@field focusable boolean

---@class Applet.LayoutAllocation
---@field key string
---@field node Applet.LayoutNode
---@field basis? Applet.LayoutDimension
---@field min integer
---@field max? integer
---@field size integer
---@field grow number
---@field shrink number
---@field signature string

---@class Applet.AllocationCandidate
---@field index integer
---@field capacity integer
---@field weight number

local M = {}

local applet_actions = {
  ["applet.close"] = true,
  ["applet.focus"] = true,
  ["applet.focus.move"] = true,
  ["applet.focus.restore"] = true,
  ["applet.target.move"] = true,
  ["applet.target.activate"] = true,
  ["applet.target.reveal"] = true,
}

local tree_fields = { root = true, bindings = true, focus = true }
local frame_fields = { type = true, key = true, child = true, layers = true }
local split_fields = {
  type = true, key = true, axis = true, revision = true, children = true,
}
local split_child_fields = {
  key = true, basis = true, grow = true, shrink = true, min = true,
  max = true, child = true,
}
local scope_fields = { type = true, key = true, bindings = true, child = true }
local mount_fields = {
  type = true, pane = true, lifecycle = true,
  owns_pane = true, required = true, mount_revision = true,
  buffer = true, window = true, focus = true, bindings = true,
}
local layer_fields = {
  type = true, key = true, container = true, anchor = true, width = true,
  height = true, zindex = true, modal = true, enter = true,
  restore_focus = true, child = true,
}
local buffer_fields = {
  name = true, uri = true, filetype = true, sensitive = true, options = true,
}
local window_fields = {
  border = true, options = true, host_options = true,
}
local host_options_fields = { floating = true, tab = true }
local pane_focus_fields = { mode = true, cursor = true }
local tree_focus_fields = { initial = true, intent = true }
local focus_intent_fields = { key = true, revision = true }
local binding_fields = {
  mode = true, lhs = true, action = true, desc = true, nowait = true,
  silent = true,
}
local action_fields = { action = true, payload = true }
local content_dimension_fields = { content = true, min = true, max = true }

local reserved_buffer_options = { bufhidden = true }
local reserved_window_options = {
  winbar = true, statusline = true, winfixheight = true, winfixwidth = true,
}

local anchors = {
  center = true, top = true, bottom = true, left = true, right = true,
  top_left = true, top_right = true, bottom_left = true, bottom_right = true,
}

local borders = {
  none = true, single = true, double = true, rounded = true,
  solid = true, shadow = true,
}

---@param value unknown
---@return TypeGuard<number>
local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

---@param value unknown
---@return TypeGuard<integer>
local function integer(value)
  return finite(value) and value % 1 == 0
end

---@param value table
---@param accepted table<string, boolean>
---@param path string
local function fields(value, accepted, path)
  applet_expect(type(value) == "table", path, "must be a table", 4)
  applet_expect(getmetatable(value) == nil, path, "must be a plain table", 4)
  for key in pairs(value) do
    applet_expect(accepted[key] == true, path .. "." .. tostring(key),
      "is not a recognized field", 4)
  end
end

---@generic T: Applet.Data
---@param value T
---@param path string
---@param active? table<table, boolean>
---@return T
local function copy_value(value, path, active)
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "string" then return value end
  if kind == "number" then
    applet_expect(finite(value), path, "must contain only finite numbers", 4)
    return value
  end
  applet_expect(kind == "table", path,
    "must contain only plain data values", 4)
  applet_expect(getmetatable(value) == nil, path, "must be a plain table", 4)
  ---@cast value Applet.DataTable
  active = active or {}
  applet_expect(not active[value], path, "must not contain a cycle", 4)
  active[value] = true
  local result = {}
  for key, item in pairs(value) do
    local key_kind = type(key)
    applet_expect(key_kind == "string" or key_kind == "number", path,
      "must use string or number keys", 4)
    result[key] = copy_value(item, path .. "." .. tostring(key), active)
  end
  active[value] = nil
  return result --[[@as T]]
end

---@param value string
---@param path string
---@return string
local function nonempty(value, path)
  applet_expect(util.nonempty_string(value), path, "must be a non-empty string", 4)
  return value
end

---@param value? Applet.LayoutDimension
---@return string
local function dimension_signature(value)
  if type(value) ~= "table" then return tostring(value) end
  return table.concat({ "content", tostring(value.content), "min",
    tostring(value.min), "max", tostring(value.max) }, ":")
end

---@param value number
---@param path string
---@param allow_zero? boolean
---@return number
local function validate_scalar_dimension(value, path, allow_zero)
  applet_expect(finite(value) and (allow_zero and value >= 0 or value > 0),
    path, allow_zero and "must be a non-negative finite number"
      or "must be a positive finite number", 4)
  applet_expect(value <= 1 or value % 1 == 0, path,
    "must be a fraction in (0, 1] or an integral cell count", 4)
  return value
end

---@overload fun(value: number, path: string, content?: boolean): number
---@param value Applet.LayoutDimension
---@param path string
---@param content? boolean
---@return Applet.LayoutDimension
local function validate_dimension(value, path, content)
  if type(value) == "number" then
    return validate_scalar_dimension(value, path)
  end
  applet_expect(content and type(value) == "table", path,
    "must be a number or content request", 4)
  fields(value, content_dimension_fields, path)
  applet_expect(value.content == true
      or (finite(value.content) and value.content >= 0
        and value.content % 1 == 0),
    path .. ".content", "must be true or a non-negative integral cell count", 4)
  if value.min ~= nil then validate_scalar_dimension(value.min, path .. ".min") end
  if value.max ~= nil then validate_scalar_dimension(value.max, path .. ".max") end
  return {
    content = value.content,
    min = value.min,
    max = value.max,
  }
end

---@param value number
---@param total integer
---@return integer
local function resolve_scalar(value, total)
  if value <= 1 then return math.max(1, math.floor(total * value + 0.5)) end
  -- Scalar validation guarantees integral cell counts above one.
  return value --[[@as integer]]
end

---@param border? Applet.WindowBorder
---@return Applet.Insets
local function border_metrics(border)
  if border == nil or border == "" or border == "none" then
    return { top = 0, right = 0, bottom = 0, left = 0 }
  end
  if type(border) == "string" then
    applet_expect(borders[border] == true, "Pane.window.border",
      "must be a recognized border name or plain border table", 4)
    return { top = 1, right = 1, bottom = 1, left = 1 }
  end
  applet_expect(type(border) == "table" and getmetatable(border) == nil,
    "Pane.window.border", "must be a string or plain border table", 4)
  applet_expect(#border == 8, "Pane.window.border",
    "border tables must contain eight cells", 4)
  local count = 0
  for _ in pairs(border) do count = count + 1 end
  applet_expect(count == 8, "Pane.window.border",
    "border tables must contain a dense list of eight cells", 4)
  local occupied = {}
  for index, cell in ipairs(border) do
    if type(cell) == "table" then
      applet_expect(getmetatable(cell) == nil and #cell >= 1 and #cell <= 2,
        "Pane.window.border." .. index,
        "must be a string or { text, highlight }", 4)
      local cell_count = 0
      for _ in pairs(cell) do cell_count = cell_count + 1 end
      applet_expect(cell_count == #cell, "Pane.window.border." .. index,
        "must be a dense border cell", 4)
      applet_expect(cell[2] == nil or type(cell[2]) == "string",
        "Pane.window.border." .. index .. ".2",
        "highlight must be a string", 4)
      cell = cell[1]
    end
    applet_expect(type(cell) == "string", "Pane.window.border." .. index,
      "must be a string or { text, highlight }", 4)
    applet_expect(util.display_width(cell) <= 1, "Pane.window.border." .. index,
      "must occupy at most one display cell", 4)
    occupied[index] = cell ~= ""
  end
  return {
    top = (occupied[1] or occupied[2] or occupied[3]) and 1 or 0,
    right = (occupied[3] or occupied[4] or occupied[5]) and 1 or 0,
    bottom = (occupied[5] or occupied[6] or occupied[7]) and 1 or 0,
    left = (occupied[7] or occupied[8] or occupied[1]) and 1 or 0,
  }
end

---@param rect Applet.Rectangle
---@return Applet.Rectangle
local function copy_rect(rect)
  return {
    row = rect.row,
    col = rect.col,
    width = rect.width,
    height = rect.height,
  }
end

---@param value Applet.LayoutRectangleInput|Applet.Rectangle
---@param path string
---@return Applet.Rectangle
local function normalize_rect(value, path)
  applet_expect(type(value) == "table", path, "must be a table", 4)
  local result = {
    row = value.row or 0,
    col = value.col or 0,
    width = value.width,
    height = value.height,
  }
  applet_expect(integer(result.row) and integer(result.col), path,
    "row and col must be integral cells", 4)
  applet_expect(integer(result.width) and result.width > 0
      and integer(result.height) and result.height > 0,
    path, "width and height must be positive integral cells", 4)
  return result
end

---@param host Applet.Host
---@param editor Applet.Rectangle
---@param container? Applet.ContainerGeometry
---@return Applet.Rectangle, Applet.Rectangle
local function host_bounds(host, editor, container)
  if host.kind == "tab" then return copy_rect(editor), copy_rect(editor) end
  ---@cast host Applet.FloatingHost
  local selected
  if host.container == "editor" then
    selected = editor
  elseif container and container.available ~= false then
    selected = normalize_rect(container, "Applet container")
  elseif host.container == "auto" then
    selected = editor
  else
    error("Applet floating Host container is unavailable", 0)
  end
  local available_width = selected.width - host.margin * 2
  local available_height = selected.height - host.margin * 2
  applet_expect(available_width > 0 and available_height > 0,
    "Applet floating Host", "margin leaves no available cells", 4)
  local width = math.min(available_width, resolve_scalar(host.width, selected.width))
  local height = math.min(available_height, resolve_scalar(host.height, selected.height))
  applet_expect(width > 0 and height > 0, "Applet floating Host",
    "resolved bounds must contain cells", 4)
  local row = selected.row + host.margin
  local col = selected.col + host.margin
  if host.side == "right" then
    col = selected.col + selected.width - host.margin - width
  elseif host.side == "bottom" then
    row = selected.row + selected.height - host.margin - height
  elseif host.side == "center" then
    row = selected.row + math.floor((selected.height - height) / 2)
    col = selected.col + math.floor((selected.width - width) / 2)
  end
  return { row = row, col = col, width = width, height = height }, copy_rect(selected)
end

---@param opts Applet.LayoutEnvironmentOptions
---@return Applet.LayoutEnvironment
function M.environment(opts)
  applet_expect(type(opts) == "table", "Applet environment",
    "options must be a table", 3)
  local selected = host_api.validate(opts.host)
  local editor = normalize_rect(opts.editor or {
    row = 0, col = 0, width = 80, height = 24,
  }, "Applet editor")
  local bounds, container = host_bounds(selected, editor, opts.container)
  return {
    bounds = copy_rect(bounds),
    container = copy_rect(container),
    capabilities = {
      native_splits = selected.kind == "tab",
      overlays = true,
    },
  }
end

---@param value? Applet.Options
---@param path string
---@param reserved? table<string, boolean>
---@return Applet.Options
local function validate_options(value, path, reserved)
  if value == nil then return {} end
  applet_expect(type(value) == "table" and getmetatable(value) == nil,
    path, "must be a plain table", 4)
  local result = copy_value(value, path)
  for option in pairs(result) do
    applet_expect(not (reserved and reserved[option]), path .. "." .. tostring(option),
      "is owned by Applet", 4)
  end
  return result
end

---@param value Applet.Action
---@param path string
---@param ctx Applet.LayoutCompileContext
---@return Applet.Action
local function normalize_action(value, path, ctx)
  fields(value, action_fields, path)
  local name = nonempty(value.action, path .. ".action")
  applet_expect(applet_actions[name] or ctx.handlers[name]
      or (ctx.has_action and ctx.has_action(name)),
    path .. ".action", "is unknown: " .. string.format("%q", name), 4)
  return { action = name, payload = copy_value(value.payload, path .. ".payload") }
end

---@param value? Applet.Binding[]
---@param path string
---@param ctx Applet.LayoutCompileContext
---@return Applet.LayoutBinding[]
local function normalize_bindings(value, path, ctx)
  if value == nil then return {} end
  applet_expect(type(value) == "table" and getmetatable(value) == nil,
    path, "must be a plain list", 4)
  local result, seen_pairs = {}, {}
  for index, binding in ipairs(value) do
    local item_path = path .. "." .. index
    fields(binding, binding_fields, item_path)
    local mode = binding.mode or "n"
    nonempty(mode, item_path .. ".mode")
    local lhs = nonempty(binding.lhs, item_path .. ".lhs")
    applet_expect(type(binding.action) == "table", item_path .. ".action",
      "must be an action", 4)
    local pair = mode .. "\0" .. lhs
    applet_expect(not seen_pairs[pair], item_path,
      "duplicates an equal-precedence mode and lhs", 4)
    seen_pairs[pair] = true
    result[#result + 1] = {
      mode = mode,
      lhs = lhs,
      action = normalize_action(binding.action, item_path .. ".action", ctx),
      desc = binding.desc,
      nowait = binding.nowait == true,
      silent = binding.silent ~= false,
    }
    applet_expect(binding.desc == nil or type(binding.desc) == "string",
      item_path .. ".desc", "must be a string", 4)
    applet_expect(binding.nowait == nil or type(binding.nowait) == "boolean",
      item_path .. ".nowait", "must be a boolean", 4)
    applet_expect(binding.silent == nil or type(binding.silent) == "boolean",
      item_path .. ".silent", "must be a boolean", 4)
  end
  local count = 0
  for _ in pairs(value) do count = count + 1 end
  applet_expect(count == #value, path, "must be a dense list", 4)
  return result
end

---@param keys table<string, string>
---@param key string
---@param path string
---@return string
local function register_key(keys, key, path)
  nonempty(key, path)
  applet_expect(not keys[key], path, "duplicates " .. string.format("%q", key), 4)
  keys[key] = path
  return key
end

---@type fun(ctx: Applet.LayoutCompileContext, node: Applet.LayoutNode, axis: Applet.LayoutAxis): integer
local child_decoration

---@param node Applet.LayoutNode
---@return string
local function layout_key(node)
  if node.type == "mount" then
    ---@cast node Applet.MountNode
    if Pane.is(node.pane) then return node.pane:key() end
  end
  return node.key --[[@as string]]
end

---@param ctx Applet.LayoutCompileContext
---@param node Applet.LayoutNode
---@param axis Applet.LayoutAxis
---@return integer
local function measured_content(ctx, node, axis)
  if node.type == "scope" then
    ---@cast node Applet.LayoutScopeNode
    return measured_content(ctx, node.child, axis)
  end
  if node.type == "split" then
    ---@cast node Applet.LayoutSplitNode
    local measured = node.axis == axis and 0 or 1
    for _, item in ipairs(node.children or {}) do
      local child = measured_content(ctx, item.child, axis)
        + child_decoration(ctx, item.child, axis)
      if node.axis == axis then measured = measured + child
      else measured = math.max(measured, child) end
    end
    return measured
  end
  local key = layout_key(node)
  local measured = key and ctx.measurements[key] or nil
  if not measured then return 1 end
  if axis == "vertical" then
    return measured.screen_lines or measured.content_lines or 1
  end
  return measured.screen_width or measured.content_width or 1
end

---@param ctx Applet.LayoutCompileContext
---@param key string
---@param border? Applet.WindowBorder
---@return Applet.Insets
local function chrome_metrics(ctx, key, border)
  if ctx.host.kind == "floating" then return border_metrics(border) end
  local measured = ctx.measurements[key]
  local metrics = measured and measured.chrome or nil
  if not metrics then return { top = 0, right = 0, bottom = 0, left = 0 } end
  local result = { top = 0, right = 0, bottom = 0, left = 0 }
  for _, side in ipairs({ "top", "right", "bottom", "left" }) do
    local value = metrics[side] or 0
    applet_expect(integer(value) and value >= 0,
      "measurements." .. key .. ".chrome." .. side,
      "must be a non-negative integral cell count", 4)
    result[side] = value
  end
  return result
end

---@param ctx Applet.LayoutCompileContext
---@param node Applet.LayoutNode
---@param axis Applet.LayoutAxis
---@return integer
child_decoration = function(ctx, node, axis)
  if node.type == "scope" then
    ---@cast node Applet.LayoutScopeNode
    return child_decoration(ctx, node.child, axis)
  end
  if node.type ~= "mount" then return 0 end
  local window = node.window or {}
  local metrics = chrome_metrics(ctx, layout_key(node), window.border)
  if axis == "vertical" then return metrics.top + metrics.bottom end
  return metrics.left + metrics.right
end

---@param value Applet.LayoutDimension
---@param total integer
---@param node Applet.LayoutNode
---@param axis Applet.LayoutAxis
---@param ctx Applet.LayoutCompileContext
---@return integer
local function resolve_content_dimension(value, total, node, axis, ctx)
  if type(value) == "number" then return resolve_scalar(value, total) end
  local content = value.content == true and measured_content(ctx, node, axis)
    or value.content
  local result = content + child_decoration(ctx, node, axis)
  if value.min ~= nil then result = math.max(result, resolve_scalar(value.min, total)) end
  if value.max ~= nil then result = math.min(result, resolve_scalar(value.max, total)) end
  return result
end

---@param items Applet.LayoutAllocation[]
---@param amount integer
---@param growing boolean
---@return integer
local function weighted_change(items, amount, growing)
  ---@type Applet.AllocationCandidate[]
  local candidates = {}
  ---@type number
  local weight_total = 0
  for index, item in ipairs(items) do
    local capacity = growing and (item.max or item.size + amount) - item.size
      or item.size - item.min
    local weight = growing and item.grow or item.shrink
    if capacity > 0 and weight > 0 then
      candidates[#candidates + 1] = {
        index = index,
        capacity = capacity,
        weight = weight,
      }
      weight_total = weight_total + weight
    end
  end
  if #candidates == 0 then return 0 end
  local changed = 0
  ---@type {candidate: Applet.AllocationCandidate, fraction: number}[]
  local fractions = {}
  for _, candidate in ipairs(candidates) do
    local exact = amount * candidate.weight / weight_total
    local cells = math.min(candidate.capacity, math.floor(exact))
    if cells > 0 then
      local item = assert(items[candidate.index])
      item.size = item.size + (growing and cells or -cells)
      candidate.capacity = candidate.capacity - cells
      changed = changed + cells
    end
    fractions[#fractions + 1] = { candidate = candidate, fraction = exact - math.floor(exact) }
  end
  table.sort(fractions, function(left, right)
    if left.fraction == right.fraction then
      return left.candidate.index < right.candidate.index
    end
    return left.fraction > right.fraction
  end)
  local remaining = amount - changed
  while remaining > 0 do
    local progress = false
    for _, value in ipairs(fractions) do
      local candidate = value.candidate
      if candidate.capacity > 0 and remaining > 0 then
        local item = assert(items[candidate.index])
        item.size = item.size + (growing and 1 or -1)
        candidate.capacity = candidate.capacity - 1
        remaining = remaining - 1
        changed = changed + 1
        progress = true
      end
    end
    if not progress then break end
  end
  return changed
end

---@param children Applet.LayoutSplitChild[]
---@param total integer
---@param axis Applet.LayoutAxis
---@param ctx Applet.LayoutCompileContext
---@param path string
---@return Applet.LayoutAllocation[]
local function allocate(children, total, axis, ctx, path)
  ---@type Applet.LayoutAllocation[]
  local items = {}
  local used = 0
  for index, value in ipairs(children) do
    local item_path = path .. ".children." .. index
    fields(value, split_child_fields, item_path)
    register_key(ctx.child_keys, value.key, item_path .. ".key")
    applet_expect(type(value.child) == "table", item_path .. ".child",
      "must be a layout node", 4)
    local basis = value.basis
    if basis ~= nil then basis = validate_dimension(basis, item_path .. ".basis", true) end
    local declared_min = value.min
    if declared_min ~= nil then
      declared_min = validate_dimension(declared_min, item_path .. ".min", false)
    end
    local declared_max = value.max
    if declared_max ~= nil then
      declared_max = validate_dimension(declared_max, item_path .. ".max", false)
    end
    local intrinsic = math.max(1, child_decoration(ctx, value.child, axis) + 1)
    local minimum = declared_min and resolve_scalar(declared_min, total) or intrinsic
    minimum = math.max(intrinsic, minimum)
    local maximum = declared_max and resolve_scalar(declared_max, total) or nil
    applet_expect((maximum == nil or maximum >= minimum), item_path, "max must be at least min", 4)
    local size = basis and resolve_content_dimension(
      basis, total, value.child, axis, ctx) or minimum
    size = math.max(minimum, maximum and math.min(maximum, size) or size)
    local grow = value.grow
    if grow == nil then grow = basis == nil and 1 or 0 end
    local shrink = value.shrink == nil and 1 or value.shrink
    applet_expect(finite(grow) and grow >= 0, item_path .. ".grow",
      "must be a non-negative finite number", 4)
    applet_expect(finite(shrink) and shrink >= 0, item_path .. ".shrink",
      "must be a non-negative finite number", 4)
    items[#items + 1] = {
      key = value.key,
      node = value.child,
      basis = basis,
      min = minimum,
      max = maximum,
      size = size,
      grow = grow,
      shrink = shrink,
      signature = table.concat({ value.key, dimension_signature(basis),
        tostring(grow), tostring(shrink), tostring(declared_min),
        tostring(declared_max) }, "\0"),
    }
    used = used + size
  end
  if used < total then
    local remaining = total - used
    local changed = weighted_change(items, remaining, true)
    if changed < remaining then
      for index = #items, 1, -1 do
        local item = assert(items[index])
        local capacity = (item.max or item.size + remaining - changed) - item.size
        local cells = math.min(capacity, remaining - changed)
        item.size = item.size + cells
        changed = changed + cells
        if changed == remaining then break end
      end
    end
    applet_expect(changed == remaining, path,
      "maximum constraints leave unallocated cells", 4)
  elseif used > total then
    local needed = used - total
    local changed = weighted_change(items, needed, false)
    applet_expect(changed == needed, path,
      "minimum constraints do not fit the available cells ("
        .. used .. " required, " .. total .. " available)", 4)
  end
  return items
end

---@param value? Applet.MountBufferOptions
---@param key string
---@param lifecycle Applet.MountLifecycle
---@param path string
---@return Applet.MountBuffer
local function normalize_buffer(value, key, lifecycle, path)
  value = value or {}
  fields(value, buffer_fields, path)
  local name = value.name or key
  nonempty(name, path .. ".name")
  applet_expect(value.uri == nil or util.nonempty_string(value.uri),
    path .. ".uri", "must be a non-empty string", 4)
  applet_expect(value.filetype == nil or type(value.filetype) == "string",
    path .. ".filetype", "must be a string", 4)
  applet_expect(value.sensitive == nil or type(value.sensitive) == "boolean",
    path .. ".sensitive", "must be a boolean", 4)
  applet_expect(not value.sensitive or lifecycle == "transient",
    path .. ".sensitive", "requires a transient Pane", 4)
  local options = validate_options(value.options, path .. ".options",
    reserved_buffer_options)
  if value.sensitive then
    applet_expect(options.swapfile == nil or options.swapfile == false,
      path .. ".options.swapfile", "must be false for a sensitive Pane", 4)
    applet_expect(options.undofile == nil or options.undofile == false,
      path .. ".options.undofile", "must be false for a sensitive Pane", 4)
    options.swapfile, options.undofile = false, false
  end
  return {
    name = name,
    uri = value.uri,
    filetype = value.filetype,
    sensitive = value.sensitive == true,
    options = options,
  }
end

---@param value? Applet.MountWindowOptions
---@param path string
---@return Applet.MountWindow
local function normalize_window(value, path)
  value = value or {}
  fields(value, window_fields, path)
  local border = value.border
  if border ~= nil then border_metrics(border) end
  local host_options = value.host_options or {}
  fields(host_options, host_options_fields, path .. ".host_options")
  return {
    border = copy_value(border, path .. ".border"),
    options = validate_options(value.options, path .. ".options",
      reserved_window_options),
    host_options = {
      floating = validate_options(host_options.floating,
        path .. ".host_options.floating", reserved_window_options),
      tab = validate_options(host_options.tab,
        path .. ".host_options.tab", reserved_window_options),
    },
  }
end

---@param value? Applet.MountFocusOptions
---@param pane Applet.Pane
---@param path string
---@return Applet.MountFocus
local function normalize_pane_focus(value, pane, path)
  value = value or {}
  fields(value, pane_focus_fields, path)
  local editable = pane.buffer_mode == "editable"
  local mode = value.mode or (editable and "insert" or "normal")
  applet_expect(mode == "normal" or mode == "insert" or mode == "preserve",
    path .. ".mode", "must be normal, insert, or preserve", 4)
  applet_expect(not ((mode == "insert" or mode == "preserve") and not editable),
    path .. ".mode", "requires an editable Pane", 4)
  local cursor = value.cursor or "preserve"
  applet_expect(cursor == "preserve" or cursor == "start" or cursor == "end",
    path .. ".cursor", "must be preserve, start, or end", 4)
  return { mode = mode, cursor = cursor }
end

---@type fun(ctx: Applet.LayoutCompileContext, node: Applet.LayoutNode, rect: Applet.Rectangle, state: Applet.LayoutWalkState, path: string): Applet.LayoutTopology
local layout_node

---@param ctx Applet.LayoutCompileContext
---@param node Applet.MountNode
---@param rect Applet.Rectangle
---@param state Applet.LayoutWalkState
---@param path string
---@return Applet.PaneTopology
local function project_mount(ctx, node, rect, state, path)
  fields(node, mount_fields, path)
  local pane = node.pane
  applet_expect(Pane.is(pane), path .. ".pane", "must be a Pane instance", 4)
  local key = register_key(ctx.pane_keys, pane:key(), path .. ".pane")
  register_key(ctx.node_keys, key, path .. ".pane")
  applet_expect(not ctx.mounted_panes[pane], path .. ".pane",
    "is already mounted as " .. tostring(ctx.mounted_panes[pane]), 4)
  ctx.mounted_panes[pane] = key
  local lifecycle = node.lifecycle or "retained"
  applet_expect(lifecycle == "retained" or lifecycle == "transient",
    path .. ".lifecycle", "must be retained or transient", 4)
  applet_expect(node.owns_pane == nil or type(node.owns_pane) == "boolean",
    path .. ".owns_pane", "must be a boolean", 4)
  applet_expect(node.required == nil or type(node.required) == "boolean",
    path .. ".required", "must be a boolean", 4)
  applet_expect(node.mount_revision == nil
      or type(node.mount_revision) == "string" or finite(node.mount_revision),
    path .. ".mount_revision", "must be a finite number or string", 4)
  local buffer = normalize_buffer(node.buffer, key, lifecycle, path .. ".buffer")
  local window = normalize_window(node.window, path .. ".window")
  local focus = normalize_pane_focus(node.focus, pane, path .. ".focus")
  local bindings = normalize_bindings(node.bindings, path .. ".bindings", ctx)
  local metrics = chrome_metrics(ctx, key, window.border)
  local content = {
    row = rect.row + metrics.top,
    col = rect.col + metrics.left,
    width = rect.width - metrics.left - metrics.right,
    height = rect.height - metrics.top - metrics.bottom,
  }
  applet_expect(content.width > 0 and content.height > 0, path,
    "decoration leaves no positive Pane content rectangle", 4)
  local scopes = {}
  for _, scope in ipairs(ctx.root_scopes) do scopes[#scopes + 1] = scope end
  for _, scope in ipairs(state.scopes) do scopes[#scopes + 1] = scope end
  if state.modal then
    scopes[#scopes + 1] = {
      key = "@applet:modal:" .. tostring(state.layer),
      kind = "modal",
      modal = true,
      bindings = {},
    }
  end
  if #bindings > 0 then
    scopes[#scopes + 1] = {
      key = "@applet:pane:" .. key,
      kind = "pane",
      bindings = bindings,
    }
  end
  local projection_kind = (state.layer ~= nil or ctx.host.kind == "floating")
    and "floating" or "split"
  local projection
  if projection_kind == "floating" then
    projection = {
      kind = "floating",
      config = {
        relative = "editor",
        row = state.layer and content.row or rect.row,
        col = state.layer and content.col or rect.col,
        width = content.width,
        height = content.height,
        style = "minimal",
        border = copy_value(window.border, path .. ".window.border"),
        zindex = state.zindex or ctx.host.base_zindex,
        focusable = state.focusable ~= false,
      },
    }
  else
    projection = {
      kind = "split",
      width = content.width,
      height = content.height,
    }
  end
  local descriptor = {
    key = key,
    pane = pane,
    lifecycle = lifecycle,
    owns_pane = node.owns_pane == true,
    required = node.required == true,
    mount_revision = node.mount_revision,
    buffer = buffer,
    window = window,
    focus = focus,
    bindings = bindings,
    scopes = scopes,
    outer = copy_rect(rect),
    content = content,
    chrome = metrics,
    projection = projection,
    layer = state.layer,
    modal = state.modal == true,
    focusable = state.focusable ~= false,
  }
  ctx.panes[key] = descriptor
  ctx.pane_order[#ctx.pane_order + 1] = key
  if state.layer then
    local layer_panes = assert(state.layer_panes)
    layer_panes[#layer_panes + 1] = key
  end
  return { type = "pane", key = key }
end

---@param ctx Applet.LayoutCompileContext
---@param node Applet.LayoutScopeNode
---@param rect Applet.Rectangle
---@param state Applet.LayoutWalkState
---@param path string
---@return Applet.ScopeTopology
local function project_scope(ctx, node, rect, state, path)
  fields(node, scope_fields, path)
  local key = register_key(ctx.node_keys, node.key, path .. ".key")
  local bindings = normalize_bindings(node.bindings, path .. ".bindings", ctx)
  applet_expect(type(node.child) == "table", path .. ".child",
    "must be a layout node", 4)
  local next_state = {
    scopes = {}, layer = state.layer, layer_panes = state.layer_panes,
    modal = state.modal, zindex = state.zindex, focusable = state.focusable,
  }
  for _, scope in ipairs(state.scopes) do next_state.scopes[#next_state.scopes + 1] = scope end
  next_state.scopes[#next_state.scopes + 1] = {
    key = key,
    kind = "layout",
    bindings = bindings,
  }
  return {
    type = "scope",
    key = key,
    child = layout_node(ctx, node.child, rect, next_state, path .. ".child"),
  }
end

---@param node Applet.LayoutSplitNode
---@param items Applet.LayoutAllocation[]
---@return string
local function split_signature(node, items)
  local values = { node.axis, tostring(node.revision) }
  for _, item in ipairs(items) do values[#values + 1] = item.signature end
  return table.concat(values, "\1")
end

---@param ctx Applet.LayoutCompileContext
---@param node Applet.LayoutSplitNode
---@param rect Applet.Rectangle
---@param state Applet.LayoutWalkState
---@param path string
---@return Applet.SplitTopology
local function project_split(ctx, node, rect, state, path)
  fields(node, split_fields, path)
  local key = register_key(ctx.node_keys, node.key, path .. ".key")
  applet_expect(node.axis == "vertical" or node.axis == "horizontal",
    path .. ".axis", "must be vertical or horizontal", 4)
  applet_expect(node.revision == nil or type(node.revision) == "string"
      or finite(node.revision), path .. ".revision",
    "must be a finite number or string", 4)
  applet_expect(type(node.children) == "table" and #node.children > 0,
    path .. ".children", "must be a non-empty list", 4)
  applet_expect(getmetatable(node.children) == nil,
    path .. ".children", "must be a plain list", 4)
  local child_count = 0
  for _ in pairs(node.children) do child_count = child_count + 1 end
  applet_expect(child_count == #node.children,
    path .. ".children", "must be a dense list", 4)
  local axis_total = node.axis == "vertical" and rect.height or rect.width
  local items = allocate(node.children, axis_total, node.axis, ctx, path)
  local signature = split_signature(node, items)
  local override = ctx.overrides[key]
  if override and override.signature == signature
      and type(override.sizes) == "table" and #override.sizes == #items then
    local total = 0
    for index, size in ipairs(override.sizes) do
      local item = assert(items[index])
      if not integer(size) or size < item.min
          or (item.max and size > item.max) then
        total = -1
        break
      end
      total = total + size
    end
    if total == axis_total then
      for index, size in ipairs(override.sizes) do assert(items[index]).size = size end
    end
  end
  local children, offset = {}, 0
  for index, item in ipairs(items) do
    local child_rect = copy_rect(rect)
    if node.axis == "vertical" then
      child_rect.row = rect.row + offset
      child_rect.height = item.size
    else
      child_rect.col = rect.col + offset
      child_rect.width = item.size
    end
    local projected = layout_node(ctx, item.node, child_rect, state,
      path .. ".children." .. index .. ".child")
    children[#children + 1] = {
      key = item.key,
      size = item.size,
      min = item.min,
      max = item.max,
      child = projected,
    }
    offset = offset + item.size
  end
  local split_sizes = {}
  for _, item in ipairs(items) do split_sizes[#split_sizes + 1] = item.size end
  ctx.splits[key] = {
    key = key,
    axis = node.axis,
    revision = node.revision,
    signature = signature,
    sizes = split_sizes,
  }
  ctx.split_order[#ctx.split_order + 1] = key
  return {
    type = "split",
    key = key,
    axis = node.axis,
    revision = node.revision,
    signature = signature,
    children = children,
  }
end

---@param ctx Applet.LayoutCompileContext
---@param node Applet.LayoutNode
---@param rect Applet.Rectangle
---@param state Applet.LayoutWalkState
---@param path string
---@return Applet.LayoutTopology
layout_node = function(ctx, node, rect, state, path)
  applet_expect(type(node) == "table", path, "must be a layout node", 4)
  applet_expect(getmetatable(node) == nil, path, "must be a plain table", 4)
  applet_expect(not ctx.active[node], path, "must not contain a cycle", 4)
  ctx.active[node] = true
  local result
  if node.type == "mount" then
    result = project_mount(ctx, node, rect, state, path)
  elseif node.type == "scope" then
    result = project_scope(ctx, node, rect, state, path)
  elseif node.type == "split" then
    result = project_split(ctx, node, rect, state, path)
  else
    error(path .. ".type: must be mount, scope, or split", 0)
  end
  ctx.active[node] = nil
  return result
end

---@param value? Applet.LayoutDimension
---@param total integer
---@param child Applet.LayoutNode
---@param axis Applet.LayoutAxis
---@param ctx Applet.LayoutCompileContext
---@param path string
---@return integer
local function resolve_layer_dimension(value, total, child, axis, ctx, path)
  if value == nil then value = 0.8 end
  value = validate_dimension(value, path, true)
  return math.min(total, resolve_content_dimension(value, total, child, axis, ctx))
end

---@param container Applet.Rectangle
---@param width integer
---@param height integer
---@param anchor Applet.LayerAnchor
---@return Applet.Rectangle
local function anchor_rect(container, width, height, anchor)
  local row, col = container.row, container.col
  if anchor == "center" then
    row = row + math.floor((container.height - height) / 2)
    col = col + math.floor((container.width - width) / 2)
  elseif anchor == "bottom" then
    row = row + container.height - height
    col = col + math.floor((container.width - width) / 2)
  elseif anchor == "top" then
    col = col + math.floor((container.width - width) / 2)
  elseif anchor == "right" then
    row = row + math.floor((container.height - height) / 2)
    col = col + container.width - width
  elseif anchor == "left" then
    row = row + math.floor((container.height - height) / 2)
  elseif anchor == "top_right" then
    col = col + container.width - width
  elseif anchor == "bottom_left" then
    row = row + container.height - height
  elseif anchor == "bottom_right" then
    row = row + container.height - height
    col = col + container.width - width
  end
  return { row = row, col = col, width = width, height = height }
end

---@param ctx Applet.LayoutCompileContext
---@param node Applet.LayoutLayerNode
---@param index integer
---@param path string
---@return Applet.LayoutLayer
local function project_layer(ctx, node, index, path)
  fields(node, layer_fields, path)
  local key = register_key(ctx.node_keys, node.key, path .. ".key")
  applet_expect(type(node.child) == "table", path .. ".child",
    "must be a layout node", 4)
  local container_key = node.container or "applet"
  local container
  if container_key == "editor" then container = ctx.editor
  elseif container_key == "applet" then container = ctx.bounds
  else
    nonempty(container_key, path .. ".container")
    local pane = ctx.panes[container_key]
    applet_expect(pane ~= nil, path .. ".container",
      "must name an already-declared Pane", 4)
    container = pane.outer
  end
  local anchor = node.anchor or "center"
  applet_expect(anchors[anchor], path .. ".anchor", "is not recognized", 4)
  local width = resolve_layer_dimension(node.width, container.width,
    node.child, "horizontal", ctx, path .. ".width")
  local height = resolve_layer_dimension(node.height, container.height,
    node.child, "vertical", ctx, path .. ".height")
  applet_expect(width > 0 and height > 0, path,
    "must resolve to a positive rectangle", 4)
  local rect = anchor_rect(container, width, height, anchor)
  local zindex = node.zindex or ((ctx.host.base_zindex or 40) + 30 + index * 10)
  applet_expect(integer(zindex) and zindex > 0, path .. ".zindex",
    "must be a positive integral value", 4)
  for _, field in ipairs({ "modal", "enter", "restore_focus" }) do
    applet_expect(node[field] == nil or type(node[field]) == "boolean",
      path .. "." .. field, "must be a boolean", 4)
  end
  local layer = {
    key = key,
    container = container_key,
    anchor = anchor,
    rect = rect,
    zindex = zindex,
    modal = node.modal == true,
    enter = node.enter == true,
    restore_focus = node.restore_focus ~= false,
    panes = {},
    order = index,
    width_request = type(node.width) == "table" and node.width.content == true,
    height_request = type(node.height) == "table" and node.height.content == true,
  }
  local state = {
    scopes = {}, layer = key, layer_panes = layer.panes,
    modal = layer.modal, zindex = zindex, focusable = true,
  }
  layer.child = layout_node(ctx, node.child, rect, state, path .. ".child")
  applet_expect(not layer.modal or not layer.enter or #layer.panes > 0, path,
    "modal entry requires a focusable Pane", 4)
  ctx.layers[#ctx.layers + 1] = layer
  return layer
end

---@param value? Applet.LayoutFocusOptions
---@param ctx Applet.LayoutCompileContext
---@return Applet.LayoutFocus
local function normalize_tree_focus(value, ctx)
  value = value or {}
  fields(value, tree_focus_fields, "Applet layout.focus")
  if value.initial ~= nil then nonempty(value.initial, "Applet layout.focus.initial") end
  local intent
  if value.intent ~= nil then
    fields(value.intent, focus_intent_fields, "Applet layout.focus.intent")
    intent = {
      key = nonempty(value.intent.key, "Applet layout.focus.intent.key"),
      revision = value.intent.revision,
    }
    applet_expect(intent.revision == nil or type(intent.revision) == "string"
        or finite(intent.revision), "Applet layout.focus.intent.revision",
      "must be a finite number or string", 4)
  end
  local initial = value.initial or ctx.pane_order[1]
  applet_expect(initial == nil or ctx.panes[initial] ~= nil,
    "Applet layout.focus.initial", "must name a Pane", 4)
  applet_expect(intent == nil or ctx.panes[intent.key] ~= nil,
    "Applet layout.focus.intent.key", "must name a Pane", 4)
  return { initial = initial, intent = intent }
end

---@param opts Applet.LayoutCompileOptions
---@return Applet.CompiledLayout
function M.compile(opts)
  applet_expect(type(opts) == "table", "Applet.layout.compile",
    "options must be a table", 3)
  local tree = opts.tree
  fields(tree, tree_fields, "Applet layout")
  applet_expect(type(tree.root) == "table", "Applet layout.root",
    "must be a frame node", 3)
  local host = host_api.validate(opts.host)
  local editor = normalize_rect(opts.editor or {
    row = 0, col = 0, width = 80, height = 24,
  }, "Applet editor")
  local bounds, container = host_bounds(host, editor, opts.container)
  ---@type Applet.LayoutCompileContext
  local ctx = {
    host = host,
    editor = editor,
    bounds = bounds,
    container = container,
    measurements = opts.measurements or {},
    overrides = opts.overrides or {},
    handlers = opts.handlers or {},
    has_action = opts.has_action,
    active = {},
    node_keys = {},
    pane_keys = {},
    child_keys = {},
    mounted_panes = {},
    panes = {},
    pane_order = {},
    splits = {},
    split_order = {},
    layers = {},
    root_scopes = {},
  }
  applet_expect(type(ctx.measurements) == "table", "Applet measurements",
    "must be a table", 3)
  applet_expect(type(ctx.overrides) == "table", "Applet overrides",
    "must be a table", 3)
  applet_expect(type(ctx.handlers) == "table", "Applet handlers",
    "must be a table", 3)
  applet_expect(ctx.has_action == nil or type(ctx.has_action) == "function",
    "Applet has_action", "must be a function", 3)
  local root_bindings = normalize_bindings(tree.bindings,
    "Applet layout.bindings", ctx)
  if #root_bindings > 0 then
    ctx.root_scopes[1] = {
      key = "@applet:root",
      kind = "root",
      bindings = root_bindings,
    }
  end
  local frame = tree.root
  fields(frame, frame_fields, "Applet layout.root")
  applet_expect(frame.type == "frame", "Applet layout.root.type",
    "must be frame", 3)
  local frame_key = register_key(ctx.node_keys, frame.key, "Applet layout.root.key")
  applet_expect(type(frame.child) == "table", "Applet layout.root.child",
    "must be an Applet layout node", 3)
  local topology = layout_node(ctx, frame.child, bounds, {
    scopes = {}, layer = nil, layer_panes = nil, modal = false,
    zindex = host.base_zindex, focusable = true,
  }, "Applet layout.root.child")
  local declared_layers = frame.layers or {}
  applet_expect(type(declared_layers) == "table" and getmetatable(declared_layers) == nil,
    "Applet layout.root.layers", "must be a plain list", 3)
  for index, layer in ipairs(declared_layers) do
    applet_expect(type(layer) == "table" and layer.type == "layer",
      "Applet layout.root.layers." .. index, "must be a layer node", 3)
    project_layer(ctx, layer, index, "Applet layout.root.layers." .. index)
  end
  local layer_count = 0
  for _ in pairs(declared_layers) do layer_count = layer_count + 1 end
  applet_expect(layer_count == #declared_layers,
    "Applet layout.root.layers", "must be a dense list", 3)
  table.sort(ctx.layers, function(left, right)
    if left.zindex == right.zindex then return left.order < right.order end
    return left.zindex < right.zindex
  end)
  local modal_index
  for index, layer in ipairs(ctx.layers) do
    if layer.modal then modal_index = index end
  end
  local modal_boundary = {}
  if modal_index then
    for index = modal_index, #ctx.layers do
      for _, key in ipairs(ctx.layers[index].panes) do modal_boundary[#modal_boundary + 1] = key end
    end
  end
  if #modal_boundary > 0 then
    local allowed = {}
    for _, key in ipairs(modal_boundary) do allowed[key] = true end
    for key, pane in pairs(ctx.panes) do
      if pane.projection.kind == "floating" then
        local projection = pane.projection --[[@as Applet.FloatingProjection]]
        projection.config.focusable = allowed[key] == true
      end
    end
  end
  local focus = normalize_tree_focus(tree.focus, ctx)
  for index = #ctx.layers, 1, -1 do
    local layer = ctx.layers[index]
    if layer.enter and #layer.panes > 0 then
      focus.layer_entry = layer.panes[1]
      break
    end
  end
  if #modal_boundary > 0 then
    local allowed = {}
    for _, key in ipairs(modal_boundary) do allowed[key] = true end
    if focus.intent then
      applet_expect(allowed[focus.intent.key], "Applet layout.focus.intent.key",
        "must target the active modal boundary", 3)
    end
    if not focus.layer_entry or not allowed[focus.layer_entry] then
      focus.layer_entry = modal_boundary[1]
    end
  end
  return {
    host = host,
    plan = {
      kind = host.kind,
      bounds = copy_rect(bounds),
      container = copy_rect(container),
      topology = topology,
    },
    frame = { key = frame_key },
    bounds = copy_rect(bounds),
    topology = topology,
    panes = ctx.panes,
    pane_order = ctx.pane_order,
    splits = ctx.splits,
    split_order = ctx.split_order,
    layers = ctx.layers,
    modal_boundary = modal_boundary,
    bindings = root_bindings,
    focus = focus,
  }
end

return M
