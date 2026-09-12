local util = require("applet.util")
local applet_expect = util.expect

local M = {}

---@param value string
---@return integer
function M.width(value)
  applet_expect(type(value) == "string", "text", "must be a string", 3)
  return util.display_width(value)
end

---@param value string
---@param first integer
---@param last? integer
---@return string
function M.slice(value, first, last)
  applet_expect(type(value) == "string", "text", "must be a string", 3)
  applet_expect(
    type(first) == "number" and first >= 0 and first % 1 == 0,
    "first",
    "must be a non-negative integral display column",
    3
  )
  if last == nil then
    last = M.width(value)
  end
  applet_expect(
    type(last) == "number" and last >= first and last % 1 == 0,
    "last",
    "must be an integral display column at or after first",
    3
  )
  local result, column = {}, 0
  for _, character in ipairs(util.characters(value, "text")) do
    local width = util.display_width(character)
    if column >= first and column + width <= last then
      result[#result + 1] = character
    end
    column = column + width
    if column >= last then
      break
    end
  end
  return table.concat(result)
end

---@param value string
---@param width integer
---@param opts? {marker?: string, side?: "left"|"right"|"middle"}
---@return string
function M.truncate(value, width, opts)
  applet_expect(type(value) == "string", "text", "must be a string", 3)
  applet_expect(
    type(width) == "number" and width >= 0 and width % 1 == 0,
    "width",
    "must be a non-negative integral cell count",
    3
  )
  opts = opts or {}
  applet_expect(type(opts) == "table", "truncate options", "must be a table", 3)
  local marker = opts.marker == nil and "…" or opts.marker
  applet_expect(type(marker) == "string", "truncate marker", "must be a string", 3)
  if M.width(value) <= width then
    return value
  end
  local marker_width = M.width(marker)
  if marker_width > width then
    return M.slice(marker, 0, width)
  end
  local side = opts.side or "right"
  applet_expect(
    side == "right" or side == "left" or side == "middle",
    "truncate side",
    "must be right, left, or middle",
    3
  )
  local available = width - marker_width
  if side == "left" then
    local total = M.width(value)
    return marker .. M.slice(value, total - available, total)
  end
  if side == "middle" then
    local left = math.ceil(available / 2)
    local total = M.width(value)
    return M.slice(value, 0, left) .. marker .. M.slice(value, total - (available - left), total)
  end
  return M.slice(value, 0, available) .. marker
end

---@param value string
---@return string[]
function M.lines(value)
  applet_expect(type(value) == "string", "text", "must be a string", 3)
  local result = vim.split(value, "\n", { plain = true })
  return result
end

return M
