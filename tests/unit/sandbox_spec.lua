local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")
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
---@return T
local function complete(fn)
  local run = async.run(fn)
  assert(vim.wait(1000, function() return run:is_done() end, 5))
  local value = assert(run:result())
  if value.ok == false then
    error(value.error, 0)
  end
  return value --[[@as T]]
end

---@param request Neoagent.WorkerRequest
---@return Neoagent.WorkerLease
local function loopback_child(request)
  local protocol = require("neoagent.rpc.protocol")
  local server
  server = require("neoagent.rpc.server").new({
    send = function(message)
      if request.on_stdout then
        request.on_stdout(protocol.encode(message))
      end
    end,
  })
  local decoder = protocol.decoder(function(message)
    server:receive(message)
  end)
  local result = { code = 0, signal = 0, stderr = "" }
  local closed = false
  ---@type Neoagent.WorkerLease
  return {
    write = function(_, bytes)
      decoder:feed(bytes)
      return true
    end,
    close_stdin = function()
      return true
    end,
    terminate = function()
      server:eof()
    end,
    wait = function()
      return util.copy(result)
    end,
    start = function() end,
    wait_ready = function() return true end,
    is_released = function() return true end,
    wait_release = function() return true end,
    dispose = function()
      if not closed then
        closed = true
        if request.on_exit then
          request.on_exit(util.copy(result))
        end
      end
    end,
  }
end

---@param on_start? fun(request: Neoagent.SandboxWorkerRequest)
---@return Neoagent.SandboxPlatform<Neoagent.SandboxContext<Neoagent.TestSandboxEnvironment>>
local function test_platform(on_start)
  return {
    name = "test",
    check = function()
      return { ok = true, platform = "test", capabilities = {} }
    end,

    create_worker = function(request)
      if on_start then
        on_start(request)
      end
      return loopback_child(request)
    end,
  }
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

  it("uses the Pi Bash grammar for prefix grants when the editor shell differs", function()
    local previous = vim.o.shell
    vim.o.shell = "cmd.exe"
    local ok, err = pcall(function()
      local tool = require("neoagent.tools.pi.command").new({ shell = "bash" })
      local replies = { "approve_prefix", { ok = true, action = "accept_prefix", input = "git" }, "deny" }
      local elevated = 0
      local execute = require("neoagent.sandbox.escalation").new():wrap({
        restricted = function()
          return require("neoagent.sandbox.result").sandbox("preflight", { preflight_denied = true })
        end,
        elevated = function()
          elevated = elevated + 1
          return { content = { { type = "text", text = "approved" } } }
        end,
      })
      local ctx = dialog_context(temp(), function() return table.remove(replies, 1) end)
      execute(tool, { command = "git status" }, ctx)
      local value = execute(tool, { command = "git status; echo unapproved" }, ctx)
      assert.is_true(value.isError)
      assert.are.equal(1, elevated)
      assert.are.equal(0, #replies)
    end)
    vim.o.shell = previous
    assert(ok, err)
  end)

  it("shows prepared paths in renamed file and patch approvals", function()
    local root = temp()
    local cases = {
      { tool = require("neoagent.tools.pi.write").new(), arguments = { path = "../outside.txt", content = "text" } },
      { tool = require("neoagent.tools.codex.apply_patch").new(), arguments = {
        patch = "*** Begin Patch\n*** Add File: ../outside.txt\n+text\n*** End Patch",
      } },
    }
    for _, case in ipairs(cases) do
      ---@type string?
      local body
      local execute = require("neoagent.sandbox.escalation").new():wrap({
        restricted = function()
          return require("neoagent.sandbox.result").sandbox("preflight", { preflight_denied = true })
        end,
        elevated = function() error("denied operation ran") end,
      })
      execute(case.tool, case.arguments, dialog_context(root, function(request)
        body = request.body
        return "deny"
      end))
      assert.matches(vim.fs.joinpath(vim.fs.dirname(root), "outside.txt"), assert(body), 1, true)
    end
  end)

  it("summarizes image, multi-file patch, and documentation approvals", function()
    local root = temp()
    local ctx = context(root)
    ctx.model.input = { "text", "image" }
    local summary = require("neoagent.sandbox.approval_summary").for_tool
    assert.are.equal(
      "View image " .. root .. "/image.png (high)",
      summary(require("neoagent.tools.codex.view_image").new(), { path = "image.png" }, ctx)
    )
    local text = summary(
      require("neoagent.tools.codex.apply_patch").new(),
      {
        patch = table.concat({
          "*** Begin Patch",
          "*** Update File: old",
          "*** Move to: moved",
          "@@",
          "-before",
          "+after",
          "*** Update File: other",
          "@@",
          "-before",
          "+after",
          "*** End Patch",
        }, "\n"),
      },
      ctx
    )
    assert.are.equal("Move and update " .. root .. "/old to " .. root .. "/moved\nUpdate " .. root .. "/other", text)
    assert.are.equal(
      "Read Neoagent documentation",
      summary(require("neoagent.tools.read_agent_documentation").new(), {}, ctx)
    )
  end)

  it("keeps prefix grants distinct for case-sensitive executable paths", function()
    if jit.os ~= "Linux" then return end
    local root = temp()
    assert(fs.mkdirp(root .. "/Upper"))
    assert(fs.mkdirp(root .. "/upper"))
    local replies = { "approve_prefix", { ok = true, action = "accept_prefix", input = "git" }, "deny" }
    local elevated = 0
    local execute = require("neoagent.sandbox.escalation").new():wrap({
      restricted = function()
        return require("neoagent.sandbox.result").sandbox("preflight", { preflight_denied = true })
      end,
      elevated = function()
        elevated = elevated + 1
        return { content = { { type = "text", text = "approved" } } }
      end,
    })
    local ctx = dialog_context(root, function() return table.remove(replies, 1) end)
    execute(require("neoagent.tools.pi.command").new({ shell = root .. "/Upper/bash" }), { command = "git status" }, ctx)
    local value = execute(require("neoagent.tools.pi.command").new({ shell = root .. "/upper/bash" }), { command = "git status" }, ctx)
    assert.is_true(value.isError)
    assert.are.equal(1, elevated)
    assert.are.equal(0, #replies)
  end)

  it("reports copied grants and parent Tool exceptions for the active execution policy", function()
    local root = temp()
    local tool = require("neoagent.tools.read_file").new()
    local _, _, _, runtime = require("neoagent.sandbox.composition").switchable(
      { tools = { tool } }, { enabled = true, parent_tools = { tool }, profile = { network = "enabled" } },
      { platform = test_platform(), status = { ok = true, platform = "test" } }
    )
    local facts = runtime:facts({ root = root, cwd = root })
    assert.are.equal("sandbox", facts.mode)
    assert.are.equal("enabled", facts.network)
    assert.are.same({ "read_file" }, facts.parent_tools)
    assert.are.equal("read", assert(facts.filesystem).default)
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(entry) return entry.path end,
      assert(facts.filesystem).entries), root))
    facts.network = "restricted"
    assert.are.equal("enabled", runtime:facts({ root = root, cwd = root }).network)
    assert(runtime:set_enabled(false))
    assert.are.equal("host", runtime:facts({ root = root, cwd = root }).mode)
  end)

  it("validates sandbox settings while direct Agents stay explicit",
    ---@async
    function()
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
    assert.has_error(function()
      require("neoagent.config").resolve({
        sandbox = { enabled = false, parent_tools = "all" },
      } --[[@as Neoagent.ConfigInput]])
    end, "sandbox.parent_tools must be a list")

    local agent = require("neoagent").new({
      name = "Direct",
      default_registry = false,
      providers = {},
      sandbox = { enabled = true },
      tools = {},
    })
    assert.is_true(agent:config().sandbox.enabled)
    agent:destroy()
  end)

  it("validates profiles and resolves path precedence and canonical aliases",
    ---@async
    function()
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
    local normalized =
      require("neoagent.sandbox.profile").validate(source)
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
    local paths = require("neoagent.sandbox.path").posix
    local lexical = vim.fs.joinpath(root, "ordinary.txt")
    local canonical = paths.canonical_candidate(lexical)
    assert.is_true(policy.allows(normalized, lexical, canonical, "write"))
    lexical = vim.fs.joinpath(protected, "file.txt")
    canonical = paths.canonical_candidate(lexical)
    assert.is_false(policy.allows(
      normalized, lexical, canonical, "read"))

    local outside = temp()
    local link = vim.fs.joinpath(root, "link")
    assert(vim.uv.fs_symlink(outside, link))
    lexical = vim.fs.joinpath(link, "new.txt")
    canonical = paths.canonical_candidate(lexical)
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
      function(value) value.environment.inherit = { "NOT=VALID" } end,
      function(value) value.environment.inherit = { "" } end,
      function(value) value.environment.inherit = { "NUL\0NAME" } end,
      function(value) value.environment.set = { ["NOT=VALID"] = "x" } end,
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
    local original_realpath = vim.uv.fs_realpath
    vim.uv.fs_realpath = function() return nil end
    local resolved, fallback_canonical =
      pcall(paths.canonical_candidate, "/missing/child")
    vim.uv.fs_realpath = original_realpath
    assert.is_true(resolved)
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

  it("applies Windows path and environment semantics without changing profiles",
    ---@async
    function()
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
    assert.are.equal("part", path_module.posix.validate_component("part"))
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
        inherit = { "Path", "PATH", "TEMP", "ProgramFiles(x86)" },
        set = { path = "C:\\bin", Temp = "C:\\Temp", ["programfiles(X86)"] = "C:\\Applications" },
      },
    }
    local normalized = require("neoagent.sandbox.profile").validate(
      source, { paths = paths })
    assert.are.same({ "Path", "TEMP", "ProgramFiles(x86)" }, normalized.environment.inherit)
    assert.are.same({ Path = "C:\\bin", TEMP = "C:\\Temp", ["ProgramFiles(x86)"] = "C:\\Applications" },
      normalized.environment.set)
    assert.are.equal("write", assert(normalized.filesystem.entries[1]).access)
    assert.are.equal("read", assert(normalized.filesystem.entries[2]).access)

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

  it("dispatches platforms explicitly and reports unsupported systems",
    ---@async
    function()
    ---@param name string
    ---@return Neoagent.SandboxPlatform
    local function platform(name)
      return {
        name = name,
        check = function() return { ok = true, platform = name } end,
        create_worker = function() error("dispatch must not execute") end,
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
    assert.matches("unsupported platform", assert(assert(status).message))
  end)

  it("activates only after a successful platform probe",
    ---@async
    function()
    local root = temp()
    local tool = require("neoagent.tools.write_file").new()
    ---@type Neoagent.Tool<unknown>[]
    local original_tools = { tool }
    local original = {
      name = "Neo",
      sandbox = { enabled = true },
      tools = original_tools,

    }
    local checked = 0
    local starts = 0
    ---@type Neoagent.SandboxPlatform<Neoagent.SandboxContext<Neoagent.TestSandboxEnvironment>>
    local platform = test_platform(function()
      starts = starts + 1
    end)
    platform.check = function()
      checked = checked + 1
      return { ok = true, platform = "test" }
    end
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
    assert.is_nil(assert(assert(assert(toolset).tools[1]).input_schema.properties).options)
    assert.is_nil(original.tools[1].input_schema.properties.options)

    local composed, _, dialogs =
      composition.switchable({ tools = original.tools }, original.sandbox, { platform = platform })
    assert.are.equal(1, checked)
    assert.is_table(dialogs)
    assert.are.equal("write_file", assert(assert(composed.tools)[1]).name)
    assert.is_nil(
      assert(assert(assert(composed.tools)[1]).input_schema.properties).options)
    assert.is_nil(
      original.tools[1].input_schema.properties.options)
    local value = complete(function()
      return assert(composed.execute_tool)(
        assert(assert(composed.tools)[1]), {
          path = "activation.txt",
          content = "sandboxed\n",
        }, context(root))
    end)
    assert.matches("Successfully wrote", assert(assert(value.content[1]).text))
    assert.are.equal("sandboxed\n", assert(fs.read(vim.fs.joinpath(root, "activation.txt"))))
    assert.are.equal(1, starts)

    local disabled = util.copy(original)
    disabled.sandbox.enabled = false
    local untouched, disabled_status, broker =
      composition.compose({ tools = disabled.tools }, disabled.sandbox, { platform = platform })
    assert.is_table(broker)
    assert.is_function(untouched.execute_tool)
    assert.is_false(disabled_status.enabled)
    assert.are.equal(1, checked)

    local dispatch_module = package.loaded["neoagent.sandbox.platform"]
    package.loaded["neoagent.sandbox.platform"] = {
      select = function()
        return platform, { ok = true, platform = "test" }
      end,
    }
    local selected_ok, selected_value = pcall(
      composition.compose, { tools = original.tools }, original.sandbox)
    package.loaded["neoagent.sandbox.platform"] = dispatch_module
    assert.is_true(selected_ok)
    assert.is_function(assert(selected_value).execute_tool)
  end)

  it("preserves custom Tool schemas and arguments in fixed host mode", function()
    local tool = {
      name = "inspect", description = "Inspect parent state",
      input_schema = { type = "object", properties = { options = { type = "string" } },
        required = { "options" }, additionalProperties = false },
      execute = function(arguments)
        return { content = { { type = "text", text = arguments.options } } }
      end,
    }
    local composed, status = require("neoagent.sandbox.composition").compose(
      { tools = { tool } }, { enabled = false })
    assert.is_false(status.enabled)
    local selected = assert(composed.tools[1])
    local execute = assert(composed.execute_tool)
    assert.are.same(tool.input_schema, selected.input_schema)
    local value = complete(function()
      return execute(selected, { options = "brief" }, context(temp()))
    end)
    assert.are.equal("brief", assert(value.content[1]).text)
  end)

  it("exposes sandbox execution facts from the composed Toolset",
    ---@async
    function()
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
        ---@async
        execute = function()
          return {
            content = { {
              type = "text",
              text = "parent adapter",
            } },
          }
        end,
      } },

    }
    ---@type Neoagent.SandboxPlatform<Neoagent.SandboxContext<Neoagent.TestSandboxEnvironment>>
    local platform = test_platform()
    local composition = require("neoagent.sandbox.composition")
    local toolset, status = composition.compose({
      tools = original.tools,
    }, original.sandbox, {
      platform = platform,
      status = { ok = true, platform = "test" },
      dialogs = require("neoagent.dialog").new(),
    }
      )
      assert.is_true(status.active)
      local root = temp()
      local policy = assert(toolset.execution_policy)({ root = root, cwd = root })
      assert.are.equal("sandbox", policy.mode)
      assert.are.equal("test", policy.platform)
      assert.are.equal("restricted", policy.network)
    end
  )

  it("switches one stable toolset between host and sandbox execution",
    ---@async
    function()
    local root = temp()
    local checks = 0
    local tool = require("neoagent.tools.write_file").new()
    local starts = 0
    ---@type Neoagent.SandboxPlatform<Neoagent.SandboxContext<Neoagent.TestSandboxEnvironment>>
    local platform = test_platform(function()
      starts = starts + 1
    end)
    platform.check = function()
      checks = checks + 1
      return { ok = true, platform = "test" }
    end
    local stable, status, _, runtime =
      require("neoagent.sandbox.composition").switchable({
        tools = { tool },
      }, { enabled = false }, { platform = platform })
    local original_tools = util.copy(stable.tools)
    local execute = assert(stable.execute_tool)
    assert.is_false(status.enabled)
    assert.are.equal(0, checks)
    local value = complete(function()
      return execute(assert(stable.tools[1]), {
        path = "switchable.txt",
        content = "host\n",
      }, context(root))
    end)
    assert.matches("Successfully wrote", assert(assert(value.content[1]).text))
    assert.are.equal("host\n", assert(fs.read(vim.fs.joinpath(root, "switchable.txt"))))
    assert.are.equal(0, starts)

    status = assert(runtime:set_enabled(true))
    assert.is_true(status.active)
    assert.are.equal(1, checks)
    value = complete(function()
      return execute(assert(stable.tools[1]), {
        path = "switchable.txt",
        content = "sandbox\n",
      }, context(root))
    end)
    assert.matches("Successfully wrote", assert(assert(value.content[1]).text))
    assert.are.equal("sandbox\n", assert(fs.read(vim.fs.joinpath(root, "switchable.txt"))))
    assert.are.equal(1, starts)

    status = assert(runtime:set_enabled(false))
    assert.is_false(status.enabled)
    value = complete(function()
      return execute(assert(stable.tools[1]), {
        path = "switchable.txt",
        content = "host again\n",
      }, context(root))
    end)
    assert.matches("Successfully wrote", assert(assert(value.content[1]).text))
    assert.are.equal("host again\n", assert(fs.read(vim.fs.joinpath(root, "switchable.txt"))))
    assert.are.equal(1, starts)
    assert(runtime:set_enabled(true))
    assert.are.equal(1, checks)
    assert.are.equal(execute, stable.execute_tool)
    assert.are.same(original_tools, stable.tools)
  end)

  it("preserves parent-only arguments outside escalation processing",
    ---@async
    function()
    local root = temp()
    local seen = {}
    local capabilities = {}
    local dialogs = require("neoagent.dialog").new()
    local tool = {
      name = "parent-inspect",
      description = "Inspect parent execution",
      input_schema = {
        type = "object",
        properties = { options = { type = "string" } },
        required = { "options" },
        additionalProperties = false,
      },
      ---@async
      execute = function(arguments, ctx)
        seen[#seen + 1] = arguments.options
        capabilities[#capabilities + 1] = assert(ctx.dialog)
        return { content = { { type = "text", text = arguments.options } } }
      end,
    }
    local starts = 0
    local stable, _, _, runtime = require("neoagent.sandbox.composition").switchable(
      { tools = { tool } }, { enabled = false, parent_tools = { tool } }, {
        platform = test_platform(function()
          starts = starts + 1
        end),
        dialogs = dialogs,
      })
    local execute = assert(stable.execute_tool)
    local selected = assert(stable.tools[1])

    local host = complete(function()
      return execute(selected, { options = "brief" }, context(root))
    end)
    assert.are.equal("brief", assert(host.content[1]).text)
    local active, active_err = pcall(function()
      capabilities[1]:choose_pending("approve")
    end)
    assert.is_false(active)
    assert.matches("Dialog capability has expired", util.normalize_error(active_err).message)
    assert(runtime:set_enabled(true))
    local enabled = complete(function()
      return execute(selected, { options = "detailed" }, context(root))
    end)

    assert.are.equal("detailed", assert(enabled.content[1]).text)
    active, active_err = pcall(function()
      capabilities[2]:choose_pending("approve")
    end)
    assert.is_false(active)
    assert.matches("Dialog capability has expired", util.normalize_error(active_err).message)
    assert.are.same({ "brief", "detailed" }, seen)
    assert.are_not.equal(capabilities[1], capabilities[2])
    assert.are.equal(0, starts)
  end)

  it("blocks unavailable sandbox execution until explicitly disabled",
    ---@async
    function()
    local root = temp()
    local executions = 0
    local tool = {
      name = "inspect", description = "Inspect", input_schema = { type = "object" },
      ---@async
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
    local blocked = complete(function()
      return execute_stable(assert(stable.tools[1]), {}, context(root))
    end)
    assert.is_true(blocked.isError)
    assert.is_true(assert(assert(blocked.execution).sandbox).unavailable)
    assert.are.equal(0, executions)

    assert(runtime:set_enabled(false))
    local permitted = complete(function()
      return execute_stable(assert(stable.tools[1]), {}, context(root))
    end)
    assert.are.equal("host", assert(permitted.content[1]).text)
    assert.are.equal(1, executions)

    local parent_tool = util.copy(tool)
    parent_tool.name = "parent-inspect"
    local parent = composition.switchable({ tools = { parent_tool } },
      { enabled = true, parent_tools = { parent_tool } }, options)
    local parent_value = complete(function()
      return assert(parent.execute_tool)(assert(assert(parent.tools)[1]), {}, context(root))
    end)
    assert.are.equal("host", assert(parent_value.content[1]).text)
    assert.are.equal(2, executions)
  end)

  it("bounds unavailable warnings and fails initial activation exceptions",
    ---@async
    function()
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
          create_worker = function() error("must not execute") end,

        },
      })
    end)
    assert.is_false(activated)
    assert.matches("temporary root failed",
      util.normalize_error(activation_err).message)
  end)

  it("keeps a failed activation exception from restoring host authority",
    ---@async
    function()
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

        create_worker = function() error("must not execute") end,
      } })

    local status, err = runtime:set_enabled(true)

    assert.is_nil(status)
    assert.matches("backend setup failed", assert(err).message)
    assert.is_true(runtime:status().enabled)
    assert.is_false(runtime:status().active)
    local blocked = complete(function()
      return assert(stable.execute_tool)(assert(stable.tools[1]), {}, context(root))
    end)
    assert.is_true(blocked.isError)
    assert.are.equal(0, executions)
  end)

  it("publishes a failed activation warning for Agent presentation",
    ---@async
    function()
    ---@type Neoagent.Config<Neoagent.TestSandboxEnvironment>
    local configured = require("neoagent.config").resolve({
      name = "Neo",
      sandbox = { enabled = true },
      tools = {},

    })
    local composition = require("neoagent.sandbox.composition")
    local _, status = composition.switchable({ tools = assert(configured.tools) }, configured.sandbox, {
        status = {
          ok = false, platform = "test",
          stage = "probe",
          message = "native support is unavailable",
        },
      })
    assert.matches("restricted tool execution is blocked",
      composition.warning(configured.name, status))
  end)

  it("merges profile tables and calls profile callbacks with defaults",
    ---@async
    function()
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

    ---@type {default: Neoagent.SandboxProfile, ctx: Neoagent.SandboxContext<Neoagent.TestSandboxEnvironment>}?
    local seen
    ---@type Neoagent.SandboxProfile?
    local started_profile
    local platform = test_platform(function(request)
      started_profile = request.profile
    end)
    ---@type Neoagent.Config<Neoagent.TestSandboxEnvironment>
    local configured = require("neoagent.config").resolve({
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

    })
    assert(fs.write_all(vim.fs.joinpath(root, "file"), "contents"))
    local composed, status = composition.switchable(
      { tools = assert(configured.tools) }, configured.sandbox, { platform = platform })
    assert.is_true(status.active)
    local value = complete(function()
      return assert(composed.execute_tool)(
        assert(assert(composed.tools)[1]), { path = "file" }, context(root))
    end)
    assert.are.equal("contents", assert(value.content[1]).text)
    assert.are.equal("enabled", assert(started_profile).network)
    assert.are.equal("enabled", assert(seen).default.network)
    assert.are.equal(root,
      assert(assert(seen).ctx.context).workspace.root)

    assert(configured.sandbox).profile = { network = "enabled" }
    configured.tools = { require("neoagent.tools.shell").new() }
    composed = composition.switchable(
      { tools = assert(configured.tools) }, configured.sandbox, { platform = platform })
    value = complete(function()
      return assert(composed.execute_tool)(
        assert(assert(composed.tools)[1]), { command = "true" }, context(root))
    end)
    assert.is_false(value.isError)
    assert.are.equal("enabled", assert(started_profile).network)

    local ok, err = pcall(function()
      composition.default_profile({})
    end)
    assert.is_false(ok)
    assert.are.equal("Sandbox requires a workspace root", util.normalize_error(err).message)
    local _, failed_status = composition.switchable({ tools = assert(configured.tools) }, configured.sandbox, {
      platform = {
        name = "broken",

        create_worker = function() error("probe failed") end,
        check = function() error("probe exploded") end,
      },
    })
    assert.is_false(failed_status.active)
    assert.are.equal("requirements", failed_status.stage)
    assert.matches("probe exploded", composition.warning(configured.name, failed_status))
  end)

  it("keeps a root workspace bounded to shared temporary writes",
    ---@async
    function()
    ---@type Neoagent.SandboxProfile?
    local seen_profile
    local composed = require("neoagent.sandbox.composition").switchable({
      tools = { require("neoagent.tools.read_file").new() },
    }, { enabled = true }, {
      platform = test_platform(function(request)
        seen_profile = request.profile
      end),
      status = {
        ok = true,
        platform = "test",
        capabilities = { filesystem = true },
      },
    })
    local value = complete(function()
      return assert(composed.execute_tool)(
        assert(assert(composed.tools)[1]), { path = "/etc/hosts" }, context("/"))
    end)
    assert.is_nil(value.isError)
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

  it("formats runtime capabilities and inactive configuration without probing global state",
    ---@async
    function()
      local sandbox = require("neoagent.sandbox")
      local status = {
        enabled = true,
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
      }
      assert.is_true(status.active)
      local agent = require("neoagent").new({
        name = "Sandbox status", default_registry = false, tools = {},
        sandbox = { enabled = true },
      })
      local agent_status = sandbox.info(agent)
      agent:destroy()
      assert.is_true(agent_status.enabled)
      assert.is_false(agent_status.active)
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
  it("frames fragmented binary MessagePack events",
    ---@async
    function()
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

  it("exposes stable architecture and seccomp values",
    ---@async
    function()
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

  it("compiles macOS policies with parameterized paths",
    ---@async
    function()
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

    local private = root .. "/private"
    local readonly = root .. "/readonly"
    ---@type Neoagent.SandboxAccessPolicy
    local bootstrap_profile = {
      filesystem = {
        default = "read",
        entries = {
          { path = private, access = "deny" },
          { path = readonly, access = "read" },
        },
      },
      network = "restricted",
    }
    local bootstrap_policy, bootstrap_parameters = compiler.compile(
      bootstrap_profile, { { path = root, access = "write" } })
    local private_parameters = {}
    local readonly_excluded = false
    for _, parameter in ipairs(bootstrap_parameters) do
      if parameter.value == private then
        private_parameters[#private_parameters + 1] = parameter.name
      elseif parameter.value == readonly and bootstrap_policy:match(
        '%(require%-not %(subpath %(param "' .. parameter.name .. '"%)%)%)'
      ) then
        readonly_excluded = true
      end
    end
    assert.are.equal(3, #private_parameters)
    for _, name in ipairs(private_parameters) do
      assert.matches(
        '%(require%-not %(subpath %(param "' .. name .. '"%)%)%)',
        bootstrap_policy
      )
    end
    assert.is_true(readonly_excluded)
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

  it("preserves Tool schemas and approves only a proven preflight denial", function()
    local tool = require("neoagent.tools.pi.write").new()
    local escalation = require("neoagent.sandbox.escalation").new()
    local schema = util.copy(tool.input_schema)
    local restricted, elevated, prompts = 0, 0, 0
    local execute = escalation:wrap({
      restricted = function()
        restricted = restricted + 1
        return require("neoagent.sandbox.result").sandbox("denied before effects", { preflight_denied = true })
      end,
      elevated = function() elevated = elevated + 1; return { content = { { type = "text", text = "approved" } } } end,
    })
    local value = execute(tool, { path = "file", content = "text" }, dialog_context(temp(), function()
      prompts = prompts + 1
      return "approve"
    end))
    assert.are.equal("approved", assert(value.content[1]).text)
    assert.are.equal(1, restricted)
    assert.are.equal(1, elevated)
    assert.are.equal(1, prompts)
    assert.are.same(schema, tool.input_schema)
    for _, metadata in ipairs({ { denied = true }, { outcome_uncertain = true }, { unavailable = true } }) do
      local blocked = escalation:wrap({
        restricted = function() return require("neoagent.sandbox.result").sandbox("operation may have run", metadata) end,
        elevated = function() error("unproven denial must not elevate") end,
      })
      assert.is_true(blocked(tool, { path = "file", content = "text" }, context(temp())).isError)
    end
  end)

  it("shares one prepared invocation across approval, RPC, and host execution", function()
    local root = temp()
    local tool = require("neoagent.tools.pi.write").new()
    tool.name = "renamed_write"
    ---@type Neoagent.WriteFileRequest?
    local request
    local execute = require("neoagent.sandbox.escalation").new():wrap({
      restricted = function(selected, arguments, ctx)
        assert.are.equal(tool, selected)
        arguments.path, arguments.content = "changed.txt", "changed"
        local proxy, revoke = require("neoagent.rpc.registry").proxy(selected, {
          call = require("neoagent.tools.common").call(ctx),
          invoke = function(_, prepared)
            request = require("neoagent.tools.write_file").validate_request(prepared)
            return require("neoagent.sandbox.result").sandbox("preflight", { preflight_denied = true })
          end,
        })
        local value = assert(proxy).execute(arguments, ctx)
        assert(revoke)()
        return value
      end,
      elevated = function(selected, _, ctx)
        assert.are.equal(tool, selected)
        return selected.execute({ path = "changed-again.txt", content = "changed again" }, ctx)
      end,
    })
    local ctx = dialog_context(root, function(prompt)
      assert.matches(root .. "/original.txt", prompt.body, 1, true)
      assert.is_nil((prompt.body:find("changed.txt", 1, true)))
      return "approve"
    end)
    local result = complete(function()
      return execute(tool, { path = "original.txt", content = "original" }, ctx)
    end)
    assert.is_not_true(result.isError)
    assert.are.equal(root .. "/original.txt", assert(request).resolved_path)
    assert.are.equal("original", fs.read(root .. "/original.txt"))
    assert.is_nil(fs.read(root .. "/changed.txt"))
    assert.is_nil(fs.read(root .. "/changed-again.txt"))
  end)

  it("renders shell approval commands separately from agent justification",
    ---@async
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      local shell = require("neoagent.tools.shell").new()
      ---@type Neoagent.DialogRequest?
      local request
      local execute = module.new():wrap({
        restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
        elevated = function() error("elevated") end,
      })
      local value = execute(assert(shell), {
        command = "rm /outside/test.md",
      }, dialog_context(root, function(candidate)
        request = candidate
        return "deny"
      end))
      assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)
      assert.are.equal(table.concat({
        "Run this tool once outside the sandbox?",
        "",
        "Tool: shell",
        "Working directory: " .. root,
        "Agent justification: The workspace policy denied this operation before execution.",
        "",
        "Shell argv: " .. vim.json.encode(require("neoagent.tools.command").argv("rm /outside/test.md"))
          .. "\\x0AWorking directory: " .. root,
        "",
        "This grants the tool your full user filesystem, process, environment, and network authority for this call.",
      }, "\n"), assert(request).body)
    end)

  for _, replacement in ipairs({ "renamed", "custom" }) do
    it("uses implementation identity for " .. replacement .. " shell approvals", function()
      local escalation = require("neoagent.sandbox.escalation").new()
      local shell = assert(require("neoagent.tools.shell").new())
      local elevated = 0
      local execute = escalation:wrap({
        restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
        elevated = function()
          elevated = elevated + 1
          return { content = { { type = "text", text = "approved" } } }
        end,
      })
      local arguments = {
        command = "git status --short",
      }
      local replies = {
        "approve_prefix",
        { ok = true, action = "accept_prefix", input = "git status" },
      }
      local ctx = dialog_context(temp(), function() return table.remove(replies, 1) end)
      assert.is_not_true(execute(shell, arguments, ctx).isError)
      assert.are.equal(1, elevated)
      if replacement == "renamed" then
        shell.name = "run_command"
        ctx = dialog_context(ctx.context.workspace.root, function()
          error("renaming the bundled shell discarded its prefix approval")
        end)
        assert.is_not_true(execute(shell, arguments, ctx).isError)
        assert.are.equal(2, elevated)
      else
        shell.execute = function() error("custom Tool must not inherit shell approval") end
        local prompts = 0
        ctx = dialog_context(ctx.context.workspace.root, function(request)
          prompts = prompts + 1
          assert.is_false(vim.tbl_contains(vim.tbl_map(function(action) return action.id end,
            request.actions), "approve_prefix"))
          return "deny"
        end)
        assert.is_true(execute(shell, arguments, ctx).isError)
        assert.are.equal(1, prompts)
        assert.are.equal(1, elevated)
      end
    end)
  end

  it("remembers edited shell command prefixes for the current session",
    ---@async
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      local escalation = module.new()
      local shell = require("neoagent.tools.shell").new()
      local elevated, restricted = {}, {}
      local preflight_denied = true
      local execute = escalation:wrap({
        restricted = function(_, arguments)
          if preflight_denied then
            return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true })
          end
          restricted[#restricted + 1] = arguments.command
          return { content = { { type = "text", text = "restricted" } } }
        end,
        elevated = function(_, arguments)
          elevated[#elevated + 1] = arguments.command
          return { content = { { type = "text", text = "elevated" } } }
        end,
      })
      ---@param command string
      ---@return Neoagent.JsonObject
      local function arguments(command)
        return { command = command }
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
      assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)
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
        assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)
        assert.is_true(vim.tbl_contains(
          vim.tbl_map(function(action) return action.id end,
            prompted[#prompted].actions), "approve_prefix"), command)
      end

      prompted = {}
      value = execute(assert(shell), arguments("$(whoami) --version"),
        with_dialog("session-one", { "deny" }, prompted))
      assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)
      assert.is_false(vim.tbl_contains(
        vim.tbl_map(function(action) return action.id end,
          prompted[#prompted].actions), "approve_prefix"))

      execute(assert(shell), arguments("git status '&&'"),
        with_dialog("session-one", {}, {}))
      assert.are.equal("git status '&&'", elevated[#elevated])

      value = execute(assert(shell), arguments("git status --porcelain"),
        with_dialog("session-two", { "deny" }, {}))
      assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)

      preflight_denied = false
      value = execute(assert(shell), arguments("git status --short"),
        with_dialog("session-one", {}, {}))
      assert.are.equal("restricted", assert(value.content[1]).text)
      assert.are.same({ "git status --short" }, restricted)
    end)

  it("rejects compound or unrelated remembered shell prefixes",
    ---@async
    function()
    local root = temp()
    local module = require("neoagent.sandbox.escalation")
    local shell = require("neoagent.tools.shell").new()
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
      local escalation = module.new()
      shell = require("neoagent.tools.shell").new()
      local elevated = false
      local execute = escalation:wrap({
        restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
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
      }, ctx)
      assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)
      assert.is_false(elevated)
      assert.are.equal(4, #requests)
      assert.matches("cannot be remembered", requests[3].body)
    end

    local escalation = module.new()
    shell = require("neoagent.tools.shell").new()
    local elevated = 0
    local execute = escalation:wrap({
      restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
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
    }, ctx)
    local remembered_ctx = dialog_context(root, function()
      error("remembered quoted operator unexpectedly prompted")
    end)
    remembered_ctx.context.session_id = "quoted-operator"
    execute(assert(shell), {
      command = [[printf "%s" "&&" ignored]],
    }, remembered_ctx)
    assert.are.equal(2, elevated)
  end)

  it("offers cmd and PowerShell leading prefixes without operator tokens",
    ---@async
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      ---@param shell string
      ---@param command string
      ---@return string[]
      ---@async
      local function action_ids(shell, command)
        local escalation = module.new()
        local tool = require("neoagent.tools.shell").new({
          argv = require("neoagent.tools.command").shell_argv(shell, false),
        })
        ---@type Neoagent.DialogRequest?
        local request
        local execute = escalation:wrap({
          restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
          elevated = function() error("elevated") end,
        })
        local value = execute(assert(tool), {
          command = command,
        }, dialog_context(root, function(candidate)
          request = candidate
          return "deny"
        end))
        assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)
        return vim.tbl_map(function(action) return action.id end,
          assert(request).actions)
      end
      ---@param shell string
      ---@param command string
      ---@return boolean
      ---@async
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

  it("coalesces remembered prefixes across supported shell parsers",
    ---@async
    function()
    local root = temp()
    local module = require("neoagent.sandbox.escalation")
    local active_shell = "/bin/sh"
    local escalation = module.new()
    local elevated = {}
    local execute = escalation:wrap({
      restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
      elevated = function(_, arguments)
        elevated[#elevated + 1] = arguments.command
        return { content = { { type = "text", text = "ok" } } }
      end,
    })
    ---@param command string
    ---@param replies (string|Neoagent.DialogResult)[]
    ---@async
    local function run(command, replies)
      local ctx = dialog_context(root, function()
        local reply = table.remove(replies, 1)
        assert.is_not_nil(reply, "unexpected approval prompt")
        return reply
      end)
      ctx.context.session_id = "coalesced"
      local value = execute(require("neoagent.tools.shell").new({
        argv = require("neoagent.tools.command").shell_argv(active_shell, false),
      }), {
        command = command,
      }, ctx)
      assert.are.equal("ok", assert(value.content[1]).text)
      assert.are.equal(0, #replies)
    end
    ---@param command string
    ---@param prefix string
    ---@async
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

    active_shell = "/opt/pwsh.exe"
    remember("Write-Output literal", "Write-Output")
    run("Write-Output other", {})
    active_shell = "/bin/sh"
    run("git status --short", {})
    assert.are.equal(8, #elevated)
  end)

  it("remembers any literal prefix while compound commands keep prompting",
    ---@async
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      local escalation = module.new()
      local shell = require("neoagent.tools.shell").new()
      local elevated = {}
      local execute = escalation:wrap({
        restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
        elevated = function(_, arguments)
          elevated[#elevated + 1] = arguments.command
          return { content = { { type = "text", text = "elevated" } } }
        end,
      })
      ---@param command string
      ---@param replies (string|Neoagent.DialogResult)[]
      ---@param seen? Neoagent.DialogRequest[]
      ---@return Neoagent.ToolResult
      ---@async
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
      assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)
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
      assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)

      assert.are.same({
        "python3 scripts/report.py --json",
        "python3 tools/cleanup.py",
        "git status && git push",
        "git",
        "git status --short",
      }, elevated)
    end)

  it("keeps cmd and PowerShell rules and matches free of chaining syntax",
    ---@async
    function()
      local root = temp()
      local module = require("neoagent.sandbox.escalation")
      ---@param shell_path string
      ---@param session string
      local function harness(shell_path, session)
        local escalation = module.new()
        local tool = require("neoagent.tools.shell").new({ argv = require("neoagent.tools.command").shell_argv(shell_path, false) })
        local elevated = {}
        local execute = escalation:wrap({
          restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
          elevated = function(_, arguments)
            elevated[#elevated + 1] = arguments.command
            return { content = { { type = "text", text = "elevated" } } }
          end,
        })
        ---@param command string
        ---@param replies (string|Neoagent.DialogResult)[]
        ---@param seen? Neoagent.DialogRequest[]
        ---@return Neoagent.ToolResult
        ---@async
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
      ---@async
      local function check(shell_path, session, compound, chained_prefix)
        local run, elevated = harness(shell_path, session)
        local requests = {}
        local value = run("git status --short", {
          "approve_prefix",
          { ok = true, action = "accept_prefix", input = chained_prefix },
          "cancel_prefix",
          "deny",
        }, requests)
        assert.is_true(assert(assert(value.execution).sandbox).denied_by_user)
        assert.matches("cannot be remembered", requests[3].body)
        run("git status --short", {
          "approve_prefix",
          { ok = true, action = "accept_prefix", input = "git status" },
        })
        run("git status --porcelain", {})
        for _, command in ipairs(compound) do
          value = run(command, { "deny" })
          assert.is_true(assert(assert(value.execution).sandbox).denied_by_user, command)
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

      check("/opt/pwsh.exe", "pwsh-chaining", {
        "git status; whoami",
        "git status | whoami",
        "git status & whoami",
        "git status $(whoami)",
        "git status `; whoami",
        "git status\nwhoami",
      }, "git status; whoami")
    end)

  it("fails closed when command-prefix editing cannot settle",
    ---@async
    function()
    local root = temp()
    local module = require("neoagent.sandbox.escalation")
    ---@param replies (string|Neoagent.DialogResult)[]
    ---@async
    local function attempt(replies)
      local escalation = module.new()
      local shell = require("neoagent.tools.shell").new()
      local execute = escalation:wrap({
        restricted = function() return require("neoagent.sandbox.result").sandbox("preflight denial", { preflight_denied = true }) end,
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
      }, ctx)
      assert.is_true(assert(assert(value.execution).sandbox).approval_unavailable)
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

  it("validates native command approval inputs and fails closed without a presenter", function()
    local root = temp()
    local tool = require("neoagent.tools.process").exec_command()
    local escalation = require("neoagent.sandbox.escalation").new()
    local execute = escalation:wrap({
      restricted = function() return { content = { { type = "text", text = "restricted" } } } end,
      elevated = function() error("malformed or unanswered approval must not execute") end,
    })
    for _, input in ipairs({
      { cmd = "echo test", sandbox_permissions = "invalid" },
      { cmd = "echo test", sandbox_permissions = "require_escalated" },
      { cmd = "echo test", sandbox_permissions = "use_default", justification = "invalid" },
      { cmd = "echo test", sandbox_permissions = "require_escalated", justification = "reason", prefix_rule = {} },
      { cmd = "echo test", sandbox_permissions = "require_escalated", justification = "reason", prefix_rule = { "" } },
      { cmd = "echo test", sandbox_permissions = "require_escalated", justification = "reason", prefix_rule = { 42 } },
      vim.json.decode('["array"]'),
    }) do
      local rejected = execute(tool, input, context(root))
      assert.is_true(assert(assert(rejected.execution).sandbox).invalid_escalation)
    end
    local unanswered = execute(tool, { cmd = "echo test", sandbox_permissions = "require_escalated", justification = "reason" }, context(root))
    assert.is_true(assert(assert(unanswered.execution).sandbox).approval_unavailable)
    local bypassed = escalation:bypass(function(_, input)
      assert.is_nil(input.sandbox_permissions)
      assert.is_nil(input.justification)
      assert(type(input.cmd) == "string")
      return { content = { { type = "text", text = input.cmd } } }
    end)(tool, { cmd = "echo test", sandbox_permissions = "require_escalated", justification = "reason" }, context(root))
    assert.are.equal("echo test", assert(bypassed.content[1]).text)
    local malformed = escalation:bypass(function()
      error("invalid options executed")
    end)(tool, { cmd = "echo test", sandbox_permissions = "invalid" }, context(root))
    assert.is_true(assert(assert(malformed.execution).sandbox).invalid_escalation)
  end)

  it("contains unavailable, invalid, and queued native approval decisions", function()
    local root = temp()
    local tool = require("neoagent.tools.process").exec_command()
    local arguments = { cmd = "echo test", sandbox_permissions = "require_escalated", justification = "reason" }
    for _, decision in ipairs({ false, "invalid", "deny_all", "deny_all_throw", "deny_all_error", "show_throw" }) do
      local execute = require("neoagent.sandbox.escalation").new():wrap({
        restricted = function()
          error("restricted execution")
        end,
        elevated = function()
          error("unanswered approval executed")
        end,
      })
      local ctx = dialog_context(root, function()
        if decision == "show_throw" then
          error("presenter failed")
        end
        if decision == "deny_all_throw" or decision == "deny_all_error" then
          return "deny_all"
        end
        return decision
      end, function(_, action)
        assert.are.equal("deny", action)
        if decision == "deny_all_throw" then
          error("queue failed")
        end
        if decision == "deny_all_error" then
          return nil, util.error("sandbox_approval", "queue failed")
        end
        return 0
      end)
      local result = execute(tool, arguments, ctx)
      local metadata = assert(assert(result.execution).sandbox)
      if decision == false or decision == "deny_all" then
        assert.is_true(metadata.denied_by_user)
      else
        assert.is_true(metadata.approval_unavailable)
      end
    end
    local dialogs = require("neoagent.dialog").new()
    local detach = dialogs:subscribe(function() end)
    local execute = require("neoagent.sandbox.escalation").new():wrap({
      restricted = function()
        error("restricted execution")
      end,
      elevated = function()
        error("pending approval executed")
      end,
    })
    local pending = execute(
      tool,
      arguments,
      dialog_context(root, function(request)
        return dialogs:show(request)
      end)
    )
    detach()
    assert.is_true(assert(assert(pending.execution).sandbox).approval_unavailable)
    assert.is_nil(dialogs:snapshot().active)
  end)

  it("bounds approval summaries, falls back on summary errors, and propagates admitted execution errors", function()
    local root = temp()
    local tool = require("neoagent.tools.process").exec_command()
    for _, failure in ipairs({ false, true }) do
      local execute = require("neoagent.sandbox.escalation")
        .new({
          summarize = function()
            if failure then
              error("summary failed")
            end
            return string.rep("a", 2100)
          end,
        })
        :wrap({
          restricted = function()
            error("restricted execution")
          end,
          elevated = function()
            error("admitted operation failed")
          end,
        })
      local ctx = dialog_context(root, function(request)
        if failure then
          assert.matches("Run exec_command with its current arguments", request.body, 1, true)
        else
          assert.matches(string.rep("a", 1997) .. "...", request.body, 1, true)
          assert.is_nil((request.body:find(string.rep("a", 2001), 1, true)))
        end
        return true
      end)
      local ok, err = pcall(
        execute,
        tool,
        { cmd = "echo test", sandbox_permissions = "require_escalated", justification = "reason" },
        ctx
      )
      assert.is_false(ok)
      assert.matches("admitted operation failed", tostring(err))
    end
  end)
end)
