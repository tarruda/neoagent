local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")
local presentation = require("tests.helpers.presentation")
local switcher_ui = require("tests.helpers.switcher")
local view_handles = require("tests.helpers.view_handles")

describe("neoagent Agent-owned Applets", function()
  local neoagent
  local applet
  local paths

  before_each(function()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
    paths = {}
  end)

  after_each(function()
    if applet and not applet:is_destroyed() then
      applet:destroy()
    end
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
  end)

  local function configuration(model, extra)
    local options = {
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = {
        fake = { api = "fake-api", models = { test = {} } },
      },
      _apis = { ["fake-api"] = function(resolved)
        model.api = model.api or resolved.api
        model.provider = model.provider or resolved.provider_id
        model.id = model.id or resolved.model_id
        model.input = model.input or resolved.model.input or { "text" }
        return model
      end },
      tools = {},
      agent_instructions = false,
      skills = false,
      ui = { position = "center" },
    }
    return vim.tbl_deep_extend("force", options, extra or {})
  end

  local function setup(model, extra)
    applet = neoagent.setup(configuration(model, extra))
    return applet
  end

  local function feed(keys)
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  local function submit(value)
    local view = assert(applet:view())
    view:set_input(value)
    view:focus_input()
    feed(view.config.mappings.submit)
  end

  it("keeps setup and the initial toggle Agent-free until submission", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "created" } }),
    } })
    setup(model)

    assert.is_true(applet._neoagent_applet)
    assert.are.same({}, applet:agents())
    assert.is_nil(applet:active_agent())
    assert.is_nil(neoagent.default())
    assert(applet:toggle())

    local draft = assert(applet:foreground_applet())
    assert.is_nil(draft:agent())
    assert.are.same({}, applet:agents())

    submit("   ")
    assert.are.same({}, applet:agents())
    assert.are.equal("   ", draft:get_input())

    submit("first message")
    assert(vim.wait(1000, function()
      return #applet:agents() == 1
        and applet:agents()[1]:get_session() ~= nil
    end, 5))
    local agent = applet:agents()[1]
    assert.are.equal(agent, applet:active_agent())
    assert.are.equal(draft, agent:applet())
    assert.are.equal("neo", agent:profile_id())
    assert.are.equal("Neo", agent:label())
    assert(vim.wait(1000, function()
      return not agent:is_running()
    end, 5))
  end)

  it("keeps the top-level Provider Shell independent from draft construction", function()
    local service = {
      id = "fake",
      name = "Fake service",
      operations = {},
      state = function()
        return { blocks = { {
          type = "status",
          text = "Provider ready",
          level = "success",
        } } }
      end,
    }
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "bound" } }),
    } }), {
      providers = { fake = {
        service = function() return service end,
      } },
    })
    assert(applet:toggle())
    assert.are.same({}, applet:agents())
    local draft = assert(applet:foreground_applet())
    local view = assert(draft:view())
    view:focus_input()

    feed(view.config.mappings.toggle_provider_shell)

    assert.are.same({}, applet:agents())
    assert.is_nil(draft:agent())
    assert.is_nil(draft.ensure_agent)
    assert(vim.wait(1000, function()
      return applet:provider_shell_open()
    end, 5))
    local shell = assert(applet:provider_shell())
    local provider = assert(shell:view():pane("provider")):native()
    assert.matches("Provider ready", table.concat(
      vim.api.nvim_buf_get_lines(provider.buffer, 0, -1, false), "\n"))
    assert(applet:set_provider_shell(false))

    submit("bind provider controls")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    view:focus_input()
    feed(view.config.mappings.toggle_provider_shell)
    assert(vim.wait(1000, function()
      return applet:provider_shell_open()
    end, 5))
    local agent = assert(applet:active_agent())
    assert.are.equal(draft, agent:applet())
    assert.is_table(agent:get_session())
    assert.is_false(agent:is_running())
    assert.are.equal(shell, applet:provider_shell())
  end)

  it("retains the exact draft across construction failure and commits its label once", function()
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "created" } }),
    } }))
    assert(applet:toggle())
    local draft = applet:foreground_applet()
    local profile = applet:profile("neo")
    local create_agent = profile.create_agent
    profile.create_agent = function() error("construction failed") end

    submit("preserved draft")
    assert.are.same({}, applet:agents())
    assert.are.equal("preserved draft", draft:get_input())
    assert.is_nil(draft:agent())

    profile.create_agent = create_agent
    submit("preserved draft")
    assert(vim.wait(1000, function()
      return #applet:agents() == 1
    end, 5))
    assert.are.equal("Neo", applet:agents()[1]:label())
    assert.are.equal(draft, applet:agents()[1]:applet())
  end)

  it("rolls back a failed Agent bind without consuming draft resources", function()
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "created" } }),
    } }))
    assert(applet:toggle())
    local draft = applet:foreground_applet()
    local view = draft:view()
    local presenter = draft:presenter()
    local dialogs = draft:dialogs()
    local profile = applet:profile("neo")
    local create_agent = profile.create_agent
    local rejected
    profile.create_agent = function(context)
      rejected = create_agent(context)
      rejected.snapshot = function() error("snapshot failed") end
      return rejected
    end

    submit("retained through bind")

    assert.is_true(rejected:is_destroyed())
    assert.is_false(draft:is_destroyed())
    assert.is_nil(draft:agent())
    assert.are.equal(view, draft:view())
    assert.are.equal(presenter, draft:presenter())
    assert.are.equal(dialogs, draft:dialogs())
    assert.are.equal("retained through bind", draft:get_input())
    assert.are.same({}, applet:agents())

    profile.create_agent = create_agent
    submit("retained through bind")
    assert(vim.wait(1000, function()
      return #applet:agents() == 1
    end, 5))
    local accepted = applet:agents()[1]
    assert.are.equal(draft, accepted:applet())
    assert.is_nil(applet:record(accepted).draft_rollback)
    assert.is_nil(draft.binding_restore)
  end)

  it("retains draft ownership when activity registration rejects construction", function()
    setup(fake_model.new({}))
    assert(applet:toggle())
    local draft = applet:foreground_applet()
    local view = draft:view()
    local presenter = draft:presenter()
    local dialogs = draft:dialogs()
    local profile = applet:profile("neo")
    local create_agent = profile.create_agent
    local rejected
    profile.create_agent = function(context)
      rejected = create_agent(context)
      rejected.subscribe_activity = function()
        error("activity registration failed")
      end
      return rejected
    end

    draft:set_input("retained registration draft")
    local run, err = draft:send("retained registration draft")

    assert.is_nil(run)
    assert.matches("activity registration failed", err.message)
    assert.is_true(rejected:is_destroyed())
    assert.is_false(draft:is_destroyed())
    assert.is_nil(draft:agent())
    assert.are.equal(view, draft:view())
    assert.are.equal(presenter, draft:presenter())
    assert.are.equal(dialogs, draft:dialogs())
    assert.are.equal("retained registration draft", draft:get_input())
    assert.are.same({}, applet:agents())
  end)

  it("restores the exact draft when initial Agent preparation fails", function()
    setup(setmetatable({ api = "fake", provider = "fake", id = "test" }, {
      __index = {
        stream = function() error("model construction failed") end,
      },
    }))
    local profile = applet:profile("neo")
    local factory = profile.config._apis["fake-api"]
    profile.config._apis["fake-api"] = function()
      error("model construction failed")
    end
    assert(applet:toggle())
    local draft = applet:foreground_applet()

    submit("retry me")
    assert(vim.wait(1000, function()
      return #applet:agents() == 0
    end, 5))
    assert.are.equal(draft, applet:retained_draft("neo"))
    assert.is_nil(draft:agent())
    assert.are.equal("retry me", draft:get_input())

    profile.config._apis["fake-api"] = factory
    submit("retry me")
    assert(vim.wait(1000, function()
      return #applet:agents() == 1
    end, 5))
    assert.are.equal(draft, applet:agents()[1]:applet())
  end)

  it("commits an unbound window position into the constructed Agent", function()
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "created" } }),
    } }))
    assert(applet:toggle())
    local draft = applet:foreground_applet()
    assert.are.equal("left", applet:set_position("left"))
    assert.are.equal("left", draft.position)

    submit("positioned")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local agent = applet:active_agent()
    assert.are.equal("left", draft.position)
    assert.are.equal("left", draft:view().position)
    assert.are.equal("left", agent:snapshot().context.position)
  end)

  it("presents Profile context and Workspace history before construction", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local root = require("neoagent.fs").canonical(vim.fn.getcwd())
    local history = require("neoagent.input_history").new({
      directory = directory,
      root = root,
    })
    assert(history:add("earlier prompt"))
    setup(fake_model.new({}), {
      persistence = {
        enabled = true,
        workspace_settings = false,
        directory = directory,
      },
    })

    assert(applet:toggle())

    local view = assert(applet:view())
    assert.are.equal("fake/test", view.context.model)
    assert.are.equal("medium", view.context.thinking)
    assert.are.same({ "earlier prompt" }, applet:input_history())
    assert.are.same({}, applet:agents())
  end)

  it("selects the first available model when no preference is configured", function()
    local model = fake_model.new({})
    local options = configuration(model)
    options.default_model = nil
    options.providers = {
      zeta = { api = "fake-api", models = { second = {} } },
      alpha = { api = "fake-api", models = { first = {} } },
    }
    applet = neoagent.setup(options)

    assert(applet:toggle())

    assert.are.equal("alpha/first", assert(applet:view()).context.model)
    assert.are.same({}, applet:agents())

    applet:destroy()
    options.providers = {}
    applet = neoagent.setup(options)
    assert(applet:toggle())
    assert.are.equal("no model", assert(applet:view()).context.model)
    assert.are.same({}, applet:agents())
  end)

  it("persists a draft model only when its first message is accepted", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({
      agents = { neo = {
        default_model = { provider = "fake", model = "test" },
      } },
    }))
    local response = fake_model.assistant({ { type = "text", text = "saved" } })
    response.message.model = "other"
    setup(fake_model.new({ { result = response } }), {
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = directory,
      },
      providers = {
        fake = { api = "fake-api", models = { test = {}, other = {} } },
      },
    })
    assert(applet:toggle())

    assert.are.same({ provider = "fake", model = "other" },
      applet:set_model("fake", "other"))
    assert.are.same({ provider = "fake", model = "test" },
      assert(settings:load()).agents.neo.default_model)
    assert.are.same({}, applet:agents())

    submit("remember this model")

    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local agent = assert(applet:active_agent())
    assert.are.same({ provider = "fake", model = "other" },
      assert(settings:load()).agents.neo.default_model)
    assert.are.same({ provider = "fake", model = "other" },
      agent:get_session():state().model)
  end)

  it("restores workspace preferences into the first lazy Profile draft", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({
      agents = { neo = {
        default_model = { provider = "fake", model = "remembered" },
        default_thinking_level = "high",
      } },
      ui_position = "left",
    }))
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "bound" } }),
    } }), {
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = directory,
      },
      providers = {
        fake = {
          api = "fake-api",
          models = { test = {}, remembered = { thinking = { high = {} } } },
        },
      },
    })

    assert(applet:toggle())

    local draft = assert(applet:foreground_applet())
    assert.are.same({}, applet:agents())
    assert.are.equal("fake/remembered", assert(applet:view()).context.model)
    assert.are.equal("high", applet:view().context.thinking)
    assert.are.equal("left", applet:view().position)
    assert.are.same({
      default_model = { provider = "fake", model = "remembered" },
      default_thinking_level = "high",
      ui = { position = "left" },
    }, assert(applet:get_draft_options(draft)))

    submit("bind remembered preferences")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local agent = assert(applet:active_agent())
    assert.is_table(agent:get_session())
    assert.are.equal("fake/remembered", agent:snapshot().context.model)
    assert.are.equal("high", agent:get_thinking_level())
  end)

  it("rejects an unsupported workspace setting without applying it", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({ controllers = { Neo = {
      default_model = { provider = "fake", model = "obsolete" },
    } } }))
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end

    local ok, err = pcall(function()
      setup(fake_model.new({}), {
        persistence = {
          enabled = true,
          workspace_settings = true,
          directory = directory,
        },
      })
      assert(applet:toggle())
    end)
    vim.notify = original_notify

    assert(ok, err)
    assert.are.equal("fake/test", assert(applet:view()).context.model)
    local warning = assert(vim.iter(notifications):find(function(entry)
      return entry[1]:find(settings.settings_path, 1, true) ~= nil
    end))
    assert.matches("unsupported workspace setting", warning[1])
    assert.matches("update or delete", warning[1])
    assert.are.equal(vim.log.levels.WARN, warning[2])
  end)

  it("reports malformed workspace settings without blocking the first toggle", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({}))
    assert(require("neoagent.fs").write_all(
      settings.settings_path, "{]", "w", 384))
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end

    local ok, err = pcall(function()
      setup(fake_model.new({}), {
        persistence = {
          enabled = true,
          workspace_settings = true,
          directory = directory,
        },
      })
      assert(applet:toggle())
    end)
    vim.notify = original_notify

    assert(ok, err)
    assert.are.equal("fake/test", assert(applet:view()).context.model)
    local warning = assert(vim.iter(notifications):find(function(entry)
      return entry[1]:find(settings.settings_path, 1, true) ~= nil
    end))
    assert.matches("Invalid workspace settings", warning[1])
    assert.matches("outdated", warning[1])
    assert.matches("update or delete", warning[1])
    assert.are.equal(vim.log.levels.WARN, warning[2])
  end)

  it("stages draft controls without constructing an Agent", function()
    setup(fake_model.new({}), {
      providers = {
        fake = { api = "fake-api", models = {
          test = { thinking = { off = {}, medium = {}, high = {} } },
          other = { thinking = { off = {}, medium = {}, high = {} } },
        } },
      },
    })

    assert.are.equal("draft text", applet:set_input("draft text"))
    assert.are.equal("draft text", applet:get_input())
    assert.are.equal("left", applet:set_position("left"))
    assert.are.equal("pi", applet:set_transcript_style("pi"))
    assert.are.equal(require("neoagent.ui.renderers").codex,
      applet:set_renderer(require("neoagent.ui.renderers").codex))
    assert.are.same({ provider = "fake", model = "other" },
      applet:set_model("fake", "other"))
    assert.are.same({ "off", "medium", "high" },
      applet:available_thinking_levels())
    local missing, missing_err = applet:set_model("fake", "missing")
    assert.is_nil(missing)
    assert.matches("Unknown model: fake/missing", missing_err.message)
    local unsupported, unsupported_err = applet:set_thinking_level("low")
    assert.is_nil(unsupported)
    assert.matches("is not supported by fake/other", unsupported_err.message)
    assert.are.equal("high", applet:cycle_thinking_level())

    local draft = assert(applet:retained_draft("neo"))
    assert.are.same({
      default_model = { provider = "fake", model = "other" },
      default_thinking_level = "high",
      ui = { position = "left" },
    }, assert(applet:get_draft_options(draft)))
    assert.are.equal("fake/other", draft:view().context.model)
    assert.are.equal("high", draft:view().context.thinking)
    assert.are.same({}, applet:agents())
  end)

  it("constructs from a direct first send without opening a draft", function()
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "created" } }),
    } }))

    local run = assert(applet:send("direct first message"))

    assert(vim.wait(1000, function()
      return run:is_done() and #applet:agents() == 1
    end, 5))
    assert.are.equal("direct first message",
      applet:agents()[1]:get_session():messages()[1].content)
  end)

  it("selects a model into an unbound Profile draft", function()
    setup(fake_model.new({}), {
      providers = {
        fake = { api = "fake-api", models = { test = {}, other = {} } },
      },
    })

    assert(applet:select_model())
    assert(applet:open())
    local _, request = presentation.active(applet)
    local selected
    for _, item in ipairs(request.items) do
      if item.label == "fake/other" then selected = item.id break end
    end
    assert(selected)
    presentation.choose(applet, selected)

    local draft = assert(applet:retained_draft("neo"))
    assert(vim.wait(1000, function()
      local options = applet:get_draft_options(draft)
      return options and options.default_model
        and options.default_model.model == "other"
    end, 5))
    assert.are.equal("fake/other", draft:view().context.model)
    assert.are.same({}, applet:agents())
  end)

  it("selects history and resumes a stored session from an unbound draft", function()
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
    local root = require("neoagent.fs").canonical(vim.fn.getcwd())
    local history = require("neoagent.input_history").new({
      directory = directory,
      root = root,
    })
    assert(history:add("earlier prompt"))
    setup(fake_model.new({}), {
      persistence = {
        enabled = true,
        workspace_settings = false,
        directory = directory,
      },
    })
    assert(applet:toggle())
    local draft = assert(applet:foreground_applet())

    assert(draft:select_input_history())
    local _, history_request = presentation.active(applet)
    presentation.choose(applet, history_request.items[1].id)
    assert(vim.wait(1000, function()
      return draft:get_input() == "earlier prompt"
    end, 5))

    assert(applet:resume())
    local _, resume_request = presentation.active(applet)
    presentation.choose(applet, resume_request.items[1].id)
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and agent:get_session()
        and agent:get_session():messages()[1].content == "stored"
    end, 5))
    assert.is_true(applet:is_open())
  end)

  it("resumes through the stored Profile and reuses one live Session owner", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local session = assert(require("neoagent.profile_sessions").new({
      profile_id = "neo",
      workspace = vim.fn.getcwd(),
      persistence = { enabled = true, directory = directory },
    }))
    assert(session:append({
      role = "user", content = "owned once", timestamp = 1,
    }, { model = { provider = "fake", model = "test" } }))
    setup(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
    })
    assert(applet:new("chat"))
    applet:profile("neo").label = "Renamed Neo"

    local first = assert(applet:resume(session:metadata().path))

    assert.are.equal("neo", first:profile_id())
    assert.are.equal("Renamed Neo", first:label())
    assert.are.equal(session:id(), first:get_session():id())
    assert.are.equal(1, #applet:agents())
    first:applet():close()

    local duplicate = assert(applet:resume(session:metadata().path))

    assert.are.equal(first, duplicate)
    assert.are.equal(1, #applet:agents())
    assert.are.equal(first, applet:active_agent())

    assert.is_true(applet:destroy_agent(first))
    local resumed = assert(applet:resume(session:metadata().path))
    assert.are_not.equal(first, resumed)
    assert.are.equal(session:id(), resumed:get_session():id())
    assert.are.equal(1, #applet:agents())
  end)

  it("rejects Profile-free and unavailable Sessions", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local unassigned = require("neoagent.storage").new({
      directory = directory,
      cwd = vim.fn.getcwd(),
      metadata = { foreign = "unassigned" },
    })
    assert(unassigned:append({
      role = "user", content = "unassigned", timestamp = 1,
    }))
    local unavailable = assert(require("neoagent.profile_sessions").new({
      profile_id = "removed-profile",
      workspace = vim.fn.getcwd(),
      persistence = { enabled = true, directory = directory },
    }))
    assert(unavailable:append({
      role = "user", content = "unavailable", timestamp = 2,
    }))
    local unassigned_before = assert(require("neoagent.fs").read(
      unassigned:metadata().path))
    setup(fake_model.new({}), {
      persistence = { enabled = true, directory = directory },
    })

    local direct, direct_err = applet:resume(unassigned:metadata().path)
    assert.is_nil(direct)
    assert.are.equal("profile", direct_err.kind)
    direct, direct_err = applet:resume(unavailable:metadata().path)
    assert.is_nil(direct)
    assert.are.equal("profile", direct_err.kind)
    assert.matches("removed%-profile", direct_err.message)
    assert.are.same({}, applet:agents())

    assert.is_nil(applet:resume())
    assert.are.same({}, applet:agents())
    assert.are.equal(unassigned_before,
      assert(require("neoagent.fs").read(unassigned:metadata().path)))
  end)

  it("copies complete Sessions into independent same- and cross-Profile Agents", function()
    local selected_response = fake_model.assistant({
      { type = "text", text = "one" },
    })
    selected_response.message.provider = "fake"
    selected_response.message.model = "selected"
    local models = {
      default = fake_model.new({}),
      selected = fake_model.new({
        { result = selected_response },
      }),
    }
    models.default.provider, models.default.id = "fake", "default"
    models.selected.provider, models.selected.id = "fake", "selected"
    setup(models.default, {
      default_model = { provider = "fake", model = "default" },
      providers = { fake = { api = "fake-api", models = {
        default = {},
        selected = {},
      } } },
      _apis = { ["fake-api"] = function(resolved)
        return models[resolved.model_id]
      end },
    })
    assert(applet:toggle())
    assert(neoagent.set_model("fake", "selected"))
    submit("copy source")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local source = applet:active_agent()
    local source_snapshot = assert(source:get_session():snapshot())

    assert(applet:copy_session())
    local _, request = presentation.active(applet)
    assert.are.equal("profile:neo", request.items[1].id)
    presentation.choose(applet, "profile:neo")
    assert(vim.wait(1000, function() return #applet:agents() == 2 end, 5))
    local duplicate = applet:active_agent()
    assert.are.equal("neo", duplicate:profile_id())
    assert.are.equal(models.selected, duplicate:get_model())
    assert.are_not.equal(source:get_session():id(), duplicate:get_session():id())
    assert.are.same(source_snapshot.entries, duplicate:get_session():entries())
    assert.are.equal(source_snapshot.leaf_id, duplicate:get_session():leaf_id())
    assert.are.same(source_snapshot, source:get_session():snapshot())
    assert.are.equal(source:get_session():id(),
      duplicate:get_session():metadata().data.neoagent.derivation.sourceSessionId)

    assert(applet:select(source))
    assert(applet:copy_session())
    _, request = presentation.active(applet)
    presentation.choose(applet, "profile:chat")
    assert(vim.wait(1000, function() return #applet:agents() == 3 end, 5))
    local chat = applet:active_agent()
    assert.are.equal("chat", chat:profile_id())
    assert.are.equal(models.default, chat:get_model())
    assert.are.equal("selected", chat:get_session():state().model.model)
    assert.are.same(source_snapshot.entries, chat:get_session():entries())
    assert.are.same(source_snapshot, source:get_session():snapshot())
  end)

  it("enforces copy visibility, content, activity, and cancellation boundaries", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local empty_source = assert(require("neoagent.profile_sessions").new({
      profile_id = "neo",
      workspace = vim.fn.getcwd(),
      persistence = { enabled = false },
    }))
    local empty = assert(require("neoagent.profile_sessions").derive(
      empty_source, {
        kind = "copy",
        source_profile_id = "neo",
        target_profile_id = "neo",
        workspace = vim.fn.getcwd(),
        persistence = { enabled = true, directory = directory },
      }))
    local pending
    local model = { api = "fake", provider = "fake", id = "test" }
    function model:stream(opts)
      return async.run(function()
        local text = async.await(function(done)
          pending = done
          return function() end
        end)
        return fake_model.assistant({ { type = "text", text = text } })
      end, {
        on_event = opts.on_event,
        on_done = opts.on_done,
        error_kind = "model",
      })
    end
    setup(model, {
      persistence = { enabled = true, directory = directory },
    })
    assert(applet:toggle())

    local copied, err = applet:copy_session()
    assert.is_nil(copied)
    assert.are.equal("session", err.kind)
    assert.matches("bound Agent", err.message)

    local source = assert(applet:resume(empty:metadata().path))
    copied, err = applet:copy_session()
    assert.is_nil(copied)
    assert.matches("accepted user message", err.message)

    submit("running source")
    assert(vim.wait(1000, function() return pending ~= nil end, 5))
    copied, err = applet:copy_session()
    assert.is_nil(copied)
    assert.matches("running", err.message)
    pending.resolve("finished")
    assert(vim.wait(1000, function() return not source:is_running() end, 5))
    local before = assert(source:get_session():snapshot())

    assert(applet:copy_session())
    presentation.cancel(applet)
    assert(vim.wait(1000, function()
      return source:presenter():snapshot().active == nil
    end, 5))
    assert.are.equal(1, #applet:agents())
    assert.are.same(before, source:get_session():snapshot())

    pending = nil
    assert(applet:copy_session())
    local active_run = assert(source:send("run during Profile selection"))
    assert(vim.wait(1000, function() return pending ~= nil end, 5))
    local forked, fork_err = applet:select_fork()
    assert.is_nil(forked)
    assert.matches("running", fork_err.message)
    presentation.choose(applet, "profile:neo")
    assert(vim.wait(1000, function()
      return source:presenter():snapshot().active == nil
    end, 5))
    pending.resolve("finished again")
    assert(vim.wait(1000, function()
      return active_run:is_done() and not source:is_running()
    end, 5))
    assert.are.equal(1, #applet:agents())

    assert(applet:copy_session())
    assert(source:get_session():append({
      role = "user", content = "changed during Profile selection",
    }))
    presentation.choose(applet, "profile:neo")
    assert(vim.wait(1000, function()
      return source:presenter():snapshot().active == nil
    end, 5))
    assert.are.equal(1, #applet:agents())

    assert(applet:close())
    copied, err = applet:copy_session()
    assert.is_nil(copied)
    assert.matches("visible bound Agent", err.message)
  end)

  it("uses target Profile defaults on the next turn of a cross-Profile copy", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local settings = require("neoagent.workspace_settings").new({
      directory = directory,
      root = vim.fn.getcwd(),
    })
    assert(settings:write({
      agents = { chat = {
        default_model = { provider = "fake", model = "target" },
      } },
    }))
    local source_response = fake_model.assistant({
      { type = "text", text = "source reply" },
    })
    source_response.message.provider = "fake"
    source_response.message.model = "source"
    local target_response = fake_model.assistant({
      { type = "text", text = "target reply" },
    })
    target_response.message.provider = "fake"
    target_response.message.model = "target"
    local models = {
      source = fake_model.new({ { result = source_response } }),
      target = fake_model.new({ { result = target_response } }),
    }
    models.source.provider, models.source.id = "fake", "source"
    models.target.provider, models.target.id = "fake", "target"
    setup(models.source, {
      persistence = {
        enabled = true,
        workspace_settings = true,
        directory = directory,
      },
      default_model = { provider = "fake", model = "source" },
      providers = { fake = { api = "fake-api", models = {
        source = {},
        target = {},
      } } },
      _apis = { ["fake-api"] = function(resolved)
        return models[resolved.model_id]
      end },
    })
    assert(applet:toggle())
    submit("source turn")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local source = applet:active_agent()
    local before = assert(source:get_session():snapshot())
    local settings_before = assert(settings:load())

    assert(applet:copy_session())
    presentation.choose(applet, "profile:chat")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return #applet:agents() == 2 and agent
        and agent:profile_id() == "chat"
    end, 5))
    local chat = applet:active_agent()
    assert.are.equal(models.target, chat:get_model())
    assert.are.equal("source", chat:get_session():state().model.model)
    assert.are.same(settings_before, assert(settings:load()))

    local source_user = assert(vim.iter(chat:get_session():entries())
      :find(function(entry)
        return entry.type == "message" and entry.message.role == "user"
      end))
    assert(chat:branch(source_user.id))
    assert.are.equal(models.target, chat:get_model())

    submit("target turn")
    assert(vim.wait(1000, function() return not chat:is_running() end, 5))
    assert.are.equal("target", chat:get_session():state().model.model)
    assert.are.equal(1, #models.target.requests)
    assert.are.equal("target turn",
      models.target.requests[1].messages[#models.target.requests[1].messages].content)
    assert.are.same(before, source:get_session():snapshot())
  end)

  it("reports a durable Session when its derived Agent cannot be built", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local response = fake_model.assistant({ { type = "text", text = "source" } })
    response.message.provider = "fake"
    response.message.model = "test"
    local model = fake_model.new({ { result = response } })
    setup(model, {
      persistence = { enabled = true, directory = directory },
    })
    assert(applet:toggle())
    submit("durable source")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local source = applet:active_agent()
    local source_snapshot = assert(source:get_session():snapshot())
    local profile = applet:profile("neo")
    local create_agent = profile.create_agent
    profile.create_agent = function() error("derived construction failed") end

    local derived, err = applet:fork()

    profile.create_agent = create_agent
    assert.is_nil(derived)
    assert.is_string(err.session_path)
    assert.is_true(err.session_created)
    assert.is_truthy(err.message:find(err.session_path, 1, true))
    assert(vim.uv.fs_stat(err.session_path))
    assert.are.same(source_snapshot, source:get_session():snapshot())
    local listed = require("neoagent.profile_sessions").list({
      enabled = true,
      directory = directory,
    }, vim.fn.getcwd())
    assert.is_true(vim.iter(listed):any(function(item)
      return item.path == err.session_path
    end))

    local resumed = assert(applet:resume(err.session_path))
    assert.are_not.equal(source:get_session():id(), resumed:get_session():id())
  end)

  it("retains Profile drafts independently for each Workspace", function()
    local first = vim.fn.tempname()
    local second = vim.fn.tempname()
    paths[#paths + 1], paths[#paths + 2] = first, second
    vim.fn.mkdir(first, "p")
    vim.fn.mkdir(second, "p")
    setup(fake_model.new({}))

    local first_draft = assert(applet:draft("neo", first))
    assert.are.equal("first", first_draft:set_input("first"))
    local second_draft = assert(applet:draft("neo", second))
    assert.are.equal("second", second_draft:set_input("second"))

    assert.are_not.equal(first_draft, second_draft)
    assert.are.equal(first_draft, applet:retained_draft("neo", first))
    assert.are.equal(second_draft, applet:retained_draft("neo", second))
    assert.are.equal("first", first_draft:get_input())
    assert.are.equal("second", second_draft:get_input())
  end)

  it("keeps sandbox controls scoped to the selected Profile draft", function()
    setup(fake_model.new({}))
    assert(applet:new("chat"))
    local chat = applet:foreground_applet()
    assert.are.equal("chat", chat.profile)

    local status, err = neoagent.set_sandbox_enabled(true)

    assert.is_nil(status)
    assert.are.equal("sandbox", err.kind)
    assert.is_false(applet:profile("chat").config.sandbox.enabled)
    assert.is_false(applet:profile("neo").config.sandbox.enabled)
    assert.are.same({}, applet:agents())
  end)

  it("does not commit one Neo draft's sandbox choice into its Profile", function()
    setup(fake_model.new({}))
    assert(applet:new("neo"))
    assert.is_true(assert(neoagent.set_sandbox_enabled(true)).enabled)

    applet:send("sandboxed draft")
    assert(vim.wait(1000, function()
      return #applet:agents() == 1
    end, 5))
    local first = applet:agents()[1]
    assert.is_true(applet:record(first).metadata.sandbox.status.enabled)

    assert(applet:new("neo"))
    assert.is_false(neoagent.sandbox_info().enabled)
    assert.is_false(applet:profile("neo").config.sandbox.enabled)
  end)

  it("inspects static sandbox state without allocating a draft", function()
    setup(fake_model.new({}))
    local profile = applet:profile("neo")
    local create_applet = profile.create_applet
    local created = 0
    profile.create_applet = function(context)
      created = created + 1
      return create_applet(context)
    end

    assert.is_false(neoagent.sandbox_info().enabled)
    assert.are.equal(0, created)
    assert.are.same({}, applet:agents())

    assert.is_true(assert(neoagent.set_sandbox_enabled(true)).enabled)
    assert.are.equal(1, created)
  end)

  it("keeps independently subscribed Agents alive while selecting Applets", function()
    local pending
    local calls = 0
    local model = { api = "fake", provider = "fake", id = "test" }
    function model:stream(opts)
      calls = calls + 1
      if calls == 1 then
        return async.run(function(run)
          local value = async.await(function(done)
            pending = done
            return function() end
          end)
          run:emit({ type = "text_delta", text = value })
          return fake_model.assistant({ { type = "text", text = value } })
        end, {
          on_event = opts.on_event,
          on_done = opts.on_done,
          error_kind = "model",
        })
      end
      return async.run(function()
        return fake_model.assistant({ { type = "text", text = "chat reply" } })
      end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
    end
    setup(model)
    assert(applet:toggle())
    submit("alpha")
    assert(vim.wait(1000, function() return pending ~= nil end, 5))
    local alpha = applet:active_agent()
    local alpha_applet = alpha:applet()

    assert(applet:new("chat"))
    submit("beta")
    assert(vim.wait(1000, function() return #applet:agents() == 2 end, 5))
    local chat = applet:active_agent()
    local chat_applet = chat:applet()
    assert.are_not.equal(alpha_applet, chat_applet)
    assert.is_false(alpha_applet:is_open())
    assert.is_true(chat_applet:is_open())
    chat_applet:set_input("chat draft")

    pending.resolve("alpha reply")
    assert(vim.wait(1000, function() return not alpha:is_running() end, 5))
    assert.are.equal(chat, applet:active_agent())
    assert.are.equal("chat draft", chat_applet:get_input())

    assert.are.equal(alpha, applet:select(alpha:id()))
    assert.is_true(alpha_applet:is_open())
    assert.is_false(chat_applet:is_open())
    assert.are.equal("alpha reply",
      alpha:get_session():messages()[2].content[1].text)
    assert.are.equal(chat, applet:select(chat:id()))
    assert.are.equal("chat draft", chat_applet:get_input())
  end)

  it("restores the last Agent with its completed background state", function()
    local pending
    local model = { api = "fake", provider = "fake", id = "test" }
    function model:stream(opts)
      return async.run(function()
        local value = async.await(function(done)
          pending = done
          return function() end
        end)
        return fake_model.assistant({ { type = "text", text = value } })
      end, {
        on_event = opts.on_event,
        on_done = opts.on_done,
        error_kind = "model",
      })
    end
    setup(model)
    assert(applet:toggle())
    submit("continue closed")
    assert(vim.wait(1000, function() return pending ~= nil end, 5))
    local agent = applet:active_agent()
    local owned = agent:applet()
    local view = owned:view()

    assert.is_false(applet:toggle())
    assert.is_nil(applet:foreground_applet())
    assert.is_true(agent:is_running())
    pending.resolve("completed while closed")
    assert(vim.wait(1000, function() return not agent:is_running() end, 5))

    assert.is_true(applet:toggle())
    assert.are.equal(agent, applet:active_agent())
    assert.are.equal(owned, applet:foreground_applet())
    assert.are.equal(view, owned:view())
    assert.matches("completed while closed", table.concat(
      vim.api.nvim_buf_get_lines(view_handles.buffer(view, "transcript"), 0, -1, false), "\n"))
  end)

  it("restores the last Agent after an unbound draft closes", function()
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "ready" } }),
    } }))
    assert(applet:toggle())
    submit("create Neo")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local agent = applet:active_agent()
    local agent_applet = agent:applet()

    assert(applet:new("chat"))
    local chat_draft = applet:foreground_applet()
    chat_draft:set_input("retained Chat draft")
    assert.is_true(applet:close())

    assert.is_true(applet:toggle())
    assert.are.equal(agent, applet:active_agent())
    assert.are.equal(agent_applet,
      applet:foreground_applet())
    assert.are.equal("retained Chat draft",
      assert(applet:draft("chat")):get_input())
  end)

  it("reconfigures idle ownership and rejects replacement during work", function()
    local pending
    local model = { api = "fake", provider = "fake", id = "test" }
    function model:stream(opts)
      return async.run(function()
        return async.await(function(done)
          pending = done
          return function() end
        end)
      end, {
        on_event = opts.on_event,
        on_done = opts.on_done,
        error_kind = "model",
      })
    end
    setup(model)
    assert(applet:toggle())
    submit("running")
    assert(vim.wait(1000, function() return pending ~= nil end, 5))
    local original = applet
    local agent = applet:active_agent()

    assert.has_error(function()
      neoagent.setup(configuration(fake_model.new({})))
    end, "Cannot reconfigure neoagent while a run is active")
    assert.are.equal(original, neoagent.applet())
    assert.is_false(original:is_destroyed())
    assert.is_false(agent:is_destroyed())

    pending.resolve(fake_model.assistant({ { type = "text", text = "done" } }))
    assert(vim.wait(1000, function() return not agent:is_running() end, 5))
    local replacement = neoagent.setup(configuration(fake_model.new({})))
    applet = replacement
    assert.is_true(original:is_destroyed())
    assert.is_true(agent:is_destroyed())
    assert.are.same({}, replacement:agents())
  end)

  it("keeps the complete prior composition when replacement construction fails", function()
    setup(fake_model.new({}))
    local original = applet
    local configured = require("neoagent.config").get()
    local broken = configuration(fake_model.new({}), {
      providers = {
        broken = {
          api = "fake-api",
          models = {},
          service = function() error("replacement service failed") end,
        },
      },
    })

    local ok, err = pcall(neoagent.setup, broken)

    assert.is_false(ok)
    assert.matches("Failed to construct provider service for broken",
      require("neoagent.util").normalize_error(err, "provider").message)
    assert.are.equal(original, neoagent.applet())
    assert.is_false(original:is_destroyed())
    assert.are.same(configured, require("neoagent.config").get())
  end)

  it("retains background attention for explicit programmatic resolution", function()
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "ready" } }),
    } })
    setup(model)
    assert(applet:toggle())
    submit("create Neo")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local neo = applet:active_agent()
    assert(applet:new("chat"))
    local foreground = applet:foreground_applet()

    local selection = neo:presenter():select({
      prompt = "Background choice",
      items = { { id = "continue", label = "Continue" } },
    })
    assert(vim.wait(1000, function()
      return neo:activity().state == "waiting"
    end, 5))
    assert.are.equal(foreground, applet:foreground_applet())
    assert.is_false(neo:applet():is_open())
    local request = assert(neo:presenter():snapshot().active)
    assert(neo:presenter():resolve(request.id, "continue"))
    assert(vim.wait(1000, function() return selection:is_done() end, 5))
    assert.is_true(selection:result().ok)
    assert.are.equal("idle", neo:activity().state)
  end)

  it("selects New and live Agents through one activity-aware switcher", function()
    local pending
    local model = { api = "fake", provider = "fake", id = "test" }
    function model:stream(opts)
      return async.run(function(run)
        local value = async.await(function(done)
          pending = done
          return function() end
        end)
        run:emit({ type = "text_delta", text = value })
        return fake_model.assistant({ { type = "text", text = value } })
      end, {
        on_event = opts.on_event,
        on_done = opts.on_done,
        error_kind = "model",
      })
    end
    setup(model)
    assert(applet:toggle())
    submit("working")
    assert(vim.wait(1000, function() return pending ~= nil end, 5))
    local neo = assert(applet:active_agent())

    assert(applet:show_agents())
    local function lines()
      return switcher_ui.lines()
    end
    assert(vim.wait(1000, function()
      local text = table.concat(lines(), "\n")
      return text:find("New session - Neo", 1, true)
        and text:find("New session - Chat", 1, true)
        and text:find("Working", 1, true)
    end, 5))
    local working = table.concat(lines(), "\n")
    assert(vim.wait(1000, function()
      return table.concat(lines(), "\n") ~= working
    end, 5))

    local choice = neo:presenter():select({
      prompt = "Pause for attention",
      items = { { id = "continue", label = "Continue" } },
    })
    assert(vim.wait(1000, function()
      return table.concat(lines(), "\n"):find("Waiting", 1, true)
    end, 5))
    local waiting = table.concat(lines(), "\n")
    assert.is_false(vim.wait(250, function()
      return table.concat(lines(), "\n") ~= waiting
    end, 10))
    local request = assert(neo:presenter():snapshot().active)
    assert(neo:presenter():resolve(request.id, "continue"))
    assert(vim.wait(1000, function()
      return choice:is_done()
        and table.concat(lines(), "\n"):find("Working", 1, true)
    end, 5))

    assert.are.equal("New session - Chat",
      switcher_ui.set_filter("New session - Chat"))
    switcher_ui.press("<CR>")
    assert(vim.wait(1000, function()
      local foreground = applet:foreground_applet()
      return not switcher_ui.is_open() and foreground
        and foreground.profile == "chat" and foreground:agent() == nil
    end, 5))
    local chat_draft = applet:foreground_applet()

    assert(applet:show_agents())
    switcher_ui.press("<C-c>")
    assert(vim.wait(1000, function() return not switcher_ui.is_open() end, 5))
    assert.are.equal(chat_draft, applet:foreground_applet())

    assert(applet:show_agents())
    switcher_ui.set_filter("Neo Working")
    switcher_ui.press("<CR>")
    assert(vim.wait(1000, function()
      return applet:active_agent() == neo and not switcher_ui.is_open()
    end, 5))

    pending.resolve("finished")
    assert(vim.wait(1000, function() return not neo:is_running() end, 5))
    assert(applet:show_agents())
    assert(vim.wait(1000, function()
      return table.concat(lines(), "\n"):find("Idle", 1, true)
    end, 5))
    local idle = table.concat(lines(), "\n")
    assert.is_false(vim.wait(250, function()
      return table.concat(lines(), "\n") ~= idle
    end, 10))
    applet:close()
    assert.is_false(switcher_ui.is_open())
  end)

  it("opens the Agent switcher through the default UI mapping", function()
    setup(fake_model.new({}))
    assert(applet:toggle())
    local view = assert(applet:view())
    view:focus_input()

    feed("<A-n>")

    assert(vim.wait(1000, switcher_ui.is_open, 5))
    local rendered = table.concat(switcher_ui.lines(), "\n")
    assert.is_not_nil(rendered:find("New session - Neo", 1, true))
    assert.is_not_nil(rendered:find("New session - Chat", 1, true))
  end)

  it("contains a switcher choice invalidated before scheduled dispatch", function()
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } }))
    assert(applet:toggle())
    submit("create selectable Agent")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local agent = applet:active_agent()
    assert(applet:show_agents())
    switcher_ui.set_filter("Neo Idle")

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local ok, err = pcall(function()
      switcher_ui.press("<CR>")
      agent:destroy()
      assert(vim.wait(1000, function()
        return not switcher_ui.is_open() and #notifications > 0
      end, 5))
      assert.matches("Agent is not owned", notifications[#notifications][1])
      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications][2])
    end)
    vim.notify = original_notify
    assert(ok, err)
    assert.are.same({}, applet:agents())
  end)

  it("removes destroyed drafts and Agents from top-level ownership", function()
    setup(fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } }))
    assert(applet:toggle())
    local first_draft = applet:foreground_applet()
    first_draft:destroy()
    assert.is_nil(applet:foreground_applet())
    assert(applet:new("neo"))
    assert.are_not.equal(first_draft, applet:foreground_applet())

    submit("owned lifecycle")
    assert(vim.wait(1000, function()
      local agent = applet:active_agent()
      return agent and not agent:is_running()
    end, 5))
    local agent = applet:active_agent()
    local owned = agent:applet()
    agent:destroy()

    assert.are.same({}, applet:agents())
    assert.is_nil(applet:active_agent())
    assert.is_nil(applet:default_agent())
    assert.is_true(owned:is_destroyed())
    assert.is_true(applet:toggle())
    assert.is_nil(applet:foreground_applet():agent())
  end)
end)
