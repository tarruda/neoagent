local canvas = require("applet.pane.canvas")
local util = require("applet.util")
local applet_expect = util.expect

local M = {}

---@class Applet.Decoration
---@field row integer
---@field col integer
---@field group string
---@field end_col? integer
---@field whole_line? boolean
---@field priority? integer

---@class Applet.DecoratedLines
---@field lines string[]
---@field decorations Applet.Decoration[]

---@class Applet.SceneLayer: Applet.CanvasLayer
---@field fragment Applet.DecoratedLines
---@field coverage Applet.CellCoverage
---@field key? string
---@field width integer
---@field position_offset? integer

---@class Applet.Scene
---@field key string
---@field width integer
---@field height integer
---@field layers Applet.SceneLayer[]
---@field positions table<string, integer>
---@field retained boolean
---@field spatial? boolean
---@field revision? integer

---@class Applet.SceneSurface
---@field buffer integer
---@field window? fun(): integer?

---@class Applet.SceneBinding
---@field scene Applet.Scene
---@field surface Applet.SceneSurface
---@field layers Applet.SceneLayer[]

---@class Applet.SceneProvider
---@field namespace integer
---@field binding? Applet.SceneBinding

---@class Applet.ScenePosition
---@field mode? "absolute"
---@field row? integer
---@field col? integer
---@field zindex? integer

---@class Applet.CellDecoration
---@field first integer
---@field last number
---@field group string
---@field priority integer
---@field order integer

---@type table<Applet.DecoratedLines, table<integer, Applet.CellDecoration[]>>
local prepared = setmetatable({}, { __mode = "k" })

---@param scene Applet.Scene
---@return Applet.SceneLayer[]
local function sorted_layers(scene)
  local layers = vim.list_slice(scene.layers)
  table.sort(layers, function(left, right)
    if left.zindex ~= right.zindex then return left.zindex < right.zindex end
    return left.order < right.order
  end)
  return layers
end

---@param fragment Applet.DecoratedLines
---@param row integer
---@return Applet.CellDecoration[]
local function decoration_cells(fragment, row)
  local cached = prepared[fragment]
  if not cached then
    cached = {}
    prepared[fragment] = cached
  end
  if cached[row + 1] then return cached[row + 1] end

  local line = fragment.lines[row + 1] or ""
  local values = {}
  for index, decoration in ipairs(fragment.decorations) do
    if decoration.row == row then
      local first = decoration.whole_line and 0
        or util.display_width(line:sub(1, decoration.col))
      local last = decoration.whole_line and math.huge
        or decoration.end_col
          and util.display_width(line:sub(1, decoration.end_col))
          or math.huge
      values[#values + 1] = {
        first = first,
        last = last,
        group = decoration.group,
        priority = decoration.priority or 100,
        order = index,
      }
    end
  end
  cached[row + 1] = values
  return values
end

---@param decorations Applet.CellDecoration[]
---@param col integer
---@return string
local function group_at(decorations, col)
  local group, priority, order = "Normal", -1, -1
  for _, decoration in ipairs(decorations) do
    if col >= decoration.first and col < decoration.last
        and (decoration.priority > priority
          or decoration.priority == priority and decoration.order > order) then
      group, priority, order = decoration.group,
        decoration.priority, decoration.order
    end
  end
  return group
end

---@param fragment Applet.DecoratedLines
---@param row integer
---@param first integer
---@param last integer
---@return [string, string][]
local function chunks(fragment, row, first, last)
  local decorations = decoration_cells(fragment, row)
  local result, cursor = {}, first
  while cursor < last do
    local group = group_at(decorations, cursor)
    local edge = cursor + 1
    while edge < last and group_at(decorations, edge) == group do
      edge = edge + 1
    end
    result[#result + 1] = {
      canvas.slice(fragment.lines, row, cursor, edge),
      group,
    }
    cursor = edge
  end
  return result
end

---@param binding Applet.SceneBinding
---@param namespace integer
---@param layer Applet.SceneLayer
---@param row integer
---@param priority integer
local function draw_layer(binding, namespace, layer, row, priority)
  local source_row = row - layer.row
  local intervals = layer.coverage[source_row]
  if not intervals then return end
  local clip = layer.clip or {
    row = 0,
    col = 0,
    width = binding.scene.width,
    height = binding.scene.height,
  }
  if row < clip.row or row >= clip.row + clip.height then return end
  local clip_first = math.max(0, clip.col)
  local clip_last = math.min(binding.scene.width, clip.col + clip.width)
  for _, interval in ipairs(intervals) do
    local first = math.max(clip_first, layer.col + interval.first)
    local last = math.min(clip_last, layer.col + interval.last)
    if first < last then
      vim.api.nvim_buf_set_extmark(binding.surface.buffer,
        namespace, row, 0, {
          ephemeral = true,
          virt_text = chunks(layer.fragment, source_row,
            first - layer.col, last - layer.col),
          virt_text_win_col = first,
          hl_mode = "replace",
          priority = priority,
          strict = false,
        })
    end
  end
end

---@param namespace integer
---@return Applet.SceneProvider
function M.attach(namespace)
  ---@type Applet.SceneProvider
  local provider = { namespace = namespace }
  vim.api.nvim_set_decoration_provider(namespace, {
    on_win = function(_, window, buffer)
      local binding = provider.binding
      if not binding then return false end
      local surface = binding.surface
      local target = surface.window and surface.window()
      return target == window and surface.buffer == buffer
    end,
    on_line = function(_, _, buffer, row)
      local binding = provider.binding
      if not binding or binding.surface.buffer ~= buffer
          or row < 0 or row >= binding.scene.height then return end
      for index, layer in ipairs(binding.layers) do
        draw_layer(binding, namespace, layer, row, 1000 + index)
      end
    end,
  })
  return provider
end

---@param provider Applet.SceneProvider
---@param surface Applet.SceneSurface
---@param retained Applet.Scene
function M.update(provider, surface, retained)
  assert(provider and surface and retained and retained.retained,
    "retained scene update requires a provider, surface, and scene")
  provider.binding = {
    surface = surface, scene = retained, layers = sorted_layers(retained),
  }
  local window = surface.window and surface.window()
  if window and vim.api.nvim_win_is_valid(window) then
    vim.api.nvim__redraw({
      win = window,
      range = { 0, retained.height },
      valid = false,
    })
  end
end

---@generic S: Applet.Scene
---@param current S
---@param key string
---@param position Applet.ScenePosition
---@return S
function M.reposition(current, key, position)
  applet_expect(type(current) == "table" and current.retained == true,
    "scene", "must be retained placement state", 3)
  applet_expect(util.nonempty_string(key), "scene.position.key",
    "must be a non-empty string", 3)
  applet_expect(type(position) == "table", "scene.position",
    "must be a table", 3)
  if position.mode ~= nil then
    applet_expect(position.mode == "absolute", "scene.position.mode",
      "must be absolute", 3)
  end
  for field in pairs(position) do
    applet_expect(field == "mode" or field == "row" or field == "col"
        or field == "zindex", "scene.position." .. tostring(field),
      "is unknown", 3)
  end
  local index = current.positions and current.positions[key]
  applet_expect(type(index) == "number", "scene.position.key",
    ("does not identify a positioned container: %q"):format(key), 3)
  for _, field in ipairs({ "row", "col", "zindex" }) do
    local value = position[field]
    if value ~= nil then
      applet_expect(type(value) == "number" and value % 1 == 0,
        "scene.position." .. field, "must be an integer", 3)
    end
  end

  local result = util.copy(current)
  result.layers = vim.list_slice(current.layers)
  -- Compiled position indices refer to entries in this scene's layer array.
  local original = result.layers[index]
  ---@cast original Applet.SceneLayer
  local layer = util.copy(original)
  local offset = layer.position_offset or 0
  if position.row ~= nil then layer.row = offset + position.row end
  if position.col ~= nil then layer.col = offset + position.col end
  if position.zindex ~= nil then layer.zindex = position.zindex end
  result.layers[index] = layer
  result.revision = (current.revision or 0) + 1
  return result --[[@as S]]
end

---@param provider? Applet.SceneProvider
function M.clear(provider)
  if not provider then return end
  provider.binding = nil
  vim.api.nvim_set_decoration_provider(provider.namespace, {})
end

---@param scene Applet.Scene
---@return string[]
function M.lines(scene)
  local line = string.rep(" ", scene.width)
  local result = {}
  for _ = 1, scene.height do result[#result + 1] = line end
  return result
end

return M
