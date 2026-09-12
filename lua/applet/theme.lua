local util = require("applet.util")
local applet_expect = util.expect

---@alias Applet.Color string|number

---@class Applet.Highlight: vim.api.keyset.highlight
---@field base? string
---@field fg? Applet.Color
---@field bg? Applet.Color
---@field sp? Applet.Color
---@field foreground? Applet.Color
---@field background? Applet.Color
---@field special? Applet.Color
---@field ctermfg? integer
---@field ctermbg? integer

---@alias Applet.HighlightDefinitions table<string, Applet.Highlight>
---@alias Applet.Highlights Applet.HighlightDefinitions|fun(palette: Applet.Palette): Applet.HighlightDefinitions?

---@class Applet.ThemeOptions
---@field name? string
---@field groups? table<string, string>
---@field highlights? Applet.Highlights
---@field generation? integer
---@field max_derived_highlights? integer

---@class Applet.DerivedHighlight
---@field group string
---@field spec Applet.Highlight

local ansi_palette = {
  0x000000,
  0xcd0000,
  0x00cd00,
  0xcdcd00,
  0x0000ee,
  0xcd00cd,
  0x00cdcd,
  0xe5e5e5,
  0x7f7f7f,
  0xff0000,
  0x00ff00,
  0xffff00,
  0x5c5cff,
  0xff00ff,
  0x00ffff,
  0xffffff,
}

---@class Applet.Palette
---@field theme? Applet.Theme
local Palette = {}
Palette.__index = Palette

---@class Applet.CompileTheme
---@field generation integer
---@field group fun(self: Applet.CompileTheme, style: string): string

---@class Applet.Theme: Applet.CompileTheme
---@field name string
---@field resource_prefix string
---@field groups table<string, string>
---@field highlights? Applet.Highlights
---@field generation integer
---@field max_derived_highlights integer
---@field derived table<string, Applet.DerivedHighlight>
---@field derived_order string[]
---@field palette? Applet.Palette
local Theme = {}
Theme.__index = Theme
local next_theme_id = 0

---@param value unknown
---@return TypeGuard<number>
local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

---@param value integer
---@return integer
local function rgb_cterm(value)
  local red = math.floor(value / 0x10000) % 0x100
  local green = math.floor(value / 0x100) % 0x100
  local blue = value % 0x100
  return 16
    + math.floor(red * 5 / 255 + 0.5) * 36
    + math.floor(green * 5 / 255 + 0.5) * 6
    + math.floor(blue * 5 / 255 + 0.5)
end

---@param value unknown
---@return integer?
local function color_number(value)
  if type(value) == "number" and value >= 0 and value <= 0xffffff then
    return math.floor(value)
  end
  if type(value) ~= "string" then
    return nil
  end
  local hex = value:match("^#(%x%x%x%x%x%x)$")
  if hex then
    return tonumber(hex, 16)
  end
  local resolved = vim.api.nvim_get_color_by_name(value)
  if resolved and resolved >= 0 then
    return resolved
  end
end

---@param theme? Applet.Theme
---@return Applet.Palette
function Palette.new(theme)
  return setmetatable({ theme = theme }, Palette)
end

---@param name string
---@return vim.api.keyset.hl_info
function Palette:group(name)
  applet_expect(util.nonempty_string(name), "palette group", "must be a non-empty string", 3)
  local resolved = self.theme and self.theme:group(name) or name
  local ok, value = pcall(vim.api.nvim_get_hl, 0, {
    name = resolved,
    link = false,
  })
  return ok and util.copy(value) or {}
end

---@return boolean
function Palette:is_light()
  return vim.o.background == "light"
end

---@param index integer
---@return integer
local function cube_channel(index)
  return index == 0 and 0 or 55 + 40 * index
end

---@param index integer
---@return integer
function Palette:terminal(index)
  applet_expect(
    type(index) == "number" and index >= 0 and index <= 255 and index % 1 == 0,
    "terminal color",
    "must be an integral palette index from 0 through 255",
    3
  )
  local configured = index < 16 and vim.g["terminal_color_" .. index] or nil
  local resolved = color_number(configured)
  if resolved then
    return resolved
  end
  if index < 16 then
    -- The validated ANSI index addresses one of the sixteen palette entries.
    local color = ansi_palette[index + 1]
    ---@cast color integer
    return color
  end
  if index < 232 then
    local value = index - 16
    local red = cube_channel(math.floor(value / 36))
    local green = cube_channel(math.floor(value / 6) % 6)
    local blue = cube_channel(value % 6)
    return red * 0x10000 + green * 0x100 + blue
  end
  local level = 8 + (index - 232) * 10
  return level * 0x10000 + level * 0x100 + level
end

---@param value unknown
---@return integer?
function Palette:color(value)
  return color_number(value)
end

---@param value unknown
---@return {red: integer, green: integer, blue: integer}?
function Palette:rgb(value)
  local color = self:color(value)
  if not color then
    return nil
  end
  return {
    red = math.floor(color / 0x10000) % 0x100,
    green = math.floor(color / 0x100) % 0x100,
    blue = color % 0x100,
  }
end

---@param value unknown
---@return integer?
function Palette:cterm(value)
  local color = self:color(value)
  return color and rgb_cterm(color) or nil
end

---@param background Applet.Color
---@param foreground Applet.Color
---@param alpha number
---@return integer
function Palette:blend(background, foreground, alpha)
  local bottom_color = self:color(background)
  local top_color = self:color(foreground)
  applet_expect(bottom_color ~= nil and top_color ~= nil, "palette blend", "requires resolvable colors", 3)
  applet_expect(finite(alpha) and alpha >= 0 and alpha <= 1, "palette blend alpha", "must be in [0, 1]", 3)
  local result = 0
  for _, shift in ipairs({ 0x10000, 0x100, 1 }) do
    local bottom = math.floor(bottom_color / shift) % 0x100
    local top = math.floor(top_color / shift) % 0x100
    result = result + math.floor(top * alpha + bottom * (1 - alpha)) * shift
  end
  return result
end

---@param palette Applet.Palette
---@param spec Applet.Highlight
---@return Applet.Highlight
local function normalized_highlight(palette, spec)
  applet_expect(type(spec) == "table", "highlight", "must be a table", 4)
  ---@type Applet.Highlight
  local result = util.copy(spec)
  result.base = nil
  if spec.base ~= nil then
    applet_expect(util.nonempty_string(spec.base), "highlight.base", "must be a non-empty string", 4)
    result = vim.tbl_extend("force", palette:group(spec.base), result)
  end
  for _, pair in ipairs({ { "fg", "ctermfg" }, { "bg", "ctermbg" }, { "sp", nil } }) do
    local key, cterm = pair[1], pair[2]
    local value = result[key]
    if value ~= nil then
      local color = palette:color(value)
      if color then
        result[key] = color
        if cterm and result[cterm] == nil then
          result[cterm] = rgb_cterm(color)
        end
      end
    end
  end
  return result
end

---@param opts? Applet.ThemeOptions
---@return Applet.Theme
function Theme.new(opts)
  if opts == nil then
    opts = {}
  end
  applet_expect(type(opts) == "table", "theme", "must be a table", 3)
  applet_expect(opts.name == nil or util.nonempty_string(opts.name), "theme.name", "must be a non-empty string", 3)
  applet_expect(opts.groups == nil or type(opts.groups) == "table", "theme.groups", "must be a table", 3)
  applet_expect(
    opts.highlights == nil or type(opts.highlights) == "table" or type(opts.highlights) == "function",
    "theme.highlights",
    "must be a table or function",
    3
  )
  applet_expect(
    opts.max_derived_highlights == nil
      or (
        type(opts.max_derived_highlights) == "number"
        and opts.max_derived_highlights >= 0
        and opts.max_derived_highlights % 1 == 0
      ),
    "theme.max_derived_highlights",
    "must be a non-negative integral count",
    3
  )
  next_theme_id = next_theme_id + 1
  local name = opts.name or "Applet"
  local prefix = name:gsub("[^%w]", "")
  if prefix == "" then
    prefix = "Applet"
  end
  return setmetatable({
    name = name,
    resource_prefix = prefix .. "Theme" .. next_theme_id,
    groups = util.copy(opts.groups or {}),
    highlights = opts.highlights,
    generation = opts.generation or 0,
    max_derived_highlights = opts.max_derived_highlights or 256,
    derived = {},
    derived_order = {},
    palette = nil,
  }, Theme)
end

---@overload fun(self: Applet.Theme, style: string): string
---@param style? string
---@return string?
function Theme:group(style)
  if style == nil then
    return nil
  end
  applet_expect(util.nonempty_string(style), "style", "must be a non-empty string", 3)
  return self.groups[style] or style
end

---@return Applet.Palette
function Theme:colors()
  if not self.palette then
    self.palette = Palette.new(self)
  end
  return self.palette
end

---@return Applet.HighlightDefinitions
function Theme:_definitions()
  local value = self.highlights
  if type(value) == "function" then
    value = value(self:colors())
  end
  applet_expect(value == nil or type(value) == "table", "theme.highlights", "callback must return a table", 3)
  return value or {}
end

function Theme:define()
  local palette = self:colors()
  for group, spec in pairs(self:_definitions()) do
    vim.api.nvim_set_hl(0, group, normalized_highlight(palette, spec))
  end
  for _, key in ipairs(self.derived_order) do
    local derived = self.derived[key]
    vim.api.nvim_set_hl(0, derived.group, normalized_highlight(palette, derived.spec))
  end
end

---@param key string
---@param spec Applet.Highlight
---@return string?
function Theme:derive(key, spec)
  applet_expect(util.nonempty_string(key), "derived highlight key", "must be a non-empty string", 3)
  applet_expect(type(spec) == "table", "derived highlight", "must be a table", 3)
  local current = self.derived[key]
  if current then
    return current.group
  end
  if #self.derived_order >= self.max_derived_highlights then
    return spec.base and self:group(spec.base) or nil
  end
  local group = self.resource_prefix .. "Derived" .. tostring(#self.derived_order + 1)
  self.derived[key] = { group = group, spec = util.copy(spec) }
  self.derived_order[#self.derived_order + 1] = key
  vim.api.nvim_set_hl(0, group, normalized_highlight(self:colors(), self.derived[key].spec))
  return group
end

Theme.Palette = Palette

---@class Applet.ThemeModule
---@field new fun(opts?: Applet.ThemeOptions): Applet.Theme
local module = { new = Theme.new, Palette = Palette }

return setmetatable(module, {
  __call = function(_, opts)
    return Theme.new(opts)
  end,
}) --[[@as Applet.ThemeModule]]
