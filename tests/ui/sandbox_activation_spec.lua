local config = require("neoagent.config")
local Agent = require("neoagent.agent")
local sandbox_composition = require("neoagent.sandbox.composition")
local util = require("neoagent.util")
local NeoagentApplet = require("neoagent.applet")
local fake_model = require("tests.helpers.fake_model")

describe("neoagent sandbox activation warning", function()
  local original_notify
  local notifications
  local windows
  local agents
  local original_compose

  before_each(function()
    config._reset()
    original_notify = vim.notify
    notifications = {}
    windows = {}
    agents = {}
    original_compose = sandbox_composition.compose
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
  end)

  after_each(function()
    for _, window in ipairs(windows) do window:destroy() end
    for _, agent in ipairs(agents) do agent:destroy() end
    sandbox_composition.compose = original_compose
    vim.notify = original_notify
    config._reset()
    vim.cmd("silent! only")
  end)

  local function agent_options(name)
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
    local neo_options = agent_options("Neo")
    neo_options.sandbox.enabled = true
    status = status or {
      ok = false,
      stage = "probe",
      message = "native isolation unavailable",
    }
    neo_options = require("neoagent.sandbox.composition").agent(
      neo_options, {
        platform = {
          name = "test",
          exec = function() error("must not execute") end,
          fs = function() error("must not access files") end,
        },
        status = status,
      })
    local chat_options = agent_options("Chat")
    chat_options.sandbox.enabled = false
    local neo = Agent.from_config(neo_options)
    local chat = Agent.from_config(chat_options)
    agents = { neo, chat }
    local window = NeoagentApplet._from_agents({
      agents = agents,
      active = active == "Chat" and 2 or 1,
      config = util.copy(neo_options.ui),
      _view = neo_options._view,
      persistence = neo_options.persistence,
    })
    windows[#windows + 1] = window
    return window
  end

  it("waits until the requesting Agent is first shown", function()
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

  it("keeps degraded activation silent", function()
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
    assert.are.equal(0, #notifications)
    window:toggle()
    assert.is_true(window:toggle())
    assert.are.equal(0, #notifications)
  end)

  it("uses the built-in warning when workspace trust is disabled", function()
    sandbox_composition.compose = function()
      return nil, {
        ok = false,
        stage = "requirements",
        message = "native isolation unavailable",
      }
    end
    package.loaded["neoagent"] = nil
    local neoagent = require("neoagent")
    local applet = neoagent.setup({
      workspace_trust = false,
      sandbox = { enabled = true },
      default_registry = false,
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake", models = { test = {} } } },
      _apis = { fake = function() return fake_model.new({}) end },
      tools = {},
      persistence = {
        enabled = false,
        workspace_settings = false,
        directory = vim.fn.tempname(),
      },
    })
    local window = neoagent.applet()
    windows[#windows + 1] = window

    assert(window:open())
    assert.are.equal(0, #notifications)
    assert.are.same({}, window:agents())
    applet:send("construct")
    assert(vim.wait(1000, function()
      return #window:agents() == 1
    end, 5))
    agents = window:agents()
    assert.are.equal(1, #notifications)
    assert.matches("tools will run without a sandbox", notifications[1][1])
    assert.are.equal(agents[1], window:default_agent())
  end)
end)
