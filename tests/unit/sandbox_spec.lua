local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")
local common = require("neoagent.tools.common")
local fake_model = require("tests.helpers.fake_model")

---@class Neoagent.TestSandboxEnvironment
---@field workspace Neoagent.Workspace
---@field files Neoagent.Files
---@field agent string
---@field session_id? string

---@class Neoagent.TestSandboxContext: Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
---@field context Neoagent.TestSandboxEnvironment

---@type Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>[]
local context_runs = {}

local function temporary_directory()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return assert(vim.uv.fs_realpath(path))
end

---@param root string
local function workspace(root)
  return require("neoagent.workspace").new({ root = root, cwd = root })
end

---@param root string
---@return Neoagent.TestSandboxContext
local function context(root)
  -- Keep the execution owner live until this scenario's teardown.
  ---@async
  ---@return Neoagent.AgentLoopResult
  local function lifetime()
    return async.await(
      ---@param _ Neoagent.AwaitCallbacks<Neoagent.AgentLoopResult>
      function(_) end)
  end
  local run = async.run(lifetime)
  context_runs[#context_runs + 1] = run
  return {
    context = { workspace = workspace(root), agent = "Neo", files = require("neoagent.files.memory").new() },
    model = fake_model.new(), run = run,
    execute_tool = function(tool, arguments, ctx) return tool.execute(arguments, ctx) end,
    call = { type = "toolCall", id = "sandbox-probe", name = "probe", arguments = {} },
    on_update = function() end,
  }
end

---@param root string
---@param show fun(request: Neoagent.DialogRequest): unknown
---@param choose_pending? fun(self: Neoagent.DialogCapability, action: string, reason?: string): integer?, Neoagent.Error?
---@return Neoagent.TestSandboxContext
local function dialog_context(root, show, choose_pending)
  local ctx = context(root)
  -- Exercise both completed decisions and malformed presenter responses.
  rawset(ctx, "dialog", {
    show = function(_, request) return show(request) end,
    choose_pending = choose_pending or function() return 0 end,
  })
  return ctx
end

---@param root string
---@param entries? Neoagent.SandboxFilesystemEntry[]
---@return Neoagent.SandboxProfile
local function profile(root, entries)
  return {
    id = "test",
    filesystem = {
      default = "read",
      entries = entries or { { path = root, access = "write" } },
    },
    network = "restricted",
    environment = {
      clear = true,
      inherit = { "PATH" },
      set = { TEST_SANDBOX = "yes" },
    },
  }
end

---@generic T
---@param fn async fun(): T
---@return Neoagent.RunResult<T>
local function complete(fn)
  local run = async.run(fn)
  assert(vim.wait(1000, function() return run:is_done() end, 5))
  local value = assert(run:result())
  return value
end

describe("neoagent sandbox composition", function()
  local paths = {}

  after_each(function()
    for _, run in ipairs(context_runs) do run:cancel() end
    context_runs = {}
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
    require("neoagent.config")._reset()
  end)

  local function temp()
    local path = temporary_directory()
    paths[#paths + 1] = path
    return path
  end

  it("validates sandbox settings while direct Agents stay explicit", function()
    local configured = require("neoagent.config").resolve({
      sandbox = { enabled = false },
    })
    assert.is_false(configured.sandbox.enabled)
    assert.has_error(function()
      require("neoagent.config").resolve({
        sandbox = { enabled = false, future_policy = true },
      })
    end, "unsupported sandbox setting: future_policy")
    assert.has_error(function()
      require("neoagent.config").resolve({ sandbox = false } --[[@as Neoagent.ConfigInput]])
    end, "sandbox must be a table")
    assert.has_error(function()
      require("neoagent.config").resolve({
        sandbox = { enabled = "yes" },
      } --[[@as Neoagent.ConfigInput]])
    end, "sandbox.enabled must be boolean")

    local agent = require("neoagent.agent").new({
      name = "Direct",
      default_registry = false,
      providers = {},
      sandbox = { enabled = true },
      tools = {},
    })
    assert.is_true(agent:config().sandbox.enabled)
    agent:destroy()
  end)

  it("validates profiles and resolves path precedence and canonical aliases", function()
    local root = temp()
    local protected = vim.fs.joinpath(root, "protected")
    local missing_read = vim.fs.joinpath(root, "missing-read")
    local missing_deny = vim.fs.joinpath(root, "missing-deny")
    assert.are.equal(1, vim.fn.mkdir(protected, "p"))
    local source = profile(root, {
      { path = root, access = "write" },
      { path = protected, access = "read" },
      { path = protected, access = "deny" },
      { path = missing_read, access = "read" },
      { path = missing_deny, access = "deny" },
    })
    local normalized, fingerprint =
      require("neoagent.sandbox.profile").validate(source)
    assert.is_string(fingerprint)
    assert.are.equal(4, #normalized.filesystem.entries)
    assert.are.equal("write", assert(normalized.filesystem.entries[1]).access)
    local retained_missing_read, retained_missing_deny = false, false
    for _, entry in ipairs(normalized.filesystem.entries) do
      if entry.path == missing_read and entry.access == "read" then
        retained_missing_read = true
      elseif entry.path == missing_deny and entry.access == "deny" then
        retained_missing_deny = true
      end
    end
    assert.is_true(retained_missing_read)
    assert.is_true(retained_missing_deny)

    local policy = require("neoagent.sandbox.policy")
    local lexical, canonical =
      policy.resolve_path(context(root), "ordinary.txt")
    assert.are.equal(vim.fs.joinpath(root, "ordinary.txt"), lexical)
    assert.is_true(policy.allows(normalized, lexical, canonical, "write"))
    lexical, canonical =
      policy.resolve_path(context(root), "protected/file.txt")
    assert.is_false(policy.allows(
      normalized, lexical, canonical, "read"))

    local outside = temp()
    local link = vim.fs.joinpath(root, "link")
    assert(vim.uv.fs_symlink(outside, link))
    lexical, canonical =
      policy.resolve_path(context(root), "link/new.txt")
    assert.are.equal(vim.fs.joinpath(outside, "new.txt"), canonical)
    assert.is_false(policy.allows(
      normalized, lexical, canonical, "write"))

    local invalid = profile(root, {
      { path = vim.fs.joinpath(root, "absent"), access = "write" },
    })
    assert.has_error(function()
      require("neoagent.sandbox.profile").validate(invalid)
    end)

    local invalid_profiles = {
      function(value) value.filesystem = { "not", "an", "object" } end,
      function(value) value.id = "" end,
      function(value) value.network = "sometimes" end,
      function(value) value.temporary = "private" end,
      function(value) value.filesystem.default = "write" end,
      function(value) value.filesystem.entries = {} value.filesystem.entries.bad = true end,
      function(value) value.filesystem.entries[1].access = "execute" end,
      function(value) value.filesystem.entries[1].path = "relative" end,
      function(value) value.filesystem.entries[1].path = "bad\0path" end,
      function(value) value.environment.clear = "yes" end,
      function(value) value.environment.inherit = {} value.environment.inherit.bad = true end,
      function(value) value.environment.inherit = { "NOT-VALID" } end,
      function(value) value.environment.set = { ["NOT-VALID"] = "x" } end,
      function(value) value.environment.set = { VALID = "x\0y" } end,
      function(value) value.extra = true end,
    }
    for _, mutate in ipairs(invalid_profiles) do
      invalid = profile(root)
      mutate(invalid)
      assert.has_error(function()
        require("neoagent.sandbox.profile").validate(invalid)
      end)
    end

    invalid = profile(root)
    assert(invalid.filesystem.entries[1]).path = link
    local ok, err = pcall(function()
      require("neoagent.sandbox.profile").validate(invalid)
    end)
    assert.is_false(ok)
    assert.matches("must use a canonical path", util.normalize_error(err).message)
    assert.has_error(function()
      require("neoagent.sandbox.policy").resolve_path({}, "relative")
    end)
    assert.has_error(function()
      require("neoagent.sandbox.policy").resolve_path(context(root), "")
    end)
    local original_realpath = vim.uv.fs_realpath
    vim.uv.fs_realpath = function() return nil end
    local resolved, fallback_lexical, fallback_canonical =
      pcall(policy.resolve_path, {}, "/missing/child")
    vim.uv.fs_realpath = original_realpath
    assert.is_true(resolved)
    assert.are.equal("/missing/child", fallback_lexical)
    assert.are.equal("/missing/child", fallback_canonical)
    invalid = profile(root)
    assert(invalid.filesystem.entries[1]).path = "/"
    assert.has_error(function()
      require("neoagent.sandbox.profile").validate(invalid)
    end)

    local alpha = vim.fs.joinpath(root, "alpha")
    local bravo = vim.fs.joinpath(root, "bravo")
    assert.are.equal(1, vim.fn.mkdir(alpha))
    assert.are.equal(1, vim.fn.mkdir(bravo))
    normalized = require("neoagent.sandbox.profile").validate(
      profile(root, {
        { path = bravo, access = "read" },
        { path = alpha, access = "read" },
      }))
    assert.are.equal(alpha, assert(normalized.filesystem.entries[1]).path)
    assert.are.equal(bravo, assert(normalized.filesystem.entries[2]).path)

    local granted = policy.access({
      id = "test", network = "restricted", environment = { clear = true, inherit = {}, set = {} },
      filesystem = {
        default = "read",
        entries = {
          { path = protected, access = "read" },
          { path = protected, access = "deny" },
        },
      },
    }, protected, protected)
    assert.are.equal("deny", granted)
  end)

  it("applies Windows path and environment semantics without changing profiles", function()
    local path_module = require("neoagent.sandbox.path")
    local existing = {
      ["c:\\repo"] = true,
      ["c:\\repo\\.git"] = true,
      ["c:\\temp"] = true,
      ["c:\\state\\shared-tmp"] = true,
    }
    local paths = path_module.windows({
      realpath = function(path)
        local key = vim.fn.tolower((path:gsub("/", "\\")))
        return existing[key] and path or nil
      end,
      stat = function(path)
        local key = vim.fn.tolower((path:gsub("/", "\\")))
        if not existing[key] then return end
        local value = assert(vim.uv.fs_stat("."))
        value.type = "directory"
        return value
      end,
    })

    assert.are.equal("C:\\Repo\\file.txt",
      paths.normalize("c:/Repo/child/../file.txt"))
    assert.are.equal("\\\\server\\share\\folder",
      paths.normalize("//server/share/folder/"))
    assert.are.equal("\\\\server\\share\\folder",
      paths.normalize("\\\\?\\UNC\\server\\share\\folder"))
    assert.are.equal("C:\\Repo\\file",
      paths.normalize("\\\\?\\C:\\Repo\\file"))
    assert.is_true(paths.contains("C:\\Repo", "c:/repo/File.txt"))
    assert.is_true(paths.contains("C:\\", "c:/repo/File.txt"))
    assert.is_true(paths.contains("C:\\Ärea", "c:\\ärea\\File.txt"))
    assert.is_false(paths.contains("C:\\Repo", "C:\\Repository"))
    assert.are.equal("D:\\other",
      paths.join("C:\\Repo", "D:\\other"))
    assert.are.equal("c:\\repo", paths.key("C:/Repo"))
    assert.are.equal(paths.key("C:\\Ärea"), paths.key("c:\\ärea"))
    assert.are.equal(paths.environment_key("Ärea"),
      paths.environment_key("äREA"))
    assert.is_false(paths.is_absolute(nil))
    assert.is_false(paths.is_absolute(""))
    assert.are.equal("C:\\", paths.dirname("C:\\"))
    assert.are.equal("C:\\", paths.dirname("C:\\child"))
    assert.has_error(function() paths.normalize("") end)
    assert.has_error(function() paths.normalize("C:relative") end)
    assert.has_error(function() paths.normalize("\\\\server") end)
    assert.has_error(function() paths.normalize("\\\\.\\PhysicalDrive0") end)
    assert.has_error(function() paths.normalize("C:\\Repo\\file:stream") end)
    assert.has_error(function() paths.normalize("C:\\Repo\\CON") end)
    assert.has_error(function() paths.validate_component("NUL.txt") end)
    assert.has_error(function() paths.validate_component("COM¹.txt") end)
    assert.has_error(function() paths.validate_component("trailing.") end)
    assert.are.equal("spill-", paths.validate_component("spill-"))
    assert.has_error(function()
      path_module.posix.validate_component("two/parts")
    end)
    assert.are.equal("windows", path_module.for_os("Windows").name)
    assert.are.equal(path_module.posix, path_module.for_os("Linux"))

    existing["c:\\repo\\existing"] = true
    assert.are.equal("C:\\Repo\\existing\\missing\\child",
      paths.canonical_candidate(
        "C:\\Repo\\existing\\missing\\child"))

    local source = {
      id = "windows-test",
      filesystem = {
        default = "read",
        entries = {
          { path = "C:\\Repo", access = "write" },
          { path = "c:/repo/.git", access = "read" },
        },
      },
      network = "restricted",
      environment = {
        clear = true,
        inherit = { "Path", "PATH", "TEMP" },
        set = { path = "C:\\bin", Temp = "C:\\Temp" },
      },
    }
    local normalized = require("neoagent.sandbox.profile").validate(
      source, { paths = paths })
    assert.are.same({ "Path", "TEMP" }, normalized.environment.inherit)
    assert.are.same({ Path = "C:\\bin", TEMP = "C:\\Temp" },
      normalized.environment.set)
    assert.are.equal("write", assert(normalized.filesystem.entries[1]).access)
    assert.are.equal("read", assert(normalized.filesystem.entries[2]).access)

    local fake_workspace = {
      resolve = function(_, value)
        return paths.join("C:\\Repo", value)
      end,
    }
    local lexical, canonical =
      require("neoagent.sandbox.policy").resolve_path({
        context = { workspace = fake_workspace },
      }, "src/../README.md", paths)
    assert.are.equal("C:\\Repo\\README.md", lexical)
    assert.are.equal(lexical, canonical)
    assert.is_true(require("neoagent.sandbox.policy").allows(
      normalized, "c:\\repo\\new.txt", "C:\\Repo\\new.txt",
      "write", paths))

    local original_tmpdir = vim.uv.os_tmpdir
    vim.uv.os_tmpdir = function() return "C:\\Temp" end
    local defaults = require("neoagent.sandbox.composition").default_profile({
      context = { workspace = { root = "C:\\Repo" } },
    }, paths)
    vim.uv.os_tmpdir = original_tmpdir
    assert.are.same({
      "PATH",
      "SystemRoot",
      "WINDIR",
      "COMSPEC",
      "PATHEXT",
    }, defaults.environment.inherit)
    assert.are.equal("C:\\Temp", defaults.environment.set.TEMP)

    local dedicated =
      require("neoagent.sandbox.composition").default_profile({
        context = { workspace = { root = "C:\\Repo" } },
      }, paths, "C:\\state\\shared-tmp")
    assert.are.equal("C:\\state\\shared-tmp",
      dedicated.environment.set.TEMP)
    assert.are.same({
      { path = "C:\\Repo", access = "write" },
      { path = "C:\\state\\shared-tmp", access = "write" },
      { path = "C:\\Repo\\.git", access = "read" },
    }, dedicated.filesystem.entries)
  end)

  it("dispatches platforms explicitly and reports unsupported systems", function()
    ---@param name string
    ---@return Neoagent.SandboxPlatform
    local function platform(name)
      return {
        name = name,
        check = function() return { ok = true, platform = name } end,
        exec = function() error("dispatch must not execute") end,
        fs = function() error("dispatch must not access files") end,
      }
    end
    local linux, macos, windows = platform("linux"), platform("macos"), platform("windows")
    local dispatch = require("neoagent.sandbox.platform")
    assert.are.equal(linux,
      dispatch.select("Linux",
        { linux = linux, macos = macos, windows = windows }))
    assert.are.equal(macos,
      dispatch.select("OSX",
        { linux = linux, macos = macos, windows = windows }))
    assert.are.equal(windows,
      dispatch.select("Windows",
        { linux = linux, macos = macos, windows = windows }))
    local selected, status =
      dispatch.select("Plan9",
        { linux = linux, macos = macos, windows = windows })
    assert.is_nil(selected)
    assert.is_false(assert(status).ok)
    assert.matches("unsupported platform",
      dispatch.status_error(status).message)

    local dispatched, dispatch_err = pcall(
      require("neoagent.sandbox").sandbox_exec,
      { "true" },
      {
        os = "Plan9",
        profile = {
          id = "unused",
          filesystem = { default = "read", entries = {} },
          network = "restricted",
          environment = { clear = true, inherit = {}, set = {} },
        },
        platforms = { linux = linux, macos = macos, windows = windows },
      }
    )
    assert.is_false(dispatched)
    assert.is_table(dispatch_err)
    assert.matches("unsupported platform",
      (dispatch_err --[[@as Neoagent.Error]]).message)
  end)

  it("activates only after a successful platform probe", function()
    local root = temp()
    local original = {
      name = "Neo",
      sandbox = { enabled = true },
      tools = { {
        name = "custom",
        description = "custom",
        input_schema = {
          type = "object",
          properties = {},
          additionalProperties = false,
        },
        execute = function(_, ctx)
          return {
            content = { {
              type = "text",
              text = (ctx --[[@as Neoagent.ToolCapabilities]]).process and "restricted" or "host",
            } },
          }
        end,
      } },

    }
    local checked = 0
    ---@type Neoagent.SandboxPlatform<Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>>
    local platform = {
      name = "test",
      check = function()
        checked = checked + 1
        return { ok = true, platform = "test" }
      end,
      exec = function()
        return {
          code = 0, signal = 0, stdout = "", stderr = "",
          output = "", timed_out = false,
        }
      end,
      fs = function() return true end,
    }
    local composition = require("neoagent.sandbox.composition")
    local dialog_source = require("neoagent.dialog").new()
    local toolset, toolset_status, returned_dialogs = composition.compose({
      tools = original.tools,
    }, original.sandbox, {
      platform = platform,
      status = { ok = true, platform = "test" },
      dialogs = dialog_source,
    })
    assert.is_true(toolset_status.active)
    assert.are.equal(dialog_source, returned_dialogs)
    assert.is_table(assert(assert(assert(toolset).tools[1]).input_schema.properties).options)
    assert.is_nil(original.tools[1].input_schema.properties.options)

    local composed, dialogs =
      composition.agent(require("neoagent.config").resolve(original), { platform = platform })
    assert.are.equal(1, checked)
    assert.is_table(dialogs)
    assert.are.equal("custom", assert(assert(composed.tools)[1]).name)
    assert.is_table(
      assert(assert(assert(composed.tools)[1]).input_schema.properties).options)
    assert.is_nil(
      original.tools[1].input_schema.properties.options)
    local value = assert(composed.execute_tool)(
      assert(assert(composed.tools)[1]), {}, context(root))
    assert.are.equal("restricted", assert(value.content[1]).text)

    local disabled = util.copy(original)
    disabled.sandbox.enabled = false
    local untouched, broker =
      require("neoagent.sandbox.composition").agent(
        require("neoagent.config").resolve(disabled), { platform = platform })
    assert.is_nil(broker)
    assert.are.equal(original.tools[1].execute,
      assert(assert(untouched.tools)[1]).execute)
    assert.are.equal(1, checked)

    local dispatch_module = package.loaded["neoagent.sandbox.platform"]
    package.loaded["neoagent.sandbox.platform"] = {
      select = function()
        return platform, { ok = true, platform = "test" }
      end,
    }
    local selected_ok, selected_value = pcall(
      require("neoagent.sandbox.composition").agent, require("neoagent.config").resolve(original))
    package.loaded["neoagent.sandbox.platform"] = dispatch_module
    assert.is_true(selected_ok)
    assert.is_function(selected_value.execute_tool)
  end)

  it("carries sandbox guidance in the composed toolset prompt", function()
    local original = {
      sandbox = { enabled = true },
      tools = { {
        name = "custom",
        description = "Custom tool",
        input_schema = {
          type = "object",
          properties = {},
          additionalProperties = false,
        },
        execute = function(_, ctx)
          return {
            content = { {
              type = "text",
              text = (ctx --[[@as Neoagent.ToolCapabilities]]).process and "restricted" or "host",
            } },
          }
        end,
      } },

    }
    ---@type Neoagent.SandboxPlatform<Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>>
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test" } end,
      exec = function()
        return {
          code = 0, signal = 0, stdout = "", stderr = "",
          output = "", timed_out = false,
        }
      end,
      fs = function() return true end,
    }
    local composition = require("neoagent.sandbox.composition")
    local toolset, status = composition.compose({
      tools = original.tools,
    }, original.sandbox, {
      platform = platform,
      status = { ok = true, platform = "test" },
      dialogs = require("neoagent.dialog").new(),
    })
    assert.is_true(status.active)
    assert.is_string(assert(toolset).system_prompt)
    assert.matches("Sandboxed execution", (assert(assert(toolset).system_prompt)))
    assert.matches("native test sandbox", (assert(assert(toolset).system_prompt)))
    assert.matches("require_escalation", (assert(assert(toolset).system_prompt)))
    assert.matches("denial", (assert(assert(toolset).system_prompt)))

    local composed = composition.agent(require("neoagent.config").resolve(original), {
      platform = platform,
    })
    assert.are.equal(assert(toolset).system_prompt,
      composed._sandbox_system_prompt)

    local disabled = util.copy(original)
    disabled.sandbox.enabled = false
    local untouched =
      composition.agent(require("neoagent.config").resolve(disabled), { platform = platform })
    assert.is_nil(untouched._sandbox_system_prompt)
  end)

  it("switches one stable toolset between host and sandbox execution", function()
    local root = temp()
    local checks = 0
    local tool = {
      name = "inspect",
      description = "Inspect execution",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
      execute = function(arguments, ctx)
        assert.is_nil(arguments.options)
        return { content = { {
          type = "text",
          text = (ctx --[[@as Neoagent.ToolCapabilities]]).process and "sandbox" or "host",
        } } }
      end,
    }
    ---@type Neoagent.SandboxPlatform<Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>>
    local platform = {
      name = "test",
      check = function()
        checks = checks + 1
        return { ok = true, platform = "test" }
      end,
      exec = function() error("must not execute") end,
      fs = function() error("must not access files") end,
    }
    local stable, status, _, runtime =
      require("neoagent.sandbox.composition").switchable({
        tools = { tool },
      }, { enabled = false }, { platform = platform })
    local original_tools = util.copy(stable.tools)
    local execute = assert(stable.execute_tool)
    assert.is_false(status.enabled)
    assert.are.equal(0, checks)
    local value = execute(assert(stable.tools[1]), { options = {
      require_escalation = true,
      escalation_justification = "inspect host execution",
    } }, context(root))
    assert.are.equal("host", assert(value.content[1]).text)

    status = assert(runtime:set_enabled(true))
    assert.is_true(status.active)
    assert.are.equal(1, checks)
    value = execute(assert(stable.tools[1]), {}, context(root))
    assert.are.equal("sandbox", assert(value.content[1]).text)

    status = assert(runtime:set_enabled(false))
    assert.is_false(status.enabled)
    value = execute(assert(stable.tools[1]), {}, context(root))
    assert.are.equal("host", assert(value.content[1]).text)
    assert(runtime:set_enabled(true))
    assert.are.equal(1, checks)
    assert.are.equal(execute, stable.execute_tool)
    assert.are.same(original_tools, stable.tools)
  end)

  it("blocks unavailable sandbox execution until explicitly disabled", function()
    local root = temp()
    local executions = 0
    local tool = {
      name = "inspect", description = "Inspect", input_schema = { type = "object" },
      execute = function()
        executions = executions + 1
        return { content = { { type = "text", text = "host" } } }
      end,
    }
    local composition = require("neoagent.sandbox.composition")
    local options = { status = { ok = false, platform = "test", message = "unavailable" } }
    local stable, status, _, runtime = composition.switchable(
      { tools = { tool } }, { enabled = true }, options)

    assert.is_true(status.enabled)
    assert.is_false(status.active)
    local execute_stable = assert(stable.execute_tool)
    local blocked = execute_stable(assert(stable.tools[1]), {}, context(root))
    assert.is_true(blocked.isError)
    assert.is_true(assert(assert(blocked.details).sandbox).unavailable)
    assert.are.equal(0, executions)

    assert(runtime:set_enabled(false))
    local permitted = execute_stable(assert(stable.tools[1]), {}, context(root))
    assert.are.equal("host", assert(permitted.content[1]).text)
    assert.are.equal(1, executions)

    local direct = composition.agent(require("neoagent.config").resolve({
      tools = { tool }, sandbox = { enabled = true },
    }), options)
    local execute = direct.execute_tool or function(selected, arguments, ctx)
      return selected.execute(arguments, ctx)
    end
    blocked = execute(assert(assert(direct.tools)[1]), {}, context(root))
    assert.is_true(blocked.isError)
    assert.are.equal(1, executions)
  end)

  it("bounds unavailable warnings and fails initial activation exceptions", function()
    local composition = require("neoagent.sandbox.composition")
    local warning = composition.warning(string.rep("n", 1100), {
      stage = "probe",
      message = string.rep("m", 1100),
    })
    assert.matches(string.rep("n", 997) .. "...", warning, 1, true)
    assert.is_true(warning:find(string.rep("m", 900), 1, true) ~= nil)
    assert.are.equal("...", warning:sub(-3))
    assert.matches("requirements check failed", composition.warning("", {
      message = "",
    }), 1, true)

    local activated, activation_err = pcall(function()
      composition.switchable({ tools = {} }, { enabled = true }, {
        platform = {
          name = "broken",
          check = function() return { ok = true, platform = "broken" } end,
          temporary_root = function() error("temporary root failed") end,
          exec = function() error("must not execute") end,
          fs = function() error("must not access files") end,
        },
      })
    end)
    assert.is_false(activated)
    assert.matches("temporary root failed",
      util.normalize_error(activation_err).message)
  end)

  it("keeps a failed activation exception from restoring host authority", function()
    local root = temp()
    local executions = 0
    local tool = {
      name = "inspect", description = "Inspect", input_schema = { type = "object" },
      execute = function()
        executions = executions + 1
        return { content = { { type = "text", text = "host" } } }
      end,
    }
    local stable, _, _, runtime = require("neoagent.sandbox.composition").switchable(
      { tools = { tool } }, { enabled = false }, { platform = {
        name = "test",
        check = function() return { ok = true, platform = "test" } end,
        temporary_root = function() error("backend setup failed") end,
        fs = function() error("must not access files") end,
        exec = function() error("must not execute") end,
      } })

    local status, err = runtime:set_enabled(true)

    assert.is_nil(status)
    assert.matches("backend setup failed", assert(err).message)
    assert.is_true(runtime:status().enabled)
    assert.is_false(runtime:status().active)
    assert.is_true(assert(stable.execute_tool)(assert(stable.tools[1]), {}, context(root)).isError)
    assert.are.equal(0, executions)
  end)

  it("publishes a failed activation warning for Agent presentation", function()
    ---@type Neoagent.ConfigInput<Neoagent.TestSandboxEnvironment>
    local configured = {
      name = "Neo",
      sandbox = { enabled = true },
      tools = {},

    }
    local composed, broker =
      require("neoagent.sandbox.composition").agent(require("neoagent.config").resolve(configured), {
        status = {
          ok = false, platform = "test",
          stage = "probe",
          message = "native support is unavailable",
        },
      })
    assert.is_nil(broker)
    assert.is_string(composed._sandbox_warning)
    assert.matches("tool execution is blocked",
      (assert(composed._sandbox_warning)))
  end)

  it("merges profile tables and calls profile callbacks with defaults", function()
    local root = temp()
    local composition = require("neoagent.sandbox.composition")
    local defaults = composition.default_profile(context(root))
    assert.are.equal(root,
      assert(defaults.filesystem.entries[1]).path)
    assert.are.equal("restricted", defaults.network)
    assert.is_true(defaults.environment.clear)
    assert.are.equal(
      vim.uv.fs_realpath(vim.uv.os_tmpdir()),
      defaults.environment.set.TMPDIR)
    local writable_temporary = {}
    for _, entry in ipairs(defaults.filesystem.entries) do
      if entry.access == "write" then
        writable_temporary[entry.path] = true
      end
    end
    assert.is_true(writable_temporary[
      vim.uv.fs_realpath(vim.uv.os_tmpdir())])
    assert.is_true(writable_temporary[vim.uv.fs_realpath("/tmp")])

    local original_realpath = vim.uv.fs_realpath
    vim.uv.fs_realpath = function() return nil end
    local has_temporary, temporary_err = pcall(
      composition.default_profile, context(root))
    vim.uv.fs_realpath = original_realpath
    assert.is_false(has_temporary)
    assert.matches("requires a host temporary directory",
      util.normalize_error(temporary_err).message)
    local fallback = composition.default_profile(context(root),
      require("neoagent.sandbox.path").posix, "")
    assert.are.equal(vim.uv.fs_realpath("/tmp"), fallback.environment.set.TMPDIR)

    ---@type {default: Neoagent.SandboxProfile, ctx: Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>}?
    local seen
    ---@type Neoagent.SandboxPlatform<Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>>
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test" } end,
      fs = function() return "contents" end,
      exec = function()
        return {
          code = 0, signal = 0, stdout = "", stderr = "",
          output = "", timed_out = false,
        }
      end,
    }
    ---@type Neoagent.ConfigInput<Neoagent.TestSandboxEnvironment>
    local configured = {
      name = "Neo",
      sandbox = {
        enabled = true,
        profile = function(default, ctx)
          seen = { default = default, ctx = ctx }
          default.network = "enabled"
          return default
        end,
      },
      tools = { require("neoagent.tools.read_file").new() },

    }
    local composed = composition.agent(
      require("neoagent.config").resolve(configured), { platform = platform })
    assert.is_true(assert(composed._sandbox_status).active)
    local value = assert(composed.execute_tool)(
      assert(assert(composed.tools)[1]), { path = "file" }, context(root))
    assert.are.equal("contents", assert(value.content[1]).text)
    assert.are.equal("enabled", assert(seen).default.network)
    assert.are.equal(root,
      assert(assert(seen).ctx.context).workspace.root)

    assert(configured.sandbox).profile = { network = "enabled" }
    ---@async
    ---@param arguments Neoagent.JsonObject
    ---@param ctx Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
    ---@return Neoagent.ToolResult
    local function run_process(arguments, ctx)
      common.process(ctx --[[@as Neoagent.ToolCapabilities]], { "true" }, { cwd = root })
      return { content = { { type = "text", text = "ok" } } }
    end
    configured.tools = { {
      name = "process",
      description = "process",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
      execute = run_process,
    } }
    platform.exec = function(request)
      assert.are.equal("enabled", request.profile.network)
      return {
        code = 0, signal = 0, stdout = "", stderr = "",
        output = "", timed_out = false,
      }
    end
    composed = composition.agent(
      require("neoagent.config").resolve(configured), { platform = platform })
    value = assert(composed.execute_tool)(
      assert(assert(composed.tools)[1]), {}, context(root))
    assert.are.equal("ok", assert(value.content[1]).text)

    local ok, err = pcall(function()
      composition.default_profile({})
    end)
    assert.is_false(ok)
    assert.are.equal("Sandbox requires a workspace root", util.normalize_error(err).message)
    local failed = composition.agent(require("neoagent.config").resolve(configured), {
      platform = {
        name = "broken",
        fs = function() error("probe failed") end,
        exec = function() error("probe failed") end,
        check = function() error("probe exploded") end,
      },
    })
    assert.is_false(assert(failed._sandbox_status).active)
    assert.are.equal("requirements", assert(failed._sandbox_status).stage)
    assert.is_string(failed._sandbox_warning)
  end)

  it("keeps a root workspace bounded to shared temporary writes", function()
    ---@type Neoagent.SandboxProfile?
    local seen_profile
    local composed = require("neoagent.sandbox.composition").agent(require("neoagent.config").resolve({
      name = "Root",
      sandbox = { enabled = true },
      tools = { require("neoagent.tools.read_file").new() },

    }), {
      platform = { check = function() return { ok = true, platform = "test" } end,
        name = "test",
        fs = function(request)
          seen_profile = request.profile
          return "root-readable"
        end,
        exec = function() error("must not execute") end,
      },
      status = {
        ok = true,
        platform = "test",
        capabilities = { filesystem = true },
      },
    })
    local value = assert(composed.execute_tool)(
      assert(assert(composed.tools)[1]), { path = "/etc/hosts" }, context("/"))
    assert.are.equal("root-readable", assert(value.content[1]).text)
    assert.are.equal("read", assert(seen_profile).filesystem.default)
    local allowed_writes = {
      [vim.uv.fs_realpath(vim.uv.os_tmpdir())] = true,
      [vim.uv.fs_realpath("/tmp")] = true,
    }
    for _, entry in ipairs(assert(seen_profile).filesystem.entries) do
      assert.are_not.equal("/", entry.path)
      if entry.access == "write" then
        assert.is_true(allowed_writes[entry.path])
      end
    end
  end)

  it("reports recorded sandbox capabilities without probing global state",
    function()
      local sandbox = require("neoagent.sandbox")
      local status = sandbox.info({
        sandbox = { enabled = true },
        _sandbox_status = {
          ok = true,
          active = true,
          platform = "linux",
          degraded = true,
          degraded_reason = "inherited host procfs is active",
          capabilities = {
            filesystem = true,
            procfs = "host",
            procfs_isolated = false,
          },
        },
      })
      assert.is_true(status.active)
      local agent = require("neoagent.agent").new({
        name = "Sandbox status", default_registry = false, tools = {},
        sandbox = { enabled = true },
      })
      local agent_status = sandbox.info(agent)
      agent:destroy()
      assert.is_true(agent_status.enabled)
      assert.is_nil(agent_status.active)
      local rendered = sandbox.format_info(status)
      assert.matches("isolation: degraded", rendered)
      assert.matches("reason: inherited host procfs is active",
        rendered, 1, true)
      assert.matches("capability.procfs: host", rendered, 1, true)
      assert.matches("capability.procfs_isolated: no", rendered, 1, true)
      assert.are.equal("Neoagent sandbox\nenabled: no\nactive: no",
        sandbox.format_info(sandbox.info({
          sandbox = { enabled = false },
        })))
      assert.are.equal(table.concat({
        "Neoagent sandbox",
        "enabled: yes",
        "active: no",
        "platform: linux",
        "stage: probe",
        "reason: user namespaces are unavailable",
      }, "\n"), sandbox.format_info({
        enabled = true,
        active = false,
        platform = "linux",
        stage = "probe",
        message = "user namespaces are unavailable",
      }))
    end)
end)

describe("neoagent sandbox protocol and native profiles", function()
  it("frames fragmented binary MessagePack events", function()
    local protocol = require("neoagent.sandbox.protocol")
    local binary = "a\0b\255"
    local data = protocol.encode({ v = 1, type = "ready" })
      .. protocol.encode({
        v = 1,
        type = "output",
        stream = "stdout",
        seq = 1,
        data = binary,
      })
      .. protocol.encode({
        v = 1, type = "exit", code = 7, signal = 0,
      })
    for split = 1, #data do
      local events = {}
      local decoder = protocol.new({
        on_event = function(event) events[#events + 1] = event end,
      })
      decoder:feed(data:sub(1, split))
      decoder:feed(data:sub(split + 1))
      local terminal = assert(decoder:finish())
      assert.are.equal(7, terminal.code)
      assert.are.equal(binary, events[2].data)
    end
    local invalid, invalid_err =
      protocol.decode_all(protocol.encode({
        v = 1,
        type = "output",
        stream = "stdout",
        seq = 1,
        data = "early",
      }))
    assert.is_nil(invalid)
    assert.matches("precedes ready", tostring(invalid_err))
    local events, err = protocol.decode_all("\255\255\255\255")
    assert.is_nil(events)
    assert.matches("frame length", tostring(err))

    local invalid_events = {
      {},
      { v = 1, type = "ready" },
      { v = 1, type = "ready", duplicate = true },
      {
        v = 1, type = "output", stream = "other",
        seq = 1, data = "x",
      },
      {
        v = 1, type = "output", stream = "stdout",
        seq = 2, data = "x",
      },
      { v = 1, type = "exit", code = -1, signal = 0 },
      { v = 1, type = "error", stage = "", errno = 1 },
      { v = 1, type = "unknown" },
    }
    for index, event in ipairs(invalid_events) do
      local decoder = protocol.new()
      if index > 1 then
        decoder:feed(protocol.encode({ v = 1, type = "ready" }))
      end
      assert.has_error(function()
        decoder:feed(protocol.encode(event))
      end)
    end
    local after_terminal = protocol.new()
    after_terminal:feed(protocol.encode({ v = 1, type = "ready" }))
    after_terminal:feed(protocol.encode({
      v = 1, type = "exit", code = 0, signal = 0,
    }))
    assert.has_error(function()
      after_terminal:feed(protocol.encode({
        v = 1, type = "output", stream = "stdout", seq = 1, data = "late",
      }))
    end, "sandbox output follows terminal event")
    local truncated = protocol.new()
    truncated:feed(protocol.encode({ v = 1, type = "ready" }):sub(1, 6))
    assert.is_nil(truncated:finish())
    local unterminated = protocol.new()
    unterminated:feed(protocol.encode({ v = 1, type = "ready" }))
    assert.is_nil(unterminated:finish())
  end)

  it("exposes stable architecture and seccomp values", function()
    local abi = require("neoagent.sandbox.linux.abi")
    assert.is_true(abi.supported("x64"))
    assert.is_true(abi.supported("arm64"))
    assert.is_false(abi.supported("mips"))
    assert.are.equal(155, assert(abi.current("x64")).pivot_root)
    assert.are.equal(41, assert(abi.current("arm64")).pivot_root)
    local seccomp = require("neoagent.sandbox.linux.seccomp")
    local restricted = seccomp.rules("x64", "restricted")
    assert.are.equal(41, assert(restricted).socket)
    assert.are.equal(53, assert(restricted).socketpair)
    assert.are.equal(56, assert(restricted).clone)
    assert.are.equal(435, assert(restricted).clone3)
    assert.is_false(vim.list_contains(assert(restricted).deny, assert(restricted).clone3))
    assert.are.equal(0x7e020080, assert(restricted).namespace_flags)
    assert.is_true(vim.list_contains(assert(assert(restricted).network_deny), 42))
    assert.is_true(vim.list_contains(assert(assert(restricted).network_deny), 307))
    assert.is_nil(assert(seccomp.rules("x64", "enabled")).socket)
    assert.is_nil(assert(seccomp.rules("x64", "enabled")).socketpair)
    assert.is_nil(assert(seccomp.rules("x64", "enabled")).network_deny)
    local arm = seccomp.rules("arm64", "restricted")
    assert.are.equal(198, assert(arm).socket)
    assert.are.equal(199, assert(arm).socketpair)
    assert.is_true(vim.list_contains(assert(assert(arm).network_deny), 203))
    assert.is_nil(seccomp.rules("mips", "restricted"))
  end)

  it("compiles macOS policies with parameterized paths", function()
    local root = "/tmp/workspace \"quoted\""
    local compiler = require("neoagent.sandbox.macos.profile")
    local policy, parameters = compiler.compile({
      filesystem = {
        default = "read",
        entries = {
          { path = root, access = "write" },
          { path = root .. "/.git", access = "read" },
          { path = root .. "/secret", access = "deny" },
        },
      },
      network = "restricted",
    }, { { path = "/tmp/internal", access = "write" } })
    assert.is_nil((policy:find(root, 1, true)))
    assert.is_nil((policy:find("network-outbound", 1, true)))
    assert.is_true(#parameters > 0)
    local argv = compiler.argv("/usr/bin/sandbox-exec",
      policy, parameters)
    assert.are.equal("/usr/bin/sandbox-exec", argv[1])
    assert.are.equal("--", argv[#argv])
    local enabled = util.copy({
      filesystem = { default = "read", entries = {} },
      network = "enabled",
    })
    assert.matches("network%-outbound",
      (compiler.compile(enabled)))

    local alpha = "/tmp/alpha"
    local bravo = "/tmp/bravo"
    local _, ordered = compiler.compile({
      filesystem = {
        default = "read",
        entries = {
          { path = bravo, access = "read" },
          { path = alpha, access = "read" },
        },
      },
      network = "restricted",
    })
    assert.are.equal(alpha, assert(ordered[2]).value)
    assert.are.equal(bravo, assert(ordered[3]).value)
  end)
end)

describe("neoagent sandbox execution", function()
  local paths = {}

  after_each(function()
    for _, run in ipairs(context_runs) do run:cancel() end
    context_runs = {}
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  local function temp()
    local path = temporary_directory()
    paths[#paths + 1] = path
    return path
  end

  it("preserves ordinary nonzero command results", function()
    local root = temp()
    local box = require("neoagent.sandbox.enforce").new({
      platform = { check = function() return { ok = true, platform = "test" } end,
        name = "test",
        fs = function() return true end,
        exec = function()
          return {
            code = 1,
            signal = 0,
            stdout = "",
            stderr = "",
            output = "",
            timed_out = false,
          }
        end,
      },
      profile = profile(root),
    })
    local value = box:wrap()(
      require("neoagent.tools.shell").new(),
      { command = "grep missing file.txt" },
      context(root))

    assert.is_true(value.isError)
    assert.are.equal(1, assert(value.details).exit_code)
    assert.is_nil(assert(value.details).sandbox)
    assert.are.equal(
      "[Command exited with status 1]\n(no output)",
      assert(value.content[1]).text)

    ---@type Neoagent.ToolResult
    local expected = {
      content = { { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" } },
      is_error = true,
      details = { exit_code = 1, source = "command" },
    }
    ---@async
    ---@param arguments Neoagent.JsonObject
    ---@param ctx Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
    ---@return Neoagent.ToolResult
    local function preserve_result(arguments, ctx)
      local process_result =
        common.process(ctx --[[@as Neoagent.ToolCapabilities]], { "grep" }, { cwd = root })
      assert.are.equal(1, process_result.code)
      return expected
    end
    local custom = box:wrap()({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} },
      execute = preserve_result,
    }, {}, context(root))
    assert.are.same(expected, custom)

    local no_matches = box:wrap()(
      require("neoagent.tools.grep").new(),
      { pattern = "missing" },
      context(root))
    assert.is_nil(no_matches.isError)
    assert.are.equal("No matches found", assert(no_matches.content[1]).text)
  end)

  it("classifies likely sandbox denials from bounded process evidence",
    function()
      local root = temp()
      ---@type table<string, {code: integer, signal?: integer, stdout?: string, stderr?: string, output?: string, stdout_stream?: string, stream?: string, extra_stream?: string}>
      local responses = {}
      local streamed = {}
      local box = require("neoagent.sandbox.enforce").new({
        platform = { check = function() return { ok = true, platform = "test" } end,
          name = "linux",
          fs = function() return true end,
          exec = function(request)
            local response = assert(responses[assert(request.argv[1])])
            if response.stdout_stream then
              assert(request.on_output)(response.stdout_stream, false, response.stdout_stream, "", response.stdout_stream)
            end
            if response.stream then
              assert(request.on_output)(response.stream, true, "", response.stream, response.stream)
              streamed[#streamed + 1] = response.stream
              if response.extra_stream then assert(request.on_output)(response.extra_stream, true, "", response.extra_stream, response.extra_stream) end
            end
            return {
              code = response.code,
              signal = response.signal or 0,
              stdout = response.stdout or "",
              stderr = response.stderr or "",
              output = response.output or "",
              timed_out = false,
            }
          end,
        },
        profile = profile(root),
      })
      ---@param name string
      ---@param returned? Neoagent.ToolResult
      ---@param throws? boolean
      ---@return Neoagent.ToolResult
      local function execute(name, returned, throws)
        ---@async
        ---@param arguments Neoagent.JsonObject
        ---@param ctx Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
        ---@return Neoagent.ToolResult
        local function run_command(arguments, ctx)
          local process_result = common.process(ctx --[[@as Neoagent.ToolCapabilities]], { name }, {
            cwd = root,
            on_output = function(data)
              assert.is_string(data)
            end,
          })
          if throws then
            error("tool rejected status " .. process_result.code)
          end
          return returned or {
            content = { { type = "text", text = name } },
            details = { exit_code = process_result.code },
            isError = true,
          }
        end
        return box:wrap()({
          name = "probe", description = "Probe sandbox behavior",
          input_schema = { type = "object", properties = {} },
          execute = run_command,
        }, {}, context(root))
      end
      ---@param value Neoagent.ToolResult
      local function assert_restricted(value)
        assert.is_true(value.isError or value.is_error)
        assert.is_true(assert(assert(value.details).sandbox).ran_restricted)
        assert.matches("blocked by the sandbox",
          assert(assert(value.content[1]).text), 1, true)
      end
      ---@type {name: string, code?: integer, stderr?: string, stdout?: string, output?: string, stream?: string}[]
      local cases = {
        {
          name = "operation",
          stderr = "Operation not permitted",
        },
        {
          name = "permission",
          stream = "Permission denied",
        },
        {
          name = "readonly",
          stdout = "Read-only file system",
        },
        {
          name = "seccomp",
          output = "seccomp rejected the syscall",
        },
        {
          name = "sandbox",
          stderr = "sandbox policy rejected the operation",
        },
        {
          name = "landlock",
          stdout = "Landlock denied the path",
        },
        {
          name = "write",
          output = "failed to write file",
        },
      }
      for _, item in ipairs(cases) do
        responses[item.name] = { code = 1, stdout = item.stdout, stderr = item.stderr, output = item.output, stream = item.stream }
        assert_restricted(execute(item.name))
      end
      assert.are.same({ "Permission denied" }, streamed)

      responses.image = {
        code = 127,
        stderr = "Permission denied",
      }
      local image = execute("image", {
        content = { { type = "image", file_id = string.rep("a", 64), bytes = 3, mime_type = "image/png" } },
        details = { source = "custom" },
        is_error = true,
      })
      assert_restricted(image)
      assert.are.equal("custom", assert(image.details).source)
      assert.are.equal("image", assert(image.content[2]).type)

      for _, details in ipairs({
        "tool detail", 7, false, vim.NIL, { "first", "second" },
        { sandbox = "tool-owned detail" },
        { sandbox = { "tool-owned list" } },
      }) do
        local original = {
          content = { { type = "text", text = "custom failure" } },
          isError = true,
          details = details,
        }
        local annotated = execute("image", original)
        assert.are.same(details, annotated.details)
        assert.matches("blocked by the sandbox", (assert(assert(annotated.content[1]).text)),
          1, true)
        assert.are.equal("custom failure", original.content[1].text)
      end

      responses.thrown = {
        code = 1,
        stderr = "operation not permitted",
      }
      local thrown = execute("thrown", nil, true)
      assert_restricted(thrown)
      assert.matches("tool rejected status 1",
        (assert(assert(thrown.content[1]).text)), 1, true)

      responses.cancelled = {
        code = 1,
        stderr = "operation not permitted",
      }
      local cancel_execute = box:wrap()
      ---@async
      ---@param arguments Neoagent.JsonObject
      ---@param ctx Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
      ---@return Neoagent.ToolResult
      local function cancel_after_process(arguments, ctx)
        common.process(ctx --[[@as Neoagent.ToolCapabilities]], { "cancelled" }, { cwd = root })
        error({ kind = "cancelled", message = "cancelled" }, 0)
      end
      local completed, cancelled = pcall(cancel_execute, {
        name = "probe", description = "Probe sandbox behavior",
        input_schema = { type = "object", properties = {} },
        execute = cancel_after_process,
      }, {}, context(root))
      assert.is_false(completed)
      assert.are.equal("cancelled", util.normalize_error(cancelled).kind)

      for _, code in ipairs({ 2, 126, 127 }) do
        local name = "ordinary-" .. code
        responses[name] = { code = code, stderr = "command not found" }
        local ordinary = execute(name)
        assert.is_nil(assert(ordinary.details).sandbox)
        assert.are.equal(name, assert(ordinary.content[1]).text)
      end

      responses.success = {
        code = 0,
        stderr = "operation not permitted",
      }
      local success = execute("success")
      assert.is_nil(assert(success.details).sandbox)

      responses.bounded = {
        code = 1,
        stream = string.rep("x", 1024 * 1024) .. "permission denied",
        extra_stream = "permission denied",
      }
      local bounded = execute("bounded")
      assert.is_nil(assert(bounded.details).sandbox)

      responses.contention = {
        code = 1,
        stdout_stream = string.rep("x", 1024 * 1024),
        stream = "permission denied",
      }
      assert_restricted(execute("contention"))

      local constants = (vim.uv --[[@as {constants?: table<string, integer>}]]).constants
      local sigsys = constants and constants.SIGSYS
      if sigsys then
        responses.sigsys = { code = 128 + sigsys, signal = sigsys }
        assert_restricted(execute("sigsys"))
      end
    end)

  it("enforces filesystem, process, environment, and capability lifetime", function()
    local root = temp()
    local protected = vim.fs.joinpath(root, ".git")
    assert.are.equal(1, vim.fn.mkdir(protected, "p"))
    ---@type (Neoagent.SandboxFilesystemRequest|Neoagent.SandboxProcessRequest)[], Neoagent.ToolCapabilities
    local calls, retained = {}, {}
    ---@type Neoagent.SandboxPlatform<Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>>
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test" } end,
      fs = function(request)
        calls[#calls + 1] = request
        if request.operation == "read" then return "read:" .. request.path end
        return true
      end,
      exec = function(request)
        calls[#calls + 1] = request
        if request.on_output then request.on_output("chunk", false, "chunk", "", "chunk") end
        return {
          code = request.argv[1] == "fail" and 2 or 0,
          signal = 0,
          stdout = "",
          stderr = "",
          output = "",
          timed_out = false,
        }
      end,
    }
    local box = require("neoagent.sandbox.enforce").new({
      platform = platform,
      profile = profile(root, {
        { path = root, access = "write" },
        { path = protected, access = "read" },
      }),
      environ = function()
        return { PATH = "/bin", SECRET = "hidden" }
      end,
    })
    local execute = box:wrap(function(tool, arguments, ctx)
      retained.fs, retained.process = (ctx --[[@as Neoagent.ToolCapabilities]]).fs, (ctx --[[@as Neoagent.ToolCapabilities]]).process
      return tool.execute(arguments, ctx)
    end)
    local read = { name = "probe", description = "Read through sandbox", input_schema = { type = "object", properties = {} },
      execute = function(arguments, ctx)
        return {
          content = { {
            type = "text",
            text = assert(common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).read(arguments.path)),
          } },
        }
      end,
    }
    local value = execute(read, { path = "file" }, context(root))
    assert.matches(root, (assert(assert(value.content[1]).text)), 1, true)
    value = execute({ name = "probe", description = "Probe sandbox behavior", input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        assert(common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).atomic_replace(root .. "/file", "changed", {
          preserve_mode = true,
          new_mode = 420,
        }))
        return { content = { { type = "text", text = "replaced" } } }
      end,
    }, {}, context(root))
    assert.are.equal("replaced", assert(value.content[1]).text)
    local replacement = calls[#calls]
    assert.are.equal("atomic_replace", assert(replacement).operation)
    assert.are.equal("changed", assert(replacement).data)
    assert.are.same({ preserve_mode = true, new_mode = 420 },
      assert(replacement).policy)
    assert.are.equal(32, #assert(replacement).suffix)
    local denied = execute({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).write_all(protected .. "/config", "x")
        error("denied write must not return")
      end,
    }, {}, context(root))
    assert.is_true(denied.isError)
    assert.is_true(assert(assert(denied.details).sandbox).denied)
    assert.matches("require_escalation", (assert(assert(denied.content[1]).text)))

    local updates = {}
    ---@async
    ---@param arguments Neoagent.JsonObject
    ---@param ctx Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
    ---@return Neoagent.ToolResult
    local function failed_command(arguments, ctx)
      local result = common.process(ctx --[[@as Neoagent.ToolCapabilities]], { "fail", "" }, {
        cwd = root,
        on_output = function(data) updates[#updates + 1] = data end,
      })
      return {
        content = { { type = "text", text = "failed" } },
        isError = result.code ~= 0,
      }
    end
    local failed = execute({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} },
      execute = failed_command,
    }, {}, context(root))
    assert.are.same({ "chunk" }, updates)
    assert.is_true(failed.isError)
    assert.are.equal("failed", assert(failed.content[1]).text)
    assert.is_nil(failed.details)
    assert.has_error(function()
      ---@async
      ---@param arguments Neoagent.JsonObject
      ---@param ctx Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
      ---@return Neoagent.ToolResult
      local function reject_status(arguments, ctx)
        local process_result = common.process(ctx --[[@as Neoagent.ToolCapabilities]], { "fail" }, { cwd = root })
        error("native tool rejected status " .. process_result.code)
      end
      execute({ name = "probe", description = "Probe sandbox behavior", input_schema = { type = "object", properties = {} },
        execute = reject_status,
      }, {}, context(root))
    end, "native tool rejected status 2")
    local process_request = calls[#calls]
    assert.are.same({ PATH = "/bin", TEST_SANDBOX = "yes" },
      assert(process_request).env)
    assert.has_error(function() assert(retained.fs).read(root) end)
    assert.has_error(function()
      assert(retained.fs).atomic_replace(root .. "/file", "late", {
        preserve_mode = true, new_mode = 420,
      })
    end)
    assert.has_error(function() assert(retained.process)({ "true" }) end)

    local original_random = vim.uv.random
    vim.uv.random = function() return nil, "entropy unavailable" end
    value = execute({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        local replaced, replace_err = common.fs(
          ctx --[[@as Neoagent.ToolCapabilities]]
        ).atomic_replace(root .. "/file", "changed", { mode = 384 })
        return { content = { { type = "text", text = tostring(replaced) .. ":" .. tostring(replace_err) } } }
      end,
    }, {}, context(root))
    vim.uv.random = original_random
    assert.are.equal("nil:entropy unavailable", assert(value.content[1]).text)
  end)

  it("preserves chunked reads through the guarded filesystem", function()
    local root = temp()
    local contents = "zero\none\ntwo\n" .. string.rep("padding\n", 140000)
    local calls = 0
    local box = require("neoagent.sandbox.enforce").new({
      profile = profile(root),
      platform = {
        name = "test",
        check = function() return { ok = true, platform = "test" } end,
        fs = function(request)
          calls = calls + 1
          assert.are.equal("read_range", request.operation)
          assert.is_number(request.offset)
          assert.are.equal(1024 * 1024, request.size)
          local offset = assert(request.offset)
          return contents:sub(offset + 1, offset + assert(request.size))
        end,
        exec = function() error("no process expected") end,
      },
    })
    local result = box:wrap()(
      require("neoagent.tools.read_file").new(),
      { path = "streamed.txt", offset = 2, limit = 2 },
      context(root)
    )
    assert.is_nil(result.isError)
    assert.are.equal(2, calls)
    assert.matches("^one\ntwo", (assert(assert(result.content[1]).text)))
    assert.matches("1 more lines in file", (assert(assert(result.content[1]).text)))
  end)

  it("shares temporary read mounts across tool calls only while file identity is unchanged", function()
    local root = temp()
    ---@type Neoagent.SandboxFilesystemRequest[]
    local requests = {}
    local box = require("neoagent.sandbox.enforce").new({
      profile = profile(root), temporary_root = root,
      platform = { check = function() return { ok = true, platform = "test" } end,
        name = "test",
        compile = function(selected)
          selected = vim.deepcopy(selected)
          selected.filesystem.entries[#selected.filesystem.entries + 1] = {
            path = root .. "/protected", access = "deny",
          }
          return selected
        end,
        fs = function(request)
          requests[#requests + 1] = request
          return fs.read(request.path)
        end,
        exec = function() error("no process expected") end,
      },
    })
    local execute = box:wrap()
    local created = execute({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        local files = common.fs(ctx --[[@as Neoagent.ToolCapabilities]])
        local name = assert(files.create_temp("spill-"))
        assert(files.write_all(name, "original"))
        return { content = { { type = "text", text = name } } }
      end,
    }, {}, context(root))
    local path = util.text_content(created.content)
    local read = {
      name = "probe", description = "Read through sandbox",
      input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        local files = common.fs(ctx --[[@as Neoagent.ToolCapabilities]])
        return { content = { { type = "text", text = assert(files.read(path)) } } }
      end,
    }
    assert.are.equal("original", util.text_content(execute(read, {}, context(root)).content))
    local entries = requests[#requests].profile.filesystem.entries
    assert.are.same({ path = path, access = "read" }, entries[#entries])
    local inode = assert(vim.uv.fs_stat(path)).ino
    assert(fs.atomic_replace(path, "replacement", { preserve_mode = true, new_mode = 384 }))
    assert.are_not.equal(inode, assert(vim.uv.fs_stat(path)).ino)
    assert.are.equal("replacement", util.text_content(execute(read, {}, context(root)).content))
    entries = requests[#requests].profile.filesystem.entries
    assert.are.same({ path = root .. "/protected", access = "deny" }, entries[#entries])
    assert.are.equal("replacement", util.text_content(execute(read, {}, context(root)).content))
    local denied = execute({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        local files = common.fs(ctx --[[@as Neoagent.ToolCapabilities]])
        return { content = { {
          type = "text", text = assert(files.read(root .. "/protected")),
        } } }
      end,
    }, {}, context(root))
    assert.is_true(denied.isError)
    assert.is_true(assert(assert(denied.details).sandbox).denied)
    assert.are.equal(3, #requests)
  end)

  it("fails closed for malformed capabilities and backend failures", function()
    local root = temp()
    local temporary = vim.fs.joinpath(root, "spill")
    local raw_calls = {}
    local raw_fs = {
      create_temp_directory = fs.create_temp_directory,
      create_temp = function(_, directory)
        raw_calls[#raw_calls + 1] = "create_temp:" .. tostring(directory)
        return temporary
      end,
      read = function(path)
        raw_calls[#raw_calls + 1] = "read:" .. path
        return "temporary"
      end,
      mkdirp = function(path)
        raw_calls[#raw_calls + 1] = "mkdirp:" .. path
        return true
      end,
      write_all = function(path)
        raw_calls[#raw_calls + 1] = "write:" .. path
        return true
      end,
      atomic_replace = function(path)
        raw_calls[#raw_calls + 1] = "replace:" .. path
        return true
      end,
    }
    ---@type Neoagent.SandboxPlatform<Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>>
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test" } end,
      fs = function(request)
        raw_calls[#raw_calls + 1] = "platform:" .. request.operation
        return true
      end,
      exec = function()
        return {
          code = 0, signal = 0, stdout = "", stderr = "",
          output = "", timed_out = false,
        }
      end,
    }
    local box = require("neoagent.sandbox.enforce").new({
      platform = platform,
      profile = profile(root),
      fs = raw_fs,
      temporary_root = root,
    })
    local execute = box:wrap()
    local value = execute({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        local path = assert(common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).create_temp("spill-"))
        assert(common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).write_all(path, "data", "a", 384))
        assert(common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).atomic_replace(path, "replacement", {
          preserve_mode = true, new_mode = 420,
        }))
        assert.are.equal("temporary", common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).read(path))
        assert(common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).mkdirp(vim.fs.joinpath(root, "directory")))
        return { content = { { type = "text", text = "ok" } } }
      end,
    }, {}, context(root))
    assert.are.equal("ok", assert(value.content[1]).text)
    assert.are.same({
      "create_temp:" .. root,
      "write:" .. temporary,
      "replace:" .. temporary,
      "read:" .. temporary,
      "platform:mkdirp",
    }, raw_calls)

    local path_module = require("neoagent.sandbox.path")
    local rejecting_paths = util.copy(path_module.posix)
    rejecting_paths.validate_component = function() error("invalid component") end
    local rejecting = require("neoagent.sandbox.enforce").new({
      platform = platform,
      profile = profile(root),
      fs = raw_fs,
      paths = rejecting_paths,
      temporary_root = root,
    }):wrap()
    value = rejecting({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).create_temp("spill-")
        return { content = { { type = "text", text = "unexpected" } } }
      end,
    }, {}, context(root))
    assert.is_true(assert(assert(value.details).sandbox).unavailable)

    local calls_before_escape = #raw_calls
    value = execute({ name = "probe", description = "Probe sandbox behavior", input_schema = { type = "object", properties = {} },
      execute = function(_, ctx)
        common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).create_temp("../outside-")
        return { content = { { type = "text", text = "escaped" } } }
      end,
    }, {}, context(root))
    assert.is_true(value.isError)
    assert.is_true(assert(assert(value.details).sandbox).unavailable)
    assert.are.equal(calls_before_escape, #raw_calls)

    ---@async
    ---@param arguments Neoagent.JsonObject
    ---@param ctx Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
    ---@return Neoagent.ToolResult
    local function malformed_process(arguments, ctx)
      -- Deliberately malformed process inputs must reach sandbox validation.
      common.process(ctx --[[@as Neoagent.ToolCapabilities]],
        arguments.argv --[[@as string[] ]], arguments.opts --[[@as Neoagent.ProcessOptions]])
      return { content = { { type = "text", text = "unexpected" } } }
    end
    local process_tool = {
      name = "probe", description = "Run through sandbox",
      input_schema = { type = "object", properties = {} },
      execute = malformed_process,
    }
    for _, arguments in ipairs({
      { argv = {}, opts = { cwd = root } },
      { argv = { "" }, opts = { cwd = root } },
      { argv = { "true", "bad\0arg" }, opts = { cwd = root } },
      { argv = { "true" }, opts = "bad" },
      { argv = { "true" }, opts = { cwd = "" } },
    }) do
      value = execute(process_tool, arguments, context(root))
      assert.is_true(value.isError)
      assert.is_true(assert(assert(value.details).sandbox).unavailable)
    end

    local denied_root = vim.fs.joinpath(root, "denied")
    assert.are.equal(1, vim.fn.mkdir(denied_root, "p"))
    local denied_execute = require("neoagent.sandbox.enforce").new({
      platform = platform,
      profile = profile(root, {
        { path = root, access = "write" },
        { path = denied_root, access = "deny" },
      }),
      fs = raw_fs,
    }):wrap()
    value = denied_execute(process_tool, {
      argv = { "true" },
      opts = { cwd = denied_root },
    }, context(root))
    assert.is_true(assert(assert(value.details).sandbox).denied)

    rawset(platform, "exec", function() return {} end)
    value = execute(process_tool, {
      argv = { "true" },
      opts = { cwd = root },
    }, context(root))
    assert.is_true(assert(assert(value.details).sandbox).unavailable)

    platform.exec = function()
      error(util.error("sandbox_unavailable", "backend unavailable"), 0)
    end
    value = execute(process_tool, {
      argv = { "true" },
      opts = { cwd = root },
    }, context(root))
    assert.matches("backend unavailable", (assert(assert(value.content[1]).text)))

    local dynamic = require("neoagent.sandbox.enforce").new({
      platform = platform,
      profile = function() error("profile failed") end,
    }):wrap()
    value = dynamic({
      name = "probe", description = "Probe sandbox behavior",
      input_schema = { type = "object", properties = {} }, execute = function() error("tool must not run") end }, {}, context(root))
    assert.is_true(assert(assert(value.details).sandbox).unavailable)

    platform.exec = function()
      return {
        code = 0, signal = 0, stdout = "", stderr = "",
        output = "", timed_out = false,
      }
    end
    assert.has_error(function()
      execute({
        name = "probe", description = "Probe sandbox behavior",
        input_schema = { type = "object", properties = {} }, execute = function() error("ordinary failure") end },
        {}, context(root))
    end, "ordinary failure")

    local case_insensitive = util.copy(path_module.posix)
    case_insensitive.environment_key = function(name) return name:lower() end
    local seen_environment
    local environment_box = require("neoagent.sandbox.enforce").new({
      platform = {
        name = "test",
        check = platform.check,
        fs = platform.fs,
        exec = function(request)
          seen_environment = request.env
          return {
            code = 0, signal = 0, stdout = "", stderr = "",
            output = "", timed_out = false,
          }
        end,
      },
      paths = case_insensitive,
      environ = function() return { Path = "old" } end,
      profile = {
        id = "environment",
        filesystem = { default = "read", entries = {} },
        network = "restricted",
        environment = {
          clear = false,
          inherit = {},
          set = { PATH = "new" },
        },
      },
    }):wrap()
    value = environment_box(process_tool, {
      argv = { "true" }, opts = { cwd = root },
    }, context(root))
    assert.is_false(value.isError == true)
    assert.are.same({ PATH = "new" }, seen_environment)
  end)

  it("decorates schemas and grants one revocable approved call", function()
    local root = temp()
    local original_arguments = {
      path = "file",
      options = {
        native = "keep",
        require_escalation = true,
        escalation_justification = "needed for this test",
      },
    }
    local tool = {
      name = "custom",
      description = "custom",
      input_schema = {
        type = "object",
        properties = {
          path = { type = "string" },
          options = {
            type = "object",
            properties = { native = { type = "string" } },
            additionalProperties = false,
          },
        },
        additionalProperties = false,
      },
      execute = function() error("tool must not run") end,
    }
    ---@type Neoagent.JsonObject?, Neoagent.ToolFilesystem?, (fun(argv: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult)?, Neoagent.DialogRequest?
    local seen, retained_fs, retained_process, approval
    local escalation = require("neoagent.sandbox.escalation").new({
      fs = {
        read = function(path) return "host:" .. path end,
        create_temp = fs.create_temp,
        atomic_replace = fs.atomic_replace,
        mkdirp = fs.mkdirp,
        write_all = fs.write_all,
      },
      process = function()
        return { code = 0, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
      end,
    })
    local approved_ctx = dialog_context(root, function(value)
      approval = value
      return "approve"
    end)
    local transformed = escalation:tools({ tool })
    assert.is_nil(
      tool.input_schema.properties.options.properties.require_escalation)
    assert.is_table(assert(assert(assert(transformed[1]).input_schema.properties).options
      .properties).require_escalation)
    ---@async
    ---@param arguments Neoagent.JsonObject
    ---@param ctx Neoagent.ToolContext<Neoagent.TestSandboxEnvironment>
    ---@return Neoagent.ToolResult
    local function elevated_read(_, arguments, ctx)
      assert(type(arguments.path) == "string")
      seen = arguments
      retained_fs = (ctx --[[@as Neoagent.ToolCapabilities]]).fs
      retained_process = (ctx --[[@as Neoagent.ToolCapabilities]]).process
      local process_value = common.process(ctx --[[@as Neoagent.ToolCapabilities]], { "true" })
      return {
        content = { {
          type = "text",
          text = common.fs(ctx --[[@as Neoagent.ToolCapabilities]]).read(arguments.path)
            .. ":" .. tostring(process_value.code),
        } },
      }
    end
    local execute = escalation:wrap({
      restricted = function() error("restricted path ran") end,
      elevated = elevated_read,
    })
    local value = execute(
      assert(transformed[1]), original_arguments, approved_ctx)
    assert.are.equal("host:file:0", assert(value.content[1]).text)
    assert.are.same({ path = "file", options = { native = "keep" } },
      seen)
    assert.is_true(original_arguments.options.require_escalation)
    assert.are.equal("transcript", assert(approval).placement)
    assert.matches("Tool: custom", assert(approval).body)
    assert.matches("needed for this test", assert(approval).body)
    assert.are.same({
      { id = "approve", label = "approve", key = "y" },
      { id = "deny", label = "deny", key = "n" },
      { id = "deny_all", label = "deny all pending", key = "N" },
    }, assert(approval).actions)
    assert.has_error(function() assert(retained_fs).read("later") end)
    assert.has_error(function() assert(retained_process)({ "true" }) end)

    local bypassed = escalation:bypass(function(_, arguments)
      local native = assert(arguments.options).native
      if type(native) ~= "string" then error("native option was not preserved") end
      return { content = { { type = "text", text = native } } }
    end)(assert(transformed[1]), { options = { native = "keep" } }, context(root))
    assert.are.equal("keep", assert(bypassed.content[1]).text)

    local malformed = execute(assert(transformed[1]), {
      options = { require_escalation = true },
    }, context(root))
    assert.is_true(assert(assert(malformed.details).sandbox).invalid_escalation)

    local denied = require("neoagent.sandbox.escalation").new():wrap({
      restricted = function() error("restricted path ran") end,
      elevated = function() error("elevated path ran") end,
    })(assert(transformed[1]), original_arguments,
      dialog_context(root, function() return "deny" end))
    assert.is_true(assert(assert(denied.details).sandbox).denied_by_user)

    local invalid = escalation:bypass(function() error("must not execute") end)(
      assert(transformed[1]), "invalid" --[[@as Neoagent.JsonObject]], context(root))
    assert.is_true(assert(assert(invalid.details).sandbox).invalid_escalation)
  end)

  it("renders shell approval commands separately from agent justification",
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      local shell = module.new():tools({
        require("neoagent.tools.shell").new(),
      })[1]
      ---@type Neoagent.DialogRequest?
      local request
      local execute = module.new():wrap({
        restricted = function() error("restricted") end,
        elevated = function() error("elevated") end,
      })
      local value = execute(assert(shell), {
        command = "rm /outside/test.md",
        options = {
          require_escalation = true,
          escalation_justification =
            "User wants to clean up the test file.",
        },
      }, dialog_context(root, function(candidate)
        request = candidate
        return "deny"
      end))
      assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
      assert.are.equal(table.concat({
        "Run this tool once outside the sandbox?",
        "",
        "Tool: shell",
        "Working directory: " .. root,
        "Agent justification: User wants to clean up the test file.",
        "",
        "$ rm /outside/test.md",
        "",
        "This grants the tool your full user filesystem, process, environment, and network authority for this call.",
      }, "\n"), assert(request).body)
    end)

  it("remembers edited shell command prefixes for the current session",
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      local escalation = module.new({ shell = "/bin/sh" })
      local shell = escalation:tools({
        require("neoagent.tools.shell").new(),
      })[1]
      local elevated, restricted = {}, {}
      local execute = escalation:wrap({
        restricted = function(_, arguments)
          restricted[#restricted + 1] = arguments.command
          return { content = { { type = "text", text = "restricted" } } }
        end,
        elevated = function(_, arguments)
          elevated[#elevated + 1] = arguments.command
          return { content = { { type = "text", text = "elevated" } } }
        end,
      })
      ---@param command string
      ---@param requested? boolean
      ---@return Neoagent.JsonObject
      local function arguments(command, requested)
        local value = { command = command }
        if requested ~= false then
          value.options = {
            require_escalation = true,
            escalation_justification = "required by the test",
          }
        end
        return value
      end
      ---@param session_id string
      ---@param replies (string|Neoagent.DialogResult)[]
      ---@param seen Neoagent.DialogRequest[]
      local function with_dialog(session_id, replies, seen)
        local ctx = dialog_context(root, function(request)
          seen[#seen + 1] = request
          local reply = table.remove(replies, 1)
          assert.is_not_nil(reply, "unexpected approval prompt")
          return reply
        end)
        ctx.context.session_id = session_id
        return ctx
      end

      local seen = {}
      local value = execute(assert(shell), arguments("git status --short"),
        with_dialog("session-one", {
          "approve_prefix",
          {
            ok = true,
            action = "accept_prefix",
            input = "git status",
          },
        }, seen))
      assert.are.equal("elevated", assert(value.content[1]).text)
      assert.are.equal("transcript", seen[1].placement)
      assert.are.same({
        "approve", "approve_prefix", "deny", "deny_all",
      }, vim.tbl_map(function(action) return action.id end,
        seen[1].actions))
      assert.are.equal("float", seen[2].placement)
      assert.are.equal("git status --short", seen[2].input.value)
      assert.are.same({
        { id = "accept_prefix", label = "accept", key = "<CR>" },
        { id = "cancel_prefix", label = "cancel", key = "<C-c>" },
      }, seen[2].actions)

      execute(assert(shell), arguments("git status --porcelain"),
        with_dialog("session-one", {}, {}))
      assert.are.same({
        "git status --short",
        "git status --porcelain",
      }, elevated)

      local prompted = {}
      value = execute(assert(shell), arguments("git status-danger"),
        with_dialog("session-one", { "deny" }, prompted))
      assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
      assert.are.equal(1, #prompted)

      prompted = {}
      for _, command in ipairs({
        "git status && rm -rf /tmp/should-not-run",
        "git status || rm -rf /tmp/should-not-run",
        "git status; rm -rf /tmp/should-not-run",
        "git status | sh",
        "git status $(rm -rf /tmp/should-not-run)",
        "git status > /tmp/should-not-run",
        "git status 'unterminated",
        "git status\nrm -rf /tmp/should-not-run",
      }) do
        value = execute(assert(shell), arguments(command),
          with_dialog("session-one", { "deny" }, prompted))
        assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
        assert.is_true(vim.tbl_contains(
          vim.tbl_map(function(action) return action.id end,
            prompted[#prompted].actions), "approve_prefix"), command)
      end

      prompted = {}
      value = execute(assert(shell), arguments("$(whoami) --version"),
        with_dialog("session-one", { "deny" }, prompted))
      assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
      assert.is_false(vim.tbl_contains(
        vim.tbl_map(function(action) return action.id end,
          prompted[#prompted].actions), "approve_prefix"))

      execute(assert(shell), arguments("git status '&&'"),
        with_dialog("session-one", {}, {}))
      assert.are.equal("git status '&&'", elevated[#elevated])

      value = execute(assert(shell), arguments("git status --porcelain"),
        with_dialog("session-two", { "deny" }, {}))
      assert.is_true(assert(assert(value.details).sandbox).denied_by_user)

      value = execute(assert(shell), arguments("git status --short", false),
        with_dialog("session-one", {}, {}))
      assert.are.equal("restricted", assert(value.content[1]).text)
      assert.are.same({ "git status --short" }, restricted)
    end)

  it("rejects compound or unrelated remembered shell prefixes", function()
    local root = temp()
    local module = require("neoagent.sandbox.escalation")
    local shell = module.new({ shell = "/bin/sh" }):tools({
      require("neoagent.tools.shell").new(),
    })[1]
    local attacks = {
      "git status && rm -rf /tmp/owned",
      "git status || rm -rf /tmp/owned",
      "git status; rm -rf /tmp/owned",
      "git status | sh",
      "git status & rm -rf /tmp/owned",
      "git status\nrm -rf /tmp/owned",
      "git status $(rm -rf /tmp/owned)",
      "git status `rm -rf /tmp/owned`",
      "git status ${IFS}rm",
      [[git status "$HOME"]],
      "git status > /tmp/owned",
      "git status # ignored && rm -rf /tmp/owned",
      "git status (rm -rf /tmp/owned)",
      "git status { rm -rf /tmp/owned; }",
      "git status 'unterminated",
      [[git status "a\q"]],
      [[git status "a\"b"]],
      "git\\ status",
      "git status \\",
      "git status\1hidden",
      string.rep("a", 16385),
      "FOO=bar git status",
      "! git status",
      "coproc git status",
      "npm run",
      "env FOO=bar",
      "cargo build",
      "git status --short extra",
    }
    for index, prefix in ipairs(attacks) do
      local escalation = module.new({ shell = "/bin/sh" })
      shell = escalation:tools({
        require("neoagent.tools.shell").new(),
      })[1]
      local elevated = false
      local execute = escalation:wrap({
        restricted = function() error("restricted") end,
        elevated = function() elevated = true return { content = {} } end,
      })
      local requests = {}
      local replies = {
        "approve_prefix",
        {
          ok = true,
          action = "accept_prefix",
          input = prefix,
        },
        "cancel_prefix",
        "deny",
      }
      local ctx = dialog_context(root, function(request)
        requests[#requests + 1] = request
        return table.remove(replies, 1)
      end)
      ctx.context.session_id = "attack-" .. index
      local value = execute(assert(shell), {
        command = "git status --short",
        options = {
          require_escalation = true,
          escalation_justification = "test unsafe prefix",
        },
      }, ctx)
      assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
      assert.is_false(elevated)
      assert.are.equal(4, #requests)
      assert.matches("cannot be remembered", requests[3].body)
    end

    local escalation = module.new({ shell = "/bin/sh" })
    shell = escalation:tools({
      require("neoagent.tools.shell").new(),
    })[1]
    local elevated = 0
    local execute = escalation:wrap({
      restricted = function() error("restricted") end,
      elevated = function()
        elevated = elevated + 1
        return { content = { { type = "text", text = "ok" } } }
      end,
    })
    local replies = {
      "approve_prefix",
      {
        ok = true,
        action = "accept_prefix",
        input = [[printf "%s" "&&"]],
      },
    }
    local ctx = dialog_context(root, function()
      return table.remove(replies, 1)
    end)
    ctx.context.session_id = "quoted-operator"
    execute(assert(shell), {
      command = [[printf "%s" "&&"]],
      options = {
        require_escalation = true,
        escalation_justification = "test quoted operator",
      },
    }, ctx)
    local remembered_ctx = dialog_context(root, function()
      error("remembered quoted operator unexpectedly prompted")
    end)
    remembered_ctx.context.session_id = "quoted-operator"
    execute(assert(shell), {
      command = [[printf "%s" "&&" ignored]],
      options = {
        require_escalation = true,
        escalation_justification = "test quoted operator",
      },
    }, remembered_ctx)
    assert.are.equal(2, elevated)
  end)

  it("offers cmd and PowerShell leading prefixes without operator tokens",
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      local shell_tool = require("neoagent.tools.shell").new()
      ---@param shell string
      ---@param command string
      ---@return string[]
      local function action_ids(shell, command)
        local escalation = module.new({ shell = shell })
        local tool = escalation:tools({ shell_tool })[1]
        ---@type Neoagent.DialogRequest?
        local request
        local execute = escalation:wrap({
          restricted = function() error("restricted") end,
          elevated = function() error("elevated") end,
        })
        local value = execute(assert(tool), {
          command = command,
          options = {
            require_escalation = true,
            escalation_justification = "test shell parser",
          },
        }, dialog_context(root, function(candidate)
          request = candidate
          return "deny"
        end))
        assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
        return vim.tbl_map(function(action) return action.id end,
          assert(request).actions)
      end
      ---@param shell string
      ---@param command string
      ---@return boolean
      local function supports(shell, command)
        return vim.tbl_contains(action_ids(shell, command),
          "approve_prefix")
      end

      local cmd = [[C:\Windows\System32\cmd.exe]]
      assert.is_true(supports(cmd, "git status --short"))
      assert.is_true(supports(cmd, [[echo "&&"]]))
      for _, command in ipairs({
        "git status && whoami",
        "git status || whoami",
        "git status & whoami",
        "git status > owned.txt",
        "git status (whoami)",
        "git status ^& whoami",
        "git status %COMSPEC%",
        "git status !COMSPEC!",
        [[git status "a\"b"]],
        [[git status "unterminated]],
      }) do
        assert.is_true(supports(cmd, command), command)
      end
      assert.is_false(supports(cmd, "%COMSPEC% /c whoami"))

      local powershell =
        [[C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe]]
      assert.is_true(supports(powershell, "git status --short"))
      assert.is_true(supports(powershell, "Write-Output '&&'"))
      assert.is_true(supports(powershell, [[Write-Output "literal"]]))
      assert.is_true(supports(powershell, "Write-Output 'it''s'"))
      for _, command in ipairs({
        "git status; whoami",
        "git status || whoami",
        "git status | whoami",
        "git status & whoami",
        "git status > owned.txt",
        "git status $(whoami)",
        "git status $env:COMSPEC",
        [[git status "$env:COMSPEC"]],
        "git status `& whoami",
        "git status { whoami }",
        [[git status "unterminated]],
      }) do
        assert.is_true(supports(powershell, command), command)
      end
      assert.is_false(supports(powershell, "$env:COMSPEC /c whoami"))

      assert.is_false(supports("/usr/bin/fish", "git status --short"))
    end)

  it("coalesces remembered prefixes across supported shell parsers", function()
    local root = temp()
    local module = require("neoagent.sandbox.escalation")
    local active_shell = "/bin/sh"
    local escalation = module.new({
      shell = function() return active_shell end,
    })
    local shell = escalation:tools({
      require("neoagent.tools.shell").new(),
    })[1]
    local elevated = {}
    local execute = escalation:wrap({
      restricted = function() error("restricted") end,
      elevated = function(_, arguments)
        elevated[#elevated + 1] = arguments.command
        return { content = { { type = "text", text = "ok" } } }
      end,
    })
    ---@param command string
    ---@param replies (string|Neoagent.DialogResult)[]
    local function run(command, replies)
      local ctx = dialog_context(root, function()
        local reply = table.remove(replies, 1)
        assert.is_not_nil(reply, "unexpected approval prompt")
        return reply
      end)
      ctx.context.session_id = "coalesced"
      local value = execute(assert(shell), {
        command = command,
        options = {
          require_escalation = true,
          escalation_justification = "test rule coalescing",
        },
      }, ctx)
      assert.are.equal("ok", assert(value.content[1]).text)
      assert.are.equal(0, #replies)
    end
    ---@param command string
    ---@param prefix string
    local function remember(command, prefix)
      run(command, {
        "approve_prefix",
        { ok = true, action = "accept_prefix", input = prefix },
      })
    end

    remember("git status --short", "git status --short")
    remember("git status --porcelain", "git status")
    run("git status --branch", {})
    remember("cargo test --lib", "cargo test")
    run("cargo test --doc", {})

    active_shell = "pwsh.exe"
    remember("Write-Output literal", "Write-Output")
    run("Write-Output other", {})
    active_shell = "/bin/sh"
    run("git status --short", {})
    assert.are.equal(8, #elevated)
  end)

  it("remembers any literal prefix while compound commands keep prompting",
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      local escalation = module.new({ shell = "/bin/sh" })
      local shell = escalation:tools({
        require("neoagent.tools.shell").new(),
      })[1]
      local elevated = {}
      local execute = escalation:wrap({
        restricted = function() error("restricted") end,
        elevated = function(_, arguments)
          elevated[#elevated + 1] = arguments.command
          return { content = { { type = "text", text = "elevated" } } }
        end,
      })
      ---@param command string
      ---@param replies (string|Neoagent.DialogResult)[]
      ---@param seen? Neoagent.DialogRequest[]
      ---@return Neoagent.ToolResult
      local function run(command, replies, seen)
        local ctx = dialog_context(root, function(request)
          if seen then seen[#seen + 1] = request end
          local reply = table.remove(replies, 1)
          assert.is_not_nil(reply, "unexpected approval prompt for " .. command)
          return reply
        end)
        ctx.context.session_id = "any-prefix"
        local value = execute(assert(shell), {
          command = command,
          options = {
            require_escalation = true,
            escalation_justification = "test user-chosen prefixes",
          },
        }, ctx)
        assert.are.equal(0, #replies)
        return value
      end
      ---@param request Neoagent.DialogRequest
      ---@return boolean
      local function offered(request)
        return vim.tbl_contains(
          vim.tbl_map(function(action) return action.id end, request.actions),
          "approve_prefix")
      end

      local seen = {}
      local value = run("python3 scripts/report.py --json", {
        "approve_prefix",
        { ok = true, action = "accept_prefix", input = "python3" },
      }, seen)
      assert.are.equal("elevated", assert(value.content[1]).text)
      assert.is_true(offered(seen[1]))

      value = run("python3 tools/cleanup.py", {})
      assert.are.equal("elevated", assert(value.content[1]).text)

      seen = {}
      value = run("python3 tools/cleanup.py && rm -rf /tmp/owned",
        { "deny" }, seen)
      assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
      assert.is_true(offered(seen[1]))

      seen = {}
      value = run("git status && git push", {
        "approve_prefix",
        { ok = true, action = "accept_prefix", input = "git" },
      }, seen)
      assert.are.equal("elevated", assert(value.content[1]).text)
      assert.is_true(offered(seen[1]))
      assert.are.equal("git status && git push", seen[2].input.value)

      value = run("git", {})
      assert.are.equal("elevated", assert(value.content[1]).text)

      value = run("git status --short", {})
      assert.are.equal("elevated", assert(value.content[1]).text)

      value = run("git status; rm -rf /tmp/owned", { "deny" })
      assert.is_true(assert(assert(value.details).sandbox).denied_by_user)

      assert.are.same({
        "python3 scripts/report.py --json",
        "python3 tools/cleanup.py",
        "git status && git push",
        "git",
        "git status --short",
      }, elevated)
    end)

  it("keeps cmd and PowerShell rules and matches free of chaining syntax",
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      ---@param shell_path string
      ---@param session string
      local function harness(shell_path, session)
        local escalation = module.new({ shell = shell_path })
        local tool = escalation:tools({
          require("neoagent.tools.shell").new(),
        })[1]
        local elevated = {}
        local execute = escalation:wrap({
          restricted = function() error("restricted") end,
          elevated = function(_, arguments)
            elevated[#elevated + 1] = arguments.command
            return { content = { { type = "text", text = "elevated" } } }
          end,
        })
        ---@param command string
        ---@param replies (string|Neoagent.DialogResult)[]
        ---@param seen? Neoagent.DialogRequest[]
        ---@return Neoagent.ToolResult
        local function run(command, replies, seen)
          local ctx = dialog_context(root, function(request)
            if seen then seen[#seen + 1] = request end
            local reply = table.remove(replies, 1)
            assert.is_not_nil(reply,
              "unexpected approval prompt for " .. command)
            return reply
          end)
          ctx.context.session_id = session
          local value = execute(assert(tool), {
            command = command,
            options = {
              require_escalation = true,
              escalation_justification = "test chaining boundaries",
            },
          }, ctx)
          assert.are.equal(0, #replies, command)
          return value
        end
        return run, elevated
      end
      ---@param shell_path string
      ---@param session string
      ---@param compound string[]
      ---@param chained_prefix string
      local function check(shell_path, session, compound, chained_prefix)
        local run, elevated = harness(shell_path, session)
        local requests = {}
        local value = run("git status --short", {
          "approve_prefix",
          { ok = true, action = "accept_prefix", input = chained_prefix },
          "cancel_prefix",
          "deny",
        }, requests)
        assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
        assert.matches("cannot be remembered", requests[3].body)
        run("git status --short", {
          "approve_prefix",
          { ok = true, action = "accept_prefix", input = "git status" },
        })
        run("git status --porcelain", {})
        for _, command in ipairs(compound) do
          value = run(command, { "deny" })
          assert.is_true(assert(assert(value.details).sandbox).denied_by_user, command)
        end
        assert.are.same({
          "git status --short",
          "git status --porcelain",
        }, elevated)
      end

      check([[C:\Windows\System32\cmd.exe]], "cmd-chaining", {
        "git status & whoami",
        "git status && whoami",
        "git status | more",
        "git status > owned.txt",
        "git status %COMSPEC%",
        "git status !COMSPEC!",
        "git status ^& whoami",
        "git status\nwhoami",
      }, "git status & whoami")

      check("pwsh.exe", "pwsh-chaining", {
        "git status; whoami",
        "git status | whoami",
        "git status & whoami",
        "git status $(whoami)",
        "git status `; whoami",
        "git status\nwhoami",
      }, "git status; whoami")
    end)

  it("fails closed when command-prefix editing cannot settle", function()
    local root = temp()
    local module = require("neoagent.sandbox.escalation")
    ---@param replies (string|Neoagent.DialogResult)[]
    local function attempt(replies)
      local escalation = module.new({ shell = "/bin/sh" })
      local shell = escalation:tools({
        require("neoagent.tools.shell").new(),
      })[1]
      local execute = escalation:wrap({
        restricted = function() error("restricted") end,
        elevated = function() error("must not elevate") end,
      })
      local ctx = dialog_context(root, function()
        local reply = table.remove(replies, 1)
        assert.is_not_nil(reply, "unexpected approval prompt")
        return reply
      end)
      ctx.context.session_id = "unsettled"
      local value = execute(assert(shell), {
        command = "git status --short",
        options = {
          require_escalation = true,
          escalation_justification = "test failed editor",
        },
      }, ctx)
      assert.is_true(assert(assert(value.details).sandbox).approval_unavailable)
      assert.are.equal(0, #replies)
    end

    attempt({
      "approve_prefix",
      {
        ok = false,
        presenter_unavailable = true,
        error = { kind = "dialog", message = "editor disappeared" },
      },
    })

    ---@type (string|Neoagent.DialogResult)[]
    local invalid = { "approve_prefix" }
    for index = 1, 16 do
      invalid[#invalid + 1] = ({
        ok = true,
        action = "accept_prefix",
        input = index == 1 and true
          or index == 2 and [[git "status\]]
          or "git status && whoami",
      }) --[[@as Neoagent.DialogResult]]
    end
    attempt(invalid)

    local cancelled = {}
    for _ = 1, 16 do
      cancelled[#cancelled + 1] = "approve_prefix"
      cancelled[#cancelled + 1] = "cancel_prefix"
    end
    attempt(cancelled)
  end)

  it("validates escalation schemas, requests, and presenter failures", function()
    local root = temp()
    local function tool(schema)
      return {
        name = "custom",
        description = "custom",
        input_schema = schema or {
          type = "object",
          properties = {},
          additionalProperties = false,
        },
        execute = function() error("tool must not run") end,
      }
    end
    local module = require("neoagent.sandbox.escalation")
    local transform = module.new()
    assert.has_error(function()
      transform:tools({ tool({
        type = "object",
        properties = { options = { type = "string" } },
      }) })
    end, "tool options schema must be object-valued for custom")
    assert.has_error(function()
      transform:tools({ tool({
        type = "object",
        properties = {
          options = {
            type = "object",
            properties = {
              require_escalation = { type = "boolean" },
            },
          },
        },
      }) })
    end,
      "tool options schema reserves require_escalation for sandbox escalation in custom")
    assert.has_error(function()
      transform:tools({ tool({
        type = "object",
        properties = { "not", "an", "object" },
      }) })
    end, "tool input_schema.properties must be an object for custom")
    assert.has_error(function()
      transform:tools({ tool({
        type = "object",
        properties = {
          options = {
            type = "object",
            properties = { "not", "an", "object" },
          },
        },
      }) })
    end, "tool options properties must be an object for custom")

    local transformed = transform:tools({ tool() })[1]
    local calls = 0
    local execute = transform:wrap({
      restricted = function(_, arguments)
        calls = calls + 1
        return {
          content = { {
            type = "text",
            text = arguments.options and "options" or "restricted",
          } },
        }
      end,
      elevated = function()
        calls = calls + 1
        return { content = { { type = "text", text = "elevated" } } }
      end,
    })
    local value = execute(assert(transformed), {}, context(root))
    assert.are.equal("restricted", assert(value.content[1]).text)
    value = execute(assert(transformed), { options = {} }, context(root))
    assert.are.equal("restricted", assert(value.content[1]).text)
    for _, arguments in ipairs({
      "invalid",
      { options = "invalid" },
      {
        options = {
          require_escalation = false,
          escalation_justification = "reason",
        },
      },
      {
        options = {
          require_escalation = true,
          escalation_justification = string.rep("x", 1001),
        },
      },
    }) do
      value = execute(assert(transformed), arguments --[[@as Neoagent.JsonObject]], context(root))
      assert.is_true(assert(assert(value.details).sandbox).invalid_escalation)
    end

    local pending = async.run(function()
      return async.await(function() return function() end end)
    end)
    value = module.new():wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })(assert(transformed), {
      options = {
        require_escalation = true,
        escalation_justification = "reason",
      },
    }, dialog_context(root, function() return pending end))
    assert.is_true(assert(assert(value.details).sandbox).approval_unavailable)
    assert.is_true(pending:is_cancelled())

    for _, decision in ipairs({
      function() return "invalid" end,
      function() error("presenter failed") end,
      function()
        return {
          ok = false,
          presenter_unavailable = true,
          error = util.error("dialog", "presenter detached"),
        }
      end,
      function()
        return async.run(function()
          return {
            ok = false,
            error = util.error("dialog", "presenter missing"),
          }
        end)
      end,
    }) do
      value = module.new():wrap({
        restricted = function() error("restricted") end,
        elevated = function() error("elevated") end,
      })(assert(transformed), {
        options = {
          require_escalation = true,
          escalation_justification = "reason",
        },
      }, dialog_context(root, decision))
      assert.is_true(assert(assert(value.details).sandbox).approval_unavailable)
    end

    value = module.new():wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })(assert(transformed), {
      options = {
        require_escalation = true,
        escalation_justification = "reason",
      },
    }, dialog_context(root, function()
      return { ok = true, action = "deny" }
    end))
    assert.is_true(assert(assert(value.details).sandbox).denied_by_user)

    local approval_arguments = {
      options = {
        require_escalation = true,
        escalation_justification = "reason",
      },
    }
    value = execute(assert(transformed), approval_arguments,
      dialog_context(root, function() return true end))
    assert.are.equal("elevated", assert(value.content[1]).text)
    value = execute(assert(transformed), approval_arguments,
      dialog_context(root, function() return false end))
    assert.is_true(assert(assert(value.details).sandbox).denied_by_user)

    local failed_shell = module.new({
      shell = function() error("shell lookup failed") end,
    })
    local failed_shell_tool = failed_shell:tools({
      require("neoagent.tools.shell").new(),
    })[1]
    value = failed_shell:wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })(assert(failed_shell_tool), {
      command = "git status",
      options = approval_arguments.options,
    },
      dialog_context(root, function() return "deny" end))
    assert.is_true(assert(assert(value.details).sandbox).denied_by_user)

    assert.has_error(function()
      module.new():wrap({
        restricted = function() error("restricted") end,
        elevated = function() error("elevated failed") end,
      })(assert(transformed), approval_arguments,
        dialog_context(root, function() return true end))
    end, "elevated failed")

    ---@type Neoagent.DialogRequest?
    local summarized
    local summary_transform = module.new({
      summarize = function()
        error("summary failed")
      end,
    })
    local summary_tool = summary_transform:tools({ tool() })[1]
    local summary_execute = summary_transform:wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })
    value = summary_execute(assert(summary_tool), {
      options = {
        require_escalation = true,
        escalation_justification = "bad\0reason",
      },
    }, dialog_context(root, function(request)
      summarized = request
      return "deny"
    end))
    assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
    assert.matches("current arguments", assert(summarized).body)
    assert.matches("\\x00", assert(summarized).body, 1, true)

    local long_summary = module.new({
      summarize = function() return string.rep("s", 2100) end,
    })
    local long_tool = long_summary:tools({ tool() })[1]
    value = long_summary:wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })(assert(long_tool), approval_arguments,
      dialog_context(root, function(request)
        summarized = request
        return "deny"
      end))
    assert.is_true(assert(assert(value.details).sandbox).denied_by_user)
    assert.is_true(assert(summarized).body:find(
      string.rep("s", 1997) .. "...", 1, true
    ) ~= nil)

    local escalation_arguments = {
      options = {
        require_escalation = true,
        escalation_justification = "reason",
      },
    }
    local incomplete = context(root)
    rawset(incomplete, "dialog", {
      show = function() return "approve" end,
    })
    value = execute(assert(transformed), escalation_arguments, incomplete)
    assert.is_true(assert(assert(value.details).sandbox).approval_unavailable)

    for _, choose_pending in ipairs({
      function() error("bulk action failed") end,
      function()
        return nil, util.error("dialog", "bulk action unavailable")
      end,
    }) do
      value = execute(assert(transformed), escalation_arguments,
        dialog_context(root, function() return "deny_all" end,
          choose_pending))
      assert.is_true(assert(assert(value.details).sandbox).approval_unavailable)
    end
    value = execute(assert(transformed), escalation_arguments,
      dialog_context(root, function() return "deny_all" end,
        function(_, action, reason)
          assert.are.equal("deny", action)
          assert.matches("another sandbox request", (assert(reason)))
          return 2
        end))
    assert.is_true(assert(assert(value.details).sandbox).denied_by_user)

    local source = require("neoagent.dialog").new()
    local detach = source:subscribe(function() end)
    local composed = module.new():wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })
    local run = async.run(function()
      return composed(assert(transformed), {
        options = {
          require_escalation = true,
          escalation_justification = "reason",
        },
      }, dialog_context(root, function(request)
        return source:show(request)
      end, function(_, action, reason)
        return source:choose_pending(action, reason)
      end))
    end)
    assert(vim.wait(1000, function()
      return source:snapshot().active ~= nil
    end, 5))
    detach()
    assert(vim.wait(1000, function() return run:is_done() end, 5))
    assert.is_true(
      assert(assert(assert(run:result()).details).sandbox).approval_unavailable)
    assert.is_false(
      assert(assert(assert(run:result()).details).sandbox).denied_by_user == true)
    assert.are.equal(3, calls)
  end)

  it("summarizes every bundled tool without exposing write contents", function()
    local summarize =
      require("neoagent.sandbox.approval_summary").for_tool
    local ctx = context(temp())
    local cases = {
      shell = { command = "printf test" },
      read_file = { path = "input.txt" },
      write_file = {
        path = "output.txt",
        content = "private contents",
      },
      edit_file = {
        path = "output.txt",
        edits = { { oldText = "a", newText = "b" } },
      },
      grep = { pattern = "needle" },
      find = { pattern = "*.lua" },
      read_agent_documentation = {},
    }
    for name, arguments in pairs(cases) do
      local summary = summarize({ name = name, description = "Probe summary", input_schema = { type = "object", properties = {} } }, arguments, ctx)
      assert.is_string(summary)
      assert.is_true(summary ~= "")
      assert.is_nil((summary:find("private contents", 1, true)))
    end
    assert.matches("custom",
      summarize({ name = "custom", description = "Probe summary", input_schema = { type = "object", properties = {} } }, {}, ctx))
  end)
end)
