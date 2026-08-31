local Applet = require("applet")
local Provider = require("neoagent.ui.panes.provider")
local Providers = require("neoagent.ui.panes.providers")
local renderer_protocol = require("neoagent.ui.renderer")
local util = require("neoagent.util")

local layout = Applet.layout
local M = {}
local View = {}
View.__index = View

local window_options = {
  wrap = false,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = true,
  winhl = "NormalFloat:Normal,FloatBorder:NeoagentBorder,FloatTitle:NeoagentWindowTitle",
}

local function mount(component, config, required)
  local pane = component.pane or component
  return layout.mount(pane, {
    lifecycle = "retained",
    required = required == true,
    buffer = {
      name = pane:key(),
      filetype = "neoagent-provider",
      options = { buftype = "nofile", swapfile = false, undofile = false },
    },
    window = {
      border = config.border,
      options = window_options,
    },
    focus = { mode = "normal", cursor = "preserve" },
  })
end

local function presentation_mount(component, config, opts)
  local pane = component.pane or component
  local options = util.copy(window_options)
  for key, value in pairs(opts.window_options or {}) do options[key] = value end
  return layout.mount(pane, {
    lifecycle = "transient",
    owns_pane = true,
    mount_revision = opts.revision,
    buffer = {
      name = pane:key(),
      filetype = opts.filetype,
      sensitive = opts.sensitive,
      options = { buftype = "nofile", swapfile = false, undofile = false },
    },
    window = {
      border = config.border,
      options = options,
    },
    focus = { mode = opts.mode, cursor = "preserve" },
  })
end

local function dimension(value, fallback)
  return value == nil and fallback or value
end

function View.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "Provider Shell UI config is required")
  local renderer = opts.renderer or opts.config.renderer
  renderer_protocol.assert(renderer, "Provider Shell Renderer")
  local defined, err = renderer_protocol.define_highlights(renderer)
  assert(defined, err and err.message or "Provider Shell highlights failed")

  local self = setmetatable({
    config = util.copy(opts.config),
    renderer = renderer,
    callbacks = {
      action = opts.on_action or function() end,
      select = opts.on_select or function() end,
      previous = opts.on_previous or function() end,
      next = opts.on_next or function() end,
      close = opts.on_close or function() end,
      presentation_resolve = opts.on_presentation_resolve or function() end,
      presentation_cancel = opts.on_presentation_cancel or function() end,
    },
    on_error = opts.on_error,
    applet_theme = renderer.theme,
    provider_count = 0,
    provider_id = nil,
    presentation = nil,
    presentation_component = nil,
    presentation_seed = nil,
    destroyed = false,
  }, View)
  self.provider = Provider.new({
    config = self.config,
    theme = renderer.theme,
    callbacks = {
      run = self.callbacks.action,
      previous = self.callbacks.previous,
      next = self.callbacks.next,
      close = function() self:close() end,
    },
    on_error = opts.on_error,
  })
  self.providers = Providers.new({
    config = self.config,
    theme = renderer.theme,
    callbacks = {
      select = self.callbacks.select,
      close = function() self:close() end,
    },
    on_error = opts.on_error,
  })
  local shell_config = self.config.provider_shell or {}
  self.applet = Applet.new({
    name = "neoagent-provider-shell",
    host = opts.host or function()
      return Applet.host.floating({
        container = "editor",
        side = shell_config.position or "center",
        width = dimension(shell_config.width, 0.75),
        height = dimension(shell_config.height, 0.75),
        margin = self.config.margin == nil and 1 or self.config.margin,
        base_zindex = 80,
      })
    end,
    render = function(_, env) return self:_render(env) end,
    on_pane_close = function(event, default)
      self:_pane_detached(event.pane and event.pane:key(), default)
    end,
    on_pane_buffer_change = function(event, default)
      self:_pane_detached(event.pane and event.pane:key(), default)
    end,
    on_error = opts.on_error,
    notify = opts.notify,
    open_uri = opts.open_uri,
  })
  self.applet:set_state({ revision = 0 })
  return self
end

function View:_render(env)
  local provider = mount(self.provider, self.config, true)
  local child = provider
  if self.provider_count > 1 then
    child = layout.split({
      key = "provider-shell:split",
      axis = "horizontal",
      children = {
        { key = "providers", basis = 22, grow = 0, min = 20,
          child = mount(self.providers, self.config, true) },
        { key = "provider", grow = 1, min = 24, child = provider },
      },
    })
  end
  local layers = {}
  if self.presentation and self.presentation.active
      and self.presentation_component then
    local request = self.presentation.active
    local presentation = self.presentation_component
    local editable = request.kind == "input"
    local secret = editable and request.secret == true
    local presentation_child
    if editable then
      presentation_child = presentation_mount(presentation, self.config, {
        revision = request.id,
        filetype = secret and "neoagent-secret" or "neoagent-prompt",
        sensitive = secret,
        mode = "insert",
        window_options = {
          wrap = request.multiline == true,
          cursorline = false,
          conceallevel = secret and 2 or nil,
          concealcursor = secret and "niv" or nil,
        },
      })
    elseif request.kind == "notice" then
      presentation_child = presentation_mount(presentation, self.config, {
        revision = request.id,
        filetype = "neoagent-notice",
        mode = "normal",
        window_options = { wrap = true, cursorline = false },
      })
    else
      presentation_child = layout.split({
        key = "provider-shell:presentation-split",
        axis = "vertical",
        revision = request.id,
        children = {
          {
            key = "filter",
            basis = { content = true },
            grow = 0,
            child = presentation_mount(presentation.filter, self.config, {
              revision = request.id .. ":filter",
              filetype = "neoagent-prompt",
              mode = "insert",
              window_options = { wrap = false, cursorline = false },
            }),
          },
          {
            key = "results",
            basis = { content = true },
            grow = 0,
            child = presentation_mount(presentation.results, self.config, {
              revision = request.id .. ":results",
              filetype = "neoagent-prompt",
              mode = "normal",
              window_options = { wrap = false, cursorline = false },
            }),
          },
        },
      })
    end
    local bounds = env.host.bounds
    layers[1] = layout.layer({
      key = "provider-shell:presentation-layer",
      container = "applet",
      anchor = "center",
      width = math.max(3, math.min(80, bounds.width - 2)),
      height = editable and math.max(4, math.min(bounds.height - 2,
          request.multiline and 12 or 6))
        or { content = true, max = math.max(3, bounds.height - 2) },
      modal = true,
      enter = true,
      restore_focus = true,
      child = presentation_child,
    })
  end
  return {
    root = layout.frame({
      key = "provider-shell:frame",
      child = child,
      layers = layers,
    }),
    focus = { initial = "provider" },
  }
end

function View:_submit()
  self.revision = (self.revision or 0) + 1
  self.applet:set_state({ revision = self.revision })
end

function View:set(snapshot, providers)
  local changed_provider = self.provider_id ~= nil
    and snapshot and snapshot.id ~= self.provider_id
  self.provider_id = snapshot and snapshot.id or nil
  self.provider:set(snapshot)
  self.providers:set(providers)
  self.provider_count = #(providers or {})
  self:_submit()
  if self:is_open() then
    local ok, err = self.applet:flush()
    if not ok then return nil, err end
    if changed_provider then self.provider:focus_initial() end
  end
  return true
end

function View:_new_presentation_component(active)
  return Applet.presentation.new({
    key = "presentation",
    filter_key = "presentation-filter",
    results_key = "presentation-results",
    request = active,
    theme = self.applet_theme,
    on_choose = function(value)
      self.callbacks.presentation_resolve(active.id, value)
    end,
    on_cancel = function()
      self.callbacks.presentation_cancel(active.id)
    end,
    on_error = self.on_error,
  })
end

function View:_ensure_presentation_component()
  local active = self.presentation and self.presentation.active
  if not active then return false end
  local current = self.presentation_component
  local editable = current and current:editable_pane() or nil
  local results = current and current.pane or nil
  if current and not current:is_destroyed()
      and editable and not editable:is_destroyed()
      and results and not results:is_destroyed() then
    return false
  end
  if current then current:destroy() end
  self.presentation_component = self:_new_presentation_component(active)
  return true
end

function View:_seed_presentation()
  local component = self.presentation_component
  local editable = component and component:editable_pane() or nil
  if self.presentation_seed == nil or not editable
      or not editable:is_editable() or not editable:is_connected() then
    return false
  end
  local value = self.presentation_seed
  self.presentation_seed = nil
  component:set_text(value)
  return true
end

function View:set_presentation(snapshot)
  assert(snapshot == nil or type(snapshot) == "table",
    "presentation snapshot must be a table")
  snapshot = snapshot and util.copy(snapshot)
    or { active = nil, queue_count = 0 }
  local active = snapshot.active
  if active then
    assert(type(active.id) == "string" and active.id ~= ""
        and (active.kind == "select" or active.kind == "input"
          or active.kind == "notice"),
      "presentation request is invalid")
  end
  local current = self.presentation and self.presentation.active
  if current and active and current.id == active.id
      and current.kind == active.kind then
    if active.kind == "select" and self.presentation_component then
      self.presentation_component:set_items(active.items)
    end
    self.presentation = snapshot
    return true
  end

  local previous_snapshot = self.presentation
  local previous_component = self.presentation_component
  local next_component = active and self:_new_presentation_component(active)
    or nil
  self.presentation = active and snapshot or nil
  self.presentation_component = next_component
  self.presentation_seed = active and active.kind == "input"
      and (active.default or "") or nil
  self:_submit()
  if self:is_open() then
    local committed, err = self.applet:flush()
    if not committed then
      self.presentation = previous_snapshot
      self.presentation_component = previous_component
      self.presentation_seed = nil
      self:_submit()
      self.applet:flush()
      if next_component then next_component:destroy() end
      return nil, err
    end
    self:_seed_presentation()
  end
  if previous_component and not self:is_open() then
    previous_component:destroy()
  end
  return true
end

function View:_pane_detached(key, default)
  default()
  if key == "presentation" or key == "presentation-filter"
      or key == "presentation-results" then
    local id = self.presentation and self.presentation.active
      and self.presentation.active.id
    if id then self.callbacks.presentation_cancel(id) end
  else
    self:close()
  end
end

function View:open(origin)
  if self.destroyed then
    return nil, util.error("ui", "Provider Shell View is destroyed")
  end
  if self:is_open() then
    self.provider:focus_initial()
    return true
  end
  if self:_ensure_presentation_component() then self:_submit() end
  local opened, err = self.applet:open({ origin = origin })
  if not opened then return nil, err end
  self.provider:focus_initial()
  self:_seed_presentation()
  return true
end

function View:close()
  if self.destroyed or not self:is_open() then return false end
  if self.presentation and self.presentation.active
      and self.presentation.active.kind == "input" then
    self.presentation_seed = self.presentation.active.default or ""
  end
  self.applet:close()
  self.callbacks.close()
  return true
end

function View:is_open()
  return not self.destroyed and self.applet:is_open()
end

function View:pane(key)
  return self.applet:pane(key)
end

function View:notify(message, level)
  return self.applet:notify(message, level)
end

function View:open_uri(uri)
  return self.applet:open_uri(uri)
end

function View:destroy()
  if self.destroyed then return end
  self.destroyed = true
  self.applet:destroy()
  if self.presentation_component then self.presentation_component:destroy() end
  self.presentation, self.presentation_component = nil, nil
  self.provider:destroy()
  self.providers:destroy()
end

M.new = View.new
M.View = View

return M
