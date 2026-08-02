local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local Dialogs = {}
Dialogs.__index = Dialogs

local function dialog_error(message)
  return util.error("dialog", message)
end

local function snapshot(state)
  return {
    active = state.active and util.copy(state.active.dialog) or nil,
    queue_count = #state.queue,
  }
end

local function publish(state)
  local value = snapshot(state)
  for _, subscriber in pairs(state.subscribers) do
    local ok, err = pcall(subscriber, util.copy(value))
    if not ok then
      vim.notify("neoagent dialog subscriber failed: " .. tostring(err),
        vim.log.levels.ERROR)
    end
  end
end

local function remove(state, entry)
  if state.active == entry then
    state.active = table.remove(state.queue, 1)
    publish(state)
    return true
  end
  for index, queued in ipairs(state.queue) do
    if queued == entry then
      table.remove(state.queue, index)
      publish(state)
      return true
    end
  end
  return false
end

local function valid_text(value, limit, allow_empty)
  return type(value) == "string" and (allow_empty or value ~= "")
    and #value <= limit
    and not value:find("\0", 1, true)
end

local function validate_dialog(dialog)
  assert(type(dialog) == "table"
    and (next(dialog) == nil or not util.is_list(dialog)),
    "dialog must be an object")
  assert(dialog.placement == "transcript" or dialog.placement == "float",
    "dialog placement must be transcript or float")
  assert(dialog.controller == nil or valid_text(dialog.controller, 512),
    "dialog controller must be a non-empty string")
  assert(valid_text(dialog.title, 512), "dialog title is invalid")
  assert(valid_text(dialog.body, 16 * 1024, true),
    "dialog body is invalid")
  if dialog.input ~= nil then
    assert(dialog.placement == "float",
      "dialog input requires float placement")
    assert(type(dialog.input) == "table"
      and (next(dialog.input) == nil or not util.is_list(dialog.input)),
      "dialog input must be an object")
    assert(valid_text(dialog.input.label, 256),
      "dialog input label is invalid")
    assert(valid_text(dialog.input.value, 16 * 1024, true),
      "dialog input value is invalid")
    assert(type(dialog.input.multiline) == "boolean",
      "dialog input multiline must be boolean")
  end
  assert(type(dialog.actions) == "table" and util.is_list(dialog.actions)
    and #dialog.actions > 0 and #dialog.actions <= 16,
    "dialog actions must be a non-empty list of at most 16 actions")
  local ids, keys = {}, {}
  for _, action in ipairs(dialog.actions) do
    assert(type(action) == "table"
      and (next(action) == nil or not util.is_list(action)),
      "dialog action must be an object")
    assert(valid_text(action.id, 128), "dialog action id is invalid")
    assert(valid_text(action.label, 256),
      "dialog action label is invalid")
    assert(valid_text(action.key, 64), "dialog action key is invalid")
    assert(not ids[action.id], "dialog action ids must be distinct")
    assert(not keys[action.key], "dialog action keys must be distinct")
    ids[action.id], keys[action.key] = true, true
  end
end

local function has_action(dialog, action_id)
  for _, action in ipairs(dialog.actions) do
    if action.id == action_id then return true end
  end
  return false
end

local function validate_input(dialog, value)
  if not dialog.input then
    assert(value == nil, "dialog response cannot include input")
    return nil
  end
  assert(valid_text(value, 16 * 1024, true),
    "dialog response input is invalid")
  assert(dialog.input.multiline or not value:find("\n", 1, true),
    "dialog response input must be one line")
  return value
end

function Dialogs:show(dialog)
  validate_dialog(dialog)
  dialog = util.copy(dialog)
  local state = self._state
  state.next_dialog = state.next_dialog + 1
  dialog.id = "dialog-" .. self._instance_id .. "-" .. state.next_dialog
  return async.run(function()
    if next(state.subscribers) == nil then
      return {
        ok = false,
        error = dialog_error(
          "Dialog is unavailable because no presenter is attached"),
      }
    end
    local selected = async.await(function(done)
      local entry = { dialog = dialog, done = done, resolved = false }
      if state.active then
        state.queue[#state.queue + 1] = entry
      else
        state.active = entry
      end
      publish(state)
      return function()
        if not entry.resolved then remove(state, entry) end
      end
    end)
    return selected
  end, { error_kind = "dialog" })
end

function Dialogs:subscribe(callback)
  assert(type(callback) == "function",
    "dialog subscriber must be a function")
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
    if not active then return end
    active = false
    state.subscribers[id] = nil
    if next(state.subscribers) == nil then
      self:cancel_pending("dialog presenter detached", {
        presenter_unavailable = true,
      })
    end
  end
end

function Dialogs:choose(id, action_id, input)
  assert(type(id) == "string" and id ~= "", "dialog id is required")
  assert(type(action_id) == "string" and action_id ~= "",
    "dialog action id is required")
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

function Dialogs:cancel(id, reason, opts)
  assert(type(id) == "string" and id ~= "", "dialog id is required")
  opts = opts or {}
  assert(type(opts) == "table"
    and (next(opts) == nil or not util.is_list(opts)),
    "dialog cancellation options must be an object")
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
    presenter_unavailable =
      opts.presenter_unavailable == true and true or nil,
  })
  publish(state)
  return true
end

function Dialogs:choose_pending(action_id, reason)
  assert(type(action_id) == "string" and action_id ~= "",
    "dialog action id is required")
  local state, pending = self._state, {}
  if state.active then pending[#pending + 1] = state.active end
  vim.list_extend(pending, state.queue)
  for _, entry in ipairs(pending) do
    if not has_action(entry.dialog, action_id) then
      return nil, dialog_error(
        "A pending dialog does not provide action: " .. action_id)
    end
    if entry.dialog.input then
      return nil, dialog_error(
        "A pending dialog requires an individual input response")
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
  if #pending > 0 then publish(state) end
  return #pending
end

function Dialogs:cancel_pending(reason, opts)
  opts = opts or {}
  assert(type(opts) == "table"
    and (next(opts) == nil or not util.is_list(opts)),
    "dialog cancellation options must be an object")
  local state, pending = self._state, {}
  if state.active then pending[#pending + 1] = state.active end
  vim.list_extend(pending, state.queue)
  state.active, state.queue = nil, {}
  for _, entry in ipairs(pending) do
    if not entry.resolved then
      entry.resolved = true
      entry.done.resolve({
        ok = false,
        error = dialog_error(reason or "Dialog was cancelled"),
        presenter_unavailable =
          opts.presenter_unavailable == true and true or nil,
      })
    end
  end
  if #pending > 0 then publish(state) end
  return #pending
end

function Dialogs:snapshot()
  return snapshot(self._state)
end

function M.wrap(dialogs, next_execute_tool)
  assert(type(dialogs) == "table"
    and type(dialogs.show) == "function"
    and type(dialogs.choose_pending) == "function",
    "dialog source must implement show and choose_pending")
  next_execute_tool = next_execute_tool or function(tool, arguments, ctx)
    return tool.execute(arguments, ctx)
  end
  assert(type(next_execute_tool) == "function",
    "dialog next executor must be a function")
  return function(tool, arguments, ctx)
    local active = true
    local function require_active()
      if not active then
        error(dialog_error("Dialog capability has expired"), 0)
      end
    end
    local decorated = {}
    for key, value in pairs(ctx or {}) do decorated[key] = value end
    decorated.dialog = {
      show = function(_, request)
        require_active()
        local controller = type(decorated.context) == "table"
            and decorated.context.controller
          or nil
        if type(request) == "table" and request.controller == nil
            and type(controller) == "string" and controller ~= "" then
          request = util.copy(request)
          request.controller = controller
        end
        return dialogs:show(request)
      end,
      choose_pending = function(_, action_id, reason)
        require_active()
        return dialogs:choose_pending(action_id, reason)
      end,
    }
    local executed = { pcall(next_execute_tool,
      tool, arguments, decorated) }
    active = false
    local ok = table.remove(executed, 1)
    if not ok then error(executed[1], 0) end
    return unpack(executed)
  end
end

function M.new()
  return setmetatable({
    _instance_id = tostring({}):gsub("table: ", ""),
    _state = {
      active = nil,
      queue = {},
      subscribers = {},
      next_subscriber = 0,
      next_dialog = 0,
    },
  }, Dialogs)
end

return M
