local util = require("applet.util")

local ansi_palette = {
  0x000000, 0xcd0000, 0x00cd00, 0xcdcd00,
  0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
  0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00,
  0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
}

local Palette = {}
Palette.__index = Palette

local Theme = {}
Theme.__index = Theme
local next_theme_id = 0

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function rgb_cterm(value)
  local red = math.floor(value / 0x10000) % 0x100
  local green = math.floor(value / 0x100) % 0x100
  local blue = value % 0x100
  return 16 + math.floor(red * 5 / 255 + 0.5) * 36
    + math.floor(green * 5 / 255 + 0.5) * 6
    + math.floor(blue * 5 / 255 + 0.5)
end

local function color_number(value)
  if type(value) == "number" and value >= 0 and value <= 0xffffff then
    return math.floor(value)
  end
  if type(value) ~= "string" then return nil end
  local hex = value:match("^#(%x%x%x%x%x%x)$")
  if hex then return tonumber(hex, 16) end
  local resolved = vim.api.nvim_get_color_by_name(value)
  if resolved and resolved >= 0 then return resolved end
end

function Palette.new(theme)
  return setmetatable({ theme = theme }, Palette)
end

function Palette:group(name)
  util.expect(util.nonempty_string(name), "palette group",
    "must be a non-empty string", 3)
  local resolved = self.theme and self.theme:group(name) or name
  local ok, value = pcall(vim.api.nvim_get_hl, 0, {
    name = resolved,
    link = false,
  })
  return ok and util.copy(value) or {}
end

function Palette:is_light()
  return vim.o.background == "light"
end

function Palette:terminal(index)
  util.expect(type(index) == "number" and index >= 0 and index <= 255
      and index % 1 == 0, "terminal color",
    "must be an integral palette index from 0 through 255", 3)
  local configured = index < 16 and vim.g["terminal_color_" .. index] or nil
  local resolved = color_number(configured)
  if resolved then return resolved end
  if index < 16 then return ansi_palette[index + 1] end
  if index < 232 then
    local value = index - 16
    local levels = { 0, 95, 135, 175, 215, 255 }
    local red = levels[math.floor(value / 36) + 1]
    local green = levels[math.floor(value / 6) % 6 + 1]
    local blue = levels[value % 6 + 1]
    return red * 0x10000 + green * 0x100 + blue
  end
  local level = 8 + (index - 232) * 10
  return level * 0x10000 + level * 0x100 + level
end

function Palette:color(value)
  return color_number(value)
end

function Palette:rgb(value)
  local color = self:color(value)
  if not color then return nil end
  return {
    red = math.floor(color / 0x10000) % 0x100,
    green = math.floor(color / 0x100) % 0x100,
    blue = color % 0x100,
  }
end

function Palette:cterm(value)
  local color = self:color(value)
  return color and rgb_cterm(color) or nil
end

function Palette:blend(background, foreground, alpha)
  background = self:color(background)
  foreground = self:color(foreground)
  util.expect(background ~= nil and foreground ~= nil, "palette blend",
    "requires resolvable colors", 3)
  util.expect(finite(alpha) and alpha >= 0 and alpha <= 1,
    "palette blend alpha", "must be in [0, 1]", 3)
  local result = 0
  for _, shift in ipairs({ 0x10000, 0x100, 1 }) do
    local bottom = math.floor(background / shift) % 0x100
    local top = math.floor(foreground / shift) % 0x100
    result = result + math.floor(top * alpha + bottom * (1 - alpha)) * shift
  end
  return result
end

local function normalized_highlight(palette, spec)
  util.expect(type(spec) == "table", "highlight", "must be a table", 4)
  local result = {}
  if spec.base ~= nil then
    util.expect(util.nonempty_string(spec.base), "highlight.base",
      "must be a non-empty string", 4)
    result = palette:group(spec.base)
  end
  for key, value in pairs(spec) do
    if key ~= "base" then result[key] = value end
  end
  for _, pair in ipairs({ { "fg", "ctermfg" }, { "bg", "ctermbg" },
    { "sp", nil } }) do
    local key, cterm = pair[1], pair[2]
    local value = result[key]
    if value ~= nil then
      local color = palette:color(value)
      if color then
        result[key] = color
        if cterm and result[cterm] == nil then result[cterm] = rgb_cterm(color) end
      end
    end
  end
  return result
end

function Theme.new(opts)
  if opts == nil then opts = {} end
  util.expect(type(opts) == "table", "theme", "must be a table", 3)
  util.expect(opts.name == nil or util.nonempty_string(opts.name),
    "theme.name", "must be a non-empty string", 3)
  util.expect(opts.groups == nil or type(opts.groups) == "table",
    "theme.groups", "must be a table", 3)
  util.expect(opts.highlights == nil or type(opts.highlights) == "table"
      or type(opts.highlights) == "function",
    "theme.highlights", "must be a table or function", 3)
  util.expect(opts.max_derived_highlights == nil
      or (type(opts.max_derived_highlights) == "number"
        and opts.max_derived_highlights >= 0
        and opts.max_derived_highlights % 1 == 0),
    "theme.max_derived_highlights",
    "must be a non-negative integral count", 3)
  next_theme_id = next_theme_id + 1
  local name = opts.name or "Applet"
  local prefix = name:gsub("[^%w]", "")
  if prefix == "" then prefix = "Applet" end
  return setmetatable({
    name = name,
    resource_prefix = prefix .. "Theme" .. next_theme_id,
    groups = util.copy(opts.groups),
    highlights = opts.highlights,
    generation = opts.generation or 0,
    max_derived_highlights = opts.max_derived_highlights or 256,
    derived = {},
    derived_order = {},
    palette = nil,
  }, Theme)
end

function Theme:group(style)
  if style == nil then return nil end
  util.expect(util.nonempty_string(style), "style", "must be a non-empty string", 3)
  return self.groups[style] or style
end

function Theme:colors()
  if not self.palette then self.palette = Palette.new(self) end
  return self.palette
end

function Theme:_definitions()
  local value = self.highlights
  if type(value) == "function" then value = value(self:colors()) end
  util.expect(value == nil or type(value) == "table", "theme.highlights",
    "callback must return a table", 3)
  return value or {}
end

function Theme:define()
  local palette = self:colors()
  for group, spec in pairs(self:_definitions()) do
    vim.api.nvim_set_hl(0, group, normalized_highlight(palette, spec))
  end
  for _, key in ipairs(self.derived_order) do
    local derived = self.derived[key]
    vim.api.nvim_set_hl(0, derived.group,
      normalized_highlight(palette, derived.spec))
  end
end

function Theme:derive(key, spec)
  util.expect(util.nonempty_string(key), "derived highlight key",
    "must be a non-empty string", 3)
  util.expect(type(spec) == "table", "derived highlight",
    "must be a table", 3)
  local current = self.derived[key]
  if current then return current.group end
  if #self.derived_order >= self.max_derived_highlights then
    return spec.base and self:group(spec.base) or nil
  end
  local group = self.resource_prefix .. "Derived"
    .. tostring(#self.derived_order + 1)
  self.derived[key] = { group = group, spec = util.copy(spec) }
  self.derived_order[#self.derived_order + 1] = key
  vim.api.nvim_set_hl(0, group,
    normalized_highlight(self:colors(), self.derived[key].spec))
  return group
end

Theme.Palette = Palette

return setmetatable({ new = Theme.new, Palette = Palette }, {
  __call = function(_, opts) return Theme.new(opts) end,
})
