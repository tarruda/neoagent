local Pane = require("applet.pane")
local util = require("applet.util")

---@alias Applet.LayoutAxis 'vertical'|'horizontal'
---@alias Applet.MountLifecycle 'retained'|'transient'
---@alias Applet.LayerAnchor 'center'|'top'|'bottom'|'left'|'right'|'top_left'|'top_right'|'bottom_left'|'bottom_right'
---@alias Applet.WindowBorder string|(string|string[])[]

---@class Applet.ContentDimension
---@field content true|integer
---@field min? number
---@field max? number

---@alias Applet.LayoutDimension number|Applet.ContentDimension

---@class Applet.MountBufferOptions
---@field name? string
---@field uri? string
---@field filetype? string
---@field sensitive? boolean
---@field options? Applet.Options

---@class Applet.MountWindowOptions
---@field border? Applet.WindowBorder
---@field options? Applet.Options
---@field host_options? {floating?: Applet.Options, tab?: Applet.Options}

---@class Applet.MountFocusOptions
---@field mode? 'normal'|'insert'|'preserve'
---@field cursor? 'preserve'|'start'|'end'

---@class Applet.MountOptions
---@field lifecycle? Applet.MountLifecycle
---@field owns_pane? boolean
---@field required? boolean
---@field mount_revision? number|string
---@field buffer? Applet.MountBufferOptions
---@field window? Applet.MountWindowOptions
---@field focus? Applet.MountFocusOptions
---@field bindings? Applet.Binding[]

---@class Applet.MountNode: Applet.MountOptions
---@field type 'mount'
---@field pane Applet.Pane

---@class Applet.LayoutScopeOptions
---@field key string
---@field bindings? Applet.Binding[]
---@field child Applet.LayoutNode

---@class Applet.LayoutScopeNode: Applet.LayoutScopeOptions
---@field type 'scope'

---@class Applet.LayoutSplitChild
---@field key string
---@field basis? Applet.LayoutDimension
---@field grow? number
---@field shrink? number
---@field min? number
---@field max? number
---@field child Applet.LayoutNode

---@class Applet.LayoutSplitOptions
---@field key string
---@field axis Applet.LayoutAxis
---@field revision? string|number
---@field children Applet.LayoutSplitChild[]

---@class Applet.LayoutSplitNode: Applet.LayoutSplitOptions
---@field type 'split'

---@alias Applet.LayoutNode Applet.MountNode|Applet.LayoutScopeNode|Applet.LayoutSplitNode

---@class Applet.LayoutLayerOptions
---@field key string
---@field container? string
---@field anchor? Applet.LayerAnchor
---@field width? Applet.LayoutDimension
---@field height? Applet.LayoutDimension
---@field zindex? integer
---@field modal? boolean
---@field enter? boolean
---@field restore_focus? boolean
---@field child Applet.LayoutNode

---@class Applet.LayoutLayerNode: Applet.LayoutLayerOptions
---@field type 'layer'

---@class Applet.LayoutFrameOptions
---@field key string
---@field child Applet.LayoutNode
---@field layers? Applet.LayoutLayerNode[]

---@class Applet.LayoutFrameNode: Applet.LayoutFrameOptions
---@field type 'frame'

---@class Applet.LayoutFocusOptions
---@field initial? string
---@field intent? {key: string, revision?: string|number}

---@class Applet.LayoutTree
---@field root Applet.LayoutFrameNode
---@field bindings? Applet.Binding[]
---@field focus? Applet.LayoutFocusOptions

---@class Applet.LayoutModule
local M = {}

---@generic T: table
---@param kind string
---@param opts T
---@return T
local function node(kind, opts)
  util.expect(type(opts) == "table", "Applet " .. kind,
    "options must be a table", 4)
  local result = util.copy(opts)
  result.type = kind
  return result
end

---@param opts Applet.LayoutFrameOptions
---@return Applet.LayoutFrameNode
function M.frame(opts)
  return node("frame", opts) --[[@as Applet.LayoutFrameNode]]
end

---@param opts Applet.LayoutSplitOptions
---@return Applet.LayoutSplitNode
function M.split(opts)
  return node("split", opts) --[[@as Applet.LayoutSplitNode]]
end

---@param opts Applet.LayoutScopeOptions
---@return Applet.LayoutScopeNode
function M.scope(opts)
  return node("scope", opts) --[[@as Applet.LayoutScopeNode]]
end

---@param opts Applet.LayoutLayerOptions
---@return Applet.LayoutLayerNode
function M.layer(opts)
  return node("layer", opts) --[[@as Applet.LayoutLayerNode]]
end

---@param pane Applet.Pane
---@param opts? Applet.MountOptions
---@return Applet.MountNode
function M.mount(pane, opts)
  util.expect(Pane.is(pane), "Applet mount.pane",
    "must be a Pane instance", 3)
  opts = opts or {}
  util.expect(type(opts) == "table", "Applet mount",
    "options must be a table", 3)
  local result = node("mount", opts) --[[@as Applet.MountNode]]
  result.pane = pane
  return result
end

M.compile = require("applet.layout.compile").compile

return M
