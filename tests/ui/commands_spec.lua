local fake_model = require("tests.helpers.fake_model")
local switcher_ui = require("tests.helpers.switcher")
local presentation = require("tests.helpers.presentation")

describe("neoagent commands", function()
  local neoagent
  local paths

  before_each(function()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
    paths = {}
    if not vim.g.loaded_neoagent then
      vim.cmd("runtime plugin/neoagent.lua")
    end
  end)

  after_each(function()
    local applet = neoagent.applet()
    if not applet:is_destroyed() then applet:destroy() end
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
  end)

  local function setup(extra)
    local model = fake_model.new({})
    local opts = {
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake", models = { test = {
        thinking = { off = {}, high = {} },
      } } } },
      _apis = { fake = function() return model end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    }
    for key, value in pairs(extra or {}) do opts[key] = value end
    return neoagent.setup(opts), model
  end

  it("installs global commands and stable Plug mapping targets", function()
    setup()
    for _, name in ipairs({
      "Neoagent", "NeoagentCycle", "NeoagentResume",
      "NeoagentCopySession", "NeoagentStop", "NeoagentModel",
      "NeoagentThinking", "NeoagentPosition", "NeoagentCompact",
      "NeoagentBranch",
      "NeoagentFork", "NeoagentSandboxInfo", "NeoagentToggleSandbox",
      "NeoagentTranscriptStyle", "NeoagentProvider",
    }) do
      assert.are.equal(2, vim.fn.exists(":" .. name))
    end
    assert.are.equal(0, vim.fn.exists(":NeoagentNew"))
    assert.are.equal(0, vim.fn.exists(":NeoagentAgents"))
    assert.are.equal(0, vim.fn.exists(":NeoagentLogin"))
    assert.are.equal(0, vim.fn.exists(":NeoagentLogout"))
    assert.is_nil(neoagent.new_session)
    assert.is_nil(neoagent.cycle_agent)
    assert.are.equal("", vim.fn.maparg("<leader>a", "n"))

    local toggle = vim.fn.maparg("<Plug>(NeoagentToggle)", "n", false, true)
    local cycle = vim.fn.maparg(
      "<Plug>(NeoagentCycle)", "n", false, true)
    assert.is_function(toggle.callback)
    assert.is_function(cycle.callback)
    assert.is_true(toggle.silent == 1)
    assert.is_true(cycle.silent == 1)

    toggle.callback()
    assert.is_true(neoagent.applet():is_open())
    assert.are.same({}, neoagent.applet():agents())
    cycle.callback()
    assert.is_true(switcher_ui.is_open())
    toggle.callback()
    assert.is_false(switcher_ui.is_open())
    assert.is_true(neoagent.applet():is_open())
  end)

  it("routes command operations and reports lifecycle failures", function()
    setup()
    local calls = {}
    local originals = {
      show_sandbox_info = neoagent.show_sandbox_info,
      compact = neoagent.compact,
      notify = neoagent.notify,
      resume = neoagent.resume,
      copy_session = neoagent.copy_session,
      fork = neoagent.fork,
      select_fork = neoagent.select_fork,
    }
    neoagent.show_sandbox_info = function()
      calls[#calls + 1] = { "sandbox" }
    end
    neoagent.compact = function(instructions)
      calls[#calls + 1] = { "compact", instructions }
    end
    neoagent.notify = function(message, level)
      calls[#calls + 1] = { "notify", message, level }
    end
    neoagent.resume = function()
      return nil, { message = "resume failed", detail = "unavailable" }
    end
    neoagent.copy_session = function()
      return nil, { message = "copy failed" }
    end
    neoagent.fork = function()
      return nil, { message = "fork failed" }
    end
    neoagent.select_fork = function()
      return nil, { message = "selection failed" }
    end

    vim.cmd("NeoagentSandboxInfo")
    vim.cmd("NeoagentCompact")
    vim.cmd("NeoagentCompact preserve decisions")
    vim.cmd("NeoagentModel malformed")
    vim.cmd("NeoagentResume missing.jsonl")
    vim.cmd("NeoagentCopySession")
    vim.cmd("NeoagentFork entry")
    vim.cmd("NeoagentFork")

    neoagent.show_sandbox_info = originals.show_sandbox_info
    neoagent.compact = originals.compact
    neoagent.notify = originals.notify
    neoagent.resume = originals.resume
    neoagent.copy_session = originals.copy_session
    neoagent.fork = originals.fork
    neoagent.select_fork = originals.select_fork
    assert.are.same({
      { "sandbox" },
      { "compact" },
      { "compact", "preserve decisions" },
      { "notify", "expected provider/model", vim.log.levels.ERROR },
      { "notify", "resume failed: unavailable", vim.log.levels.ERROR },
      { "notify", "copy failed", vim.log.levels.ERROR },
      { "notify", "fork failed", vim.log.levels.ERROR },
      { "notify", "selection failed", vim.log.levels.ERROR },
    }, calls)
  end)

  it("stages Agent configuration through commands without eager creation", function()
    local applet = setup()
    assert.are.same({}, applet:agents())

    vim.cmd("NeoagentPosition")
    assert.is_true(applet:is_open())
    local _, request = presentation.active(applet)
    assert.are.equal("Select window position:", request.prompt)
    presentation.choose(applet, "2")
    assert(vim.wait(1000, function()
      return applet:view().position == "left"
    end, 5))
    assert.are.equal("left", applet:view().position)
    assert.are.same({}, applet:agents())

    vim.cmd("NeoagentTranscriptStyle codex")
    assert.are.equal("codex", applet:view().config.style)
    assert.are.same({ "pi", "codex" },
      vim.fn.getcompletion("NeoagentTranscriptStyle ", "cmdline"))

    vim.cmd("NeoagentModel fake/test")
    vim.cmd("NeoagentThinking high")
    assert.is_nil(neoagent.get_model())
    assert.are.equal("high", neoagent.get_thinking_level())
    assert.are.equal("fake/test", applet:view().context.model)
    assert.are.same({}, applet:agents())

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    vim.cmd("NeoagentToggleSandbox")
    assert.is_true(neoagent.sandbox_info().enabled)
    assert.matches("next Neo Agent", notifications[#notifications][1])
    vim.cmd("NeoagentToggleSandbox")
    assert.is_false(neoagent.sandbox_info().enabled)
    vim.notify = original_notify

    vim.cmd("Neoagent")
    assert.is_false(applet:is_open())
    vim.cmd("Neoagent")
    assert.is_true(applet:is_open())
    assert.are.same({}, applet:agents())
  end)

  it("constructs and opens an Agent only after a confirmed resume", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local session = assert(require("neoagent.profile_sessions").new({
      profile_id = "neo",
      workspace = vim.fn.getcwd(),
      persistence = { enabled = true, directory = directory },
    }))
    assert(session:append({
      role = "user", content = "stored", timestamp = 1,
    }))
    local applet = setup({
      persistence = { enabled = true, directory = directory },
    })
    assert.are.same({}, applet:agents())

    vim.cmd("NeoagentResume " .. vim.fn.fnameescape(session:metadata().path))

    assert.are.equal(1, #applet:agents())
    assert.is_true(applet:is_open())
    assert.are.equal("stored", neoagent.get_session():messages()[1].content)
    local entry_id = neoagent.get_session():leaf_id()
    local original_agent = neoagent.default()
    assert.is_nil(original_agent.new_session)
    assert.is_nil(original_agent.resume)
    assert.is_nil(original_agent.fork)
    assert.is_nil(original_agent.select_fork)
    vim.cmd("NeoagentBranch " .. entry_id)
    assert.are.equal(entry_id, neoagent.get_session():leaf_id())
    local parent_path = neoagent.get_session():metadata().path
    vim.cmd("NeoagentFork " .. entry_id)
    assert.are.equal(2, #applet:agents())
    assert.is_false(original_agent:is_destroyed())
    assert.are.equal(parent_path,
      neoagent.get_session():metadata().parent_session)
    assert.are.equal("stored", applet:get_input())

    vim.cmd("NeoagentCycle")
    assert.is_true(switcher_ui.is_open())
    applet:close()
    assert.is_false(switcher_ui.is_open())
  end)

  it("opens and operates the Provider Shell without constructing an Agent", function()
    local calls = 0
    local cancelled = 0
    local operation_args
    local service = {
      id = "fake",
      name = "Fake provider",
      state = function()
        return { blocks = { { type = "status", text = "Ready" } } }
      end,
      operations = {
        inspect = {
          label = "Inspect",
          complete = function()
            return { "second", "first" }
          end,
          run = function(ctx)
            calls = calls + 1
            operation_args = ctx.args
            return require("neoagent.async").run(function()
              return { ok = true }
            end)
          end,
        },
        wait = {
          label = "Wait",
          run = function()
            return require("neoagent.async").run(function()
              require("neoagent.async").await(function()
                return function() cancelled = cancelled + 1 end
              end)
            end)
          end,
        },
      },
    }
    local applet = setup({
      providers = { fake = {
        api = "fake",
        models = { test = { thinking = { off = {}, high = {} } } },
        service = function() return service end,
      } },
    })
    assert.are.same({}, applet:agents())

    vim.cmd("NeoagentProvider")
    assert.is_true(applet:provider_shell_open())
    assert.are.same({ "inspect", "wait" },
      vim.fn.getcompletion("NeoagentProvider ", "cmdline"))
    assert.are.same({ "first", "second" },
      vim.fn.getcompletion("NeoagentProvider inspect ", "cmdline"))
    vim.cmd("NeoagentProvider inspect first second")
    assert(vim.wait(1000, function() return calls == 1 end, 5))
    assert.are.equal("first second", operation_args)
    local shell = applet:provider_shell()
    local function wait_enabled()
      for _, operation in ipairs(shell:operations()) do
        if operation.id == "wait" then return operation.enabled end
      end
      return false
    end
    assert(vim.wait(1000, wait_enabled, 5))
    vim.cmd("NeoagentProvider wait")
    assert(vim.wait(1000, function() return not wait_enabled() end, 5))
    vim.cmd("NeoagentProvider!")
    assert(vim.wait(1000, function() return cancelled == 1 end, 5))
    assert.are.same({}, applet:agents())
  end)
end)
