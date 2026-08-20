local async = require("neoagent.async")
local management = require("neoagent.providers.codex_management")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}

local STALE_AFTER_MS = 15 * 60 * 1000
local DEFAULT_BASE_URL = "https://chatgpt.com/backend-api"

local plan_labels = {
  free = "Free",
  go = "Go",
  plus = "Plus",
  pro = "Pro",
  prolite = "Pro Lite",
  team = "Business",
  self_serve_business_prolite = "Business",
  self_serve_business_usage_based = "Business",
  business = "Enterprise",
  ent26 = "Enterprise",
  enterprise_cbp_automation = "Enterprise (Automation)",
  enterprise_cbp_usage_based = "Enterprise",
  enterprise = "Enterprise",
  education = "Edu",
  edu = "Edu",
  edu_plus = "Edu Plus",
  edu_pro = "Edu Pro",
  k12 = "K-12",
  quorum = "Quorum",
}

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function safe_text(value, maximum)
  if type(value) ~= "string" then return nil end
  value = util.trim(value)
  if value == "" or #value > maximum
      or not util.is_valid_utf8(value)
      or value:find("[%z\1-\31\127]") then
    return nil
  end
  return value
end

local function plan_label(value)
  value = safe_text(value, 64)
  return value and plan_labels[
    value:lower():gsub("%-", "_"):gsub("%s+", "_")] or nil
end

local function duration_label(minutes)
  if minutes == 300 then return "5h" end
  if minutes == 10080 then return "Weekly" end
  if minutes == 43200 or minutes == 44640 then return "Monthly" end
  if not finite(minutes) or minutes <= 0 then return "Usage" end
  if minutes % 1440 == 0 then
    local days = minutes / 1440
    return tostring(days) .. (days == 1 and " day" or " days")
  end
  if minutes % 60 == 0 then return tostring(minutes / 60) .. "h" end
  return tostring(minutes) .. "m"
end

local function limit_label(limit, window)
  local duration = duration_label(window.window_minutes)
  local name = safe_text(limit.name, 128)
  if name then
    duration = duration:sub(1, 1):lower() .. duration:sub(2)
    return name .. " " .. duration .. " limit"
  end
  return duration .. " limit"
end

local function parse_limits(status)
  local blocks = {}
  for _, part in ipairs(vim.split(status, " · ", { plain = true })) do
    local window, available = part:match("^(%S+)%s+(%d+%.?%d*)%% left$")
    local percent = tonumber(available)
    if window and window ~= "" and percent then
      local label = window == "weekly" and "Weekly"
        or window == "5h" and "5h" or window
      blocks[#blocks + 1] = {
        type = "limit",
        label = label .. " limit",
        remaining = math.max(0, math.min(1, percent / 100)),
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

local function normalized_window(value)
  if type(value) ~= "table" then return nil end
  local remaining = value.remaining
  if not finite(remaining) then
    local used = value.used_percent
    if finite(used) then remaining = (100 - used) / 100 end
  end
  if not finite(remaining) then return nil end
  local result = {
    remaining = math.max(0, math.min(1, remaining)),
  }
  if finite(value.window_minutes) and value.window_minutes > 0 then
    result.window_minutes = value.window_minutes
  elseif finite(value.limit_window_seconds)
      and value.limit_window_seconds > 0 then
    result.window_minutes = value.limit_window_seconds / 60
  end
  if finite(value.resets_at) and value.resets_at > 0 then
    result.resets_at = value.resets_at
  elseif finite(value.reset_at) and value.reset_at > 0 then
    result.resets_at = value.reset_at
  end
  return result
end

local function normalized_limit(source, id, name)
  if type(source) ~= "table" then return nil end
  local primary = normalized_window(source.primary or source.primary_window)
  local secondary = normalized_window(
    source.secondary or source.secondary_window)
  if not primary and not secondary then return nil end
  return {
    id = safe_text(id, 128),
    name = safe_text(name, 128),
    primary = primary,
    secondary = secondary,
  }
end

local function limit_level(remaining)
  if remaining <= 0 then return "error" end
  if remaining <= 0.2 then return "warn" end
  return "success"
end

local function account_display(account)
  if not account then return nil end
  if account.email and account.plan then
    return account.email .. " (" .. account.plan .. ")"
  end
  return account.email or account.plan or "ChatGPT"
end

local function interact_confirm(ctx, options)
  return async.await(function(done)
    return ctx.interact.confirm(options, done)
  end)
end

local function random_id()
  return "neoagent-" .. vim.uv.random(16):gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end)
end

function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local service_opts = opts.service_opts or {}
  local now = resources.now or util.now_ms
  local new_id = resources.new_id or random_id
  local client = management.new({
    base_url = opts.base_url or DEFAULT_BASE_URL,
    transport = resources.transport,
    timeout_ms = service_opts.timeout_ms,
    max_response_bytes = service_opts.max_response_bytes,
  })
  local status = {
    type = "status",
    text = "Usage not loaded · run Refresh usage",
    level = "muted",
  }
  local connection_status
  local limits = {}
  local limit_order = {}
  local account
  local credits
  local spend_control
  local reset_credit_count
  local reset_credits = {}
  local reached_type
  local activity
  local workspaces
  local usage
  local checked_at
  local stale_visible = false
  local destroyed = false
  local active_runs = {}
  local refresh_run
  local dashboard = provider_state.new({ blocks = { status } })

  local function has_account_data()
    return account ~= nil or #limit_order > 0 or credits ~= nil
      or spend_control ~= nil or reset_credit_count ~= nil
  end

  local function blocks()
    local result = {}
    local visible_status = connection_status or status
    if visible_status then
      result[#result + 1] = util.copy(visible_status)
    end
    local display = account_display(account)
    if display then
      result[#result + 1] = {
        type = "field", label = "Account", value = display,
      }
    end
    for _, id in ipairs(limit_order) do
      local limit = limits[id]
      for _, window in ipairs({ limit.primary, limit.secondary }) do
        if window then
          result[#result + 1] = {
            type = "limit",
            label = limit_label(limit, window),
            remaining = window.remaining,
            resets_at = window.resets_at,
            level = limit_level(window.remaining),
          }
        end
      end
    end
    if credits then
      local value
      if credits.unlimited then
        value = "Unlimited"
      elseif credits.has_credits and credits.balance then
        value = credits.balance
      elseif credits.has_credits then
        value = "Available"
      else
        value = "None"
      end
      result[#result + 1] = {
        type = "field", label = "Credits", value = value,
      }
    end
    if spend_control then
      if finite(spend_control.remaining_percent) then
        result[#result + 1] = {
          type = "limit",
          label = "Monthly spend control",
          remaining = math.max(0,
            math.min(1, spend_control.remaining_percent / 100)),
          resets_at = spend_control.resets_at,
          detail = spend_control.detail,
          level = spend_control.reached and "error" or "info",
        }
      else
        result[#result + 1] = {
          type = "field",
          label = "Spend control",
          value = spend_control.reached and "Reached" or "Available",
        }
      end
    end
    if reset_credit_count ~= nil then
      result[#result + 1] = {
        type = "field", label = "Reset credits",
        value = tostring(reset_credit_count),
      }
    end
    if reached_type then
      result[#result + 1] = {
        type = "status", text = reached_type, level = "error",
      }
    end
    if usage then result[#result + 1] = util.copy(usage) end
    if activity then result[#result + 1] = util.copy(activity) end
    if workspaces then result[#result + 1] = util.copy(workspaces) end
    if #reset_credits > 0 then
      local items = {}
      for _, credit in ipairs(reset_credits) do
        local detail = credit.description
        if credit.expires_at then
          detail = (detail and detail .. " · " or "")
            .. "expires " .. credit.expires_at
        end
        items[#items + 1] = {
          label = credit.title or "Rate-limit reset",
          detail = detail,
        }
      end
      result[#result + 1] = {
        type = "list", title = "Reset credits", items = items,
      }
    end
    return result
  end

  local function publish()
    if destroyed then return end
    local ok, err = dashboard:push({ blocks = blocks() })
    if not ok then
      vim.notify("neoagent Codex dashboard failed: "
        .. tostring(err and err.message or err), vim.log.levels.ERROR)
    end
  end

  local function replace_limit(source)
    if type(source) ~= "table" then return false end
    local id = safe_text(source.id, 128)
    if not id then return false end
    local primary = normalized_window(source.primary)
    local secondary = normalized_window(source.secondary)
    if not primary and not secondary then return false end
    if not limits[id] then
      if #limit_order >= 28 then return false end
      limit_order[#limit_order + 1] = id
    end
    local current = limits[id] or { id = id }
    current.name = safe_text(source.name, 128) or current.name
    current.primary = primary or current.primary
    current.secondary = secondary or current.secondary
    limits[id] = current
    return true
  end

  local function apply_header_details(details)
    if type(details) ~= "table" then return false end
    local changed = false
    if type(details.limits) == "table" and util.is_list(details.limits) then
      for _, limit in ipairs(details.limits) do
        changed = replace_limit(limit) or changed
      end
    end
    if type(details.credits) == "table"
        and type(details.credits.has_credits) == "boolean"
        and type(details.credits.unlimited) == "boolean" then
      credits = {
        has_credits = details.credits.has_credits,
        unlimited = details.credits.unlimited,
        balance = safe_text(details.credits.balance, 128),
      }
      changed = true
    end
    return changed
  end

  local function account_snapshot(payload, metadata)
    local next_limits = {}
    local base = normalized_limit(payload.rate_limit, "codex")
    if base then next_limits[#next_limits + 1] = base end
    if type(payload.additional_rate_limits) == "table"
        and util.is_list(payload.additional_rate_limits) then
      for index, extra in ipairs(payload.additional_rate_limits) do
        if index > 24 then break end
        if type(extra) == "table" then
          local id = safe_text(extra.metered_feature, 128)
            or "metered-" .. tostring(index)
          local item = normalized_limit(
            extra.rate_limit, id, extra.limit_name)
          if item then next_limits[#next_limits + 1] = item end
        end
      end
    end

    local next_credits
    if type(payload.credits) == "table"
        and type(payload.credits.has_credits) == "boolean"
        and type(payload.credits.unlimited) == "boolean" then
      next_credits = {
        has_credits = payload.credits.has_credits,
        unlimited = payload.credits.unlimited,
        balance = safe_text(payload.credits.balance, 128),
      }
    end

    local next_spend
    if type(payload.spend_control) == "table" then
      local individual = payload.spend_control.individual_limit
      next_spend = { reached = payload.spend_control.reached == true }
      if type(individual) == "table" then
        next_spend.remaining_percent = finite(individual.remaining_percent)
          and individual.remaining_percent or nil
        next_spend.resets_at = finite(individual.reset_at)
          and individual.reset_at or nil
        local remaining = safe_text(individual.remaining, 128)
        local maximum = safe_text(individual.limit, 128)
        if remaining and maximum then
          next_spend.detail = remaining .. " of " .. maximum .. " left"
        end
      end
    end

    local reset_count
    if type(payload.rate_limit_reset_credits) == "table"
        and finite(payload.rate_limit_reset_credits.available_count) then
      reset_count = math.max(0,
        math.floor(payload.rate_limit_reset_credits.available_count))
    end
    local next_account = {
      email = safe_text(metadata and metadata.email, 254),
      plan = plan_label(payload.plan_type)
        or safe_text(metadata and metadata.plan, 64),
    }
    local reached = type(payload.rate_limit_reached_type) == "table"
      and safe_text(payload.rate_limit_reached_type.type, 128) or nil
    if reached then
      reached = reached:gsub("_", " ")
      reached = reached:sub(1, 1):upper() .. reached:sub(2)
    end
    return {
      limits = next_limits,
      credits = next_credits,
      spend_control = next_spend,
      reset_credit_count = reset_count,
      account = next_account,
      reached_type = reached,
    }
  end

  local function apply_account_snapshot(snapshot)
    limits, limit_order = {}, {}
    for _, limit in ipairs(snapshot.limits) do replace_limit(limit) end
    account = snapshot.account
    credits = snapshot.credits
    spend_control = snapshot.spend_control
    reset_credit_count = snapshot.reset_credit_count
    reached_type = snapshot.reached_type
    checked_at = now()
    stale_visible = false
    status = #snapshot.limits == 0 and snapshot.credits == nil
        and snapshot.spend_control == nil and {
          type = "status",
          text = "Account connected · quota information unavailable",
          level = "muted",
        } or nil
  end

  local function refresh_failure(err)
    local message = safe_text(err and err.message, 300)
      or "Codex usage refresh failed"
    if has_account_data() then
      status = {
        type = "status",
        text = "Usage data is stale · " .. message,
        level = "muted",
      }
      stale_visible = true
    else
      status = { type = "status", text = message, level = "warn" }
    end
    publish()
  end

  local function start_tracked(fn, clear)
    local run
    run = async.run(fn, {
      on_done = function()
        active_runs[run] = nil
        if clear then clear(run) end
      end,
      error_kind = "provider",
    })
    active_runs[run] = true
    return run
  end

  local function refresh(ctx)
    if refresh_run and not refresh_run:is_done() then return refresh_run end
    status = has_account_data() and status or {
      type = "status", text = "Loading account usage", level = "muted",
    }
    publish()
    local run = start_tracked(function()
      local result = client:usage(ctx):await()
      if result.ok == false then
        if not (result.error and result.error.kind == "cancelled") then
          refresh_failure(result.error)
        end
        return result
      end
      apply_account_snapshot(account_snapshot(result.value, result.metadata))
      publish()
      return { ok = true }
    end, function(candidate)
      if refresh_run == candidate then refresh_run = nil end
    end)
    refresh_run = run
    return run
  end

  local function auxiliary(ctx, request, apply)
    return start_tracked(function()
      local result = request(client, ctx):await()
      if result.ok == false then
        if not (result.error and result.error.kind == "cancelled") then
          refresh_failure(result.error)
        end
        return result
      end
      local ok, err = apply(result.value)
      if not ok then
        local failure = util.error("provider", err)
        refresh_failure(failure)
        return { ok = false, error = failure }
      end
      status = nil
      publish()
      return { ok = true }
    end)
  end

  local service = {
    id = resources.provider_id or "openai-codex",
    name = "Codex",
    operations = {},
  }

  service.operations.refresh = {
    label = "Refresh usage",
    description = "Load ChatGPT account quotas",
    run = refresh,
  }

  service.operations.activity = {
    label = "Account activity",
    description = "Load aggregate token activity",
    run = function(ctx)
      return auxiliary(ctx, client.activity, function(payload)
        local stats = type(payload.stats) == "table" and payload.stats or nil
        if not stats then return nil, "Codex activity response is malformed" end
        local rows = {}
        for _, field in ipairs({
          { "Lifetime tokens", stats.lifetime_tokens },
          { "Peak daily tokens", stats.peak_daily_tokens },
          { "Longest turn", stats.longest_running_turn_sec, "s" },
          { "Current streak", stats.current_streak_days, " days" },
          { "Longest streak", stats.longest_streak_days, " days" },
        }) do
          if finite(field[2]) then
            rows[#rows + 1] = {
              label = field[1],
              detail = grouped_number(field[2]) .. (field[3] or ""),
            }
          end
        end
        activity = {
          type = "list", title = "Account activity", items = rows,
        }
        return true
      end)
    end,
  }

  service.operations.workspaces = {
    label = "Workspaces",
    description = "Load ChatGPT workspace names",
    run = function(ctx)
      return auxiliary(ctx, client.accounts, function(payload)
        if type(payload.accounts) ~= "table" then
          return nil, "Codex workspace response is malformed"
        end
        local by_id = {}
        if util.is_list(payload.accounts) then
          for _, item in ipairs(payload.accounts) do
            if type(item) == "table" and safe_text(item.id, 256) then
              by_id[item.id] = item
            end
          end
        else
          for id, wrapper in pairs(payload.accounts) do
            local item = type(wrapper) == "table" and wrapper.account or nil
            if type(item) == "table" then by_id[id] = item end
          end
        end
        local order = type(payload.account_ordering) == "table"
          and util.is_list(payload.account_ordering)
          and payload.account_ordering or vim.tbl_keys(by_id)
        local items = {}
        for _, id in ipairs(order) do
          if #items >= 50 then break end
          local item = by_id[id]
          if item then
            local name = safe_text(item.name, 512) or "Workspace"
            local detail = id == payload.default_account_id and "Default"
              or safe_text(item.structure, 128)
            items[#items + 1] = { label = name, detail = detail }
          end
        end
        workspaces = {
          type = "list", title = "Workspaces", items = items,
        }
        return true
      end)
    end,
  }

  service.operations.reset_credits = {
    label = "Reset credits",
    description = "Load earned rate-limit resets",
    run = function(ctx)
      return auxiliary(ctx, client.reset_credits, function(payload)
        if not finite(payload.available_count)
            or type(payload.credits) ~= "table"
            or not util.is_list(payload.credits) then
          return nil, "Codex reset-credit response is malformed"
        end
        reset_credit_count = math.max(0, math.floor(payload.available_count))
        reset_credits = {}
        for index, item in ipairs(payload.credits) do
          if index > 50 then break end
          if type(item) == "table" then
            local id = safe_text(item.id, 256)
            local state = safe_text(item.status, 32)
            if id and state then
              reset_credits[#reset_credits + 1] = {
                id = id,
                status = state,
                title = safe_text(item.title, 512),
                description = safe_text(item.description, 350),
                expires_at = safe_text(item.expires_at, 128),
              }
            end
          end
        end
        return true
      end)
    end,
  }

  service.operations.redeem = {
    label = "Redeem reset credit",
    description = "Reset eligible rate-limit windows",
    mutating = true,
    run = function(ctx)
      return start_tracked(function()
        local selected
        for _, credit in ipairs(reset_credits) do
          if credit.status == "available" then selected = credit break end
        end
        local prompt = selected and selected.title
          and "Redeem " .. selected.title .. "?"
          or "Redeem one rate-limit reset credit?"
        if not interact_confirm(ctx, { prompt = prompt }) then
          return { ok = true, cancelled = true }
        end
        local redeem_request_id = new_id()
        local result = client:redeem(ctx, redeem_request_id,
          selected and selected.id or nil):await()
        if result.ok == false then
          if not (result.error and result.error.kind == "cancelled") then
            refresh_failure(result.error)
          end
          return result
        end
        local code = safe_text(result.value.code, 64)
        if code == "no_credit" or code == "nothing_to_reset" then
          local err = util.error("provider",
            code == "no_credit" and "No reset credit is available"
              or "No rate-limit window can be reset")
          refresh_failure(err)
          return { ok = false, error = err }
        end
        if code ~= "reset" and code ~= "already_redeemed" then
          local err = util.error("provider",
            "Codex reset-credit response is malformed")
          refresh_failure(err)
          return { ok = false, error = err }
        end
        if selected then
          for index, credit in ipairs(reset_credits) do
            if credit == selected then table.remove(reset_credits, index) break end
          end
        end
        if reset_credit_count then
          reset_credit_count = math.max(0, reset_credit_count - 1)
        end
        local refreshed = client:usage(ctx):await()
        if refreshed.ok then
          apply_account_snapshot(account_snapshot(
            refreshed.value, refreshed.metadata))
        else
          refresh_failure(refreshed.error)
        end
        publish()
        return { ok = true, code = code }
      end)
    end,
  }

  function service:state()
    if checked_at and not stale_visible
        and now() - checked_at > STALE_AFTER_MS then
      stale_visible = true
      status = {
        type = "status",
        text = "Usage data is stale · run Refresh usage",
        level = "muted",
      }
      publish()
    end
    return dashboard:state()
  end

  function service:subscribe(listener)
    return dashboard:subscribe(listener)
  end

  function service:on_event(event)
    if type(event) ~= "table" then return end
    if event.type == "provider_status" then
      local text = safe_text(event.text, 512)
      if type(event.reconnecting) == "boolean" then
        if event.reconnecting and text then
          connection_status = {
            type = "status", text = text, level = "warn",
          }
        elseif not event.reconnecting then
          connection_status = nil
        end
        publish()
        return
      end
      if apply_header_details(event.details) then
        if not checked_at then status = nil end
        publish()
      elseif text then
        local parsed = parse_limits(text)
        if #parsed > 0 then
          for _, block in ipairs(parsed) do
            local id = "legacy-" .. tostring(#limit_order + 1)
            local window_minutes = block.label == "Weekly limit" and 10080
              or block.label == "5h limit" and 300 or nil
            local name
            if not window_minutes then
              name = block.label:gsub(" limit$", "")
            end
            limit_order[#limit_order + 1] = id
            limits[id] = {
              id = id,
              name = name,
              primary = {
                remaining = block.remaining,
                window_minutes = window_minutes,
              },
            }
          end
          if not checked_at then status = nil end
        else
          status = {
            type = "status",
            text = text,
            level = text:lower():find("reconnect", 1, true)
              and "warn" or "info",
          }
        end
        publish()
      end
    elseif event.type == "usage" then
      local next_usage = usage_field(event.usage)
      if next_usage then
        usage = next_usage
        publish()
      end
    end
  end

  function service:destroy()
    if destroyed then return end
    destroyed = true
    for run in pairs(active_runs) do run:cancel() end
    active_runs = {}
    refresh_run = nil
    dashboard:destroy()
  end

  return service
end

M.duration_label = duration_label
M.parse_limits = parse_limits

return M
