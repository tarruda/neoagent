local responses = require("neoagent.api.openai_responses")
local util = require("neoagent.util")

local M = {}

local function window_label(minutes)
  return ({ [300] = "5h", [10080] = "weekly" })[minutes]
    or tostring(minutes) .. "m"
end

local function rate_limit_status(headers)
  local normalized = {}
  for name, value in pairs(headers or {}) do normalized[name:lower()] = value end
  local parts = {}
  for _, window in ipairs({
    { prefix = "primary" },
    { prefix = "secondary" },
  }) do
    local base = "x-codex-" .. window.prefix .. "-"
    local used = tonumber(normalized[base .. "used-percent"])
    local minutes = tonumber(normalized[base .. "window-minutes"])
    if used and minutes and minutes > 0 then
      local remaining = math.max(0, math.min(100, 100 - used))
      local formatted = string.format("%.1f", remaining):gsub("%.0$", "")
      parts[#parts + 1] = string.format("%s %s%% left",
        window_label(minutes), formatted)
    end
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

local function base_url(value)
  local normalized = value:gsub("/+$", "")
  if normalized:sub(-10) == "/responses" then normalized = normalized:sub(1, -11) end
  if normalized:sub(-6) ~= "/codex" then normalized = normalized .. "/codex" end
  return normalized
end

function M.new(opts)
  opts = util.copy(opts or {})
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  opts.base_url = base_url(opts.base_url)
  opts.profile = "codex"
  opts.response_status = rate_limit_status
  local model = responses.new(opts)
  model.api = "openai-codex-responses"
  return model
end

return M
