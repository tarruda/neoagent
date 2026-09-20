if vim.env.NEOAGENT_RPC_BOUNDARY == "1" then
  local root = assert(vim.env.NEOAGENT_RPC_ROOT)
  package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
  require("neoagent.rpc.protocol")
  require("neoagent.rpc.server")
  require("neoagent.rpc.artifacts")
  for _, name in ipairs({
    "read_file",
    "write_file",
    "edit_file",
    "shell",
    "grep",
    "find",
  }) do
    require("neoagent.tools." .. name)
  end
  local forbidden_roots = {
    "applet",
    "neoagent.agent",
    "neoagent.agent_loop",
    "neoagent.applet",
    "neoagent.auth",
    "neoagent.authentication",
    "neoagent.config",
    "neoagent.profile",
    "neoagent.profiles",
    "neoagent.provider",
    "neoagent.providers",
    "neoagent.sandbox",
    "neoagent.session",
    "neoagent.storage",
    "neoagent.ui",
  }
  local loaded = {}
  for name in pairs(package.loaded) do
    local forbidden = false
    for _, prefix in ipairs(forbidden_roots) do
      if name == prefix or name:sub(1, #prefix + 1) == prefix .. "." then
        forbidden = true
        break
      end
    end
    if forbidden then
      loaded[#loaded + 1] = name
    end
  end
  table.sort(loaded)
  io.stdout:write("NEOAGENT_RPC_BOUNDARY=", vim.json.encode(loaded), "\n")
  io.stdout:flush()
  os.exit(#loaded == 0 and 0 or 86)
end

local assert = require("luassert")
local async = require("neoagent.async")

---@generic T
---@param run Neoagent.Run<T, unknown>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function()
    return run:is_done()
  end), "RPC boundary operation did not settle")
  local result = run:result()
  if not result then
    error("RPC boundary operation did not return a result")
  end
  return result
end

describe("neoagent Tool RPC boundary", function()
  it("recognizes concrete shipped implementations and creates expiring shallow proxies", function()
    local registry = require("neoagent.rpc.registry")
    local codec = require("neoagent.rpc.codec")
    local tool = require("neoagent.tools.edit_file").new()
    local marker = {}
    tool.marker = marker
    local adapter = registry.resolve(tool)
    assert.is_not_nil(adapter)
    adapter = registry.resolve(require("neoagent.tools.update_plan").new())
    assert.is_nil(adapter)
    adapter = registry.resolve(require("neoagent.tools.read_agent_documentation").new())
    assert.is_nil(adapter)
    adapter = registry.resolve({
      name = "edit_file",
      description = "unrelated custom Tool",
      input_schema = { type = "object", properties = {} },
      execute = function() error("must not run") end,
    })
    assert.is_nil(adapter)

    local workspace = require("neoagent.workspace").new({
      root = vim.uv.cwd() or vim.fn.getcwd(),
      cwd = vim.uv.cwd() or vim.fn.getcwd(),
    })
    local ctx = {
      context = {
        workspace = workspace,
        files = require("neoagent.files.memory").new(),
      },
      on_update = function() end,
    } --[[@as Neoagent.ToolContext<unknown>]]
    local call = require("neoagent.tools.common").call(ctx)
    local requests = {}
    local connection = {
      request = function(_, method, payload)
        requests[#requests + 1] = { method = method, payload = payload }
        return {
          content = { { type = "text", text = "remote edit" } },
        }
      end,
      abort = function() end,
    }
    local proxy_value, revoke_value = registry.proxy(tool, {
      call = call,
      invoke = function(method, payload, operation_call)
        return require("neoagent.rpc.tool_client").invoke(connection --[[@as Neoagent.RpcConnection]], method, payload, operation_call)
      end,
    })
    local proxy = assert(proxy_value)
    local revoke = assert(revoke_value)
    assert.are.equal(marker, rawget(proxy, "marker"))
    assert.are.equal(tool.input_schema, proxy.input_schema)
    assert.are_not.equal(tool.execute, proxy.execute)
    local completed = wait(async.run(function()
      return proxy.execute({
        path = "file.txt",
        edits = { { oldText = "old", newText = "new" } },
      }, ctx)
    end))
    assert.is_nil(completed.isError)
    assert.are.equal("remote edit", assert(completed.content[1]).text)
    assert.are.same(codec.methods.edit_file, requests[1].method)
    assert.are.same({
      path = "file.txt",
      resolved_path = vim.fs.joinpath(workspace.cwd, "file.txt"),
      edits = { { old_text = "old", new_text = "new" } },
    }, requests[1].payload)
    revoke()
    local expired = wait(async.run(function()
      return proxy.execute({ path = "file.txt", edits = {} }, ctx)
    end))
    assert.is_false(expired.ok)
    assert.matches("proxy invocation has expired", assert(expired.error).message)
  end)

  it("rejects incompatible request budgets before constructing an executable proxy", function()
    local protocol = require("neoagent.rpc.protocol")
    local original_limit = protocol.MAX_REQUEST
    protocol.MAX_REQUEST = require("neoagent.tools.limits").MAX_INPUT_BYTES - 1
    local created, failure = pcall(require("neoagent.rpc.registry").proxy,
      require("neoagent.tools.write_file").new(), {
        call = {
          workspace = { root = "/workspace", cwd = "/workspace" },
          on_update = function() end,
        },
        invoke = function() error("incompatible requests must not be dispatched") end,
      })
    protocol.MAX_REQUEST = original_limit
    assert.is_false(created, "a proxy was created with an insufficient transport budget")
    assert.matches("Tool request limit exceeds RPC transport capacity", tostring(failure), 1, true)
  end)

  it("adapts Tool updates and artifacts and contains import failures", function()
    local registry = require("neoagent.rpc.registry")
    local codec = require("neoagent.rpc.codec")
    local tool = require("neoagent.tools.read_file").new()

    local function invoke(behavior, storage)
      storage = storage or require("neoagent.files.memory").new()
      local updates = {}
      local ctx = {
        context = {
          workspace = require("neoagent.workspace").new({
            root = vim.uv.cwd() or vim.fn.getcwd(),
            cwd = vim.uv.cwd() or vim.fn.getcwd(),
          }),
          files = storage,
        },
        on_update = function(update)
          updates[#updates + 1] = update
        end,
      } --[[@as Neoagent.ToolContext<unknown>]]
      local aborted = 0
      local connection = {
        request = function(_, method, payload, handlers)
          assert.are.equal(codec.methods.read_file, method)
          assert.are.equal("remote.png", payload.path)
          return behavior(assert(handlers).on_event)
        end,
        abort = function()
          aborted = aborted + 1
        end,
        is_failed = function() return aborted > 0 end,
      }
      local proxy = assert(registry.proxy(tool, {
        call = require("neoagent.tools.common").call(ctx),
        invoke = function(method, payload, operation_call)
          return require("neoagent.rpc.tool_client").invoke(connection --[[@as Neoagent.RpcConnection]], method, payload, operation_call)
        end,
      }))
      local value = wait(async.run(function()
        return proxy.execute({ path = "remote.png" }, ctx)
      end))
      return value, updates, aborted, storage
    end

    local data = "artifact bytes"
    local file_id = vim.fn.sha256(data)
    local value, updates, aborted, storage = invoke(function(on_event)
      on_event({
        name = codec.events.update,
        value = { content = { { type = "text", text = "working" } } },
      })
      on_event({
        name = codec.events.artifact_begin,
        value = { artifact_id = 1, file_id = file_id, bytes = #data },
      })
      on_event({
        name = codec.events.artifact_chunk,
        value = { artifact_id = 1, data = data },
      })
      on_event({
        name = codec.events.artifact_end,
        value = { artifact_id = 1 },
      })
      return {
        content = { {
          type = "image", file_id = file_id, bytes = #data,
          mime_type = "image/png",
        } },
      }
    end)
    assert.are.equal(file_id, assert(value.content[1]).file_id)
    assert.are.equal("working", assert(updates[1].content[1]).text)
    assert.is_not_nil(storage.inspect(file_id))
    assert.are.equal(0, aborted)

    value = invoke(function(on_event)
      on_event({
        name = codec.events.artifact_chunk,
        value = { artifact_id = 1, data = data },
      })
    end)
    assert.is_false(value.ok)
    assert.matches("import", assert(value.error).message)

    local cancelled_storage = require("neoagent.files.memory").new()
    cancelled_storage.put = function()
      error(require("neoagent.async").cancelled_error, 0)
    end
    value = invoke(function(on_event)
      on_event({
        name = codec.events.artifact_begin,
        value = { artifact_id = 1, file_id = file_id, bytes = #data },
      })
      on_event({
        name = codec.events.artifact_chunk,
        value = { artifact_id = 1, data = data },
      })
      on_event({
        name = codec.events.artifact_end,
        value = { artifact_id = 1 },
      })
    end, cancelled_storage)
    assert.is_false(value.ok)
    assert.are.equal("cancelled", assert(value.error).kind)

    value = invoke(function(on_event)
      on_event({
        name = codec.events.update,
        value = { content = { {
          type = "image", file_id = file_id, bytes = #data,
          mime_type = "image/png", id = "preview", revision = 1,
        } } },
      })
    end)
    assert.is_false(value.ok)
    assert.matches("invalid artifact", assert(value.error).message)

    value, _, aborted = invoke(function()
      return false
    end)
    assert.is_false(value.ok)
    assert.are.equal(1, aborted)
    assert.matches("Tool must return a result with content blocks", assert(value.error).message, 1, true)

    value, _, aborted = invoke(function()
      return { content = "invalid" }
    end)
    assert.is_false(value.ok)
    assert.are.equal(1, aborted)
    assert.matches("block list", assert(value.error).message)

    value, _, aborted = invoke(function()
      return { content = { {
        type = "image", file_id = file_id, bytes = #data,
        mime_type = "image/png",
      } } }
    end)
    assert.is_false(value.ok)
    assert.are.equal(1, aborted)
    assert.matches("invalid artifact", assert(value.error).message)

    local unsupported = registry.proxy(
      require("neoagent.tools.update_plan").new(),
      {
        call = {
          workspace = { root = "/workspace", cwd = "/workspace" },
          on_update = function() end,
        },
        invoke = function()
          error("must not invoke")
        end,
      }
    )
    assert.is_nil(unsupported)
  end)

  it("keeps worker dependencies independent of parent compositions", function()
    local source = assert(debug.getinfo(1, "S")).source
    local path = source:sub(1, 1) == "@" and source:sub(2) or source
    path = vim.uv.fs_realpath(path) or vim.fs.normalize(path)
    local root = assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(path))))))))
    local worker = require("neoagent.rpc.worker")
    local argv = worker.nvim_command(vim.env.NEOAGENT_NVIM)
    vim.list_extend(argv, {
      "--headless",
      "--noplugin",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-n",
      "-c",
      "lua dofile(assert(vim.env.NEOAGENT_RPC_BOUNDARY_FILE))",
    })
    local env = require("tests.helpers.tool_worker").environment()
    env.NEOAGENT_RPC_BOUNDARY = "1"
    env.NEOAGENT_RPC_BOUNDARY_FILE = path
    env.NEOAGENT_RPC_ROOT = root
    ---@type table<string, string>|string[]
    local process_env = env
    if vim.fn.has("nvim-0.12") == 0 then
      local names = vim.tbl_keys(env)
      table.sort(names)
      process_env = vim.tbl_map(function(name)
        return name .. "=" .. env[name]
      end, names)
    end
    local completed = vim.system(argv, {
      cwd = root,
      env = process_env,
      clear_env = true,
      text = true,
    }):wait(10000)
    assert.are.equal(0, completed.code, completed.stderr)
    local encoded = assert(assert(completed.stdout):match("NEOAGENT_RPC_BOUNDARY=(%b[])"))
    assert.are.same({}, vim.json.decode(encoded))
  end)

  it("resolves worker commands across explicit, fallback, and script-mode launchers", function()
    local worker = require("neoagent.rpc.worker")
    assert.are.same({ "launcher", "nvim" }, worker.nvim_command({ "launcher", "nvim" }))

    local original_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, ...)
      if path == "/proc/self/cmdline" then
        return nil
      end
      return original_open(path, ...)
    end
    local fallback = worker.nvim_command()
    vim.uv.fs_open = original_open
    assert.are.same({ vim.v.progpath }, fallback)

    local original_version = vim.version
    local current = (original_version --[[@as fun(): vim.Version]])()
    rawset(vim, "version", setmetatable({ lt = original_version.lt }, {
      __call = function()
        return setmetatable({ major = 0, minor = 13, patch = 0 }, { __index = current })
      end,
    }))
    local argv = worker.argv({ "nvim" }, "/plugin/scripts/tool_worker.lua")
    vim.version = original_version
    assert.are.same({
      "nvim", "--headless", "--noplugin", "-u", "NONE", "-i", "NONE", "-n", "-l",
      "/plugin/scripts/tool_worker.lua",
    }, argv)

    local worker_file = worker.worker_file()
    local root = assert(vim.fs.dirname(assert(vim.fs.dirname(worker_file))))
    local bootstrap = worker.bootstrap_paths(worker_file, {})
    assert.is_true(vim.list_contains(bootstrap, worker_file))
    assert.is_true(vim.list_contains(bootstrap, vim.fs.joinpath(root, "lua", "neoagent")))
    assert.is_false(vim.list_contains(bootstrap, root))
    local found_modules, modules_err = pcall(worker.bootstrap_paths, "/missing/scripts/tool_worker.lua", {})
    assert.is_false(found_modules)
    assert.are.equal("worker_start", require("neoagent.util").normalize_error(modules_err).kind)

    local original_runtime_file = vim.api.nvim_get_runtime_file
    vim.api.nvim_get_runtime_file = function()
      return {}
    end
    local found, find_err = pcall(worker.worker_file)
    vim.api.nvim_get_runtime_file = original_runtime_file
    assert.is_false(found)
    assert.are.equal("worker_start", require("neoagent.util").normalize_error(find_err).kind)
  end)
end)
