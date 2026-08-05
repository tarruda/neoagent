local fake_model = require("tests.helpers.fake_model")

local function feed(keys)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, false, true),
    "x", false)
end

describe("neoagent workspace trust UI", function()
  local neoagent
  local paths = {}
  local original_cwd
  local original_agents_discover
  local original_skills_discover
  local custom_windows = {}
  local custom_controllers = {}

  before_each(function()
    original_agents_discover = require("neoagent.agents").discover
    original_skills_discover = require("neoagent.skills").discover
    original_cwd = vim.fn.getcwd()
    local workspace = vim.fn.tempname()
    vim.fn.mkdir(workspace, "p")
    paths[#paths + 1] = workspace
    vim.cmd("cd " .. vim.fn.fnameescape(workspace))
  end)

  local function setup(extra)
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
    local model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } })
    local directory = vim.fn.tempname()
    local trust_path = directory .. "/trust.json"
    paths[#paths + 1] = directory
    local options = {
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = "test" },
      providers = {
        fake = { api = "fake-api", models = { test = {} } },
      },
      apis = { ["fake-api"] = function() return model end },
      tools = { {
        name = "inspect",
        description = "Inspect the workspace",
        input_schema = {
          type = "object",
          properties = {},
          additionalProperties = false,
        },
        execute = function()
          return { content = { { type = "text", text = "ok" } } }
        end,
      } },
      agents = false,
      skills = false,
      workspace_trust = { path = trust_path },
      ui = { position = "center" },
    }
    for key, value in pairs(extra or {}) do options[key] = value end
    local controller = neoagent.setup(options)
    return controller, model, trust_path
  end

  local function view()
    return neoagent.default_window():_state().view
  end

  local function wait_for_dialog()
    assert(vim.wait(1000, function()
      return view() and view().dialog_buf ~= nil
        and vim.api.nvim_buf_is_valid(view().dialog_buf)
    end, 5))
    return view()
  end

  after_each(function()
    for _, window in ipairs(custom_windows) do window:destroy() end
    for _, controller in ipairs(custom_controllers) do controller:destroy() end
    custom_windows, custom_controllers = {}, {}
    if neoagent then
      local window = neoagent.default_window()
      for _, controller in ipairs(window:controllers()) do
        controller:destroy()
      end
      window:destroy()
    end
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
    require("neoagent.agents").discover = original_agents_discover
    require("neoagent.skills").discover = original_skills_discover
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
    vim.cmd("silent! only")
  end)

  it("prompts only when protected Neo is visible and accepts session trust",
    function()
      local controller, model, trust_path = setup()
      local window = neoagent.default_window()
      window:set_input("preserved draft")
      assert(window:select(2))
      assert(neoagent.open())
      vim.wait(50)
      assert.is_nil(view().dialog_buf)
      assert.is_nil(controller:get_session())
      assert.is_nil(controller:get_model())

      assert(window:select(controller))
      local active_view = wait_for_dialog()
      local body = active_view.dialog.active.body
      assert.are.equal("Trust workspace?", active_view.dialog.active.title)
      assert.is_not_nil(body:find(
        require("neoagent.workspace_trust").target(vim.fn.getcwd()),
        1, true))
      assert.is_not_nil(body:find("prompt injection", 1, true))
      assert.is_not_nil(body:find("sandboxing is disabled", 1, true))
      assert.are.equal("preserved draft", active_view:get_input())
      assert.is_nil(controller:get_session())
      assert.is_nil(controller:get_model())

      feed("<CR>")
      vim.wait(20)
      assert.is_not_nil(active_view.dialog_buf)
      feed("s")
      assert(vim.wait(1000, function()
        return active_view.dialog_buf == nil
      end, 5))
      assert.is_true(window:is_open())
      assert.are.equal("preserved draft", active_view:get_input())
      assert.is_nil(controller:get_session())
      assert.is_nil(vim.uv.fs_stat(trust_path))
      vim.wait(50)

      local run = assert(controller:send("reviewed draft"))
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.are.equal(1, #model.requests)
    end)

  it("selects the configured model once trust is approved", function()
    local controller = setup()
    local window = neoagent.default_window()
    assert(neoagent.open())
    local active_view = wait_for_dialog()
    assert.is_nil(controller:get_model())
    assert.matches("no model", active_view.context.model)

    feed("s")
    assert(vim.wait(1000, function()
      return active_view.dialog_buf == nil
    end, 5))
    assert(vim.wait(1000, function()
      return controller:get_model() ~= nil
    end, 5))
    assert.is_true(window:is_open())
    assert.is_not_nil(controller:get_model())
    assert.are.equal("fake/test", active_view.context.model)
  end)

  it("routes trust action keys through the transcript prompt",
    function()
      setup()
      assert(neoagent.open())
      local active_view = wait_for_dialog()
      assert.are.equal("transcript", active_view.dialog.active.placement)
      assert.is_nil(active_view.dialog_win)
      assert.are.equal(active_view.transcript_win,
        vim.api.nvim_get_current_win())
      assert.is_false(
        vim.api.nvim_get_mode().mode:sub(1, 1) == "i")
      feed("s")
      assert(vim.wait(1000, function()
        return active_view.dialog_buf == nil
      end, 5))
      assert.is_true(neoagent.default_window():is_open())
    end)

  it("hides the trust prompt while Chat is selected with the input mapping",
    function()
      local controller = setup()
      local window = neoagent.default_window()
      assert(neoagent.open())
      local active_view = wait_for_dialog()

      vim.cmd("stopinsert")
      vim.api.nvim_set_current_win(active_view.input_win)
      feed("i<A-n>")
      assert(vim.wait(1000, function()
        return window:active():config().name == "Chat"
      end, 5))
      assert.is_nil(active_view.dialog_buf)
      assert.is_true(window:is_open())

      feed("<A-n>")
      assert(vim.wait(1000, function()
        return window:active() == controller
          and active_view.dialog_buf ~= nil
          and vim.api.nvim_buf_is_valid(active_view.dialog_buf)
      end, 5))
    end)

  it("persists trust and treats cancellation as fail closed",
    function()
      local controller, _, trust_path = setup()
      local window = neoagent.default_window()
      window:set_input("keep me")
      assert(neoagent.open())
      local active_view = wait_for_dialog()
      feed("q")
      assert(vim.wait(1000, function() return not window:is_open() end, 5))
      assert.are.equal("keep me", window:_state().drafts[controller])
      assert.is_nil(vim.uv.fs_stat(trust_path))
      assert.is_nil(controller:get_session())

      assert(neoagent.open())
      active_view = wait_for_dialog()
      feed("t")
      assert(vim.wait(1000, function()
        return active_view.dialog_buf == nil
          and vim.uv.fs_stat(trust_path) ~= nil
      end, 5))
      assert.is_true(window:is_open())
      assert.is_nil(controller:get_session())
      local trusted = assert(require("neoagent.workspace_trust")
        .new_store(trust_path):list())
      assert.are.same({ require("neoagent.workspace_trust")
        .target(vim.fn.getcwd()) }, trusted)
    end)

  it("blocks sends before display and selects hidden Neo for its prompt",
    function()
      local controller = setup()
      local window = neoagent.default_window()
      window:set_input("blocked draft")
      assert(window:select(2))
      local changed, model_err = controller:set_model("fake", "test")
      assert.is_nil(changed)
      assert.are.equal("workspace_trust", model_err.kind)
      local selected, select_err = controller:select_model()
      assert.is_nil(selected)
      assert.are.equal("workspace_trust", select_err.kind)
      local run, err = controller:send("do not send")
      assert.is_nil(run)
      assert.are.equal("workspace_trust", err.kind)
      assert.is_nil(controller:get_session())
      assert.is_nil(controller:get_model())
      wait_for_dialog()
      assert.are.equal(controller, window:active())
      assert.is_true(window:is_open())
      assert.are.equal("blocked draft", view():get_input())
    end)

  it("rechecks new and resumed workspaces before replacing the Session",
    function()
      local controller = setup()
      local window = neoagent.default_window()
      assert(neoagent.open())
      local active_view = wait_for_dialog()
      feed("s")
      assert(vim.wait(1000, function()
        return active_view.dialog_buf == nil
      end, 5))
      vim.wait(50)
      local first_session = assert(controller:new_session())

      local second = vim.fn.tempname()
      vim.fn.mkdir(second, "p")
      paths[#paths + 1] = second
      vim.cmd("cd " .. vim.fn.fnameescape(second))
      local created, create_err = controller:new_session()
      assert.is_nil(created)
      assert.are.equal("workspace_trust", create_err.kind)
      assert.are.equal(first_session, controller:get_session())
      active_view = wait_for_dialog()
      assert.is_not_nil(active_view.dialog.active.body:find(
        require("neoagent.workspace_trust").target(second), 1, true))
      feed("s")
      assert(vim.wait(1000, function()
        return active_view.dialog_buf == nil
      end, 5))
      vim.wait(50)
      local second_session = assert(controller:new_session())
      assert.are_not.equal(first_session, second_session)

      local third = vim.fn.tempname()
      local sessions = vim.fn.tempname()
      vim.fn.mkdir(third, "p")
      paths[#paths + 1], paths[#paths + 2] = third, sessions
      local store = require("neoagent.storage").new({
        directory = sessions,
        cwd = third,
      })
      assert(store:append({ role = "user", content = "saved", timestamp = 1 }))
      local resumed, resume_err = controller:resume(store:metadata().path)
      assert.is_nil(resumed)
      assert.are.equal("workspace_trust", resume_err.kind)
      assert.are.equal(second_session, controller:get_session())
      active_view = wait_for_dialog()
      assert.is_not_nil(active_view.dialog.active.body:find(
        require("neoagent.workspace_trust").target(third), 1, true))
      feed("s")
      assert(vim.wait(1000, function()
        return active_view.dialog_buf == nil
      end, 5))
      vim.wait(50)
      assert(controller:resume(store:metadata().path))
      assert.are.equal("saved", controller:get_session():messages()[1].content)
      assert.are.equal(require("neoagent.fs").canonical(third),
        controller:_state().workspace.root)
      assert.is_true(window:is_open())
    end)

  it("supports an explicit custom Controller trust composition", function()
    neoagent = nil
    local api = require("neoagent")
    local dialogs = require("neoagent.dialog").new()
    local trust_path = vim.fn.tempname() .. "/trust.json"
    paths[#paths + 1] = vim.fs.dirname(trust_path)
    local opts = {
      name = "Review",
      persistence = {
        enabled = false,
        workspace_settings = false,
        directory = vim.fn.tempname(),
      },
      tools = { {
        name = "inspect",
        description = "Inspect the workspace",
        input_schema = {
          type = "object",
          properties = {},
          additionalProperties = false,
        },
        execute = function()
          return { content = { { type = "text", text = "ok" } } }
        end,
      } },
      agents = false,
      skills = false,
      workspace_trust = { path = trust_path },
      ui = { position = "center" },
    }
    local trust_view, policy =
      require("neoagent.workspace_trust").compose(opts, {
        dialogs = dialogs,
        sandbox_status = {
          enabled = true,
          active = true,
          platform = "test",
        },
        session = {},
      })
    local controller = api.new(opts, { workspace_trust = policy })
    custom_controllers[#custom_controllers + 1] = controller
    local window = api.new_window({
      controllers = { controller },
      dialogs = dialogs,
      view = trust_view,
    })
    custom_windows[#custom_windows + 1] = window
    assert.is_nil(controller:config().view)
    policy:attach_window(window, controller)

    window:set_input("custom draft")
    assert(window:open())
    assert(vim.wait(1000, function()
      local active_view = window:_state().view
      return active_view and active_view.dialog_buf ~= nil
    end, 5))
    local active_view = window:_state().view
    assert.are.equal("Review", active_view.dialog.active.controller)
    assert.is_not_nil(active_view.dialog.active.body:find(
      "Review can load AGENTS.md", 1, true))
    assert.is_not_nil(active_view.dialog.active.body:find(
      "native test sandbox", 1, true))

    local session, err = controller:new_session()
    assert.is_nil(session)
    assert.are.equal("workspace_trust", err.kind)
    feed("s")
    assert(vim.wait(1000, function()
      return active_view.dialog_buf == nil
        and policy:is_trusted(vim.fn.getcwd())
    end, 5))
    assert.are.equal("custom draft", active_view:get_input())
    assert(controller:new_session())
  end)

  it("reports a custom trust Controller activation failure", function()
    neoagent = nil
    local api = require("neoagent")
    local dialogs = require("neoagent.dialog").new()
    local path = vim.fn.tempname() .. "/trust.json"
    paths[#paths + 1] = vim.fs.dirname(path)
    local base = {
      persistence = {
        enabled = false,
        workspace_settings = false,
        directory = vim.fn.tempname(),
      },
      tools = {},
      agents = false,
      skills = false,
    }
    local first_opts = vim.tbl_extend("force", vim.deepcopy(base), {
      name = "First",
    })
    local protected_opts = vim.tbl_extend("force", vim.deepcopy(base), {
      name = "Protected",
      workspace_trust = { path = path },
    })
    local notices = {}
    local trust_view, policy =
      require("neoagent.workspace_trust").compose(protected_opts, {
        dialogs = dialogs,
        notify = function(err) notices[#notices + 1] = err end,
        session = {},
      })
    local first = api.new(first_opts)
    local protected = api.new(protected_opts, {
      workspace_trust = policy,
    })
    custom_controllers = { first, protected }
    local window = api.new_window({
      controllers = custom_controllers,
      dialogs = dialogs,
      view = trust_view,
    })
    custom_windows[#custom_windows + 1] = window
    policy:attach_window(window, protected)
    assert(window:open())
    protected.prepare = function()
      return nil, { kind = "ui", message = "selection failed" }
    end

    assert.is_false(policy:request(vim.fn.getcwd()))
    assert(vim.wait(1000, function() return #notices == 1 end, 5))
    assert.are.equal("Failed to activate workspace trust prompt",
      notices[1].message)
    assert.are.equal("selection failed", notices[1].detail)
    assert.is_nil(dialogs:snapshot().active)
  end)

  it("protects project instruction discovery without tools", function()
    local discoveries = 0
    require("neoagent.agents").discover = function()
      discoveries = discoveries + 1
      return { files = {}, diagnostics = {} }
    end
    local controller = setup({
      tools = {},
      agents = {
        global_files = {},
        project_filenames = { "AGENTS.md" },
      },
      skills = false,
    })
    local run, err = controller:send("blocked")
    assert.is_nil(run)
    assert.are.equal("workspace_trust", err.kind)
    assert.are.equal(0, discoveries)

    local active_view = wait_for_dialog()
    feed("s")
    assert(vim.wait(1000, function()
      return active_view.dialog_buf == nil
    end, 5))
    vim.wait(50)
    run = assert(controller:send("allowed"))
    assert(vim.wait(1000, function() return run:is_done() end, 5))
    assert.are.equal(1, discoveries)
  end)

  it("keeps project instruction and skill discovery behind trust",
    function()
      local discoveries = { agents = 0, skills = 0 }
      require("neoagent.agents").discover = function()
        discoveries.agents = discoveries.agents + 1
        return { files = {}, diagnostics = {} }
      end
      require("neoagent.skills").discover = function()
        discoveries.skills = discoveries.skills + 1
        return { skills = {}, diagnostics = {} }
      end
      local read = {
        name = "read_file",
        description = "Read a file",
        input_schema = {
          type = "object",
          properties = {},
          additionalProperties = false,
        },
        execute = function()
          return { content = { { type = "text", text = "ok" } } }
        end,
      }
      local controller = setup({
        tools = { read },
        agents = { global_files = {}, project_filenames = { "AGENTS.md" } },
        skills = { global_dirs = {}, project_dirs = { ".agents/skills" } },
      })
      local run, err = controller:send("blocked")
      assert.is_nil(run)
      assert.are.equal("workspace_trust", err.kind)
      assert.are.same({ agents = 0, skills = 0 }, discoveries)
      local active_view = wait_for_dialog()
      feed("s")
      assert(vim.wait(1000, function()
        return active_view.dialog_buf == nil
      end, 5))
      vim.wait(50)
      run = assert(controller:send("allowed"))
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.are.same({ agents = 1, skills = 1 }, discoveries)
    end)
end)
