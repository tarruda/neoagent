local util = require("neoagent.util")

local M = {}

local order = { "off", "minimal", "low", "medium", "high", "xhigh", "max" }
local known = {}
for _, level in ipairs(order) do known[level] = true end

function M.is_level(level)
  return type(level) == "string" and known[level] == true
end

function M.levels(model)
  local configured = model and model.thinking
  if type(configured) ~= "table" then return {} end
  local result = {}
  for _, level in ipairs(order) do
    local value = configured[level]
    if type(value) == "table" or type(value) == "function" then
      result[#result + 1] = level
    end
  end
  return result
end

function M.clamp(model, level)
  local available = M.levels(model)
  if #available == 0 then return nil end
  if vim.tbl_contains(available, level) then return level end
  local requested
  for index, candidate in ipairs(order) do
    if candidate == level then requested = index break end
  end
  if not requested then return available[1] end
  for index = requested + 1, #order do
    if vim.tbl_contains(available, order[index]) then return order[index] end
  end
  for index = requested - 1, 1, -1 do
    if vim.tbl_contains(available, order[index]) then return order[index] end
  end
  return available[1]
end

function M.next(model, level)
  local available = M.levels(model)
  if #available == 0 then return nil end
  local current = M.clamp(model, level)
  for index, candidate in ipairs(available) do
    if candidate == current then return available[index % #available + 1] end
  end
  return available[1]
end

function M.request_opts(model, level)
  if level == nil then return nil end
  local value = model and type(model.thinking) == "table" and model.thinking[level] or nil
  if type(value) ~= "table" and type(value) ~= "function" then return nil end
  return util.copy(value)
end

M.order = util.copy(order)

return M
