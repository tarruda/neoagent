local Applet = require("applet")

local ui = Applet.Pane.nodes

---@alias Neoagent.InputPaneEvent Applet.ActionEvent<Applet.Pane<Neoagent.InputPaneState>>

---@class Neoagent.InputPaneState
---@field config Neoagent.UIConfigInput
---@field completion boolean
---@field footer? string
---@field virtual_lines Applet.TextRun[][]

---@class Neoagent.InputPaneCallbacks
---@field pane? fun(): Applet.Pane?
---@field submit fun(text: string): unknown
---@field close fun(event?: Neoagent.InputPaneEvent): unknown
---@field previous_card? fun(event: Neoagent.InputPaneEvent): unknown
---@field history fun(): string[]

---@class Neoagent.InputPaneOptions
---@field config? Neoagent.UIConfigInput
---@field callbacks Neoagent.InputPaneCallbacks
---@field theme? Applet.Theme
---@field on_error? fun(error: Applet.PaneError)

---@class Neoagent.InputPane
---@field config Neoagent.UIConfigInput
---@field callbacks Neoagent.InputPaneCallbacks
---@field theme? Applet.Theme
---@field on_error? fun(error: Applet.PaneError)
---@field history_index integer
---@field history_draft? {text: string, cursor?: Applet.Cursor}
---@field revision integer
---@field state Neoagent.InputPaneState
---@field pane Applet.Pane<Neoagent.InputPaneState>
---@field pending_text? string
---@field pending_cursor? Applet.Cursor|[integer, integer]
local Input = {}
Input.__index = Input

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

---@param result Applet.Binding[]
---@param modes string|string[]
---@param lhs Neoagent.UIMapping?
---@param action Applet.Action
---@param opts? {count?: boolean, desc?: string}
local function bind(result, modes, lhs, action, opts)
  modes = type(modes) == "table" and modes or { modes }
  for _, mode in ipairs(modes) do
    for _, key in ipairs(values(lhs)) do
      result[#result + 1] = {
        mode = mode,
        lhs = key,
        action = action,
        count = opts and opts.count or false,
        desc = opts and opts.desc or nil,
      }
    end
  end
end

---@param state Neoagent.InputPaneState
---@return Applet.Binding[]
local function bindings(state)
  local mappings = state.config.mappings or {}
  ---@type Applet.Binding[]
  local result = {}
  if state.completion then
    bind(result, "i", mappings.complete, ui.action("input.complete"), { desc = "Complete input" })
  end
  bind(result, { "n", "i" }, mappings.submit, ui.action("input.submit"), { desc = "Submit input" })
  bind(result, "n", mappings.close_input, ui.action("input.close"), { desc = "Close Neoagent" })
  for _, key in ipairs(values(mappings.close_empty)) do
    bind(result, { "n", "i" }, key, ui.action("input.close_empty", { key = key }), { desc = "Close empty input" })
  end
  bind(result, { "n", "i" }, mappings.card_previous, ui.action("input.previous_card"), {
    count = true,
    desc = "Previous card",
  })
  bind(
    result,
    "i",
    mappings.history_previous,
    ui.action("input.history", { direction = -1 }),
    { desc = "Previous input" }
  )
  bind(result, "i", mappings.history_next, ui.action("input.history", { direction = 1 }), { desc = "Next input" })
  return result
end

---@param state Neoagent.InputPaneState
---@return Applet.Tree
local function render(state)
  return {
    root = ui.scope({
      key = "input:scope",
      bindings = bindings(state),
      child = ui.virtual({
        key = "input:virtual",
        placement = "above-end",
        lines = state.virtual_lines or {},
      }),
    }),
    chrome = {
      footer = state.footer and { { text = state.footer, style = "muted" } } or nil,
      footer_pos = "center",
      options = { wrap = true },
    },
    edit = { on_change = ui.action("input.changed") },
  }
end

---@param self Neoagent.InputPane
---@return Applet.Pane<Neoagent.InputPaneState>
local function new_pane(self)
  local callbacks = self.callbacks
  return Applet.Pane.new({
    key = "input",
    extent = "document",
    buffer_mode = "editable",
    theme = self.theme,
    render = render,
    handlers = {
      ["input.changed"] = function()
        self:_changed()
      end,
      ["input.complete"] = function()
        self:_complete()
      end,
      ["input.submit"] = function()
        self:_submit()
      end,
      ["input.close"] = callbacks.close or function() end,
      ["input.close_empty"] = function(event)
        return self:_close_empty(event)
      end,
      ["input.previous_card"] = callbacks.previous_card or function() end,
      ["input.history"] = function(event)
        return self:_move_history((event.payload --[[@as {direction: integer}]]).direction, event)
      end,
    },
    on_error = self.on_error,
  })
end

---@param opts Neoagent.InputPaneOptions
---@return Neoagent.InputPane
function Input.new(opts)
  opts = opts or {}
  opts.config = opts.config or {}
  opts.callbacks = opts.callbacks or {}
  local callbacks = opts.callbacks
  local self = setmetatable({
    config = opts.config,
    callbacks = callbacks,
    theme = opts.theme,
    on_error = opts.on_error,
    history_index = 0,
    revision = 0,
    state = {
      config = opts.config,
      footer = nil,
      virtual_lines = {},
      completion = opts.config.completion == true,
    },
  }, Input)
  self.pane = new_pane(self)
  self.pane:set_state(self.state)
  return self
end

function Input:_changed()
  self.history_index = 0
  self.history_draft = nil
end

---@param theme Applet.Theme
function Input:set_theme(theme)
  self.theme = theme
  self.pane:set_theme(theme)
end

---@return boolean
function Input:_complete()
  local pane = self.callbacks.pane and self.callbacks.pane()
  if not pane then
    return false
  end
  if pane:completion_visible() then
    pane:completion_move("next")
    return true
  end
  return pane:complete()
end

---@return unknown
function Input:_submit()
  local pane = self.callbacks.pane and self.callbacks.pane()
  if pane and pane:completion_visible() then
    return pane:completion_accept()
  end
  return self.callbacks.submit(self:text())
end

---@param event Neoagent.InputPaneEvent
---@return unknown
function Input:_close_empty(event)
  if self:text() == "" then
    return self.callbacks.close()
  end
  return event:pass()
end

---@return string
function Input:text()
  if not self.pane:is_connected() then
    return self.pending_text or ""
  end
  return self.pane:text()
end

---@param text string
---@param cursor? Applet.Cursor|[integer, integer]
---@return boolean
function Input:set_text(text, cursor)
  self:_changed()
  return self:_replace_text(text, cursor)
end

---@param text string
---@param cursor? Applet.Cursor|[integer, integer]
---@return boolean
function Input:_replace_text(text, cursor)
  self.revision = self.revision + 1
  if not self.pane:is_connected() then
    self.pending_text = text or ""
    self.pending_cursor = cursor
    return true
  end
  local pane = self.callbacks.pane and self.callbacks.pane()
  if pane then
    local semantic = cursor
        and {
          line = cursor.line or cursor[1],
          column = cursor.column or cursor[2],
        }
      or nil
    return pane:replace_text(text, semantic, self.revision)
  end
  return self.pane:replace_text(text, cursor, self.revision)
end

---@param text string
---@param cursor? Applet.Cursor|[integer, integer]
---@return boolean
function Input:replace_text(text, cursor)
  return self:set_text(text, cursor)
end

---@param state Neoagent.InputPaneState?
function Input:set_state(state)
  self.state = state or self.state
  self.pane:set_state(self.state)
end

---@param config Neoagent.UIConfigInput?
function Input:set_config(config)
  self.config = config or {}
  self.state = vim.tbl_extend("force", {}, self.state, {
    config = self.config,
    completion = self.config.completion == true,
  })
  self.pane:set_state(self.state)
end

---@param lines Applet.TextRun[][]?
function Input:set_virtual_lines(lines)
  self.state = vim.tbl_extend("force", {}, self.state, {
    virtual_lines = lines or {},
  })
  self.pane:set_state(self.state)
end

---@param value string?
---@return boolean
function Input:set_footer(value)
  if self.state.footer == value then
    return false
  end
  self.state = vim.tbl_extend("force", {}, self.state, { footer = value })
  self.pane:set_state(self.state)
  return true
end

---@return Applet.Binding[]
function Input:mapping_bindings()
  return bindings(self.state)
end

---@param text string
---@param placement "start"|"end"
---@param cursor Applet.Cursor?
function Input:_history_text(text, placement, cursor)
  local lines = Applet.Pane.text.lines(text or "")
  local target = cursor
    or (placement == "start" and { line = 1, column = 0 } or { line = #lines, column = #lines[#lines] })
  self:_replace_text(text, target)
end

---@param direction integer
---@return boolean
function Input:_browse_history(direction)
  local history = self.callbacks.history()
  if type(history) ~= "table" or #history == 0 then
    return false
  end
  local next_index = self.history_index - direction
  if next_index < 0 or next_index > #history then
    return false
  end
  if self.history_index == 0 and next_index > 0 then
    local pane = self.callbacks.pane and self.callbacks.pane()
    self.history_draft = {
      text = self:text(),
      cursor = pane and pane:cursor() or nil,
    }
  end
  self.history_index = next_index
  if next_index == 0 then
    local draft = self.history_draft or { text = "" }
    self:_history_text(draft.text, "end", draft.cursor)
    self.history_draft = nil
  else
    self:_history_text(assert(history[next_index]), direction < 0 and "start" or "end")
  end
  return true
end

---@param direction integer
---@param event Neoagent.InputPaneEvent?
---@return boolean|Neoagent.InputPaneEvent
function Input:_move_history(direction, event)
  local pane = self.callbacks.pane and self.callbacks.pane()
  if not pane or not pane:is_mounted() then
    return false
  end
  if pane:completion_visible() then
    pane:completion_move(direction < 0 and "previous" or "next")
    return true
  end
  local cursor = pane:cursor()
  if direction < 0 then
    if self.history_index > 0 or self:text() == "" or pane:at_start() then
      return self:_browse_history(direction)
    elseif cursor.line == 1 then
      pane:set_cursor({ line = 1, column = 0 })
      return false
    end
  elseif self.history_index > 0 then
    return self:_browse_history(direction)
  else
    local lines = Applet.Pane.text.lines(self:text())
    if cursor.line == #lines then
      pane:set_cursor({ line = #lines, column = #(lines[#lines] or "") })
      return false
    end
  end
  return event and event:pass() or false
end

function Input:destroy()
  self.pane:destroy()
end

return Input
