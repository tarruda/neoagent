local switcher_module = require("neoagent.ui.switcher")
local util = require("neoagent.util")

describe("neoagent Agent switcher", function()
  it("keeps one spinner frame pending while scheduled work is delayed", function()
    local agent = {}
    function agent:activity() return { state = "working" } end
    local owner = {
      _neoagent_applet = true,
      agents = function() return { agent } end,
    }
    local switcher = switcher_module.new({ owner = owner })
    switcher.is_open = function() return true end
    local refreshes = 0
    switcher.refresh = function()
      refreshes = refreshes + 1
      return true
    end

    local timer = { active = false, closing = false }
    function timer:start(_, interval, callback)
      self.active = true
      self.interval = interval
      self.callback = callback
    end
    function timer:fire()
      if not self.active then return end
      if self.interval == 0 then self.active = false end
      self.callback()
    end
    function timer:stop() self.active = false end
    function timer:is_closing() return self.closing end
    function timer:close() self.closing = true end

    local original_new_timer = vim.uv.new_timer
    local original_schedule = vim.schedule
    local scheduled = {}
    vim.uv.new_timer = function() return timer end
    vim.schedule = function(callback)
      scheduled[#scheduled + 1] = callback
    end
    local ok, err = pcall(function()
      switcher:_sync_timer()
      for _ = 1, 5 do timer:fire() end
      assert.are.equal(1, #scheduled)
      assert.are.equal(0, refreshes)

      table.remove(scheduled, 1)()
      assert.are.equal(1, refreshes)
      assert.are.equal(1, #scheduled)
      table.remove(scheduled, 1)()

      for _ = 1, 5 do timer:fire() end
      assert.are.equal(1, #scheduled)
    end)
    vim.uv.new_timer = original_new_timer
    vim.schedule = original_schedule
    switcher:destroy()
    assert(ok, err)
  end)

  it("contains invalid choices and Applet surface failures", function()
    local owner = {
      _neoagent_applet = true,
      profile_order = { { id = "neo", label = "Neo" } },
      agents = function() return {} end,
      profile = function() end,
      new = function() return true end,
      select = function() return true end,
    }
    local switcher = switcher_module.new({ owner = owner })
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local ok, err = pcall(function()
      assert.is_true(switcher:open())
      assert.is_true(switcher:open())

      switcher.presentation.filter:_report("render", "picker failed")
      switcher.applet:_report("render", "window failed")
      assert.matches("picker failed", notifications[#notifications - 1][1])
      assert.matches("window failed", notifications[#notifications][1])

      local defaulted = 0
      switcher.applet.callbacks.on_pane_close(nil, function()
        defaulted = defaulted + 1
      end)
      assert(vim.wait(1000, function() return not switcher:is_open() end, 5))
      assert.are.equal(1, defaulted)

      assert.is_true(switcher:open())
      switcher.applet.callbacks.on_pane_buffer_change(nil, function()
        defaulted = defaulted + 1
      end)
      assert(vim.wait(1000, function() return not switcher:is_open() end, 5))
      assert.are.equal(2, defaulted)

      assert.is_true(switcher:open())
      switcher:_choose("invalid", switcher.generation)
      assert(vim.wait(1000, function()
        return not switcher:is_open()
          and notifications[#notifications]
          and notifications[#notifications][1]:match("invalid selection")
      end, 5))

      switcher:destroy()
      local opened, open_err = switcher:open()
      assert.is_nil(opened)
      assert.matches("destroyed", open_err.message)
    end)
    vim.notify = original_notify
    if not switcher.destroyed then switcher:destroy() end
    assert(ok, err)
  end)

  it("rolls back a failed Applet open", function()
    local Applet = require("applet")
    local original_new = Applet.new
    local failed_applet
    Applet.new = function()
      failed_applet = {
        destroyed = false,
        set_state = function() end,
        is_open = function() return false end,
        open = function()
          return nil, util.error("ui", "switcher open failed")
        end,
        destroy = function(self) self.destroyed = true end,
      }
      return failed_applet
    end
    local switcher = switcher_module.new({
      owner = {
        _neoagent_applet = true,
        profile_order = {},
        agents = function() return {} end,
      },
    })
    local ok, err = pcall(function()
      local opened, open_err = switcher:open()
      assert.is_nil(opened)
      assert.matches("switcher open failed", open_err.message)
      assert.is_true(failed_applet.destroyed)
      assert.is_nil(switcher.applet)
      assert.is_nil(switcher.presentation)
    end)
    Applet.new = original_new
    switcher:destroy()
    assert(ok, err)
  end)
end)
