local util = require("neoagent.util")
local renderer_protocol = require("neoagent.ui.renderer")
local renderers = require("neoagent.ui.renderers")

local M = {}
local ui_positions = { auto = true, left = true, right = true, top = true, bottom = true, center = true }

local function assert_controller(controller)
  assert(type(controller) == "table" and controller._neoagent_controller,
    "Window controllers must be Neoagent Controllers")
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.controllers) == "table" and #opts.controllers > 0,
    "Window requires at least one Controller")
  assert(type(opts.config) == "table", "Window UI config is required")
  if opts.dialogs ~= nil then
    assert(type(opts.dialogs) == "table"
      and type(opts.dialogs.subscribe) == "function"
      and type(opts.dialogs.choose) == "function"
      and type(opts.dialogs.cancel) == "function"
      and type(opts.dialogs.cancel_pending) == "function",
      "Window dialogs must provide subscribe, choose, cancel, and cancel_pending")
  end
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
  local initial_renderer = opts.config.renderer
    or renderers.get(opts.config.style)
  renderer_protocol.assert(initial_renderer, "Window Renderer")
  local state = {
    controllers = vim.list_slice(opts.controllers),
    active = opts.active or 1,
    drafts = setmetatable({}, { __mode = "k" }),
    histories = {},
    history_stores = {},
    workspace_root = nil,
    persistence = util.copy(opts.persistence),
    view = nil,
    rendered_controller = nil,
    unsubscribe = nil,
    dialog_unsubscribe = nil,
    dialog = nil,
    position = opts.config.position,
    transcript_style = opts.config.style,
    renderer = initial_renderer,
    position_loaded = false,
    provider_console_open = false,
    provider_open_request = 0,
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

  local function visible_dialog()
    if not state.dialog then return nil end
    local owner = state.dialog.active.controller
    if owner and owner ~= active():config().name then return nil end
    return util.copy(state.dialog)
  end

  local function history_store(root)
    local persistence = state.persistence
    if not persistence or not persistence.enabled then return nil end
    if not state.history_stores[root] then
      state.history_stores[root] = require("neoagent.input_history").new({
        directory = persistence.directory,
        root = root,
      })
    end
    return state.history_stores[root]
  end

  local function load_history(root, refresh)
    if not root then return {} end
    if state.histories[root] and not refresh then return state.histories[root] end
    local store = history_store(root)
    if not store then
      state.histories[root] = state.histories[root] or {}
      return state.histories[root]
    end
    local history, err = store:load()
    if not history then
      notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.WARN)
      state.histories[root] = state.histories[root] or {}
      return state.histories[root]
    end
    state.histories[root] = history
    return history
  end

  local function select_workspace(root)
    local changed = state.workspace_root ~= root
    state.workspace_root = root
    load_history(root)
    return changed
  end

  local function record_history(text)
    local root = state.workspace_root
    text = util.trim(text)
    if not root or text == "" then return true end
    local store = history_store(root)
    if not store then
      local history = load_history(root)
      if history[1] ~= text then
        table.insert(history, 1, text)
        if #history > 100 then table.remove(history) end
      end
      return true
    end
    local history, err = store:add(text)
    if not history then
      notify("input history was not saved: " .. err.message, vim.log.levels.WARN)
      return nil, err
    end
    state.histories[root] = history
    return true
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
      if select_workspace(update.context.workspace) then
        view:set_input(view:get_input())
      end
      view:set_context(context(update.context))
      if type(view.set_provider) == "function" then
        view:set_provider(update.context.provider or false)
        if state.provider_console_open and update.context.provider
            and view.provider_open ~= true then
          view:set_provider_open(true)
        end
      end
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

  local function prepared_snapshot(controller)
    local prepared, err = controller:prepare()
    if not prepared then return nil, err end
    local ok, snapshot = pcall(controller.snapshot, controller)
    if not ok then
      return nil, util.normalize_error(snapshot, "controller")
    end
    return snapshot
  end

  local function hydrate(controller, snapshot)
    controller = controller or active()
    if not snapshot then
      local err
      snapshot, err = prepared_snapshot(controller)
      if not snapshot then return nil, err end
    end
    select_workspace(snapshot.context.workspace)
    state.view:set_messages(snapshot.messages)
    state.view:set_context(context(snapshot.context))
    if type(state.view.set_provider) == "function" then
      state.view:set_provider(snapshot.context.provider or false, true)
      if state.provider_console_open and snapshot.context.provider
          and state.view.provider_open ~= true then
        state.view:set_provider_open(true)
      end
    end
    for _, event in ipairs(snapshot.events) do state.view:apply(event) end
    if snapshot.result then state.view:finish(snapshot.result) end
    state.view:set_input(state.drafts[controller] or "")
    state.rendered_controller = controller
    if opts.dialogs then state.view:set_dialog(visible_dialog()) end
    return true
  end

  local function ensure_view()
    if state.view and not state.view.destroyed then return state.view end
    local factory = opts.view or require("neoagent.ui").new
    state.rendered_controller = nil
    local view_config = util.copy(opts.config)
    view_config.style = state.transcript_style
    view_config.renderer = state.renderer
    state.view = factory({
      config = view_config,
      on_submit = function(prompt)
        local controller = active()
        local run, err = controller:send(prompt)
        if run then
          record_history(prompt)
          state.drafts[controller] = ""
          if active() == controller then state.view:set_input("") end
        end
        return run, err
      end,
      on_stop = function() return active():stop() end,
      on_dequeue_steering = function() return active():dequeue_steering() end,
      on_input_history = function() return window:input_history() end,
      on_select_history = function() return window:select_input_history() end,
      on_cycle_thinking = function() return active():cycle_thinking_level() end,
      on_cycle_agent = function() return window:cycle() end,
      on_select_model = function() return active():select_model() end,
      on_resume_session = function() return active():resume() end,
      resolve_tool = function(name)
        for _, tool in ipairs(active():get_toolset().tools) do
          if tool.name == name then return tool end
        end
      end,
      on_dialog_action = function(id, action, input)
        if not opts.dialogs then return nil end
        return opts.dialogs:choose(id, action, input)
      end,
      on_dialog_dismiss = function(id)
        if not opts.dialogs then return nil end
        return opts.dialogs:cancel(id, "dialog dismissed by user")
      end,
      on_provider_action = function(id, args)
        return active():provider_operation(id, args)
      end,
      on_provider_close = function()
        state.provider_console_open = false
      end,
      on_provider_toggle = function()
        local toggled, err = window:toggle_provider_console()
        if toggled == nil and err then
          notify(err.message, vim.log.levels.WARN)
        end
        return toggled, err
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
    if opts.dialogs then
      assert(type(state.view.set_dialog) == "function",
        "View must implement set_dialog when Window dialogs are configured")
      state.view:set_dialog(visible_dialog())
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
    local controller = state.controllers[index]
    local snapshot
    if state.view and not state.view.destroyed then
      local err
      snapshot, err = prepared_snapshot(controller)
      if not snapshot then return nil, err end
      state.drafts[active()] = state.view:get_input()
    end
    state.active = index
    if state.view and not state.view.destroyed
        and state.dialog and not visible_dialog() then
      state.view:set_dialog(nil)
    end
    subscribe()
    if state.view and not state.view.destroyed then
      local hydrated, err = hydrate(controller, snapshot)
      if not hydrated then return nil, err end
    end
    return controller
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
    state.provider_console_open = false
    state.view:close()
  end

  function window:toggle()
    if state.view and state.view:is_open() then self:close() else return self:open() end
  end

  function window:is_open()
    return state.view ~= nil and state.view:is_open()
  end

  function window:view()
    return state.view
  end

  function window:rendered_controller()
    return state.rendered_controller
  end

  function window:set_position(position)
    if not ui_positions[position] then return nil, util.error("ui", "invalid window position") end
    state.position = position
    state.position_loaded = true
    local saved, err = active():set_ui_position(position)
    if state.view and not state.view.destroyed then
      state.view:set_context(context(active():snapshot().context))
    end
    if not saved then
      notify("window position changed but workspace settings were not saved: " .. err.message,
        vim.log.levels.WARN)
    end
    return position, err
  end

  function window:set_renderer(renderer)
    local selected, err = renderer_protocol.validate(renderer)
    if not selected then return nil, err end
    if state.view and not state.view.destroyed
        and type(state.view.set_renderer) ~= "function" then
      return nil, util.error(
        "ui", "the active View does not support Renderers")
    end
    if state.view and not state.view.destroyed then
      local installed, install_err = state.view:set_renderer(selected)
      if not installed then return nil, install_err end
    end
    state.renderer = selected
    return selected
  end

  function window:set_transcript_style(style)
    local renderer = renderers.get(style)
    if not renderer then
      return nil, util.error("ui", "invalid transcript style")
    end
    local selected, err = self:set_renderer(renderer)
    if not selected then return nil, err end
    state.transcript_style = style
    if state.view and not state.view.destroyed then
      state.view.config.style = style
    end
    return style
  end

  function window:set_input(value)
    assert(type(value) == "string", "Window input must be a string")
    state.drafts[active()] = value
    if state.view and not state.view.destroyed and state.rendered_controller == active() then
      state.view:set_input(value)
    end
    return value
  end

  function window:set_provider_console(open)
    assert(type(open) == "boolean", "provider console visibility must be boolean")
    state.provider_open_request = state.provider_open_request + 1
    local request = state.provider_open_request
    if open then
      if state.destroyed then
        return nil, util.error("ui", "Window is destroyed")
      end
      local controller = active()
      if type(controller.is_destroyed) == "function"
          and controller:is_destroyed() then
        return nil, util.error("controller", "Controller is destroyed")
      end
      local snapshot, err = prepared_snapshot(controller)
      if not snapshot then return nil, err end
      if not controller:provider_service_bound() then
        local providers = controller:console_providers()
        if #providers == 1 then
          local bound, bind_err = controller:bind_provider(providers[1].id)
          if not bound then return nil, bind_err end
          snapshot = controller:snapshot()
        elseif #providers > 1 then
          local picked = controller:select_console_provider(function()
            util.schedule(function()
              if state.destroyed or request ~= state.provider_open_request
                  or active() ~= controller
                  or type(controller.is_destroyed) == "function"
                    and controller:is_destroyed() then
                return
              end
              window:set_provider_console(true)
            end)
          end)
          if picked ~= nil then return true end
        elseif not snapshot.context.provider then
          notify("the active provider has no console service", vim.log.levels.WARN)
          return nil
        end
      end
      local view, view_err = ensure_view()
      if not view then return nil, view_err end
      if state.rendered_controller ~= active() then
        local hydrated, hydrate_err = hydrate(controller, snapshot)
        if not hydrated then return nil, hydrate_err end
      end
      local main_opened, main_err = self:open()
      if not main_opened then return nil, main_err end
      if type(view.set_provider_open) ~= "function" then
        notify("the active View does not support the provider console",
          vim.log.levels.WARN)
        return nil
      end
      local opened, open_err = view:set_provider_open(true)
      if not opened then
        if open_err then notify(open_err.message, vim.log.levels.WARN) end
        return nil, open_err
      end
      state.provider_console_open = true
      return true
    end
    state.provider_console_open = false
    if state.view and not state.view.destroyed
        and type(state.view.set_provider_open) == "function" then
      state.view:set_provider_open(false)
    end
    return true
  end

  function window:toggle_provider_console()
    return self:set_provider_console(not state.provider_console_open)
  end

  function window:provider_console_open()
    return state.provider_console_open
  end

  function window:get_input()
    if state.view and not state.view.destroyed
        and state.rendered_controller == active() then
      return state.view:get_input()
    end
    return state.drafts[active()] or ""
  end

  function window:input_history()
    return util.copy(load_history(state.workspace_root))
  end

  function window:add_input_history(value)
    assert(type(value) == "string", "Window history input must be a string")
    return record_history(value)
  end

  function window:select_input_history()
    local history = self:input_history()
    if #history == 0 then notify("no input history found for the current workspace") return nil end
    vim.ui.select(history, {
      prompt = "Select input history:",
      format_item = function(item)
        local label = util.trim(item:gsub("[%c%s]+", " "))
        if vim.fn.strchars(label) > 100 then
          label = vim.fn.strcharpart(label, 0, 100) .. "…"
        end
        return label
      end,
    }, function(choice)
      if not choice then return end
      self:set_input(choice)
      if state.view and state.view:is_open() and type(state.view.focus_input) == "function" then
        state.view:focus_input()
      end
    end)
    return true
  end

  function window:destroy()
    if state.destroyed then return end
    state.destroyed = true
    state.provider_open_request = state.provider_open_request + 1
    if opts.dialogs then
      opts.dialogs:cancel_pending("dialog Window destroyed", {
        presenter_unavailable = true,
      })
    end
    if state.view and not state.view.destroyed then
      state.drafts[active()] = state.view:get_input()
      state.view:destroy()
    end
    state.view = nil
    state.rendered_controller = nil
    if state.unsubscribe then state.unsubscribe() end
    state.unsubscribe = nil
    if state.dialog_unsubscribe then state.dialog_unsubscribe() end
    state.dialog_unsubscribe = nil
  end

  subscribe()
  if opts.dialogs then
    state.dialog_unsubscribe =
      opts.dialogs:subscribe(function(snapshot)
        state.dialog = snapshot.active and util.copy(snapshot) or nil
        if state.destroyed then return end
        if snapshot.active and visible_dialog() then
          local ok, opened = pcall(window.open, window)
          if not ok or not opened then
            opts.dialogs:cancel_pending(
              "dialog presenter unavailable", {
                presenter_unavailable = true,
              })
            return
          end
          if state.view and not state.view.destroyed then
            local presented = pcall(
              state.view.set_dialog, state.view, visible_dialog())
            if not presented then
              opts.dialogs:cancel_pending(
                "dialog presenter unavailable", {
                  presenter_unavailable = true,
                })
            end
          end
        elseif state.view and not state.view.destroyed
            and type(state.view.set_dialog) == "function" then
          pcall(state.view.set_dialog, state.view, nil)
        end
      end)
  end
  return window
end

return M
