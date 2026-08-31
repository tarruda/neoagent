local ui = require("applet.pane.nodes")
local util = require("applet.util")

local M = {}

local function key_binding(lhs, action, opts)
  if lhs == false or lhs == nil then return {} end
  local values = type(lhs) == "table" and lhs or { lhs }
  local result = {}
  for _, value in ipairs(values) do
    util.expect(util.nonempty_string(value), "widget key", "must be a non-empty string", 4)
    result[#result + 1] = {
      mode = opts and opts.mode or "n",
      lhs = value,
      action = action,
      count = opts and opts.count or false,
      desc = opts and opts.desc or nil,
    }
  end
  return result
end

local function append(destination, values)
  for _, value in ipairs(values) do destination[#destination + 1] = value end
end

local function binding_id(binding)
  return (binding.mode or "n") .. "\0" .. binding.lhs
end

local function item_content(menu_key, item, text_wrap)
  local children = {
    ui.text({
      key = menu_key .. ":item:" .. item.key .. ":label",
      runs = type(item.label) == "table" and item.label or {
        { text = item.label, style = item.disabled and "muted" or nil },
      },
      wrap = text_wrap,
    }),
  }
  if item.detail ~= nil then
    children[#children + 1] = ui.text({
      key = menu_key .. ":item:" .. item.key .. ":detail",
      runs = type(item.detail) == "table" and item.detail or {
        { text = item.detail, style = "muted" },
      },
      wrap = text_wrap,
    })
  end
  return #children == 1 and children[1] or ui.column({
    key = menu_key .. ":item:" .. item.key .. ":content",
    gap = 0,
    children = children,
  })
end

function M.menu(opts)
  util.expect(type(opts) == "table", "menu", "options must be a table", 3)
  util.expect(util.nonempty_string(opts.key), "menu.key", "must be a non-empty string", 3)
  util.expect(type(opts.items) == "table", "menu.items", "must be a list", 3)
  util.expect(opts.initial == nil or util.nonempty_string(opts.initial),
    "menu.initial", "must name an enabled item", 3)
  local orientation = opts.orientation or "vertical"
  util.expect(orientation == "vertical" or orientation == "horizontal",
    "menu.orientation", "must be vertical or horizontal", 3)
  local text_wrap = opts.text_wrap or "word"
  util.expect(text_wrap == "word" or text_wrap == "character"
      or text_wrap == "none" or text_wrap == "native",
    "menu.text_wrap", "must be word, character, none, or native", 3)
  local group = opts.group or opts.key
  util.expect(util.nonempty_string(group), "menu.group", "must be a non-empty string", 3)
  local item_nodes, bindings, seen, quick_bindings = {}, {}, {}, {}
  local first_enabled, initial_target, final
  for index, item in ipairs(opts.items) do
    local path = ("menu.items[%d]"):format(index)
    util.expect(type(item) == "table", path, "must be a table", 3)
    util.expect(util.nonempty_string(item.key), path .. ".key", "must be a non-empty string", 3)
    util.expect(not seen[item.key], path .. ".key", "must be unique", 3)
    seen[item.key] = true
    util.expect(type(item.label) == "string" or type(item.label) == "table",
      path .. ".label", "must be text or runs", 3)
    util.expect(item.disabled == nil or type(item.disabled) == "boolean",
      path .. ".disabled", "must be a boolean", 3)
    if not item.disabled then
      util.expect(type(item.action) == "table", path .. ".action", "is required", 3)
    end
    local target_key = opts.key .. ":item:" .. item.key
    final = target_key
    if not item.disabled and not first_enabled then first_enabled = target_key end
    if item.key == opts.initial then
      util.expect(not item.disabled, "menu.initial", "must name an enabled item", 3)
      initial_target = target_key
    end
    item_nodes[#item_nodes + 1] = ui.target({
      key = target_key,
      group = group,
      role = "menuitem",
      disabled = item.disabled == true,
      action = item.action,
      focus_style = not item.disabled
        and (item.focus_style or "selected") or nil,
      child = item_content(opts.key, item, text_wrap),
    })
    for _, quick_key in ipairs(item.quick_keys or {}) do
      local values = key_binding(quick_key, ui.action("applet.target.activate", {
        target = target_key,
      }), { desc = "Choose " .. item.key })
      for _, binding in ipairs(values) do
        quick_bindings[binding_id(binding)] = true
      end
      append(bindings, values)
    end
  end
  local keys = opts.keys or {}
  local function append_default(value, action, binding_opts)
    for _, binding in ipairs(key_binding(value, action, binding_opts)) do
      if not quick_bindings[binding_id(binding)] then
        bindings[#bindings + 1] = binding
      end
    end
  end
  append_default(keys.previous, ui.action("applet.target.move", {
    group = group,
    direction = "previous",
    wrap = opts.wrap_navigation == true,
    entry = "first",
  }), { count = true, desc = "Previous " .. opts.key })
  append_default(keys.next, ui.action("applet.target.move", {
    group = group,
    direction = "next",
    wrap = opts.wrap_navigation == true,
    entry = "first",
  }), { count = true, desc = "Next " .. opts.key })
  append_default(keys.activate, ui.action("applet.target.activate"),
    { desc = "Choose " .. opts.key })
  local items
  if orientation == "vertical" then
    items = ui.column({
      key = opts.key .. ":items",
      gap = opts.gap or 0,
      children = item_nodes,
    })
  else
    local descriptors = {}
    for _, item_node in ipairs(item_nodes) do
      descriptors[#descriptors + 1] = {
        node = item_node,
        min_width = opts.item_min_width or 1,
        grow = 1,
      }
    end
    items = ui.row({
      key = opts.key .. ":items",
      gap = opts.gap or 1,
      children = descriptors,
    })
  end
  local content = items
  if opts.title ~= nil then
    content = ui.column({
      key = opts.key .. ":content",
      gap = opts.title_gap or 1,
      children = {
        ui.text({
          key = opts.key .. ":title",
          runs = type(opts.title) == "table" and opts.title
            or { { text = opts.title, style = "strong" } },
          wrap = text_wrap,
        }),
        items,
      },
    })
  end
  local root = ui.scope({
    key = opts.key .. ":scope",
    bindings = bindings,
    child = content,
  })
  if opts.initial ~= nil then
    util.expect(initial_target ~= nil,
      "menu.initial", "must name an enabled item", 3)
  end
  local selected = initial_target or first_enabled
  return root, selected and {
    select = selected,
    reveal = final,
  } or nil
end

function M.menu_intent(entry, key)
  if entry == nil then return nil end
  util.expect(type(entry) == "table", "menu entry", "must be a table", 3)
  util.expect(util.nonempty_string(entry.select), "menu entry.select",
    "must name a target", 3)
  util.expect(util.nonempty_string(entry.reveal), "menu entry.reveal",
    "must name a target", 3)
  util.expect(util.nonempty_string(key), "menu intent key",
    "must be a non-empty string", 3)
  return {
    key = key,
    select = entry.select,
    reveal = entry.reveal,
  }
end

function M.dialog(opts)
  util.expect(type(opts) == "table", "dialog", "options must be a table", 3)
  util.expect(util.nonempty_string(opts.key), "dialog.key", "must be a non-empty string", 3)
  local actions = {}
  for _, action in ipairs(opts.actions or {}) do
    actions[#actions + 1] = {
      key = action.key,
      label = action.label,
      action = action.action,
      disabled = action.disabled,
      quick_keys = action.quick_keys,
    }
  end
  local children = {}
  if opts.title then
    children[#children + 1] = ui.text({
      key = opts.key .. ":title",
      runs = type(opts.title) == "table" and opts.title
        or { { text = opts.title, style = "strong" } },
      wrap = "word",
    })
  end
  if opts.body then
    children[#children + 1] = type(opts.body) == "table" and opts.body.type
      and opts.body or ui.text({
        key = opts.key .. ":body",
        runs = type(opts.body) == "table" and opts.body or { { text = opts.body } },
        wrap = "word",
      })
  end
  if opts.queue_status then children[#children + 1] = opts.queue_status end
  local action_menu, entry = M.menu({
    key = opts.key .. ":actions",
    group = opts.key .. ".actions",
    orientation = opts.orientation or "vertical",
    items = actions,
    keys = opts.keys or {
      previous = "<Up>",
      next = "<Down>",
      activate = "<CR>",
    },
    initial = opts.initial_action,
    wrap_navigation = opts.wrap_navigation ~= false,
    gap = opts.action_gap ~= nil and opts.action_gap
      or (opts.orientation == "horizontal" and 2 or 0),
  })
  local bindings = util.copy(opts.bindings or {})
  append(bindings, action_menu.bindings)
  action_menu.bindings = {}
  children[#children + 1] = action_menu
  return ui.scope({
    key = opts.key .. ":modal",
    modal = true,
    bindings = bindings,
    child = ui.panel({
      key = opts.key .. ":panel",
      padding = opts.padding or 1,
      background = opts.background,
      child = ui.column({
        key = opts.key .. ":content",
        gap = opts.gap or 1,
        children = children,
      }),
    }),
  }), entry
end

function M.card(opts)
  util.expect(type(opts) == "table", "card", "options must be a table", 3)
  util.expect(util.nonempty_string(opts.key), "card.key", "must be a non-empty string", 3)
  util.expect(type(opts.child) == "table", "card.child", "must be a node", 3)
  local child = opts.child
  if opts.source then
    child = ui.source({
      key = opts.key .. ":source",
      path = opts.source.path,
      language = opts.source.language,
      child = child,
    })
  end
  child = ui.panel({
    key = opts.key .. ":panel",
    padding = opts.padding or { left = 1, right = 1 },
    background = opts.background,
    child = child,
  })
  return ui.target({
    key = opts.key,
    group = opts.group or "cards",
    role = opts.role or "document",
    action = opts.details_action,
    focus_style = opts.focus_style or "selected",
    child = child,
  })
end

return M
