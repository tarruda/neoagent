local Applet = require("applet")
local util = require("neoagent.util")

local layout = Applet.layout
local M = {}
local Switcher = {}
Switcher.__index = Switcher

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function mount(pane, opts)
  return layout.mount(pane, {
    lifecycle = "transient",
    owns_pane = true,
    required = true,
    buffer = {
      name = "agent-switcher-" .. pane:key(),
      filetype = "neoagent-prompt",
      options = { buftype = "nofile", swapfile = false, undofile = false },
    },
    window = {
      border = opts.border,
      options = {
        wrap = false,
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
        cursorline = false,
        winhl = "NormalFloat:Normal,FloatBorder:NeoagentBorder,FloatTitle:NeoagentWindowTitle",
      },
    },
    focus = { mode = opts.mode, cursor = "preserve" },
  })
end

function Switcher.new(opts)
  opts = opts or {}
  assert(type(opts.owner) == "table" and opts.owner._neoagent_applet,
    "Agent switcher requires a Neoagent Applet")
  return setmetatable({
    owner = opts.owner,
    applet = nil,
    presentation = nil,
    timer = nil,
    frame = 1,
    generation = 0,
    rows = 0,
    closing = false,
    destroyed = false,
  }, Switcher)
end

function Switcher:_items()
  local result = {}
  for _, profile in ipairs(self.owner.profile_order) do
    result[#result + 1] = {
      id = "new:" .. profile.id,
      label = "New session - " .. profile.label,
      detail = "Profile",
    }
  end
  for _, agent in ipairs(self.owner:agents()) do
    local summary = agent:summary()
    local activity = summary.activity
    local marker = "  "
    if activity.state == "working" then
      marker = spinner_frames[self.frame] .. " "
    elseif activity.state == "waiting" then
      marker = "● "
    end
    local profile = self.owner:profile(summary.profile_id)
    local details = {
      profile and profile.label or summary.profile_id or "Agent",
      summary.workspace,
      summary.model,
      activity.state == "working" and "Working"
        or activity.state == "waiting" and "Waiting" or "Idle",
      activity.detail,
    }
    local filtered = {}
    for _, value in ipairs(details) do
      if type(value) == "string" and value ~= "" then
        filtered[#filtered + 1] = value
      end
    end
    result[#result + 1] = {
      id = "agent:" .. summary.id,
      label = marker .. summary.label,
      detail = table.concat(filtered, " · "),
    }
  end
  return result
end

function Switcher:_has_working()
  for _, agent in ipairs(self.owner:agents()) do
    if agent:activity().state == "working" then return true end
  end
  return false
end

function Switcher:_stop_timer()
  local timer = self.timer
  if not timer then return end
  self.timer = nil
  timer:stop()
  if not timer:is_closing() then timer:close() end
end

function Switcher:_sync_timer()
  if not self:is_open() or not self:_has_working() then
    self:_stop_timer()
    return
  end
  if self.timer then return end
  local timer = vim.uv.new_timer()
  self.timer = timer
  local arm
  arm = function()
    if self.destroyed or self.timer ~= timer then return end
    timer:start(80, 0, vim.schedule_wrap(function()
      if self.destroyed or self.timer ~= timer or not self:is_open() then
        return
      end
      self.frame = self.frame % #spinner_frames + 1
      self:refresh()
      if self.timer == timer then vim.schedule(arm) end
    end))
  end
  arm()
end

function Switcher:_resize(count)
  self.rows = math.max(0, count)
  if self.applet and not self.applet:is_destroyed() then
    self.applet:set_state({ rows = self.rows, revision = self.frame })
  end
end

function Switcher:_choose(id, generation)
  vim.schedule(function()
    if self.destroyed or self.generation ~= generation then return end
    self:close()
    local profile = id:match("^new:(.+)$")
    local ok, selected, err
    if profile then
      ok, selected, err = pcall(self.owner.new, self.owner, profile)
    else
      local agent = id:match("^agent:(.+)$")
      if agent then
        ok, selected, err = pcall(
          self.owner.select, self.owner, agent)
      else
        ok, err = true, util.error("ui",
          "Agent switcher returned an invalid selection")
      end
    end
    if not ok or not selected then
      local failure = util.normalize_error(ok and err or selected, "ui")
      Applet.Presenter.notify("neoagent: " .. failure.message,
        vim.log.levels.ERROR)
    end
  end)
end

function Switcher:_cancel(generation)
  vim.schedule(function()
    if not self.destroyed and self.generation == generation then self:close() end
  end)
end

function Switcher:_create()
  self.generation = self.generation + 1
  local generation = self.generation
  local selected = self.owner.selected
  local theme = selected and selected.renderer
      and selected.renderer.theme
    or require("neoagent.ui.renderers").codex.theme
  local items = self:_items()
  self.presentation = Applet.presentation.new({
    key = "agent-switcher",
    filter_key = "filter",
    results_key = "results",
    request = {
      id = "neoagent-agent-switcher",
      kind = "select",
      prompt = "Agents",
      items = items,
    },
    theme = theme,
    on_choose = function(id) self:_choose(id, generation) end,
    on_cancel = function() self:_cancel(generation) end,
    on_results = function(snapshot) self:_resize(snapshot.count) end,
    on_error = function(err)
      Applet.Presenter.notify("neoagent: " .. err.message,
        vim.log.levels.ERROR)
    end,
  })
  local presentation = self.presentation
  local border = selected and selected.config.border or "rounded"
  self.applet = Applet.new({
    name = "neoagent-agent-switcher",
    host = function(state)
      return Applet.host.floating({
        container = "editor",
        side = "center",
        width = 0.7,
        height = math.min(30, math.max(6, (state.rows or self.rows) + 5)),
        margin = 1,
        base_zindex = 120,
      })
    end,
    render = function()
      return {
        root = layout.frame({
          key = "agent-switcher-frame",
          child = layout.split({
            key = "agent-switcher-split",
            axis = "vertical",
            children = {
              {
                key = "filter",
                basis = 3,
                grow = 0,
                child = mount(presentation.filter, {
                  border = border,
                  mode = "insert",
                }),
              },
              {
                key = "results",
                grow = 1,
                child = mount(presentation.results, {
                  border = border,
                  mode = "normal",
                }),
              },
            },
          }),
        }),
        focus = { initial = "filter" },
      }
    end,
    on_pane_close = function(_, default)
      default()
      self:_cancel(generation)
    end,
    on_pane_buffer_change = function(_, default)
      default()
      self:_cancel(generation)
    end,
    on_error = function(err)
      local normalized = util.normalize_error(
        type(err) == "table" and err.message or err, "ui")
      Applet.Presenter.notify("neoagent: " .. normalized.message,
        vim.log.levels.ERROR)
    end,
  })
  self.applet:set_state({ rows = #items, revision = self.frame })
end

function Switcher:open()
  if self.destroyed then
    return nil, util.error("ui", "Agent switcher is destroyed")
  end
  if self:is_open() then
    local pane_value = self.applet:pane("filter")
    if pane_value then pane_value:focus() end
    return true
  end
  self:_create()
  local opened, err = self.applet:open()
  if not opened then
    self:close()
    return nil, err
  end
  self:_sync_timer()
  return true
end

function Switcher:refresh()
  if not self.presentation then return false end
  self.presentation:set_items(self:_items())
  self:_sync_timer()
  return true
end

function Switcher:is_open()
  return self.applet ~= nil and self.applet:is_open()
end

function Switcher:close()
  if self.closing then return end
  self.closing = true
  self.generation = self.generation + 1
  self:_stop_timer()
  local applet, presentation = self.applet, self.presentation
  self.applet, self.presentation = nil, nil
  if applet then applet:destroy() end
  if presentation then presentation:destroy() end
  self.closing = false
end

function Switcher:destroy()
  if self.destroyed then return end
  self.destroyed = true
  self:close()
  self.owner = nil
end

function M.new(opts) return Switcher.new(opts) end
M.Switcher = Switcher

return M
