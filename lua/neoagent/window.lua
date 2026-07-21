local util = require("neoagent.util")

local M = {}

local function assert_controller(controller)
  assert(type(controller) == "table" and controller._neoagent_controller,
    "Window controllers must be Neoagent Controllers")
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.controllers) == "table" and #opts.controllers > 0,
    "Window requires at least one Controller")
  assert(type(opts.config) == "table", "Window UI config is required")
  local names = {}
  for _, controller in ipairs(opts.controllers) do
    assert_controller(controller)
    local name = controller:config().name
    assert(type(name) == "string" and name ~= "",
      "Window Controllers require non-empty names")
    assert(not names[name], "Window Controller names must be unique: " .. name)
    names[name] = true
  end

  local window = { _neoagent_window = true }
  local state = {
    controllers = vim.list_slice(opts.controllers),
    active = opts.active or 1,
    drafts = setmetatable({}, { __mode = "k" }),
    view = nil,
    rendered_controller = nil,
    unsubscribe = nil,
    position = opts.config.position,
    position_loaded = false,
    destroyed = false,
  }
  assert(type(state.active) == "number" and state.controllers[state.active],
    "Window active controller index is invalid")

  local function notify(message, level)
    vim.notify("neoagent: " .. message, level or vim.log.levels.INFO)
  end

  local function active()
    return state.controllers[state.active]
  end

  local function context(value)
    value = util.copy(value or {})
    if not state.position_loaded and value.position then
      state.position = value.position
      state.position_loaded = true
    end
    value.position = state.position
    return value
  end

  local function apply(update)
    local view = state.view
    if not view or view.destroyed then return end
    if update.type == "context" then
      view:set_context(context(update.context))
    elseif update.type == "messages" then
      view:set_messages(update.messages)
    elseif update.type == "event" then
      view:apply(update.event)
    elseif update.type == "finish" then
      view:finish(update.result)
    end
  end

  local function subscribe()
    if state.unsubscribe then state.unsubscribe() end
    state.unsubscribe = active():subscribe(apply)
  end

  local function hydrate()
    local controller = active()
    local prepared, err = controller:prepare()
    if not prepared then return nil, err end
    local snapshot = controller:snapshot()
    state.view:set_messages(snapshot.messages)
    state.view:set_context(context(snapshot.context))
    for _, event in ipairs(snapshot.events) do state.view:apply(event) end
    if snapshot.result then state.view:finish(snapshot.result) end
    state.view:set_input(state.drafts[controller] or "")
    state.rendered_controller = controller
    return true
  end

  local function ensure_view()
    if state.view and not state.view.destroyed then return state.view end
    local factory = opts.view or require("neoagent.ui").new
    state.rendered_controller = nil
    state.view = factory({
      config = util.copy(opts.config),
      on_submit = function(prompt)
        local controller = active()
        local run, err = controller:send(prompt)
        if run then
          state.drafts[controller] = ""
          if active() == controller then state.view:set_input("") end
        end
        return run, err
      end,
      on_stop = function() return active():stop() end,
      on_cycle_thinking = function() return active():cycle_thinking_level() end,
      on_cycle_agent = function() return window:cycle() end,
      on_select_model = function() return active():select_model() end,
      on_resume_session = function() return active():resume() end,
      on_position_change = function(position)
        state.position = position
        state.position_loaded = true
        local saved, err = active():set_ui_position(position)
        if not saved then
          notify("window position changed but workspace settings were not saved: " .. err.message,
            vim.log.levels.WARN)
        end
      end,
      window = window,
    })
    assert(type(state.view) == "table", "View factory must return a View")
    for _, method in ipairs({
      "open", "close", "is_open", "destroy", "get_input", "set_input",
      "set_messages", "set_context", "apply", "finish",
    }) do
      assert(type(state.view[method]) == "function", "View must implement " .. method)
    end
    return state.view
  end

  function window:active()
    return active()
  end

  function window:controllers()
    return vim.list_slice(state.controllers)
  end

  function window:select(value)
    assert(not state.destroyed, "Window is destroyed")
    local index = value
    if type(value) == "table" then
      index = nil
      for candidate, controller in ipairs(state.controllers) do
        if controller == value then index = candidate break end
      end
    end
    assert(type(index) == "number" and state.controllers[index],
      "Controller is not attached to this Window")
    if index == state.active then return active() end
    if state.view and not state.view.destroyed then
      state.drafts[active()] = state.view:get_input()
    end
    state.active = index
    subscribe()
    if state.view and not state.view.destroyed then
      local hydrated, err = hydrate()
      if not hydrated then return nil, err end
    end
    return active()
  end

  function window:cycle()
    local index = state.active % #state.controllers + 1
    local controller = self:select(index)
    if #state.controllers > 1 and controller then
      local name = controller:config().name
      notify("agent: " .. (name or tostring(index)))
    end
    return controller
  end

  function window:open()
    if state.destroyed then return nil, util.error("ui", "Window is destroyed") end
    local view, err = ensure_view()
    if not view then return nil, err end
    if state.rendered_controller ~= active() then
      local hydrated, hydrate_err = hydrate()
      if not hydrated then return nil, hydrate_err end
    end
    return view:open()
  end

  function window:close()
    if not state.view then return end
    state.drafts[active()] = state.view:get_input()
    state.view:close()
  end

  function window:toggle()
    if state.view and state.view:is_open() then self:close() else return self:open() end
  end

  function window:is_open()
    return state.view ~= nil and state.view:is_open()
  end

  function window:set_input(value)
    assert(type(value) == "string", "Window input must be a string")
    state.drafts[active()] = value
    if state.view and not state.view.destroyed and state.rendered_controller == active() then
      state.view:set_input(value)
    end
    return value
  end

  function window:_state()
    return state
  end

  function window:destroy()
    if state.destroyed then return end
    state.destroyed = true
    if state.view and not state.view.destroyed then
      state.drafts[active()] = state.view:get_input()
      state.view:destroy()
    end
    state.view = nil
    state.rendered_controller = nil
    if state.unsubscribe then state.unsubscribe() end
    state.unsubscribe = nil
  end

  subscribe()
  return window
end

return M
