local util = require("neoagent.util")

local M = {}

local function add(result, text)
  local row = #result.lines
  result.lines[#result.lines + 1] = text
  result.highlights[#result.highlights + 1] = {
    row = row,
    col = 0,
    end_col = #text,
    group = "NeoagentMuted",
  }
end

function M.render(status, opts)
  local steering = type(status.steering) == "table"
    and status.steering or {}
  if #steering == 0 then return nil end
  local result = { lines = {}, highlights = {}, line_groups = {} }
  for _, message in ipairs(steering) do
    local text = util.trim(tostring(message):gsub("%s+", " "))
    add(result, " Steering: " .. text)
  end
  add(result, " ↳ " .. (opts.dequeue_key or "Alt-Up")
    .. " to edit queued messages")
  return result
end

return M
