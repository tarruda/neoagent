local Applet = require("applet")
local util = require("neoagent.util")

local ui = Applet.Pane.nodes
local widgets = Applet.Pane.widgets

---@class Neoagent.ProvidersPaneState
---@field providers Neoagent.ProviderListEntry[]
---@field config Neoagent.UIConfigInput

---@class Neoagent.ProvidersPaneCallbacks
---@field select? fun(provider: string): unknown
---@field close? fun(event: Applet.ActionEvent<Applet.Pane<Neoagent.ProvidersPaneState>>): unknown

---@class Neoagent.ProvidersPaneOptions
---@field config? Neoagent.UIConfigInput
---@field theme? Applet.Theme
---@field callbacks? Neoagent.ProvidersPaneCallbacks
---@field on_error? fun(error: Applet.PaneError)

---@class Neoagent.ProvidersPane
---@field config Neoagent.UIConfigInput
---@field theme? Applet.Theme
---@field callbacks Neoagent.ProvidersPaneCallbacks
---@field state Neoagent.ProvidersPaneState
---@field pane Applet.Pane<Neoagent.ProvidersPaneState>
local Providers = {}
Providers.__index = Providers

---@param value Neoagent.UIMapping?
---@return string[]
local function values(value)
  if type(value) == "string" then return { value } end
  if type(value) == "table" then return value end
  return {}
end

local credential_source_icons = {
  environment = "📤",
}

---@param authentication? {connected: boolean, source?: string, error: boolean}
---@return string?
local function authentication_icons(authentication)
  if type(authentication) ~= "table" then return nil end
  local icons = { authentication.connected and "✅" or "⭕" }
  local source = credential_source_icons[authentication.source]
  if source then icons[#icons + 1] = source end
  if authentication.error then icons[#icons + 1] = "⚠️" end
  return table.concat(icons)
end

---@param state Neoagent.ProvidersPaneState
---@return Applet.Tree
local function render(state)
  ---@type Applet.MenuItem[]
  local items = {}
  for _, provider in ipairs(state.providers or {}) do
    local marker = provider.selected and "● " or "  "
    local label = { { text = marker .. provider.name } }
    local icons = authentication_icons(provider.authentication)
    if icons then
      label[#label + 1] = {
        text = " " .. icons,
      }
    end
    items[#items + 1] = {
      key = provider.id,
      label = label,
      disabled = provider.enabled == false,
      focus_style = "menu_selected",
      action = ui.action("providers.select", { provider = provider.id }),
    }
  end
  local mappings = state.config.mappings or {}
  local menu, entry = widgets.menu({
    key = "providers",
    group = "providers.items",
    title = "Providers",
    items = items,
    keys = {
      previous = mappings.menu_previous,
      next = mappings.menu_next,
      activate = mappings.card_details,
    },
    text_wrap = "native",
    gap = 0,
    title_gap = 0,
  })
  ---@type Applet.Binding[]
  local bindings = {}
  local claimed = {}
  for _, name in ipairs({ "provider_close", "toggle_provider_shell" }) do
    for _, lhs in ipairs(values(mappings[name])) do
      if not claimed[lhs] then
        claimed[lhs] = true
        bindings[#bindings + 1] = {
          mode = "n",
          lhs = lhs,
          action = ui.action("providers.close"),
          desc = "Close provider shell",
        }
      end
    end
  end
  if not claimed["<C-c>"] then
    bindings[#bindings + 1] = {
      mode = "n",
      lhs = "<C-c>",
      action = ui.action("providers.close"),
      desc = "Close provider shell",
    }
  end
  return {
    root = ui.scope({
      key = "providers:root",
      bindings = bindings,
      child = menu,
    }),
    view = {
      scroll = "preserve",
      target_intent = widgets.menu_intent(entry, "providers:entry"),
    },
  }
end

---@param opts? Neoagent.ProvidersPaneOptions
---@return Neoagent.ProvidersPane
function Providers.new(opts)
  opts = opts or {}
  local self = setmetatable({
    config = opts.config or {},
    theme = opts.theme,
    callbacks = opts.callbacks or {},
    state = { providers = {}, config = opts.config or {} },
  }, Providers)
  self.callbacks.select = self.callbacks.select or function() end
  self.pane = Applet.Pane.new({
    key = "providers",
    extent = "document",
    theme = self.theme,
    render = render,
    handlers = {
      ["providers.select"] = function(event)
        return assert(self.callbacks.select)(
          (event.payload --[[@as {provider: string}]]).provider)
      end,
      ["providers.close"] = self.callbacks.close or function() end,
    },
    on_error = opts.on_error,
  })
  self.pane:set_state(self.state)
  return self
end

---@param providers? Neoagent.ProviderListEntry[]
function Providers:set(providers)
  self.state = {
    providers = util.copy(providers or {}),
    config = self.config,
  }
  self.pane:set_state(self.state)
end

---@param theme Applet.Theme
function Providers:set_theme(theme)
  self.theme = theme
  self.pane:set_theme(theme)
end

function Providers:destroy()
  self.pane:destroy()
end

return Providers
