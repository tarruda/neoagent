local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local function temporary_directory()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return assert(vim.uv.fs_realpath(path))
end

local function workspace(root)
  return require("neoagent.workspace").new({ root = root, cwd = root })
end

local function context(root)
  return { context = { workspace = workspace(root), agent = "Neo" } }
end

local function dialog_context(root, show, choose_pending)
  local ctx = context(root)
  ctx.dialog = {
    show = function(_, request) return show(request) end,
    choose_pending = choose_pending or function() return 0 end,
  }
  return ctx
end

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

local function complete(fn)
  local run = async.run(fn)
  assert(vim.wait(1000, function() return run:is_done() end, 5))
  return run:result()
end

describe("neoagent sandbox composition", function()
  local paths = {}

  after_each(function()
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
      require("neoagent.config").resolve({ sandbox = false })
    end, "sandbox must be a table")
    assert.has_error(function()
      require("neoagent.config").resolve({
        sandbox = { enabled = "yes" },
      })
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
    assert.are.equal("write", normalized.filesystem.entries[1].access)
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
    invalid.filesystem.entries[1].path = link
    local ok, err = pcall(function()
      require("neoagent.sandbox.profile").validate(invalid)
    end)
    assert.is_false(ok)
    assert.matches("must use a canonical path", err.message)
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
    invalid.filesystem.entries[1].path = "/"
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
    assert.are.equal(alpha, normalized.filesystem.entries[1].path)
    assert.are.equal(bravo, normalized.filesystem.entries[2].path)

    local granted = policy.access({
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
        return existing[key] and { type = "directory" } or nil
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
    assert.are.equal("write", normalized.filesystem.entries[1].access)
    assert.are.equal("read", normalized.filesystem.entries[2].access)

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
    local linux, macos, windows = {}, {}, {}
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
    assert.is_false(status.ok)
    assert.matches("unsupported platform",
      dispatch.status_error(status).message)
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
              text = ctx.process and "restricted" or "host",
            } },
          }
        end,
      } },
      _tools_supplied = true,
    }
    local checked = 0
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
    assert.is_table(toolset.tools[1].input_schema.properties.options)
    assert.is_nil(original.tools[1].input_schema.properties.options)

    local composed, dialogs =
      composition.agent(original, { platform = platform })
    assert.are.equal(1, checked)
    assert.is_table(dialogs)
    assert.are.equal("custom", composed.tools[1].name)
    assert.is_table(
      composed.tools[1].input_schema.properties.options)
    assert.is_nil(
      original.tools[1].input_schema.properties.options)
    local value = composed.execute_tool(
      composed.tools[1], {}, context(root))
    assert.are.equal("restricted", value.content[1].text)

    local disabled = util.copy(original)
    disabled.sandbox.enabled = false
    local untouched, broker =
      require("neoagent.sandbox.composition").agent(
        disabled, { platform = platform })
    assert.is_nil(broker)
    assert.are.equal(original.tools[1].execute,
      untouched.tools[1].execute)
    assert.are.equal(1, checked)

    local dispatch_module = package.loaded["neoagent.sandbox.platform"]
    package.loaded["neoagent.sandbox.platform"] = {
      select = function()
        return platform, { ok = true, platform = "test" }
      end,
    }
    local selected_ok, selected_value = pcall(
      require("neoagent.sandbox.composition").agent, original)
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
              text = ctx.process and "restricted" or "host",
            } },
          }
        end,
      } },
      _tools_supplied = true,
    }
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
    assert.is_string(toolset.system_prompt)
    assert.matches("Sandboxed execution", toolset.system_prompt)
    assert.matches("native test sandbox", toolset.system_prompt)
    assert.matches("require_escalation", toolset.system_prompt)
    assert.matches("denial", toolset.system_prompt)

    local composed = composition.agent(original, {
      platform = platform,
    })
    assert.are.equal(toolset.system_prompt,
      composed._sandbox_system_prompt)

    local disabled = util.copy(original)
    disabled.sandbox.enabled = false
    local untouched =
      composition.agent(disabled, { platform = platform })
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
          text = ctx.process and "sandbox" or "host",
        } } }
      end,
    }
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
    local execute = stable.execute_tool
    assert.is_false(status.enabled)
    assert.are.equal(0, checks)
    local value = execute(stable.tools[1], { options = {
      require_escalation = true,
      escalation_justification = "inspect host execution",
    } }, context(root))
    assert.are.equal("host", value.content[1].text)

    status = assert(runtime:set_enabled(true))
    assert.is_true(status.active)
    assert.are.equal(1, checks)
    value = execute(stable.tools[1], {}, context(root))
    assert.are.equal("sandbox", value.content[1].text)

    status = assert(runtime:set_enabled(false))
    assert.is_false(status.enabled)
    value = execute(stable.tools[1], {}, context(root))
    assert.are.equal("host", value.content[1].text)
    assert(runtime:set_enabled(true))
    assert.are.equal(1, checks)
    assert.are.equal(execute, stable.execute_tool)
    assert.are.same(original_tools, stable.tools)
  end)

  it("publishes a failed activation warning for Agent presentation", function()
    local configured = {
      name = "Neo",
      sandbox = { enabled = true },
      tools = {},
      _tools_supplied = true,
    }
    local composed, broker =
      require("neoagent.sandbox.composition").agent(configured, {
        status = {
          ok = false,
          stage = "probe",
          message = "native support is unavailable",
        },
      })
    assert.is_nil(broker)
    assert.is_string(composed._sandbox_warning)
    assert.matches("tools will run without a sandbox",
      composed._sandbox_warning)
  end)

  it("merges profile tables and calls profile callbacks with defaults", function()
    local root = temp()
    local composition = require("neoagent.sandbox.composition")
    local defaults = composition.default_profile(context(root))
    assert.are.equal(root,
      defaults.filesystem.entries[1].path)
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
      temporary_err.message)

    local seen
    local platform = {
      name = "test",
      check = function() return { ok = true } end,
      fs = function() return "contents" end,
      exec = function()
        return {
          code = 0, signal = 0, stdout = "", stderr = "",
          output = "", timed_out = false,
        }
      end,
    }
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
      _tools_supplied = true,
    }
    local composed = composition.agent(
      configured, { platform = platform })
    assert.is_true(composed._sandbox_status.active)
    local value = composed.execute_tool(
      composed.tools[1], { path = "file" }, context(root))
    assert.are.equal("contents", value.content[1].text)
    assert.are.equal("enabled", seen.default.network)
    assert.are.equal(root,
      seen.ctx.context.workspace.root)

    configured.sandbox.profile = { network = "enabled" }
    configured.tools = { {
      name = "process",
      description = "process",
      input_schema = {
        type = "object",
        properties = {},
        additionalProperties = false,
      },
      execute = function(_, ctx)
        ctx.process({ "true" }, { cwd = root })
        return { content = { { type = "text", text = "ok" } } }
      end,
    } }
    platform.exec = function(request)
      assert.are.equal("enabled", request.profile.network)
      return {
        code = 0, signal = 0, stdout = "", stderr = "",
        output = "", timed_out = false,
      }
    end
    composed = composition.agent(
      configured, { platform = platform })
    value = composed.execute_tool(
      composed.tools[1], {}, context(root))
    assert.are.equal("ok", value.content[1].text)

    local ok, err = pcall(function()
      composition.default_profile({})
    end)
    assert.is_false(ok)
    assert.are.equal("Sandbox requires a workspace root", err.message)
    local failed = composition.agent(configured, {
      platform = {
        name = "broken",
        check = function() error("probe exploded") end,
      },
    })
    assert.is_false(failed._sandbox_status.active)
    assert.are.equal("requirements", failed._sandbox_status.stage)
    assert.is_string(failed._sandbox_warning)
  end)

  it("keeps a root workspace bounded to shared temporary writes", function()
    local seen_profile
    local composed = require("neoagent.sandbox.composition").agent({
      name = "Root",
      sandbox = { enabled = true },
      tools = { require("neoagent.tools.read_file").new() },
      _tools_supplied = true,
    }, {
      platform = {
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
    local value = composed.execute_tool(
      composed.tools[1], { path = "/etc/hosts" }, context("/"))
    assert.are.equal("root-readable", value.content[1].text)
    assert.are.equal("read", seen_profile.filesystem.default)
    local allowed_writes = {
      [vim.uv.fs_realpath(vim.uv.os_tmpdir())] = true,
      [vim.uv.fs_realpath("/tmp")] = true,
    }
    for _, entry in ipairs(seen_profile.filesystem.entries) do
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
    local protocol = require("neoagent.sandbox.linux.protocol")
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
    assert.matches("precedes ready", invalid_err)
    local events, err = protocol.decode_all("\255\255\255\255")
    assert.is_nil(events)
    assert.matches("frame length", err)

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
    assert.are.equal(155, abi.current("x64").pivot_root)
    assert.are.equal(41, abi.current("arm64").pivot_root)
    local seccomp = require("neoagent.sandbox.linux.seccomp")
    local restricted = seccomp.rules("x64", "restricted")
    assert.are.equal(41, restricted.socket)
    assert.are.equal(53, restricted.socketpair)
    assert.are.equal(56, restricted.clone)
    assert.are.equal(435, restricted.clone3)
    assert.is_false(vim.list_contains(restricted.deny, restricted.clone3))
    assert.are.equal(0x7e020080, restricted.namespace_flags)
    assert.is_true(vim.list_contains(restricted.network_deny, 42))
    assert.is_true(vim.list_contains(restricted.network_deny, 307))
    assert.is_nil(seccomp.rules("x64", "enabled").socket)
    assert.is_nil(seccomp.rules("x64", "enabled").socketpair)
    assert.is_nil(seccomp.rules("x64", "enabled").network_deny)
    local arm = seccomp.rules("arm64", "restricted")
    assert.are.equal(198, arm.socket)
    assert.are.equal(199, arm.socketpair)
    assert.is_true(vim.list_contains(arm.network_deny, 203))
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
    assert.is_nil(policy:find(root, 1, true))
    assert.is_nil(policy:find("network-outbound", 1, true))
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
      compiler.compile(enabled))

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
    assert.are.equal(alpha, ordered[2].value)
    assert.are.equal(bravo, ordered[3].value)
  end)
end)

describe("neoagent sandbox execution", function()
  local paths = {}

  after_each(function()
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
      platform = {
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
    assert.are.equal(1, value.details.exit_code)
    assert.is_nil(value.details.sandbox)
    assert.are.equal(
      "[Command exited with status 1]\n(no output)",
      value.content[1].text)

    local expected = {
      content = { { type = "image", data = "ordinary-error" } },
      is_error = true,
      details = { exit_code = 1, source = "command" },
    }
    local custom = box:wrap()({
      execute = function(_, ctx)
        local process_result =
          ctx.process({ "grep" }, { cwd = root })
        assert.are.equal(1, process_result.code)
        return expected
      end,
    }, {}, context(root))
    assert.are.same(expected, custom)

    local no_matches = box:wrap()(
      require("neoagent.tools.grep").new(),
      { pattern = "missing" },
      context(root))
    assert.is_nil(no_matches.isError)
    assert.are.equal("No matches found", no_matches.content[1].text)
  end)

  it("classifies likely sandbox denials from bounded process evidence",
    function()
      local root = temp()
      local responses = {}
      local streamed = {}
      local box = require("neoagent.sandbox.enforce").new({
        platform = {
          name = "linux",
          fs = function() return true end,
          exec = function(request)
            local response = assert(responses[request.argv[1]])
            if response.stdout_stream then
              request.on_output(response.stdout_stream, false)
            end
            if response.stream then
              request.on_output(response.stream, true)
              streamed[#streamed + 1] = response.stream
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
      local function execute(name, returned, throws)
        return box:wrap()({
          execute = function(_, ctx)
            local process_result = ctx.process({ name }, {
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
          end,
        }, {}, context(root))
      end
      local function assert_restricted(value)
        assert.is_true(value.isError or value.is_error)
        assert.is_true(value.details.sandbox.ran_restricted)
        assert.matches("blocked by the sandbox",
          value.content[1].text, 1, true)
      end
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
        item.code = 1
        responses[item.name] = item
        assert_restricted(execute(item.name))
      end
      assert.are.same({ "Permission denied" }, streamed)

      responses.image = {
        code = 127,
        stderr = "Permission denied",
      }
      local image = execute("image", {
        content = { { type = "image", data = "bytes" } },
        details = { source = "custom" },
        is_error = true,
      })
      assert_restricted(image)
      assert.are.equal("custom", image.details.source)
      assert.are.equal("image", image.content[2].type)

      responses.thrown = {
        code = 1,
        stderr = "operation not permitted",
      }
      local thrown = execute("thrown", nil, true)
      assert_restricted(thrown)
      assert.matches("tool rejected status 1",
        thrown.content[1].text, 1, true)

      responses.cancelled = {
        code = 1,
        stderr = "operation not permitted",
      }
      local cancel_execute = box:wrap()
      local completed, cancelled = pcall(cancel_execute, {
        execute = function(_, ctx)
          ctx.process({ "cancelled" }, { cwd = root })
          error({ kind = "cancelled", message = "cancelled" }, 0)
        end,
      }, {}, context(root))
      assert.is_false(completed)
      assert.are.equal("cancelled", cancelled.kind)

      for _, code in ipairs({ 2, 126, 127 }) do
        local name = "ordinary-" .. code
        responses[name] = { code = code, stderr = "command not found" }
        local ordinary = execute(name)
        assert.is_nil(ordinary.details.sandbox)
        assert.are.equal(name, ordinary.content[1].text)
      end

      responses.success = {
        code = 0,
        stderr = "operation not permitted",
      }
      local success = execute("success")
      assert.is_nil(success.details.sandbox)

      responses.bounded = {
        code = 1,
        stream = string.rep("x", 1024 * 1024) .. "permission denied",
      }
      local bounded = execute("bounded")
      assert.is_nil(bounded.details.sandbox)

      responses.contention = {
        code = 1,
        stdout_stream = string.rep("x", 1024 * 1024),
        stream = "permission denied",
      }
      assert_restricted(execute("contention"))

      local sigsys = vim.uv.constants and vim.uv.constants.SIGSYS
      if sigsys then
        responses.sigsys = { code = 128 + sigsys, signal = sigsys }
        assert_restricted(execute("sigsys"))
      end
    end)

  it("enforces filesystem, process, environment, and capability lifetime", function()
    local root = temp()
    local protected = vim.fs.joinpath(root, ".git")
    assert.are.equal(1, vim.fn.mkdir(protected, "p"))
    local calls, retained = {}, {}
    local platform = {
      name = "test",
      fs = function(request)
        calls[#calls + 1] = request
        if request.operation == "read" then return "read:" .. request.path end
        return true
      end,
      exec = function(request)
        calls[#calls + 1] = request
        if request.on_output then request.on_output("chunk", false) end
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
      retained.fs, retained.process = ctx.fs, ctx.process
      return tool.execute(arguments, ctx)
    end)
    local read = {
      execute = function(arguments, ctx)
        return {
          content = { {
            type = "text",
            text = assert(ctx.fs.read(arguments.path)),
          } },
        }
      end,
    }
    local value = execute(read, { path = "file" }, context(root))
    assert.matches(root, value.content[1].text, 1, true)
    value = execute({
      execute = function(_, ctx)
        assert(ctx.fs.atomic_replace(root .. "/file", "changed", {
          preserve_mode = true,
          new_mode = 420,
        }))
        return { content = { { type = "text", text = "replaced" } } }
      end,
    }, {}, context(root))
    assert.are.equal("replaced", value.content[1].text)
    local replacement = calls[#calls]
    assert.are.equal("atomic_replace", replacement.operation)
    assert.are.equal("changed", replacement.data)
    assert.are.same({ preserve_mode = true, new_mode = 420 },
      replacement.policy)
    assert.are.equal(32, #replacement.suffix)
    local denied = execute({
      execute = function(_, ctx)
        ctx.fs.write_all(protected .. "/config", "x")
      end,
    }, {}, context(root))
    assert.is_true(denied.isError)
    assert.is_true(denied.details.sandbox.denied)
    assert.matches("require_escalation", denied.content[1].text)

    local updates = {}
    local failed = execute({
      execute = function(_, ctx)
        local result = ctx.process({ "fail", "" }, {
          cwd = root,
          on_output = function(data) updates[#updates + 1] = data end,
        })
        return {
          content = { { type = "text", text = "failed" } },
          isError = result.code ~= 0,
        }
      end,
    }, {}, context(root))
    assert.are.same({ "chunk" }, updates)
    assert.is_true(failed.isError)
    assert.are.equal("failed", failed.content[1].text)
    assert.is_nil(failed.details)
    assert.has_error(function()
      execute({
        execute = function(_, ctx)
          local process_result = ctx.process({ "fail" }, { cwd = root })
          error("native tool rejected status " .. process_result.code)
        end,
      }, {}, context(root))
    end, "native tool rejected status 2")
    local process_request = calls[#calls]
    assert.are.same({ PATH = "/bin", TEST_SANDBOX = "yes" },
      process_request.env)
    assert.has_error(function() retained.fs.read(root) end)
    assert.has_error(function()
      retained.fs.atomic_replace(root .. "/file", "late", {
        preserve_mode = true, new_mode = 420,
      })
    end)
    assert.has_error(function() retained.process({ "true" }) end)
  end)

  it("fails closed for malformed capabilities and backend failures", function()
    local root = temp()
    local temporary = vim.fs.joinpath(root, "spill")
    local raw_calls = {}
    local raw_fs = {
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
    local platform = {
      name = "test",
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
      execute = function(_, ctx)
        local path = assert(ctx.fs.create_temp("spill-"))
        assert(ctx.fs.write_all(path, "data", "a", 384))
        assert(ctx.fs.atomic_replace(path, "replacement", {
          preserve_mode = true, new_mode = 420,
        }))
        assert.are.equal("temporary", ctx.fs.read(path))
        assert(ctx.fs.mkdirp(vim.fs.joinpath(root, "directory")))
        return { content = { { type = "text", text = "ok" } } }
      end,
    }, {}, context(root))
    assert.are.equal("ok", value.content[1].text)
    assert.are.same({
      "create_temp:" .. root,
      "write:" .. temporary,
      "replace:" .. temporary,
      "read:" .. temporary,
      "platform:mkdirp",
    }, raw_calls)

    local calls_before_escape = #raw_calls
    value = execute({
      execute = function(_, ctx)
        ctx.fs.create_temp("../outside-")
        return { content = { { type = "text", text = "escaped" } } }
      end,
    }, {}, context(root))
    assert.is_true(value.isError)
    assert.is_true(value.details.sandbox.unavailable)
    assert.are.equal(calls_before_escape, #raw_calls)

    local process_tool = {
      execute = function(arguments, ctx)
        ctx.process(arguments.argv, arguments.opts)
        return { content = { { type = "text", text = "unexpected" } } }
      end,
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
      assert.is_true(value.details.sandbox.unavailable)
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
    assert.is_true(value.details.sandbox.denied)

    platform.exec = function() return {} end
    value = execute(process_tool, {
      argv = { "true" },
      opts = { cwd = root },
    }, context(root))
    assert.is_true(value.details.sandbox.unavailable)

    platform.exec = function()
      error(util.error("sandbox_unavailable", "backend unavailable"), 0)
    end
    value = execute(process_tool, {
      argv = { "true" },
      opts = { cwd = root },
    }, context(root))
    assert.matches("backend unavailable", value.content[1].text)

    local dynamic = require("neoagent.sandbox.enforce").new({
      platform = platform,
      profile = function() error("profile failed") end,
    }):wrap()
    value = dynamic({ execute = function() end }, {}, context(root))
    assert.is_true(value.details.sandbox.unavailable)

    platform.exec = function()
      return {
        code = 0, signal = 0, stdout = "", stderr = "",
        output = "", timed_out = false,
      }
    end
    assert.has_error(function()
      execute({ execute = function() error("ordinary failure") end },
        {}, context(root))
    end, "ordinary failure")
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
      execute = function() end,
    }
    local seen, retained_fs, retained_process, approval
    local escalation = require("neoagent.sandbox.escalation").new({
      fs = {
        read = function(path) return "host:" .. path end,
        create_temp = fs.create_temp,
        mkdirp = fs.mkdirp,
        write_all = fs.write_all,
      },
      process = function()
        return { code = 0, signal = 0 }
      end,
    })
    local approved_ctx = dialog_context(root, function(value)
      approval = value
      return "approve"
    end)
    local transformed = escalation:tools({ tool })
    assert.is_nil(
      tool.input_schema.properties.options.properties.require_escalation)
    assert.is_table(transformed[1].input_schema.properties.options
      .properties.require_escalation)
    local execute = escalation:wrap({
      restricted = function() error("restricted path ran") end,
      elevated = function(_, arguments, ctx)
        seen = arguments
        retained_fs = ctx.fs
        retained_process = ctx.process
        local process_value = ctx.process({ "true" })
        return {
          content = { {
            type = "text",
            text = ctx.fs.read(arguments.path)
              .. ":" .. tostring(process_value.code),
          } },
        }
      end,
    })
    local value = execute(
      transformed[1], original_arguments, approved_ctx)
    assert.are.equal("host:file:0", value.content[1].text)
    assert.are.same({ path = "file", options = { native = "keep" } },
      seen)
    assert.is_true(original_arguments.options.require_escalation)
    assert.are.equal("transcript", approval.placement)
    assert.matches("Tool: custom", approval.body)
    assert.matches("needed for this test", approval.body)
    assert.are.same({
      { id = "approve", label = "approve", key = "y" },
      { id = "deny", label = "deny", key = "n" },
      { id = "deny_all", label = "deny all pending", key = "N" },
    }, approval.actions)
    assert.has_error(function() retained_fs.read("later") end)
    assert.has_error(function() retained_process({ "true" }) end)

    local malformed = execute(transformed[1], {
      options = { require_escalation = true },
    }, context(root))
    assert.is_true(malformed.details.sandbox.invalid_escalation)

    local denied = require("neoagent.sandbox.escalation").new():wrap({
      restricted = function() error("restricted path ran") end,
      elevated = function() error("elevated path ran") end,
    })(transformed[1], original_arguments,
      dialog_context(root, function() return "deny" end))
    assert.is_true(denied.details.sandbox.denied_by_user)
  end)

  it("renders shell approval commands separately from agent justification",
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      local shell = module.new():tools({
        require("neoagent.tools.shell").new(),
      })[1]
      local request
      local execute = module.new():wrap({
        restricted = function() error("restricted") end,
        elevated = function() error("elevated") end,
      })
      local value = execute(shell, {
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
      assert.is_true(value.details.sandbox.denied_by_user)
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
      }, "\n"), request.body)
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
      local value = execute(shell, arguments("git status --short"),
        with_dialog("session-one", {
          "approve_prefix",
          {
            ok = true,
            action = "accept_prefix",
            input = "git status",
          },
        }, seen))
      assert.are.equal("elevated", value.content[1].text)
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

      execute(shell, arguments("git status --porcelain"),
        with_dialog("session-one", {}, {}))
      assert.are.same({
        "git status --short",
        "git status --porcelain",
      }, elevated)

      local prompted = {}
      value = execute(shell, arguments("git status-danger"),
        with_dialog("session-one", { "deny" }, prompted))
      assert.is_true(value.details.sandbox.denied_by_user)
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
        value = execute(shell, arguments(command),
          with_dialog("session-one", { "deny" }, prompted))
        assert.is_true(value.details.sandbox.denied_by_user)
        assert.is_true(vim.tbl_contains(
          vim.tbl_map(function(action) return action.id end,
            prompted[#prompted].actions), "approve_prefix"), command)
      end

      prompted = {}
      value = execute(shell, arguments("$(whoami) --version"),
        with_dialog("session-one", { "deny" }, prompted))
      assert.is_true(value.details.sandbox.denied_by_user)
      assert.is_false(vim.tbl_contains(
        vim.tbl_map(function(action) return action.id end,
          prompted[#prompted].actions), "approve_prefix"))

      execute(shell, arguments("git status '&&'"),
        with_dialog("session-one", {}, {}))
      assert.are.equal("git status '&&'", elevated[#elevated])

      value = execute(shell, arguments("git status --porcelain"),
        with_dialog("session-two", { "deny" }, {}))
      assert.is_true(value.details.sandbox.denied_by_user)

      value = execute(shell, arguments("git status --short", false),
        with_dialog("session-one", {}, {}))
      assert.are.equal("restricted", value.content[1].text)
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
        elevated = function() elevated = true end,
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
      local value = execute(shell, {
        command = "git status --short",
        options = {
          require_escalation = true,
          escalation_justification = "test unsafe prefix",
        },
      }, ctx)
      assert.is_true(value.details.sandbox.denied_by_user)
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
    execute(shell, {
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
    execute(shell, {
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
      local function action_ids(shell, command)
        local escalation = module.new({ shell = shell })
        local tool = escalation:tools({ shell_tool })[1]
        local request
        local execute = escalation:wrap({
          restricted = function() error("restricted") end,
          elevated = function() error("elevated") end,
        })
        local value = execute(tool, {
          command = command,
          options = {
            require_escalation = true,
            escalation_justification = "test shell parser",
          },
        }, dialog_context(root, function(candidate)
          request = candidate
          return "deny"
        end))
        assert.is_true(value.details.sandbox.denied_by_user)
        return vim.tbl_map(function(action) return action.id end,
          request.actions)
      end
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
    local function run(command, replies)
      local ctx = dialog_context(root, function()
        local reply = table.remove(replies, 1)
        assert.is_not_nil(reply, "unexpected approval prompt")
        return reply
      end)
      ctx.context.session_id = "coalesced"
      local value = execute(shell, {
        command = command,
        options = {
          require_escalation = true,
          escalation_justification = "test rule coalescing",
        },
      }, ctx)
      assert.are.equal("ok", value.content[1].text)
      assert.are.equal(0, #replies)
    end
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
      local function run(command, replies, seen)
        local ctx = dialog_context(root, function(request)
          if seen then seen[#seen + 1] = request end
          local reply = table.remove(replies, 1)
          assert.is_not_nil(reply, "unexpected approval prompt for " .. command)
          return reply
        end)
        ctx.context.session_id = "any-prefix"
        local value = execute(shell, {
          command = command,
          options = {
            require_escalation = true,
            escalation_justification = "test user-chosen prefixes",
          },
        }, ctx)
        assert.are.equal(0, #replies)
        return value
      end
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
      assert.are.equal("elevated", value.content[1].text)
      assert.is_true(offered(seen[1]))

      value = run("python3 tools/cleanup.py", {})
      assert.are.equal("elevated", value.content[1].text)

      seen = {}
      value = run("python3 tools/cleanup.py && rm -rf /tmp/owned",
        { "deny" }, seen)
      assert.is_true(value.details.sandbox.denied_by_user)
      assert.is_true(offered(seen[1]))

      seen = {}
      value = run("git status && git push", {
        "approve_prefix",
        { ok = true, action = "accept_prefix", input = "git" },
      }, seen)
      assert.are.equal("elevated", value.content[1].text)
      assert.is_true(offered(seen[1]))
      assert.are.equal("git status && git push", seen[2].input.value)

      value = run("git", {})
      assert.are.equal("elevated", value.content[1].text)

      value = run("git status --short", {})
      assert.are.equal("elevated", value.content[1].text)

      value = run("git status; rm -rf /tmp/owned", { "deny" })
      assert.is_true(value.details.sandbox.denied_by_user)

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
        local function run(command, replies, seen)
          local ctx = dialog_context(root, function(request)
            if seen then seen[#seen + 1] = request end
            local reply = table.remove(replies, 1)
            assert.is_not_nil(reply,
              "unexpected approval prompt for " .. command)
            return reply
          end)
          ctx.context.session_id = session
          local value = execute(tool, {
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
      local function check(shell_path, session, compound, chained_prefix)
        local run, elevated = harness(shell_path, session)
        local requests = {}
        local value = run("git status --short", {
          "approve_prefix",
          { ok = true, action = "accept_prefix", input = chained_prefix },
          "cancel_prefix",
          "deny",
        }, requests)
        assert.is_true(value.details.sandbox.denied_by_user)
        assert.matches("cannot be remembered", requests[3].body)
        run("git status --short", {
          "approve_prefix",
          { ok = true, action = "accept_prefix", input = "git status" },
        })
        run("git status --porcelain", {})
        for _, command in ipairs(compound) do
          value = run(command, { "deny" })
          assert.is_true(value.details.sandbox.denied_by_user, command)
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
      local value = execute(shell, {
        command = "git status --short",
        options = {
          require_escalation = true,
          escalation_justification = "test failed editor",
        },
      }, ctx)
      assert.is_true(value.details.sandbox.approval_unavailable)
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

    local invalid = { "approve_prefix" }
    for _ = 1, 16 do
      invalid[#invalid + 1] = {
        ok = true,
        action = "accept_prefix",
        input = "git status && whoami",
      }
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
        execute = function() end,
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
    local value = execute(transformed, {}, context(root))
    assert.are.equal("restricted", value.content[1].text)
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
      value = execute(transformed, arguments, context(root))
      assert.is_true(value.details.sandbox.invalid_escalation)
    end

    local pending = async.run(function()
      return async.await(function() return function() end end)
    end)
    value = module.new():wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })(transformed, {
      options = {
        require_escalation = true,
        escalation_justification = "reason",
      },
    }, dialog_context(root, function() return pending end))
    assert.is_true(value.details.sandbox.approval_unavailable)
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
      })(transformed, {
        options = {
          require_escalation = true,
          escalation_justification = "reason",
        },
      }, dialog_context(root, decision))
      assert.is_true(value.details.sandbox.approval_unavailable)
    end

    value = module.new():wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })(transformed, {
      options = {
        require_escalation = true,
        escalation_justification = "reason",
      },
    }, dialog_context(root, function()
      return { ok = true, action = "deny" }
    end))
    assert.is_true(value.details.sandbox.denied_by_user)

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
    value = summary_execute(summary_tool, {
      options = {
        require_escalation = true,
        escalation_justification = "bad\0reason",
      },
    }, dialog_context(root, function(request)
      summarized = request
      return "deny"
    end))
    assert.is_true(value.details.sandbox.denied_by_user)
    assert.matches("current arguments", summarized.body)
    assert.matches("\\x00", summarized.body, 1, true)

    local escalation_arguments = {
      options = {
        require_escalation = true,
        escalation_justification = "reason",
      },
    }
    local incomplete = context(root)
    incomplete.dialog = {
      show = function() return "approve" end,
    }
    value = execute(transformed, escalation_arguments, incomplete)
    assert.is_true(value.details.sandbox.approval_unavailable)

    for _, choose_pending in ipairs({
      function() error("bulk action failed") end,
      function()
        return nil, util.error("dialog", "bulk action unavailable")
      end,
    }) do
      value = execute(transformed, escalation_arguments,
        dialog_context(root, function() return "deny_all" end,
          choose_pending))
      assert.is_true(value.details.sandbox.approval_unavailable)
    end
    value = execute(transformed, escalation_arguments,
      dialog_context(root, function() return "deny_all" end,
        function(_, action, reason)
          assert.are.equal("deny", action)
          assert.matches("another sandbox request", reason)
          return 2
        end))
    assert.is_true(value.details.sandbox.denied_by_user)

    local source = require("neoagent.dialog").new()
    local detach = source:subscribe(function() end)
    local composed = module.new():wrap({
      restricted = function() error("restricted") end,
      elevated = function() error("elevated") end,
    })
    local run = async.run(function()
      return composed(transformed, {
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
      run:result().details.sandbox.approval_unavailable)
    assert.is_false(
      run:result().details.sandbox.denied_by_user == true)
    assert.are.equal(1, calls)
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
      local summary = summarize({ name = name }, arguments, ctx)
      assert.is_string(summary)
      assert.is_true(summary ~= "")
      assert.is_nil(summary:find("private contents", 1, true))
    end
    assert.matches("custom",
      summarize({ name = "custom" }, {}, ctx))
  end)
end)
