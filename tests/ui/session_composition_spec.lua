local fs = require("neoagent.fs")
local assert = require("luassert")
local neoagent = require("neoagent")
local config = require("neoagent.config")
local fake_model = require("tests.helpers.fake_model")
---@type (Neoagent.NeoagentApplet|Neoagent.Agent)[]
local owners = {}
---@type string[]
local paths = {}
---@type (fun())[]
local restores = {}

---@return string
local function directory()
  local path = fs.canonical(vim.fn.tempname())
  paths[#paths + 1] = path
  return path
end

---@param extra? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@return Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
local function configuration(extra)
  ---@type Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  local options = {
    default_registry = false,
    workspace_trust = false,
    sandbox = { enabled = false },
    persistence = { enabled = false },
    recording = { enabled = false },
    agent_instructions = false,
    skills = false,
    tools = {},
    compaction = false,
    default_model = { provider = "fake", model = "a" },
    providers = { fake = { api = "fake-api", models = { a = {}, b = {} } } },
    _apis = {
      ["fake-api"] = function(resolved)
        local model = fake_model.new({
          { result = fake_model.assistant({ { type = "text", text = "done" } }) },
          { result = fake_model.assistant({ { type = "text", text = "done again" } }) },
        })
        model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
        model.thinking = { medium = {}, high = {} }
        for _, response in ipairs(model.responses) do
          local message = response.result.message
          assert(message)
          message.api = resolved.api
          message.provider = resolved.provider_id
          message.model = resolved.model_id
        end
        return model
      end,
    },
    ui = { images = false, position = "center" },
  }
  return require("neoagent.util").deep_merge(options, extra or {}) --[[@as Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>]]
end

---@param extra? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@return Neoagent.NeoagentApplet
local function setup(extra)
  local owner = neoagent._setup(configuration(extra), { startup = false })
  owners[#owners + 1] = owner
  return owner
end

---@param draft Neoagent.AgentApplet
---@return Neoagent.Agent
local function submit(draft)
  local run = draft:send("synthetic review probe")
  assert(run)
  assert(type(run) == "table")
  assert(vim.wait(2000, function()
    return run:is_done()
  end, 5))
  local result = run:result()
  assert(result)
  assert(result.ok, vim.inspect(result))
  local agent = draft:agent()
  assert(agent)
  return agent
end

---@generic R, E
---@param run Neoagent.Run<R, E>
---@return R
local function finish(run)
  assert(vim.wait(3000, function()
    return run:is_done()
  end, 5))
  local result = run:result()
  assert(result)
  return result
end

describe("Session composition transitions", function()
  after_each(function()
    for index = #restores, 1, -1 do
      restores[index]()
    end
    restores = {}
    for index = #owners, 1, -1 do
      owners[index]:destroy()
    end
    owners = {}
    for _, path in ipairs(paths) do
      vim.fn.delete(path, "rf")
    end
    paths = {}
  end)

  it("retains a draft's explicit renderer when model selection changes its Profile", function()
    local owner = setup({
      default_profile = function(model)
        return model and model.model == "b" and "chat" or "pi"
      end,
    })
    assert(owner:open())
    local draft, view = owner:foreground_applet(), owner:view()
    assert(draft)
    assert(view)
    local renderer = require("neoagent.util").shallow_copy(draft.renderer)
    assert(draft:set_renderer(renderer))
    assert(owner:set_model("fake", "b"))
    assert.are.equal("chat", draft.profile)
    assert.are.equal(renderer, draft.renderer)
    assert.are.equal(renderer, view.renderer)
    assert.are.equal(renderer, assert(assert(owner:get_draft_options(draft)).ui).renderer)
  end)

  for _, existing in ipairs({ false, true }) do
    it("retains " .. (existing and "existing" or "new") .. " relative storage across cwd changes", function()
      local fs = require("neoagent.fs")
      local a, b = directory(), directory()
      assert(fs.mkdirp(a))
      assert(fs.mkdirp(b))
      local cwd = vim.fn.getcwd()
      restores[#restores + 1] = function()
        vim.api.nvim_set_current_dir(cwd)
      end
      vim.api.nvim_set_current_dir(a)
      local storage = a .. "/state"
      if existing then
        assert(require("neoagent.workspace_settings").new({ directory = storage, root = a }):write({
          default_model = { provider = "fake", model = "b" },
        }))
      end
      local owner = setup({ persistence = { enabled = true, directory = "state", workspace_settings = true } })
      assert(owner:open())
      local draft = owner:foreground_applet()
      assert(draft)
      vim.api.nvim_set_current_dir(b)
      assert(owner:update_draft_options({ system_prompt = "ordinary edit after changing cwd" }, draft))
      local agent = submit(draft)
      assert.are.equal(storage, agent:config().persistence.directory)
      local metadata = agent:get_session():metadata()
      assert(metadata)
      assert.are.equal(a, metadata.cwd)
      assert.is_true(vim.startswith(assert(metadata.path), storage .. "/"))
      assert.are.same({ provider = "fake", model = existing and "b" or "a" }, agent:get_model_selection())
      assert.are.equal(storage, assert(draft.persistence).directory)
      assert.is_nil(vim.uv.fs_stat(b .. "/state"))
      vim.api.nvim_set_current_dir(a)
      local choices = owner:_resume_choices()
      assert.are.equal(1, #choices)
      assert.are.equal(metadata.path, assert(choices[1]).path)
    end)
  end

  it("rejects presentation edits while a draft awaits Workspace trust", function()
    local owner = setup({
      workspace_trust = { path = directory() .. "/trust.json" },
      tools = { require("neoagent.tools.pi.read").new() },
    })
    assert(owner:open())
    local applet = owner:foreground_applet()
    assert(applet)
    local draft = owner:_owned_draft(applet)
    local renderer = applet.renderer
    local run, trust_err = owner:send("retain this pending submission")
    assert.is_nil(run)
    assert.are.equal("workspace_trust", assert(trust_err).kind)
    assert.are.equal("provisional", draft:state())
    ---@type (fun(): unknown, Neoagent.Error|Applet.Error|nil)[]
    local mutations = {
      function() return applet:set_position("left") end,
      function() return applet:set_renderer(require("neoagent.ui.renderers").codex) end,
      function() return applet:set_transcript_style("codex") end,
      function() return owner:set_position("left") end,
    }
    for _, mutate in ipairs(mutations) do
      local changed, err = mutate()
      assert.is_nil(changed)
      assert.are.equal("profile", assert(err).kind)
    end
    assert.are.equal(renderer, applet.renderer)
    assert.are.equal("center", applet.position)
    assert.are.equal("pi", applet.transcript_style)
  end)

  for _, operation in ipairs({ "resume", "copy", "fork" }) do
    it("returns a busy error when " .. operation .. " targets a draft awaiting trust", function()
      local owner = setup({
        workspace_trust = { path = directory() .. "/trust.json" },
        tools = { require("neoagent.tools.pi.read").new() },
      })
      assert(owner:open())
      local applet = owner:foreground_applet()
      assert(applet)
      local draft = owner:_owned_draft(applet)
      local run, trust_err = owner:send("retain this pending submission")
      assert.is_nil(run)
      assert.are.equal("workspace_trust", assert(trust_err).kind)
      local key = draft.key
      assert.are.equal("provisional", draft:state())
      local session = assert(require("neoagent.profile_sessions").new({
        profile_id = "pi",
        workspace = draft.workspace,
        persistence = { enabled = true, directory = directory() },
      }))
      assert(session:append({ role = "user", content = "saved conversation" }))
      local selected, err
      if operation == "resume" then
        selected, err = owner:resume(assert(session:metadata()).path)
      else
        local source = neoagent.new(configuration(), { session = session, workspace = draft.workspace })
        owners[#owners + 1] = source
        selected, err = owner:_derive(source, "pi", { kind = operation })
      end
      assert.is_nil(selected)
      assert.are.equal("The destination draft is already being submitted", assert(err).message)
      assert.are.equal("provisional", draft:state())
      assert.are.equal(key, draft.key)
      assert.are.equal(applet, owner:retained_draft("pi", draft.workspace))
      assert.are.equal("retain this pending submission", applet:pending_message())
    end)
  end

  it("preserves explicit configuration through health checks and Applet recreation", function()
    local options = configuration({ profile = "chat", name = "Explicit Chat", sandbox = { enabled = true } })
    local owner = neoagent._setup(options, { startup = false })
    owners[#owners + 1] = owner
    local function check(applet)
      local accepted = applet:_owned_draft(assert(applet:draft())):snapshot().config
      assert.are.equal("Explicit Chat", accepted.name)
      assert.is_true(accepted.sandbox.enabled)
    end
    check(owner)
    options.name = "caller mutation"
    assert(options.sandbox).enabled = false
    local profiles = require("neoagent.profiles")
    local original = profiles.bundled
    restores[#restores + 1] = function()
      profiles.bundled = original
    end
    local checked = false
    profiles.bundled = function(snapshot, runtime)
      local definitions, default, resources = original(snapshot, runtime)
      for _, profile in ipairs(definitions) do
        if profile.id == "chat" then
          local effective = require("neoagent.profiles.selection").configuration(snapshot, profile)
          checked = effective.name == "Explicit Chat" and effective.sandbox.enabled == true
        end
      end
      return definitions, default, resources
    end
    local health = vim.health
    restores[#restores + 1] = function()
      vim.health = health
    end
    vim.health = { start = function() end, ok = function() end, warn = function() end, error = function() end }
    require("neoagent.health").check()
    assert.is_true(checked)
    local replaced = pcall(neoagent.setup, configuration({ name = "Rejected", default_profile = "missing" }))
    assert.is_false(replaced)
    owner:destroy()
    local recreated = neoagent.applet()
    owners[#owners + 1] = recreated
    check(recreated)
  end)

  for _, enabled in ipairs({ false, true }) do
    it("discovers accepted storage through draft binding, original persistence=" .. tostring(enabled), function()
      local destination = directory()
      local owner = setup({ persistence = { enabled = enabled, directory = directory() } })
      local draft, draft_err = owner:draft("pi")
      assert(draft, draft_err)
      assert(owner:update_draft_options({ persistence = { enabled = true, directory = destination } }, draft))
      local agent = submit(draft)
      local path = assert(agent:get_session():metadata()).path
      local choices = owner:_resume_choices()
      assert.are.equal(1, #choices)
      assert.are.equal(path, assert(choices[1]).path)
      local retained = assert(owner:draft("pi"))
      assert(
        owner:update_draft_options({ persistence = { enabled = true, directory = destination .. "/./" } }, retained)
      )
      assert.are.equal(1, #owner:_resume_choices())
      owner:destroy_agent(agent)
      choices = owner:_resume_choices()
      assert.are.equal(1, #choices)
      assert.are.equal(path, assert(choices[1]).path)
    end)
  end

  it("uses explicit Tools on a supplied Profile without a default Tool factory", function()
    local tool = require("neoagent.tools.pi.read").new()
    local owner = neoagent._setup(configuration({ profile = "custom", tools = { tool } }), {
      startup = false,
      profiles = { { id = "custom", label = "Custom" } },
    })
    owners[#owners + 1] = owner
    local accepted = owner:_owned_draft(assert(owner:draft())):snapshot()
    local tools = require("neoagent.profiles.composition").tools(accepted)
    assert.are.equal(1, #tools)
    assert.are.equal(tool.execute, assert(tools[1]).execute)
  end)

  it("keeps Chat instruction discovery disabled by default", function()
    local root = directory()
    assert(require("neoagent.fs").mkdirp(root))
    assert(require("neoagent.fs").write_all(root .. "/AGENTS.md", "DISABLED_CHAT_INSTRUCTION\n"))
    local discovered
    local options = configuration({
      profile = "chat",
      system_prompt = function(context)
        discovered = context.agent_instructions
        return "Chat base"
      end,
    })
    options.agent_instructions = nil
    local agent = neoagent.new(options, { workspace = root })
    owners[#owners + 1] = agent
    assert.is_true(finish(assert(agent:send("work"))).ok)
    assert.are.same({}, discovered)
    assert.is_false(agent:config().agent_instructions)
  end)

  it("initializes the completed Toolset once with copied resumed history", function()
    local session = assert(require("neoagent.session").new())
    assert(session:append({ role = "user", content = "retained history" }))
    local tool = require("neoagent.tools.pi.read").new()
    local calls = 0
    local observed, identity, files
    tool.on_messages = function(messages, context)
      calls = calls + 1
      observed = require("neoagent.util").copy(messages)
      identity, files = context.session_id, context.files
      assert(messages[1]).content = "hook mutation"
    end
    local agent = neoagent.new(configuration({ tools = { tool } }), { session = session })
    owners[#owners + 1] = agent
    assert.are.equal(1, calls)
    assert.are.same(session:messages(), observed)
    assert.are.equal("retained history", assert(session:messages()[1]).content)
    assert.are.equal(session:identity(), identity)
    assert.are.equal(session:files(), files)
    assert.are.equal(tool.on_messages, assert(agent:get_toolset().tools[1]).on_messages)
  end)

  it("closes native ownership when final Agent initialization fails", function()
    local processes = require("neoagent.process_sessions")
    local original = processes.new
    ---@type Neoagent.ProcessSessions?
    local captured
    restores[#restores + 1] = function()
      processes.new = original
      if captured then
        captured:close("test cleanup")
      end
    end
    processes.new = function(...)
      captured = original(...)
      return captured
    end
    local effects = require("neoagent.util").shallow_copy(require("applet").host_effects)
    effects.on_exit = function()
      error("exit registration rejected", 0)
    end
    local ok, err = pcall(neoagent.new, configuration(), { host_effects = effects })
    assert.is_false(ok)
    assert.matches("exit registration rejected", tostring(err))
    assert(captured)
    assert.is_true(captured:status().closed)
    assert.is_true(captured:status().cleanup_done)
  end)

  for _, dependency in ipairs({ "auth", "runtimes", "host_effects" }) do
    it("rejects an invalid supplied " .. dependency .. " dependency", function()
      ---@type Neoagent.AgentRuntimeOptions
      local runtime = { runtimes = {} }
      rawset(runtime, dependency, false)
      local ok, value = pcall(neoagent.new, configuration(), runtime)
      if ok then
        owners[#owners + 1] = value
      end
      assert.is_false(ok)
    end)
  end

  for _, strategy in ipairs({ "summary", "prefix" }) do
    it("retains explicitly enabled Chat instructions during " .. strategy .. " compaction", function()
      local root = directory()
      local fs = require("neoagent.fs")
      assert(fs.mkdirp(root))
      assert(fs.write_all(root .. "/AGENTS.md", "EXPLICIT_CHAT_INSTRUCTION\n"))
      local options = configuration({
        profile = "chat",
        system_prompt = "Explicit Chat base",
        agent_instructions = { global_files = {}, project_filenames = { "AGENTS.md" } },
        compaction = { strategy = strategy, auto = false, keep_recent_tokens = 1, reserve_tokens = 512 },
      })
      local model = fake_model.new({
        { result = fake_model.assistant({ { type = "text", text = "done" } }) },
        { result = fake_model.assistant({ { type = "text", text = "summary" } }) },
      })
      model.context_window = 16384
      assert(options._apis)["fake-api"] = function()
        return model
      end
      local agent = neoagent.new(options, { workspace = root })
      owners[#owners + 1] = agent
      assert.is_true(finish(assert(agent:send(string.rep("synthetic history ", 700)))).ok)
      assert.is_true(finish(assert(agent:compact())).ok)
      assert.are.equal(2, #model.requests)
      for _, request in ipairs(model.requests) do
        local context = (request.system_prompt or "") .. vim.inspect(request.messages)
        assert.matches("EXPLICIT_CHAT_INSTRUCTION", context, 1, true)
        assert.matches(root:gsub("\\", "/"), context, 1, true)
      end
      assert.matches("Explicit Chat base", assert(assert(model.requests[1]).system_prompt), 1, true)
      if strategy == "summary" then
        assert.matches(
          require("neoagent.compaction.summary").system_prompt,
          assert(assert(model.requests[2]).system_prompt),
          1,
          true
        )
      end
      assert.is_nil(vim.inspect(agent:get_session():entries()):find("EXPLICIT_CHAT_INSTRUCTION", 1, true))
    end)

    it("retains shipped Pi context during " .. strategy .. " compaction", function()
      local root = directory()
      local fs = require("neoagent.fs")
      assert(fs.mkdirp(root .. "/skills/fixture"))
      assert(fs.write_all(root .. "/AGENTS.md", "TRUSTED_PROJECT_MARKER: preserve this rule\n"))
      assert(
        fs.write_all(
          root .. "/skills/fixture/SKILL.md",
          "---\nname: fixture\ndescription: TRUSTED_SKILL_MARKER\n---\nSynthetic body.\n"
        )
      )
      local options = configuration({
        profile = "pi",
        agent_instructions = { global_files = {}, project_filenames = { "AGENTS.md" } },
        skills = { global_dirs = {}, project_dirs = { "skills" } },
        compaction = { strategy = strategy, auto = false, keep_recent_tokens = 1, reserve_tokens = 512 },
      })
      options.tools = nil
      ---@type Neoagent.TestModel?
      local captured
      local create = assert(assert(options._apis)["fake-api"])
      assert(options._apis)["fake-api"] = function(resolved)
        local model = create(resolved)
        model.context_window = 16384
        captured = model --[[@as Neoagent.TestModel]]
        return model
      end
      local agent = neoagent.new(options, { workspace = root })
      owners[#owners + 1] = agent
      assert.is_true(finish(assert(agent:send(string.rep("synthetic history ", 700)))).ok)
      assert.is_true(finish(assert(agent:compact())).ok)
      assert(captured)
      assert.are.equal(2, #captured.requests)
      for _, request in ipairs(captured.requests) do
        local context = (request.system_prompt or "") .. vim.inspect(request.messages)
        assert.matches("TRUSTED_PROJECT_MARKER", context, 1, true)
        assert.matches("TRUSTED_SKILL_MARKER", context, 1, true)
        assert.matches(root:gsub("\\", "/"), context, 1, true)
      end
      if strategy == "summary" then
        assert.matches(
          require("neoagent.compaction.summary").system_prompt,
          assert(assert(captured.requests[2]).system_prompt),
          1,
          true
        )
      end
      assert.is_nil(vim.inspect(agent:get_session():messages()):find("TRUSTED_PROJECT_MARKER", 1, true))
    end)
  end

  for _, kind in ipairs({ "copy", "fork" }) do
    for _, change in ipairs({ "disabled", "directory" }) do
      it("uses the accepted destination for " .. kind .. " with persistence " .. change, function()
        local base, destination = directory(), directory()
        local owner = setup({ persistence = { enabled = true, directory = base } })
        local first = owner:draft("pi")
        assert(first)
        local source = submit(first)
        local target = owner:draft("pi")
        assert(target)
        local patch = change == "disabled" and { enabled = false } or { directory = destination }
        assert(owner:update_draft_options({ persistence = patch }, target))
        local run = owner:_derive(source, "pi", { kind = kind })
        assert(run)
        local result = finish(run)
        assert(result.ok, vim.inspect(result))
        local agent = result.agent
        local metadata = agent:get_session():metadata()
        assert(metadata)
        assert.are.equal(target, agent:applet())
        assert.are.equal(change ~= "disabled", metadata.persisted)
        assert.are.equal(change ~= "disabled", agent:config().persistence.enabled)
        if change == "directory" then
          assert.are.equal(destination, agent:config().persistence.directory)
          assert(metadata.path)
          assert.are.equal(destination, metadata.path:sub(1, #destination))
        else
          assert.is_nil(metadata.path)
        end
      end)
    end
  end

  for _, operation in ipairs({ "resume", "copy" }) do
    for _, failure in ipairs({ "construction", "hydration" }) do
      it("preserves an automatic draft after " .. operation .. " " .. failure .. " fails", function()
        local owner = setup({ persistence = { enabled = true, directory = directory() } })
        local first = owner:draft("pi")
        assert(first)
        local source = submit(first)
        local source_path = assert(source:get_session():metadata()).path
        if operation == "resume" then
          owner:destroy_agent(source)
        end
        assert(owner:new())
        local automatic = owner:foreground_applet()
        assert(automatic)
        automatic:set_input("retained draft input")
        assert(owner:select_model())
        local picker = automatic:presenter():snapshot().active
        assert(picker)
        local draft = owner:_owned_draft(automatic)
        local original_key = draft.key
        if failure == "construction" then
          local profiles = require("neoagent.profiles")
          local original = profiles.create_agent
          restores[#restores + 1] = function()
            profiles.create_agent = original
          end
          profiles.create_agent = function()
            error("construction rejected", 0)
          end
        else
          local view = automatic:view()
          assert(view)
          local original = view.set_messages
          restores[#restores + 1] = function()
            view.set_messages = original
          end
          local reject = true
          function view:set_messages(messages)
            if reject then
              reject = false
              error("hydration rejected", 0)
            end
            return original(view, messages)
          end
        end
        if operation == "resume" then
          local resumed, err = owner:resume(source_path)
          assert.is_nil(resumed)
          assert.matches(failure .. " rejected", assert(err).message)
        else
          local run = owner:_derive(source, "pi", { kind = "copy" })
          assert(run)
          local result = finish(run)
          assert.is_false(result.ok)
        end
        assert.are.equal("retained draft input", automatic:get_input())
        assert.is_true(draft:is_automatic())
        assert.are.equal(original_key, draft.key)
        assert.are.equal(automatic, owner:draft())
        assert.are.equal(picker.id, assert(automatic:presenter():snapshot().active).id)
      end)
    end
  end

  for _, transition in ipairs({ "update", "submit", "destroy", "cancel" }) do
    it("preserves newer draft state when " .. transition .. " interrupts derivation", function()
      local owner = setup({ persistence = { enabled = true, directory = directory() } })
      local first = owner:draft("pi")
      assert(first)
      local source = submit(first)
      assert(owner:new())
      local target = owner:foreground_applet()
      assert(target)
      target:set_input("retained input")
      assert(owner:select_model())
      local draft = owner:_owned_draft(target)
      local picker = target:presenter():snapshot().active
      assert(picker)
      local sessions = require("neoagent.profile_sessions")
      local original = sessions.derive
      restores[#restores + 1] = function()
        sessions.derive = original
      end
      ---@type fun()?
      local release
      ---@async
      sessions.derive = function(session, options)
        require("neoagent.async").await(function(done)
          release = function()
            done.resolve(true)
          end
        end)
        return original(session, options)
      end
      local run = owner:_derive(source, "pi", { kind = "copy" })
      assert(run)
      restores[#restores + 1] = function()
        run:cancel()
      end
      assert(vim.wait(1000, function()
        return release ~= nil
      end, 5))
      if transition == "update" then
        assert(owner:update_draft_options({ persistence = { enabled = false } }, target))
      elseif transition == "submit" then
        submit(target)
      elseif transition == "destroy" then
        target:destroy()
      else
        run:cancel()
      end
      assert(release)
      release()
      local result = finish(run)
      assert.is_false(result.ok)
      if transition == "cancel" then
        assert.are.equal("cancelled", result.error.kind)
      else
        assert.matches("destination draft changed", tostring(result.error.detail))
        assert.is_true(result.error.session_created)
        assert.is_truthy(vim.uv.fs_stat(result.error.session_path))
      end
      if transition == "update" or transition == "cancel" then
        assert.is_true(draft:is_automatic())
        assert.are.equal(target, owner:draft())
        assert.are.equal("retained input", target:get_input())
        assert.are.equal(picker.id, assert(target:presenter():snapshot().active).id)
      elseif transition == "submit" then
        assert.are.equal(2, #owner:agents())
      else
        assert.are.equal(1, #owner:agents())
      end
    end)
  end

  it("filters fallback inventory using a constant default Profile", function()
    local options = configuration({ default_profile = "codex" })
    options.default_model = nil
    options.providers = {
      anthropic = { api = "anthropic-messages", base_url = "https://example.test", models = { test = {} } },
      openai = { api = "openai-responses", base_url = "https://example.test", models = { test = {} } },
    }
    options._apis = {}
    local function factory(resolved)
      local model = fake_model.new({})
      model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
      return model
    end
    options._apis["anthropic-messages"], options._apis["openai-responses"] = factory, factory
    local agent = neoagent.new(options)
    owners[#owners + 1] = agent
    assert(agent:prepare())
    assert.are.same({ provider = "openai", model = "test" }, agent:get_model_selection())
    local compatible, err = pcall(neoagent.new, options, {
      initial_selection = { model = { provider = "anthropic", model = "test" } },
    })
    assert.is_false(compatible)
    assert.matches("incompatible with Profile codex", tostring(err))
  end)

  for _, strategy in ipairs({ "summary", "prefix" }) do
    it("projects Profile context into " .. strategy .. " generation", function()
      ---@type Neoagent.TestModel?
      local captured
      local projections = 0
      local options = configuration({
        default_profile = "custom",
        compaction = {
          strategy = strategy,
          auto = false,
          keep_recent_tokens = 1,
          reserve_tokens = 512,
        },
      })
      assert(options._apis)["fake-api"] = function(resolved)
        local model = fake_model.new({ { result = fake_model.assistant({ { type = "text", text = "checkpoint" } }) } })
        model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
        model.context_window = 16384
        captured = model
        return model
      end
      local agent = neoagent.new(options, {
        profiles = {
          {
            id = "custom",
            label = "Custom",
            prepare_prompt = function()
              return {
                system_prompt = "Profile system",
                prepare_request = function(request)
                  projections = projections + 1
                  ---@type Neoagent.RequestMessage[]
                  local messages = { { role = "developer", content = "ephemeral profile context" } }
                  vim.list_extend(messages, request.messages)
                  return { messages = messages, system_prompt = request.system_prompt }
                end,
              }
            end,
          },
        },
      })
      owners[#owners + 1] = agent
      assert(agent:prepare())
      assert(agent:get_session():append({ role = "user", content = string.rep("synthetic history ", 1000) }))
      assert(agent:get_session():append(fake_model.assistant({ { type = "text", text = "completed work" } }).message))
      local run = agent:compact()
      assert(run)
      assert.is_true(finish(run).ok)
      assert(captured)
      local request = captured.requests[1]
      assert(request)
      assert.is_true(projections > 0)
      assert.matches("ephemeral profile context", vim.inspect(request.messages), 1, true)
      assert.is_nil(vim.inspect(agent:get_session():messages()):find("ephemeral profile context", 1, true))
      assert.are.equal(
        strategy == "summary" and require("neoagent.compaction.summary").system_prompt or "Profile system",
        request.system_prompt
      )
    end)
  end

  for _, diagnostic in ipairs({ "dialog", "trust" }) do
    it("routes direct Agent " .. diagnostic .. " diagnostics through its Presenter after adoption", function()
      local options = configuration()
      if diagnostic == "trust" then
        local path = directory()
        vim.fn.writefile({ "{" }, path)
        options.workspace_trust = { path = path }
        options.agent_instructions = { global_files = {}, project_filenames = { "AGENTS.md" } }
      end
      local agent = neoagent.new(options)
      owners[#owners + 1] = agent
      local owner = require("neoagent.applet").new({ agents = { agent } })
      owners[#owners + 1] = owner
      local presenter = agent:presenter()
      local local_count, global_count = 0, 0
      local original_local = presenter.notify
      restores[#restores + 1] = function()
        presenter.notify = original_local
      end
      presenter.notify = function()
        local_count = local_count + 1
      end
      local global = require("applet").Presenter
      local original_global = global.notify
      restores[#restores + 1] = function()
        global.notify = original_global
      end
      global.notify = function()
        global_count = global_count + 1
      end
      if diagnostic == "trust" then
        local trust = agent:workspace_trust()
        assert(trust)
        local trusted, err = trust:request(vim.fn.getcwd())
        assert.is_nil(trusted)
        assert.matches("Invalid workspace trust store", assert(err).message)
      else
        local dialogs = agent:dialogs()
        local unsubscribe = dialogs:subscribe(function(snapshot)
          if snapshot.active then
            error("diagnostic recipient", 0)
          end
        end)
        restores[#restores + 1] = unsubscribe
        local run = dialogs:show({
          placement = "float",
          title = "Review",
          body = "Synthetic",
          actions = {
            { id = "ok", label = "OK", key = "o" },
          },
        })
        restores[#restores + 1] = function()
          run:cancel()
        end
        assert(vim.wait(1000, function()
          return local_count + global_count > 0
        end, 5))
      end
      assert.are.equal(1, local_count)
      assert.are.equal(0, global_count)
    end)
  end

  for _, borrowed in ipairs({ false, true }) do
    for _, failure in ipairs({ "provider", "tools" }) do
      it(
        "releases only owned presentation resources after " .. failure .. " failure, borrowed=" .. tostring(borrowed),
        function()
          local module = require("neoagent.presenter")
          local original = module.new
          ---@type Neoagent.Presenter?
          local presenter
          if borrowed then
            presenter = original()
            restores[#restores + 1] = function()
              presenter:destroy()
            end
          else
            restores[#restores + 1] = function()
              module.new = original
            end
            module.new = function(options)
              presenter = original(options)
              return presenter
            end
          end
          if failure == "provider" then
            local resources = require("neoagent.provider_resources")
            local create = resources.new
            restores[#restores + 1] = function()
              resources.new = create
            end
            resources.new = function()
              error("provider rejected", 0)
            end
          end
          local options = configuration({ default_profile = "custom" })
          options.tools = nil
          local ok, err = pcall(neoagent.new, options, {
            presenter = presenter,
            profiles = {
              {
                id = "custom",
                label = "Custom",
                create_tools = function()
                  error("tools rejected", 0)
                end,
              },
            },
          })
          assert.is_false(ok)
          assert.matches(failure .. " rejected", tostring(err))
          assert(presenter)
          assert.are.equal(not borrowed, presenter.destroyed)
        end
      )
    end
  end
end)
