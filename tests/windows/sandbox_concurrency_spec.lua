local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local helper = require("tests.helpers.subprocess")
local windows = require("neoagent.sandbox.windows")

describe("concurrent Windows sandbox authority", function()
  if jit.os ~= "Windows" then
    pending("requires Windows")
    return
  end

  ---@type string
  local root
  ---@type table<string, string>
  local environment
  ---@type Neoagent.WorkerLease[]
  local leases
  ---@type Neoagent.Run<unknown, unknown>[]
  local runs
  ---@type Neoagent.ProcessSessions?
  local owner
  ---@type vim.SystemObj?
  local lock_holder
  ---@type uv.uv_timer_t?
  local unlock_timer
  ---@type string[]
  local temporary_directories
  ---@param entries Neoagent.SandboxFilesystemEntry[]
  ---@return Neoagent.WindowsSandboxProfile
  local function profile(entries)
    return windows.compile({
      id = "concurrent-workers", network = "restricted",
      filesystem = { default = "read", entries = entries },
      environment = { clear = true, inherit = {}, set = {} },
    })
  end

  ---@param selected Neoagent.SandboxProfile
  ---@return Neoagent.WindowsSandboxProfile
  local function prepare(selected)
    return windows.compile(windows.prepare(selected, {}, { fs = fs }))
  end

  ---@param selected Neoagent.SandboxProfile
  ---@param argv string[]
  ---@param launch? fun(request: Neoagent.WorkerRequest): Neoagent.WorkerLease
  ---@return Neoagent.WorkerLease, fun(): string
  local function start(selected, argv, launch)
    local output = ""
    local lease = require("tests.helpers.sandbox").start_worker(windows, {
      argv = argv, cwd = root, env = vim.tbl_extend("force", environment, selected.environment.set), profile = selected,
      on_stdout = function(bytes) output = output .. bytes end,
    }, { fs = fs, nvim = vim.env.NEOAGENT_NVIM, start_worker = launch })
    leases[#leases + 1] = lease
    return lease, function() return output end
  end

  ---@param lease Neoagent.WorkerLease
  local function finish(lease)
    assert(lease:close_stdin())
    local result = helper.success(function() return lease:wait() end, 15000)
    assert.is_nil(result.error, vim.inspect(result))
    assert.is_nil(result.cleanup_error, vim.inspect(result))
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.is_true(helper.complete(function() return lease:wait_release() end, 10000))
  end

  -- Exercise actual filesystem checks repeatedly within the same restricted
  -- process, before and after another lease changes or revokes its own ACLs.
  ---@param selected Neoagent.SandboxProfile
  ---@param launch? fun(request: Neoagent.WorkerRequest): Neoagent.WorkerLease
  ---@return Neoagent.WorkerLease, fun(mode: string, path: string): string
  local function access_worker(selected, launch)
    local lease, output = start(selected, { "python", "-u", "-c", table.concat({
      "import ctypes, json, os, pathlib, sys",
      "from ctypes import wintypes as w",
      "class LUID(ctypes.Structure): _fields_ = [('low', w.DWORD), ('high', w.LONG)]",
      "class PRIVILEGES(ctypes.Structure): _fields_ = [('count', w.DWORD), ('luid', LUID), ('attributes', w.DWORD)]",
      "objects = {}",
      "def enable_privilege(name):",
      " a = ctypes.WinDLL('advapi32', use_last_error=True)",
      " token = w.HANDLE()",
      " if not a.OpenProcessToken(w.HANDLE(-1), 0x28, ctypes.byref(token)): raise PermissionError(ctypes.get_last_error())",
      " try:",
      "  p = PRIVILEGES(); p.count = 1; p.attributes = 2",
      "  if not a.LookupPrivilegeValueW(None, ctypes.c_wchar_p(name), ctypes.byref(p.luid)): raise RuntimeError('lookup failed')",
      "  ctypes.set_last_error(0)",
      "  if not a.AdjustTokenPrivileges(token, False, ctypes.byref(p), 0, None, None): raise RuntimeError('adjust failed')",
      "  if ctypes.get_last_error() == 1300: raise PermissionError('privilege absent')",
      " finally: ctypes.windll.kernel32.CloseHandle(token)",
      "print('READY', flush=True)",
      "for line in sys.stdin:",
      " mode, name = json.loads(line)",
      " if mode == 'pid': print(os.getpid(), flush=True); continue",
      " try:",
      "  p = pathlib.Path(name)",
      "  if mode == 'write': p.write_text('written')",
      "  elif mode == 'move': os.replace(*json.loads(name))",
      "  elif mode == 'replace-parent':",
      "   p.rename(p.with_name(p.name + '.moved')); p.mkdir(); (p / 'protected').write_text('replacement')",
      "  elif mode == 'privilege': enable_privilege(name)",
      "  elif mode == 'coordinator':",
      "   import winreg",
      "   with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\\Neoagent\\Sandbox', 0, winreg.KEY_SET_VALUE | winreg.KEY_WOW64_64KEY): pass",
      "  elif mode.startswith('mutex-'):",
      "   k = ctypes.WinDLL('kernel32', use_last_error=True); a = ctypes.WinDLL('advapi32', use_last_error=True)",
      "   k.CreateMutexW.restype = w.HANDLE",
      "   if mode == 'mutex-close':",
      "    h = w.HANDLE(objects.pop(name)); k.ReleaseMutex(h); k.CloseHandle(h); print('ALLOWED', flush=True); continue",
      "   class SECURITY(ctypes.Structure): _fields_ = [('length', w.DWORD), ('descriptor', w.LPVOID), ('inherit', w.BOOL)]",
      "   descriptor = w.LPVOID()",
      "   if not a.ConvertStringSecurityDescriptorToSecurityDescriptorW(ctypes.c_wchar_p('D:P(D;;GA;;;' + name + ')(A;;GA;;;WD)'), 1, ctypes.byref(descriptor), None): raise RuntimeError('DACL failed')",
      "   attributes = SECURITY(ctypes.sizeof(SECURITY), descriptor, False)",
      "   try:",
      "    h = k.CreateMutexW(ctypes.byref(attributes), True, ctypes.c_wchar_p(r'Global\\NeoagentSandboxAuthority'))",
      "    if not h: raise PermissionError(ctypes.get_last_error())",
      "    objects[name] = h",
      "   finally: k.LocalFree(descriptor)",
      "  elif mode.startswith('namespace-'):",
      "   alias, identity = json.loads(name)",
      "   k = ctypes.WinDLL('kernel32', use_last_error=True); a = ctypes.WinDLL('advapi32', use_last_error=True)",
      "   k.CreateBoundaryDescriptorW.restype = w.HANDLE",
      "   k.OpenPrivateNamespaceW.restype = w.HANDLE; k.CreatePrivateNamespaceW.restype = w.HANDLE",
      "   boundary = w.HANDLE(k.CreateBoundaryDescriptorW(ctypes.c_wchar_p(alias), 0)); sid = w.LPVOID()",
      "   if not boundary: raise RuntimeError('boundary allocation failed')",
      "   try:",
      "    if not a.ConvertStringSidToSidW(ctypes.c_wchar_p(identity), ctypes.byref(sid)): raise RuntimeError('SID failed')",
      "    if not k.AddSIDToBoundaryDescriptor(ctypes.byref(boundary), sid): raise RuntimeError('boundary SID failed')",
      "    h = k.OpenPrivateNamespaceW(boundary, ctypes.c_wchar_p(alias)) if mode == 'namespace-open' else k.CreatePrivateNamespaceW(None, boundary, ctypes.c_wchar_p(alias))",
      "    err = ctypes.get_last_error()",
      "    if h: k.ClosePrivateNamespace(w.HANDLE(h), 1 if mode == 'namespace-create' else 0)",
      "    elif mode == 'namespace-open' and err != 5: raise RuntimeError('unexpected namespace error ' + str(err))",
      "    else: raise PermissionError(err)",
      "   finally:",
      "    if sid: k.LocalFree(sid)",
      "    k.DeleteBoundaryDescriptor(boundary)",
      "  elif mode.startswith('event-'):",
      "   k = ctypes.WinDLL('kernel32', use_last_error=True)",
      "   k.CreateEventW.restype = w.HANDLE; k.OpenEventW.restype = w.HANDLE",
      "   if mode == 'event-create': h = k.CreateEventW(None, False, False, ctypes.c_wchar_p(name))",
      "   else: h = k.OpenEventW(0x1f0003, False, ctypes.c_wchar_p(name))",
      "   if not h: raise PermissionError(ctypes.get_last_error())",
      "   objects[name] = h",
      "  elif mode.startswith('process-'):",
      "   access = int(mode.split('-')[1])",
      "   k = ctypes.WinDLL('kernel32', use_last_error=True); k.OpenProcess.restype = w.HANDLE",
      "   h = k.OpenProcess(access, False, int(name))",
      "   if not h: raise PermissionError(ctypes.get_last_error())",
      "   k.CloseHandle(w.HANDLE(h))",
      "  elif mode == 'acl':",
      "   code = ctypes.windll.advapi32.SetNamedSecurityInfoW(ctypes.c_wchar_p(name), 1, 4, None, None, None, None)",
      "   if code: raise PermissionError(code)",
      "  else: p.read_text()",
      "  print('ALLOWED', flush=True)",
      " except PermissionError: print('DENIED', flush=True)",
    }, "\n") }, launch)
    helper.success(function() return assert(lease.wait_ready)(lease) end, 30000)
    assert(vim.wait(10000, function() return output():find("READY", 1, true) ~= nil end, 10))
    return lease, function(mode, path)
      local offset = #output()
      assert(lease:write(vim.json.encode({ mode, path }) .. "\n"))
      assert(vim.wait(10000, function() return output():sub(offset + 1):find("\n", 1, true) ~= nil end, 10))
      return vim.trim(output():sub(offset + 1))
    end
  end

  before_each(function()
    root = vim.fs.joinpath(assert(vim.env.RUNNER_TEMP), "neoagent-concurrent-" .. tostring(vim.uv.hrtime()))
    assert(fs.mkdirp(root))
    environment = {
      PATH = assert(vim.env.PATH), SystemRoot = assert(vim.env.SystemRoot),
      TEMP = windows.temporary_root(), TMP = windows.temporary_root(),
    }
    leases, runs, temporary_directories = {}, {}, {}
  end)

  ---@type Neoagent.AwaitCallbacks<true>?
  local recovery_waiter
  local custody_module = require("neoagent.sandbox.windows.custody")
  local new_custody = custody_module.new
  after_each(function()
    custody_module.new = new_custody
    if recovery_waiter then recovery_waiter.resolve(true); recovery_waiter = nil end
    if unlock_timer then
      unlock_timer:stop()
      unlock_timer:close()
      unlock_timer = nil
    end
    if lock_holder then
      pcall(lock_holder.write, lock_holder, nil)
      lock_holder:wait(10000)
      lock_holder = nil
    end
    if owner then
      owner:close("concurrency test finished")
      helper.complete(function() return assert(owner):wait_cleanup(15000) end, 20000)
      owner = nil
    end
    for _, run in ipairs(runs) do
      if not run:is_done() then run:cancel("concurrency test finished") end
    end
    for _, lease in ipairs(leases) do
      lease:dispose("concurrency test finished")
      helper.complete(function() return lease:wait() end, 15000)
    end
    for _, lease in ipairs(leases) do
      assert.is_true(helper.complete(function() return lease:wait_release() end, 15000))
    end
    local recovered = windows.check({ fs = fs, nvim = vim.env.NEOAGENT_NVIM })
    assert.is_true(recovered.ok, vim.inspect(recovered))
    for _, path in ipairs(temporary_directories) do vim.fn.delete(path, "rf") end
    vim.fn.delete(root, "rf")
  end)

  it("admits another restricted worker while the first waits for input", function()
    local selected = profile({ { path = root, access = "write" } })
    local first, output = start(selected, { "cmd.exe", "/d", "/s", "/c",
      "echo WAITING & set /p line= & echo FIRST-FINISHED" })
    helper.success(function() return assert(first.wait_ready)(first) end, 30000)
    assert(vim.wait(10000, function() return output():find("WAITING", 1, true) ~= nil end, 10))
    local second, second_output = start(selected, { "cmd.exe", "/d", "/s", "/c", "echo SECOND-FINISHED" })
    local ready = async.run(function() return assert(second.wait_ready)(second) end)
    runs[#runs + 1] = ready
    assert(vim.wait(10000, function() return ready:is_done() end, 10),
      "a live worker must not hold the permission-journal lock for its whole lifetime")
    assert.is_true(helper.wait(ready))
    local completed = helper.success(function() return second:wait() end, 10000)
    assert.is_nil(completed.error, vim.inspect(completed))
    assert.is_nil(completed.cleanup_error, vim.inspect(completed))
    assert.are.equal(0, completed.code)
    assert.matches("SECOND-FINISHED", second_output(), 1, true)
    assert.is_true(helper.complete(function() return second:wait_release() end, 10000))
    assert.is_nil((output():find("FIRST-FINISHED", 1, true)))
    assert(first:write("continue\r\n"))
    assert(first:close_stdin())
    completed = helper.success(function() return first:wait() end, 10000)
    assert.is_nil(completed.cleanup_error, vim.inspect(completed))
    assert.are.equal(0, completed.code)
    assert.matches("FIRST-FINISHED", output(), 1, true)
    assert.is_true(helper.complete(function() return first:wait_release() end, 10000))
  end)

  it("keeps shared denials and compatible write grants independent through cleanup", function()
    local left, right = vim.fs.joinpath(root, "left"), vim.fs.joinpath(root, "right")
    assert(fs.mkdirp(left))
    assert(fs.mkdirp(right))
    local left_file, right_file = vim.fs.joinpath(left, "value"), vim.fs.joinpath(right, "value")
    local secret = vim.fs.joinpath(root, "secret")
    assert(fs.write_all(left_file, "left"))
    assert(fs.write_all(right_file, "right"))
    assert(fs.write_all(secret, "protected"))
    local first, check_first = access_worker(profile({
      { path = left, access = "write" }, { path = secret, access = "deny" },
    }))
    local second, check_second = access_worker(profile({
      { path = right, access = "write" }, { path = secret, access = "deny" },
    }))
    assert.are.equal("ALLOWED", check_first("write", left_file))
    assert.are.equal("DENIED", check_first("read", secret))
    assert.are.equal("DENIED", check_first("write", right_file))
    assert.are.equal("ALLOWED", check_second("write", right_file))
    assert.are.equal("DENIED", check_second("read", secret))
    assert.are.equal("DENIED", check_second("write", left_file))
    local owned = vim.fs.joinpath(left, "created-by-sandbox")
    assert.are.equal("ALLOWED", check_first("write", owned))
    assert.are.equal("DENIED", check_second("acl", owned))
    local first_pid = check_first("pid", "")
    for _, access in ipairs({ 0x10, 0x20, 0x2, 0x40000 }) do
      assert.are.equal("DENIED", check_second("process-" .. access, first_pid))
    end
    finish(first)
    -- A new host must join the namespace still owned by the surviving peer,
    -- even after the host that originally created it has left.
    local third = access_worker(profile({
      { path = left, access = "write" }, { path = secret, access = "deny" },
    }))
    assert.are.equal("ALLOWED", check_second("write", right_file))
    assert.are.equal("DENIED", check_second("read", secret))
    assert.are.equal("DENIED", check_second("write", left_file))
    finish(third)
    finish(second)
  end)

  for _, operation in ipairs({ "runtime", "setup" }) do
    it("rejects an independent authority inventory during " .. operation, function()
      local original = assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE)
      local alternate = vim.fs.joinpath(assert(vim.env.RUNNER_TEMP), "neoagent-alternate-" .. tostring(vim.uv.hrtime()))
      temporary_directories[#temporary_directories + 1] = alternate
      assert(fs.mkdirp(vim.fs.joinpath(alternate, "shared-tmp")))
      -- Reuse setup credentials without allocating another persistent account
      -- or network policy. The copied inventory is independently empty.
      assert(fs.write_all(vim.fs.joinpath(alternate, "state.json"), assert(fs.read(vim.fs.joinpath(original, "state.json")))))
      local protected = vim.fs.joinpath(root, "protected")
      local replacement = vim.fs.joinpath(root, "replacement")
      assert(fs.write_all(protected, "protected"))
      local first, check_first = access_worker(profile({
        { path = root, access = "write" }, { path = protected, access = "deny" },
      }))
      assert.are.equal("DENIED", check_first("read", protected))
      if operation == "setup" then
        local runtime = assert(vim.uv.fs_realpath("scripts/sandbox_windows_runtime.lua"))
        local result = vim.system({ assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE",
          "-n", "-l", runtime, "--", "--setup" }, {
          text = true, env = { NEOAGENT_WINDOWS_SANDBOX_STATE = alternate },
        }):wait(30000)
        assert.are_not.equal(0, result.code, "another storage directory created an independent coordinator")
        assert.matches("coordinator", assert(result.stderr), 1, true)
      else
        local second = start(profile({ { path = root, access = "write" } }), {
          "python", "-c", "import os, pathlib, sys; pathlib.Path(sys.argv[1]).write_text('replacement'); os.replace(sys.argv[1], sys.argv[2])",
          replacement, protected,
        }, function(request)
          request.env.NEOAGENT_WINDOWS_SANDBOX_STATE = alternate
          return require("neoagent.rpc.worker_lease").start(request)
        end)
        local result = helper.success(function() return second:wait() end, 15000)
        assert.are.equal("DENIED", check_first("read", protected), "a second inventory bypassed the original denial")
        assert.matches("coordinator", assert(result.error).message, 1, true)
        assert.is_nil(result.cleanup_error, vim.inspect(result))
        assert.is_true(helper.complete(function() return second:wait_release() end, 10000))
      end
      finish(first)
    end)
  end

  it("keeps machine registration outside restricted target authority", function()
    local lease, check = access_worker(profile({ { path = root, access = "write" } }))
    assert.are.equal("DENIED", check("coordinator", ""))
    finish(lease)
  end)

  it("rejects replacement of the registered authority directory", function()
    local directory = assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE)
    local saved = directory .. "-identity-" .. tostring(vim.uv.hrtime())
    local state = assert(fs.read(vim.fs.joinpath(directory, "state.json")))
    assert(vim.uv.fs_rename(directory, saved))
    local checked, failure = pcall(function()
      assert(fs.mkdirp(vim.fs.joinpath(directory, "shared-tmp")))
      assert(fs.write_all(vim.fs.joinpath(directory, "state.json"), state))
      local lease = start(profile({ { path = root, access = "write" } }), { "cmd.exe", "/d", "/c", "exit 0" })
      local result = helper.success(function() return lease:wait() end, 15000)
      assert.matches("coordinator-identity", assert(result.error).message, 1, true)
      assert.is_nil(result.cleanup_error)
      assert.is_true(helper.complete(function() return lease:wait_release() end, 10000))
    end)
    vim.fn.delete(directory, "rf")
    assert(vim.uv.fs_rename(saved, directory))
    if not checked then error(failure, 0) end
  end)

  for _, mode in ipairs({ "missing", "unreadable" }) do
    it("preserves established authority when its journal is " .. mode, function()
      local protected = vim.fs.joinpath(root, "protected")
      assert(fs.write_all(protected, "protected"))
      local lease, check = access_worker(profile({
        { path = root, access = "write" }, { path = protected, access = "deny" },
      }))
      local path = vim.fs.joinpath(assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")
      local original = assert(fs.read(path))
      local saved = path .. ".saved"
      if mode == "missing" then assert(vim.uv.fs_rename(path, saved)) end
      local checked, failure = pcall(function()
        local runtime = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_account_failure.lua"))
        local result = vim.system({ assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE",
          "-n", "-l", runtime, "--", "--setup" }, {
          text = true, env = { NEOAGENT_ACCOUNT_TEST_FAILURE = "setup-journal-" .. mode },
        }):wait(30000)
        assert.are.equal(1, result.code, result.stderr)
        local diagnostic = vim.json.decode((assert(result.stderr)))
        assert.are.equal(mode == "missing" and "state-missing" or "state-read", diagnostic.stage)
        assert.are.equal("DENIED", check("read", protected))
      end)
      if mode == "missing" then assert(vim.uv.fs_rename(saved, path)) end
      assert.are.equal(original, fs.read(path))
      finish(lease)
      if not checked then error(failure, 0) end
    end)
  end

  it("keeps a peer's created files read-only without an explicit denial", function()
    local left, right = vim.fs.joinpath(root, "left"), vim.fs.joinpath(root, "right")
    assert(fs.mkdirp(left))
    assert(fs.mkdirp(right))
    local first, check_first = access_worker(profile({ { path = left, access = "write" } }))
    local second, check_second = access_worker(profile({ { path = right, access = "write" } }))
    local created = vim.fs.joinpath(left, "created-by-peer")
    assert.are.equal("ALLOWED", check_first("write", created))
    assert.are.equal("ALLOWED", check_second("read", created))
    assert.are.equal("DENIED", check_second("write", created))
    assert.are.equal("DENIED", check_second("acl", created))
    finish(first)
    assert.are.equal("ALLOWED", check_second("read", created))
    assert.are.equal("DENIED", check_second("write", created))
    assert.are.equal("DENIED", check_second("acl", created))
    finish(second)
  end)

  it("keeps named objects private across concurrent invocation cleanup", function()
    local selected = profile({ { path = root, access = "write" } })
    local first, check_first = access_worker(selected)
    local second, check_second = access_worker(selected)
    local name = "Local\\NeoagentIsolation-" .. tostring(vim.uv.hrtime())
    assert.are.equal("ALLOWED", check_first("event-create", name))
    assert.are.equal("DENIED", check_second("event-open", name))
    finish(first)
    assert.are.equal("ALLOWED", check_second("event-create", name))
    finish(second)
  end)

  for _, shared in ipairs({ false, true }) do
    it("does not transfer a peer's write access through " .. (shared and "shared temporary files" or "overlapping roots"), function()
      local left, right = vim.fs.joinpath(root, "left"), vim.fs.joinpath(root, "right")
      assert(fs.mkdirp(left))
      assert(fs.mkdirp(right))
      local source_root = shared and vim.fs.joinpath(root, "tmp") or left
      assert(fs.mkdirp(source_root))
      local first_entries = { { path = left, access = "write" } }
      local second_entries = { { path = shared and right or root, access = "write" } }
      if shared then
        first_entries[#first_entries + 1] = { path = source_root, access = "write" }
        second_entries[#second_entries + 1] = { path = source_root, access = "write" }
      end
      local first, check_first = access_worker(profile(first_entries))
      local source, destination = vim.fs.joinpath(source_root, "source"), vim.fs.joinpath(right, "destination")
      assert(fs.write_all(source, "movable"))
      assert.are.equal("ALLOWED", check_first("write", source))
      assert.are.equal("DENIED", check_first("write", destination))
      local selected = profile(second_entries)
      local argv = { "python", "-u", "-c",
        "import os, sys; os.replace(sys.argv[1], sys.argv[2]); print('MOVED', flush=True); sys.stdin.read()", source, destination }
      local second, output = start(selected, argv)
      local admission = helper.complete(function() return assert(second.wait_ready)(second) end, 30000)
      if admission == true then
        assert(vim.wait(10000, function() return output():find("MOVED", 1, true) ~= nil end, 10))
        assert.are.equal("DENIED", check_first("write", destination), "moving a peer's file expanded its write authority")
      end
      assert.matches("lease-policy-conflict", assert(admission.error).message, 1, true)
      assert.is_true(helper.complete(function() return second:wait_release() end, 10000))
      finish(first)
      local later = start(selected, argv)
      helper.success(function() return assert(later.wait_ready)(later) end, 30000)
      finish(later)
    end)
  end

  it("keeps default temporary storage within each workspace's write authority", function()
    local left, right = vim.fs.joinpath(root, "left"), vim.fs.joinpath(root, "right")
    assert(fs.mkdirp(left))
    assert(fs.mkdirp(right))
    local composition = require("neoagent.sandbox.composition")
    local first_profile = prepare(composition.default_profile({ context = { root = left } },
      windows.paths, windows.temporary_root()))
    local second_profile = prepare(composition.default_profile({ context = { root = right } },
      windows.paths, windows.temporary_root()))
    temporary_directories = { first_profile.environment.set.TEMP, second_profile.environment.set.TEMP }
    assert.are_not.equal(first_profile.environment.set.TEMP, second_profile.environment.set.TEMP)
    local first, check_first = access_worker(first_profile)
    local second, check_second = access_worker(second_profile)
    local temporary = vim.fs.joinpath(first_profile.environment.set.TEMP, "source")
    local destination = vim.fs.joinpath(right, "destination")
    assert.are.equal("ALLOWED", check_first("write", temporary))
    assert.are.equal("ALLOWED", check_second("write", vim.fs.joinpath(second_profile.environment.set.TEMP, "value")))
    assert.are.equal("DENIED", check_second("move", vim.json.encode({ temporary, destination })))
    assert.are.equal("DENIED", check_first("write", destination))
    local peer_profile = prepare(composition.default_profile({ context = { root = left } },
      windows.paths, windows.temporary_root()))
    assert.are.equal(first_profile.environment.set.TEMP, peer_profile.environment.set.TEMP)
    local peer, check_peer = access_worker(peer_profile)
    assert.are.equal("ALLOWED", check_peer("write", temporary))
    finish(peer)
    assert.are.equal("ALLOWED", check_first("write", temporary))
    finish(second)
    finish(first)
  end)

  it("reports managed temporary storage failure before worker admission", function()
    local selected = require("neoagent.sandbox.composition").default_profile({ context = { root = root } },
      windows.paths, windows.temporary_root())
    local mkdirp = fs.mkdirp
    fs.mkdirp = function() return nil, "temporary directory unavailable" end
    local ok, err = pcall(prepare, selected)
    fs.mkdirp = mkdirp
    assert.is_false(ok)
    local failure = require("neoagent.util").normalize_error(err, "test")
    assert.are.equal("sandbox_unavailable", failure.kind)
    assert.matches("temporary storage", failure.message)
    assert.are.equal(0, #leases)
  end)

  it("keeps absolute temporary bootstrap denials at their declared native paths", function()
    local denied = vim.fs.joinpath(windows.temporary_root(), "neoagent-denied-" .. tostring(vim.uv.hrtime()))
    assert(fs.mkdirp(denied))
    temporary_directories[#temporary_directories + 1] = denied
    local bootstrap = vim.fs.joinpath(denied, "worker.lua")
    assert(fs.write_all(bootstrap, "return {}"))
    local selected = require("neoagent.sandbox.composition").default_profile({ context = { root = root } },
      windows.paths, windows.temporary_root())
    selected.filesystem.entries[#selected.filesystem.entries + 1] = { path = denied, access = "deny" }
    local compiled = prepare(selected)
    temporary_directories[#temporary_directories + 1] = compiled.environment.set.TEMP
    local ok, result = pcall(function(...) return require("tests.helpers.sandbox").start_worker(windows, ...) end, {
      argv = { "python", "-c", "import pathlib, sys; print(pathlib.Path(sys.argv[1]).read_text())", bootstrap },
      cwd = root, env = environment, profile = compiled, bootstrap_paths = { bootstrap },
    }, { fs = fs, nvim = vim.env.NEOAGENT_NVIM })
    if ok then leases[#leases + 1] = result end
    assert.is_false(ok, "required bootstrap read bypassed an explicit native denial")
    local failure = require("neoagent.util").normalize_error(result, "test")
    assert.are.equal("sandbox_unavailable", failure.kind)
    assert.matches("denies required bootstrap", failure.message)
  end)

  it("retains a shared protective placeholder until its last lease releases", function()
    local future = vim.fs.joinpath(root, "future")
    local selected = profile({ { path = root, access = "write" }, { path = future, access = "deny" } })
    local first, first_check = access_worker(selected)
    local second, second_check = access_worker(selected)
    local path = vim.fs.joinpath(future, "value")
    assert.are.equal("DENIED", first_check("write", path))
    assert.are.equal("DENIED", second_check("write", path))
    finish(first)
    assert.is_table(vim.uv.fs_lstat(future))
    assert.are.equal("DENIED", second_check("write", path))
    finish(second)
    assert.is_nil(vim.uv.fs_lstat(future))
  end)

  it("retains a placeholder for a denied peer without a writable ancestor", function()
    local future = vim.fs.joinpath(root, "future")
    local first = access_worker(profile({ { path = root, access = "write" }, { path = future, access = "deny" } }))
    local second, check_second = access_worker(profile({ { path = future, access = "deny" } }))
    finish(first)
    assert.is_table(vim.uv.fs_lstat(future), "cleanup removed a live peer's denied path")
    local protected = vim.fs.joinpath(future, "protected")
    assert(fs.write_all(protected, "still denied"))
    assert.are.equal("DENIED", check_second("read", protected))
    assert(vim.uv.fs_unlink(protected))
    finish(second)
    assert.is_nil(vim.uv.fs_lstat(future))
  end)

  for _, access in ipairs({ "read", "deny" }) do
    it("rejects a concurrent writer that can replace a live " .. access .. " boundary", function()
      local path = vim.fs.joinpath(root, "protected")
      assert(fs.write_all(path, "existing"))
      local first, check = access_worker(profile({
        { path = root, access = "write" }, { path = path, access = access },
      }))
      local operation = access == "read" and "write" or "read"
      assert.are.equal("DENIED", check(operation, path))
      local writer = profile({ { path = root, access = "write" } })
      local argv = { "python", "-c",
        "import os, pathlib, sys; p=pathlib.Path(sys.argv[1]); t=p.with_suffix('.new'); t.write_text('replacement'); os.replace(t,p)",
        path }
      local second = start(writer, argv)
      local admission = helper.complete(function() return assert(second.wait_ready)(second) end, 30000)
      if admission == true then
        finish(second)
        assert.are.equal("DENIED", check(operation, path), "replacement removed another live invocation's protection")
      end
      assert.is_table(admission, "conflicting write authority was admitted")
      assert.matches("lease-policy-conflict", assert(admission.error).message, 1, true)
      assert.is_true(helper.complete(function() return second:wait_release() end, 10000))
      assert.are.equal("DENIED", check(operation, path))
      finish(first)
      local later = start(writer, argv)
      helper.success(function() return assert(later.wait_ready)(later) end, 30000)
      finish(later)
      assert.are.equal("replacement", fs.read(path))
    end)
  end

  it("rejects a protected boundary while another live invocation may replace it", function()
    local path = vim.fs.joinpath(root, "protected")
    assert(fs.write_all(path, "existing"))
    local writer, check = access_worker(profile({ { path = root, access = "write" } }))
    local selected = profile({ { path = root, access = "write" }, { path = path, access = "deny" } })
    local blocked = start(selected, { "cmd.exe", "/d", "/c", "exit 0" })
    local admission = helper.complete(function() return assert(blocked.wait_ready)(blocked) end, 30000)
    assert.is_table(admission, "protection was admitted while its object remained replaceable")
    assert.matches("lease-policy-conflict", assert(admission.error).message, 1, true)
    assert.is_true(helper.complete(function() return blocked:wait_release() end, 10000))
    assert.are.equal("ALLOWED", check("write", path))
    finish(writer)
    local later = start(selected, { "cmd.exe", "/d", "/c", "exit 0" })
    helper.success(function() return assert(later.wait_ready)(later) end, 30000)
    finish(later)
  end)

  it("rejects write authority within another invocation's denied directory", function()
    local denied = vim.fs.joinpath(root, "denied")
    local writable = vim.fs.joinpath(denied, "work")
    assert(fs.mkdirp(writable))
    local first = access_worker(profile({ { path = root, access = "write" }, { path = denied, access = "deny" } }))
    local second = start(profile({ { path = writable, access = "write" } }), { "cmd.exe", "/d", "/c", "exit 0" })
    local admission = helper.complete(function() return assert(second.wait_ready)(second) end, 30000)
    assert.matches("lease-policy-conflict", assert(admission.error).message, 1, true)
    assert.is_true(helper.complete(function() return second:wait_release() end, 10000))
    finish(first)
  end)

  it("preserves matching writable exceptions beneath a shared read-only boundary", function()
    local readonly = vim.fs.joinpath(root, "metadata")
    local writable = vim.fs.joinpath(readonly, "work")
    assert(fs.mkdirp(writable))
    local protected_file, writable_file = vim.fs.joinpath(readonly, "value"), vim.fs.joinpath(writable, "value")
    assert(fs.write_all(protected_file, "protected"))
    assert(fs.write_all(writable_file, "writable"))
    local selected = profile({
      { path = root, access = "write" }, { path = readonly, access = "read" }, { path = writable, access = "write" },
    })
    local first, first_check = access_worker(selected)
    local second, second_check = access_worker(selected)
    assert.are.equal("DENIED", first_check("write", protected_file))
    assert.are.equal("ALLOWED", first_check("write", writable_file))
    assert.are.equal("DENIED", second_check("write", protected_file))
    assert.are.equal("ALLOWED", second_check("write", writable_file))
    finish(first)
    assert.are.equal("DENIED", second_check("write", protected_file))
    assert.are.equal("ALLOWED", second_check("write", writable_file))
    finish(second)
  end)

  it("preserves a nested restriction when a worker tries to replace its ancestor", function()
    local parent = vim.fs.joinpath(root, "parent")
    local protected = vim.fs.joinpath(parent, "protected")
    assert(fs.mkdirp(parent))
    assert(fs.write_all(protected, "protected"))
    local selected = profile({ { path = root, access = "write" }, { path = protected, access = "deny" } })
    local first, first_check = access_worker(selected)
    local second, second_check = access_worker(selected)
    local sibling = vim.fs.joinpath(parent, "allowed")
    assert.are.equal("ALLOWED", first_check("write", sibling))
    assert.are.equal("ALLOWED", second_check("write", sibling))
    assert.are.equal("DENIED", second_check("replace-parent", parent), "ancestor replacement removed a live path boundary")
    assert.are.equal("DENIED", first_check("read", protected))
    finish(second)
    assert.are.equal("ALLOWED", first_check("write", sibling))
    assert.are.equal("DENIED", first_check("replace-parent", parent))
    assert.are.equal("DENIED", first_check("read", protected))
    finish(first)
  end)

  it("recovers a crashed host without revoking the surviving worker's lease", function()
    local left, right = vim.fs.joinpath(root, "left"), vim.fs.joinpath(root, "right")
    assert(fs.mkdirp(left))
    assert(fs.mkdirp(right))
    ---@type Neoagent.ProcessWorkerLease?
    local host
    local first, first_check = access_worker(profile({ { path = left, access = "write" } }), function(request)
      host = require("neoagent.rpc.worker_lease").start(request)
      return host
    end)
    -- The production editor owns custody; this regression retains no test
    -- handle that could supply evidence absent from ordinary execution.
    local second, second_check = access_worker(profile({
      { path = right, access = "write" },
    }))
    local left_file, right_file = vim.fs.joinpath(left, "value"), vim.fs.joinpath(right, "value")
    assert.are.equal("ALLOWED", first_check("write", left_file))
    assert.are.equal("ALLOWED", second_check("write", right_file))
    assert(assert(assert(host)._driver).kill())
    local crashed = helper.success(function() return first:wait() end, 15000)
    assert.is_not_nil(crashed.error)
    assert.is_true(helper.success(function() return first:wait_release() end, 15000))
    local recovered = windows.check({ fs = fs, nvim = vim.env.NEOAGENT_NVIM })
    assert.is_true(recovered.ok, vim.inspect(recovered))
    assert.are.equal("ALLOWED", second_check("write", right_file))
    assert.are.equal("DENIED", second_check("write", left_file))
    finish(second)
    assert.is_true(first:is_released())
  end)

  it("denies restricted targets access to their host's Job namespace", function()
    local lease, check = access_worker(profile({ { path = root, access = "write" } }))
    local directory = assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE)
    local state = vim.json.decode((assert(fs.read(vim.fs.joinpath(directory, "state.json")))))
    local id = assert(next(state.leases))
    local alias = "NeoagentSandbox-" .. vim.fn.sha256(directory:gsub("/", "\\"):lower()):sub(1, 32)
      .. "-job-" .. id .. "-" .. state.owner_sid
    local request = vim.json.encode({ alias, state.owner_sid })
    assert.are.equal("DENIED", check("namespace-open", request))
    assert.are.equal("DENIED", check("namespace-create", vim.json.encode({ alias .. "-replacement", state.owner_sid })))
    finish(lease)
  end)

  it("keeps coordination independent of a public mutex owned by a restricted target", function()
    local selected = profile({ { path = root, access = "write" } })
    local attacker, check = access_worker(selected)
    local peer = access_worker(selected)
    local directory = assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE)
    local state = vim.json.decode((assert(fs.read(vim.fs.joinpath(directory, "state.json")))))
    assert.are.equal("ALLOWED", check("mutex-create", state.owner_sid))
    local completed, err = pcall(finish, peer)
    assert.are.equal("ALLOWED", check("mutex-close", state.owner_sid))
    finish(attacker)
    assert.is_true(completed, "untrusted public coordination blocked peer cleanup: " .. vim.inspect(err))
  end)

  it("keeps abandoned authority when the Job name cannot prove termination", function()
    ---@type Neoagent.ProcessWorkerLease?
    local host
    local protected = vim.fs.joinpath(root, "protected")
    assert(fs.write_all(protected, "protected"))
    custody_module.new = function(scripts, recover)
      return new_custody(scripts, function(id)
        require("neoagent.async").await(function(done) recovery_waiter = done end)
        return recover(id)
      end)
    end
    local lease = access_worker(profile({
      { path = root, access = "write" }, { path = protected, access = "deny" },
    }), function(request)
      host = require("neoagent.rpc.worker_lease").start(request)
      return host
    end)
    custody_module.new = new_custody
    assert(assert(assert(host)._driver).kill())
    local crashed = helper.success(function() return lease:wait() end, 15000)
    assert.is_not_nil(crashed.cleanup_error)
    local path = vim.fs.joinpath(assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")
    local recorded = assert(fs.read(path))
    local checked = windows.check({
      fs = fs, nvim = vim.env.NEOAGENT_NVIM,
      system = function(argv, options, timeout)
        for index, value in ipairs(argv) do
          if value:match("sandbox_windows_runtime%.lua$") then
            argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_job_failure.lua"))
          end
        end
        return vim.system(argv, options):wait(timeout)
      end,
    })
    assert.is_false(checked.ok, "missing native identity erased the abandoned policy reservation")
    assert.are.equal("lease-job-unconfirmed", checked.stage)
    assert.are.equal(recorded, fs.read(path), "unconfirmed recovery changed the authority inventory")
    assert(recovery_waiter).resolve(true)
    recovery_waiter = nil
    assert.is_true(helper.success(function() return lease:wait_release() end, 15000))
  end)

  it("records confirmed Job emptiness before closing its last handle", function()
    local record = vim.fs.joinpath(root, "job-closed.json")
    local lease = start(profile({ { path = root, access = "write" } }), { "cmd.exe", "/d", "/c", "exit 0" },
      function(request)
        request.env.NEOAGENT_JOB_TEST_FAILURE = "closed"
        request.env.NEOAGENT_JOB_TEST_RECORD = record
        for index, value in ipairs(request.argv) do
          if value:match("sandbox_windows_runtime%.lua$") then
            request.argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_job_failure.lua"))
          end
        end
        return require("neoagent.rpc.worker_lease").start(request)
      end)
    local crashed = helper.success(function() return lease:wait() end, 30000)
    assert.is_not_nil(crashed.error)
    local recorded = vim.json.decode((assert(fs.read(record))))
    assert.are.equal("empty", recorded.job, "the last handle closed before termination evidence was journaled")
    local checked = windows.check({ fs = fs, nvim = vim.env.NEOAGENT_NVIM })
    assert.is_true(checked.ok, vim.inspect(checked))
    local state = vim.json.decode((assert(fs.read(vim.fs.joinpath(
      assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")))))
    assert.is_nil(state.leases[recorded.id])
  end)

  for _, phase in ipairs({ "persist", "read" }) do
    it("keeps native termination evidence through a failed journal " .. phase, function()
      local record = vim.fs.joinpath(root, "failed-empty-write.json")
        local lease = start(profile({ { path = root, access = "write" } }), { "cmd.exe", "/d", "/c", "exit 0" },
        function(request)
          request.env.NEOAGENT_JOB_TEST_FAILURE = phase
          request.env.NEOAGENT_JOB_TEST_RECORD = record
          for index, value in ipairs(request.argv) do
            if value:match("sandbox_windows_runtime%.lua$") then
              request.argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_job_failure.lua"))
            end
          end
          return require("neoagent.rpc.worker_lease").start(request)
        end)
      local result = helper.success(function() return lease:wait() end, 30000)
      local observed = vim.json.decode((assert(fs.read(record))))
      assert.are.equal("empty", observed.job)
      assert.is_nil(result.error, vim.inspect(result))
      assert.is_nil(result.cleanup_error, "one failed journal operation discarded the only termination evidence")
      assert.is_true(helper.complete(function() return lease:wait_release() end, 10000))
      local checked = windows.check({ fs = fs, nvim = vim.env.NEOAGENT_NVIM })
      assert.is_true(checked.ok, vim.inspect(checked))
    end)
  end

  it("allows failed admission to complete native rollback before its parent deadline", function()
    local record = vim.fs.joinpath(root, "admission-empty-write.json")
    local relay = require("neoagent.sandbox.relay_lease")
    local previous = relay.DEFAULT_ADMISSION_TIMEOUT_MS
    relay.DEFAULT_ADMISSION_TIMEOUT_MS = 10000
    local created, lease = pcall(start, profile({ { path = root, access = "write" } }), { "cmd.exe", "/d", "/c", "exit 0" },
      function(request)
        request.env.NEOAGENT_JOB_TEST_FAILURE = "admission"
        request.env.NEOAGENT_JOB_TEST_RECORD = record
        for index, value in ipairs(request.argv) do
          if value:match("sandbox_windows_runtime%.lua$") then
            request.argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_job_failure.lua"))
          end
        end
        local child = require("neoagent.rpc.worker_lease").start(request)
        -- Start observing readiness at rollback, independently of machine
        -- account-creation latency. The native cleanup budget is still active.
        if not vim.wait(30000, function() return fs.read(record) ~= nil end, 10) then
          child:dispose("admission regression did not reach rollback")
          local result = helper.success(function() return child:wait() end, 10000)
          error("admission regression did not reach rollback: " .. vim.inspect(result))
        end
        return child
      end)
    relay.DEFAULT_ADMISSION_TIMEOUT_MS = previous
    assert(created, vim.inspect(lease))
    local ready = helper.complete(function() return assert(lease.wait_ready)(lease) end, 20000)
    assert.matches("target-create", assert(ready.error).message, 1, true)
    local result = helper.success(function() return lease:wait() end, 10000)
    assert.is_nil(result.cleanup_error, vim.inspect(result))
    assert.is_true(helper.complete(function() return lease:wait_release() end, 10000))
  end)

  for _, phase in ipairs({ "admission_expired", "creation_expired", "resume" }) do
    it("rejects execution after native " .. phase, function()
      local marker = vim.fs.joinpath(root, "must-not-run")
      local lease = start(profile({ { path = root, access = "write" } }),
        { "python", "-c", "import pathlib, sys; pathlib.Path(sys.argv[1]).write_text('ran')", marker },
        function(request)
          request.env.NEOAGENT_JOB_TEST_FAILURE = phase
          local spec = vim.json.decode((assert(request.env.NEOAGENT_SANDBOX_SPEC)))
          spec.admission_timeout_ms = 1000
          request.env.NEOAGENT_SANDBOX_SPEC = vim.json.encode(spec)
          for index, value in ipairs(request.argv) do
            if value:match("sandbox_windows_runtime%.lua$") then
              request.argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_job_failure.lua"))
            end
          end
          return require("neoagent.rpc.worker_lease").start(request)
        end)
      local ready = helper.complete(function() return assert(lease.wait_ready)(lease) end, 15000)
      local result = helper.success(function() return lease:wait() end, 15000)
      assert.is_nil(fs.read(marker), "execution started after the admission deadline")
      assert.matches(phase == "resume" and "target-resume" or "admission-timeout", assert(ready.error).message, 1, true)
      assert.is_nil(result.cleanup_error, vim.inspect(result))
      assert.is_true(helper.complete(function() return lease:wait_release() end, 10000))
    end)
  end

  it("bounds unavailable journal persistence without retiring unconfirmed authority", function()
    local record = vim.fs.joinpath(root, "unavailable-empty-write.json")
    local lease = start(profile({ { path = root, access = "write" } }), { "cmd.exe", "/d", "/c", "exit 0" },
      function(request)
        request.env.NEOAGENT_JOB_TEST_FAILURE = "persist_deadline"
        request.env.NEOAGENT_JOB_TEST_RECORD = record
        local spec = vim.json.decode((assert(request.env.NEOAGENT_SANDBOX_SPEC)))
        spec.finalization_timeout_ms = 500
        request.env.NEOAGENT_SANDBOX_SPEC = vim.json.encode(spec)
        for index, value in ipairs(request.argv) do
          if value:match("sandbox_windows_runtime%.lua$") then
            request.argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_job_failure.lua"))
          end
        end
        return require("neoagent.rpc.worker_lease").start(request)
      end)
    helper.success(function() return assert(lease.wait_ready)(lease) end, 30000)
    local result = helper.success(function() return lease:wait() end, 5000)
    assert.is_nil(result.error, vim.inspect(result))
    assert.matches("state-replace", tostring(assert(result.cleanup_error).detail), 1, true)
    local observed = vim.json.decode((assert(fs.read(record))))
    assert.are.equal("empty", observed.job)
    assert.is_true(helper.complete(function() return lease:wait_release() end, 15000))
    local state = vim.json.decode((assert(fs.read(vim.fs.joinpath(
      assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")))))
    assert.is_nil(state.leases[observed.id], "confirmed recovery retained the old authority reservation")
  end)

  it("lets a completed health probe retain its native finalization budget", function()
    local record = vim.fs.joinpath(root, "probe-empty-write.json")
    local checked = windows.check({
      fs = fs, nvim = vim.env.NEOAGENT_NVIM, probe_timeout_ms = 10,
      system = function(argv, options, timeout)
        local env = assert(options.env)
        env.NEOAGENT_JOB_TEST_FAILURE = "persist_delay"
        env.NEOAGENT_JOB_TEST_RECORD = record
        for index, value in ipairs(argv) do
          if value:match("sandbox_windows_runtime%.lua$") then
            argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_job_failure.lua"))
          end
        end
        lock_holder = vim.system(argv, options)
        -- Begin the outer observation at native finalization to isolate its
        -- budget from machine-dependent account and process startup latency.
        local observed = vim.wait(30000, function()
          local bytes = fs.read(record)
          if not bytes or bytes == "" then return false end
          local decoded, value = pcall(vim.json.decode, bytes)
          return decoded and value.job == "empty"
        end, 10)
        if not observed then lock_holder:kill(9) end
        local result = lock_holder:wait(observed and timeout or 5000)
        lock_holder = nil
        assert(observed, vim.inspect(result))
        return result
      end,
    })
    assert.is_true(checked.ok, "the probe killed its native cleanup owner: " .. vim.inspect(checked))
  end)

  it("rejects an incompatible journal without migrating or replacing it", function()
    local path = vim.fs.joinpath(assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")
    local original = assert(fs.read(path))
    local state = vim.json.decode(original)
    state.v = state.v - 1
    local incompatible = vim.json.encode(state)
    assert(fs.write_all(path, incompatible))
    local checked, failure = pcall(function()
      local before = windows.check({ fs = fs, nvim = vim.env.NEOAGENT_NVIM })
      assert.is_false(before.ok)
      assert.are.equal("state-format", before.stage)
      local runtime = assert(vim.uv.fs_realpath("scripts/sandbox_windows_runtime.lua"))
      local setup = vim.system({ assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE",
        "-n", "-l", runtime, "--", "--setup" }, { text = true }):wait(30000)
      assert.are.equal(1, setup.code)
      assert.matches('"stage":"state-format"', assert(setup.stderr), 1, true)
      assert.are.equal(incompatible, fs.read(path))
    end)
    assert(fs.write_all(path, original))
    if not checked then error(failure, 0) end
  end)

  for _, principal in ipairs({ "launcher", "offline_group" }) do
    it("rejects changed " .. principal .. " ownership during setup", function()
      local path = vim.fs.joinpath(assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")
      local original = assert(fs.read(path))
      local state = vim.json.decode(original)
      state[principal].marker = string.rep("0", 32)
      assert(fs.write_all(path, vim.json.encode(state)))
      local checked, failure = pcall(function()
        local runtime = assert(vim.uv.fs_realpath("scripts/sandbox_windows_runtime.lua"))
        local setup = vim.system({ assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE",
          "-n", "-l", runtime, "--", "--setup" }, { text = true }):wait(30000)
        assert.are.equal(1, setup.code)
        assert.matches(principal == "launcher" and "account-identity" or "account-group-identity",
          assert(setup.stderr), 1, true)
        local status = windows.check({ fs = fs, nvim = vim.env.NEOAGENT_NVIM })
        assert.is_false(status.ok)
        assert.are.equal("setup-incomplete", status.stage)
      end)
      assert(fs.write_all(path, original))
      if not checked then error(failure, 0) end
    end)
  end

  for _, mode in ipairs({ "grant", "crash" }) do
    it("retires a private account after " .. mode .. " interrupts startup", function()
      local record = vim.fs.joinpath(root, "allocated-account")
      local lease = start(profile({ { path = root, access = "write" } }), { "cmd.exe", "/c", "exit 0" },
        function(request)
          request.env.NEOAGENT_ACCOUNT_TEST_RECORD = record
          request.env.NEOAGENT_ACCOUNT_TEST_FAILURE = mode
          for index, value in ipairs(request.argv) do
            if value:match("sandbox_windows_runtime%.lua$") then
              request.argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_account_failure.lua"))
            end
          end
          return require("neoagent.rpc.worker_lease").start(request)
        end)
      local admission = helper.complete(function() return assert(lease.wait_ready)(lease) end, 30000)
      assert.is_not_nil(admission.error, vim.inspect(admission))
      helper.complete(function() return lease:wait() end, 15000)
      local name = assert(fs.read(record))
      assert.is_true(helper.complete(function() return lease:wait_release() end, 15000))
      local retired = vim.system({ "net", "user", name }, { text = true }):wait(10000)
      assert.are_not.equal(0, retired.code, "failed startup left its private account behind")
      local state = vim.json.decode((assert(fs.read(vim.fs.joinpath(
        assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")))))
      assert.is_nil((next(state.leases)))
    end)
  end

  it("rejects domain-account authority before setup or invocation mutation", function()
    local path = vim.fs.joinpath(assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")
    local original = assert(fs.read(path))
    local runtime = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_account_failure.lua"))
    local setup = vim.system({ assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE",
      "-n", "-l", runtime, "--", "--setup" }, {
      text = true, env = { NEOAGENT_ACCOUNT_TEST_FAILURE = "domain-controller" },
    }):wait(30000)
    assert.are.equal(1, setup.code, setup.stderr)
    local diagnostic = assert(setup.stderr)
    assert.are.equal("account-local-database", vim.json.decode(diagnostic).stage)
    assert.are.equal(original, fs.read(path))
    local lease = start(profile({ { path = root, access = "write" } }), { "cmd.exe", "/c", "exit 0" },
      function(request)
        request.env.NEOAGENT_ACCOUNT_TEST_FAILURE = "domain-controller"
        for index, value in ipairs(request.argv) do
          if value:match("sandbox_windows_runtime%.lua$") then request.argv[index] = runtime end
        end
        return require("neoagent.rpc.worker_lease").start(request)
      end)
    local admission = helper.complete(function() return assert(lease.wait_ready)(lease) end, 30000)
    assert.matches("account-local-database", assert(admission.error).message, 1, true)
    assert.is_true(helper.complete(function() return lease:wait_release() end, 10000))
    assert.are.equal(original, fs.read(path))
  end)

  it("launches without host creation privileges and removes them from the target", function()
    local lease, check = access_worker(profile({ { path = root, access = "write" } }), function(request)
      for index, value in ipairs(request.argv) do
        if value:match("sandbox_windows_runtime%.lua$") then
          request.argv[index] = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_unprivileged.lua"))
        end
      end
      return require("neoagent.rpc.worker_lease").start(request)
    end)
    assert.are.equal("ALLOWED", check("privilege", "SeChangeNotifyPrivilege"))
    assert.are.equal("DENIED", check("privilege", "SeAssignPrimaryTokenPrivilege"))
    assert.are.equal("DENIED", check("privilege", "SeIncreaseQuotaPrivilege"))
    finish(lease)
  end)

  it("allows a restricted worker to create children with inherited and redirected streams", function()
    local lease, output = start(profile({ { path = root, access = "write" } }), {
      "python", "-u", "-c", table.concat({
        "import ctypes, json, os, subprocess",
        "from ctypes import wintypes as w",
        "k = ctypes.WinDLL('kernel32', use_last_error=True); k.OpenProcess.restype = w.HANDLE",
        "a = ctypes.WinDLL('advapi32', use_last_error=True)",
        "results = {}",
        "for access in [0x80, 0x40, 0x40000, 0x1fffff]:",
        " h = k.OpenProcess(access, False, os.getpid())",
        " results['self-' + str(access)] = True if h else ctypes.get_last_error()",
        " if h: k.CloseHandle(w.HANDLE(h))",
        "token = w.HANDLE()",
        "ok = a.OpenProcessToken(w.HANDLE(-1), 0xb, ctypes.byref(token))",
        "results['token'] = True if ok else ctypes.get_last_error()",
        "if ok: k.CloseHandle(token)",
        "k.CreateNamedPipeW.restype = w.HANDLE; k.CreateFileW.restype = w.HANDLE",
        "name = '\\\\\\\\.\\\\pipe\\\\NeoagentNativePipe-' + str(os.getpid())",
        "pipe = k.CreateNamedPipeW(ctypes.c_wchar_p(name), 0x40003, 0, 1, 65536, 65536, 0, None)",
        "if pipe == w.HANDLE(-1).value: results['named-pipe'] = ctypes.get_last_error()",
        "else:",
        " client = k.CreateFileW(ctypes.c_wchar_p(name), 0xc0040000, 0, None, 3, 0, None)",
        " if client == w.HANDLE(-1).value:",
        "  failure = {'code': ctypes.get_last_error()}",
        "  sd = ctypes.c_void_p(); text = ctypes.c_void_p()",
        "  if a.GetSecurityInfo(w.HANDLE(pipe), 6, 4, None, None, None, None, ctypes.byref(sd)) == 0:",
        "   if a.ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, 1, 4, ctypes.byref(text), None):",
        "    failure['dacl'] = ctypes.wstring_at(text); k.LocalFree(text)",
        "   k.LocalFree(sd)",
        "  results['named-pipe'] = failure",
        " else: results['named-pipe'] = True; k.CloseHandle(w.HANDLE(client))",
        " k.CloseHandle(w.HANDLE(pipe))",
        "for redirected in [False, True]:",
        " try:",
        "  result = subprocess.run(['cmd.exe', '/d', '/c', 'exit 0'], capture_output=redirected, timeout=5)",
        "  results['redirected-' + str(redirected)] = True if result.returncode == 0 else result.returncode",
        " except OSError as e: results['redirected-' + str(redirected)] = e.winerror",
        "print(json.dumps(results), flush=True)",
      }, "\n"),
    })
    helper.success(function() return assert(lease.wait_ready)(lease) end, 30000)
    local result = helper.success(function() return lease:wait() end, 15000)
    assert.is_nil(result.error, vim.inspect(result))
    assert.are.equal(0, result.code, vim.inspect(result))
    local observations = vim.json.decode(output())
    for _, value in pairs(observations) do
      assert.is_true(value, vim.inspect(observations))
    end
    assert.is_true(helper.complete(function() return lease:wait_release() end, 10000))
  end)

  it("creates native libuv pipes and subprocesses inside the restricted Neovim", function()
    local lease, output = start(profile({ { path = root, access = "write" } }), {
      assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l",
      assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_children.lua")),
    })
    helper.success(function() return assert(lease.wait_ready)(lease) end, 30000)
    local result = helper.success(function() return lease:wait() end, 15000)
    assert.is_nil(result.error, vim.inspect(result))
    assert.are.equal(0, result.code, vim.inspect(result))
    local observations = vim.json.decode(output())
    for _, value in pairs(observations) do
      assert.is_true(value, vim.inspect(observations))
    end
    assert.is_true(helper.complete(function() return lease:wait_release() end, 10000))
  end)

  it("preserves retained release while native finalization waits for another transaction", function()
    local selected = {
      id = "contended-native-release", network = "restricted",
      filesystem = { default = "read", entries = { { path = root, access = "write" } } },
      environment = { clear = true, inherit = {}, set = environment },
    }
    local placement = require("neoagent.sandbox.placement").new({
      profile = selected, platform = windows, nvim = vim.env.NEOAGENT_NVIM,
    })
    local processes = require("neoagent.process_sessions").new({ capacity = 1 }, nil,
      require("neoagent.sandbox.process_session").factory(placement, {}))
    owner = processes
    local admission = helper.success(function()
      return helper.admit(processes, {
        argv = { "python", "-u", "-c", "input(); print('finished')" }, cwd = root,
        stdio = { kind = "pipes", stdin = "open" }, timeout_ms = 60000,
      }, 0)
    end, 30000)
    local id = assert(admission.commit())
    local output = ""
    lock_holder = vim.system({ assert(vim.env.NEOAGENT_NVIM), "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l",
      assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_mutex.lua")) }, {
      stdin = true,
      stdout = function(_, bytes) output = output .. (bytes or "") end,
    })
    assert(vim.wait(10000, function() return output:find("LOCKED", 1, true) ~= nil end, 10))
    unlock_timer = assert(vim.uv.new_timer())
    unlock_timer:start(14000, 0, function()
      assert(lock_holder):write(nil)
    end)
    helper.success(function() return processes:interact(id, 0, { kind = "write", data = "finish\n" }) end)
    local released = helper.complete(function() return processes:wait_release(25000) end, 30000)
    assert.is_true(released, vim.inspect(processes:status()))
    assert.is_nil(processes:status().cleanup_error)
  end)
end)
