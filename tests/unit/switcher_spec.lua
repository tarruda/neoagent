local assert = require("luassert")
local switcher_module = require("neoagent.ui.switcher")
local NeoagentApplet = require("neoagent.applet")

describe("neoagent Agent switcher", function()
  ---@type Neoagent.NeoagentApplet[]
  local owners = {}
  ---@type Neoagent.Agent[]
  local agents = {}

  after_each(function()
    for _, owner in ipairs(owners) do owner:destroy() end
    for _, agent in ipairs(agents) do agent:destroy() end
    owners, agents = {}, {}
  end)

  ---@param options Neoagent.AppletOptions?
  local function owner(options)
    local value = NeoagentApplet.new(options or {})
    owners[#owners + 1] = value
    return value
  end

  ---@param applet Applet.Applet
  ---@param kind Applet.ObservationKind
  ---@return Applet.ExternalEvent
  local function surface_event(applet, kind)
    return {
      applet = applet, source = "neovim", kind = kind,
      reason = "test surface change", revision = 1, request_generation = 1,
      before = { open = true, visible = true },
      after = { open = false, visible = false },
      native = function() return { events = {} } end,
    }
  end
  it("keeps one spinner frame pending while scheduled work is delayed", function()
    local agent = require("neoagent.agent").new({
      workspace_trust = false, default_registry = false, providers = {},
      persistence = { enabled = false }, tools = {},
      agent_instructions = false, skills = false,
    })
    agents[#agents + 1] = agent
    function agent:activity() return { state = "working", attention = false } end
    local switcher = switcher_module.new({ owner = owner({ agents = { agent } }) })
    switcher.is_open = function() return true end
    local refreshes = 0
    switcher.refresh = function()
      refreshes = refreshes + 1
      return true
    end

    ---@class Neoagent.TestSwitcherTimer
    ---@field active boolean
    ---@field closing boolean
    ---@field interval? integer
    ---@field callback? fun()
    local timer = { active = false, closing = false }
    ---@param timeout integer
    ---@param interval integer
    ---@param callback fun()
    function timer:start(timeout, interval, callback)
      self.active = true
      self.interval = interval
      self.callback = callback
    end
    function timer:fire()
      if not self.active then return end
      if self.interval == 0 then self.active = false end
      assert(self.callback)()
    end
    function timer:stop() self.active = false end
    function timer:is_closing() return self.closing end
    function timer:close() self.closing = true end

    local original_new_timer = vim.uv.new_timer
    local original_schedule = vim.schedule
    ---@type (fun())[]
    local scheduled = {}
    vim.uv.new_timer = function() return timer --[[@as uv.uv_timer_t]] end
    vim.schedule = function(callback)
      scheduled[#scheduled + 1] = callback
    end
    local ok, err = pcall(function()
      switcher:_sync_timer()
      for _ = 1, 5 do timer:fire() end
      assert.are.equal(1, #scheduled)
      assert.are.equal(0, refreshes)

      assert(table.remove(scheduled, 1))()
      assert.are.equal(1, refreshes)
      assert.are.equal(1, #scheduled)
      assert(table.remove(scheduled, 1))()

      for _ = 1, 5 do timer:fire() end
      assert.are.equal(1, #scheduled)
    end)
    vim.uv.new_timer = original_new_timer
    vim.schedule = original_schedule
    switcher:destroy()
    assert(ok, err)
  end)

  it("contains invalid choices and Applet surface failures", function()
    local switcher = switcher_module.new({ owner = owner() })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local ok, err = pcall(function()
      assert.is_true((switcher:open()))
      assert.is_true((switcher:open()))

      assert(assert(switcher.presentation).filter):_report("render", "picker failed", 0)
      assert(switcher.applet):_report("render", "window failed")
      assert.matches("picker failed", notifications[#notifications - 1][1])
      assert.matches("window failed", notifications[#notifications][1])

      local defaulted = 0
      local applet = assert(switcher.applet)
      assert(applet.callbacks.on_pane_close)(surface_event(applet, "pane_close"), function()
        defaulted = defaulted + 1
        return true
      end)
      assert(vim.wait(1000, function() return not switcher:is_open() end, 5))
      assert.are.equal(1, defaulted)

      assert.is_true((switcher:open()))
      local applet = assert(switcher.applet)
      assert(applet.callbacks.on_pane_buffer_change)(surface_event(applet, "pane_buffer_change"), function()
        defaulted = defaulted + 1
        return true
      end)
      assert(vim.wait(1000, function() return not switcher:is_open() end, 5))
      assert.are.equal(2, defaulted)

      assert.is_true((switcher:open()))
      switcher:_choose("invalid", switcher.generation)
      assert(vim.wait(1000, function()
        return not switcher:is_open()
          and notifications[#notifications]
          and notifications[#notifications][1]:match("invalid selection")
      end, 5))

      switcher:destroy()
      local opened, open_err = switcher:open()
      assert.is_nil(opened)
      assert.matches("destroyed", assert(open_err).message)
    end)
    vim.notify = original_notify
    if not switcher.destroyed then switcher:destroy() end
    assert(ok, err)
  end)

  it("rolls back a failed Applet open", function()
    local Applet = require("applet")
    local original_new = Applet.new
    ---@type Applet.Applet<Neoagent.AgentSwitcherState>?
    local failed_applet
    Applet.new = function(options)
      local applet = original_new(options)
      failed_applet = applet
      function applet:open()
        return nil, { applet = self.name, phase = "open",
          generation = self.generation, message = "switcher open failed" }
      end
      return applet
    end
    local switcher = switcher_module.new({ owner = owner() })
    local ok, err = pcall(function()
      local opened, open_err = switcher:open()
      assert.is_nil(opened)
      assert.matches("switcher open failed", assert(open_err).message)
      assert.is_true(assert(failed_applet):is_destroyed())
      assert.is_nil(switcher.applet)
      assert.is_nil(switcher.presentation)
    end)
    Applet.new = original_new
    switcher:destroy()
    assert(ok, err)
  end)
end)
