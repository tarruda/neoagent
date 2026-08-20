local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}

local function field_label(window)
  if window == "weekly" then return "Plan window" end
  if window == "5h" then return "Rolling window" end
  return window .. " window"
end

local function parse_limits(status)
  local blocks = {}
  for _, part in ipairs(vim.split(status, " · ", { plain = true })) do
    local window, available = part:match("^(%S+)%s+(%d+%.?%d*)%% left$")
    local percent = tonumber(available)
    if window and window ~= "" and percent then
      blocks[#blocks + 1] = {
        type = "progress",
        label = field_label(window),
        value = math.max(0, math.min(1, percent / 100)),
        detail = available .. "% left",
      }
    end
  end
  return blocks
end

local function grouped_number(value)
  local digits = tostring(math.floor(value + 0.5))
  while true do
    local replaced, count = digits:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
    digits = replaced
    if count == 0 then return digits end
  end
end

local function usage_field(usage)
  if type(usage) ~= "table" then return nil end
  local input = tonumber(usage.inputTokens or usage.input_tokens)
  local output = tonumber(usage.outputTokens or usage.output_tokens)
  if not input and not output then return nil end
  local parts = {}
  if input then parts[#parts + 1] = grouped_number(input) .. " in" end
  if output then parts[#parts + 1] = grouped_number(output) .. " out" end
  return {
    type = "field",
    label = "Last response",
    value = table.concat(parts, " · "),
  }
end

function M.new(_, resources)
  resources = resources or {}
  local status = {
    type = "status",
    text = "Awaiting first response",
    level = "muted",
  }
  local limits = {}
  local usage
  local dashboard = provider_state.new({ blocks = { status } })

  local function publish()
    local blocks = { util.copy(status) }
    if usage then blocks[#blocks + 1] = util.copy(usage) end
    vim.list_extend(blocks, util.copy(limits))
    local ok, err = dashboard:push({ blocks = blocks })
    if not ok then
      vim.notify("neoagent Codex dashboard failed: "
        .. tostring(err and err.message or err), vim.log.levels.ERROR)
    end
  end

  local service = {
    id = resources.provider_id or "openai-codex",
    name = "Codex",
    operations = {},
  }

  function service:state()
    return dashboard:state()
  end

  function service:subscribe(listener)
    return dashboard:subscribe(listener)
  end

  function service:on_event(event)
    if type(event) ~= "table" then return end
    if event.type == "provider_status"
        and type(event.text) == "string"
        and util.trim(event.text) ~= "" then
      local text = util.trim(event.text)
      local parsed = parse_limits(text)
      if #parsed > 0 then
        limits = parsed
        status = {
          type = "status",
          text = "Usage updated",
          level = "success",
        }
      else
        status = {
          type = "status",
          text = text,
          level = text:lower():find("reconnect", 1, true)
            and "warn" or "info",
        }
      end
      publish()
    elseif event.type == "usage" then
      local next_usage = usage_field(event.usage)
      if next_usage then
        usage = next_usage
        publish()
      end
    end
  end

  function service:destroy()
    status = { type = "status", text = "Destroyed", level = "muted" }
    limits = {}
    usage = nil
    dashboard:destroy()
  end

  return service
end

M.parse_limits = parse_limits

return M
