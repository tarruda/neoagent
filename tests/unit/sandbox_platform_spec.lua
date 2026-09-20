local assert = require("luassert")
local fs = require("neoagent.fs")
local protocol = require("neoagent.sandbox.protocol")

local function temporary_directory()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return assert(vim.uv.fs_realpath(path))
end

---@param command string
local function executable_path(command)
  local path = vim.fn.exepath(command)
  if path == "" then path = command end
  return assert(vim.uv.fs_realpath(path))
end

---@param environment? string[]|table<string, string|number>
---@return string
local function encoded_spec(environment)
  assert(type(environment) == "table")
  local encoded = environment.NEOAGENT_SANDBOX_SPEC
  if type(encoded) == "string" then return encoded end
  for _, value in ipairs(environment) do
    if type(value) == "string" then
      local selected = value:match("^NEOAGENT_SANDBOX_SPEC=(.*)$")
      if selected then return selected end
    end
  end
  error("sandbox specification is missing")
end

local function uses_low_level_lua()
  -- These versions provide -ll before editor initialization; 0.13+ uses -l.
  local version = (vim.version --[[@as fun(): vim.Version]])()
  return version.major == 0 and version.minor < 13
end

---@param root string
---@param extra? Neoagent.SandboxFilesystemEntry[]
---@return Neoagent.SandboxProfile
local function profile(root, extra)
  ---@type Neoagent.SandboxFilesystemEntry[]
  local entries = { { path = root, access = "write" } }
  vim.list_extend(entries, extra or {})
  return (assert(require("neoagent.sandbox.profile").validate({
    id = "platform-test",
    filesystem = {
      default = "read",
      entries = entries,
    },
    network = "restricted",
    environment = {
      clear = true,
      inherit = {},
      set = { PATH = "/bin:/usr/bin" },
    },
  })))
end

---@param value unknown
---@return Neoagent.Error
local function structured_error(value)
  assert(type(value) == "table", vim.inspect(value))
  assert(type(value.message) == "string")
  ---@cast value Neoagent.Error
  return value
end

---@param fn fun(): unknown
---@return Neoagent.Error
local function caught(fn)
  local ok, value = pcall(fn)
  assert.is_false(ok)
  assert(type(value) == "table", vim.inspect(value))
  ---@cast value Neoagent.Error
  return value
end

---@class Neoagent.TestSandboxRequest: Neoagent.SandboxWorkerRequest
---@field cwd string
---@field env table<string, string>

---@param root string
---@param active_profile? Neoagent.SandboxProfile
---@return Neoagent.TestSandboxRequest
local function request(root, active_profile)
  return {
    argv = { "/bin/sh", "-c", "true" },
    cwd = root,
    env = { PATH = "/bin:/usr/bin" },
    profile = active_profile or profile(root),
  }
end

---@param overrides Partial<Neoagent.SandboxFilesystemService>
---@return Neoagent.SandboxFilesystemService
local function filesystem(overrides)
  ---@type Neoagent.SandboxFilesystemService
  local value = vim.tbl_extend("force", fs, overrides)
  return value
end

---@param opts Neoagent.WorkerRequest?
---@param data string
---@param is_stderr boolean
local function emit_output(opts, data, is_stderr)
  local callback = is_stderr and assert(opts).on_stderr or assert(opts).on_stdout
  assert(callback)(data)
end

---@param opts Neoagent.WorkerRequest
---@return Neoagent.WorkerLease
local function completed_worker(opts)
  local result = {
      code = 0,
      signal = 0, stderr = "" }
  if opts.on_exit then
    opts.on_exit(result)
  end
  return {
    write = function()
      return true
    end,
    close_stdin = function()
      return true
    end,
    wait = function()
      return result
    end,
    terminate = function() end,
    dispose = function() end,
    }
end

describe("neoagent sandbox platform adapters", function()
  ---@type string[]
  local paths = {}
  ---@type (fun())[]
  local cleanups = {}
  local linux_it = vim.uv.os_uname().sysname == "Linux" and it or pending

  after_each(function()
    for index = #cleanups, 1, -1 do cleanups[index]() end
    cleanups = {}
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  ---@param callback fun()
  local function cleanup(callback)
    cleanups[#cleanups + 1] = callback
  end

  local function temp()
    local path = temporary_directory()
    paths[#paths + 1] = path
    return path
  end

  it("probes Linux through the standalone framed runtime", function()
    local seen = {}
    local status = require("neoagent.sandbox.linux").check({
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function(argv, opts, timeout)
        local encoded = encoded_spec(opts.env)
        seen[#seen + 1] = {
          argv = argv,
          opts = opts,
          timeout = timeout,
          spec = vim.json.decode(encoded),
        }
        if #seen == 1 then
          return {
            code = 125,
            signal = 0,
            stdout = protocol.encode({
              v = 1,
              type = "error",
              stage = "mount-proc",
              errno = 1,
            }),
            stderr = "",
          }
        end
        return {
          code = 0,
          signal = 0,
          stdout = protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }),
          stderr = "",
        }
      end,
      probe_timeout_ms = 321,
    })
    assert.is_true(status.ok)
    assert.is_true(assert(status.capabilities).process_supervision)
    assert.is_true(assert(status.capabilities).protected_create)
    assert.is_true(status.degraded)
    assert.are.equal("host", assert(status.capabilities).procfs)
    assert.matches("mount%-proc", (assert(status.degraded_reason)))
    assert.are.equal(2, #seen)
    assert.are.equal("fresh", seen[1].spec.procfs)
    assert.are.equal("host", seen[2].spec.procfs)
    assert.are.equal("deny", seen[2].spec.protected_create[1].access)
    assert.matches("protected%-create%-probe$",
      seen[2].spec.protected_create[1].path)
    assert.are.equal(321, seen[2].timeout)
    assert.are.equal(executable_path(assert(vim.env.NEOAGENT_NVIM)),
      seen[2].argv[1])
    if uses_low_level_lua() then
      assert.are.equal("-ll", seen[2].argv[#seen[2].argv - 1])
    else
      assert.is_true(vim.list_contains(seen[2].argv, "--headless"))
      assert.are.equal("-l", seen[2].argv[#seen[2].argv - 1])
    end
    assert.is_true(seen[2].opts.clear_env)
    if vim.version.lt((vim.version --[[@as fun(): vim.Version]])(), { 0, 11, 0 }) then
      assert.are.equal("string", type(seen[2].opts.env[1]))
    else
      assert.are.equal("string",
        type(encoded_spec(seen[2].opts.env)))
    end
    assert.are.equal("host", seen[2].spec.procfs)

    local failed = require("neoagent.sandbox.linux").check({
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function()
        return {
          code = 125,
          signal = 0,
          stdout = protocol.encode({
            v = 1,
            type = "error",
            stage = "mount-root",
            errno = 5,
          }),
          stderr = "",
        }
      end,
    })
    assert.is_false(failed.ok)
    assert.matches("mount%-root failed", (assert(failed.message)))

    local probes = 0
    failed = require("neoagent.sandbox.linux").check({
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function()
        probes = probes + 1
        if probes == 2 then return nil end
        return {
          code = 125,
          signal = 0,
          stdout = protocol.encode({
            v = 1,
            type = "error",
            stage = "mount-proc",
            errno = 1,
          }),
          stderr = "",
        }
      end,
    })
    assert.are.equal(2, probes)
    assert.are.equal("probe", failed.stage)
    assert.matches("timed out", assert(failed.message))
  end)

  linux_it("reads large Linux runtime specifications",
    function()
      local runtime = assert(vim.api.nvim_get_runtime_file(
        "scripts/sandbox_linux_runtime.lua", false)[1])
      local encoded = string.rep("x", 2048)
      local environment = {
        NEOAGENT_SANDBOX_SPEC = encoded,
      }
      if vim.version.lt((vim.version --[[@as fun(): vim.Version]])(), { 0, 11, 0 }) then
        environment = { "NEOAGENT_SANDBOX_SPEC=" .. encoded }
      end
      local argv = { executable_path(assert(vim.env.NEOAGENT_NVIM)) }
      if uses_low_level_lua() then
        vim.list_extend(argv, { "-ll", runtime })
      else
        vim.list_extend(argv, {
          "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", runtime,
        })
      end
      local completed = vim.system(argv, {
        clear_env = true,
        env = environment,
        text = false,
      }):wait(5000)
      local events, terminal = protocol.decode_all((assert(completed.stdout)))
      assert.are.equal(125, completed.code)
      assert.is_table(events)
      assert.are.equal("error", terminal.type)
      assert.are.equal("specification-json", terminal.stage)
    end)

  it("resolves a configured Linux Neovim command through PATH", function()
    local command = vim.fs.basename(vim.fn.exepath("nvim"))
    local expected = executable_path(command)
    ---@type string[]?
    local argv
    local status = require("neoagent.sandbox.linux").check({
      fs = fs,
      nvim = command,
      system = function(value)
        argv = value
        return {
          code = 0,
          signal = 0,
          stdout = protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }),
          stderr = "",
        }
      end,
    })
    assert.is_true(status.ok)
    assert.are.equal(expected, assert(argv)[1])
  end)

  it("uses the script-mode Linux runtime and map environment on Neovim 0.13", function()
    local original_version = vim.version
    local current = (original_version --[[@as fun(): vim.Version]])()
    local future = setmetatable({ lt = original_version.lt }, {
      __call = function()
        return setmetatable({ major = 0, minor = 13, patch = 0 }, {
          __index = current,
        })
      end,
    })
    rawset(vim, "version", future)
    cleanup(function() vim.version = original_version end)
    local argv, environment
    local status = require("neoagent.sandbox.linux").check({
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function(command, opts)
        argv, environment = command, opts.env
        return {
          code = 0,
          signal = 0,
          stdout = protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }),
          stderr = "",
        }
      end,
    })
    assert.is_true(status.ok)
    if not argv or not environment then
      error("Linux sandbox probe inputs were not captured")
    end
    assert.is_true(vim.list_contains(argv, "--headless"))
    assert.is_true(vim.list_contains(argv, "-l"))
    assert.is_string(environment.NEOAGENT_SANDBOX_SPEC)
  end)

  it("uses the legacy list environment for a Neovim 0.10 probe", function()
    local original_version = vim.version
    local current = (original_version --[[@as fun(): vim.Version]])()
    local legacy = setmetatable({ lt = original_version.lt }, {
      __call = function()
        return setmetatable({ major = 0, minor = 10, patch = 0 }, {
          __index = current,
        })
      end,
    })
    rawset(vim, "version", legacy)
    cleanup(function() vim.version = original_version end)
    ---@type string[]|table<string, string|number>|nil
    local environment
    local status = require("neoagent.sandbox.linux").check({
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function(_, opts)
        environment = opts.env
        return {
          code = 0,
          signal = 0,
          stdout = protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }),
          stderr = "",
        }
      end,
    })
    assert.is_true(status.ok)
    assert.is_true(vim.islist(environment))
    assert.is_string(encoded_spec(environment))
  end)

  it("resolves a reconstructed Linux Neovim command through PATH", function()
    local original_open = vim.uv.fs_open
    local original_read = vim.uv.fs_read
    local original_close = vim.uv.fs_close
    local proc = {}
    vim.uv.fs_open = function(path, ...)
      if path == "/proc/self/cmdline" then return proc end
      return original_open(path, ...)
    end
    vim.uv.fs_read = function(fd, ...)
      if fd == proc then return "nvim\0" .. vim.v.argv[1] .. "\0" end
      return original_read(fd, ...)
    end
    vim.uv.fs_close = function(fd)
      if fd == proc then return true end
      return original_close(fd)
    end
    ---@type string[]?
    local argv
    local checked, status = pcall(
      require("neoagent.sandbox.linux").check, {
        fs = fs,
        system = function(value)
          argv = value
          return {
            code = 0,
            signal = 0,
            stdout = protocol.encode({ v = 1, type = "ready" })
              .. protocol.encode({
                v = 1, type = "exit", code = 0, signal = 0,
              }),
            stderr = "",
          }
        end,
      })
    vim.uv.fs_open = original_open
    vim.uv.fs_read = original_read
    vim.uv.fs_close = original_close
    assert.is_true(checked, tostring(status))
    assert.is_true(status.ok)
    assert.are.equal(executable_path("nvim"), assert(argv)[1])
  end)

  it("keeps Linux staging outside filesystem profile grants", function()
    local root = temp()
    local linux = require("neoagent.sandbox.linux")
    local staging_grants
    if vim.uv.os_uname().sysname == "Linux" then
      staging_grants = {
        { path = assert(vim.uv.fs_realpath("/run")), access = "read" },
        { path = assert(vim.uv.fs_realpath("/dev/shm")), access = "read" },
      }
    else
      staging_grants = {
        {
          path = assert(vim.uv.fs_realpath(vim.uv.os_tmpdir())),
          access = "read",
        },
      }
    end
    local active_profile = profile(root, staging_grants)
    local created = false
    local err = caught(function()
      linux.start_worker(request(root, active_profile), {
        fs = filesystem({
          create_temp_directory = function()
            created = true
            error("must not create")
          end,
        }),
        nvim = vim.env.NEOAGENT_NVIM,
        start_worker = function() error("must not run") end,
      })
    end)
    assert.is_false(created)
    assert.matches("filesystem profile exposes", tostring(err.detail))
  end)

  linux_it("rejects Linux worker bootstrap paths denied exactly or by an ancestor", function()
    local root = temp()
    local bootstrap = assert(vim.uv.fs_realpath(assert(vim.api.nvim_get_runtime_file(
      "scripts/tool_worker.lua", false)[1])))
    local parent = vim.fs.dirname(bootstrap)
    assert.is_string(parent)
    ---@cast parent string
    ---@type string[]
    local denied_paths = { bootstrap, parent }
    for _, denied in ipairs(denied_paths) do
      ---@type Neoagent.SandboxFilesystemEntry[]
      local denied_entry = { { path = denied, access = "deny" } }
      local started = false
      local err = caught(function()
        require("neoagent.sandbox.linux").start_worker({
          argv = { "/bin/sh", "-c", "true" },
          cwd = root,
          env = { PATH = "/bin:/usr/bin" },
          profile = profile(root, denied_entry),
          bootstrap_paths = { bootstrap },
        }, {
          fs = fs,
          nvim = vim.env.NEOAGENT_NVIM,
          capabilities = { procfs = "host" },

          start_worker = function()
            started = true
            error("must not start")
          end,
        })
      end)
      assert.is_false(started)
      assert.are.equal("sandbox_unavailable", err.kind)
      assert.matches("denies required bootstrap path", err.message)
    end

    local relative = caught(function()
      require("neoagent.sandbox.linux").start_worker({
        argv = { "/bin/sh", "-c", "true" },
        cwd = root,
        env = { PATH = "/bin:/usr/bin" },
        profile = profile(root),
        bootstrap_paths = { "relative" },
      }, {
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        capabilities = { procfs = "host" },
        start_worker = function() error("must not start") end,
      })
    end)
    assert.are.equal("sandbox_unavailable", relative.kind)
    assert.matches("bootstrap path is not absolute", relative.message)
  end)

  linux_it("honors explicit Linux bootstrap exceptions beneath denied ancestors", function()
    local root = temp()
    local bootstrap = assert(vim.uv.fs_realpath(assert(vim.api.nvim_get_runtime_file(
      "scripts/tool_worker.lua", false)[1])))
    local active_profile = profile(root, {
      { path = assert(vim.fs.dirname(bootstrap)), access = "deny" },
      { path = bootstrap, access = "read" },
    })
    local started = false
    local child = require("neoagent.sandbox.linux").start_worker({
      argv = { "/bin/sh", "-c", "true" },
      cwd = root,
      env = { PATH = "/bin:/usr/bin" },
      profile = active_profile,
      bootstrap_paths = { bootstrap },
    }, {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      capabilities = { procfs = "host" },

      start_worker = function(request_value)
        started = true
        assert(request_value.on_stdout)(protocol.encode({ v = 1, type = "ready" })
          .. protocol.encode({ v = 1, type = "exit", code = 0, signal = 0 }))
        assert(request_value.on_exit)({ code = 0, signal = 0, stderr = "" })
        return {
          write = function() return true end,
          close_stdin = function() return true end,
          terminate = function() end,
          wait = function() return { code = 0, signal = 0, stderr = "" } end,
          dispose = function() end,
        }
      end,
    })
    assert.is_true(started)
    assert.are.equal(0, child:wait().code)
    child:dispose("test complete")
  end)

  linux_it("preserves exact and inherited writes for Linux worker bootstrap paths", function()
    local root = temp()
    local nested = vim.fs.joinpath(root, "bootstrap")
    assert(fs.mkdirp(nested))
    local active_profile = profile(root)

    for _, bootstrap in ipairs({ root, nested }) do
      ---@type Neoagent.WorkerRequest?
      local started_request
      local child = require("neoagent.sandbox.linux").start_worker({
        argv = { "/bin/sh", "-c", "true" },
        cwd = root,
        env = { PATH = "/bin:/usr/bin" },
        profile = active_profile,
        bootstrap_paths = { bootstrap },
      }, {
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        capabilities = { procfs = "host" },

        start_worker = function(request_value)
          started_request = request_value
          assert(request_value.on_stdout)(protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({ v = 1, type = "exit", code = 0, signal = 0 }))
          assert(request_value.on_exit)({ code = 0, signal = 0, stderr = "" })
          return {
            write = function()
              return true
            end,
            close_stdin = function()
              return true
            end,
            terminate = function() end,
            wait = function()
              return { code = 0, signal = 0, stderr = "" }
            end,
            dispose = function() end,
          }
        end,
      })
      local spec = vim.json.decode(encoded_spec(assert(started_request).env))
      local access = spec.profile.filesystem.default
      local specificity = -1
      for _, entry in ipairs(spec.profile.filesystem.entries) do
        if
          (entry.path == bootstrap or bootstrap:sub(1, #entry.path + 1) == entry.path .. "/")
          and #entry.path > specificity
        then
          access = entry.access
          specificity = #entry.path
        end
      end
      assert.are.equal("write", access, bootstrap)
      assert.are.equal(0, child:wait().code)
      child:dispose("test complete")
    end
  end)

  it("starts macOS streaming workers with explicit bootstrap grants", function()
    local root = temp()
    local macos = require("neoagent.sandbox.macos")
    local active_profile = profile(root)
    local captured
    local returned = {
      write = function() return true end,
      close_stdin = function() return true end,
      terminate = function() end,
      wait = function() return { code = 0, signal = 0, stderr = "" } end,
      dispose = function() end,
    }
    local child = macos.start_worker({
      argv = { "/bin/sh", "-c", "true" },
      cwd = root,
      env = { PATH = "/bin:/usr/bin" },
      profile = active_profile,
      bootstrap_paths = { root .. "/bootstrap" },
      kill_grace_ms = 1,
    }, {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      sandbox_exec = "/bin/true",
      start_worker = function(value)
        captured = value
        return returned
      end,
    })
    assert.is_true((child:write("request")))
    local captured_request = captured or error("macOS child request was not captured")
    assert.are.equal(root, captured_request.cwd)
    assert.are.equal(100, captured_request.kill_grace_ms)
    local specification = vim.json.decode(captured_request.env.NEOAGENT_MACOS_SANDBOX_SPEC)
    assert.are.equal("run", specification.mode)
    assert.are.same({ PATH = "/bin:/usr/bin" }, specification.env)
    local found_bootstrap = false
    for _, value in ipairs(specification.argv) do
      found_bootstrap = found_bootstrap or value:find(root .. "/bootstrap", 1, true) ~= nil
    end
    assert.is_true(found_bootstrap)
    captured_request.on_stdout(protocol.encode({ v = 1, type = "ready" })
      .. protocol.encode({ v = 1, type = "exit", code = 0, signal = 0 }))
    captured_request.on_exit({ code = 0, signal = 0, stderr = "" })
    assert.are.equal(0, child:wait().code)

    macos.start_worker({
      argv = { "/bin/sh", "-c", "true" }, cwd = root,
      env = { PATH = "/bin:/usr/bin" }, profile = active_profile,
    }, {
      fs = fs,
      nvim = { assert(vim.env.NEOAGENT_NVIM), "--cmd", "let g:neoagent_launcher = 1" },
      sandbox_exec = "/bin/true",
      start_worker = function(value)
        captured = value
        return returned
      end,
    })
    local launcher_request = captured or error("macOS launcher request was not captured")
    local launcher_args = launcher_request.argv
    local found_launcher = false
    for index, value in ipairs(launcher_args) do
      if value == "--cmd" then
        assert.are.equal("let g:neoagent_launcher = 1", launcher_args[index + 1])
        found_launcher = true
      end
    end
    assert.is_true(found_launcher, "macOS discarded the Neovim launcher arguments")

    local process_module = require("neoagent.process")
    local original_run = process_module.run
    cleanup(function() process_module.run = original_run end)
    for _, recovered in ipairs({ 0, 17 }) do
      local recovery
      process_module.run = function(command, opts)
        local encoded = assert(assert(opts).env).NEOAGENT_MACOS_SANDBOX_SPEC
        assert.is_string(encoded)
        ---@cast encoded string
        recovery = vim.json.decode(encoded)
        assert.are.equal(executable_path(assert(vim.env.NEOAGENT_NVIM)), command[1])
        return { code = recovered, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
      end
      local failed = macos.start_worker({
        argv = { "/bin/sh", "-c", "true" }, cwd = root,
        env = {}, profile = active_profile,
      }, {
        fs = fs, nvim = vim.env.NEOAGENT_NVIM, sandbox_exec = "/bin/true",
        start_worker = function(value) captured = value return returned end,
      })
      local failed_request = captured or error("failed macOS request was not captured")
      local failed_specification = vim.json.decode(failed_request.env.NEOAGENT_MACOS_SANDBOX_SPEC)
      failed_request.on_exit({ code = 137, signal = 9, stderr = "" })
      assert.are.same({ mode = "cleanup", scope = failed_specification.scope }, recovery)
      assert.is_not_nil(failed:wait().error)
    end
    process_module.run = original_run

    local denied_profile = profile(root, {
      { path = root .. "/bootstrap", access = "deny" },
    })
    local denied_started = false
    local denied, denied_err = pcall(macos.start_worker, {
      argv = { "/bin/sh", "-c", "true" },
      cwd = root,
      env = { PATH = "/bin:/usr/bin" },
      profile = denied_profile,
      bootstrap_paths = { root .. "/bootstrap" },
    }, {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      sandbox_exec = "/bin/true",
      start_worker = function()
        denied_started = true
        error("must not start")
      end,
    })
    assert.is_false(denied)
    assert.is_false(denied_started)
    assert.matches(
      "denies required bootstrap path",
      structured_error(denied_err).message
    )

    local original_runtime = vim.api.nvim_get_runtime_file
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "scripts/sandbox_macos_runtime.lua" then
        return {}
      end
      return original_runtime(path, all)
    end
    local found, missing = pcall(macos.start_worker, {
      argv = { "/bin/true" }, cwd = root, env = {}, profile = active_profile,
    }, {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
    })
    vim.api.nvim_get_runtime_file = original_runtime
    assert.is_false(found)
    assert.matches("runtime was not found", structured_error(missing).message)

    local started, start_err = pcall(macos.start_worker, {
      argv = { "/bin/true" }, cwd = root, env = {}, profile = active_profile,
    }, {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      sandbox_exec = "/bin/true",
      start_worker = function() error("macOS spawn failed") end,
    })
    assert.is_false(started)
    assert.matches("Could not start macOS", structured_error(start_err).message)
  end)

  linux_it("fails Linux streaming worker setup without leaking staging roots", function()
    local root = temp()
    local linux = require("neoagent.sandbox.linux")
    local active_profile = profile(root)
    ---@param request_value Neoagent.TestSandboxRequest
    ---@param overrides? {fs?: Neoagent.SandboxFilesystemService, start_worker?: fun(request: Neoagent.WorkerRequest): Neoagent.WorkerLease}
    local function launch(request_value, overrides)
      ---@type Neoagent.SandboxExecutionServices<string>
      local services = {
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        capabilities = { procfs = "host" },
      }
      if overrides and overrides.fs then services.fs = overrides.fs end
      if overrides and overrides.start_worker then services.start_worker = overrides.start_worker end
      ---@type Neoagent.SandboxWorkerRequest
      local child_request = {
        argv = request_value.argv,
        cwd = request_value.cwd,
        env = request_value.env,
        profile = request_value.profile,
      }
      return linux.start_worker(child_request, services)
    end
    local original_runtime = vim.api.nvim_get_runtime_file
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "scripts/sandbox_linux_runtime.lua" then
        return {}
      end
      return original_runtime(path, all)
    end
    local ok, err = pcall(launch, request(root, active_profile))
    vim.api.nvim_get_runtime_file = original_runtime
    assert.is_false(ok)
    assert.matches("runtime was not found", structured_error(err).message)

    ok, err = pcall(launch, request(root, active_profile), {
      fs = filesystem({ create_temp_directory = function()
        return nil, "staging unavailable"
      end,
      }),
    })
    assert.is_false(ok)
    assert.matches("Could not create Linux sandbox root", structured_error(err).message)

    local invalid_root = vim.fs.joinpath(root, "not-a-directory")
    assert(fs.write_all(invalid_root, "preserve"))
    ok, err = pcall(launch, request(root, active_profile), {
      fs = filesystem({ create_temp_directory = function() return invalid_root end }),
      start_worker = function() error("must not launch without a directory") end,
    })
    assert.is_false(ok)
    assert.matches("temporary root is not a directory", tostring(structured_error(err).detail))
    assert.are.equal("preserve", fs.read(invalid_root))

    local relative = request(root, active_profile)
    relative.argv[1] = "sh"
    local leased = launch(relative, { start_worker = function(opts)
      local separator = assert(vim.fn.index(opts.argv, "--")) + 1
      assert.are.equal(vim.uv.fs_realpath(vim.fn.exepath("sh")), opts.argv[separator + 1])
      emit_output(opts, protocol.encode({ v = 1, type = "ready" })
        .. protocol.encode({ v = 1, type = "exit", code = 0, signal = 0 }), false)
      return completed_worker(opts)
    end })
    assert.are.equal(0, leased:wait().code)

    local missing = request(root, active_profile)
    missing.argv = { "not-a-real-program" }
    ok, err = pcall(launch, missing)
    assert.is_false(ok)
    assert.matches("executable was not found", structured_error(err).message)

    ok, err = pcall(launch, request(root, active_profile), {
      start_worker = function() error("Linux spawn failed") end,
    })
    assert.is_false(ok)
    assert.matches("Could not start Linux", structured_error(err).message)

    for _, failure in ipairs({ "specification", "spawn" }) do
      local original_rmdir = vim.uv.fs_rmdir
      local failed_root
      vim.uv.fs_rmdir = function(path)
        failed_root = path
        return nil, "cleanup denied"
      end
      if failure == "specification" then
        ok, err = pcall(launch, missing)
      else
        ok, err = pcall(launch, request(root, active_profile), {
          start_worker = function() error("Linux spawn failed") end,
        })
      end
      vim.uv.fs_rmdir = original_rmdir
      if failed_root then vim.fn.delete(failed_root, "rf") end
      assert.is_false(ok)
      assert.matches("Could not remove Linux sandbox root",
        structured_error(err).message)
    end

    local original_lstat = vim.uv.fs_lstat
    local selected_root
    local inspections = 0
    local changed_fs = filesystem({ create_temp_directory = function(prefix, directory)
      local path = assert(fs.create_temp_directory(prefix, directory))
      selected_root = path
      return path
    end,
    })
    vim.uv.fs_lstat = function(path)
      local stat, stat_err, stat_name = original_lstat(path)
      if selected_root and path == selected_root then
        inspections = inspections + 1
        if inspections > 1 and stat then
          stat = vim.deepcopy(stat)
          stat.ino = stat.ino == 1 and 2 or 1
        end
      end
      return stat, stat_err, stat_name
    end
    ok, err = pcall(launch, request(root, active_profile), { fs = changed_fs })
    vim.uv.fs_lstat = original_lstat
    if selected_root then
      vim.fn.delete(selected_root, "rf")
    end
    assert.is_false(ok)
    assert.matches("identity changed", structured_error(err).message)
  end)

  it("keeps missing Linux restricted paths out of the host namespace", function()
    local root = temp()
    local nested = vim.fs.joinpath(root, "missing", "parent", "blocked")
    local readonly = vim.fs.joinpath(root, "also-protected")
    local linux = require("neoagent.sandbox.linux")
    local active_profile = profile(root, {
      { path = nested, access = "deny" },
      { path = readonly, access = "read" },
    })
    local observed
    linux.start_worker(request(root, active_profile), {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      start_worker = function(opts)
        observed = vim.uv.fs_lstat(nested)
        local spec = vim.json.decode(encoded_spec(assert(opts).env))
        assert.are.same({
          { path = readonly, access = "read" },
          { path = nested, access = "deny" },
        }, spec.protected_create)
        emit_output(opts, protocol.encode({ v = 1, type = "ready" })
          .. protocol.encode({
            v = 1, type = "exit", code = 0, signal = 0,
          }), false)
        return completed_worker(opts)
      end,
    })
    assert.is_nil(observed)
    assert.is_nil(vim.uv.fs_stat(vim.fs.dirname(nested)))
  end)

  it("leaves substituted Linux sandbox roots untouched", function()
    local root = temp()
    local linux = require("neoagent.sandbox.linux")
    for _, replacement in ipairs({ "directory", "symlink", "missing" }) do
      ---@type string?
      local sandbox_path
      ---@type string?
      local owned_path
      ---@type string?
      local replacement_target
      local lease = linux.start_worker(request(root), {
          fs = fs,
          nvim = vim.env.NEOAGENT_NVIM,
        start_worker = function(opts)
            local spec = vim.json.decode(
              encoded_spec(assert(opts).env))
            sandbox_path = spec.root
            owned_path = sandbox_path .. ".owned"
            assert(vim.uv.fs_rename(sandbox_path, owned_path))
            if replacement == "directory" then
              assert(vim.uv.fs_mkdir(sandbox_path, 448))
            elseif replacement == "symlink" then
              replacement_target = sandbox_path .. ".target"
              assert(vim.uv.fs_mkdir(replacement_target, 448))
              assert(fs.write_all(
                vim.fs.joinpath(replacement_target, "preserve"), "data"))
              assert(vim.uv.fs_symlink(replacement_target, sandbox_path))
            end
            emit_output(opts, protocol.encode({ v = 1, type = "ready" })
              .. protocol.encode({
                v = 1, type = "exit", code = 0, signal = 0,
              }), false)
            return completed_worker(opts)
        end,
        })
      local err = assert(lease:wait().error)
      assert.matches("Could not clean native sandbox resources", err.message)
      if replacement == "directory" then
        assert.are.equal("directory",
          assert(vim.uv.fs_lstat((assert(sandbox_path)))).type)
      elseif replacement == "symlink" then
        assert.are.equal("link",
          assert(vim.uv.fs_lstat((assert(sandbox_path)))).type)
        assert.are.equal("data", assert(fs.read(
          vim.fs.joinpath((assert(replacement_target)), "preserve"))))
        vim.fn.delete((assert(sandbox_path)))
      else
        assert.is_nil(vim.uv.fs_lstat((assert(sandbox_path))))
      end
      vim.fn.delete((assert(owned_path)), "rf")
      if replacement == "directory" then
        vim.fn.delete((assert(sandbox_path)), "rf")
      end
      if replacement_target then vim.fn.delete(replacement_target, "rf") end
    end
  end)

  it("refuses a Linux sandbox root substituted before use", function()
    local root = temp()
    local linux = require("neoagent.sandbox.linux")
    ---@type string?
    local sandbox_path
    ---@type string?
    local owned_path
    ---@type string?
    local replacement_path
    local root_checks = 0
    ---@type uv.fs_stat.result?
    local root_identity
    local original_lstat = vim.uv.fs_lstat
    local filesystem = setmetatable({
      create_temp_directory = function(prefix)
        sandbox_path = assert(fs.create_temp_directory(prefix))
        sandbox_path = assert(vim.uv.fs_realpath((assert(sandbox_path))))
        owned_path = sandbox_path .. ".owned"
        replacement_path = vim.fs.joinpath(sandbox_path, "preserve")
        return sandbox_path
      end,
    }, { __index = fs })
    vim.uv.fs_lstat = function(path)
      if path == sandbox_path then
        root_checks = root_checks + 1
        if root_checks == 2 then
          assert(vim.uv.fs_rename((assert(sandbox_path)), assert(owned_path)))
          assert(vim.uv.fs_mkdir((assert(sandbox_path)), 448))
          assert(fs.write_all(assert(replacement_path), "replacement"))
        end
      end
      local stat = original_lstat(path)
      if path == sandbox_path and stat then
        if root_checks == 1 then
          root_identity = vim.deepcopy(stat)
        elseif root_checks >= 2 then
          stat.dev = assert(root_identity).dev
          stat.ino = assert(root_identity).ino
          stat.birthtime = {
            sec = assert(root_identity).birthtime.sec + 1,
            nsec = assert(root_identity).birthtime.nsec,
          }
        end
      end
      return stat
    end
    local launched = false
    local ok, err = pcall(function()
      linux.start_worker(request(root), {
        fs = filesystem,
        nvim = vim.env.NEOAGENT_NVIM,
        start_worker = function()
          launched = true
          error("must not run")
        end,
      })
    end)
    vim.uv.fs_lstat = original_lstat
    assert.is_false(ok)
    assert.is_false(launched)
    assert.matches("root identity changed before use", structured_error(err).message)
    assert.are.equal("replacement", assert(fs.read(assert(replacement_path))))
    vim.fn.delete((assert(owned_path)), "rf")
    vim.fn.delete((assert(sandbox_path)), "rf")
  end)

  it("reports Linux probe requirement and protocol failures", function()
    local linux = require("neoagent.sandbox.linux")
    local original_arch = jit.arch
    jit.arch = "mips"
    local unsupported = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
    })
    jit.arch = original_arch
    assert.are.equal("architecture", unsupported.stage)

    local get_runtime_file = vim.api.nvim_get_runtime_file
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "scripts/sandbox_linux_runtime.lua" then return {} end
      return get_runtime_file(path, all)
    end
    local checked, missing_runtime = pcall(linux.check, {
      nvim = vim.env.NEOAGENT_NVIM,
    })
    local root = temp()
    local launched, launch_err = pcall(function()
      linux.start_worker(request(root), {
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        start_worker = function() error("must not run") end,
      })
    end)
    vim.api.nvim_get_runtime_file = get_runtime_file
    assert.is_true(checked)
    assert.are.equal("runtime", missing_runtime.stage)
    assert.is_false(launched)
    assert.matches("Linux sandbox runtime was not found",
      structured_error(launch_err).message)

    local original_fs_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, flags, mode)
      if path == "/proc/self/cmdline" then return nil end
      return original_fs_open(path, flags, mode)
    end
    ---@type string[]?
    local fallback_argv
    local fallback_ok, fallback_err = pcall(function()
      linux.start_worker(request(root), {
        fs = fs,
        start_worker = function(opts)
          local argv = opts.argv
          fallback_argv = argv
          emit_output(opts, protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }), false)
          return completed_worker(opts)
        end,
      })
    end)
    vim.uv.fs_open = original_fs_open
    assert.is_true(fallback_ok, tostring(fallback_err))
    assert.are.equal(vim.v.progpath, assert(fallback_argv)[1])

    local missing_nvim = linux.check({
      nvim = "/definitely/missing/nvim",
    })
    assert.are.equal("nvim", missing_nvim.stage)
    assert.are.equal("nvim", linux.check({
      nvim = "neoagent-unavailable-nvim-for-platform-regression",
    }).stage)
    assert.are.equal("nvim", linux.check({
      nvim = { true --[[@as string]],
        },
    }).stage)

    local original_fs_read = vim.uv.fs_read
    original_fs_open = vim.uv.fs_open
    local original_close = vim.uv.fs_close
    local proc = {}
    vim.uv.fs_open = function(path, ...)
      if path == "/proc/self/cmdline" then return proc end
      return original_fs_open(path, ...)
    end
    vim.uv.fs_read = function(fd, ...)
      if fd == proc then return nil end
      return original_fs_read(fd, ...)
    end
    vim.uv.fs_close = function(fd)
      if fd == proc then return true end
      return original_close(fd)
    end
    local read_failure = linux.check({
      fs = fs,
      system = function()
        return {
          code = 0,
          signal = 0,
          stdout = protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }),
          stderr = "",
        }
      end,
    })
    vim.uv.fs_open, vim.uv.fs_read, vim.uv.fs_close =
      original_fs_open, original_fs_read, original_close
    assert.is_true(read_failure.ok)

    local original_realpath = vim.uv.fs_realpath
    local staging_paths
    if vim.uv.os_uname().sysname == "Linux" then
      staging_paths = {
        ["/run/user/" .. tostring(vim.uv.getuid())] = true,
        ["/dev/shm"] = true,
      }
    else
      staging_paths = { [vim.uv.os_tmpdir()] = true }
    end
    vim.uv.fs_realpath = function(path)
      if staging_paths[path] then return nil end
      return original_realpath(path)
    end
    local missing_staging = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
    })
    vim.uv.fs_realpath = original_realpath
    assert.are.equal("temporary-root", missing_staging.stage)
    assert.matches("staging directory is unavailable",
      (assert(missing_staging.message)))

    local temporary_failure = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = filesystem({
        create_temp_directory = function()
          return nil, "no temporary root"
        end,
      }),
    })
    assert.are.equal("temporary-root", temporary_failure.stage)

    local timeout = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = fs,
      system = function() return nil end,
    })
    assert.are.equal("probe", timeout.stage)
    assert.matches("timed out", (assert(timeout.message)))

    local malformed = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = fs,
      system = function()
        return { code = 125, signal = 0, stdout = "invalid", stderr = "" }
      end,
    })
    assert.are.equal("probe", malformed.stage)
    assert.matches("invalid sandbox protocol frame length",
      (assert(malformed.message)))

    local stderr = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = fs,
      system = function()
        return {
          code = 2, signal = 0,
          stdout = protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 2, signal = 0,
            }),
          stderr = "probe process failed " .. string.rep("x", 2000),
        }
      end,
    })
    assert.matches("probe process failed", (assert(stderr.message)))
    assert.are.equal(1000, #assert(stderr.message))
    assert.are.equal("...", assert(stderr.message):sub(-3))

    local original_rmdir = vim.uv.fs_rmdir
    ---@type string?
    local cleanup_root
    vim.uv.fs_rmdir = function(path)
      cleanup_root = path
      return nil, "cleanup denied"
    end
    local cleanup_status = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = fs,
      system = function()
        return {
          code = 0,
          signal = 0,
          stdout = protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }),
          stderr = "",
        }
      end,
    })
    vim.uv.fs_rmdir = original_rmdir
    if cleanup_root then vim.fn.delete(cleanup_root, "rf") end
    assert.are.equal("probe-cleanup", cleanup_status.stage)
  end)

  it("probes native macOS sandbox-exec", function()
    local root = temp()
    local executable = vim.fs.joinpath(root, "sandbox-exec")
    assert(fs.write_all(executable, "#!/bin/sh\nexit 0\n"))
    assert(vim.uv.fs_chmod(executable, 493))
    local nvim = executable_path(assert(vim.env.NEOAGENT_NVIM))
    local macos = require("neoagent.sandbox.macos")
    ---@type [string[], vim.SystemOpts, integer]?
    local checked
    local status = macos.check({
      sandbox_exec = executable,
      nvim = nvim,
      system = function(argv, opts, timeout)
        checked = { argv, opts, timeout }
        return { code = 0, signal = 0, stdout = "", stderr = "" }
      end,
    })
    assert.is_true(status.ok)
    assert.are.equal(executable, assert(checked)[1][1])
    assert.is_true(macos.check({
      sandbox_exec = executable,
      nvim = executable,
    }).ok)
    ---@type integer?
    local separator
    for index, value in ipairs(assert(checked)[1]) do
      if value == "--" then separator = index break end
    end
    assert.are.equal(nvim, assert(checked)[1][assert(separator) + 1])
  end)

  it("fails macOS requirements and execution closed", function()
    local root = temp()
    local executable = vim.fs.joinpath(root, "sandbox-exec")
    assert(fs.write_all(executable, "#!/bin/sh\nexit 0\n"))
    assert(vim.uv.fs_chmod(executable, 493))
    local macos = require("neoagent.sandbox.macos")
    assert.are.equal("sandbox-exec", macos.check({
      sandbox_exec = vim.fs.joinpath(root, "missing"),
    }).stage)
    assert.are.equal("nvim", macos.check({
      sandbox_exec = executable,
      nvim = vim.fs.joinpath(root, "missing-nvim"),
    }).stage)
    assert.are.equal("nvim", macos.check({
      sandbox_exec = executable,
      nvim = true --[[@as string]],
    }).stage)
    local get_runtime_file = vim.api.nvim_get_runtime_file
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "scripts/sandbox_macos_runtime.lua" then return {} end
      return get_runtime_file(path, all)
    end
    local checked, missing_runtime = pcall(macos.check, {
      sandbox_exec = executable,
      nvim = vim.env.NEOAGENT_NVIM,
    })
    local exec_ok, exec_err = pcall(function()
      macos.start_worker(request(root), {
        sandbox_exec = executable,
        nvim = vim.env.NEOAGENT_NVIM,
        fs = fs,
        start_worker = function() error("must not run") end,
      })
    end)
    vim.api.nvim_get_runtime_file = get_runtime_file
    assert.is_true(checked)
    assert.are.equal("runtime", missing_runtime.stage)
    assert.is_false(exec_ok)
    assert.matches("sandbox runtime was not found", structured_error(exec_err).message)
    local failed_probe = macos.check({
      sandbox_exec = executable,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function() return nil end,
    })
    assert.are.equal("runtime-probe", failed_probe.stage)
    assert.matches("probe failed", (assert(failed_probe.message)))
    failed_probe = macos.check({
      sandbox_exec = executable,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function()
        return {
          code = 1, signal = 0, stdout = "", stderr = string.rep("x", 2000),
        }
      end,
    })
    assert.are.equal(1000, #assert(failed_probe.message))
    assert.matches("%.%.%.$", assert(failed_probe.message))

    local probes = 0
    local sandbox_failure = macos.check({
      sandbox_exec = executable, nvim = vim.env.NEOAGENT_NVIM,
      system = function()
        probes = probes + 1
        return { code = probes == 1 and 0 or 1, signal = 0, stdout = "", stderr = "policy rejected" }
      end,
    })
    assert.are.equal("sandbox-exec-probe", sandbox_failure.stage)
    assert.are.equal("policy rejected", sandbox_failure.message)

  end)

  it("resolves configured macOS sandbox and Neovim commands through PATH", function()
    local root = temp()
    local executable = vim.fs.joinpath(root, "sandbox-exec")
    assert(fs.write_all(executable, "#!/bin/sh\nexit 0\n"))
    assert(vim.uv.fs_chmod(executable, 493))
    local original_path = vim.env.PATH
    cleanup(function() vim.env.PATH = original_path end)
    vim.env.PATH = root .. (jit.os == "Windows" and ";" or ":") .. (original_path or "")
    local command = vim.fs.basename(vim.fn.exepath("nvim"))
    local expected = executable_path(command)
    ---@type string[]?
    local argv
    local status = require("neoagent.sandbox.macos").check({
      sandbox_exec = "sandbox-exec",
      nvim = command,
      system = function(value)
        argv = value
        return { code = 0, signal = 0, stdout = "", stderr = "" }
      end,
    })
    assert.is_true(status.ok)
    assert.are.equal(executable_path(executable), assert(argv)[1])
    ---@type integer?
    local separator
    for index, value in ipairs(assert(argv)) do
      if value == "--" then separator = index break end
    end
    assert.are.equal(expected, assert(argv)[assert(separator) + 1])
  end)

  it("compiles profiles into enforceable Windows ACL roots", function()
    local existing = {
      ["c:\\repo"] = true,
      ["c:\\repo\\.git"] = true,
      ["c:\\temp"] = true,
      ["c:\\secret"] = true,
      ["c:\\ärea"] = true,
      ["c:\\ärea\\protected"] = true,
    }
    local paths = require("neoagent.sandbox.path").windows({
      realpath = function(path)
        return existing[vim.fn.tolower((path:gsub("/", "\\")))]
          and path or nil
      end,
      stat = function(path)
        if not existing[vim.fn.tolower((path:gsub("/", "\\")))] then return nil end
        local stat = assert(vim.uv.fs_stat("."))
        stat.type = "directory"
        return stat
      end,
    })
    local active = assert(require("neoagent.sandbox.profile").validate({
      id = "windows-platform-test",
      filesystem = {
        default = "read",
        entries = {
          { path = "C:\\Repo", access = "write" },
          { path = "C:\\Repo\\.git", access = "read" },
          { path = "C:\\Secret", access = "deny" },
          { path = "C:\\Temp", access = "write" },
          { path = "C:\\Ärea", access = "write" },
          { path = "c:\\ärea\\protected", access = "read" },
        },
      },
      network = "restricted",
      environment = {
        clear = true,
        inherit = {},
        set = {},
      },
    }, { paths = paths }))
    local compiled = require("neoagent.sandbox.windows.compile").compile(
      active, { paths = paths })
    assert.are.same({
      "C:\\Repo",
      "C:\\Temp",
      "C:\\Ärea",
    }, compiled.write_roots)
    assert.are.same({
      "C:\\Secret",
      "C:\\Repo\\.git",
      "C:\\ärea\\protected",
    }, compiled.deny_write)
    assert.are.same({ "C:\\Secret" }, compiled.deny_read)
    assert.are.same({
      { access = "read", path = "C:\\Repo\\.git" },
      { access = "read", path = "C:\\ärea\\protected" },
    }, compiled.protected_create)

    existing["c:\\repo\\.git"] = nil
    compiled = require("neoagent.sandbox.windows.compile").compile(
      active, { paths = paths })
    assert.are.same({
      { access = "read", path = "C:\\Repo\\.git" },
      { access = "read", path = "C:\\ärea\\protected" },
    }, compiled.protected_create)
    existing["c:\\repo\\.git"] = true

    local reopened = vim.deepcopy(active)
    reopened.filesystem.entries[#reopened.filesystem.entries + 1] = {
      path = "C:\\Repo\\.git\\worktree",
      access = "write",
    }
    existing["c:\\repo\\.git\\worktree"] = true
    compiled = require("neoagent.sandbox.windows.compile").compile(
      reopened, { paths = paths })
    assert.is_true(vim.tbl_contains(
      compiled.write_roots, "C:\\Repo\\.git\\worktree"))

    local denied_read = vim.deepcopy(active)
    denied_read.filesystem.entries[#denied_read.filesystem.entries + 1] = {
      path = "C:\\Secret\\public",
      access = "read",
    }
    existing["c:\\secret\\public"] = true
    local denied_ok, denied_err = pcall(function()
      require("neoagent.sandbox.windows.compile").compile(
        denied_read, { paths = paths })
    end)
    assert.is_false(denied_ok)
    assert.matches("cannot reopen read access", structured_error(denied_err).message)

    local missing_parent = vim.deepcopy(active)
    missing_parent.filesystem.entries[#missing_parent.filesystem.entries + 1] = {
      path = "C:\\Repo\\missing\\protected",
      access = "read",
    }
    local missing_ok, missing_err = pcall(function()
      require("neoagent.sandbox.windows.compile").compile(
        missing_parent, { paths = paths })
    end)
    assert.is_false(missing_ok)
    assert.matches("existing parent", structured_error(missing_err).message)

    local missing_deny = vim.deepcopy(active)
    missing_deny.filesystem.entries[#missing_deny.filesystem.entries + 1] = {
      path = "C:\\Absent",
      access = "deny",
    }
    missing_ok, missing_err = pcall(function()
      require("neoagent.sandbox.windows.compile").compile(
        missing_deny, { paths = paths })
    end)
    assert.is_false(missing_ok)
    assert.matches("missing deny path", structured_error(missing_err).message)
  end)

  local function windows_test_host()
    local original_arch = jit.arch
    local original_version = vim.version
    -- Windows production support is x64-only. Adapter tests simulate that
    -- host and its minimum Neovim because CI also exercises other hosts and
    -- supported versions in the same platform-neutral suite.
    jit.arch = "x64"
    local test_version = function()
      return setmetatable({ major = 0, minor = 12, patch = 0 }, {
        __index = (original_version --[[@as fun(): vim.Version]])(),
      })
    end
    rawset(vim, "version", test_version)
    cleanup(function() jit.arch = original_arch end)
    cleanup(function() vim.version = original_version end)
    local previous_state = vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE
    vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE = "C:\\state"
    cleanup(function()
      vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE = previous_state
    end)
    local original_realpath = vim.uv.fs_realpath
    local original_stat = vim.uv.fs_stat
    local original_runtime = vim.api.nvim_get_runtime_file
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "scripts/sandbox_windows_runtime.lua" then
        return { "C:/Neoagent/scripts/sandbox_windows_runtime.lua" }
      end
      return original_runtime(path, all)
    end
    vim.uv.fs_realpath = function(path)
      if type(path) == "string" and path:match("^[A-Za-z]:[/\\]") then
        if path:gsub("/", "\\"):lower() == "c:\\repo\\cmd.exe" then
          return nil
        end
        return path:gsub("/", "\\")
      end
      return original_realpath(path)
    end
    vim.uv.fs_stat = function(path)
      if type(path) == "string" and path:match("^[A-Za-z]:[/\\]") then
        return {
          type = (path:lower():match("%.exe$") or path:lower():match("%.lua$")) and "file" or "directory",
        }
      end
      return original_stat(path)
    end
    cleanup(function()
      vim.uv.fs_realpath = original_realpath
      vim.uv.fs_stat = original_stat
      vim.api.nvim_get_runtime_file = original_runtime
    end)
  end

  local function windows_profile()
    return {
      id = "windows-adapter",
      network = "restricted",
      filesystem = {
        default = "read",
        entries = {
          { path = "C:\\Repo", access = "write" },
        },
      },
      environment = { clear = true, inherit = {}, set = {} },
      windows = {
        version = 1,
        write_roots = { "C:\\Repo" },
        deny_read = {},
        deny_write = {},
      },
    }
  end

  local function windows_events(values, stderr, result)
    local framed = require("neoagent.sandbox.protocol")
    return function(_, opts)
      if stderr then emit_output(opts, stderr, true) end
      for _, value in ipairs(values or {}) do
        emit_output(opts, framed.encode(value), false)
      end
      return result or {
        code = 0,
        signal = 0,
        stdout = "",
        stderr = "",
        output = "",
        timed_out = false,
      }
    end
  end

  it("starts Windows streaming workers through the native protocol relay", function()
    windows_test_host()
    local windows = require("neoagent.sandbox.windows")
    local supported_version = vim.version
    rawset(vim, "version", function()
      return { major = 0, minor = 11, patch = 0 }
    end)
    local unsupported, unsupported_err = pcall(windows.start_worker, {
      argv = { "C:\\Repo\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = windows_profile(),
    }, {
      fs = fs,
      nvim = "C:\\Neovim\\bin\\nvim.exe",
    })
    vim.version = supported_version
    assert.is_false(unsupported)
    assert.matches("0.12 or newer", structured_error(unsupported_err).message)

    local original_runtime = vim.api.nvim_get_runtime_file
    cleanup(function() vim.api.nvim_get_runtime_file = original_runtime end)
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "scripts/sandbox_windows_runtime.lua" then
        return {}
      end
      return original_runtime(path, all)
    end
    local found, missing = pcall(windows.start_worker, {
      argv = { "C:\\Repo\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = windows_profile(),
    }, {
      fs = fs,
      nvim = "C:\\Neovim\\bin\\nvim.exe",
    })
    vim.api.nvim_get_runtime_file = original_runtime
    assert.is_false(found)
    assert.matches("runtime was not found", structured_error(missing).message)

    local resolved, resolve_err = pcall(windows.start_worker, {
      argv = { "C:\\Repo\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = windows_profile(),
    }, {
      fs = fs,
      nvim = "missing-nvim",
    })
    assert.is_false(resolved)
    assert.matches("cannot be resolved", structured_error(resolve_err).message)

    ---@type Neoagent.WorkerRequest?
    local captured
    local base = {
      write = function() return true end,
      close_stdin = function() return true end,
      terminate = function() end,
      wait = function() return { code = 0, signal = 0, stderr = "" } end,
      dispose = function() end,
    }
    local relay = windows.start_worker({
      argv = { "C:\\Repo\\tool.exe" },
      cwd = "C:\\Repo",
      env = { PATH = "C:\\Windows\\System32" },
      profile = windows_profile(),
      bootstrap_paths = { "C:\\Repo", "C:\\Repo" },
    }, {
      fs = fs,
      nvim = "C:\\Neovim\\bin\\nvim.exe",
      start_worker = function(value)
        captured = value
        assert(value.on_stdout)(protocol.encode({ v = 1, type = "ready" })
          .. protocol.encode({ v = 1, type = "exit", code = 0, signal = 0 }))
        assert(value.on_exit)({ code = 0, signal = 0, stderr = "" })
        return base
      end,
    })
    assert.are.equal(0, relay:wait().code)
    local spec = vim.json.decode(assert(captured).env.NEOAGENT_SANDBOX_SPEC)
    assert.are.equal(60000, spec.admission_timeout_ms)
    assert.is_true(vim.list_contains(spec.runner.read_roots, "C:\\Repo"))

    local denied_profile = windows_profile()
    denied_profile.filesystem.entries[#denied_profile.filesystem.entries + 1] = {
      path = "C:\\Repo\\bootstrap",
      access = "deny",
    }
    local denied_started = false
    local denied, denied_err = pcall(windows.start_worker, {
      argv = { "C:\\Repo\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = denied_profile,
      bootstrap_paths = { "C:\\Repo\\bootstrap" },
    }, {
      fs = fs,
      nvim = "C:\\Neovim\\bin\\nvim.exe",
      start_worker = function()
        denied_started = true
        error("must not start")
      end,
    })
    assert.is_false(denied)
    assert.is_false(denied_started)
    assert.matches(
      "denies required bootstrap path",
      structured_error(denied_err).message
    )

    local started, start_err = pcall(windows.start_worker, {
      argv = { "C:\\Repo\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = windows_profile(),
    }, {
      fs = fs,
      nvim = "C:\\Neovim\\bin\\nvim.exe",
      start_worker = function() error("Windows spawn failed") end,
    })
    assert.is_false(started)
    assert.matches("Could not start Windows", structured_error(start_err).message)
  end)

  it("resolves Windows worker launchers and preserves binary relay output", function()
    windows_test_host()
    local windows = require("neoagent.sandbox.windows")
    assert.are.equal("windows", windows.paths.name)
    local framed = require("neoagent.sandbox.protocol")
    local seen = {}
    local services = {
      fs = fs,
      nvim = "C:\\Neovim\\bin\\nvim.exe",
      start_worker = function(opts)
        local argv = opts.argv
        local encoded = encoded_spec(opts.env)
        seen[#seen + 1] = {
          argv = argv,
          opts = opts,
          spec = vim.json.decode(encoded),
        }
        emit_output(opts, framed.encode({
          v = 1, type = "ready",
        }), false)
        emit_output(opts, framed.encode({
          v = 1, type = "output", stream = "stdout",
          seq = 1, data = "out\0",
        }), false)
        emit_output(opts, framed.encode({
          v = 1, type = "output", stream = "stderr",
          seq = 2, data = "err",
        }) .. framed.encode({
          v = 1, type = "exit", code = 0, signal = 0,
        }), false)
        return completed_worker(opts)
      end,
    }
    local chunks = {}
    local value = windows.start_worker({
      argv = { "cmd.exe", "/d", "/c", "echo ok" },
      cwd = "C:\\Repo",
      env = {
        Path = "C:\\Windows\\System32",
        PATHEXT = ".EXE;.CMD",
      },
      profile = windows_profile(),
      on_stdout = function(data)
        chunks[#chunks + 1] = { data, false }
      end,
      on_stderr = function(data)
        chunks[#chunks + 1] = { data, true }
      end,
    }, services)
    assert.are.equal(0, value:wait().code)
    assert.are.same({
      { "out\0", false },
      { "err", true },
    }, chunks)
    assert.are.same({
      "C:\\Windows\\System32\\cmd.exe",
      "/d", "/c", "echo ok",
    }, seen[1].spec.argv)
    assert.are.equal("exec", seen[1].spec.mode)
    assert.are.equal(60000, seen[1].spec.admission_timeout_ms)
    assert.are.equal("C:\\state",
      seen[1].opts.env.NEOAGENT_WINDOWS_SANDBOX_STATE)
    assert.is_true(vim.list_contains(seen[1].argv, "-l"))
    assert.are.same({
      "C:\\Neovim\\bin",
      "C:\\Neoagent\\lua\\neoagent\\process\\windows_command.lua",
      "C:\\Neovim\\share\\nvim\\runtime",
    }, seen[1].spec.runner.read_roots)
    assert.are.equal("C:\\state\\shared-tmp", windows.temporary_root())

    local previous_runtime = vim.env.VIMRUNTIME
    vim.env.VIMRUNTIME = "C:\\Portable\\runtime"
    cleanup(function() vim.env.VIMRUNTIME = previous_runtime end)
    local simulated_stat = vim.uv.fs_stat
    vim.uv.fs_stat = function(path)
      if path:gsub("/", "\\"):lower()
          == "c:\\portable\\share\\nvim\\runtime" then
        return nil
      end
      return simulated_stat(path)
    end
    value = windows.start_worker({
      argv = { "C:\\bin\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = windows_profile(),
    }, {
      nvim = "C:\\Portable\\bin\\nvim.exe",
      fs = fs,
      start_worker = services.start_worker,
    })
    assert.are.equal(0, value:wait().code)
    assert.are.same({
      "C:\\Portable\\bin",
      "C:\\Neoagent\\lua\\neoagent\\process\\windows_command.lua",
      "C:\\Portable\\runtime",
    }, seen[#seen].spec.runner.read_roots)
    vim.uv.fs_stat = simulated_stat
    vim.env.VIMRUNTIME = previous_runtime

    value = windows.start_worker({
      argv = { "tool", "argument" },
      cwd = "C:\\Repo",
      env = { PATH = "", PATHEXT = "EXE;.CMD" },
      profile = windows_profile(),
    }, services)
    assert.are.equal(0, value:wait().code)
    assert.are.equal("C:\\Repo\\tool.EXE",
      seen[#seen].spec.argv[1])

    value = windows.start_worker({
      argv = { "bin\\tool", "argument" },
      cwd = "C:\\Repo",
      env = { PATH = "" },
      profile = windows_profile(),
    }, services)
    assert.are.equal(0, value:wait().code)
    assert.are.equal("C:\\Repo\\bin\\tool.EXE",
      seen[#seen].spec.argv[1])

    local launched_ok, launch_err = pcall(windows.start_worker, {
      argv = { "C:\\bin\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = windows_profile(),
    }, {
      nvim = { vim.env.NEOAGENT_NVIM, "--clean" },
      fs = fs,
      start_worker = services.start_worker,
    })
    assert.is_true(launched_ok, tostring(launch_err))
    assert.is_true(vim.list_contains(seen[#seen].argv, "-l"))
    assert.is_true(vim.list_contains(seen[#seen].argv, "--clean"))

    local previous_state = vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE
    local original_stdpath = vim.fn.stdpath
    cleanup(function()
      vim.fn.stdpath = original_stdpath
      vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE = previous_state
    end)
    vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE = nil
    vim.fn.stdpath = function() return "C:\\owner-state" end
    assert.are.equal("C:\\owner-state\\neoagent\\windows-sandbox\\shared-tmp",
      windows.temporary_root())
    vim.fn.stdpath = original_stdpath
    vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE = previous_state
  end)

  it("probes the live Windows runtime and fails closed", function()
    windows_test_host()
    local windows = require("neoagent.sandbox.windows")
    assert.are.equal("windows", windows.paths.name)
    local framed = require("neoagent.sandbox.protocol")
    local fake_fs = filesystem({
      create_temp_directory = function()
        return "C:\\probe"
      end,
      write_all = function() return true end,
      mkdirp = function() return true end,
    })
    ---@type {argv: string[], timeout: integer, spec: {mode: string, admission_timeout_ms: integer, probe: {deny_write: string}}}?
    local captured
    local status = windows.check({
      fs = fake_fs,
      nvim = vim.env.NEOAGENT_NVIM,
      probe_timeout_ms = 321,
      system = function(argv, opts, timeout)
        local encoded = encoded_spec(opts.env)
        captured = {
          argv = argv,
          spec = vim.json.decode(encoded),
          timeout = timeout,
        }
        return {
          code = 0,
          signal = 0,
          stdout = framed.encode({ v = 1, type = "ready" })
            .. framed.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }),
          stderr = "",
        }
      end,
    })
    assert.is_true(status.ok, vim.inspect(status))
    assert.is_true(assert(status.capabilities).restricted_token)
    assert.is_true(assert(status.capabilities).windows_filtering_platform)
    assert.is_true(assert(status.capabilities).private_desktop)
    assert.are.equal("probe", assert(assert(captured).spec).mode)
    assert.are.equal(60000, assert(assert(captured).spec).admission_timeout_ms)
    assert.are.equal("C:\\probe\\read-only.txt",
      assert(assert(captured).spec).probe.deny_write)
    assert.are.equal(321, assert(captured).timeout)

    local original_system = vim.system
    local original_getenv = vim.uv.os_getenv
    local inherited_root
    cleanup(function()
      vim.system = original_system
      vim.uv.os_getenv = original_getenv
    end)
    vim.uv.os_getenv = function(name)
      if name == "SystemRoot" then return "C:\\Windows" end
      return original_getenv(name)
    end
    vim.system = function(_, opts)
      if not opts or type(opts.env) ~= "table" then
        error("Windows probe environment was not provided")
      end
      ---@cast opts.env table<string, string>
      inherited_root = opts.env.SystemRoot
      return {
        wait = function()
          return {
            code = 0,
            signal = 0,
            stdout = framed.encode({ v = 1, type = "ready" })
              .. framed.encode({
                v = 1, type = "exit", code = 0, signal = 0,
              }),
            stderr = "",
          }
        end,
      } --[[@as vim.SystemObj]]
    end
    assert.is_true(windows.check({ fs = fake_fs }).ok)
    assert.are.equal("C:\\Windows", inherited_root)
    vim.system = original_system
    vim.uv.os_getenv = original_getenv

    local function checked(result)
      return windows.check({
        fs = fake_fs,
        nvim = vim.env.NEOAGENT_NVIM,
        system = function() return result end,
      })
    end
    assert.are.equal("probe", checked(nil).stage)
    local verbose = checked({ code = 1, signal = 0, stdout = "", stderr = string.rep("x", 2000) })
    assert.are.equal("protocol", verbose.stage)
    assert.are.equal(1000, #assert(verbose.message))
    assert.are.equal("...", assert(verbose.message):sub(-3))
    assert.are.equal(
      "protocol", checked({
      code = 1, signal = 0, stdout = "", stderr = "stopped",
    }).stage)
    assert.are.equal("protocol", checked({
      code = 0, signal = 0,
      stdout = string.char(0, 0, 0, 1) .. "{", stderr = "",
    }).stage)
    local missing = checked({
      code = 125,
      signal = 0,
      stdout = framed.encode({
        v = 1, type = "error", stage = "state-missing", errno = 2,
      }),
      stderr = "",
    })
    assert.are.equal("state-missing", missing.stage)
    assert.matches("setup command", (assert(missing.message)))

    local nonzero = checked({
      code = 1,
      signal = 0,
      stdout = framed.encode({ v = 1, type = "ready" })
        .. framed.encode({
          v = 1, type = "exit", code = 0, signal = 0,
        }),
      stderr = "",
    })
    assert.are.equal("probe", nonzero.stage)
  end)

  it("reports Windows preparation and executable failures", function()
    windows_test_host()
    local windows = require("neoagent.sandbox.windows")
    local supported_version = vim.version
    local test_version = function()
      return setmetatable({ major = 0, minor = 11, patch = 9 }, {
        __index = (supported_version --[[@as fun(): vim.Version]])(),
      })
    end
    rawset(vim, "version", test_version)
    assert.are.equal("version", windows.check({}).stage)
    local version_err = caught(function()
      windows.start_worker({
        argv = { "C:\\bin\\tool.exe" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, {
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        start_worker = function() error("must not run") end,
      })
    end)
    assert.matches("Neovim 0.12", version_err.message)
    rawset(vim, "version", function()
      return { major = "invalid", minor = 12, patch = 0 }
    end)
    assert.are.equal("version", windows.check({}).stage)
    vim.version = supported_version

    local original_arch = jit.arch
    cleanup(function() jit.arch = original_arch end)
    jit.arch = "arm64"
    assert.are.equal("architecture", windows.check({}).stage)
    jit.arch = original_arch

    local get_runtime_file = vim.api.nvim_get_runtime_file
    cleanup(function()
      vim.api.nvim_get_runtime_file = get_runtime_file
    end)
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "scripts/sandbox_windows_runtime.lua" then return {} end
      return get_runtime_file(path, all)
    end
    assert.are.equal("runtime", windows.check({}).stage)
    local missing_runtime = caught(function()
      windows.start_worker({
        argv = { "C:\\bin\\tool.exe" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, {
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        start_worker = function() error("must not run") end,
      })
    end)
    vim.api.nvim_get_runtime_file = get_runtime_file
    assert.matches("runtime was not found", missing_runtime.message)

    assert.are.equal("nvim", windows.check({
      nvim = "/definitely/missing/nvim",
    }).stage)
    assert.are.equal("nvim", windows.check({
      nvim = { "", "--clean" },
    }).stage)
    local missing_nvim = caught(function()
      windows.start_worker({
        argv = { "C:\\bin\\tool.exe" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, {
        fs = fs,
        nvim = "/definitely/missing/nvim",
        start_worker = function() error("must not run") end,
      })
    end)
    assert.matches("cannot be resolved", missing_nvim.message)

    local missing_executable = caught(function()
      windows.start_worker({
        argv = { "C:\\Repo\\missing.cmd" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, {
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        start_worker = function() error("must not run") end,
      })
    end)
    assert.matches("executable was not found", missing_executable.message)

    local function prepared(fs_override)
      return windows.check({
        fs = fs_override,
        nvim = vim.env.NEOAGENT_NVIM,
        system = function() error("must not run") end,
      })
    end
    assert.are.equal("probe-directory", prepared({
      create_temp_directory = function() return nil, "no root" end,
    }).stage)
    assert.are.equal("probe-file", prepared({
      create_temp_directory = function() return "C:\\probe" end,
      write_all = function() return nil, "no file" end,
    }).stage)
    assert.are.equal("probe-directory", prepared({
      create_temp_directory = function() return "C:\\probe" end,
      write_all = function() return true end,
      mkdirp = function() return nil, "no directory" end,
    }).stage)

    local compile = windows.compile
    cleanup(function() windows.compile = compile end)
    windows.compile = function() error("cannot compile") end
    local compile_status = prepared({
      create_temp_directory = function() return "C:\\probe" end,
      write_all = function() return true end,
      mkdirp = function() return true end,
    })
    windows.compile = compile
    assert.are.equal("profile", compile_status.stage)

  end)

  it("rejects malformed Windows runtime event streams", function()
    local framed = require("neoagent.sandbox.protocol")
    local function rejected(events, opts)
      local decoder = framed.new(opts)
      local ok, err = pcall(function()
        for _, event in ipairs(events) do
          decoder:feed(type(event) == "string" and event
            or framed.encode(event))
        end
      end)
      assert.is_false(ok)
      return tostring(err)
    end

    assert.matches("protocol event", rejected({
      { v = 2, type = "ready" },
    }))
    assert.matches("duplicate", rejected({
      { v = 1, type = "ready" },
      { v = 1, type = "ready" },
    }))
    assert.matches("precedes ready", rejected({
      {
        v = 1, type = "output", stream = "stdout",
        seq = 1, data = "",
      },
    }))
    assert.matches("output stream", rejected({
      { v = 1, type = "ready" },
      {
        v = 1, type = "output", stream = "other",
        seq = 1, data = "",
      },
    }))
    assert.matches("output event", rejected({
      { v = 1, type = "ready" },
      {
        v = 1, type = "output", stream = "stdout",
        seq = 2, data = "",
      },
    }))
    assert.matches("exit event", rejected({
      { v = 1, type = "exit", code = 0, signal = 0 },
    }))
    assert.matches("exit event", rejected({
      { v = 1, type = "ready" },
      {
        v = 1, type = "exit", code = 0, signal = 0,
        timed_out = "yes",
      },
    }))
    assert.matches("error event", rejected({
      { v = 1, type = "error", stage = "", errno = 0 },
    }))
    assert.matches("error event", rejected({
      { v = 1, type = "error", stage = "acl", errno = -1 },
    }))
    assert.matches("unknown", rejected({
      { v = 1, type = "mystery" },
    }))
    assert.matches("frame length", rejected({
      string.char(0, 0, 0, 0),
    }))
    assert.matches("MessagePack", rejected({
      string.char(0, 0, 0, 1, 0xc1),
    }))

    local decoder = framed.new()
    decoder:feed(framed.encode({ v = 1, type = "ready" }):sub(1, 5))
    local terminal, reason = decoder:finish()
    assert.is_nil(terminal)
    assert.matches("truncated", (assert(reason)))
    decoder = framed.new()
    terminal, reason = decoder:finish()
    assert.is_nil(terminal)
    assert.matches("no terminal", (assert(reason)))
    decoder = framed.new()
    decoder:feed(framed.encode({
      v = 1, type = "error", stage = "acl", errno = 5,
    }))
    terminal = assert(decoder:finish())
    assert.are.equal("error", terminal.type)

    local encoded = framed.encode({ v = 1, type = "ready" })
      .. framed.encode({
        v = 1, type = "exit", code = 0, signal = 0,
      })
    local decoded
    local decoded, decoded_terminal = framed.decode_all(encoded)
    assert(type(decoded_terminal) == "table")
    terminal = decoded_terminal
    assert.are.equal(2, #decoded)
    assert.are.equal("exit", terminal.type)
    local decoded_failure, decode_error = framed.decode_all(
      string.char(0, 0, 0, 1, 0xc1))
    assert.is_nil(decoded_failure)
    assert(type(decode_error) == "string")
    assert.matches("MessagePack", decode_error)
    local no_terminal, terminal_error = framed.decode_all(
      framed.encode({ v = 1, type = "ready" }))
    assert.is_nil(no_terminal)
    assert(type(terminal_error) == "string")
    assert.matches("no terminal", terminal_error)
  end)
end)
