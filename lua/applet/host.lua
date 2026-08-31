local util = require("applet.util")

local M = {}

local floating_fields = {
  kind = true,
  container = true,
  side = true,
  width = true,
  height = true,
  margin = true,
  base_zindex = true,
}

local tab_fields = {
  kind = true,
  position = true,
  label = true,
}

local containers = { editor = true, largest_window = true, auto = true }
local sides = { left = true, right = true, top = true, bottom = true, center = true }
local tab_positions = { before = true, after = true, first = true, last = true }

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function dimension(value, path)
  util.expect(finite(value) and value > 0, path, "must be a positive finite number", 4)
  util.expect(value <= 1 or value % 1 == 0, path,
    "must be a fraction in (0, 1] or an integral cell count", 4)
end

local function fields(value, accepted, path)
  util.expect(getmetatable(value) == nil, path, "must be a plain table", 4)
  for key in pairs(value) do
    util.expect(accepted[key] == true, path .. "." .. tostring(key),
      "is not a recognized field", 4)
  end
end

function M.floating(opts)
  opts = opts or {}
  util.expect(type(opts) == "table", "Applet floating Host",
    "options must be a table", 3)
  fields(opts, floating_fields, "Applet floating Host")
  local result = {
    kind = "floating",
    container = opts.container or "editor",
    side = opts.side or "center",
    width = opts.width or 0.9,
    height = opts.height or 0.9,
    margin = opts.margin == nil and 1 or opts.margin,
    base_zindex = opts.base_zindex or 40,
  }
  util.expect(containers[result.container] == true,
    "Applet floating Host.container",
    "must be editor, largest_window, or auto", 3)
  util.expect(sides[result.side] == true, "Applet floating Host.side",
    "must be left, right, top, bottom, or center", 3)
  dimension(result.width, "Applet floating Host.width")
  dimension(result.height, "Applet floating Host.height")
  util.expect(finite(result.margin) and result.margin >= 0
      and result.margin % 1 == 0,
    "Applet floating Host.margin",
    "must be a non-negative integral cell count", 3)
  util.expect(finite(result.base_zindex) and result.base_zindex >= 1
      and result.base_zindex % 1 == 0,
    "Applet floating Host.base_zindex",
    "must be a positive integral value", 3)
  return result
end

function M.tab(opts)
  opts = opts or {}
  util.expect(type(opts) == "table", "Applet tab Host",
    "options must be a table", 3)
  fields(opts, tab_fields, "Applet tab Host")
  local result = {
    kind = "tab",
    position = opts.position or "after",
    label = opts.label or "Applet",
  }
  util.expect(tab_positions[result.position] == true,
    "Applet tab Host.position",
    "must be before, after, first, or last", 3)
  util.expect(util.nonempty_string(result.label), "Applet tab Host.label",
    "must be a non-empty string", 3)
  return result
end

function M.validate(value)
  util.expect(type(value) == "table", "Applet Host", "must be a table", 3)
  if value.kind == "floating" then return M.floating(value) end
  if value.kind == "tab" then return M.tab(value) end
  error("Applet Host.kind: must be floating or tab", 3)
end

return M
