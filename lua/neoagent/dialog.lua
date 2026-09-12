local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.DialogAction
---@field id string
---@field label string
---@field key string

---@class Neoagent.DialogInput
---@field label string
---@field value string
---@field multiline boolean

---@class Neoagent.DialogRequest
---@field placement "transcript"|"float"
---@field agent? string
---@field title string
---@field body string
---@field default_action? string
---@field input? Neoagent.DialogInput
---@field actions Neoagent.DialogAction[]

---@class Neoagent.Dialog: Neoagent.DialogRequest
---@field id string

---@class Neoagent.DialogSuccess
---@field ok true
---@field action string
---@field input? string
---@field reason? string

---@class Neoagent.DialogFailure: Neoagent.AsyncFailure
---@field presenter_unavailable? true

---@alias Neoagent.DialogResult Neoagent.DialogSuccess|Neoagent.DialogFailure
---@alias Neoagent.DialogRun Neoagent.Run<Neoagent.DialogResult, nil>

---@class Neoagent.DialogSnapshot
---@field active? Neoagent.Dialog
---@field queue_count integer

---@class Neoagent.ActiveDialogSnapshot: Neoagent.DialogSnapshot
---@field active Neoagent.Dialog

---@class Neoagent.DialogEntry
---@field dialog Neoagent.Dialog
---@field done Neoagent.AwaitCallbacks<Neoagent.DialogResult>
---@field resolved boolean

---@class Neoagent.DialogState
---@field active? Neoagent.DialogEntry
---@field queue Neoagent.DialogEntry[]
---@field subscribers table<integer, fun(snapshot: Neoagent.DialogSnapshot)>
---@field next_subscriber integer
---@field next_dialog integer
---@field report fun(message: string, level: integer)

---@class Neoagent.DialogCapability
---@field show fun(self: Neoagent.DialogCapability, request: Neoagent.DialogRequest): Neoagent.DialogRun
---@field choose_pending fun(self: Neoagent.DialogCapability, action_id: string, reason?: string): integer?, Neoagent.Error?

---@class Neoagent.DialogToolContext<C>: Neoagent.ToolContext<C>
---@field dialog Neoagent.DialogCapability

---@class Neoagent.Dialogs: Neoagent.DialogCapability
---@field _state Neoagent.DialogState
---@field _instance_id string
local Dialogs = {}
Dialogs.__index = Dialogs

---@param message string
---@return Neoagent.Error
local function dialog_error(message)
  return util.error("dialog", message)
end

---@param state Neoagent.DialogState
---@return Neoagent.DialogSnapshot
local function snapshot(state)
  return {
    active = state.active and util.copy(state.active.dialog) or nil,
    queue_count = #state.queue,
  }
end

---@param state Neoagent.DialogState
local function publish(state)
  local value = snapshot(state)
  for _, subscriber in pairs(state.subscribers) do
    local ok, err = pcall(subscriber, util.copy(value))
    if not ok then
      state.report("neoagent dialog subscriber failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

---@param state Neoagent.DialogState
---@param entry Neoagent.DialogEntry
local function remove(state, entry)
  if state.active == entry then
    state.active = table.remove(state.queue, 1)
    publish(state)
    return
  end
  for index, queued in ipairs(state.queue) do
    if queued == entry then
      table.remove(state.queue, index)
      publish(state)
      return
    end
  end
end

---@param value unknown
---@param limit integer
---@param allow_empty? boolean
---@return TypeGuard<string>
local function valid_text(value, limit, allow_empty)
  return type(value) == "string" and (allow_empty or value ~= "") and #value <= limit and not value:find("\0", 1, true)
end

---@param dialog Neoagent.DialogRequest
local function validate_dialog(dialog)
  assert(type(dialog) == "table" and (next(dialog) == nil or not util.is_list(dialog)), "dialog must be an object")
  assert(
    dialog.placement == "transcript" or dialog.placement == "float",
    "dialog placement must be transcript or float"
  )
  assert(dialog.agent == nil or valid_text(dialog.agent, 512), "dialog agent must be a non-empty string")
  assert(valid_text(dialog.title, 512), "dialog title is invalid")
  assert(valid_text(dialog.body, 16 * 1024, true), "dialog body is invalid")
  assert(dialog.default_action == nil or valid_text(dialog.default_action, 128), "dialog default_action is invalid")
  if dialog.input ~= nil then
    assert(dialog.placement == "float", "dialog input requires float placement")
    assert(
      type(dialog.input) == "table" and (next(dialog.input) == nil or not util.is_list(dialog.input)),
      "dialog input must be an object"
    )
    assert(valid_text(dialog.input.label, 256), "dialog input label is invalid")
    assert(valid_text(dialog.input.value, 16 * 1024, true), "dialog input value is invalid")
    assert(type(dialog.input.multiline) == "boolean", "dialog input multiline must be boolean")
  end
  assert(
    type(dialog.actions) == "table" and util.is_list(dialog.actions) and #dialog.actions > 0 and #dialog.actions <= 16,
    "dialog actions must be a non-empty list of at most 16 actions"
  )
  local ids, keys = {}, {}
  for _, action in ipairs(dialog.actions) do
    assert(
      type(action) == "table" and (next(action) == nil or not util.is_list(action)),
      "dialog action must be an object"
    )
    assert(valid_text(action.id, 128), "dialog action id is invalid")
    assert(valid_text(action.label, 256), "dialog action label is invalid")
    assert(valid_text(action.key, 64), "dialog action key is invalid")
    assert(not ids[action.id], "dialog action ids must be distinct")
    assert(not keys[action.key], "dialog action keys must be distinct")
    ids[action.id], keys[action.key] = true, true
  end
  assert(dialog.default_action == nil or ids[dialog.default_action], "dialog default_action must name an action")
end

---@param dialog Neoagent.DialogRequest
---@param action_id string
---@return boolean
local function has_action(dialog, action_id)
  for _, action in ipairs(dialog.actions) do
    if action.id == action_id then
      return true
    end
  end
  return false
end

---@param dialog Neoagent.DialogRequest
---@param value unknown
---@return string?
local function validate_input(dialog, value)
  if not dialog.input then
    assert(value == nil, "dialog response cannot include input")
    return nil
  end
  assert(valid_text(value, 16 * 1024, true), "dialog response input is invalid")
  assert(dialog.input.multiline or not value:find("\n", 1, true), "dialog response input must be one line")
  return value
end

---@param dialog Neoagent.DialogRequest
---@return Neoagent.DialogRun
function Dialogs:show(dialog)
  validate_dialog(dialog)
  dialog = util.copy(dialog)
  ---@cast dialog Neoagent.Dialog
  local state = self._state
  state.next_dialog = state.next_dialog + 1
  dialog.id = "dialog-" .. self._instance_id .. "-" .. state.next_dialog
  return async.run(
    ---@return Neoagent.DialogResult
    function()
      if next(state.subscribers) == nil then
        return {
          ok = false,
          error = dialog_error("Dialog is unavailable because no presenter is attached"),
        }
      end
      local selected = async.await(
        ---@param done Neoagent.AwaitCallbacks<Neoagent.DialogResult>
        function(done)
          local entry = { dialog = dialog, done = done, resolved = false }
          if state.active then
            state.queue[#state.queue + 1] = entry
          else
            state.active = entry
          end
          publish(state)
          return function()
            if not entry.resolved then
              remove(state, entry)
            end
          end
        end
      )
      return selected
    end,
    { error_kind = "dialog" }
  )
end

---@param callback fun(snapshot: Neoagent.DialogSnapshot)
---@return fun()
function Dialogs:subscribe(callback)
  assert(type(callback) == "function", "dialog subscriber must be a function")
  local state = self._state
  state.next_subscriber = state.next_subscriber + 1
  local id = state.next_subscriber
  state.subscribers[id] = callback
  local ok, err = pcall(callback, snapshot(state))
  if not ok then
    state.subscribers[id] = nil
    error(err, 0)
  end
  local active = true
  return function()
    if not active then
      return
    end
    active = false
    state.subscribers[id] = nil
    if next(state.subscribers) == nil then
      self:cancel_pending("dialog presenter detached", {
        presenter_unavailable = true,
      })
    end
  end
end

---@param id string
---@param action_id string
---@param input? string
---@return true?, Neoagent.Error?
function Dialogs:choose(id, action_id, input)
  assert(type(id) == "string" and id ~= "", "dialog id is required")
  assert(type(action_id) == "string" and action_id ~= "", "dialog action id is required")
  local state = self._state
  local entry = state.active
  if not entry or entry.dialog.id ~= id then
    return nil, dialog_error("Dialog is not active: " .. id)
  end
  if not has_action(entry.dialog, action_id) then
    return nil, dialog_error("Dialog action is unavailable: " .. action_id)
  end
  input = validate_input(entry.dialog, input)
  entry.resolved = true
  state.active = table.remove(state.queue, 1)
  entry.done.resolve({
    ok = true,
    action = action_id,
    input = input,
  })
  publish(state)
  return true
end

---@param id string
---@param reason? string
---@param opts? {presenter_unavailable?: boolean}
---@return true?, Neoagent.Error?
function Dialogs:cancel(id, reason, opts)
  assert(type(id) == "string" and id ~= "", "dialog id is required")
  opts = opts or {}
  assert(
    type(opts) == "table" and (next(opts) == nil or not util.is_list(opts)),
    "dialog cancellation options must be an object"
  )
  local state = self._state
  local entry = state.active
  if not entry or entry.dialog.id ~= id then
    return nil, dialog_error("Dialog is not active: " .. id)
  end
  entry.resolved = true
  state.active = table.remove(state.queue, 1)
  entry.done.resolve({
    ok = false,
    error = dialog_error(reason or "Dialog was cancelled"),
    presenter_unavailable = opts.presenter_unavailable == true and true or nil,
  })
  publish(state)
  return true
end

---@param action_id string
---@param reason? string
---@return integer?, Neoagent.Error?
function Dialogs:choose_pending(action_id, reason)
  assert(type(action_id) == "string" and action_id ~= "", "dialog action id is required")
  local state = self._state
  ---@type Neoagent.DialogEntry[]
  local pending = {}
  if state.active then
    pending[#pending + 1] = state.active
  end
  vim.list_extend(pending, state.queue)
  for _, entry in ipairs(pending) do
    if not has_action(entry.dialog, action_id) then
      return nil, dialog_error("A pending dialog does not provide action: " .. action_id)
    end
    if entry.dialog.input then
      return nil, dialog_error("A pending dialog requires an individual input response")
    end
  end
  state.active, state.queue = nil, {}
  for _, entry in ipairs(pending) do
    if not entry.resolved then
      entry.resolved = true
      entry.done.resolve({
        ok = true,
        action = action_id,
        reason = reason,
      })
    end
  end
  if #pending > 0 then
    publish(state)
  end
  return #pending
end

---@param reason? string
---@param opts? {presenter_unavailable?: boolean}
---@return integer
function Dialogs:cancel_pending(reason, opts)
  opts = opts or {}
  assert(
    type(opts) == "table" and (next(opts) == nil or not util.is_list(opts)),
    "dialog cancellation options must be an object"
  )
  local state = self._state
  ---@type Neoagent.DialogEntry[]
  local pending = {}
  if state.active then
    pending[#pending + 1] = state.active
  end
  vim.list_extend(pending, state.queue)
  state.active, state.queue = nil, {}
  for _, entry in ipairs(pending) do
    if not entry.resolved then
      entry.resolved = true
      entry.done.resolve({
        ok = false,
        error = dialog_error(reason or "Dialog was cancelled"),
        presenter_unavailable = opts.presenter_unavailable == true and true or nil,
      })
    end
  end
  if #pending > 0 then
    publish(state)
  end
  return #pending
end

---@return Neoagent.DialogSnapshot
function Dialogs:snapshot()
  return snapshot(self._state)
end

---@generic C
---@param dialogs Neoagent.DialogCapability
---@param next_execute_tool? fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.DialogToolContext<C>): Neoagent.ToolResult
---@return Neoagent.ToolExecutor<C>
function M.wrap(dialogs, next_execute_tool)
  assert(
    type(dialogs) == "table" and type(dialogs.show) == "function" and type(dialogs.choose_pending) == "function",
    "dialog source must implement show and choose_pending"
  )
  next_execute_tool = next_execute_tool or function(tool, arguments, ctx)
    return tool.execute(arguments, ctx)
  end
  assert(type(next_execute_tool) == "function", "dialog next executor must be a function")
  return function(tool, arguments, ctx)
    local active = true
    local function require_active()
      if not active then
        error(dialog_error("Dialog capability has expired"), 0)
      end
    end
    local decorated = vim.tbl_extend("force", {}, ctx)
    ---@cast decorated Neoagent.DialogToolContext<C>
    decorated.dialog = {
      show = function(_, request)
        require_active()
        local agent = type(decorated.context) == "table" and rawget(decorated.context, "agent") or nil
        if type(request) == "table" and request.agent == nil and type(agent) == "string" and agent ~= "" then
          request = util.copy(request)
          request.agent = agent
        end
        return dialogs:show(request)
      end,
      choose_pending = function(_, action_id, reason)
        require_active()
        return dialogs:choose_pending(action_id, reason)
      end,
    }
    local ok, result = pcall(function()
      return next_execute_tool(tool, arguments, decorated)
    end)
    active = false
    if not ok then
      error(result, 0)
    end
    return result
  end
end

---@param opts? {report?: fun(message: string, level: integer)}
---@return Neoagent.Dialogs
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table" and (next(opts) == nil or not util.is_list(opts)), "dialog options must be an object")
  assert(opts.report == nil or type(opts.report) == "function", "dialog report must be a function")
  return setmetatable({
    _instance_id = tostring({}):gsub("table: ", ""),
    _state = {
      active = nil,
      queue = {},
      subscribers = {},
      next_subscriber = 0,
      next_dialog = 0,
      report = opts.report or function() end,
    },
  }, Dialogs)
end

return M
