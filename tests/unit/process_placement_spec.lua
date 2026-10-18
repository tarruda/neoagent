local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local fs = require("neoagent.fs")

describe("Agent retained process placement", function()
  local eol = jit.os == "Windows" and "\\x0D\n" or "\n"
  local dispatch = require("neoagent.sandbox.platform")
  local select_platform = dispatch.select
  ---@type Neoagent.Agent?
  local agent
  ---@type Neoagent.AgentApplet?
  local applet
  ---@type Neoagent.ProfileResources?
  local resources
  ---@type Neoagent.ProcessSessions?
  local owner
  ---@type Neoagent.SandboxControls
  local runtime
  ---@type string
  local root
  local checks, starts, compilations = 0, 0, 0
  local available = true
  ---@type Neoagent.SandboxContext<Neoagent.AgentToolEnvironment>[]
  local seen = {}

  before_each(function()
    root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    root = assert(vim.uv.fs_realpath(root))
    checks, starts, compilations = 0, 0, 0
    seen = {}
    available = true
    dispatch.select = function()
      return {
        name = "test",
        paths = require("neoagent.sandbox.path").for_os(jit.os),
        check = function()
          checks = checks + 1
          return { ok = available, platform = "test", message = available and nil or "activation rejected" }
        end,
        compile = function(profile)
          compilations = compilations + 1
          profile.environment.set.NEOAGENT_PLACEMENT_COMPILED = "yes"
          if jit.os == "Windows" then
            -- This fixture uses a host libuv worker instead of the native
            -- sandbox launcher, so declare its required bootstrap values.
            profile.environment.set = vim.tbl_extend("keep", profile.environment.set,
              require("tests.helpers.tool_worker").environment())
          end
          return profile
        end,
        create_worker = function(request)
          starts = starts + 1
          if vim.env.NEOAGENT_COVERAGE == "1" then
            table.insert(request.argv, 2, "--cmd")
            table.insert(request.argv, 3, ("lua dofile(%q)"):format(
              assert(vim.uv.cwd()) .. "/tests/fixtures/coverage_worker.lua"))
          end
          return require("neoagent.rpc.worker_lease").new(request)
        end,
      }
    end
  end)

  after_each(function()
    dispatch.select = select_platform
    if agent then agent:destroy(); agent = nil end
    if owner then
      owner:close("test finished")
      helper.complete(function() return assert(owner):wait_cleanup(10000) end, 12000)
      assert.is_true(helper.complete(function() return assert(owner):wait_release(10000) end, 12000))
      owner = nil
    end
    if applet then applet:destroy(); applet = nil end
    if resources then resources:destroy(); resources = nil end
    vim.fn.delete(root, "rf")
  end)

  ---@param enabled boolean
  ---@param profile_id? string
  ---@param tools? Neoagent.Tool<Neoagent.AgentToolEnvironment>[]
  ---@param decorate? fun(execute: Neoagent.ToolExecutor<Neoagent.AgentToolEnvironment>): Neoagent.ToolExecutor<Neoagent.AgentToolEnvironment>
  local function create(enabled, profile_id, tools, decorate)
    local config = require("neoagent.config").snapshot({
      default_registry = false, providers = {}, tools = tools, workspace_trust = false,
      decorate_tool = decorate,
      persistence = { enabled = false }, recording = { enabled = false }, agent_instructions = false, skills = false,
      sandbox = { enabled = enabled, profile = function(default, ctx)
        seen[#seen + 1] = ctx
        default.environment.set.NEOAGENT_PLACEMENT = "restricted"
        return default
      end },
    })
    ---@type Neoagent.Profile[]
    local profiles
    profiles, _, resources = require("neoagent.profiles").bundled(config, { startup = false })
    local profile = profiles[profile_id == "codex" and 3 or 1]
    assert(profile)
    local resolved = require("neoagent.profiles.selection").resolve({
      profiles = require("neoagent.profiles").index(profiles), snapshot = config, policy = profile.id,
      profile_id = profile.id, runtimes = resources.runtimes, auth = resources.auth, workspace = root,
    })
    applet = require("neoagent.profiles").create_applet({ composition = resolved, label = "placement", workspace = root })
    local session = assert(require("neoagent.profile_sessions").new({
      profile_id = profile_id or "neo",
      workspace = root,
      persistence = { enabled = false },
    }))
    agent = require("neoagent.profiles").create_agent({
      composition = resolved,
      applet = assert(applet),
      resources = resources,
      runtime = { id = "placement", label = "placement", session = session, workspace = root },
    })
    runtime = assert(agent:get_toolset().sandbox)
    owner = agent:get_process_sessions()
  end

  ---@param retained boolean
  ---@return Neoagent.SubprocessSpec
  local function spec(retained)
    local script = "import os; print(os.getenv('NEOAGENT_PLACEMENT', 'host') + '/' + "
      .. "os.getenv('NEOAGENT_PLACEMENT_COMPILED', 'no'), flush=True)"
    if retained then script = script .. "; input(); print(os.getenv('NEOAGENT_PLACEMENT'), flush=True)" end
    return { argv = { jit.os == "Windows" and "python" or "python3", "-u", "-c", script }, cwd = root,
      stdio = { kind = "pipes", stdin = retained and "open" or "closed" }, timeout_ms = 10000 }
  end

  for _, change in ipairs({ "sandbox toggles", "Toolset replacement" }) do
    it("preserves admitted authority across " .. change, function()
      create(true)
      local admission = helper.success(function() return helper.admit(assert(owner), spec(true), 0) end)
      local id = assert(admission.commit())
      assert.are.equal(1, starts, "Agent admission bypassed sandbox composition")
      assert.are.equal(1, checks)
      assert.are.equal(1, compilations)
      local context = assert(seen[1])
      assert.are.equal(vim.fs.normalize(root), vim.fs.normalize(assert(assert(context.context).workspace).root))
      assert.are.equal(vim.fs.normalize(root), vim.fs.normalize(assert(context.process).cwd))
      assert.is_nil(context.call)
      local previous
      if change == "Toolset replacement" then
        previous = assert(assert(agent):set_toolset({ tools = {} }))
      else
        assert(assert(runtime.set_enabled)(runtime, false))
      end
      local result = helper.success(function() return assert(owner):interact(id, 3000, { kind = "write", data = "go\n" }) end)
      local output = admission.result.text .. result.text
      assert(vim.wait(5000, function()
        if result.done then return true end
        result = helper.success(function() return assert(owner):interact(id, 100) end)
        output = output .. result.text
        return result.done
      end, 5))
      assert.matches("restricted/yes" .. eol .. "restricted" .. eol, output, 1, true)
      admission = helper.success(function() return helper.admit(assert(owner), spec(false), 3000) end)
      assert.are.equal("host/no" .. eol, admission.result.text)
      admission.commit()
      assert.are.equal(1, starts)
      if previous then
        assert(assert(agent):set_toolset(previous))
      else
        assert(assert(runtime.set_enabled)(runtime, true))
      end
      admission = helper.success(function() return helper.admit(assert(owner), spec(false), 3000) end)
      assert.are.equal("restricted/yes" .. eol, admission.result.text)
      admission.commit()
      assert.are.equal(2, starts)
      assert.are.equal(1, checks)
    end)
  end

  it("blocks admissions when activation fails and permits host placement only after disabling", function()
    available = false
    create(true)
    local result = helper.complete(function() return helper.admit(assert(owner), spec(false), 3000) end)
    assert.are.equal("sandbox_unavailable", assert(result.error, "unavailable sandbox allowed host execution").kind)
    assert.are.equal(0, starts)
    assert.are.equal(0, assert(owner):status().reserved)
    assert(assert(runtime.set_enabled)(runtime, false))
    local admission = helper.success(function() return helper.admit(assert(owner), spec(false), 3000) end)
    assert.are.equal("host/no" .. eol, admission.result.text)
    admission.commit()
  end)

  it("installs retained Tools on Codex and routes their processes through the shared placement", function()
    create(true, "codex")
    local toolset = assert(agent):get_toolset()
    local names = vim.tbl_map(function(tool) return tool.name end, toolset.tools)
    assert.is_true(vim.tbl_contains(names, "exec_command"))
    assert.is_true(vim.tbl_contains(names, "write_stdin"))
    assert.is_false(vim.tbl_contains(names, "shell"))
    local fake = require("tests.helpers.fake_model")
    local command = jit.os == "Windows" and "echo %NEOAGENT_PLACEMENT%/%NEOAGENT_PLACEMENT_COMPILED%"
      or 'printf "%s/%s" "$NEOAGENT_PLACEMENT" "$NEOAGENT_PLACEMENT_COMPILED"'
    local model = fake.new({
      { result = fake.assistant({ { type = "toolCall", id = "command", name = "exec_command",
        arguments = { cmd = command, shell = jit.os == "Windows" and "cmd.exe" or "sh", login = false, yield_time_ms = 5000 } } }, "toolUse") },
      { result = fake.assistant({ { type = "text", text = "done" } }) },
    })
    local result = helper.wait(require("neoagent.agent_loop").run({
      model = model, messages = {}, tools = toolset.tools, execute_tool = toolset.execute_tool,
      context = { workspace = require("neoagent.workspace").new({ root = root, cwd = root }), processes = owner,
        files = assert(agent):get_session():files(), session_id = assert(agent):get_session():identity() },
      commit_message = function() return true end,
    }), 15000)
    assert.is_true(result.ok, vim.inspect(result))
    local message = assert(result.new_messages)[2]
    assert(message)
    assert.is_false(message.isError, vim.inspect(message))
    assert.matches("restricted/yes", require("neoagent.util").text_content(message.content), 1, true)
    assert.are.equal(1, starts)
    assert.are.equal(1, compilations)
  end)

  it("preserves an explicitly configured Tool list on Codex", function()
    create(false, "codex", {})
    assert.are.same({}, assert(agent):get_toolset().tools)
  end)

  ---@param selected Neoagent.AgentToolset<Neoagent.AgentToolEnvironment>
  ---@param arguments Neoagent.JsonObject
  ---@param placement? fun(context: Neoagent.AgentToolEnvironment, spec: Neoagent.SubprocessSpec): Neoagent.ProcessControllerFactory
  ---@return Neoagent.ToolResultMessage
  local function headless(selected, arguments, placement)
    local fake = require("tests.helpers.fake_model")
    local model = fake.new({
      { result = fake.assistant({ { type = "toolCall", id = "command", name = "exec_command", arguments = arguments } }, "toolUse") },
      { result = fake.assistant({ { type = "text", text = "done" } }) },
    })
    agent = require("neoagent").new({
      default_registry = false, workspace_trust = false,
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      _apis = { ["fake-api"] = function() return model end },
      persistence = { enabled = false }, recording = { enabled = false }, agent_instructions = false, skills = false,
      tools = selected.tools,
    }, { workspace = root })
    selected.process_placement = placement or selected.process_placement
    assert(agent:set_toolset(selected))
    owner = agent:get_process_sessions()
    local finished = helper.wait(assert(agent:send("Run the command")), 15000)
    assert.is_true(finished.ok, vim.inspect(finished))
    local message = agent:get_session():messages()[3]
    local normalized = require("neoagent.semantic_message").normalize(message)
    if not normalized or normalized.role ~= "toolResult" then
      error("Command did not publish a Tool result")
    end
    return normalized
  end

  ---@param selected Neoagent.AgentToolset<Neoagent.AgentToolEnvironment>
  ---@param name string
  ---@param arguments Neoagent.JsonObject
  ---@return Neoagent.ToolResultMessage
  local function invoke(selected, name, arguments)
    local fake = require("tests.helpers.fake_model")
    local session = agent and agent:get_session() or assert(require("neoagent.session").new())
    local observed = helper.wait(
      require("neoagent.agent_loop").run({
        model = fake.new({
          {
            result = fake.assistant(
              { { type = "toolCall", id = "command", name = name, arguments = arguments } },
              "toolUse"
            ),
          },
          { result = fake.assistant({ { type = "text", text = "done" } }) },
        }),
        messages = {},
        tools = selected.tools,
        execute_tool = selected.execute_tool,
        context = { workspace = require("neoagent.workspace").new({ root = root, cwd = root }),
          processes = owner, files = session:files(), session_id = session:identity() },
        commit_message = function()
          return true
        end,
      }),
      15000
    )
    assert.is_true(observed.ok, vim.inspect(observed))
    local message = assert(observed.new_messages)[2]
    assert(message)
    assert(message.role == "toolResult")
    return message
  end

  it("preserves retained command admission through an executor decorator", function()
    local calls = 0
    create(true, "codex", nil, function(execute)
      ---@async
      return function(tool, arguments, ctx)
        calls = calls + 1
        return execute(tool, arguments, ctx)
      end
    end)
    local command = jit.os == "Windows" and "echo %NEOAGENT_PLACEMENT%/%NEOAGENT_PLACEMENT_COMPILED%"
      or 'printf "%s/%s" "$NEOAGENT_PLACEMENT" "$NEOAGENT_PLACEMENT_COMPILED"'
    local result = invoke(assert(agent):get_toolset(), "exec_command", {
      cmd = command, shell = jit.os == "Windows" and "cmd.exe" or "sh", login = false, yield_time_ms = 5000,
    })
    assert.is_false(result.isError)
    assert.matches("restricted/yes", require("neoagent.util").text_content(result.content), 1, true)
    assert.are.equal(1, calls)
    assert.are.equal(1, starts)
    assert.are.equal(1, compilations)
  end)

  local function gate_command(output)
    if jit.os ~= "Windows" then
      return "while [ ! -f exit-gate ]; do sleep 0.01; done; printf '" .. output .. "'; exit 0"
    end
    -- Qualify the built-ins so this lifecycle gate does not scan installed
    -- modules through the runner's command-discovery cache.
    return "while (-not (Microsoft.PowerShell.Management\\Test-Path -LiteralPath exit-gate)) { "
      .. "Microsoft.PowerShell.Utility\\Start-Sleep -Milliseconds 10 }; "
      .. "[Console]::Out.Write('" .. output .. "'); exit 0"
  end

  for _, enabled in ipairs({ true, false }) do
    it("binds headless process admission to a composition with available=" .. tostring(enabled), function()
      available = enabled
      local selected = require("neoagent.sandbox.composition").compose({ tools = require("neoagent.tools").all() }, {
        enabled = true, profile = function(profile)
          profile.environment.set.NEOAGENT_PLACEMENT = "restricted"
          return profile
        end,
      })
      local command = jit.os == "Windows" and "echo %NEOAGENT_PLACEMENT%/%NEOAGENT_PLACEMENT_COMPILED%"
        or 'printf "%s/%s" "$NEOAGENT_PLACEMENT" "$NEOAGENT_PLACEMENT_COMPILED"'
      local message = headless(selected, {
        cmd = command, shell = jit.os == "Windows" and "cmd.exe" or "sh", login = false, yield_time_ms = 5000,
      })
      assert.are.equal(not enabled, message.isError, vim.inspect(message))
      assert.are.equal(enabled and 1 or 0, starts)
      if enabled then
        assert.matches("restricted/yes", require("neoagent.util").text_content(message.content), 1, true)
      else
        assert.are.equal(0, assert(owner):status().reserved)
      end
    end)
  end

  for _, decision in ipairs({ "approve", "deny" }) do
    it("selects process authority through the Tool approval: " .. decision, function()
      local dialogs = require("neoagent.dialog").new()
      ---@type string?
      local prompted
      local unsubscribe = dialogs:subscribe(function(snapshot)
        if snapshot.active then
          prompted = snapshot.active.body
          assert(dialogs:choose(snapshot.active.id, decision))
        end
      end)
      local selected = require("neoagent.sandbox.composition").compose({ tools = require("neoagent.tools").codex() },
        { enabled = true }, { dialogs = dialogs })
      local checked, err = pcall(function()
        local executable = vim.fn.exepath(jit.os == "Windows" and "cmd.exe" or "sh")
        local message = headless(selected, {
          cmd = "echo approved-host", workdir = root, shell = executable,
          login = false, yield_time_ms = 5000,
          sandbox_permissions = "require_escalated", justification = "Synthetic approval regression",
        }, function() error("Independent manager placement must not override Tool authority") end)
        assert.matches("retains this authority until it exits", assert(prompted), 1, true)
        assert.matches("Shell argv:", assert(prompted), 1, true)
        local normalized = vim.fs.normalize(executable, { expand_env = false })
        assert.matches(vim.json.encode(normalized):sub(2, -2), assert(prompted), 1, true)
        assert.matches("Working directory:", assert(prompted), 1, true)
        assert.are.equal(0, starts, "approved host command used the restricted worker")
        assert.are.equal(decision == "deny", message.isError, vim.inspect(message))
        local metadata = assert(assert(message.execution).sandbox)
        if decision == "approve" then
          assert.is_true(metadata.elevated)
          assert.matches("approved-host", require("neoagent.util").text_content(message.content), 1, true)
        else
          assert.is_true(metadata.denied_by_user)
          assert.are.equal(0, assert(owner):status().reserved)
        end
      end)
      unsubscribe()
      if not checked then error(err, 0) end
    end)
  end

  for _, changed in ipairs({ "shell", "shellcmdflag", "workdir" }) do
    it("executes the approved command after editor " .. changed .. " changes", function()
      local old_shell, old_flags, old_directory = vim.o.shell, vim.o.shellcmdflag, vim.env.NEOAGENT_TEST_APPROVAL_CWD
      local dialogs = require("neoagent.dialog").new()
      vim.o.shell = vim.fn.exepath(jit.os == "Windows" and "cmd.exe" or "sh")
      vim.o.shellcmdflag = jit.os == "Windows" and "/d /s /c" or "-c"
      assert(fs.mkdirp(root .. "/approved-cwd"))
      assert(fs.mkdirp(root .. "/changed-cwd"))
      vim.env.NEOAGENT_TEST_APPROVAL_CWD = root .. "/approved-cwd"
      ---@type string?
      local prompted
      local unsubscribe = dialogs:subscribe(function(snapshot)
        if snapshot.active then
          prompted = snapshot.active.body
          if changed == "shell" then
            vim.o.shell = root .. "/missing-shell"
          elseif changed == "shellcmdflag" then
            vim.o.shellcmdflag = ""
          else
            vim.env.NEOAGENT_TEST_APPROVAL_CWD = root .. "/changed-cwd"
          end
          assert(dialogs:choose(snapshot.active.id, "approve"))
        end
      end)
      local checked, err = pcall(function()
        local selected = require("neoagent.sandbox.composition").compose(
          { tools = require("neoagent.tools").codex() }, { enabled = true }, { dialogs = dialogs })
        local message = headless(selected, {
          cmd = changed == "workdir" and (jit.os == "Windows" and "cd" or "pwd") or "echo APPROVED",
          workdir = "$NEOAGENT_TEST_APPROVAL_CWD", login = false, yield_time_ms = 5000,
          sandbox_permissions = "require_escalated", justification = "Synthetic immutable approval regression",
        })
        assert.matches("approved-cwd", assert(prompted), 1, true)
        assert.is_false(message.isError, vim.inspect(message))
        assert.matches(changed == "workdir" and "approved-cwd" or "APPROVED",
          require("neoagent.util").text_content(message.content), 1, true)
      end)
      vim.o.shell, vim.o.shellcmdflag, vim.env.NEOAGENT_TEST_APPROVAL_CWD = old_shell, old_flags, old_directory
      unsubscribe()
      if not checked then error(err, 0) end
    end)
  end

  it("reports restricted failures through the same escalation contract as synchronous Tools", function()
    local selected = require("neoagent.sandbox.composition").compose(
      { tools = require("neoagent.tools").codex() },
      { enabled = true }
    )
    local message = headless(selected, {
      cmd = jit.os == "Windows" and "[Console]::Error.WriteLine('Permission denied'); exit 1"
        or "printf 'Permission denied' >&2; exit 1",
      shell = jit.os == "Windows" and "powershell.exe" or "sh",
      login = false,
      yield_time_ms = 5000,
    })
    assert(vim.wait(10000, function()
      local id = assert(message.details).session_id
      if id then
        message = invoke(selected, "write_stdin", { session_id = id, yield_time_ms = 100 })
      end
      return assert(message.details).session_id == nil
    end, 5), vim.inspect(message))
    assert.is_true(message.isError, vim.inspect(message))
    assert.are.equal(1, assert(message.details).exit_code, vim.inspect(message))
    assert.matches("sandbox_permissions", require("neoagent.util").text_content(message.content), 1, true)
    assert.is_true(assert(assert(message.execution).sandbox).denied)
  end)

  it("keeps cleanup notices out of operation-denial classification", function()
    local selected = require("neoagent.sandbox.composition").compose({
      tools = require("neoagent.tools").codex(),
      execute_tool = function(tool, arguments, ctx)
        local value = tool.execute(arguments, ctx)
        value.content[#value.content + 1] = { type = "text", text = "Sandbox cleanup failed: Permission denied" }
        return value
      end,
    }, { enabled = true })
    local message = headless(selected, {
      cmd = "exit 7", shell = jit.os == "Windows" and "cmd.exe" or "sh", login = false, yield_time_ms = 5000,
    })
    assert.is_true(message.isError)
    assert.is_nil(assert(assert(message.execution).sandbox).denied)
    assert.is_nil((require("neoagent.util").text_content(message.content):find("require_escalation", 1, true)))
  end)

  it("retains denial evidence before the process output buffer evicts it", function()
    local selected = require("neoagent.sandbox.composition").compose(
      { tools = require("neoagent.tools").codex() }, { enabled = true }
    )
    owner = require("neoagent.process_sessions").new({ output_bytes = 64 })
    local message = invoke(selected, "exec_command", {
      cmd = jit.os == "Windows" and "[Console]::Out.Write('Permission denied' + ('x' * 80000)); exit 1"
        or "printf 'Permission denied'; printf '%80000s' x; exit 1",
      shell = jit.os == "Windows" and "powershell.exe" or "sh",
      login = false, yield_time_ms = 5000,
    })
    assert.is_true(message.isError, vim.inspect(message))
    assert.are.equal(1, assert(message.details).exit_code)
    assert.is_true(assert(message.details).truncated)
    local output = assert(message.details).output
    assert(type(output) == "string")
    assert.is_nil((output:find("Permission denied", 1, true)))
    assert.is_true(assert(assert(message.execution).sandbox).denied,
      "output eviction erased evidence used for escalation")
  end)

  it("preserves a confirmed outcome when an executor loses a command result", function()
    local selected = require("neoagent.sandbox.composition").compose({
      tools = require("neoagent.tools").codex(),
      execute_tool = function(tool, arguments, ctx)
        tool.execute(arguments, ctx)
        error(require("neoagent.util").error("protocol", "synthetic result loss"), 0)
      end,
    }, { enabled = true })
    local message = headless(selected, {
      cmd = "exit 0", shell = jit.os == "Windows" and "cmd.exe" or "sh", login = false, yield_time_ms = 5000,
    })
    assert.is_true(message.isError)
    local metadata = assert(assert(message.execution).sandbox)
    assert.is_true(metadata.restricted)
    assert.is_false(assert(message.details).outcome_uncertain)
    assert.are.equal(0, assert(message.details).exit_code)
    assert.matches("do not retry it automatically", require("neoagent.util").text_content(message.content), 1, true)
  end)

  for _, restricted in ipairs({ true, false }) do
    it("retains a later confirmed outcome when result delivery fails with restricted=" .. tostring(restricted), function()
      local processes = require("neoagent.process_sessions").new()
      owner = processes
      local selected = require("neoagent.sandbox.composition").compose({
        tools = require("neoagent.tools").codex(),
        execute_tool = function(tool, arguments, ctx)
          local value = tool.execute(arguments, ctx)
          assert.is_not_nil(assert(value.details).session_id)
          assert(fs.write_all(root .. "/exit-gate", "exit"))
          local settled, failure = pcall(processes.wait_cleanup, processes, 15000)
          assert.is_true(settled, vim.inspect(failure))
          error(require("neoagent.util").error("protocol", "synthetic delayed result loss"), 0)
        end,
      }, { enabled = restricted })
      local message = invoke(selected, "exec_command", {
        cmd = gate_command(""),
        shell = jit.os == "Windows" and "powershell.exe" or "sh", login = false, yield_time_ms = 0,
      })
      assert.is_true(message.isError)
      assert.is_false(assert(message.details).outcome_uncertain, vim.inspect(message))
      assert.are.equal(0, assert(message.details).exit_code)
    end)

    it("reports effects after result loss independently of placement: " .. tostring(restricted), function()
      local selected = require("neoagent.sandbox.composition").compose({
        tools = require("neoagent.tools").codex(),
        execute_tool = function(tool, arguments, ctx)
          tool.execute(arguments, ctx)
          error(require("neoagent.util").error("process_supervision", "synthetic result loss"), 0)
        end,
      }, { enabled = restricted })
      local message = headless(selected, {
        cmd = jit.os == "Windows" and "Start-Sleep -Seconds 30" or "exec sleep 30",
        shell = jit.os == "Windows" and "powershell.exe" or "sh", login = false, yield_time_ms = 0,
      })
      assert.is_true(message.isError)
      assert.is_true(assert(message.details).outcome_uncertain)
      assert.matches("Do not retry automatically", require("neoagent.util").text_content(message.content), 1, true)
    end)
  end

  it("does not infer execution from an error kind before admission", function()
    local selected = require("neoagent.sandbox.composition").compose({
      tools = require("neoagent.tools").codex(),
      execute_tool = function()
        error(require("neoagent.util").error("protocol", "failure before command admission"), 0)
      end,
    }, { enabled = true })
    local message = headless(selected, {
      cmd = "exit 0", shell = jit.os == "Windows" and "cmd.exe" or "sh", login = false, yield_time_ms = 5000,
    })
    assert.is_true(message.isError)
    assert.is_nil(message.details)
    assert.are.equal(0, starts)
  end)

  for _, restricted in ipairs({ true, false }) do
    for _, completed in ipairs({ false, true }) do
      it("preserves target facts after rejected input with restricted=" .. tostring(restricted)
        .. " completed=" .. tostring(completed), function()
        local selected = require("neoagent.sandbox.composition").compose(
          { tools = require("neoagent.tools").codex() }, { enabled = restricted })
        owner = require("neoagent.process_sessions").new()
        local initial = invoke(selected, "exec_command", {
          cmd = gate_command("FINAL"),
          shell = jit.os == "Windows" and "powershell.exe" or "sh", login = false, yield_time_ms = 0,
        })
        local id = assert(assert(initial.details).session_id)
        if completed then
          assert(fs.write_all(root .. "/exit-gate", "exit"))
          local cleanup = helper.complete(function() return owner:wait_cleanup(15000) end, 20000)
          assert.is_true(cleanup, vim.inspect(cleanup))
        end
        local message = invoke(selected, "write_stdin", { session_id = id, chars = "rejected\n", yield_time_ms = 0 })
        assert.is_true(message.isError)
        local observed = assert(message.details, "control failure discarded the known target state")
        assert.is_false(observed.outcome_uncertain, vim.inspect(message))
        assert.are.equal(completed, observed.done)
        assert.are.equal(not completed and id or nil, observed.session_id)
        assert.are.equal(completed and 0 or nil, observed.exit_code)
        assert.is_not_nil(observed.request_error)
        assert.is_nil(observed.error, "control rejection became a target failure")
        local next_poll = invoke(selected, "write_stdin", { session_id = id, yield_time_ms = 0 })
        assert.is_false(next_poll.isError, vim.inspect(next_poll))
        assert.are.equal(completed and "FINAL" or "", assert(next_poll.details).output)
      end)
    end
  end

  for _, restricted in ipairs({ true, false }) do
    it("reports the admitted authority when polling after a sandbox toggle: " .. tostring(restricted), function()
      local selected, _, _, switch = require("neoagent.sandbox.composition").switchable(
        { tools = require("neoagent.tools").codex() },
        { enabled = restricted }
      )
      owner = require("neoagent.process_sessions").new({ output_bytes = 64 })
      local message = invoke(selected, "exec_command", {
        cmd = jit.os == "Windows" and [[python -u -c "print('X' * 1000); input(); print('Permission denied'); exit(1)"]]
          or [[printf '%1000s' x; read value; printf 'Permission denied'; exit 1]],
        shell = jit.os == "Windows" and "powershell.exe" or "sh",
        login = false,
        tty = true,
        yield_time_ms = 0,
      })
      local id = assert(assert(message.details).session_id)
      assert(switch:set_enabled(not restricted))
      message = invoke(selected,
        "write_stdin",
        { session_id = id, chars = jit.os == "Windows" and "go\r" or "go\n", yield_time_ms = 5000 }
      )
      assert(vim.wait(10000, function()
        if assert(message.details).session_id then
          message = invoke(selected, "write_stdin", { session_id = id, yield_time_ms = 100 })
        end
        return assert(message.details).session_id == nil
      end, 5))
      assert.is_true(message.isError)
      local metadata = assert(assert(message.execution).sandbox)
      assert.are.equal(restricted, metadata.restricted)
      assert.are.equal(restricted, metadata.denied == true)
    end)
  end

  for _, restricted in ipairs({ true, false }) do
    it("normalizes editor variables after selecting process authority: " .. tostring(restricted), function()
      local old_nvim, old_listen = vim.env.NVIM, vim.env.NVIM_LISTEN_ADDRESS
      vim.env.NVIM, vim.env.NVIM_LISTEN_ADDRESS = "stale-editor", "stale-legacy"
      local selected = require("neoagent.sandbox.composition").compose({ tools = require("neoagent.tools").codex() }, {
        enabled = restricted,
        profile = function(profile)
          profile.environment.set.NVIM, profile.environment.set.NVIM_LISTEN_ADDRESS = "profile-editor", "profile-legacy"
          return profile
        end,
      })
      local checked, err = pcall(function()
        local message = headless(selected, {
          cmd = jit.os == "Windows" and "[Console]::Write($env:NVIM + '|' + $env:NVIM_LISTEN_ADDRESS)"
            or 'printf "%s|%s" "$NVIM" "$NVIM_LISTEN_ADDRESS"',
          shell = jit.os == "Windows" and "powershell.exe" or "sh", login = false, yield_time_ms = 5000,
        })
        assert.is_false(message.isError, vim.inspect(message))
        assert.are.equal((restricted and "" or vim.v.servername) .. "|", assert(message.details).output)
      end)
      vim.env.NVIM, vim.env.NVIM_LISTEN_ADDRESS = old_nvim, old_listen
      if not checked then error(err, 0) end
    end)
  end
end)
