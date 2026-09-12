local Applet = require("applet")
local Details = require("neoagent.ui.panes.details")
local Dialog = require("neoagent.ui.panes.dialog")
local Input = require("neoagent.ui.panes.input")
local presentation_surface = require("neoagent.ui.presentation_surface")
local Transcript = require("neoagent.ui.panes.transcript")
local protocol = require("neoagent.ui.renderer")
local renderers = require("neoagent.ui.renderers")
local image_source = require("neoagent.ui.image_source")
local util = require("neoagent.util")

local layout = Applet.layout

---@class Neoagent.ViewCallbacks
---@field on_submit fun(text: string): unknown
---@field on_stop fun(): unknown
---@field on_dequeue_steering fun(): string[]
---@field on_input_history fun(): string[]
---@field on_select_history fun(): unknown
---@field on_cycle_thinking fun(): unknown
---@field on_agents fun(): unknown
---@field on_select_model fun(): unknown
---@field on_resume_session fun(): unknown
---@field on_dialog_action fun(id: string, action: string, input?: string): unknown
---@field on_dialog_dismiss fun(id: string): unknown
---@field on_provider_shell? fun(): unknown
---@field on_help fun(request: Neoagent.NoticeRequest): unknown
---@field on_close fun(): unknown
---@field on_presentation_resolve fun(id: string, value: string): unknown
---@field on_presentation_cancel fun(id: string): unknown
---@field resolve_tool fun(name?: string): Neoagent.RenderTool?

---@alias Neoagent.ViewHostFactory Applet.HostInput|fun(state: Neoagent.ViewState, config: Neoagent.UIConfig): Applet.HostInput

---@class Neoagent.ViewOptions
---@field files? Neoagent.FileSource
---@field config Neoagent.UIConfig
---@field renderer? Neoagent.Renderer<unknown>
---@field image_system? Applet.ImageSystem|false
---@field host_factory? Neoagent.ViewHostFactory
---@field host? Neoagent.ViewHostFactory
---@field on_error? fun(error: Applet.Error|Applet.PaneError)
---@field notify? fun(message: string, level?: integer)
---@field open_uri? fun(uri: string): vim.SystemObj?, string?
---@field on_submit? fun(text: string): unknown
---@field on_stop? fun(): unknown
---@field on_dequeue_steering? fun(): string[]
---@field on_input_history? fun(): string[]
---@field on_select_history? fun(): unknown
---@field on_cycle_thinking? fun(): unknown
---@field on_agents? fun(): unknown
---@field on_select_model? fun(): unknown
---@field on_resume_session? fun(): unknown
---@field on_dialog_action? fun(id: string, action: string, input?: string): unknown
---@field on_dialog_dismiss? fun(id: string): unknown
---@field on_provider_shell? fun(): unknown
---@field on_help? fun(request: Neoagent.NoticeRequest): unknown
---@field on_close? fun(): unknown
---@field on_presentation_resolve? fun(id: string, value: string): unknown
---@field on_presentation_cancel? fun(id: string): unknown
---@field resolve_tool? fun(name?: string): Neoagent.RenderTool?

---@class Neoagent.ViewState
---@field revision integer
---@field position Neoagent.UiPosition
---@field focus_intent? {key: string, revision: integer}
---@field config {border: Applet.WindowBorder, input_height: integer}
---@field host_config Neoagent.UIConfig
---@field transcript Neoagent.TranscriptPane
---@field input Neoagent.InputPane
---@field bindings {transcript: Applet.Binding[], input: Applet.Binding[]}
---@field inline_dialog boolean
---@field details? Neoagent.DetailsPane
---@field dialog? {component: Neoagent.DialogPane, editable: boolean, enter: boolean}
---@field presentation? {component: Applet.Presentation, request: Neoagent.PublicPresentation}

---@class Neoagent.ViewPaneOptions
---@field lifecycle? Applet.MountLifecycle
---@field owns_pane? boolean
---@field required? boolean
---@field mount_revision? string|number
---@field filetype? string
---@field sensitive? boolean
---@field border? Applet.WindowBorder
---@field window_options? Applet.Options
---@field mode? 'normal'|'insert'|'preserve'
---@field cursor? 'preserve'|'start'|'end'
---@field bindings? Applet.Binding[]

---@class Neoagent.View: Neoagent.PresentationSurfaceView
---@field image_source? Neoagent.ImageSourceFactory
---@field image_reader? Applet.ImageResourceReader
---@field files_identity? string
---@field config Neoagent.UIConfig
---@field renderer Neoagent.Renderer<unknown>
---@field applet_theme Applet.Theme
---@field image_system? Applet.ImageSystem
---@field owns_image_system boolean
---@field callbacks Neoagent.ViewCallbacks
---@field on_error? fun(error: Applet.Error|Applet.PaneError)
---@field host_factory? Neoagent.ViewHostFactory
---@field context Neoagent.AgentContext
---@field position Neoagent.UiPosition
---@field dialog? Neoagent.ActiveDialogSnapshot
---@field details? Neoagent.DetailsPane
---@field details_component? Neoagent.DetailsPane
---@field dialog_component? Neoagent.DialogPane
---@field destroyed boolean
---@field spinner_frames string[]
---@field spinner_frame integer
---@field spinner_timer? uv.uv_timer_t
---@field frame_revision integer
---@field focus_revision integer
---@field transcript Neoagent.TranscriptPane
---@field input Neoagent.InputPane
---@field applet Applet.Applet<Neoagent.ViewState>
---@field blocks Neoagent.TranscriptBlock[]
---@field messages Neoagent.TranscriptMessage[]
---@field has_opened? boolean
local View = {}
View.__index = View

---@type Applet.Options
local common_window_options = {
  wrap = true,
  linebreak = true,
  breakindent = true,
  breakindentopt = "",
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  winhl = "NormalFloat:Normal,FloatBorder:NeoagentBorder," .. "FloatTitle:NeoagentWindowTitle",
}

---@generic T
---@param base T
---@param values T?
---@return T
local function copy_extend(base, values)
  local result = util.copy(base or {})
  for key, value in pairs(values or {}) do
    result[key] = value
  end
  return result
end

---@param value Neoagent.UIMapping?
---@return string?
local function mapping_hint(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    return value[1]
  end
end

---@param value Neoagent.UIMapping?
---@return string[]
local function mapping_values(value)
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
---@param desc string
local function add_applet_binding(result, modes, lhs, action, desc)
  modes = type(modes) == "table" and modes or { modes }
  for _, mode in ipairs(modes) do
    for _, key in ipairs(mapping_values(lhs)) do
      result[#result + 1] = {
        mode = mode,
        lhs = key,
        action = action,
        desc = desc,
      }
    end
  end
end

---@param context Neoagent.AgentContext
---@return boolean
local function active_state(context)
  return context.state == "running" or context.state == "stopping" or context.state == "compacting"
end

---@param config Neoagent.UIConfig
---@param width integer
---@return string
local function input_footer(config, width)
  local key = mapping_hint((config.mappings or {}).help)
  if not key then
    return ""
  end
  local result = " " .. key .. " help "
  if Applet.Pane.text.width(result) <= width then
    return result
  end
  return Applet.Pane.text.truncate(result, width)
end

---@param title string
---@param bindings Applet.Binding[]
---@param annotate_modes boolean
---@return string
local function mapping_help_section(title, bindings, annotate_modes)
  local rows, by_description = {}, {}
  for _, binding in ipairs(bindings or {}) do
    if
      type(binding.lhs) == "string"
      and binding.lhs ~= ""
      and type(binding.desc) == "string"
      and binding.desc ~= ""
    then
      local row = by_description[binding.desc]
      if not row then
        row = { description = binding.desc, keys = {}, seen = {}, modes = {} }
        rows[#rows + 1] = row
        by_description[binding.desc] = row
      end
      if not row.seen[binding.lhs] then
        row.keys[#row.keys + 1] = binding.lhs
        row.seen[binding.lhs] = true
      end
      row.modes[binding.mode] = true
    end
  end
  local lines = { title }
  for _, row in ipairs(rows) do
    local description = row.description
    if annotate_modes and row.modes.n ~= row.modes.i then
      description = description .. (row.modes.i and " (Insert mode)" or " (Normal mode)")
    end
    lines[#lines + 1] = "  " .. table.concat(row.keys, ", ") .. "  " .. description
  end
  return table.concat(lines, "\n")
end

---@param transcript Neoagent.TranscriptPane?
---@param key string?
---@return Neoagent.TranscriptBlock?
local function find_block(transcript, key)
  return transcript and key and transcript:block(key) or nil
end

---@param key string
---@param pane Applet.Pane
---@param opts Neoagent.ViewPaneOptions?
---@return Applet.MountNode
local function pane_node(key, pane, opts)
  opts = opts or {}
  assert(pane:key() == key, ("Pane key %q does not match layout key %q"):format(pane:key(), key))
  return layout.mount(pane, {
    lifecycle = opts.lifecycle or "retained",
    owns_pane = opts.owns_pane == true,
    required = opts.required == true,
    mount_revision = opts.mount_revision,
    buffer = {
      name = key,
      filetype = opts.filetype,
      sensitive = opts.sensitive,
      options = {
        buftype = "nofile",
        swapfile = false,
        undofile = false,
      },
    },
    window = {
      border = opts.border,
      options = copy_extend(common_window_options, opts.window_options),
    },
    focus = {
      mode = opts.mode,
      cursor = opts.cursor or "preserve",
    },
    bindings = opts.bindings,
  })
end

---@param config Neoagent.UIConfig
---@param position Neoagent.UiPosition
---@return Applet.HostInput
local function default_host(config, position)
  ---@type Applet.HostSide
  local side
  if position == "auto" then
    side = "center"
  else
    side = position
  end
  local horizontal = side == "left" or side == "right"
  local vertical = side == "top" or side == "bottom"
  return Applet.host.floating({
    container = position == "auto" and "auto" or "editor",
    side = side,
    width = config.width or (horizontal and 0.45 or side == "center" and 0.95 or 1),
    height = config.height or (vertical and 0.45 or side == "center" and 0.95 or 1),
    margin = config.margin == nil and 1 or config.margin,
    base_zindex = 50,
  })
end

---@type fun(state: Neoagent.ViewState, env: Applet.RenderEnvironment): Applet.LayoutTree
local render_view_state

---@param opts Neoagent.ViewOptions
---@return Neoagent.View
function View.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "UI config is required")
  local factory, reader = image_source.new(opts.files)
  local selected =
    protocol.assert(opts.renderer or opts.config.renderer or renderers.get(opts.config.style), "Applet UI Renderer")
  assert(selected.theme, "Applet UI Renderer requires a theme")
  local defined, define_err = protocol.define_highlights(selected)
  assert(defined, define_err and define_err.message or "Applet UI Renderer highlight definition failed")

  local image_system = opts.image_system
  local owns_image_system = false
  if image_system == nil and opts.config.images ~= false then
    image_system = Applet.ImageSystem.new({
      backend = opts.config.images and opts.config.images.backend,
    })
    owns_image_system = true
  elseif image_system == false then
    image_system = nil
  end

  local self = setmetatable({
    config = util.copy(opts.config),
    renderer = selected,
    applet_theme = selected.theme,
    image_system = image_system,
    image_source = factory,
    image_reader = reader,
    files_identity = opts.files and opts.files.identity,
    owns_image_system = owns_image_system,
    callbacks = {
      on_submit = opts.on_submit or function() end,
      on_stop = opts.on_stop or function() end,
      on_dequeue_steering = opts.on_dequeue_steering or function()
        return {}
      end,
      on_input_history = opts.on_input_history or function()
        return {}
      end,
      on_select_history = opts.on_select_history or function() end,
      on_cycle_thinking = opts.on_cycle_thinking or function() end,
      on_agents = opts.on_agents or function() end,
      on_select_model = opts.on_select_model or function() end,
      on_resume_session = opts.on_resume_session or function() end,
      on_dialog_action = opts.on_dialog_action or function() end,
      on_dialog_dismiss = opts.on_dialog_dismiss or function() end,
      on_provider_shell = opts.on_provider_shell,
      on_help = opts.on_help or function() end,
      on_close = opts.on_close or function() end,
      on_presentation_resolve = opts.on_presentation_resolve or function() end,
      on_presentation_cancel = opts.on_presentation_cancel or function() end,
      resolve_tool = opts.resolve_tool or function() end,
    },
    on_error = opts.on_error,
    host_factory = opts.host_factory or opts.host,
    context = { state = "idle" },
    position = opts.config.position or "auto",
    dialog = nil,
    details = nil,
    details_component = nil,
    dialog_component = nil,
    presentation = nil,
    presentation_component = nil,
    presentation_seed = nil,
    destroyed = false,
    spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    spinner_frame = 1,
    frame_revision = 0,
    focus_revision = 0,
  }, View)

  self.transcript = Transcript.new({
    image_source = self.image_source,
    image_reader = self.image_reader,
    renderer = selected,
    config = self.config,
    image_system = image_system,
    resolve_tool = self.callbacks.resolve_tool,
    callbacks = {
      details = function(key)
        self:show_card_details(key)
      end,
      card_move = function(direction, count)
        return self:_navigate_transcript(direction, count)
      end,
      dialog = function(id, action)
        self:_choose_dialog(id, action)
      end,
    },
    on_error = opts.on_error,
  })
  self.input = Input.new({
    config = self.config,
    theme = selected.theme,
    callbacks = {
      submit = function(value)
        return self:_submit(value)
      end,
      close = function()
        self:close()
      end,
      previous_card = function(event)
        return self:_focus_previous_card(event.count)
      end,
      history = self.callbacks.on_input_history,
    },
    on_error = opts.on_error,
  })
  local host_source
  if type(self.host_factory) == "table" then
    host_source = self.host_factory
  else
    local host_factory = self.host_factory
    host_source = function(state)
      if type(host_factory) == "function" then
        return host_factory(util.copy(state), util.copy(state.host_config))
      end
      return default_host(state.host_config, state.position)
    end
  end
  self.applet = Applet.new({
    name = "neoagent",
    host = host_source,
    render = render_view_state,
    handlers = {
      ["neoagent.interrupt"] = function()
        return self:_interrupt()
      end,
      ["neoagent.cycle_thinking"] = self.callbacks.on_cycle_thinking,
      ["neoagent.agents"] = self.callbacks.on_agents,
      ["neoagent.select_model"] = self.callbacks.on_select_model,
      ["neoagent.resume_session"] = self.callbacks.on_resume_session,
      ["neoagent.select_history"] = self.callbacks.on_select_history,
      ["neoagent.dequeue"] = function()
        return self:_restore_steering()
      end,
      ["neoagent.toggle_provider_shell"] = function()
        return self.callbacks.on_provider_shell and self.callbacks.on_provider_shell() or false
      end,
      ["neoagent.focus_dialog_menu"] = function()
        return self:_focus_dialog_menu()
      end,
      ["neoagent.help"] = function()
        return self:_show_mapping_help()
      end,
      ["neoagent.close"] = function()
        return self:close()
      end,
    },
    on_focus = function(current, previous)
      self:_applet_focus(current, previous)
    end,
    on_resize = function(_, default)
      default()
      vim.schedule(function()
        if not self.destroyed and self:is_open() then
          self:_refresh_input_footer()
        end
      end)
    end,
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
  presentation_surface.configure(self, {
    submit = function()
      self:_submit_frame()
    end,
    flush = function()
      return self:_flush_frame()
    end,
    is_open = function()
      return self:is_open()
    end,
    resolve = function(id, value)
      return self.callbacks.on_presentation_resolve(id, value)
    end,
    cancel = function(id)
      return self.callbacks.on_presentation_cancel(id)
    end,
  })
  self.blocks = self.transcript.blocks
  self.messages = self.transcript.messages
  self:_submit_frame()
  return self
end

---@param pane string
---@return Applet.Binding[]
function View:_applet_bindings(pane)
  local mappings = self.config.mappings or {}
  local modes = pane == "input" and { "n", "i" } or "n"
  ---@type Applet.Binding[]
  local bindings = {}
  for _, descriptor in ipairs({
    { mappings.help, "neoagent.help", "Show mapping help" },
    { mappings.interrupt, "neoagent.interrupt", "Clear or interrupt" },
    { mappings.cycle_thinking, "neoagent.cycle_thinking", "Cycle thinking" },
    { mappings.agents, "neoagent.agents", "Create or select Agent" },
    { mappings.select_model, "neoagent.select_model", "Select model" },
    { mappings.resume_session, "neoagent.resume_session", "Resume session" },
    { mappings.select_history, "neoagent.select_history", "Select history" },
    { mappings.dequeue_steering, "neoagent.dequeue", "Edit steering" },
    { mappings.toggle_provider_shell, "neoagent.toggle_provider_shell", "Toggle provider shell" },
  }) do
    add_applet_binding(bindings, modes, descriptor[1], Applet.Pane.nodes.action(descriptor[2]), descriptor[3])
  end
  if pane == "input" then
    add_applet_binding(
      bindings,
      modes,
      mappings.focus_transcript,
      Applet.Pane.nodes.action("applet.focus", { pane = "transcript" }),
      "Focus transcript"
    )
  else
    add_applet_binding(
      bindings,
      modes,
      mappings.focus_input,
      Applet.Pane.nodes.action("applet.focus", { pane = "input" }),
      "Focus input"
    )
    add_applet_binding(bindings, modes, mappings.close, Applet.Pane.nodes.action("neoagent.close"), "Close Neoagent")
  end
  local dialog = self.dialog and self.dialog.active
  if dialog and not dialog.input then
    local target_pane = dialog.placement == "transcript" and "transcript" or "dialog"
    if pane ~= target_pane then
      add_applet_binding(
        bindings,
        "n",
        mappings.menu_previous,
        Applet.Pane.nodes.action("neoagent.focus_dialog_menu"),
        "Focus dialog actions"
      )
      add_applet_binding(
        bindings,
        "n",
        mappings.menu_next,
        Applet.Pane.nodes.action("neoagent.focus_dialog_menu"),
        "Focus dialog actions"
      )
    end
  end
  return bindings
end

---@return string
function View:mapping_help()
  local function combined(component, pane)
    local result = component:mapping_bindings()
    for _, binding in ipairs(self:_applet_bindings(pane)) do
      result[#result + 1] = binding
    end
    return result
  end
  local input = mapping_help_section("Input window", combined(self.input, "input"), true)
  local transcript = mapping_help_section("Transcript window", combined(self.transcript, "transcript"), false)
  return input .. "\n\n" .. transcript
end

---@return unknown
function View:_show_mapping_help()
  return self.callbacks.on_help({
    prompt = "Neoagent mappings · <C-c>/q close",
    body = self:mapping_help(),
  })
end

---@param state Neoagent.ViewState
---@param env Applet.RenderEnvironment
---@return Applet.LayoutTree
render_view_state = function(state, env)
  local transcript = pane_node("transcript", state.transcript.pane, {
    filetype = state.inline_dialog and "neoagent-dialog" or "neoagent",
    border = state.config.border,
    required = true,
    mode = "normal",
    bindings = state.bindings.transcript,
  })
  local input = pane_node("input", state.input.pane, {
    filetype = "neoagent-input",
    border = state.config.border,
    required = true,
    mode = "insert",
    bindings = state.bindings.input,
  })
  ---@type Applet.LayoutLayerNode[]
  local layers = {}
  if state.details then
    layers[#layers + 1] = layout.layer({
      key = "neoagent:details-layer",
      container = "editor",
      anchor = "center",
      width = 0.8,
      height = { content = true, max = math.max(1, env.editor.height - 4) },
      zindex = 70,
      enter = true,
      restore_focus = true,
      child = pane_node("details", state.details.pane, {
        lifecycle = "transient",
        filetype = "neoagent",
        border = state.config.border,
        mode = "normal",
        window_options = { cursorline = true },
      }),
    })
  end
  if state.dialog then
    local editable = state.dialog.editable
    layers[#layers + 1] = layout.layer({
      key = "neoagent:dialog-layer",
      container = "editor",
      anchor = "center",
      width = math.max(1, math.min(80, env.editor.width - 4)),
      height = math.max(3, math.min(env.editor.height - 4, editable and 12 or 14)),
      zindex = 80,
      modal = false,
      enter = state.dialog.enter,
      restore_focus = true,
      child = pane_node("dialog", state.dialog.component.pane, {
        lifecycle = "transient",
        filetype = editable and "neoagent-dialog-input" or "neoagent-dialog",
        border = state.config.border,
        mode = editable and "insert" or "normal",
        window_options = { wrap = editable, cursorline = true },
      }),
    })
  end
  if state.presentation then
    local request = state.presentation.request
    local presentation = state.presentation.component
    local editable = request.kind == "input"
    local secret = editable and request.secret == true
    ---@type Applet.LayoutNode
    local child
    if editable then
      ---@type Applet.Options
      local input_options = { wrap = request.multiline == true, cursorline = false }
      if secret then
        input_options.conceallevel = 2
        input_options.concealcursor = "niv"
      end
      child = pane_node("presentation", presentation.pane, {
        lifecycle = "transient",
        owns_pane = true,
        mount_revision = request.id,
        filetype = secret and "neoagent-secret" or "neoagent-prompt",
        sensitive = secret,
        border = state.config.border,
        mode = "insert",
        window_options = input_options,
      })
    elseif request.kind == "notice" then
      child = pane_node("presentation", presentation.pane, {
        lifecycle = "transient",
        owns_pane = true,
        mount_revision = request.id,
        filetype = "neoagent-notice",
        border = state.config.border,
        mode = "normal",
        window_options = { wrap = true, cursorline = false },
      })
    else
      child = layout.split({
        key = "neoagent:presentation-split",
        axis = "vertical",
        revision = request.id,
        children = {
          {
            key = "filter",
            basis = { content = true },
            grow = 0,
            child = pane_node("presentation-filter", assert(presentation.filter), {
              lifecycle = "transient",
              owns_pane = true,
              mount_revision = request.id .. ":filter",
              filetype = "neoagent-prompt",
              border = state.config.border,
              mode = "insert",
              window_options = { wrap = false, cursorline = false },
            }),
          },
          {
            key = "results",
            basis = { content = true },
            grow = 0,
            child = pane_node("presentation-results", assert(presentation.results), {
              lifecycle = "transient",
              owns_pane = true,
              mount_revision = request.id .. ":results",
              filetype = "neoagent-prompt",
              border = state.config.border,
              mode = "normal",
              window_options = { wrap = false, cursorline = false },
            }),
          },
        },
      })
    end
    layers[#layers + 1] = layout.layer({
      key = "neoagent:presentation-layer",
      container = "editor",
      anchor = "center",
      width = math.max(1, math.min(80, env.editor.width - 4)),
      height = editable and math.max(4, math.min(env.editor.height - 4, request.multiline and 12 or 6))
        or { content = true, max = math.max(3, env.editor.height - 4) },
      zindex = 90,
      modal = true,
      enter = true,
      restore_focus = true,
      child = child,
    })
  end
  return {
    root = layout.frame({
      key = "neoagent:frame",
      child = layout.split({
        key = "neoagent:main",
        axis = "vertical",
        children = {
          { key = "body", grow = 1, min = 3, child = transcript },
          { key = "input", basis = { content = state.config.input_height or 7 }, grow = 0, child = input },
        },
      }),
      layers = layers,
    }),
    focus = {
      initial = "input",
      intent = state.focus_intent,
    },
  }
end

---@param focus string?
---@return boolean
function View:_submit_frame(focus)
  if self.destroyed then
    return false
  end
  self.frame_revision = self.frame_revision + 1
  local intent
  if focus then
    self.focus_revision = self.focus_revision + 1
    intent = { key = focus, revision = self.focus_revision }
  end
  local inline_dialog = self.dialog and self.dialog.active and self.dialog.active.placement == "transcript" or false
  local dialog
  if self.dialog_component then
    local editable = self.dialog_component.pane:is_editable()
    dialog = {
      component = self.dialog_component,
      editable = editable,
      enter = focus == "dialog",
    }
  end
  local presentation
  if self.presentation_component and self.presentation and self.presentation.active then
    presentation = {
      component = self.presentation_component,
      request = util.copy(self.presentation.active),
    }
  end
  self.applet:set_state({
    revision = self.frame_revision,
    position = self.position,
    focus_intent = intent,
    config = {
      border = self.config.border,
      input_height = self.config.input_height,
    },
    host_config = util.copy(self.config),
    transcript = self.transcript,
    input = self.input,
    bindings = {
      transcript = self:_applet_bindings("transcript"),
      input = self:_applet_bindings("input"),
    },
    inline_dialog = inline_dialog,
    details = self.details_component,
    dialog = dialog,
    presentation = presentation,
  })
  return true
end

---@return true?, Applet.Error?
function View:_flush_frame()
  local ok, err = self.applet:flush()
  if ok == nil then
    return nil, err
  end
  return true
end

---@param key string
---@return Applet.Pane?
function View:pane(key)
  return self.applet and self.applet:pane(key) or nil
end

---@param message string
---@param level integer?
function View:notify(message, level)
  return self.applet:notify(message, level)
end

---@param uri string
---@return vim.SystemObj?, string?
function View:open_uri(uri)
  return self.applet:open_uri(uri)
end

---@return boolean
function View:_ensure_presentation_component()
  return presentation_surface.ensure(self)
end

---@param origin integer?
---@param opts? {preserve_scroll?: boolean}
---@return true?, Applet.Error?
function View:open(origin, opts)
  opts = opts or {}
  assert(not self.destroyed, "View is destroyed")
  if self:is_open() then
    self:focus_input()
    return true
  end
  local reopening = self.has_opened == true
  for _, key in ipairs({ "transcript", "input" }) do
    if self:pane(key) then
      self.applet:remount(key)
    end
  end
  self:_ensure_presentation_component()
  self:_submit_frame()
  local opened, err = self.applet:open({ origin = origin })
  if not opened then
    return nil, err
  end
  if self.input.pending_text ~= nil then
    local text, cursor = self.input.pending_text, self.input.pending_cursor
    self.input.pending_text, self.input.pending_cursor = nil, nil
    self.input:set_text(text, cursor)
  end
  self:_seed_presentation()
  self.has_opened = true
  if reopening and self.config.scroll_on_reopen and opts.preserve_scroll ~= true then
    self:_scroll_transcript_to_bottom()
  end
  self:_refresh_input_footer()
  self:_sync_spinner()
  return true
end

function View:close()
  if self.destroyed then
    return
  end
  local was_open = self:is_open()
  if self.input then
    self.input.pending_text = self:get_input()
  end
  presentation_surface.retain_seed(self)
  self.applet:close()
  self:_stop_spinner()
  if was_open then
    self.callbacks.on_close()
  end
end

---@return boolean
function View:is_open()
  return self.applet and self.applet:is_open() or false
end

function View:destroy()
  if self.destroyed then
    return
  end
  self:_stop_spinner()
  self.destroyed = true
  self.applet:destroy()
  if self.details_component then
    self.details_component:destroy()
  end
  if self.dialog_component then
    self.dialog_component:destroy()
  end
  presentation_surface.destroy(self)
  self.details, self.details_component, self.dialog_component = nil, nil, nil
  self.transcript:destroy()
  self.input:destroy()
  if self.owns_image_system then
    assert(self.image_system):destroy()
  end
end

---@param context Neoagent.AgentContext?
function View:set_context(context)
  self.context = copy_extend(self.context, context)
  if context and context.position and context.position ~= self.position then
    self.position = context.position
    self:_submit_frame()
  end
  self.transcript:set_context(self.context)
  self:_sync_spinner()
end

---@param files? Neoagent.FileSource
function View:set_files(files)
  local factory, reader = image_source.new(files)
  local identity = files and files.identity
  if self.files_identity == identity then
    return
  end
  self:_close_details(false)
  self.files_identity = identity
  self.image_source = factory
  self.image_reader = reader
  self.transcript:set_image_source(factory, reader)
end

---@param messages Neoagent.TranscriptMessage[]?
function View:set_messages(messages)
  self.transcript:set_messages(messages)
  self.blocks = self.transcript.blocks
  self.messages = self.transcript.messages
  self:_refresh_details()
end

---@param event Neoagent.AgentEvent
function View:apply(event)
  self.transcript:apply(event)
  self.blocks = self.transcript.blocks
  self.messages = self.transcript.messages
  self:_refresh_details()
end

---@param result Neoagent.ActivityOutcome
function View:finish(result)
  self.transcript:finish(result)
  self.blocks = self.transcript.blocks
  self.messages = self.transcript.messages
  self:_refresh_details()
end

---@return string
function View:get_input()
  local pane = self:pane("input")
  if pane then
    local ok, value = pcall(pane.text, pane)
    if ok then
      return value
    end
  end
  return self.input and self.input.pending_text or ""
end

---@param value string
---@return string
function View:set_input(value)
  assert(type(value) == "string", "input must be a string")
  if not self.input.pane:is_connected() then
    self.input.pending_text = value
    return value
  end
  self.input:set_text(value)
  return value
end

---@param current string
---@param previous string?
function View:_applet_focus(current, previous)
  if
    previous == "transcript"
    and current ~= "transcript"
    and self.config.scroll_on_transcript_leave
    and not self.details_component
  then
    self:_scroll_transcript_to_bottom()
  end
  self:_refresh_input_footer()
end

function View:_refresh_input_footer()
  local pane = self:pane("input")
  local geometry = pane and pane:geometry() or nil
  local width = geometry and geometry.content_width or 80
  self.input:set_footer(input_footer(self.config, width))
  if self.input.pane:is_connected() then
    self.input.pane:flush()
  end
end

---@return boolean
function View:focus_transcript()
  local pane = self:pane("transcript")
  if pane then
    return pane:focus()
  end
  return false
end

---@return boolean
function View:focus_input()
  local pane = self:pane("input")
  if pane then
    return pane:focus()
  end
  return false
end

---@return boolean
function View:_focus_dialog_menu()
  local dialog = self.dialog and self.dialog.active
  if not dialog or dialog.input then
    return false
  end
  local pane_key
  if dialog.placement == "transcript" then
    pane_key = "transcript"
  else
    pane_key = "dialog"
  end
  local pane = self:pane(pane_key)
  return pane and pane:focus_target_intent() or false
end

---@return boolean
function View:_scroll_transcript_to_bottom()
  local pane = self:pane("transcript")
  return pane and pane:scroll({ target = "end", align = "bottom" }) or false
end

---@param value string
---@return unknown
function View:_submit(value)
  local pane = self:pane("input")
  if pane and pane:completion_visible() then
    return pane:completion_accept()
  end
  return self.callbacks.on_submit(value)
end

---@param value string?
---@return true
function View:submission_accepted(value)
  if value == nil or self:get_input() == value then
    self:set_input("")
  end
  if self.config.scroll_on_submit then
    self:_scroll_transcript_to_bottom()
  end
  local pane = self:pane("transcript")
  if pane and pane.domain then
    -- Acceptance is a discrete publication, outside the streaming frame
    -- throttle. The owning domain still defers unsafe native editing.
    pane.domain:request(pane)
    pane.domain:flush()
  end
  return true
end

---@return integer
function View:_restore_steering()
  local messages = util.copy(self.callbacks.on_dequeue_steering())
  if type(messages) ~= "table" or #messages == 0 then
    return 0
  end
  local current = util.trim(self:get_input())
  if current ~= "" then
    messages[#messages + 1] = current
  end
  self:set_input(table.concat(messages, "\n\n"))
  self:focus_input()
  return #messages
end

---@return unknown
function View:_interrupt()
  if self:get_input() ~= "" then
    self:set_input("")
    self:focus_input()
    return false
  end
  if active_state(self.context) then
    self:_restore_steering()
    return self.callbacks.on_stop()
  end
  return false
end

---@param direction integer
---@param count integer?
---@return boolean
function View:_navigate_transcript(direction, count)
  if direction > 0 and self.dialog and self.dialog.active and self.dialog.active.placement == "transcript" then
    self:focus_input()
    return true
  end
  local pane = self:pane("transcript")
  local moved = pane
      and pane:move_target({
        group = "transcript.cards",
        direction = direction < 0 and "previous" or "next",
        wrap = false,
      }, count)
    or false
  if not moved and direction > 0 then
    self:focus_input()
    return true
  end
  return moved
end

---@param count integer?
---@return boolean
function View:_focus_previous_card(count)
  local pane = self:pane("transcript")
  if not pane then
    return false
  end
  if not pane:focus() then
    return false
  end
  if not pane:scroll({ target = "end", align = "bottom" }) then
    return false
  end
  return pane:move_target({
    group = "transcript.cards",
    direction = "previous",
    wrap = false,
  }, count)
end

---@return Neoagent.TranscriptBlock?
function View:_current_block()
  local pane = self:pane("transcript")
  local target = pane and pane:focused_target() or nil
  local key = target and target.key:match("^card:(.+)$")
  return key and find_block(self.transcript, key) or nil
end

---@return boolean
function View:_refresh_details()
  if not self.details or not self.details.block then
    return false
  end
  local block = find_block(self.transcript, self.details.block.key)
  if not block then
    return self:_close_details(false)
  end
  self.details:set(block, self.details.raw)
  return true
end

---@param key string?
---@return boolean
function View:show_card_details(key)
  local block = find_block(self.transcript, key) or self:_current_block()
  if not block then
    return false
  end
  self:_close_details(false)
  local details = Details.new({
    image_source = self.image_source,
    image_reader = self.image_reader,
    renderer = self.transcript.renderer,
    resolve_tool = self.callbacks.resolve_tool,
    config = self.config,
    image_system = self.image_system,
    callbacks = {
      close = function()
        self:_close_details(true)
      end,
      previous = function()
        self:_details_move(-1)
      end,
      next = function()
        self:_details_move(1)
      end,
      center = function()
        self:_center_details()
      end,
      changed = function()
        self.applet:invalidate({ host = true })
      end,
    },
  })
  self.details, self.details_component = details, details
  details:set(block)
  self:_submit_frame("details")
  local opened = self:_flush_frame()
  if not opened then
    self.details, self.details_component = nil, nil
    details:destroy()
    return false
  end
  return true
end

---@param direction integer
---@return boolean
function View:_details_move(direction)
  local details = assert(self.details)
  local current = assert(details.block)
  local index
  for candidate, value in ipairs(self.transcript.blocks) do
    if value.key == current.key then
      index = candidate
      break
    end
  end
  local block = index and self.transcript.blocks[index + direction]
  if not block then
    if direction > 0 then
      self:_close_details(false)
      self:focus_input()
      return true
    end
    return false
  end
  details:set(block)
  self.applet:invalidate({ host = true })
  return true
end

---@return boolean
function View:_center_details()
  local details = assert(self.details)
  local block = assert(details.block)
  local pane = self:pane("transcript")
  if not pane or not pane:reveal_target("card:" .. block.key) then
    return false
  end
  return pane:scroll({ align = "center" })
end

---@param focus boolean
---@return boolean
function View:_close_details(focus)
  local details = self.details_component
  if not details then
    return false
  end
  self.details, self.details_component = nil, nil
  self:_submit_frame(focus and "transcript" or nil)
  if self:is_open() then
    self:_flush_frame()
  end
  details:destroy()
  if focus then
    self:focus_transcript()
  end
  return true
end

---@param id string
---@param action string
---@return unknown
function View:_choose_dialog(id, action)
  return self.callbacks.on_dialog_action(id, action)
end

---@param focus boolean?
---@return boolean?, Applet.Error?
function View:_show_dialog(focus)
  local dialog = assert(self.dialog)
  if dialog.active.placement == "transcript" then
    self:_close_dialog_surface(false)
    self.transcript:set_dialog(dialog)
    self:_submit_frame(focus and "transcript" or nil)
    if self:is_open() then
      self:_flush_frame()
    end
    return true
  end
  self.transcript:set_dialog(nil)
  local editable = dialog.active.input ~= nil
  local created = false
  if self.dialog_component and self.dialog_component.pane:is_editable() ~= editable then
    self:_close_dialog_surface(false)
  end
  if not self.dialog_component then
    created = true
    self.dialog_component = Dialog.new({
      editable = editable,
      config = self.config,
      theme = self.transcript.renderer.theme,
      callbacks = {
        focus_input = function()
          self:focus_input()
        end,
        choose = function(id, action, input)
          return self.callbacks.on_dialog_action(id, action, input)
        end,
        cancel = function(id)
          return self.callbacks.on_dialog_dismiss(id)
        end,
      },
    })
  end
  self.dialog_component:set(dialog)
  self:_submit_frame(focus and "dialog" or nil)
  if self:is_open() then
    local committed, err = self:_flush_frame()
    if committed and created and editable then
      self.dialog_component:set_text(assert(dialog.active.input).value or "")
    end
    return committed, err
  end
  return true
end

---@param focus boolean
---@return boolean
function View:_close_dialog_surface(focus)
  local dialog = self.dialog_component
  if dialog then
    self.dialog_component = nil
    self:_submit_frame(focus and "input" or nil)
    if self:is_open() then
      self:_flush_frame()
    end
    dialog:destroy()
  end
  self.transcript:set_dialog(nil)
  if focus then
    self:focus_input()
  end
  return dialog ~= nil
end

---@param snapshot Neoagent.ActiveDialogSnapshot?
---@return boolean?, Applet.Error?
function View:set_dialog(snapshot)
  local previous_id = self.dialog and self.dialog.active and self.dialog.active.id or nil
  self.dialog = snapshot and util.copy(snapshot) or nil
  if not self.dialog then
    self:_close_dialog_surface(true)
    self:_submit_frame("input")
    if self:is_open() then
      self:_flush_frame()
    end
    return true
  end
  return self:_show_dialog(previous_id ~= self.dialog.active.id)
end

---@return boolean
function View:_seed_presentation()
  return presentation_surface.seed(self)
end

---@param snapshot Neoagent.PresentationSnapshot?
---@return true?, Applet.Error?
function View:set_presentation(snapshot)
  return presentation_surface.set(self, snapshot)
end

---@param key string?
---@param default fun(): boolean
function View:_pane_detached(key, default)
  default()
  if key == "transcript" or key == "input" then
    self:close()
  elseif key == "details" then
    self:_close_details(false)
  elseif key == "dialog" then
    local id = self.dialog and self.dialog.active and self.dialog.active.id
    self:_close_dialog_surface(false)
    if id then
      self.callbacks.on_dialog_dismiss(id)
    end
  elseif key == "presentation" or key == "presentation-filter" or key == "presentation-results" then
    local id = self.presentation and self.presentation.active and self.presentation.active.id
    if id then
      self.callbacks.on_presentation_cancel(id)
    end
  end
end

function View:_sync_spinner()
  local active = active_state(self.context) and not self.dialog
  if not active or not self:is_open() then
    self:_stop_spinner()
    return
  end
  if self.spinner_timer then
    return
  end
  local timer = assert(vim.uv.new_timer())
  self.spinner_timer = timer
  ---@type fun()
  local arm
  arm = function()
    if self.destroyed or self.spinner_timer ~= timer then
      return
    end
    timer:start(
      80,
      0,
      vim.schedule_wrap(function()
        if self.destroyed or self.spinner_timer ~= timer then
          return
        end
        local pane = self.transcript.pane
        if pane:is_settled() then
          self.spinner_frame = self.spinner_frame % #self.spinner_frames + 1
          self.transcript:set_spinner((assert(self.spinner_frames[self.spinner_frame])))
          vim.schedule(arm)
        else
          arm()
        end
      end)
    )
  end
  arm()
end

function View:_stop_spinner()
  if not self.spinner_timer then
    return
  end
  self.spinner_timer:stop()
  self.spinner_timer:close()
  self.spinner_timer = nil
end

---@param position Neoagent.UiPosition
---@return true?, Applet.Error?
function View:set_position(position)
  assert(
    ({ auto = true, left = true, right = true, top = true, bottom = true, center = true })[position],
    "invalid position"
  )
  self.position = position
  self:_submit_frame()
  if self:is_open() then
    return self:_flush_frame()
  end
  return true
end

---@param renderer unknown
---@return Neoagent.Renderer<unknown>?, Neoagent.Error?
function View:set_renderer(renderer)
  local selected, err = protocol.validate(renderer)
  if not selected then
    return nil, err
  end
  local defined, define_err = protocol.define_highlights(selected)
  if not defined then
    return nil, define_err
  end
  local dialog_visible = self.dialog_component ~= nil
    and self.dialog
    and self.dialog.active
    and self.dialog.active.placement == "float"
  local dialog_focused = dialog_visible and self.applet:focused_pane() == "dialog"
  local details_key = self.details and self.details.block and self.details.block.key or nil
  local details_raw = self.details and self.details.raw == true
  if details_key then
    self:_close_details(false)
  end
  if dialog_visible then
    self:_close_dialog_surface(false)
  end
  self.renderer = selected
  self.applet_theme = selected.theme
  self.config.renderer = selected
  self.transcript:set_renderer(selected)
  self.input:set_theme(selected.theme)
  presentation_surface.set_theme(self, selected.theme)
  if dialog_visible then
    self:_show_dialog(dialog_focused)
  end
  if details_key and self:show_card_details(details_key) and details_raw then
    local details = assert(self.details)
    details:set(details.block, true)
  end
  self:_refresh_input_footer()
  return selected
end

return { new = View.new, View = View }
