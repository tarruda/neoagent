local assert = require("luassert")
local fake_model = require("tests.helpers.fake_model")
local view_handles = require("tests.helpers.view_handles")

---@param keys string
local function feed(keys)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("neoagent workspace trust UI", function()
  local neoagent = require("neoagent")
  ---@type Neoagent.NeoagentApplet?
  local applet
  ---@type string[]
  local paths
  ---@type string
  local original_cwd
  local original_agents_discover = require("neoagent.agent_instructions").discover
  local original_skills_discover = require("neoagent.skills").discover
  ---@type Neoagent.NeoagentApplet[]
  local custom_windows
  ---@type Neoagent.Agent[]
  local custom_agents

  local function current_applet()
    return (assert(applet))
  end

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
    if applet and not current_applet():is_destroyed() then current_applet():destroy() end
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
    require("neoagent.agent_instructions").discover = original_agents_discover
    require("neoagent.skills").discover = original_skills_discover
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    vim.cmd("silent! only")
  end)

  ---@param extra Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>?
  ---@param responses Neoagent.TestModelResponse[]?
  local function setup(extra, responses)
    local model = fake_model.new(responses or { {
      result = fake_model.assistant({ { type = "text", text = "done" } }),
    } })
    local directory = vim.fn.tempname()
    local trust_path = directory .. "/trust.json"
    paths[#paths + 1] = directory
    ---@type Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
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

  ---@param agent Neoagent.Agent?
  ---@return Neoagent.View
  local function view(agent)
    local owner = agent and agent:applet() or applet
    return (assert(assert(owner):view()))
  end

  ---@param agent Neoagent.Agent?
  local function wait_for_dialog(agent)
    assert(vim.wait(1000, function()
      local current = view(agent)
      return current and current.dialog and current.dialog.active
        and vim.api.nvim_buf_is_valid(
          (assert(view_handles.buffer(current, "transcript"))))
    end, 5))
    return view(agent)
  end

  ---@param text string
  local function start(text)
    assert(current_applet():open())
    current_applet():set_input(text)
    local run, err = current_applet():send(text)
    assert.is_nil(run)
    assert.are.equal("workspace_trust", assert(err).kind)
    assert.are.equal(1, #current_applet():agents())
    local agent = assert(assert(applet):agents()[1])
    assert.are.equal(text, assert(agent:applet()):pending_message())
    return agent, wait_for_dialog(agent)
  end

  ---@param active_view Neoagent.View
  ---@param key string
  local function choose(active_view, key)
    active_view:focus_transcript()
    feed(key)
  end

  it("creates the Agent at first submit and resumes the exact message after trust", function()
    local model, trust_path = setup()
    assert(current_applet():open())
    assert.are.same({}, current_applet():agents())
    assert.is_nil(view().dialog)

    local agent, active_view = start("preserved first message")
    local session = assert(agent:get_session())
    assert.is_nil(agent:get_model())
    assert.are.equal("waiting", agent:activity().state)
    assert.are.equal("preserved first message", active_view:get_input())
    local body = assert(active_view.dialog).active.body
    assert.is_not_nil((body:find(
      require("neoagent.workspace_trust").target(vim.fn.getcwd()), 1, true)))
    assert.is_not_nil((body:find("prompt injection", 1, true)))
    assert.is_not_nil((body:find("sandboxing is disabled", 1, true)))

    active_view:focus_transcript()
    feed("<CR>")
    assert(vim.wait(1000, function()
      return active_view.dialog == nil and #model.requests == 1
        and not agent:is_running()
    end, 5))
    assert.are.equal("preserved first message",
      assert(assert(agent:get_session()):messages()[1]).content)
    assert.are.equal(session, agent:get_session())
    assert.are.equal("", active_view:get_input())
    assert.is_nil(assert(agent:applet()):pending_message())
    assert.is_not_nil(vim.uv.fs_stat(trust_path))
  end)

  it("keeps a background trust request closed until its Agent is selected", function()
    local model = setup()
    local agent = start("background request")
    assert(current_applet():new("chat"))
    local chat = assert(current_applet():foreground_applet())
    assert.are.equal("chat", chat.profile)
    assert.is_nil(chat:agent())
    assert.is_false(assert(agent:applet()):is_open())
    assert.is_true(chat:is_open())
    assert.are.equal("waiting", agent:activity().state)
    assert.is_nil(assert(chat:view()).dialog)

    assert.are.equal(agent, current_applet():select(agent:id()))
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
    local provisional_applet = assert(provisional:applet())
    assert(current_applet():new("chat"))
    local chat_run = assert(current_applet():send("newer chat turn"))
    assert(type(chat_run) == "table" and type(chat_run.is_done) == "function")
    assert(vim.wait(1000, function()
      local active = current_applet():active_agent()
      return chat_run:is_done() and active and active:profile_id() == "chat"
        and not active:is_running()
    end, 5))
    local chat = assert(current_applet():active_agent())

    provisional:dialogs():cancel_pending("dialog dismissed by user")

    assert(vim.wait(1000, function()
      return provisional:is_destroyed() and #current_applet():agents() == 1
    end, 5))
    assert.are.equal(chat, current_applet():active_agent())
    assert.are.equal(chat:applet(), current_applet():foreground_applet())
    assert.are.equal(chat:applet(), current_applet():selected_applet())
    assert.are.equal("newer chat turn", assert(assert(model.requests[1]).messages[1]).content)
    assert.are.equal(provisional_applet, current_applet():retained_draft("neo"))
    assert.are.equal("provisional request", provisional_applet:get_input())
  end)

  it("retains the draft after cancellation and persists a later decision", function()
    local _, trust_path = setup()
    local agent, active_view = start("keep me")
    local draft = assert(agent:applet())
    choose(active_view, "q")
    assert(vim.wait(1000, function()
      return not current_applet():is_open() and #current_applet():agents() == 0
        and draft:agent() == nil
    end, 5))
    assert.is_true(agent:is_destroyed())
    assert.are.equal(draft, current_applet():retained_draft("neo"))
    assert.are.equal("keep me", draft:get_input())
    assert.is_nil(draft:pending_message())
    assert.is_nil(vim.uv.fs_stat(trust_path))

    assert(current_applet():open())
    local retry, retry_err = current_applet():send("keep me")
    assert.is_nil(retry)
    assert.are.equal("workspace_trust", assert(retry_err).kind)
    local retried = assert(current_applet():agents()[1])
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
    assert.are.equal("keep me", assert(assert(retried:get_session()):messages()[1]).content)
  end)

  it("restores the draft when trust storage is unreadable", function()
    local _, trust_path = setup()
    assert(require("neoagent.fs").mkdirp(vim.fs.dirname(trust_path)))
    assert(require("neoagent.fs").write_all(trust_path, "{broken", "w", 384))
    assert(current_applet():open())
    local draft = assert(current_applet():foreground_applet())

    local run, err = current_applet():send("preserve unreadable trust draft")

    assert.is_nil(run)
    assert.matches("Invalid workspace trust store", assert(err).message)
    assert.are.same({}, current_applet():agents())
    assert.are.equal(draft, current_applet():retained_draft("neo"))
    assert.is_nil(draft:agent())
    assert.is_nil(draft:pending_message())
    assert.are.equal("preserve unreadable trust draft", draft:get_input())
    assert.is_nil(assert(draft:view()).dialog)
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
    assert(current_applet():new("neo"))
    local run, create_err = current_applet():send("second workspace")
    assert.is_nil(run)
    assert.are.equal("workspace_trust", assert(create_err).kind)
    assert.are.equal(2, #current_applet():agents())
    local second_agent = assert(assert(applet):agents()[2])
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
      assert(second_session:messages()[1]).content)
    assert.are.equal(require("neoagent.fs").canonical(second),
      assert(second_agent:get_workspace()).root)
  end)

  it("supports an explicit custom Agent trust composition", function()
    applet = nil
    local dialogs = require("neoagent.dialog").new()
    local trust_path = vim.fn.tempname() .. "/trust.json"
    paths[#paths + 1] = vim.fs.dirname(trust_path)
    ---@type Neoagent.ConfigInput<Neoagent.AgentToolEnvironment> & {name: string, workspace_trust: {path: string}}
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
      close = function() assert(agent:applet()):close() end,
      on_trusted = function() agent:prepare() end,
    })

    window:set_input("custom draft")
    assert(window:open())
    local active_view = wait_for_dialog(agent)
    assert.are.equal("Review", assert(active_view.dialog).active.agent)
    assert.is_not_nil((assert(active_view.dialog).active.body:find(
      "Review can load AGENTS.md", 1, true)))
    assert.is_not_nil((assert(active_view.dialog).active.body:find(
      "native test sandbox", 1, true)))
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
    assert.are.equal(2, #assert(agent:get_session()):messages())
  end)
end)
