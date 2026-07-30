local config = require("neoagent.config")
local Controller = require("neoagent.controller")
local util = require("neoagent.util")
local Window = require("neoagent.window")

describe("neoagent sandbox activation warning", function()
  local original_notify
  local notifications
  local windows
  local controllers

  before_each(function()
    config._reset()
    original_notify = vim.notify
    notifications = {}
    windows = {}
    controllers = {}
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
  end)

  after_each(function()
    for _, window in ipairs(windows) do window:destroy() end
    for _, controller in ipairs(controllers) do controller:destroy() end
    vim.notify = original_notify
    config._reset()
    vim.cmd("silent! only")
  end)

  local function controller_options(name)
    return config.resolve({
      name = name,
      tools = {},
      persistence = {
        enabled = false,
        workspace_settings = false,
        directory = vim.fn.tempname(),
      },
    })
  end

  local function build(active, status)
    local neo_options = controller_options("Neo")
    neo_options.sandbox.enabled = true
    status = status or {
      ok = false,
      stage = "probe",
      message = "native isolation unavailable",
    }
    neo_options = require("neoagent.sandbox.composition").controller(
      neo_options, {
        platform = {
          name = "test",
          exec = function() error("must not execute") end,
          fs = function() error("must not access files") end,
        },
        status = status,
      })
    local chat_options = controller_options("Chat")
    chat_options.sandbox.enabled = false
    local neo = Controller.from_config(neo_options)
    local chat = Controller.from_config(chat_options)
    controllers = { neo, chat }
    local window = Window.new({
      controllers = controllers,
      active = active == "Chat" and 2 or 1,
      config = util.copy(neo_options.ui),
      view = neo_options.view,
      persistence = neo_options.persistence,
    })
    windows[#windows + 1] = window
    return window
  end

  it("waits until the requesting Controller is first shown", function()
    local window = build("Chat")
    assert.are.equal(0, #notifications)
    assert.is_true(window:toggle())
    assert.are.equal(0, #notifications)
    assert.are.equal("Neo", window:select(1):config().name)
    assert.are.equal(1, #notifications)
    assert.matches("tools will run without a sandbox",
      notifications[1][1])
    assert.are.equal(vim.log.levels.WARN, notifications[1][2])
    window:toggle()
    assert.is_true(window:toggle())
    assert.are.equal(1, #notifications)
  end)

  it("warns on the first toggle when Neo is active", function()
    local window = build("Neo")
    assert.are.equal(0, #notifications)
    assert.is_true(window:toggle())
    assert.are.equal(1, #notifications)
    window:toggle()
    assert.is_true(window:toggle())
    assert.are.equal(1, #notifications)
  end)

  it("warns once when native isolation activates degraded", function()
    local window = build("Neo", {
      ok = true,
      platform = "linux",
      degraded = true,
      degraded_reason = "inherited host procfs is active",
      capabilities = {
        filesystem = true,
        procfs = "host",
      },
    })
    assert.are.equal(0, #notifications)
    assert.is_true(window:toggle())
    assert.are.equal(1, #notifications)
    assert.matches("degraded isolation", notifications[1][1])
    assert.matches("inherited host procfs", notifications[1][1])
    assert.are.equal(vim.log.levels.WARN, notifications[1][2])
    window:toggle()
    assert.is_true(window:toggle())
    assert.are.equal(1, #notifications)
  end)
end)
