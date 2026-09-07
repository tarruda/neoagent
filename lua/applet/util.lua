local M = {}

---@alias Applet.NoValue nil
---@alias Applet.Copied<T> T extends Applet.NoValue and table or T

---@generic T: table|nil
---@param value T
---@return Applet.Copied<T>
function M.copy(value)
  local result = {}
  local source = value or {}
  -- The generic input is a table or nil; the fallback removes nil.
  ---@cast source table
  for key, item in pairs(source) do result[key] = item end
  -- A shallow copy retains the input fields; nil produces an empty table.
  ---@cast result Applet.Copied<T>
  return result
end

-- This assertion name is recognized by the checker through runtime.special.
---@param condition unknown
---@param path string
---@param message string
---@param level? integer
local function applet_expect(condition, path, message, level)
  if condition then return end
  error(('%s: %s'):format(path, message), level or 3)
end

M.expect = applet_expect

---@param value unknown
---@return TypeGuard<string>
function M.nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

---@param left unknown
---@param right unknown
---@param seen? table<table, table<table, boolean>>
---@return boolean
local function equal(left, right, seen)
  if rawequal(left, right) then return true end
  local kind = type(left)
  if kind ~= type(right) or kind ~= "table" then return false end
  if getmetatable(left) ~= nil or getmetatable(right) ~= nil then return false end
  if #left ~= #right then return false end
  seen = seen or {}
  seen[left] = seen[left] or {}
  if seen[left][right] then return true end
  seen[left][right] = true
  local left_count, right_count = 0, 0
  for key, value in pairs(left) do
    left_count = left_count + 1
    if not equal(value, right[key], seen) then return false end
  end
  for _ in pairs(right) do right_count = right_count + 1 end
  return left_count == right_count
end

---@param left unknown
---@param right unknown
---@return boolean
function M.equal(left, right)
  return equal(left, right)
end

---@param text string
---@return integer
function M.display_width(text)
  return vim.fn.strdisplaywidth(text)
end

---@param text string
---@param index integer
---@return integer?
local function utf8_length(text, index)
  local first = text:byte(index)
  if first < 0x80 then return 1 end
  local second, third, fourth = text:byte(index + 1, index + 3)
  ---@param byte? integer
  ---@return TypeGuard<integer>
  local continuation = function(byte) return byte ~= nil and byte >= 0x80 and byte <= 0xBF end
  if first >= 0xC2 and first <= 0xDF and continuation(second) then return 2 end
  if first >= 0xE0 and first <= 0xEF and continuation(second) and continuation(third)
      and not (first == 0xE0 and second < 0xA0)
      and not (first == 0xED and second > 0x9F) then
    return 3
  end
  if first >= 0xF0 and first <= 0xF4 and continuation(second)
      and continuation(third) and continuation(fourth)
      and not (first == 0xF0 and second < 0x90)
      and not (first == 0xF4 and second > 0x8F) then
    return 4
  end
end

---@param text string
---@param display_col integer
---@return integer
function M.byte_col(text, display_col)
  if display_col <= 0 then return 0 end
  if not text:find("[\128-\255]") then return math.min(display_col, #text) end
  M.characters(text, "text")
  local byte_col, width = 0, 0
  for index = 0, vim.fn.strchars(text, 1) - 1 do
    local character = vim.fn.strcharpart(text, index, 1, 1)
    local character_width = M.display_width(character)
    if width + character_width > display_col then break end
    byte_col = byte_col + #character
    width = width + character_width
  end
  return byte_col
end

---@param text unknown
---@param path string
---@return string
function M.validate_text(text, path)
  applet_expect(type(text) == "string", path, "must be a string")
  applet_expect(not text:find("\r", 1, true), path, "must not contain carriage returns")
  local index = 1
  while index <= #text do
    local length = utf8_length(text, index)
    applet_expect(length ~= nil, path, "must be valid UTF-8")
    index = index + length
  end
  return text
end

---@param text string
---@param path string
---@return string[]
function M.characters(text, path)
  M.validate_text(text, path)
  local result = {}
  local index = 1
  while index <= #text do
    local length = utf8_length(text, index)
    -- The immutable string was validated before collecting its characters.
    ---@cast length integer
    result[#result + 1] = text:sub(index, index + length - 1)
    index = index + length
  end
  return result
end

return M
