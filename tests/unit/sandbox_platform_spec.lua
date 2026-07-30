local fs = require("neoagent.fs")
local protocol = require("neoagent.sandbox.linux.protocol")

local function temporary_directory()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return path
end

local function profile(root, extra)
  local entries = { { path = root, access = "write" } }
  vim.list_extend(entries, extra or {})
  return assert(require("neoagent.sandbox.profile").validate({
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
  }))
end

local function caught(fn)
  local ok, value = pcall(fn)
  assert.is_false(ok)
  return value
end

local function request(root, active_profile)
  return {
    argv = { "/bin/sh", "-c", "true" },
    cwd = root,
    env = { PATH = "/bin:/usr/bin" },
    profile = active_profile or profile(root),
    capture = true,
  }
end

local function framed_process(events, host)
  return function(_, opts)
    for _, event in ipairs(events) do
      opts.on_output(protocol.encode(event), false)
    end
    return host or {
      code = 0,
      signal = 0,
      stdout = "",
      stderr = "",
      output = "",
      timed_out = false,
    }
  end
end

describe("neoagent sandbox platform adapters", function()
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

  it("probes Linux through the standalone framed runtime", function()
    local seen = {}
    local status = require("neoagent.sandbox.linux").check({
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function(argv, opts, timeout)
        local encoded
        for _, value in ipairs(opts.env) do
          encoded = encoded
            or value:match("^NEOAGENT_SANDBOX_SPEC=(.*)$")
        end
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
    assert.is_true(status.capabilities.process_supervision)
    assert.is_true(status.capabilities.protected_create)
    assert.is_true(status.degraded)
    assert.are.equal("host", status.capabilities.procfs)
    assert.matches("mount%-proc", status.degraded_reason)
    assert.are.equal(2, #seen)
    assert.are.equal("fresh", seen[1].spec.procfs)
    assert.are.equal("host", seen[2].spec.procfs)
    assert.are.equal("deny", seen[2].spec.protected_create[1].access)
    assert.matches("protected%-create%-probe$",
      seen[2].spec.protected_create[1].path)
    assert.are.equal(321, seen[2].timeout)
    assert.are.equal(vim.env.NEOAGENT_NVIM, seen[2].argv[1])
    assert.are.equal("-l", seen[2].argv[#seen[2].argv - 1])
    assert.are.equal("string", type(seen[2].opts.env[1]))
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
    assert.matches("mount%-root failed", failed.message)
  end)

  it("decodes Linux process output without host capture duplication", function()
    local root = temp()
    local reserved = vim.fs.joinpath(root, "reserved")
    local requests = {}
    local services = {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      capabilities = { procfs = "host" },
      process = function(argv, opts)
        local encoded = opts.env.NEOAGENT_SANDBOX_SPEC
        assert.is_string(encoded)
        local spec = vim.json.decode(encoded)
        requests[#requests + 1] = {
          argv = argv,
          opts = opts,
          spec = spec,
        }
        local protects_reserved = false
        for _, entry in ipairs(spec.profile.filesystem.entries) do
          if entry.path == reserved then protects_reserved = true end
        end
        if protects_reserved then
          assert.is_nil(vim.uv.fs_lstat(reserved))
          assert.are.same({
            { path = reserved, access = "deny" },
          }, spec.protected_create)
        end
        opts.on_output(protocol.encode({
          v = 1, type = "ready",
        }), false)
        opts.on_output(protocol.encode({
          v = 1,
          type = "output",
          stream = "stdout",
          seq = 1,
          data = spec.mode == "fs" and "file\0data" or "out\0",
        }), false)
        opts.on_output(protocol.encode({
          v = 1,
          type = "output",
          stream = "stderr",
          seq = 2,
          data = "err",
        }) .. protocol.encode({
          v = 1, type = "exit", code = 0, signal = 0,
        }), false)
        return {
          code = 0,
          signal = 0,
          stdout = "",
          stderr = "",
          output = "",
          timed_out = false,
        }
      end,
    }
    local platform = require("neoagent.sandbox.linux")
    local chunks = {}
    local value = platform.exec({
      argv = { "/bin/sh", "-c", "printf output" },
      cwd = root,
      env = { PATH = "/bin:/usr/bin" },
      profile = profile(root, {
        { path = reserved, access = "deny" },
      }),
      stdin = "input\0",
      capture = true,
      on_output = function(data, is_stderr)
        chunks[#chunks + 1] = { data, is_stderr }
      end,
    }, services)
    assert.are.equal("out\0", value.stdout)
    assert.are.equal("err", value.stderr)
    assert.are.equal("out\0err", value.output)
    assert.are.same({
      { "out\0", false },
      { "err", true },
    }, chunks)
    assert.is_false(requests[1].opts.capture)
    local separator
    for index, value in ipairs(requests[1].argv) do
      if value == "--" then separator = index break end
    end
    assert.is_number(separator)
    assert.are.equal(vim.uv.fs_realpath("/bin/sh"),
      requests[1].argv[separator + 1])
    assert.are.same({ "-c", "printf output" }, {
      requests[1].argv[separator + 2],
      requests[1].argv[separator + 3],
    })
    assert.is_nil(requests[1].spec.argv)
    assert.are.equal("exec", requests[1].spec.mode)
    assert.are.equal("host", requests[1].spec.procfs)
    assert.are.equal("input\0", requests[1].opts.stdin)
    assert.is_nil(requests[1].spec.env.GIT_DISCOVERY_ACROSS_FILESYSTEM)
    assert.is_nil(vim.uv.fs_stat(reserved))

    local data = assert(platform.fs({
      operation = "read",
      path = vim.fs.joinpath(root, "file"),
      profile = profile(root),
    }, services))
    assert.are.equal("file\0data", data)
    assert.are.equal("fs", requests[2].spec.mode)
    assert.are.equal(30000, requests[2].opts.timeout_ms)

    assert.is_true(platform.fs({
      operation = "write_all",
      path = vim.fs.joinpath(root, "file"),
      data = "new contents",
      profile = profile(root),
    }, services))

    local failed, reason = platform.fs({
      operation = "write_all",
      path = vim.fs.joinpath(root, "file"),
      data = "new contents",
      profile = profile(root),
    }, {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      process = framed_process({
        { v = 1, type = "ready" },
        { v = 1, type = "exit", code = 73, signal = 0 },
      }),
    })
    assert.is_nil(failed)
    assert.are.equal("sandbox filesystem operation failed", reason)
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
      linux.exec(request(root, active_profile), {
        fs = {
          create_temp_directory = function()
            created = true
            error("must not create")
          end,
        },
        nvim = vim.env.NEOAGENT_NVIM,
        process = function() error("must not run") end,
      })
    end)
    assert.is_false(created)
    assert.matches("filesystem profile exposes", err.detail)
  end)

  it("fails Linux launches closed across setup, process, and protocol errors",
    function()
      local root = temp()
      local linux = require("neoagent.sandbox.linux")
      local active_profile = profile(root)
      local function services(process, filesystem)
        return {
          fs = filesystem or fs,
          nvim = { vim.env.NEOAGENT_NVIM },
          process = process,
        }
      end

      local timed_out = linux.exec(request(root, active_profile),
        services(framed_process({
          { v = 1, type = "ready" },
          { v = 1, type = "output", stream = "stdout", seq = 1,
            data = "partial" },
        }, {
          code = 124,
          signal = 15,
          stdout = "",
          stderr = "",
          output = "",
          timed_out = true,
        })))
      assert.is_true(timed_out.timed_out)
      assert.are.equal("partial", timed_out.stdout)

      local failures = {
        {
          process = function(_, opts)
            opts.on_output("\255\255\255\255", false)
            return { code = 0, signal = 0 }
          end,
          message = "Invalid Linux sandbox protocol",
        },
        {
          process = function(_, opts)
            opts.on_output(protocol.encode({ v = 1, type = "ready" }),
              false)
            opts.on_output("runtime diagnostic", true)
            return { code = 125, signal = 0 }
          end,
          message = "sandbox protocol has no terminal event",
        },
        {
          process = framed_process({
            { v = 1, type = "error", stage = "seccomp", errno = 1 },
          }, { code = 125, signal = 0 }),
          message = "Linux sandbox setup failed at seccomp",
        },
        {
          process = function() return {} end,
          message = "invalid process result",
        },
        {
          process = function() error("spawn exploded") end,
          message = "Linux sandbox runtime failed",
        },
      }
      for _, case in ipairs(failures) do
        local err = caught(function()
          linux.exec(request(root, active_profile),
            services(case.process))
        end)
        assert.are.equal("sandbox_unavailable", err.kind)
        assert.matches(case.message, err.message)
      end

      local cancellation = {
        kind = "cancelled",
        message = "cancelled by caller",
      }
      local err = caught(function()
        linux.exec(request(root, active_profile), services(function()
          error(cancellation, 0)
        end))
      end)
      assert.are.equal(cancellation, err)

      local missing = request(root, active_profile)
      missing.argv = { "not-a-real-sandbox-program" }
      err = caught(function()
        linux.exec(missing, services(function() error("must not run") end))
      end)
      assert.matches("executable was not found", err.message)

      local relative = request(root, active_profile)
      relative.argv = { "sh", "-c", "true" }
      local launched
      linux.exec(relative, services(function(argv, opts)
        launched = argv
        opts.on_output(protocol.encode({ v = 1, type = "ready" })
          .. protocol.encode({
            v = 1, type = "exit", code = 0, signal = 0,
          }), false)
        return { code = 0, signal = 0 }
      end))
      assert.is_true(vim.tbl_contains(
        launched, assert(vim.uv.fs_realpath("/bin/sh"))))

      err = caught(function()
        linux.exec(request(root, active_profile), services(function()
          error("must not run")
        end, {
          create_temp_directory = function()
            return nil, "temporary storage unavailable"
          end,
        }))
      end)
      assert.matches("Could not create Linux sandbox root", err.message)

      err = caught(function()
        linux.exec(request(root, active_profile), services(function()
          error("must not run")
        end, {
          create_temp_directory = function()
            return vim.fs.joinpath(root, "missing-temporary-root")
          end,
        }))
      end)
      assert.matches("Could not create Linux sandbox root", err.message)

      local original_rmdir = vim.uv.fs_rmdir
      local cleanup_root
      vim.uv.fs_rmdir = function(path)
        cleanup_root = path
        return nil, "cleanup denied"
      end
      local cleanup_ok, cleanup_err = pcall(function()
        linux.exec(request(root, active_profile),
          services(framed_process({
            { v = 1, type = "ready" },
            { v = 1, type = "exit", code = 0, signal = 0 },
          })))
      end)
      vim.uv.fs_rmdir = original_rmdir
      if cleanup_root then vim.fn.delete(cleanup_root, "rf") end
      assert.is_false(cleanup_ok)
      assert.matches("Could not remove Linux sandbox root",
        cleanup_err.message)
    end)

  it("keeps missing Linux restricted paths out of the host namespace", function()
    local root = temp()
    local nested = vim.fs.joinpath(root, "missing", "parent", "blocked")
    local linux = require("neoagent.sandbox.linux")
    local active_profile = profile(root, {
      { path = nested, access = "deny" },
    })
    local observed
    linux.exec(request(root, active_profile), {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      process = function(_, opts)
        observed = vim.uv.fs_lstat(nested)
        local spec = vim.json.decode(opts.env.NEOAGENT_SANDBOX_SPEC)
        assert.are.same({
          { path = nested, access = "deny" },
        }, spec.protected_create)
        opts.on_output(protocol.encode({ v = 1, type = "ready" })
          .. protocol.encode({
            v = 1, type = "exit", code = 0, signal = 0,
          }), false)
        return { code = 0, signal = 0 }
      end,
    })
    assert.is_nil(observed)
    assert.is_nil(vim.uv.fs_stat(vim.fs.dirname(nested)))
  end)

  it("leaves substituted Linux sandbox roots untouched", function()
    local root = temp()
    local linux = require("neoagent.sandbox.linux")
    for _, replacement in ipairs({ "directory", "symlink", "missing" }) do
      local sandbox_path
      local owned_path
      local replacement_target
      local err = caught(function()
        linux.exec(request(root), {
          fs = fs,
          nvim = vim.env.NEOAGENT_NVIM,
          process = function(_, opts)
            local spec = vim.json.decode(
              opts.env.NEOAGENT_SANDBOX_SPEC)
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
            opts.on_output(protocol.encode({ v = 1, type = "ready" })
              .. protocol.encode({
                v = 1, type = "exit", code = 0, signal = 0,
              }), false)
            return { code = 0, signal = 0 }
          end,
        })
      end)
      assert.matches("Could not remove Linux sandbox root", err.message)
      if replacement == "directory" then
        assert.are.equal("directory",
          assert(vim.uv.fs_lstat(sandbox_path)).type)
      elseif replacement == "symlink" then
        assert.are.equal("link",
          assert(vim.uv.fs_lstat(sandbox_path)).type)
        assert.are.equal("data", assert(fs.read(
          vim.fs.joinpath(replacement_target, "preserve"))))
        vim.fn.delete(sandbox_path)
      else
        assert.is_nil(vim.uv.fs_lstat(sandbox_path))
      end
      vim.fn.delete(owned_path, "rf")
      if replacement == "directory" then
        vim.fn.delete(sandbox_path, "rf")
      end
      if replacement_target then vim.fn.delete(replacement_target, "rf") end
    end
  end)

  it("refuses a Linux sandbox root substituted before use", function()
    local root = temp()
    local linux = require("neoagent.sandbox.linux")
    local sandbox_path
    local owned_path
    local replacement_path
    local root_checks = 0
    local original_lstat = vim.uv.fs_lstat
    local filesystem = setmetatable({
      create_temp_directory = function(prefix)
        sandbox_path = assert(fs.create_temp_directory(prefix))
        owned_path = sandbox_path .. ".owned"
        replacement_path = vim.fs.joinpath(sandbox_path, "preserve")
        return sandbox_path
      end,
    }, { __index = fs })
    vim.uv.fs_lstat = function(path)
      if path == sandbox_path then
        root_checks = root_checks + 1
        if root_checks == 2 then
          assert(vim.uv.fs_rename(sandbox_path, owned_path))
          assert(vim.uv.fs_mkdir(sandbox_path, 448))
          assert(fs.write_all(replacement_path, "replacement"))
        end
      end
      return original_lstat(path)
    end
    local launched = false
    local ok, err = pcall(function()
      linux.exec(request(root), {
        fs = filesystem,
        nvim = vim.env.NEOAGENT_NVIM,
        process = function()
          launched = true
          error("must not run")
        end,
      })
    end)
    vim.uv.fs_lstat = original_lstat
    assert.is_false(ok)
    assert.is_false(launched)
    assert.matches("root identity changed before use", err.message)
    assert.are.equal("replacement", assert(fs.read(replacement_path)))
    vim.fn.delete(owned_path, "rf")
    vim.fn.delete(sandbox_path, "rf")
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
      linux.exec(request(root), {
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        process = function() error("must not run") end,
      })
    end)
    vim.api.nvim_get_runtime_file = get_runtime_file
    assert.is_true(checked)
    assert.are.equal("runtime", missing_runtime.stage)
    assert.is_false(launched)
    assert.matches("Linux sandbox runtime was not found",
      launch_err.message)

    local original_fs_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, flags, mode)
      if path == "/proc/self/cmdline" then return nil end
      return original_fs_open(path, flags, mode)
    end
    local fallback_argv
    local fallback_ok, fallback_err = pcall(function()
      linux.exec(request(root), {
        fs = fs,
        process = function(argv, opts)
          fallback_argv = argv
          opts.on_output(protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }), false)
          return { code = 0, signal = 0 }
        end,
      })
    end)
    vim.uv.fs_open = original_fs_open
    assert.is_true(fallback_ok, tostring(fallback_err))
    assert.are.equal(vim.v.progpath, fallback_argv[1])

    local missing_nvim = linux.check({
      nvim = "/definitely/missing/nvim",
    })
    assert.are.equal("nvim", missing_nvim.stage)

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
      missing_staging.message)

    local temporary_failure = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = {
        create_temp_directory = function()
          return nil, "no temporary root"
        end,
      },
    })
    assert.are.equal("temporary-root", temporary_failure.stage)

    local timeout = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = fs,
      system = function() return nil end,
    })
    assert.are.equal("probe", timeout.stage)
    assert.matches("timed out", timeout.message)

    local malformed = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = fs,
      system = function()
        return { code = 125, stdout = "invalid", stderr = "" }
      end,
    })
    assert.are.equal("probe", malformed.stage)
    assert.matches("invalid sandbox protocol frame length",
      malformed.message)

    local stderr = linux.check({
      nvim = vim.env.NEOAGENT_NVIM,
      fs = fs,
      system = function()
        return {
          code = 2,
          stdout = protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 2, signal = 0,
            }),
          stderr = "probe process failed",
        }
      end,
    })
    assert.matches("probe process failed", stderr.message)

    local original_rmdir = vim.uv.fs_rmdir
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

  it("uses native macOS sandbox-exec for probes and operations", function()
    local root = temp()
    local executable = vim.fs.joinpath(root, "sandbox-exec")
    assert(fs.write_all(executable, "#!/bin/sh\nexit 0\n"))
    assert(vim.uv.fs_chmod(executable, 493))
    local nvim = vim.env.NEOAGENT_NVIM
    local macos = require("neoagent.sandbox.macos")
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
    assert.are.equal(executable, checked[1][1])
    assert.is_true(macos.check({
      sandbox_exec = executable,
      nvim = nvim,
    }).ok)
    local separator
    for index, value in ipairs(checked[1]) do
      if value == "--" then separator = index break end
    end
    assert.are.equal(nvim, checked[1][separator + 1])

    local calls = {}
    local services = {
      sandbox_exec = executable,
      nvim = nvim,
      fs = fs,
      process = function(argv, opts)
        calls[#calls + 1] = { argv = argv, opts = opts }
        return {
          code = 0,
          signal = 0,
          stdout = "runtime-data",
          stderr = "",
          output = "runtime-data",
          timed_out = false,
        }
      end,
    }
    local shared_tmp = vim.uv.fs_realpath(vim.uv.os_tmpdir())
    local value = macos.exec({
      argv = { "/bin/sh", "-c", "true" },
      cwd = root,
      env = { TMPDIR = shared_tmp, TMP = shared_tmp, TEMP = shared_tmp },
      profile = profile(root),
      capture = true,
      kill_grace_ms = 0,
    }, services)
    assert.are.equal(0, value.code)
    assert.are.equal(executable, calls[1].argv[1])
    assert.are.equal(shared_tmp, calls[1].opts.env.TMPDIR)
    assert.are.equal(shared_tmp, calls[1].opts.env.TMP)
    assert.are.equal(shared_tmp, calls[1].opts.env.TEMP)
    assert.are.equal("1", calls[1].opts.env.NEOAGENT_SANDBOX_EXEC)
    assert.are.equal(100, calls[1].opts.kill_grace_ms)
    local runtime = assert(vim.api.nvim_get_runtime_file(
      "scripts/sandbox_macos_runtime.lua", false)[1])
    assert.is_true(vim.tbl_contains(calls[1].argv,
      vim.uv.fs_realpath(runtime)))
    assert.are.same({
      "--", "/bin/sh", "-c", "true",
    }, vim.list_slice(calls[1].argv, #calls[1].argv - 3))

    local data = assert(macos.fs({
      operation = "read",
      path = vim.fs.joinpath(root, "file"),
      profile = profile(root),
    }, services))
    assert.are.equal("runtime-data", data)
    assert.are.equal(30000, calls[2].opts.timeout_ms)
    assert.matches("NEOAGENT_SANDBOX_FS",
      table.concat(vim.tbl_keys(calls[2].opts.env), " "))
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
    local get_runtime_file = vim.api.nvim_get_runtime_file
    vim.api.nvim_get_runtime_file = function(path, all)
      if path == "scripts/sandbox_macos_runtime.lua" then return {} end
      return get_runtime_file(path, all)
    end
    local checked, missing_runtime = pcall(macos.check, {
      sandbox_exec = executable,
      nvim = vim.env.NEOAGENT_NVIM,
    })
    local fs_ok, fs_err = pcall(function()
      macos.fs({
        operation = "read",
        path = vim.fs.joinpath(root, "file"),
        profile = profile(root),
      }, {
        sandbox_exec = executable,
        nvim = vim.env.NEOAGENT_NVIM,
        fs = fs,
        process = function() error("must not run") end,
      })
    end)
    local exec_ok, exec_err = pcall(function()
      macos.exec(request(root), {
        sandbox_exec = executable,
        nvim = vim.env.NEOAGENT_NVIM,
        fs = fs,
        process = function() error("must not run") end,
      })
    end)
    vim.api.nvim_get_runtime_file = get_runtime_file
    assert.is_true(checked)
    assert.are.equal("runtime", missing_runtime.stage)
    assert.is_false(fs_ok)
    assert.matches("sandbox runtime was not found", fs_err.message)
    assert.is_false(exec_ok)
    assert.matches("sandbox runtime was not found", exec_err.message)
    local failed_probe = macos.check({
      sandbox_exec = executable,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function() return nil end,
    })
    assert.are.equal("sandbox-exec-probe", failed_probe.stage)
    assert.matches("probe failed", failed_probe.message)

    local active_profile = profile(root)
    local function services(process, filesystem)
      return {
        sandbox_exec = executable,
        nvim = vim.env.NEOAGENT_NVIM,
        fs = filesystem or fs,
        process = process,
      }
    end
    local err = caught(function()
      macos.exec(request(root, active_profile), services(function()
        error("spawn exploded")
      end))
    end)
    assert.are.equal("sandbox_unavailable", err.kind)
    assert.matches("process failed to start", err.message)

    local cancellation = {
      kind = "cancelled",
      message = "cancelled by caller",
    }
    err = caught(function()
      macos.exec(request(root, active_profile), services(function()
        error(cancellation, 0)
      end))
    end)
    assert.are.equal(cancellation, err)

    err = caught(function()
      macos.exec(request(root, active_profile),
        services(function() return {} end))
    end)
    assert.matches("invalid process result", err.message)

    local failed, reason = macos.fs({
      operation = "write_all",
      path = vim.fs.joinpath(root, "file"),
      data = "data",
      profile = active_profile,
    }, services(function()
      return {
        code = 73,
        signal = 0,
        stdout = "",
        stderr = "write denied",
      }
    end))
    assert.is_nil(failed)
    assert.are.equal("write denied", reason)

    local written = macos.fs({
      operation = "write_all",
      path = vim.fs.joinpath(root, "file"),
      data = "data",
      profile = active_profile,
    }, services(function()
      return { code = 0, signal = 0, stdout = "", stderr = "" }
    end))
    assert.is_true(written)
  end)

  it("keeps the public sandbox_exec API platform-neutral", function()
    local root = temp()
    local called
    local fake = {
      name = "fake",
      check = function()
        return {
          ok = true,
          platform = "fake",
          capabilities = { process = true },
        }
      end,
      exec = function(request, services)
        called = { request = request, services = services }
        return {
          code = 0, signal = 0, stdout = "ok", stderr = "",
          output = "ok", timed_out = false,
        }
      end,
    }
    local value = require("neoagent.sandbox").sandbox_exec(
      { "/bin/echo", "" }, {
        os = "Linux",
        platforms = { linux = fake },
        profile = profile(root),
        cwd = root,
        env = {},
        fs = fs,
        process = function() end,
      })
    assert.are.equal("ok", value.stdout)
    assert.are.same({ "/bin/echo", "" }, called.request.argv)
    assert.are.equal(root, called.request.cwd)
    assert.are.equal(fs, called.services.fs)
    assert.is_true(called.services.capabilities.process)
    assert.is_table(require("neoagent.sandbox").new({
      platform = {
        name = "test",
        exec = function() end,
        fs = function() end,
      },
      profile = profile(root),
    }))
    assert.has_error(function()
      require("neoagent.sandbox").sandbox_exec({ "echo" }, {
        os = "Windows",
        profile = profile(root),
      })
    end)
    fake.check = function()
      return {
        ok = false,
        platform = "fake",
        stage = "probe",
        message = "native probe failed",
      }
    end
    local ok, err = pcall(require("neoagent.sandbox").sandbox_exec,
      { "echo" }, {
        os = "Linux",
        platforms = { linux = fake },
        profile = profile(root),
      })
    assert.is_false(ok)
    assert.are.equal("sandbox_unavailable", err.kind)
    assert.matches("native probe failed", err.message)
  end)
end)
