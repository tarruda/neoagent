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
  assert(type(value) == "table")
  assert(type(value.message) == "string")
  ---@cast value Neoagent.Error
  return value
end

---@param fn fun(): unknown
---@return Neoagent.Error
local function caught(fn)
  local ok, value = pcall(fn)
  assert.is_false(ok)
  assert(type(value) == "table")
  ---@cast value Neoagent.Error
  return value
end

---@param root string
---@param active_profile? Neoagent.SandboxProfile
---@return Neoagent.SandboxProcessRequest
local function request(root, active_profile)
  return {
    argv = { "/bin/sh", "-c", "true" },
    cwd = root,
    env = { PATH = "/bin:/usr/bin" },
    profile = active_profile or profile(root),
    capture = true,
  }
end

---@param overrides Partial<Neoagent.SandboxFilesystemService>
---@return Neoagent.SandboxFilesystemService
local function filesystem(overrides)
  ---@type Neoagent.SandboxFilesystemService
  local value = vim.tbl_extend("force", fs, overrides)
  return value
end

---@param opts Neoagent.ProcessOptions?
---@param data string
---@param is_stderr boolean
local function emit_output(opts, data, is_stderr)
  assert(assert(opts).on_output)(data, is_stderr,
    is_stderr and "" or data, is_stderr and data or "", data)
end

---@param events Neoagent.SandboxProtocolEvent[]
---@param host? Neoagent.ProcessResult
---@return fun(argv: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult
local function framed_process(events, host)
  return function(_, opts)
    for _, event in ipairs(events) do
      emit_output(opts, protocol.encode(event), false)
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

---@param path string
---@param name string
---@param boundary string
---@param environment table<string, unknown>
---@return function
local function runtime_function(path, name, boundary, environment)
  local source = assert(fs.read(path))
  local marker = "local function " .. name .. "("
  local first = source:find(marker, 1, true)
  local selected
  if first then
    local last = assert((source:find(boundary, first, true)))
    selected = source:sub(first, last - 1)
      .. "\nreturn " .. name
  else
    assert.are.equal("atomic_replace", name)
    local inline = '      elseif request.operation == "atomic_replace" then'
    first = assert((source:find(inline, 1, true)))
    first = assert((source:find("\n", first, true))) + 1
    local last = assert((source:find(
      "\n      end\n      finish(64)", first, true)))
    selected = "return function(request)\n"
      .. source:sub(first, last - 1) .. "\nend"
  end
  local chunk, load_err = loadstring(selected, "@" .. path .. ":" .. name)
  assert(chunk, load_err)
  setfenv(assert(chunk), setmetatable(environment, { __index = _G }))
  local value = assert(chunk)()
  assert(type(value) == "function")
  return value
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

  it("rejects Linux atomic replacement second-inspection errors", function()
    local path = "/workspace/file"
    local suffix = string.rep("a", 32)
    local temporary = path .. "." .. suffix .. ".tmp"

    local linux_lstats, linux_unlinks, linux_renames = 0, {}, 0
    local linux_exit
    local linux = runtime_function(
      "scripts/sandbox_linux_runtime.lua", "atomic_replace",
      "\n-- Validate every value", {
        vim = {
          islist = vim.islist,
          uv = {
            fs_lstat = function()
              linux_lstats = linux_lstats + 1
              if linux_lstats == 1 then
                return { type = "file", mode = 420 }
              end
              return nil, "inspection denied", "EACCES"
            end,
          },
        },
        bit = bit,
        ffi = {
          cast = function(_, value) return value end,
          new = function() return {} end,
          string = function(buffer, count)
            return buffer.data:sub(1, count)
          end,
          errno = function() return 0 end,
        },
        C = {
          open = function() return 10 end,
          read = function(_, buffer)
            if buffer.data then return 0 end
            buffer.data = "payload"
            return #buffer.data
          end,
          close = function() return 0 end,
          chmod = function() return 0 end,
          unlinkat = function(_, value)
            linux_unlinks[#linux_unlinks + 1] = value
            return 0
          end,
          renameat = function()
            linux_renames = linux_renames + 1
            return 0
          end,
        },
        O = { WRONLY = 1, CREAT = 64, EXCL = 128, CLOEXEC = 524288 },
        E = { EINTR = 4 },
        AT_FDCWD = -100,
        write_all = function() return true end,
        missing = function(err, code)
          return code == "ENOENT"
            or type(err) == "string" and err:find("ENOENT", 1, true)
              ~= nil
        end,
        finish = function(code)
          linux_exit = code
          error("exit", 0)
        end,
      })
    local linux_ok = pcall(linux, {
      path = path,
      suffix = suffix,
      policy = { mode = 420 },
    })
    assert.is_false(linux_ok)
    assert.are.equal(74, linux_exit)
    assert.are.same({ temporary }, linux_unlinks)
    assert.are.equal(0, linux_renames)
  end)

  it("rejects macOS atomic replacement second-inspection errors", function()
    local path = "/workspace/file"
    local suffix = string.rep("a", 32)
    local temporary = path .. "." .. suffix .. ".tmp"
    local mac_lstats, mac_unlinks, mac_renames = 0, {}, 0
    local mac_failure
    local macos = runtime_function(
      "scripts/sandbox_macos_runtime.lua", "atomic_replace",
      "\nlocal function filesystem_request", {
        vim = {
          islist = vim.islist,
          uv = {
            fs_lstat = function()
              mac_lstats = mac_lstats + 1
              if mac_lstats == 1 then
                return { type = "file", mode = 420 }
              end
              return nil, "inspection denied", "EACCES"
            end,
            fs_open = function() return 10 end,
            fs_write = function(_, data) return #data end,
            fs_close = function() return true end,
            fs_chmod = function() return true end,
            fs_unlink = function(value)
              mac_unlinks[#mac_unlinks + 1] = value
              return true
            end,
            fs_rename = function()
              mac_renames = mac_renames + 1
              return true
            end,
          },
        },
        bit = bit,
        target_observation = function(stat)
          return {
            exists = stat ~= nil,
            type = stat and stat.type or nil,
            device = stat and stat.dev or nil,
            inode = stat and stat.ino or nil,
            mode = stat and stat.mode or nil,
          }
        end,
        same_target = function(left, right)
          return left.exists == right.exists and left.type == right.type
            and left.device == right.device and left.inode == right.inode
            and left.mode == right.mode
        end,
        missing = function(err, code)
          return code == "ENOENT"
            or type(err) == "string" and err:find("ENOENT", 1, true)
              ~= nil
        end,
        fail = function(message)
          mac_failure = message
          error("exit", 0)
        end,
      })
    local mac_ok = pcall(macos, {
      path = path,
      suffix = suffix,
      policy = { mode = 420 },
    }, "payload")
    assert.is_false(mac_ok)
    assert.are.equal("inspection denied", mac_failure)
    assert.are.same({ temporary }, mac_unlinks)
    assert.are.equal(0, mac_renames)
  end)

  it("keeps Windows atomic replacement second inspection fail-closed", function()
    local path = "/workspace/file"
    local suffix = string.rep("a", 32)
    local temporary = path .. "." .. suffix .. ".tmp"
    local windows_lstats, windows_deletes, windows_moves = 0, {}, 0
    local windows = runtime_function(
      "scripts/sandbox_windows_runtime.lua", "direct_atomic_replace",
      "\nlocal function direct_mkdirp", {
        vim = { islist = vim.islist },
        bit = bit,
        WIN32 = {
          ERROR = {
            INVALID_PARAMETER = 87,
            FILE_NOT_FOUND = 2,
            PATH_NOT_FOUND = 3,
            ACCESS_DENIED = 5,
          },
          FILE = {
            ATTRIBUTE_REPARSE_POINT = 1024,
            ATTRIBUTE_DIRECTORY = 16,
            MOVE_REPLACE_EXISTING = 1,
            MOVE_WRITE_THROUGH = 8,
          },
        },
        file_attributes = function()
          windows_lstats = windows_lstats + 1
          if windows_lstats == 1 then return 0 end
          return nil, 5
        end,
        path_identity = function()
          return { volume = 1, high = 0, low = 1 }
        end,
        same_identity = function(left, right)
          return left and right and left.volume == right.volume
            and left.high == right.high and left.low == right.low
        end,
        direct_write = function() return true end,
        wide = function(value) return value end,
        K = {
          DeleteFileW = function(value)
            windows_deletes[#windows_deletes + 1] = value
            return 1
          end,
          MoveFileExW = function()
            windows_moves = windows_moves + 1
            return 1
          end,
        },
      })
    local windows_ok, windows_err = windows(
      path, "payload", { mode = 420 }, suffix)
    assert.is_nil(windows_ok)
    assert.are.equal(5, windows_err)
    assert.are.same({ temporary }, windows_deletes)
    assert.are.equal(0, windows_moves)
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

  it("decodes Linux process output without host capture duplication", function()
    local root = temp()
    local reserved = vim.fs.joinpath(root, "reserved")
    local also_reserved = vim.fs.joinpath(root, "also-reserved")
    local requests = {}
    local services = {
      fs = fs,
      nvim = vim.env.NEOAGENT_NVIM,
      capabilities = { procfs = "host" },
      process = function(argv, opts)
        local encoded = encoded_spec(assert(opts).env)
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
            { path = also_reserved, access = "deny" },
            { path = reserved, access = "deny" },
          }, spec.protected_create)
        end
        emit_output(opts, protocol.encode({
          v = 1, type = "ready",
        }), false)
        emit_output(opts, protocol.encode({
          v = 1,
          type = "output",
          stream = "stdout",
          seq = 1,
          data = spec.mode == "fs" and "file\0data" or "out\0",
        }), false)
        emit_output(opts, protocol.encode({
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
        { path = also_reserved, access = "deny" },
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
    ---@type integer?
    local separator
    for index, value in ipairs(requests[1].argv) do
      if value == "--" then separator = index break end
    end
    assert.is_number(separator)
    assert.are.equal(vim.uv.fs_realpath("/bin/sh"),
      requests[1].argv[assert(separator) + 1])
    assert.are.same({ "-c", "printf output" }, {
      requests[1].argv[assert(separator) + 2],
      requests[1].argv[assert(separator) + 3],
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

    data = assert(platform.fs({
      operation = "read_range",
      path = vim.fs.joinpath(root, "file"),
      offset = 17,
      size = 4096,
      profile = profile(root),
    }, services))
    assert.are.equal("file\0data", data)
    assert.are.equal("read_range", requests[3].spec.fs.operation)
    assert.are.equal(17, requests[3].spec.fs.offset)
    assert.are.equal(4096, requests[3].spec.fs.size)

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

    local overflow = caught(function()
      platform.exec({
        argv = { "/bin/sh", "-c", "printf output" },
        cwd = root,
        env = {},
        profile = profile(root),
        capture = true,
        max_capture_bytes = 3,
      }, services)
    end)
    assert.matches("Invalid Linux sandbox protocol", overflow.message)
    assert.are.equal("sandbox output exceeded capture limit", overflow.detail)
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
        fs = filesystem({
          create_temp_directory = function()
            created = true
            error("must not create")
          end,
        }),
        nvim = vim.env.NEOAGENT_NVIM,
        process = function() error("must not run") end,
      })
    end)
    assert.is_false(created)
    assert.matches("filesystem profile exposes", tostring(err.detail))
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
            emit_output(opts, "\255\255\255\255", false)
            return { code = 0, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
          end,
          message = "Invalid Linux sandbox protocol",
        },
        {
          process = function(_, opts)
            emit_output(opts, protocol.encode({ v = 1, type = "ready" }),
              false)
            emit_output(opts, "runtime diagnostic", true)
            return { code = 125, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
          end,
          message = "sandbox protocol has no terminal event",
        },
        {
          process = framed_process({
            { v = 1, type = "error", stage = "seccomp", errno = 1 },
          }, { code = 125, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }),
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
        assert.are.equal("sandbox_unavailable", structured_error(err).kind)
        assert.matches(case.message, structured_error(err).message)
      end

      local bounded_error = caught(function()
        linux.exec(request(root, active_profile),
          services(function() error(string.rep("x", 1100)) end))
      end)
      local detail = tostring(structured_error(bounded_error).detail)
      assert.are.equal("...", detail:sub(-3))
      assert.is_true(#detail <= 1000)

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
      assert.matches("executable was not found", structured_error(err).message)

      local original_rmdir = vim.uv.fs_rmdir
      local failed_root
      vim.uv.fs_rmdir = function(path)
        failed_root = path
        return nil, "cleanup denied"
      end
      err = caught(function()
        linux.exec(missing, services(function() error("must not run") end))
      end)
      vim.uv.fs_rmdir = original_rmdir
      if failed_root then vim.fn.delete(failed_root, "rf") end
      assert.matches("Could not remove Linux sandbox root",
        structured_error(err).message)

      local relative = request(root, active_profile)
      relative.argv = { "sh", "-c", "true" }
      local launched
      linux.exec(relative, services(function(argv, opts)
        launched = argv
        emit_output(opts, protocol.encode({ v = 1, type = "ready" })
          .. protocol.encode({
            v = 1, type = "exit", code = 0, signal = 0,
          }), false)
        return { code = 0, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
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
      assert.matches("Could not create Linux sandbox root", structured_error(err).message)

      err = caught(function()
        linux.exec(request(root, active_profile), services(function()
          error("must not run")
        end, {
          create_temp_directory = function()
            return vim.fs.joinpath(root, "missing-temporary-root")
          end,
        }))
      end)
      assert.matches("Could not create Linux sandbox root", structured_error(err).message)

      original_rmdir = vim.uv.fs_rmdir
      ---@type string?
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
        structured_error(cleanup_err).message)
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
        local spec = vim.json.decode(encoded_spec(assert(opts).env))
        assert.are.same({
          { path = nested, access = "deny" },
        }, spec.protected_create)
        emit_output(opts, protocol.encode({ v = 1, type = "ready" })
          .. protocol.encode({
            v = 1, type = "exit", code = 0, signal = 0,
          }), false)
        return { code = 0, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
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
      local err = caught(function()
        linux.exec(request(root), {
          fs = fs,
          nvim = vim.env.NEOAGENT_NVIM,
          process = function(_, opts)
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
            return { code = 0, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
          end,
        })
      end)
      assert.matches("Could not remove Linux sandbox root", structured_error(err).message)
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
      structured_error(launch_err).message)

    local original_fs_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, flags, mode)
      if path == "/proc/self/cmdline" then return nil end
      return original_fs_open(path, flags, mode)
    end
    ---@type string[]?
    local fallback_argv
    local fallback_ok, fallback_err = pcall(function()
      linux.exec(request(root), {
        fs = fs,
        process = function(argv, opts)
          fallback_argv = argv
          emit_output(opts, protocol.encode({ v = 1, type = "ready" })
            .. protocol.encode({
              v = 1, type = "exit", code = 0, signal = 0,
            }), false)
          return { code = 0, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
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
      nvim = { true --[[@as string]] },
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
          stderr = "probe process failed",
        }
      end,
    })
    assert.matches("probe process failed", (assert(stderr.message)))

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

  it("uses native macOS sandbox-exec for probes and operations", function()
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
      nvim = nvim,
    }).ok)
    ---@type integer?
    local separator
    for index, value in ipairs(assert(checked)[1]) do
      if value == "--" then separator = index break end
    end
    assert.are.equal(nvim, assert(checked)[1][assert(separator) + 1])

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
    local shared_tmp = assert(vim.uv.fs_realpath(vim.uv.os_tmpdir()))
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
    local cleanup_helper_granted = false
    for _, argument in ipairs(calls[1].argv) do
      cleanup_helper_granted = cleanup_helper_granted
        or argument:match("^%-DPATH_%d+=/bin/sh$") ~= nil
    end
    assert.is_true(cleanup_helper_granted)
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

    data = assert(macos.fs({
      operation = "read_range",
      path = vim.fs.joinpath(root, "file"),
      offset = 19,
      size = 8192,
      profile = profile(root),
    }, services))
    assert.are.equal("runtime-data", data)
    local process_environment = calls[3].opts.env --[[@as table<string, string>]]
    local encoded_request = process_environment.NEOAGENT_SANDBOX_FS
    assert.is_string(encoded_request)
    local filesystem_request = vim.json.decode(encoded_request)
    assert.are.equal("read_range", filesystem_request.operation)
    assert.are.equal(19, filesystem_request.offset)
    assert.are.equal(8192, filesystem_request.size)
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
    assert.matches("sandbox runtime was not found", structured_error(fs_err).message)
    assert.is_false(exec_ok)
    assert.matches("sandbox runtime was not found", structured_error(exec_err).message)
    local failed_probe = macos.check({
      sandbox_exec = executable,
      nvim = vim.env.NEOAGENT_NVIM,
      system = function() return nil end,
    })
    assert.are.equal("sandbox-exec-probe", failed_probe.stage)
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
    assert.are.equal("sandbox_unavailable", structured_error(err).kind)
    assert.matches("process failed to start", structured_error(err).message)

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
    assert.matches("invalid process result", structured_error(err).message)

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

  it("resolves a configured macOS Neovim command through PATH", function()
    local root = temp()
    local executable = vim.fs.joinpath(root, "sandbox-exec")
    assert(fs.write_all(executable, "#!/bin/sh\nexit 0\n"))
    assert(vim.uv.fs_chmod(executable, 493))
    local command = vim.fs.basename(vim.fn.exepath("nvim"))
    local expected = executable_path(command)
    ---@type string[]?
    local argv
    local status = require("neoagent.sandbox.macos").check({
      sandbox_exec = executable,
      nvim = command,
      system = function(value)
        argv = value
        return { code = 0, signal = 0, stdout = "", stderr = "" }
      end,
    })
    assert.is_true(status.ok)
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
          type = path:lower():match("%.exe$") and "file" or "directory",
        }
      end
      return original_stat(path)
    end
    cleanup(function()
      vim.uv.fs_realpath = original_realpath
      vim.uv.fs_stat = original_stat
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

  it("adapts Windows operations to the standalone Lua runtime", function()
    windows_test_host()
    local windows = require("neoagent.sandbox.windows")
    local framed = require("neoagent.sandbox.protocol")
    local seen = {}
    local services = {
      nvim = "C:\\Neovim\\bin\\nvim.exe",
      process = function(argv, opts)
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
        return {
          code = 0, signal = 0, stdout = "", stderr = "",
          output = "", timed_out = false,
        }
      end,
    }
    local chunks = {}
    local value = windows.exec({
      argv = { "cmd.exe", "/d", "/c", "echo ok" },
      cwd = "C:\\Repo",
      env = {
        Path = "C:\\Windows\\System32",
        PATHEXT = ".EXE;.CMD",
      },
      stdin = "input",
      profile = windows_profile(),
      capture = true,
      timeout_ms = 500,
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
    assert.are.same({
      "C:\\Windows\\System32\\cmd.exe",
      "/d", "/c", "echo ok",
    }, seen[1].spec.argv)
    assert.are.equal("exec", seen[1].spec.mode)
    assert.are.equal(500, seen[1].spec.timeout_ms)
    assert.are.equal(10500, seen[1].opts.timeout_ms)
    assert.are.equal("C:\\state",
      seen[1].opts.env.NEOAGENT_WINDOWS_SANDBOX_STATE)
    assert.are.equal("input", seen[1].opts.stdin)
    assert.is_false(seen[1].opts.capture)
    assert.is_true(vim.list_contains(seen[1].argv, "-l"))
    assert.are.same({
      "C:\\Neovim\\bin",
      "C:\\Neovim\\share\\nvim\\runtime",
    }, seen[1].spec.runner.read_roots)
    assert.are.equal("C:\\state\\shared-tmp", windows.temporary_root())

    local read = windows.fs({
      operation = "read",
      path = "C:\\Repo\\file",
      profile = windows_profile(),
    }, services)
    assert.are.equal("out\0", read)
    assert.are.equal("fs", seen[2].spec.mode)
    assert.are.equal("read", seen[2].spec.fs.operation)
    assert.are.equal("C:\\state\\shared-tmp", seen[2].spec.cwd)

    read = windows.fs({
      operation = "read_range",
      path = "C:\\Repo\\file",
      offset = 23,
      size = 16384,
      profile = windows_profile(),
    }, services)
    assert.are.equal("out\0", read)
    assert.are.equal("read_range", seen[3].spec.fs.operation)
    assert.are.equal(23, seen[3].spec.fs.offset)
    assert.are.equal(16384, seen[3].spec.fs.size)

    assert.is_true(windows.fs({
      operation = "write_all",
      path = "C:\\Repo\\file",
      data = "written",
      profile = windows_profile(),
    }, services))

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
    value = windows.exec({
      argv = { "C:\\bin\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = windows_profile(),
    }, {
      nvim = "C:\\Portable\\bin\\nvim.exe",
      process = services.process,
    })
    assert.are.equal(0, value.code)
    assert.are.same({
      "C:\\Portable\\bin",
      "C:\\Portable\\runtime",
    }, seen[#seen].spec.runner.read_roots)
    vim.uv.fs_stat = simulated_stat
    vim.env.VIMRUNTIME = previous_runtime

    value = windows.exec({
      argv = { "tool", "argument" },
      cwd = "C:\\Repo",
      env = { PATH = "", PATHEXT = "EXE;.CMD" },
      profile = windows_profile(),
    }, services)
    assert.are.equal(0, value.code)
    assert.are.equal("C:\\Repo\\tool.EXE",
      seen[#seen].spec.argv[1])

    value = windows.exec({
      argv = { "bin\\tool", "argument" },
      cwd = "C:\\Repo",
      env = { PATH = "" },
      profile = windows_profile(),
    }, services)
    assert.are.equal(0, value.code)
    assert.are.equal("C:\\Repo\\bin\\tool.EXE",
      seen[#seen].spec.argv[1])

    local launched_ok, launch_err = pcall(windows.exec, {
      argv = { "C:\\bin\\tool.exe" },
      cwd = "C:\\Repo",
      env = {},
      profile = windows_profile(),
    }, {
      nvim = { vim.env.NEOAGENT_NVIM, "--clean" },
      process = services.process,
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
    local framed = require("neoagent.sandbox.protocol")
    local fake_fs = filesystem({
      create_temp_directory = function()
        return "C:\\probe"
      end,
      write_all = function() return true end,
      mkdirp = function() return true end,
    })
    ---@type {argv: string[], timeout: integer, spec: {mode: string, probe: {deny_write: string}}}?
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
    assert.is_true(status.ok)
    assert.is_true(assert(status.capabilities).restricted_token)
    assert.is_true(assert(status.capabilities).windows_filtering_platform)
    assert.is_true(assert(status.capabilities).private_desktop)
    assert.are.equal("probe", assert(assert(captured).spec).mode)
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
    assert.are.equal("probe", checked({
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
      windows.exec({
        argv = { "C:\\bin\\tool.exe" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, {
        nvim = vim.env.NEOAGENT_NVIM,
        process = function() error("must not run") end,
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
      windows.exec({
        argv = { "C:\\bin\\tool.exe" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, {
        nvim = vim.env.NEOAGENT_NVIM,
        process = function() error("must not run") end,
      })
    end)
    vim.api.nvim_get_runtime_file = get_runtime_file
    assert.matches("runtime was not found", missing_runtime.message)

    assert.are.equal("nvim", windows.check({
      nvim = "/definitely/missing/nvim",
    }).stage)
    local missing_nvim = caught(function()
      windows.exec({
        argv = { "C:\\bin\\tool.exe" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, {
        nvim = "/definitely/missing/nvim",
        process = function() error("must not run") end,
      })
    end)
    assert.matches("cannot be resolved", missing_nvim.message)

    local missing_executable = caught(function()
      windows.exec({
        argv = { "C:\\Repo\\missing.cmd" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, {
        nvim = vim.env.NEOAGENT_NVIM,
        process = function() error("must not run") end,
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

  it("fails Windows execution closed across process and protocol errors", function()
    windows_test_host()
    local windows = require("neoagent.sandbox.windows")
    local framed = require("neoagent.sandbox.protocol")
    ---@param process fun(argv: string[], opts?: Neoagent.ProcessOptions): Neoagent.ProcessResult
    ---@param request_value? Partial<Neoagent.SandboxProcessRequest>
    local function execute(process, request_value)
      ---@type Neoagent.SandboxProcessRequest
      local selected = vim.tbl_extend("force", {
        argv = { "C:\\bin\\tool.exe" },
        cwd = "C:\\Repo",
        env = {},
        profile = windows_profile(),
      }, request_value or {})
      return windows.exec(selected, {
        nvim = vim.env.NEOAGENT_NVIM,
        process = process,
      })
    end

    local err = caught(function()
      execute(function() error("spawn exploded") end)
    end)
    assert.matches("runtime failed", structured_error(err).message)
    local cancellation = { kind = "cancelled", message = "stop" }
    err = caught(function()
      execute(function() error(cancellation, 0) end)
    end)
    assert.are.equal(cancellation, err)
    err = caught(function()
      execute(function()
        local malformed = {}
        ---@cast malformed Neoagent.ProcessResult
        return malformed
      end)
    end)
    assert.matches("invalid process result", structured_error(err).message)

    local timed_out = {
      code = 124, signal = 0, stdout = "", stderr = "",
      output = "", timed_out = true,
    }
    local value = execute(function() return timed_out end)
    assert.is_true(value.timed_out)
    assert.are.equal(124, value.code)

    value = execute(windows_events({
      { v = 1, type = "ready" },
      {
        v = 1, type = "exit", code = 124, signal = 0,
        timed_out = true,
      },
    }), { timeout_ms = 500 })
    assert.is_true(value.timed_out)
    assert.are.equal(124, value.code)

    err = caught(function()
      execute(function(_, opts)
        emit_output(opts, string.char(0, 0, 0, 1) .. "{", false)
        emit_output(opts, "ignored after decoder failure", false)
        return {
          code = 0, signal = 0, stdout = "", stderr = "",
          output = "", timed_out = false,
        }
      end)
    end)
    assert.matches("Invalid Windows sandbox protocol", structured_error(err).message)
    err = caught(function()
      execute(windows_events({
        { v = 1, type = "ready" },
        {
          v = 1, type = "output", stream = "stdout",
          seq = 1, data = "overflow",
        },
        { v = 1, type = "exit", code = 0, signal = 0 },
      }), { capture = true, max_capture_bytes = 3 })
    end)
    assert.matches("Invalid Windows sandbox protocol", structured_error(err).message)
    assert.are.equal("sandbox output exceeded capture limit", err.detail)
    err = caught(function()
      execute(function() error(string.rep("x", 2000)) end)
    end)
    assert.are.equal(1000, #tostring(err.detail))
    assert.matches("%.%.%.$", tostring(err.detail))
    err = caught(function()
      execute(windows_events({
        { v = 1, type = "ready" },
      }, "runtime diagnostic"))
    end)
    assert.matches("no terminal event", structured_error(err).message)
    assert.matches("runtime diagnostic", tostring(err.detail))
    err = caught(function()
      execute(windows_events({
        { v = 1, type = "error", stage = "acl", errno = 5 },
      }))
    end)
    assert.matches("failed at acl", structured_error(err).message)
    assert.are.equal("win32=5", err.detail)

    local failed, reason = windows.fs({
      operation = "write_all",
      path = "C:\\Repo\\file",
      data = "data",
      profile = windows_profile(),
    }, {
      nvim = vim.env.NEOAGENT_NVIM,
      process = windows_events({
        { v = 1, type = "ready" },
        {
          v = 1, type = "output", stream = "stderr",
          seq = 1, data = "write denied",
        },
        { v = 1, type = "exit", code = 7, signal = 0 },
      }),
    })
    assert.is_nil(failed)
    assert.are.equal("write denied", reason)
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

  it("keeps the public sandbox_exec API platform-neutral", function()
    local root = temp()
    ---@type {request: Neoagent.SandboxProcessRequest, services: Neoagent.SandboxExecutionServices}?
    local called
    ---@type Neoagent.SandboxPlatform<unknown>
    local fake = {
      name = "fake",
      fs = function() error("unexpected filesystem operation") end,
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
        process = function() error("unexpected host process") end,
      })
    assert.are.equal("ok", value.stdout)
    assert.are.same({ "/bin/echo", "" }, assert(called).request.argv)
    assert.are.equal(root, assert(called).request.cwd)
    assert.are.equal(fs, assert(called).services.fs)
    assert.is_true(assert(assert(called).services.capabilities).process)

    local source_profile = profile(root)
    fake.compile = function(selected, ctx, services)
      assert.are.same({ workspace = root }, ctx)
      assert.is_true(assert(services.capabilities).process)
      selected.id = "compiled-profile"
      return selected
    end
    require("neoagent.sandbox").sandbox_exec({ "echo" }, {
      os = "Linux", platforms = { linux = fake },
      profile = source_profile, ctx = { workspace = root },
    })
    assert.are.equal("compiled-profile", assert(called).request.profile.id)
    assert.are.equal("platform-test", source_profile.id)
    assert.is_table(require("neoagent.sandbox").new({
      platform = {
        name = "test",
        check = function() return { ok = true, platform = "test" } end,
        exec = function() error("unexpected process") end,
        fs = function() error("unexpected filesystem operation") end,
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
    assert.are.equal("sandbox_unavailable", structured_error(err).kind)
    assert.matches("native probe failed", structured_error(err).message)
  end)
end)
