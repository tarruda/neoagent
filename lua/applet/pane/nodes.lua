local util = require("applet.util")
local applet_expect = util.expect

---@class Applet.DataTable: table<string|number, Applet.Data>
---@alias Applet.Data nil|boolean|number|string|Applet.DataTable
---@alias Applet.TextWrap "word"|"character"|"none"|"native"
---@alias Applet.Alignment "left"|"center"|"right"
---@alias Applet.VirtualPosition "overlay"|"eol"|"right_align"|"inline"
---@alias Applet.VirtualPlacement "above"|"below"|"above-end"|"below-end"
---@alias Applet.OptionValue boolean|number|string
---@alias Applet.Options table<string, Applet.OptionValue>

---@class Applet.Insets
---@field top integer
---@field right integer
---@field bottom integer
---@field left integer

---@class Applet.PaddingOptions
---@field top? integer
---@field right? integer
---@field bottom? integer
---@field left? integer

---@alias Applet.Padding integer|Applet.PaddingOptions

---@class Applet.Action
---@field action string
---@field payload? Applet.Data

---@class Applet.Binding
---@field mode? string
---@field lhs string
---@field action Applet.Action
---@field count? boolean
---@field desc? string
---@field silent? boolean
---@field nowait? boolean

---@class Applet.RunGroup
---@field group? string
---@field style? string
---@field priority? integer

---@class Applet.TextRun: Applet.RunGroup
---@field text string
---@field groups? (string|Applet.RunGroup)[]

---@class Applet.FocusDecoration
---@field row integer|"end"
---@field col? integer
---@field chunks Applet.TextRun[]
---@field position? Applet.VirtualPosition
---@field win_col? integer
---@field priority? integer

---@class Applet.TargetFocus
---@field active? Applet.FocusDecoration[]
---@field inactive? Applet.FocusDecoration[]

---@class Applet.NodeOptions
---@field key string
---@field overflow? "error"|"clip"|"collapse"|"ellipsis"
---@field overflow_marker? Applet.Node
---@field collapse? Applet.Node
---@field clip_from? "start"|"end"

---@class Applet.RegionOptions: Applet.NodeOptions
---@field revision? string|number
---@field child Applet.Node

---@class Applet.TextOptions: Applet.NodeOptions
---@field text? string
---@field runs? Applet.TextRun[]
---@field wrap? Applet.TextWrap
---@field max_lines? integer
---@field overflow? "clip"|"ellipsis"
---@field tabstop? integer
---@field background? string

---@class Applet.ColumnOptions: Applet.NodeOptions
---@field children Applet.Node[]
---@field gap? integer

---@class Applet.RowChild
---@field node Applet.Node
---@field min_width? integer
---@field grow? number

---@class Applet.RowOptions: Applet.NodeOptions
---@field children (Applet.Node|Applet.RowChild)[]
---@field gap? integer
---@field width? integer

---@class Applet.PanelOptions: Applet.NodeOptions
---@field child Applet.Node
---@field padding? Applet.Padding
---@field background? string

---@class Applet.BorderOptions: Applet.RunGroup
---@field kind? "single"|"rounded"|"double"
---@field characters? string[]
---@field title? string
---@field title_pos? Applet.Alignment
---@field title_style? string
---@field title_group? string

---@alias Applet.Border false|"none"|"single"|"rounded"|"double"|Applet.BorderOptions

---@class Applet.ShadowOptions: Applet.RunGroup
---@field row? integer
---@field col? integer
---@field character? string

---@class Applet.ContainerOptions: Applet.NodeOptions
---@field child? Applet.Node
---@field width? integer
---@field height? integer
---@field padding? Applet.Padding
---@field background? string
---@field border? Applet.Border
---@field shadow? false|Applet.ShadowOptions
---@field position? Applet.ScenePosition
---@field layers? Applet.ContainerNode[]

---@class Applet.ResponsiveVariant
---@field node Applet.Node
---@field min_width? integer
---@field max_width? integer
---@field min_height? integer
---@field max_height? integer

---@class Applet.ResponsiveOptions: Applet.NodeOptions
---@field variants Applet.ResponsiveVariant[]

---@class Applet.SourceOptions: Applet.NodeOptions
---@field child Applet.Node
---@field path? string
---@field language? string

---@class Applet.ImageNodeOptions: Applet.NodeOptions
---@field source Applet.ImageSource
---@field alt string
---@field width? integer|"fill"|"native"
---@field height? integer|"auto"
---@field max_height? integer
---@field fit? Applet.ImageFit
---@field align? Applet.Alignment
---@field fallback? Applet.Node

---@class Applet.TargetOptions: Applet.NodeOptions
---@field child Applet.Node
---@field group? string
---@field role? string
---@field disabled? boolean
---@field action? Applet.Action
---@field focus_style? string
---@field focus? Applet.TargetFocus

---@class Applet.ScopeOptions: Applet.NodeOptions
---@field child Applet.Node
---@field modal? boolean
---@field bindings? Applet.Binding[]

---@class Applet.VirtualOptions: Applet.NodeOptions
---@field lines Applet.TextRun[][]
---@field placement? Applet.VirtualPlacement

---@class Applet.TargetIntent
---@field key string
---@field select string
---@field reveal? string

---@class Applet.ViewOptions
---@field scroll? "preserve"|"follow_end"
---@field initial_target? string
---@field target_intent? Applet.TargetIntent

---@class Applet.EditOptions
---@field on_change? Applet.Action
---@field mask? string

---@class Applet.ChromeOptions
---@field title? Applet.TextRun[]
---@field footer? Applet.TextRun[]
---@field title_pos? Applet.Alignment
---@field footer_pos? Applet.Alignment
---@field options? Applet.Options

---@class Applet.TreeOptions
---@field chrome? Applet.ChromeOptions
---@field view? Applet.ViewOptions
---@field edit? Applet.EditOptions

---@class Applet.Tree: Applet.TreeOptions
---@field root Applet.Node

---@class Applet.RegionNode: Applet.RegionOptions
---@field type "region"

---@class Applet.TextNode: Applet.TextOptions
---@field type "text"

---@class Applet.ColumnNode: Applet.ColumnOptions
---@field type "column"

---@class Applet.RowNode: Applet.RowOptions
---@field type "row"

---@class Applet.ContainerNode: Applet.ContainerOptions
---@field type "container"

---@class Applet.ResponsiveNode: Applet.ResponsiveOptions
---@field type "responsive"

---@class Applet.PanelNode: Applet.PanelOptions
---@field type "panel"

---@class Applet.SourceNode: Applet.SourceOptions
---@field type "source"

---@class Applet.ImageNode: Applet.ImageNodeOptions
---@field type "image"

---@class Applet.TargetNode: Applet.TargetOptions
---@field type "target"

---@class Applet.ScopeNode: Applet.ScopeOptions
---@field type "scope"

---@class Applet.VirtualNode: Applet.VirtualOptions
---@field type "virtual"

---@alias Applet.Node
---| Applet.RegionNode
---| Applet.TextNode
---| Applet.ColumnNode
---| Applet.RowNode
---| Applet.ContainerNode
---| Applet.ResponsiveNode
---| Applet.PanelNode
---| Applet.SourceNode
---| Applet.ImageNode
---| Applet.TargetNode
---| Applet.ScopeNode
---| Applet.VirtualNode


local M = {}

---@generic K: string, T: table
---@param kind K
---@param opts T
---@return T & {type: K}
local function node(kind, opts)
  applet_expect(type(opts) == "table", kind, "options must be a table", 4)
  local result = util.copy(opts)
  ---@cast result T & {type: K}
  result.type = kind
  return result
end

---@param opts Applet.RegionOptions
---@return Applet.RegionNode
function M.region(opts)
  return node("region", opts)
end

---@param opts Applet.TextOptions
---@return Applet.TextNode
function M.text(opts)
  return node("text", opts)
end

---@param opts Applet.ColumnOptions
---@return Applet.ColumnNode
function M.column(opts)
  return node("column", opts)
end

---@param opts Applet.RowOptions
---@return Applet.RowNode
function M.row(opts)
  return node("row", opts)
end

---@param opts Applet.ContainerOptions
---@return Applet.ContainerNode
function M.container(opts)
  return node("container", opts)
end

---@param opts Applet.ResponsiveOptions
---@return Applet.ResponsiveNode
function M.responsive(opts)
  return node("responsive", opts)
end

---@param opts Applet.PanelOptions
---@return Applet.PanelNode
function M.panel(opts)
  return node("panel", opts)
end

---@param opts Applet.SourceOptions
---@return Applet.SourceNode
function M.source(opts)
  return node("source", opts)
end

---@param opts Applet.ImageNodeOptions
---@return Applet.ImageNode
function M.image(opts)
  return node("image", opts)
end

---@param opts Applet.TargetOptions
---@return Applet.TargetNode
function M.target(opts)
  return node("target", opts)
end

---@param opts Applet.ScopeOptions
---@return Applet.ScopeNode
function M.scope(opts)
  return node("scope", opts)
end

---@param opts Applet.VirtualOptions
---@return Applet.VirtualNode
function M.virtual(opts)
  return node("virtual", opts)
end

---@generic T: Applet.Data
---@param name string
---@param payload? T
---@return Applet.Action & {payload?: T}
function M.action(name, payload)
  applet_expect(util.nonempty_string(name), "action", "name must be a non-empty string", 3)
  return { action = name, payload = payload }
end

---@param root Applet.Node
---@param opts? Applet.TreeOptions
---@return Applet.Tree
function M.tree(root, opts)
  applet_expect(type(root) == "table", "tree.root", "must be a node", 3)
  ---@type Applet.Tree
  local result = util.copy(opts or {})
  result.root = root
  return result
end

return M
