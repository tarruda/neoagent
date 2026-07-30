local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local function temporary_directory()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return path
end

local function workspace(root)
  return require("neoagent.workspace").new({ root = root, cwd = root })
end

local function context(root)
  return { context = { workspace = workspace(root), controller = "Neo" } }
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

  it("keeps sandbox settings in setup while direct Controllers stay explicit", function()
    local configured = require("neoagent.config").resolve({
      sandbox = {
        enabled = false,
        future_policy = { paths = { "/example" } },
      },
    })
    assert.is_false(configured.sandbox.enabled)
    assert.are.same({ paths = { "/example" } },
      configured.sandbox.future_policy)
    assert.has_error(function()
      require("neoagent.config").resolve({ sandbox = false })
    end, "sandbox must be a table")
    assert.has_error(function()
      require("neoagent.config").resolve({
        sandbox = { enabled = "yes" },
      })
    end, "sandbox.enabled must be boolean")

    local controller = require("neoagent.controller").new({
      name = "Direct",
      sandbox = { enabled = true },
      tools = {},
    })
    assert.is_true(controller:config().sandbox.enabled)
    controller:destroy()
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

  it("dispatches platforms explicitly and reports unsupported systems", function()
    local linux, macos = {}, {}
    local dispatch = require("neoagent.sandbox.platform")
    assert.are.equal(linux,
      dispatch.select("Linux", { linux = linux, macos = macos }))
    assert.are.equal(macos,
      dispatch.select("OSX", { linux = linux, macos = macos }))
    local selected, status =
      dispatch.select("Plan9", { linux = linux, macos = macos })
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
    local composed, dialogs =
      require("neoagent.sandbox.composition").controller(
        original, { platform = platform })
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
      require("neoagent.sandbox.composition").controller(
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
      require("neoagent.sandbox.composition").controller, original)
    package.loaded["neoagent.sandbox.platform"] = dispatch_module
    assert.is_true(selected_ok)
    assert.is_function(selected_value.execute_tool)
  end)

  it("defers a failed activation warning to the requesting View", function()
    local notifications = {}
    local saved_notify = vim.notify
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end
    local opened = false
    local view
    local configured = {
      name = "Neo",
      sandbox = { enabled = true },
      tools = {},
      _tools_supplied = true,
      view = function()
        view = {
          context = {},
          set_context = function(self, value)
            self.context = vim.tbl_extend(
              "force", self.context, value)
          end,
          is_open = function() return opened end,
          open = function() return opened and true or nil, "failed" end,
        }
        return view
      end,
    }
    local composed, broker =
      require("neoagent.sandbox.composition").controller(configured, {
        status = {
          ok = false,
          stage = "probe",
          message = "native support is unavailable",
        },
      })
    assert.is_nil(broker)
    assert.are.equal(0, #notifications)
    view = composed.view({})
    view:set_context({ name = "Chat" })
    view:open()
    assert.are.equal(0, #notifications)
    opened = true
    view:open()
    assert.are.equal(0, #notifications)
    view:set_context({ name = "Neo" })
    assert.are.equal(1, #notifications)
    assert.matches("tools will run without a sandbox",
      notifications[1][1])
    view:open()
    assert.are.equal(1, #notifications)
    vim.notify = saved_notify
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
    local composed = composition.controller(
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
    composed = composition.controller(
      configured, { platform = platform })
    value = composed.execute_tool(
      composed.tools[1], {}, context(root))
    assert.are.equal("ok", value.content[1].text)

    local ok, err = pcall(function()
      composition.default_profile({})
    end)
    assert.is_false(ok)
    assert.are.equal("Sandbox requires a workspace root", err.message)
    local failed = composition.controller(configured, {
      platform = {
        name = "broken",
        check = function() error("probe exploded") end,
      },
    })
    assert.is_function(failed.view)
    assert.is_false(failed._sandbox_status.active)
    assert.are.equal("requirements", failed._sandbox_status.stage)
  end)

  it("keeps a root workspace bounded to shared temporary writes", function()
    local seen_profile
    local composed = require("neoagent.sandbox.composition").controller({
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

    local appended = require("neoagent.sandbox.result").append({
      content = { { type = "image", data = "bytes" } },
    }, "sandbox context", { ran_restricted = true })
    assert.are.equal("sandbox context", appended.content[1].text)
    assert.is_true(appended.details.sandbox.ran_restricted)
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
    assert.is_true(failed.details.sandbox.ran_restricted)
    assert.matches("ran inside the sandbox", failed.content[1].text)
    local thrown = execute({
      execute = function(_, ctx)
        local process_result = ctx.process({ "fail" }, { cwd = root })
        error("native tool rejected status " .. process_result.code)
      end,
    }, {}, context(root))
    assert.is_true(thrown.isError)
    assert.matches("native tool rejected status 2", thrown.content[1].text)
    assert.matches("ran inside the sandbox", thrown.content[1].text)
    assert.is_true(thrown.details.sandbox.ran_restricted)
    local process_request = calls[#calls]
    assert.are.same({ PATH = "/bin", TEST_SANDBOX = "yes" },
      process_request.env)
    assert.has_error(function() retained.fs.read(root) end)
    assert.has_error(function() retained.process({ "true" }) end)
  end)

  it("fails closed for malformed capabilities and backend failures", function()
    local root = temp()
    local temporary = vim.fs.joinpath(root, "spill")
    local raw_calls = {}
    local raw_fs = {
      create_temp = function()
        raw_calls[#raw_calls + 1] = "create_temp"
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
    })
    local execute = box:wrap()
    local value = execute({
      execute = function(_, ctx)
        local path = assert(ctx.fs.create_temp("spill-"))
        assert(ctx.fs.write_all(path, "data", "a", 384))
        assert.are.equal("temporary", ctx.fs.read(path))
        assert(ctx.fs.mkdirp(vim.fs.joinpath(root, "directory")))
        return { content = { { type = "text", text = "ok" } } }
      end,
    }, {}, context(root))
    assert.are.equal("ok", value.content[1].text)
    assert.are.same({
      "create_temp",
      "write:" .. temporary,
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
