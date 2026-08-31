local Applet = require("applet")
local util = require("neoagent.util")

local ui = Applet.Pane.nodes
local widgets = Applet.Pane.widgets

local Dialog = {}
Dialog.__index = Dialog

local function values(value)
  if type(value) == "string" then return { value } end
  if type(value) == "table" then return value end
  return {}
end

local function focus_bindings(config)
  local result = {}
  for _, lhs in ipairs(values((config.mappings or {}).card_next)) do
    result[#result + 1] = {
      mode = "n",
      lhs = lhs,
      action = ui.action("dialog.focus_input"),
      desc = "Focus input",
    }
  end
  return result
end

local function action_bindings(snapshot, config)
  local result = {}
  local modes = snapshot.active.input and { "n", "i" } or { "n" }
  for _, action in ipairs(snapshot.active.actions or {}) do
    for _, mode in ipairs(modes) do
      result[#result + 1] = {
        mode = mode,
        lhs = action.key,
        action = ui.action("dialog.choose", { action = action.id }),
        desc = action.label,
      }
    end
  end
  vim.list_extend(result, focus_bindings(config))
  return result
end

local function append_line(lines, text, style)
  lines[#lines + 1] = { { text = text or "", style = style } }
end

local function split_lines(text)
  local result = {}
  for _, line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
    result[#result + 1] = line
  end
  return result
end

local function input_lines(snapshot)
  local dialog = snapshot.active
  local lines = {}
  append_line(lines, dialog.title, "dialog_title")
  for _, line in ipairs(split_lines(dialog.body)) do
    append_line(lines, line, nil)
  end
  if dialog.input then
    append_line(lines, "", nil)
    append_line(lines, dialog.input.label, "dialog_title")
  end
  append_line(lines, "", nil)
  for _, action in ipairs(dialog.actions or {}) do
    append_line(lines, string.format("[%s] %s", action.key, action.label),
      "dialog_action")
  end
  if snapshot.queue_count and snapshot.queue_count > 0 then
    append_line(lines, string.format("%d more dialog%s pending",
      snapshot.queue_count, snapshot.queue_count == 1 and "" or "s"), "muted")
  end
  return lines
end

local function render(state, env)
  local snapshot = state.snapshot
  if not snapshot or not snapshot.active then
    return {
      root = ui.text({ key = "dialog:empty", text = "", wrap = "none" }),
      chrome = { options = { wrap = false } },
    }
  end
  local dialog = snapshot.active
  if dialog.input then
    local bindings = action_bindings(snapshot, state.config)
    if type(state.config.cancel_key) == "string"
        and state.config.cancel_key ~= "" then
      local cancel_modes = { "n" }
      if dialog.input then cancel_modes[#cancel_modes + 1] = "i" end
      for _, mode in ipairs(cancel_modes) do
        bindings[#bindings + 1] = {
          mode = mode,
          lhs = state.config.cancel_key,
          action = ui.action("dialog.cancel"),
          desc = "Cancel dialog",
        }
      end
    end
    return {
      root = ui.scope({
        key = "dialog:" .. dialog.id .. ":scope",
        modal = true,
        bindings = bindings,
        child = ui.virtual({
          key = "dialog:" .. dialog.id .. ":virtual",
          placement = "above",
          lines = input_lines(snapshot),
        }),
      }),
      chrome = {
        title = { { text = " " .. dialog.title .. " ", style = "window_title" } },
        title_pos = "center",
        options = { wrap = false, cursorline = true },
      },
      edit = { on_change = ui.action("dialog.changed") },
    }
  end
  local actions = {}
  for _, action in ipairs(dialog.actions or {}) do
    actions[#actions + 1] = {
      key = action.id,
      label = string.format("[%s] %s", action.key, action.label),
      quick_keys = { action.key },
      action = ui.action("dialog.choose", { action = action.id }),
    }
  end
  local body = ui.text({
    key = "dialog:" .. dialog.id .. ":body",
    text = dialog.body or "",
    wrap = "word",
  })
  local queue
  if snapshot.queue_count and snapshot.queue_count > 0 then
    queue = ui.text({
      key = "dialog:" .. dialog.id .. ":queue",
      runs = { { text = string.format("%d more dialog%s pending",
        snapshot.queue_count, snapshot.queue_count == 1 and "" or "s"),
        style = "muted" } },
      wrap = "word",
    })
  end
  local mappings = state.config.mappings or {}
  local root, entry = widgets.dialog({
    key = "dialog:" .. dialog.id,
    title = dialog.title,
    body = body,
    queue_status = queue,
    background = "dialog_background",
    actions = actions,
    initial_action = dialog.default_action,
    bindings = focus_bindings(state.config),
    keys = {
      previous = mappings.menu_previous,
      next = mappings.menu_next,
      activate = mappings.card_details,
    },
  })
  return {
    root = root,
    chrome = {
      title = { { text = " " .. dialog.title .. " ", style = "window_title" } },
      title_pos = "center",
      options = { wrap = false, cursorline = true },
    },
    view = {
      target_intent = widgets.menu_intent(entry,
        "dialog-focus:" .. dialog.id),
    },
  }
end

function Dialog.new(opts)
  opts = opts or {}
  opts.callbacks = opts.callbacks or {}
  opts.config = opts.config or {}
  local callbacks = opts.callbacks
  local dialog_config = util.copy(opts.config)
  dialog_config.cancel_key = (opts.config.mappings or {}).close or "<C-c>"
  local self = setmetatable({
    config = dialog_config,
    callbacks = callbacks,
    snapshot = nil,
    input_value = "",
  }, Dialog)
  self.pane = Applet.Pane.new({
    key = opts.key or "dialog",
    extent = "document",
    buffer_mode = opts.editable and "editable" or "managed",
    theme = opts.theme,
    render = render,
    handlers = {
      ["dialog.focus_input"] = callbacks.focus_input or function() end,
      ["dialog.choose"] = function(event)
        local active = self.snapshot and self.snapshot.active
        if active then
          callbacks.choose(active.id, event.payload.action,
            self.pane:is_editable() and self:text() or nil)
        end
      end,
      ["dialog.cancel"] = function()
        local active = self.snapshot and self.snapshot.active
        if active then callbacks.cancel(active.id) end
      end,
      ["dialog.changed"] = function()
        self.input_value = self:text()
        if callbacks.changed then callbacks.changed(self.input_value) end
      end,
    },
    on_error = opts.on_error,
  })
  return self
end

function Dialog:set(snapshot)
  self.snapshot = snapshot and util.copy(snapshot) or nil
  local input = self.snapshot and self.snapshot.active
    and self.snapshot.active.input
  self.input_value = input and input.value or ""
  self.pane:set_state({
    snapshot = self.snapshot,
    config = self.config,
  })
  if self.pane:is_editable() and self.pane:is_connected() then
    self.pane:replace_text(self.input_value)
  end
end

function Dialog:text()
  if not self.pane:is_editable() then return self.input_value end
  return self.pane:text()
end

function Dialog:set_text(value, cursor)
  self.input_value = value or ""
  if self.pane:is_editable() and self.pane:is_connected() then
    return self.pane:replace_text(self.input_value, cursor)
  end
  return true
end

function Dialog:destroy()
  self.pane:destroy()
end

return Dialog
