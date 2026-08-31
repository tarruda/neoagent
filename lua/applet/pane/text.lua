local util = require("applet.util")

local M = {}

function M.width(value)
  util.expect(type(value) == "string", "text", "must be a string", 3)
  return util.display_width(value)
end

function M.slice(value, first, last)
  util.expect(type(value) == "string", "text", "must be a string", 3)
  util.expect(type(first) == "number" and first >= 0 and first % 1 == 0,
    "first", "must be a non-negative integral display column", 3)
  if last == nil then last = M.width(value) end
  util.expect(type(last) == "number" and last >= first and last % 1 == 0,
    "last", "must be an integral display column at or after first", 3)
  local result, column = {}, 0
  for _, character in ipairs(util.characters(value, "text")) do
    local width = util.display_width(character)
    if column >= first and column + width <= last then
      result[#result + 1] = character
    end
    column = column + width
    if column >= last then break end
  end
  return table.concat(result)
end

function M.truncate(value, width, opts)
  util.expect(type(value) == "string", "text", "must be a string", 3)
  util.expect(type(width) == "number" and width >= 0 and width % 1 == 0,
    "width", "must be a non-negative integral cell count", 3)
  opts = opts or {}
  util.expect(type(opts) == "table", "truncate options", "must be a table", 3)
  local marker = opts.marker == nil and "…" or opts.marker
  util.expect(type(marker) == "string", "truncate marker", "must be a string", 3)
  if M.width(value) <= width then return value end
  local marker_width = M.width(marker)
  if marker_width > width then return M.slice(marker, 0, width) end
  local side = opts.side or "right"
  util.expect(side == "right" or side == "left" or side == "middle",
    "truncate side", "must be right, left, or middle", 3)
  local available = width - marker_width
  if side == "left" then
    local total = M.width(value)
    return marker .. M.slice(value, total - available, total)
  end
  if side == "middle" then
    local left = math.ceil(available / 2)
    local total = M.width(value)
    return M.slice(value, 0, left) .. marker
      .. M.slice(value, total - (available - left), total)
  end
  return M.slice(value, 0, available) .. marker
end

function M.lines(value)
  util.expect(type(value) == "string", "text", "must be a string", 3)
  local result = vim.split(value, "\n", { plain = true })
  return result
end

return M
