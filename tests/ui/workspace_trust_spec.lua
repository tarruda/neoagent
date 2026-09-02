local fake_model = require("tests.helpers.fake_model")
local view_handles = require("tests.helpers.view_handles")

local function feed(keys)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("neoagent workspace trust UI", function()
  local neoagent
  local applet
  local paths
  local original_cwd
  local original_agents_discover
  local original_skills_discover
  local custom_windows
  local custom_agents

  before_each(function()
    original_agents_discover = require("neoagent.agent_instructions").discover
    original_skills_discover = require("neoagent.skills").discover
    original_cwd = vim.fn.getcwd()
    paths, custom_windows, custom_agents = {}, {}, {}
    local workspace = vim.fn.tempname()
    vim.fn.mkdir(workspace, "p")
    paths[#paths + 1] = workspace
    vim.cmd("cd " .. vim.fn.fnameescape(workspace))
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
  end)

  after_each(function()
    for _, window in ipairs(custom_windows) do window:destroy() end
    for _, agent in ipairs(custom_agents) do agent:destroy() end
    if applet and not applet:is_destroyed() then applet:destroy() end
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
    require("neoagent.agent_instructions").discover = original_agents_discover
    require("neoagent.skills").discover = original_skills_discover
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    vim.cmd("silent! only")
  end)

  local function setup(extra, responses)
    local model = fake_model.new(responses or { {
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
      _apis = { ["fake-api"] = function() return model end },
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
      agent_instructions = false,
      skills = false,
      workspace_trust = { path = trust_path },
      ui = { position = "center" },
    }
    for key, value in pairs(extra or {}) do options[key] = value end
    applet = neoagent.setup(options)
    return model, trust_path
  end

  local function view(agent)
    local owner = agent and agent:applet() or applet
    return owner:view()
  end

  local function wait_for_dialog(agent)
    assert(vim.wait(1000, function()
      local current = view(agent)
      return current and current.dialog and current.dialog.active
        and vim.api.nvim_buf_is_valid(
          view_handles.buffer(current, "transcript"))
    end, 5))
    return view(agent)
  end

  local function start(text)
    assert(applet:open())
    applet:set_input(text)
    local run, err = applet:send(text)
    assert.is_nil(run)
    assert.are.equal("workspace_trust", err.kind)
    assert.are.equal(1, #applet:agents())
    local agent = applet:agents()[1]
    assert.are.equal(text, agent:applet():pending_message())
    return agent, wait_for_dialog(agent)
  end

  local function choose(active_view, key)
    active_view:focus_transcript()
    feed(key)
  end

  it("creates the Agent at first submit and resumes the exact message after trust", function()
    local model, trust_path = setup()
    assert(applet:open())
    assert.are.same({}, applet:agents())
    assert.is_nil(view().dialog)

    local agent, active_view = start("preserved first message")
    local session = assert(agent:get_session())
    assert.is_nil(agent:get_model())
    assert.are.equal("waiting", agent:activity().state)
    assert.are.equal("preserved first message", active_view:get_input())
    local body = active_view.dialog.active.body
    assert.is_not_nil(body:find(
      require("neoagent.workspace_trust").target(vim.fn.getcwd()), 1, true))
    assert.is_not_nil(body:find("prompt injection", 1, true))
    assert.is_not_nil(body:find("sandboxing is disabled", 1, true))

    active_view:focus_transcript()
    feed("<CR>")
    assert(vim.wait(1000, function()
      return active_view.dialog == nil and #model.requests == 1
        and not agent:is_running()
    end, 5))
    assert.are.equal("preserved first message",
      agent:get_session():messages()[1].content)
    assert.are.equal(session, agent:get_session())
    assert.are.equal("", active_view:get_input())
    assert.is_nil(agent:applet():pending_message())
    assert.is_not_nil(vim.uv.fs_stat(trust_path))
  end)

  it("keeps a background trust request closed until its Agent is selected", function()
    local model = setup()
    local agent = start("background request")
    assert(applet:new("chat"))
    local chat = applet:foreground_applet()
    assert.are.equal("chat", chat.profile)
    assert.is_nil(chat:agent())
    assert.is_false(agent:applet():is_open())
    assert.is_true(chat:is_open())
    assert.are.equal("waiting", agent:activity().state)
    assert.is_nil(chat:view().dialog)

    assert.are.equal(agent, applet:select(agent:id()))
    local active_view = wait_for_dialog(agent)
    choose(active_view, "s")
    assert(vim.wait(1000, function()
      return active_view.dialog == nil and #model.requests == 1
        and not agent:is_running()
    end, 5))
  end)

  it("preserves a newer Agent when a provisional trust request fails", function()
    local model = setup()
    local provisional = start("provisional request")
    local provisional_applet = provisional:applet()
    assert(applet:new("chat"))
    local chat_run = assert(applet:send("newer chat turn"))
    assert(vim.wait(1000, function()
      local active = applet:active_agent()
      return chat_run:is_done() and active and active:profile_id() == "chat"
        and not active:is_running()
    end, 5))
    local chat = assert(applet:active_agent())

    provisional:dialogs():cancel_pending("dialog dismissed by user")

    assert(vim.wait(1000, function()
      return provisional:is_destroyed() and #applet:agents() == 1
    end, 5))
    assert.are.equal(chat, applet:active_agent())
    assert.are.equal(chat:applet(), applet:foreground_applet())
    assert.are.equal(chat:applet(), applet:selected_applet())
    assert.are.equal("newer chat turn", model.requests[1].messages[1].content)
    assert.are.equal(provisional_applet, applet:retained_draft("neo"))
    assert.are.equal("provisional request", provisional_applet:get_input())
  end)

  it("retains the draft after cancellation and persists a later decision", function()
    local _, trust_path = setup()
    local agent, active_view = start("keep me")
    local draft = agent:applet()
    choose(active_view, "q")
    assert(vim.wait(1000, function()
      return not applet:is_open() and #applet:agents() == 0
        and draft:agent() == nil
    end, 5))
    assert.is_true(agent:is_destroyed())
    assert.are.equal(draft, applet:retained_draft("neo"))
    assert.are.equal("keep me", draft:get_input())
    assert.is_nil(draft:pending_message())
    assert.is_nil(vim.uv.fs_stat(trust_path))

    assert(applet:open())
    local retry, retry_err = applet:send("keep me")
    assert.is_nil(retry)
    assert.are.equal("workspace_trust", retry_err.kind)
    local retried = assert(applet:agents()[1])
    active_view = wait_for_dialog(retried)
    choose(active_view, "t")
    assert(vim.wait(1000, function()
      return active_view.dialog == nil
        and vim.uv.fs_stat(trust_path) ~= nil
        and not retried:is_running()
    end, 5))
    local trusted = assert(require("neoagent.workspace_trust")
      .new_store(trust_path):list())
    assert.are.same({ require("neoagent.workspace_trust")
      .target(vim.fn.getcwd()) }, trusted)
    assert.are.equal("keep me", retried:get_session():messages()[1].content)
  end)

  it("restores the draft when trust storage is unreadable", function()
    local _, trust_path = setup()
    assert(require("neoagent.fs").mkdirp(vim.fs.dirname(trust_path)))
    assert(require("neoagent.fs").write_all(trust_path, "{broken", "w", 384))
    assert(applet:open())
    local draft = assert(applet:foreground_applet())

    local run, err = applet:send("preserve unreadable trust draft")

    assert.is_nil(run)
    assert.matches("Invalid workspace trust store", err.message)
    assert.are.same({}, applet:agents())
    assert.are.equal(draft, applet:retained_draft("neo"))
    assert.is_nil(draft:agent())
    assert.is_nil(draft:pending_message())
    assert.are.equal("preserve unreadable trust draft", draft:get_input())
    assert.is_nil(draft:view().dialog)
  end)

  it("binds each trusted Workspace to a distinct Agent and Session", function()
    local model = setup()
    local agent, active_view = start("initial")
    choose(active_view, "s")
    assert(vim.wait(1000, function()
      return active_view.dialog == nil and #model.requests == 1
        and not agent:is_running()
    end, 5))
    local first_session = agent:get_session()

    local second = vim.fn.tempname()
    vim.fn.mkdir(second, "p")
    paths[#paths + 1] = second
    vim.cmd("cd " .. vim.fn.fnameescape(second))
    assert(applet:new("neo"))
    local run, create_err = applet:send("second workspace")
    assert.is_nil(run)
    assert.are.equal("workspace_trust", create_err.kind)
    assert.are.equal(2, #applet:agents())
    local second_agent = applet:agents()[2]
    local second_session = second_agent:get_session()
    assert.are_not.equal(agent, second_agent)
    assert.are_not.equal(first_session, second_session)
    assert.are.equal(first_session, agent:get_session())
    active_view = wait_for_dialog(second_agent)
    choose(active_view, "s")
    assert(vim.wait(1000, function()
      return active_view.dialog == nil and #model.requests == 2
        and not second_agent:is_running()
    end, 5))
    assert.are.equal(second_session, second_agent:get_session())
    assert.are.equal("second workspace",
      second_session:messages()[1].content)
    assert.are.equal(require("neoagent.fs").canonical(second),
      second_agent:get_workspace().root)
  end)

  it("supports an explicit custom Agent trust composition", function()
    applet = nil
    local dialogs = require("neoagent.dialog").new()
    local trust_path = vim.fn.tempname() .. "/trust.json"
    paths[#paths + 1] = vim.fs.dirname(trust_path)
    local opts = {
      name = "Review",
      default_registry = false,
      providers = {},
      persistence = { enabled = false, workspace_settings = false },
      tools = { {
        name = "inspect",
        description = "Inspect the workspace",
        input_schema = { type = "object", properties = {},
          additionalProperties = false },
        execute = function()
          return { content = { { type = "text", text = "ok" } } }
        end,
      } },
      agent_instructions = false,
      skills = false,
      workspace_trust = { path = trust_path },
      ui = { position = "center" },
    }
    local policy = require("neoagent.workspace_trust").compose(opts, {
      dialogs = dialogs,
      sandbox_status = { enabled = true, active = true, platform = "test" },
      session = {},
    })
    local agent = neoagent.new(opts, {
      dialogs = dialogs,
      workspace_trust = policy,
    })
    custom_agents[#custom_agents + 1] = agent
    local window = neoagent._new_applet({ agents = { agent } })
    custom_windows[#custom_windows + 1] = window
    policy:attach({
      close = function() agent:applet():close() end,
      on_trusted = function() agent:prepare() end,
    })

    window:set_input("custom draft")
    assert(window:open())
    local active_view = wait_for_dialog(agent)
    assert.are.equal("Review", active_view.dialog.active.agent)
    assert.is_not_nil(active_view.dialog.active.body:find(
      "Review can load AGENTS.md", 1, true))
    assert.is_not_nil(active_view.dialog.active.body:find(
      "native test sandbox", 1, true))
    choose(active_view, "s")
    assert(vim.wait(1000, function()
      return active_view.dialog == nil and policy:is_trusted(vim.fn.getcwd())
    end, 5))
    assert.are.equal("custom draft", active_view:get_input())
    local session = assert(agent:get_session())
    assert(agent:prepare())
    assert.are.equal(session, agent:get_session())
  end)

  it("keeps project resource discovery behind trust and resumes it once", function()
    local discoveries = { instructions = 0, skills = 0 }
    require("neoagent.agent_instructions").discover = function()
      discoveries.instructions = discoveries.instructions + 1
      return { files = {}, diagnostics = {} }
    end
    require("neoagent.skills").discover = function()
      discoveries.skills = discoveries.skills + 1
      return { skills = {}, diagnostics = {} }
    end
    setup({
      tools = { {
        name = "read_file",
        capabilities = { read_files = true },
        description = "Read a file",
        input_schema = { type = "object", properties = {},
          additionalProperties = false },
        execute = function()
          return { content = { { type = "text", text = "ok" } } }
        end,
      } },
      agent_instructions = {
        global_files = {}, project_filenames = { "AGENTS.md" },
      },
      skills = { global_dirs = {}, project_dirs = { ".agents/skills" } },
    })
    local agent, active_view = start("discover after trust")
    assert.are.same({ instructions = 0, skills = 0 }, discoveries)
    choose(active_view, "s")
    assert(vim.wait(1000, function()
      return active_view.dialog == nil and discoveries.instructions == 1
        and discoveries.skills == 1 and not agent:is_running()
    end, 5))
    assert.are.same({ instructions = 1, skills = 1 }, discoveries)
    assert.are.equal(2, #agent:get_session():messages())
  end)
end)
