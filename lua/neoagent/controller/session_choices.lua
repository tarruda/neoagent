local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}

local function relative_age(modified_at, now)
  local milliseconds = math.max(0, now - modified_at)
  local minutes = math.floor(milliseconds / 60000)
  local hours = math.floor(milliseconds / 3600000)
  local days = math.floor(milliseconds / 86400000)
  if minutes < 1 then return "now" end
  if minutes < 60 then return minutes .. "m" end
  if hours < 24 then return hours .. "h" end
  if days < 7 then return days .. "d" end
  if days < 30 then return math.floor(days / 7) .. "w" end
  if days < 365 then return math.floor(days / 30) .. "mo" end
  return math.floor(days / 365) .. "y"
end

local function session_text(info)
  local text = info.name or info.first_message or "(no messages)"
  text = util.trim(text:gsub("[%c%s]+", " "))
  if text == "" then text = "(no messages)" end
  if vim.fn.strchars(text) > 80 then text = vim.fn.strcharpart(text, 0, 80) .. "…" end
  return text
end

function M.build(sessions, current_path)
  local by_path = {}
  local nodes = {}
  for _, info in ipairs(sessions) do
    local node = { info = info, children = {}, latest = info.modified_at }
    nodes[#nodes + 1] = node
    by_path[fs.canonical(info.path)] = node
  end

  local roots = {}
  for _, node in ipairs(nodes) do
    local parent = node.info.parent_session and by_path[fs.canonical(node.info.parent_session)]
    if parent and parent ~= node then
      parent.children[#parent.children + 1] = node
    else
      roots[#roots + 1] = node
    end
  end

  local function update_latest(node)
    for _, child in ipairs(node.children) do
      node.latest = math.max(node.latest, update_latest(child))
    end
    return node.latest
  end
  local function sort_nodes(values)
    table.sort(values, function(a, b)
      if a.latest == b.latest then return a.info.path > b.info.path end
      return a.latest > b.latest
    end)
    for _, node in ipairs(values) do sort_nodes(node.children) end
  end
  for _, root in ipairs(roots) do update_latest(root) end
  sort_nodes(roots)

  local choices = {}
  local current = current_path and fs.canonical(current_path)
  local now = util.now_ms()
  local function visit(node, prefix, branch, is_last)
    local info = util.copy(node.info)
    info.current = current ~= nil and fs.canonical(info.path) == current
    local marker = info.current and "● " or "  "
    info.label = string.format("%s%s%s  %d  %s", marker, prefix .. branch,
      session_text(info), info.message_count, relative_age(info.modified_at, now))
    choices[#choices + 1] = info
    local child_prefix = prefix
    if branch ~= "" then child_prefix = child_prefix .. (is_last and "   " or "│  ") end
    for index, child in ipairs(node.children) do
      local child_last = index == #node.children
      visit(child, child_prefix, child_last and "└─ " or "├─ ", child_last)
    end
  end
  for _, root in ipairs(roots) do visit(root, "", "", true) end
  return choices
end

return M
