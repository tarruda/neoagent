local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")

describe("neoagent Provider Shell toggle", function()
  local neoagent
  local applet

  before_each(function()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
  end)

  after_each(function()
    if applet and not applet:is_destroyed() then
      applet:destroy()
    end
  end)

  local function feed(keys)
    keys = type(keys) == "table" and keys[1] or keys
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  it("opens the provider in Normal mode through the shared UI mapping", function()
    local calls = 0
    local service = {
      id = "fake",
      name = "Fake service",
      operations = {
        refresh = {
          label = "Refresh usage",
          run = function()
            calls = calls + 1
            return async.run(function() return { ok = true } end)
          end,
        },
      },
      state = function()
        return { blocks = { {
          type = "status",
          text = "Usage loads on open",
          level = "muted",
        } } }
      end,
    }
    applet = neoagent.setup({
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "fake" },
      providers = { fake = {
        api = "fake",
        models = { fake = {} },
        service = function() return service end,
      } },
      _apis = { fake = function() return fake_model.new({}) end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    })

    assert(applet:toggle())
    local agent_view = assert(applet:view())
    assert(agent_view:focus_input())
    vim.cmd("stopinsert")
    feed("i" .. agent_view.config.mappings.toggle_provider_shell .. "k")

    assert(vim.wait(1000, function()
      return calls == 1 and applet:provider_shell_open()
    end, 5))
    assert.are.same({}, applet:agents())
    local shell = assert(applet:provider_shell())
    local pane = assert(shell:view():pane("provider"))
    local native = pane:native()
    assert.matches("Usage loads on open", table.concat(
      vim.api.nvim_buf_get_lines(native.buffer, 0, -1, false), "\n"))
    local refresh
    for _, target in ipairs(pane:targets()) do
      if target.key:find("refresh", 1, true) then refresh = target break end
    end
    assert.is_not_nil(refresh)
    assert.is_true(refresh.point.row > 0)
    assert.are.equal(refresh.point.row,
      vim.api.nvim_win_get_cursor(native.window)[1])
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
    assert(vim.wait(1000, function() return not shell:is_active() end, 5))

    feed(agent_view.config.mappings.toggle_provider_shell)
    assert(vim.wait(1000, function()
      return not applet:provider_shell_open()
    end, 5))
    assert.are.equal(1, calls)

    feed(agent_view.config.mappings.toggle_provider_shell)
    local reopened = vim.wait(1000, function()
      return calls == 2 and applet:provider_shell_open()
    end, 5)
    assert.is_true(reopened, vim.inspect({
      calls = calls,
      open = applet:provider_shell_open(),
      mode = vim.api.nvim_get_mode().mode,
    }))
  end)

  it("opens the model provider and cycles providers without moving focus", function()
    local inspections = { alpha = 0, beta = 0 }
    local function service(id, name, open)
      local value = {
        id = id,
        name = name,
        operations = {
          inspect = {
            label = "Inspect",
            run = function()
              inspections[id] = inspections[id] + 1
              return async.run(function() return { ok = true } end)
            end,
          },
        },
        state = function()
          return { blocks = { { type = "status", text = name .. " ready" } } }
        end,
      }
      if open then
        value.operations.refresh = {
          label = "Refresh",
          run = function()
            return async.run(function()
              return async.await(function(done)
                return function() done.reject(async.cancelled_error) end
              end)
            end)
          end,
        }
      end
      return value
    end
    local alpha = service("alpha", "Alpha")
    local beta = service("beta", "Beta", true)
    applet = neoagent.setup({
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "alpha", model = "alpha-model" },
      providers = {
        alpha = {
          api = "fake",
          models = { ["alpha-model"] = {} },
          service = function() return alpha end,
        },
        beta = {
          api = "fake",
          models = { ["beta-model"] = {} },
          service = function() return beta end,
        },
      },
      _apis = { fake = function()
        return fake_model.new({ {
          result = fake_model.assistant({ {
            type = "text", text = "constructed",
          } }),
        } })
      end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    })

    assert(applet:toggle())
    assert.are.same({ provider = "beta", model = "beta-model" },
      applet:set_model("beta", "beta-model"))
    local agent_view = assert(applet:view())
    assert(agent_view:focus_input())
    feed(agent_view.config.mappings.toggle_provider_shell)

    local shell = assert(applet:provider_shell())
    assert(vim.wait(1000, function()
      return applet:provider_shell_open() and shell:info().id == "beta"
    end, 5))
    local native = assert(shell:view():pane("provider")):native()
    local pane = assert(shell:view():pane("provider"))
    local window = native.window
    assert.are.equal(window, vim.api.nvim_get_current_win())
    assert.are.equal("provider:operations:item:inspect",
      assert(pane:focused_target()).key)
    vim.api.nvim_buf_call(native.buffer, function()
      for _, key in ipairs({ "j", "k", "h", "l" }) do
        assert.are.same({}, vim.fn.maparg(key, "n", false, true))
      end
    end)

    feed("<C-k>")
    assert(vim.wait(1000, function()
      return shell:info().id == "alpha"
        and vim.api.nvim_get_current_win() == window
    end, 5))
    assert.matches("Alpha ready", table.concat(
      vim.api.nvim_buf_get_lines(native.buffer, 0, -1, false), "\n"))
    assert.are.equal("provider:operations:item:inspect",
      assert(pane:focused_target()).key)
    assert(pane:reveal_target("provider:operations:item:inspect"))
    feed("<CR>")
    assert(vim.wait(1000, function()
      return inspections.alpha == 1 and not shell:is_active()
    end, 5))

    feed("<C-j>")
    assert(vim.wait(1000, function()
      return shell:info().id == "beta"
        and vim.api.nvim_get_current_win() == window
    end, 5))
    assert.matches("Beta ready", table.concat(
      vim.api.nvim_buf_get_lines(native.buffer, 0, -1, false), "\n"))
    assert.are.equal("provider:operations:item:inspect",
      assert(pane:focused_target()).key)

    feed("<C-k>")
    assert(vim.wait(1000, function()
      return shell:info().id == "alpha" and not shell:is_active()
    end, 5))
    feed(agent_view.config.mappings.toggle_provider_shell)
    assert(vim.wait(1000, function()
      return not applet:provider_shell_open()
    end, 5))

    assert(applet:send("construct the Agent"))
    assert(vim.wait(1000, function()
      local agent = applet:target_agent()
      return agent ~= nil and not agent:is_running()
    end, 5))
    assert.are.same({ provider = "beta", model = "beta-model" },
      applet:target_agent():get_model_selection())

    feed(agent_view.config.mappings.toggle_provider_shell)
    assert(vim.wait(1000, function()
      return applet:provider_shell_open() and shell:info().id == "beta"
    end, 5))
  end)
end)
