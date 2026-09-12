local Applet = require("applet")
local protocol = require("neoagent.ui.renderer")
local util = require("neoagent.util")

local ui = Applet.Pane.nodes

---@class Neoagent.DetailsPaneState
---@field image_source? Neoagent.ImageSourceFactory
---@field block Neoagent.RenderBlock
---@field raw boolean
---@field renderer Neoagent.Renderer<unknown>
---@field config Neoagent.UIConfigInput
---@field spinner string
---@field title string
---@field tool? Neoagent.RenderTool
---@field following boolean

---@class Neoagent.DetailsPaneCallbacks
---@field close? fun(event: Applet.ActionEvent<Applet.Pane<Neoagent.DetailsPaneState>>): unknown
---@field previous? fun(event: Applet.ActionEvent<Applet.Pane<Neoagent.DetailsPaneState>>): unknown
---@field next? fun(event: Applet.ActionEvent<Applet.Pane<Neoagent.DetailsPaneState>>): unknown
---@field center? fun(event: Applet.ActionEvent<Applet.Pane<Neoagent.DetailsPaneState>>): unknown
---@field changed? fun(): unknown

---@class Neoagent.DetailsPaneOptions
---@field image_reader? Applet.ImageResourceReader
---@field image_source? Neoagent.ImageSourceFactory
---@field key? string
---@field config? Neoagent.UIConfigInput
---@field callbacks? Neoagent.DetailsPaneCallbacks
---@field renderer Neoagent.Renderer<unknown>
---@field resolve_tool? fun(name?: string): Neoagent.RenderTool?
---@field image_system? Applet.ImageSystem
---@field on_error? fun(error: Applet.PaneError)

---@class Neoagent.DetailsRenderCache
---@field key? string
---@field renderer Neoagent.Renderer<unknown>
---@field continuation? unknown

---@class Neoagent.DetailsPane
---@field image_source? Neoagent.ImageSourceFactory
---@field config Neoagent.UIConfigInput
---@field callbacks Neoagent.DetailsPaneCallbacks
---@field renderer Neoagent.Renderer<unknown>
---@field resolve_tool? fun(name?: string): Neoagent.RenderTool?
---@field block? Neoagent.RenderBlock
---@field tool? Neoagent.RenderTool
---@field raw boolean
---@field spinner string
---@field title string
---@field render_cache? Neoagent.DetailsRenderCache
---@field following boolean
---@field follow_timer? uv.uv_timer_t
---@field destroyed boolean
---@field pane Applet.Pane<Neoagent.DetailsPaneState>
---@field unsubscribe_images? fun()
local Details = {}
Details.__index = Details

local FOLLOW_INTERVAL_MS = 150

---@param block Neoagent.RenderBlock?
---@return boolean
local function prose(block)
  return type(block) == "table" and (block.kind == "assistant" or block.kind == "thinking")
end

---@param block Neoagent.RenderBlock?
---@return string?
local function tool_name(block)
  return block and block.kind == "tool" and block.name or nil
end

---@param block Neoagent.RenderBlock?
---@return boolean
local function follow_available(block)
  return block ~= nil and prose(block) and block.text_epoch ~= nil
end

---@param value Neoagent.UIMapping?
---@return string|false|nil
local function first(value)
  if type(value) == "table" then
    return value[1]
  end
  return value
end

---@param result Applet.Binding[]
---@param mode string
---@param lhs string|false|nil
---@param action string
---@param desc string
local function add_binding(result, mode, lhs, action, desc)
  if type(lhs) == "string" and lhs ~= "" then
    result[#result + 1] = {
      mode = mode,
      lhs = lhs,
      action = ui.action(action),
      desc = desc,
    }
  end
end

---@param component Neoagent.DetailsPane
local function stop_follow_timer(component)
  local timer = component.follow_timer
  component.follow_timer = nil
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param component Neoagent.DetailsPane
---@param enabled boolean
local function set_following(component, enabled)
  stop_follow_timer(component)
  component.following = enabled == true and follow_available(component.block)
  if not component.following then
    return
  end
  local timer = assert(vim.uv.new_timer())
  component.follow_timer = timer
  timer:start(
    0,
    FOLLOW_INTERVAL_MS,
    vim.schedule_wrap(function()
      if not component.destroyed and component.following
          and component.follow_timer == timer and component.pane:is_connected() then
        component.pane:scroll({ target = "end", align = "bottom" })
      end
    end)
  )
end

---@param state Neoagent.DetailsPaneState
---@param raw_available boolean
---@param can_follow boolean
---@param mappings table<string, Neoagent.UIMapping>
---@return string
local function border_title(state, raw_available, can_follow, mappings)
  local parts = { state.title or "Card details" }
  local raw = raw_available and first(mappings.card_raw) or nil
  if raw then
    parts[#parts + 1] = raw .. (state.raw and " rendered" or " raw")
  end
  local follow = can_follow and first(mappings.card_follow) or nil
  if follow then
    if state.following then
      parts[#parts + 1] = "following"
    end
    parts[#parts + 1] = follow .. (state.following and " toggle" or " follow")
  end
  return " " .. table.concat(parts, " · ") .. " "
end

---@param state Neoagent.DetailsPaneState
---@return Applet.TextNode
local function raw_node(state)
  return ui.text({
    key = "details:raw",
    text = state.block.text or "",
    wrap = "native",
  })
end

---@param component Neoagent.DetailsPane
---@param state Neoagent.DetailsPaneState
---@param env Applet.PaneRenderEnvironment
---@return Applet.Tree
local function render(component, state, env)
  local block = state.block or { kind = "notice", text = "" }
  local child
  if state.raw and prose(block) then
    child = raw_node(state)
  else
    local cache = component.render_cache
    local previous
    if cache and cache.renderer == state.renderer and cache.key == block.key then
      previous = cache.continuation
    end
    local node, continuation = protocol.render_details(state.renderer, block, {
      width = env.width,
      spinner = state.spinner,
      wrap_cards = state.config.wrap_cards == true,
      tool = state.tool,
      image_source = state.image_source,
    }, previous)
    if not node then
      if continuation then
        error(continuation.message, 0)
      end
      child = ui.text({
        key = "details:fallback",
        text = block.text or block.summary or block.name or block.kind or "",
        wrap = "native",
      })
    else
      child = node
      component.render_cache = {
        key = block.key,
        renderer = state.renderer,
        continuation = continuation,
      }
    end
  end
  local mappings = state.config.mappings or {}
  ---@type Applet.Binding[]
  local bindings = {}
  local raw_available = prose(block)
  local wraps = raw_available or tool_name(block) == "shell"
  local can_follow = follow_available(block)
  add_binding(bindings, "n", first(mappings.card_previous), "details.previous", "Previous card")
  add_binding(bindings, "n", first(mappings.card_next), "details.next", "Next card")
  add_binding(bindings, "n", first(mappings.card_center), "details.center", "Center card in transcript")
  if can_follow then
    add_binding(bindings, "n", first(mappings.card_follow), "details.follow", "Toggle following")
  end
  if raw_available then
    add_binding(bindings, "n", first(mappings.card_raw), "details.raw", "Toggle raw details")
  end
  add_binding(bindings, "n", first(mappings.close), "details.close", "Close details")
  if first(mappings.close) ~= "<C-c>" then
    add_binding(bindings, "n", "<C-c>", "details.close", "Close details")
  end
  return {
    root = ui.scope({
      key = "details:scope",
      bindings = bindings,
      child = child,
    }),
    chrome = {
      title = {
        { text = border_title(state, raw_available, can_follow, mappings), style = "window_title" },
      },
      title_pos = "center",
      options = {
        wrap = wraps,
        linebreak = raw_available,
        breakindent = raw_available,
        cursorline = true,
      },
    },
    view = { scroll = "preserve" },
  }
end

---@param opts Neoagent.DetailsPaneOptions
---@return Neoagent.DetailsPane
function Details.new(opts)
  opts = opts or {}
  opts.config = opts.config or {}
  opts.callbacks = opts.callbacks or {}
  local callbacks = opts.callbacks
  local self = setmetatable({
    config = opts.config,
    callbacks = callbacks,
    renderer = opts.renderer,
    image_source = opts.image_source,
    resolve_tool = opts.resolve_tool,
    block = nil,
    tool = nil,
    raw = false,
    spinner = "⠋",
    title = "Card details",
    render_cache = nil,
    following = false,
    follow_timer = nil,
    destroyed = false,
  }, Details)
  self.pane = Applet.Pane.new({
    key = opts.key or "details",
    extent = "document",
    frame_interval_ms = 50,
    theme = opts.renderer.theme,
    image_system = opts.image_system,
    read_image_resource = opts.image_reader,
    render = function(state, env)
      return render(self, state, env)
    end,
    handlers = {
      ["details.close"] = callbacks.close or function() end,
      ["details.previous"] = callbacks.previous or function() end,
      ["details.next"] = callbacks.next or function() end,
      ["details.center"] = callbacks.center or function() end,
      ["details.follow"] = function()
        if follow_available(self.block) then
          set_following(self, not self.following)
          self:_publish()
          if callbacks.changed then
            callbacks.changed()
          end
        end
      end,
      ["details.raw"] = function()
        self.raw = not self.raw
        self:_publish()
        if callbacks.changed then
          callbacks.changed()
        end
      end,
    },
    on_error = opts.on_error,
  })
  if opts.image_system then
    self.unsubscribe_images = opts.image_system:subscribe(function()
      if self.pane:is_connected() and callbacks.changed then
        callbacks.changed()
      end
    end)
  end
  return self
end

---@param block Neoagent.RenderBlock?
---@param raw boolean?
function Details:set(block, raw)
  local previous_key = self.block and self.block.key
  self.block = block and util.copy(block) or nil
  if not follow_available(self.block) then
    set_following(self, false)
  end
  if previous_key ~= (self.block and self.block.key) then
    self.render_cache = nil
  end
  self.tool = nil
  if self.block and self.block.kind == "tool" and type(self.resolve_tool) == "function" then
    local ok, resolved = pcall(self.resolve_tool, tool_name(self.block))
    if ok and type(resolved) == "table" then
      self.tool = { name = resolved.name, render = resolved.render }
    end
  end
  self.raw = raw == true
  local kind = self.block and self.block.kind
  self.title = kind == "tool" and "Tool call"
    or kind == "thinking" and "Thinking"
    or kind == "assistant" and "Text"
    or "Card details"
  self:_publish()
end

function Details:_publish()
  self.pane:set_state({
    block = self.block or { kind = "notice", text = "" },
    raw = self.raw,
    renderer = self.renderer,
    image_source = self.image_source,
    config = self.config,
    spinner = self.spinner,
    title = self.title,
    tool = self.tool,
    following = self.following,
  })
end

---@return string
function Details:text()
  return self.pane:text()
end

function Details:destroy()
  if not self.destroyed then
    self.destroyed = true
    set_following(self, false)
    if self.unsubscribe_images then
      self.unsubscribe_images()
    end
    self.unsubscribe_images = nil
    self.pane:destroy()
  end
end

return Details
