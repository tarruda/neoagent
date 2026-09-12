local Applet = require("applet")
local util = require("neoagent.util")

local ui = Applet.Pane.nodes
local widgets = Applet.Pane.widgets

---@class Neoagent.DialogPaneConfig: Neoagent.UIConfigInput
---@field cancel_key? Neoagent.UIMapping

---@class Neoagent.DialogPaneState
---@field snapshot Neoagent.ActiveDialogSnapshot
---@field config Neoagent.DialogPaneConfig

---@class Neoagent.DialogPaneCallbacks
---@field choose fun(id: string, action: string, input?: string): unknown
---@field cancel fun(id: string): unknown
---@field focus_input? fun(event: Applet.ActionEvent<Applet.Pane<Neoagent.DialogPaneState>>): unknown

---@class Neoagent.DialogPaneOptions
---@field key? string
---@field editable? boolean
---@field config? Neoagent.UIConfigInput
---@field theme? Applet.Theme
---@field callbacks Neoagent.DialogPaneCallbacks
---@field on_error? fun(error: Applet.PaneError)

---@class Neoagent.DialogPane
---@field config Neoagent.DialogPaneConfig
---@field callbacks Neoagent.DialogPaneCallbacks
---@field snapshot? Neoagent.DialogSnapshot
---@field input_value string
---@field pane Applet.Pane<Neoagent.DialogPaneState>
local Dialog = {}
Dialog.__index = Dialog

---@param value Neoagent.UIMapping?
---@return string[]
local function values(value)
  if type(value) == "string" then
    return { value }
  end
  if type(value) == "table" then
    return value
  end
  return {}
end

---@param config Neoagent.UIConfigInput
---@return Applet.Binding[]
local function focus_bindings(config)
  ---@type Applet.Binding[]
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

---@param dialog Neoagent.Dialog
---@param config Neoagent.UIConfigInput
---@return Applet.Binding[]
local function action_bindings(dialog, config)
  ---@type Applet.Binding[]
  local result = {}
  local modes = dialog.input and { "n", "i" } or { "n" }
  for _, action in ipairs(dialog.actions or {}) do
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

---@param lines Applet.TextRun[][]
---@param text string?
---@param style string?
local function append_line(lines, text, style)
  lines[#lines + 1] = { { text = text or "", style = style } }
end

---@param text unknown
---@return string[]
local function split_lines(text)
  local result = {}
  for _, line in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
    result[#result + 1] = line
  end
  return result
end

---@param dialog Neoagent.Dialog
---@param queue_count integer
---@return Applet.TextRun[][]
local function input_lines(dialog, queue_count)
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
    append_line(lines, string.format("[%s] %s", action.key, action.label), "dialog_action")
  end
  if queue_count and queue_count > 0 then
    append_line(lines, string.format("%d more dialog%s pending", queue_count, queue_count == 1 and "" or "s"), "muted")
  end
  return lines
end

---@param state Neoagent.DialogPaneState
---@return Applet.Tree
local function render(state)
  local snapshot = state.snapshot
  local dialog = snapshot.active
  if dialog.input then
    local bindings = action_bindings(dialog, state.config)
    if type(state.config.cancel_key) == "string" and state.config.cancel_key ~= "" then
      local cancel_modes = { "n" }
      cancel_modes[#cancel_modes + 1] = "i"
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
          lines = input_lines(dialog, snapshot.queue_count),
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
  ---@type Applet.MenuItem[]
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
      runs = {
        {
          text = string.format(
            "%d more dialog%s pending",
            snapshot.queue_count,
            snapshot.queue_count == 1 and "" or "s"
          ),
          style = "muted",
        },
      },
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
      target_intent = widgets.menu_intent(entry, "dialog-focus:" .. dialog.id),
    },
  }
end

---@param opts Neoagent.DialogPaneOptions
---@return Neoagent.DialogPane
function Dialog.new(opts)
  opts = opts or {}
  opts.callbacks = opts.callbacks or {}
  opts.config = opts.config or {}
  local callbacks = opts.callbacks
  ---@type Neoagent.DialogPaneConfig
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
          callbacks.choose(
            active.id,
            (event.payload --[[@as {action: string}]]).action,
            self.pane:is_editable() and self:text() or nil
          )
        end
      end,
      ["dialog.cancel"] = function()
        local active = self.snapshot and self.snapshot.active
        if active then
          callbacks.cancel(active.id)
        end
      end,
      ["dialog.changed"] = function()
        self.input_value = self:text()
      end,
    },
    on_error = opts.on_error,
  })
  return self
end

---@param snapshot Neoagent.ActiveDialogSnapshot
function Dialog:set(snapshot)
  self.snapshot = util.copy(snapshot)
  local input = self.snapshot.active.input
  self.input_value = input and input.value or ""
  self.pane:set_state({
    snapshot = self.snapshot,
    config = self.config,
  })
  if self.pane:is_editable() and self.pane:is_connected() then
    self.pane:replace_text(self.input_value)
  end
end

---@return string
function Dialog:text()
  if not self.pane:is_editable() then
    return self.input_value
  end
  return self.pane:text()
end

---@param value string?
---@param cursor? Applet.Cursor|[integer, integer]
---@return boolean
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
