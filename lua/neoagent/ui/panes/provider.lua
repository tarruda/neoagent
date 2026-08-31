local Applet = require("applet")
local util = require("neoagent.util")

local ui = Applet.Pane.nodes
local widgets = Applet.Pane.widgets
local display = Applet.Pane.text

local Provider = {}
Provider.__index = Provider

local function menu(state, key)
  local items = {}
  for _, operation in ipairs(state.snapshot.operations or {}) do
    local style = operation.enabled == false and "muted" or nil
    local label = {
      { text = "  " .. operation.label, style = style },
    }
    if operation.description and operation.description ~= "" then
      label[#label + 1] = {
        text = " · " .. operation.description,
        style = style,
      }
    end
    items[#items + 1] = {
      key = operation.id,
      label = label,
      disabled = operation.enabled == false,
      focus_style = "menu_selected",
      action = operation.enabled == false and nil or ui.action("provider.run", {
        operation = operation.id,
      }),
    }
  end
  local mappings = state.config.mappings or {}
  return widgets.menu({
    key = key,
    group = "provider.operations",
    title = state.snapshot.operation_prompt or "Actions",
    items = items,
    keys = {
      previous = mappings.menu_previous,
      next = mappings.menu_next,
      activate = mappings.card_details,
    },
    text_wrap = "native",
    gap = 0,
    title_gap = 0,
  })
end

local level_styles = {
  info = "accent",
  success = "NeoagentGreen",
  warn = "DiagnosticWarn",
  error = "error",
  muted = "muted",
}

local level_symbols = {
  info = "●",
  success = "●",
  warn = "!",
  error = "×",
  muted = "○",
}

local field_symbols = {
  info = "●",
  success = "✓",
  warn = "!",
  error = "×",
  muted = "○",
}

local function text(key, runs, wrap)
  return ui.text({ key = key, runs = runs, wrap = wrap or "word" })
end

local function progress(key, block, width)
  local heading = {
    { text = tostring(block.label or "Progress"), style = "strong" },
  }
  if block.detail and block.detail ~= "" then
    heading[#heading + 1] = { text = "  " .. block.detail, style = "muted" }
  end
  local bar
  if type(block.value) == "number" then
    local value = math.max(0, math.min(1, block.value))
    local suffix = " " .. math.floor(value * 100 + 0.5) .. "%"
    local available = math.max(1, math.min(40,
      width - display.width(suffix)))
    local filled = math.floor(value * available + 0.5)
    bar = {
      { text = string.rep("█", filled),
        style = level_styles[block.level or "info"] or "accent" },
      { text = string.rep("─", available - filled) .. suffix, style = "muted" },
    }
  else
    bar = { { text = "···", style = level_styles[block.level or "info"] } }
  end
  return ui.column({
    key = key,
    children = {
      text(key .. ":heading", heading),
      text(key .. ":bar", bar, "none"),
    },
  })
end

local function reset_time(timestamp)
  if os.date("%Y-%m-%d", timestamp) == os.date("%Y-%m-%d") then
    return os.date("%H:%M", timestamp)
  end
  local day = os.date("%d", timestamp):gsub("^0", "")
  return os.date("%H:%M on ", timestamp) .. day .. os.date(" %b", timestamp)
end

local function limit(key, block, width, label_width)
  local remaining = math.max(0, math.min(1, block.remaining or 0))
  local percent = math.floor(remaining * 100 + 0.5) .. "% left"
  local reset = block.resets_at and "resets " .. reset_time(block.resets_at)
  local bar = string.rep("█", math.floor(remaining * 20 + 0.5))
    .. string.rep("░", 20 - math.floor(remaining * 20 + 0.5))
  local label = tostring(block.label or "Limit")
  label_width = label_width or display.width(label)
  local label_fits = display.width(label) <= label_width
  local prefix = string.rep(" ", label_width + 2)
  if label_fits then
    prefix = label .. string.rep(" ", label_width - display.width(label) + 2)
  end
  local meter = prefix .. bar .. " " .. percent
  if display.width(meter) <= width then
    local meter_runs = {
      { text = prefix, style = "strong" },
      { text = bar, style = level_styles[block.level or "info"] or "accent" },
      { text = " " .. percent },
    }
    local inline_reset = reset and display.width(meter .. " (" .. reset .. ")") <= width
    if inline_reset then
      meter_runs[#meter_runs + 1] = {
        text = " (" .. reset .. ")", style = "muted",
      }
    end
    local meter_node = text(key .. ":meter", meter_runs, "none")
    if label_fits and (not reset or inline_reset) then return meter_node end
    local children = {}
    if not label_fits then
      children[#children + 1] = text(key .. ":label", {
        { text = label, style = "strong" },
      })
    end
    children[#children + 1] = meter_node
    if reset and not inline_reset then
      children[#children + 1] = text(key .. ":reset", {
        { text = "  " .. reset, style = "muted" },
      })
    end
    return ui.column({ key = key, children = children })
  end
  local summary = text(key .. ":summary", {
    { text = label .. "  ", style = "strong" },
    { text = percent },
  })
  if not reset then return summary end
  return ui.column({
    key = key,
    children = {
      summary,
      text(key .. ":reset", { { text = "  " .. reset, style = "muted" } }),
    },
  })
end

local function information_block(block, key, width, limit_label_width)
  if block.type == "status" then
    local level = block.level or "info"
    return text(key, {
      { text = (level_symbols[level] or level_symbols.info) .. " ",
        style = level_styles[level] or "accent" },
      { text = tostring(block.text or ""), style = "strong" },
    })
  end
  if block.type == "field" then
    local value = text(key .. ":value", {
      { text = tostring(block.label or "") .. "  ", style = "muted" },
      { text = tostring(block.value or "") },
    })
    if not block.level then return value end
    local level = block.level or "info"
    return ui.row({
      key = key,
      children = {
        { node = value, min_width = 1, grow = 1 },
        {
          node = text(key .. ":level", { {
            text = field_symbols[level] or field_symbols.info,
            style = level_styles[level] or "accent",
          } }, "none"),
          min_width = 1,
          grow = 0,
        },
      },
    })
  end
  if block.type == "progress" then return progress(key, block, width) end
  if block.type == "limit" then
    return limit(key, block, width, limit_label_width)
  end
  if block.type == "list" then
    local children = {
      text(key .. ":title", { { text = tostring(block.title or ""), style = "strong" } }),
    }
    for index, item in ipairs(block.items or {}) do
      children[#children + 1] = text(key .. ":item:" .. index, { {
        text = "  " .. tostring(item.label or "")
          .. (item.detail and item.detail ~= "" and " · " .. item.detail or ""),
        style = "muted",
      } })
    end
    return ui.column({ key = key, children = children })
  end
  if block.type == "activity" then
    local children = {
      text(key .. ":title", { { text = tostring(block.title or ""), style = "strong" } }),
    }
    for index, entry in ipairs(block.entries or {}) do
      local level = entry.level or "info"
      children[#children + 1] = text(key .. ":entry:" .. index, {
        { text = "  " .. (level_symbols[level] or level_symbols.info) .. " ",
          style = level_styles[level] or "muted" },
        { text = tostring(entry.message or ""), style = "muted" },
      })
    end
    return ui.column({ key = key, children = children })
  end
end

local function information(state, key, width)
  local snapshot = state.snapshot or {}
  local provider_state = snapshot.state
  local children, fields = {}, {}
  local function flush_fields()
    if #fields == 0 then return end
    children[#children + 1] = ui.column({
      key = key .. ":fields:" .. tostring(#children + 1),
      children = fields,
    })
    fields = {}
  end
  if provider_state and provider_state ~= false then
    local limit_label_width, limit_percent_width = 0, 0
    for _, block in ipairs(provider_state.blocks or {}) do
      if block.type == "limit" then
        local remaining = math.max(0, math.min(1, block.remaining or 0))
        local percent = math.floor(remaining * 100 + 0.5) .. "% left"
        limit_percent_width = math.max(limit_percent_width,
          display.width(percent))
      end
    end
    local label_budget = math.max(0, width - 23 - limit_percent_width)
    for _, block in ipairs(provider_state.blocks or {}) do
      if block.type == "limit" then
        local label_width = display.width(tostring(block.label or "Limit"))
        if label_width <= label_budget then
          limit_label_width = math.max(limit_label_width, label_width)
        end
      end
    end
    for index, block in ipairs(provider_state.blocks or {}) do
      local node = information_block(block, key .. ":block:" .. index,
        width, limit_label_width)
      if node then
        if block.type == "field" then
          fields[#fields + 1] = node
        else
          flush_fields()
          children[#children + 1] = node
        end
      end
    end
    flush_fields()
  end
  if #children == 0 then return nil end
  return ui.column({ key = key, gap = 1, children = children })
end

local function binding(result, value, action, desc)
  local values = type(value) == "table" and value or { value }
  for _, lhs in ipairs(values) do
    if type(lhs) == "string" then
      result[#result + 1] = {
        mode = "n", lhs = lhs, action = ui.action(action), desc = desc,
      }
    end
  end
end

local function mapped(value, lhs)
  local values = type(value) == "table" and value or { value }
  for _, candidate in ipairs(values) do
    if candidate == lhs then return true end
  end
  return false
end

local function render(state, env)
  local children = {}
  local dashboard = information(state, "provider:information", env.width)
  local has_actions = #(state.snapshot.operations or {}) > 0
  if dashboard then children[#children + 1] = dashboard end
  local operation_menu, operation_entry
  if has_actions then
    operation_menu, operation_entry = menu(state, "provider:operations")
    children[#children + 1] = operation_menu
  end
  if #children == 0 then
    children[1] = text("provider:empty", {
      { text = "No provider information", style = "muted" },
    })
  end
  local mappings = state.config.mappings or {}
  local bindings = {}
  if operation_menu then
    vim.list_extend(bindings, operation_menu.bindings)
    operation_menu.bindings = {}
  end
  binding(bindings, mappings.provider_previous,
    "provider.previous", "Previous provider")
  binding(bindings, mappings.provider_next,
    "provider.next", "Next provider")
  binding(bindings, mappings.provider_close, "provider.close", "Close provider")
  binding(bindings, mappings.toggle_provider_shell, "provider.close", "Close provider")
  if not mapped(mappings.provider_close, "<C-c>")
      and not mapped(mappings.toggle_provider_shell, "<C-c>") then
    binding(bindings, "<C-c>", "provider.close", "Close provider")
  end
  local claimed = {}
  for _, name in ipairs({
    "menu_previous", "menu_next", "provider_previous",
    "provider_next", "card_details", "provider_close", "toggle_provider_shell",
  }) do
    local values = type(mappings[name]) == "table"
        and mappings[name] or { mappings[name] }
    for _, lhs in ipairs(values) do claimed[lhs] = true end
  end
  for _, lhs in ipairs({
    "i", "I", "a", "A", "o", "O", "s", "S", "c", "C", "R", "gi", "gI",
  }) do
    if not claimed[lhs] then
      bindings[#bindings + 1] = {
        mode = "n", lhs = lhs, action = ui.action("provider.ignore"),
        desc = "Keep provider read-only",
      }
    end
  end
  return {
    root = ui.scope({
      key = "provider:scope",
      bindings = bindings,
      child = ui.column({
        key = "provider:layout",
        gap = 1,
        children = children,
      }),
    }),
    chrome = {
      title = { {
        text = " " .. (state.snapshot.name or "Provider")
          .. " provider shell ",
        style = "window_title",
      } },
      title_pos = "center",
      options = {
        wrap = false,
        cursorline = true,
      },
    },
    view = {
      scroll = "preserve",
      target_intent = widgets.menu_intent(operation_entry,
        "provider:operations:" .. tostring(state.snapshot.id)),
    },
  }
end

local function new_pane(self)
  local callbacks = self.callbacks
  return Applet.Pane.new({
    key = "provider",
    extent = "document",
    theme = self.theme,
    render = render,
    handlers = {
      ["provider.run"] = function(event)
        callbacks.run(event.payload.operation)
      end,
      ["provider.previous"] = callbacks.previous or function() end,
      ["provider.next"] = callbacks.next or function() end,
      ["provider.close"] = callbacks.close or function() end,
      ["provider.ignore"] = function() end,
    },
    on_error = self.on_error,
  })
end

function Provider.new(opts)
  opts = opts or {}
  opts.config = opts.config or {}
  opts.callbacks = opts.callbacks or {}
  local callbacks = opts.callbacks
  callbacks.run = callbacks.run or function() end
  local self = setmetatable({
    config = opts.config,
    callbacks = callbacks,
    theme = opts.theme,
    on_error = opts.on_error,
    state = {
      snapshot = { operations = {} },
      config = opts.config,
    },
  }, Provider)
  self.pane = new_pane(self)
  self.pane:set_state(self.state)
  return self
end

function Provider:set(snapshot)
  self.state = {
    snapshot = snapshot and util.copy(snapshot) or { operations = {} },
    config = self.state.config,
  }
  self.pane:set_state(self.state)
end

function Provider:focus_initial()
  return self.pane:focus_target_intent()
end

function Provider:set_config(config)
  self.config = config or {}
  self.state = {
    snapshot = self.state.snapshot,
    config = self.config,
  }
  self.pane:set_state(self.state)
end

function Provider:set_theme(theme)
  self.theme = theme
  self.pane:set_theme(theme)
end

function Provider:destroy()
  self.pane:destroy()
end

return Provider
