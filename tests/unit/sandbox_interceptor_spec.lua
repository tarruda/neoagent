local assert = require("luassert")
local async = require("neoagent.async")
local composition = require("neoagent.sandbox.composition")
local fs = require("neoagent.fs")
local util = require("neoagent.util")
local Workspace = require("neoagent.workspace")
local owner_runs = {}
local original_remote = package.loaded["neoagent.rpc.connection"]

---@generic T
---@param run Neoagent.Run<T, unknown>
---@return T
local function wait(run)
  assert(vim.wait(10000, function()
    return run:is_done()
  end))
  local value = assert(run:result())
  if value.ok == false then
    error(value.error, 0)
  end
  return value --[[@as T]]
end

---@param root string
---@return Neoagent.ToolContext<{workspace: Neoagent.Workspace, files: Neoagent.Files}>
local function context(root)
  local noop = function() end
  ---@async
  ---@return Neoagent.AgentLoopResult
  local function lifetime()
    return async.await(
      ---@param _ Neoagent.AwaitCallbacks<Neoagent.AgentLoopResult>
      function(_) end)
  end
  local owner = async.run(lifetime)
  owner_runs[#owner_runs + 1] = owner
  return {
    model = require("tests.helpers.fake_model").new(),
    run = owner,
    ---@async
    execute_tool = function() error("unused recursive executor") end,
    context = {
      workspace = Workspace.new({ root = root, cwd = root }),
      files = require("neoagent.files.memory").new(),
    },
    call = { type = "toolCall", id = "call", name = "test", arguments = {} },
    on_update = noop,
  }
end

describe("neoagent sandbox Tool RPC selection", function()
  local roots = {}
  local cleanup_releases = {}
  ---@type Neoagent.WorkerLease[]
  local live_children = {}

  ---@return string
  local function temporary_root()
    local root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    root = assert(vim.uv.fs_realpath(root))
    roots[#roots + 1] = root
    return root
  end

  after_each(function()
    package.loaded["neoagent.rpc.connection"] = original_remote
    for _, run in ipairs(owner_runs) do
      run:cancel()
    end
    owner_runs = {}
    for _, path in ipairs(cleanup_releases) do
      vim.fn.writefile({ "release" }, path)
    end
    cleanup_releases = {}
    for _, active_child in ipairs(live_children) do
      pcall(active_child.dispose, active_child, "sandbox interceptor test cleanup")
    end
    for _, active_child in ipairs(live_children) do
      wait(async.run(function() return active_child:wait() end))
    end
    live_children = {}
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
    roots = {}
  end)

  ---@param behavior? table
  ---@return table, table
  local function remote(behavior)
    behavior = behavior or {}
    local state = { aborted = 0, cancelled = 0, attached = 0, closed = 0, operations = 0 }
    local value = {
      attach = function()
        state.attached = state.attached + 1
      end,
      open = behavior.open or function() end,
      request = behavior.request or function()
        state.operations = state.operations + 1
        return { content = { { type = "text", text = "remote operation" } } }
      end,
      close = behavior.close or function()
        state.closed = state.closed + 1
        return true
      end,
      abort = function()
        state.aborted = state.aborted + 1
      end,
      is_failed = function() return state.aborted > 0 end,
      cancel = behavior.cancel or function()
        state.cancelled = state.cancelled + 1
      end,
      wait_cancelled = behavior.wait_cancelled or function() return true end,
      feed = function() end,
      eof = function() end,
    }
    package.loaded["neoagent.rpc.connection"] = { new = function()
      return value
    end,
    }
    return value, state
  end

  ---@return Neoagent.Tool<unknown>
  local function restricted_tool()
    return require("neoagent.tools.write_file").new()
  end

  ---@return Neoagent.WorkerLease, table
  local function child()
    local state = { terminated = {}, waited = 0, closed = 0 }
    ---@type Neoagent.WorkerLease
    local value = {
      write = function()
        return true
      end,
      close_stdin = function()
        return true
      end,
      terminate = function(_, reason)
        state.terminated[#state.terminated + 1] = reason
      end,
      wait = function()
        state.waited = state.waited + 1
        return { code = 0, signal = 0, stderr = "" }
      end,
      dispose = function()
        state.closed = state.closed + 1
      end,
    }
    return value, state
  end

  ---@param root string
  ---@param platform Neoagent.SandboxPlatform<unknown>
  ---@param profile_source? Neoagent.SandboxProfileSource<unknown>
  ---@return Neoagent.SandboxInterceptor<unknown>
  local function interceptor(root, platform, profile_source)
    return require("neoagent.sandbox.interceptor").new({
      profile = profile_source or {
        id = "interceptor-test",
        filesystem = { default = "read", entries = { { path = root, access = "write" } } },
        network = "restricted",
        environment = { clear = true, inherit = {}, set = {} },
      },
      platform = platform,
      environ = function()
        return { PATH = vim.env.PATH or "/bin" }
      end,
      nvim = vim.env.NEOAGENT_NVIM,
    })
  end

  for _, method in ipairs({ "grep", "find" }) do
    for _, ending in ipairs({ "SIGSYS", "wrapped SIGSYS", "ordinary error", "other signal", "other platform" }) do
      it("classifies " .. ending .. " from the " .. method .. " worker process", function()
        if jit.os ~= "Linux" then
          pending("requires Linux signal policy")
          return
        end
        local root = temporary_root()
        local protocol = require("neoagent.rpc.protocol")
        local constants = (vim.uv --[[@as {constants: table<string, integer>}]]).constants
        local sigsys = assert(constants.SIGSYS)
        local signal = sigsys
        if ending == "wrapped SIGSYS" or ending == "ordinary error" then
          signal = 0
        elseif ending == "other signal" then
          signal = assert(constants.SIGTERM)
        end
        local code = ending == "ordinary error" and 2 or 128 + (ending == "wrapped SIGSYS" and sigsys or signal)
        local denied = ending == "SIGSYS" or ending == "wrapped SIGSYS"
        local execute = interceptor(root, {
          name = ending == "other platform" and "macos" or "linux",
          start_worker = function(request)
            local server = require("neoagent.rpc.server").new({
              send = function(message)
                assert(request.on_stdout)(protocol.encode(message))
              end,
              dependencies = {
                process = function()
                  return { code = code, signal = signal, stdout = "", stderr = "", output = "", timed_out = false }
                end,
              },
            })
            local decoder = protocol.decoder(function(message)
              server:receive(message)
            end)
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
              dispose = function()
                server:eof()
              end,
              wait = function()
                return { code = 0, signal = 0, stderr = "" }
              end,
            }
          end,
        }):wrap()
        local run = async.run(function()
          return execute(require("neoagent.tools." .. method).new(), { pattern = "needle" }, context(root))
        end)
        assert(vim.wait(3000, function()
          return run:is_done()
        end))
        local value = assert(run:result())
        if denied then
          assert.is_not.equal(false, value.ok, vim.inspect(value))
          assert.is_true(value.isError)
          local denial = assert(assert(value.execution).sandbox)
          assert.is_true(denial.denied)
          assert.is_true(denial.can_escalate)
          assert.is_nil(value.details)
        else
          assert.is_false(value.ok)
          assert.are.equal("tool", assert(value.error).kind)
          assert.is_nil(value.error.sandbox)
        end
      end)
    end
  end

  it("keeps documentation and plan tools entirely in the parent", function()
    local root = temporary_root()
    local starts = 0
    ---@type Neoagent.SandboxPlatform<unknown>
    local platform = {
      name = "test",
      check = function()
        return { ok = true, platform = "test", capabilities = {} }
      end,

      start_worker = function()
        starts = starts + 1
        error("parent-only tools must not start a sandbox worker")
      end,
    }
    local tools = {
      require("neoagent.tools.read_agent_documentation").new(),
      require("neoagent.tools.update_plan").new(),
    }
    local selected = composition.compose({ tools = tools }, { enabled = true }, {
      platform = platform,
      status = { ok = true, platform = "test", capabilities = {} },
    })
    assert(selected)
    local execute = assert(selected.execute_tool)
    for index, tool in ipairs(selected.tools) do
      assert.is_nil(rawget(tool, "sandbox"))
      assert.is_nil(assert(tool.input_schema.properties).options, tostring(index))
    end

    local ctx = context(root)
    local values = wait(async.run(function()
      return {
        documentation = execute(assert(selected.tools[1]), {}, ctx),
        plan = execute(assert(selected.tools[2]), {
          plan = { { step = "stay local", status = "completed" } },
        }, ctx),
      }
    end))
    assert.matches("# Neoagent API map", assert(values.documentation.content)[1].text)
    assert.are.equal("Plan updated", assert(values.plan.content)[1].text)
    assert.are.equal(0, starts)
  end)

  it("recognizes renamed parent implementations without granting same-name custom tools", function()
    local root = temporary_root()
    local documentation = require("neoagent.tools.read_agent_documentation").new()
    documentation.name = "neoagent_help"
    local custom_calls = 0
    local custom = {
      name = "read_agent_documentation", description = "Custom documentation",
      input_schema = { type = "object", properties = {} },
      execute = function()
        custom_calls = custom_calls + 1
        return { content = { { type = "text", text = "custom" } } }
      end,
    }
    local selected = composition.compose({ tools = { documentation, custom } }, { enabled = true }, {
      status = { ok = false, platform = "test", message = "isolation unavailable" },
    })
    local execute = assert(selected.execute_tool)
    local ctx = context(root)
    local values = wait(async.run(function()
      return {
        documentation = execute(assert(selected.tools[1]), {}, ctx),
        custom = execute(assert(selected.tools[2]), {}, ctx),
      }
    end))
    assert.matches("# Neoagent API map", values.documentation.content[1].text)
    assert.is_true(values.custom.isError)
    assert.are.equal(0, custom_calls)
  end)

  for _, constructor in ipairs({ "compose", "switchable" }) do
    it("keeps parent-only tools available when the sandbox is unavailable via " .. constructor, function()
      local root = temporary_root()
      local parent_calls = 0
      local parent = {
        name = "inspect", description = "Inspect parent state",
        input_schema = { type = "object", properties = {} },
        execute = function()
          parent_calls = parent_calls + 1
          return { content = { { type = "text", text = "parent state" } } }
        end,
      }
      local tools = {
        require("neoagent.tools.read_agent_documentation").new(),
        require("neoagent.tools.update_plan").new(),
        parent,
        require("neoagent.tools.write_file").new(),
      }
      local options = {
        status = {
          ok = false,
          platform = "test",
          stage = "requirements",
          message = "synthetic unavailable sandbox",
        },
      }
      local selected, status
      if constructor == "compose" then
        selected, status = composition.compose({ tools = tools }, { enabled = true, parent_tools = { parent } }, options)
      else
        selected, status = composition.switchable({ tools = tools }, { enabled = true, parent_tools = { parent } }, options)
      end
      assert.is_true(status.enabled)
      assert.is_false(status.active)
      if constructor == "compose" then
        assert.is_nil(selected.system_prompt, "inactive isolation must not advertise sandboxed execution")
      else
        assert.matches("Sandbox controls", assert(selected.system_prompt))
      end
      local execute = assert(selected.execute_tool)
      local ctx = context(root)
      local values = wait(async.run(function()
        return {
          documentation = execute(assert(selected.tools[1]), {}, ctx),
          plan = execute(assert(selected.tools[2]), {
            plan = { { step = "remain local", status = "completed" } },
          }, ctx),
          parent = execute(assert(selected.tools[3]), {}, ctx),
          restricted = execute(assert(selected.tools[4]), { path = "blocked.txt", content = "blocked" }, ctx),
        }
      end))
      assert.matches("# Neoagent API map", assert(values.documentation.content)[1].text)
      assert.are.equal("Plan updated", assert(values.plan.content)[1].text)
      assert.are.equal("parent state", values.parent.content[1].text)
      assert.are.equal(1, parent_calls)
      assert.is_true(values.restricted.isError)
      assert.is_true(values.restricted.execution.sandbox.unavailable)
      assert.is_nil(vim.uv.fs_stat(root .. "/blocked.txt"))
    end)
  end

  for _, name in ipairs({ "grep", "find" }) do
    it("preserves " .. name .. " denial evidence beyond the retained error text", function()
      local root = temporary_root()
      local platform = {
        name = "test",
        start_worker = function(request)
          local protocol = require("neoagent.rpc.protocol")
          local server = require("neoagent.rpc.server").new({
            send = function(message)
              request.on_stdout(protocol.encode(message))
            end,
            dependencies = {
              process = function(_, opts)
                local emit = assert(assert(opts).on_output)
                emit(string.rep("ordinary diagnostic\n", 200), true, "", "", "")
                emit("permission ", true, "", "", "")
                emit("denied: synthetic private path\n", true, "", "", "")
                return { code = 2, signal = 0, stdout = "", stderr = "", output = "", timed_out = false }
              end,
            },
          })
          local decoder = protocol.decoder(function(message)
            server:receive(message)
          end)
          local result = { code = 0, signal = 0, stderr = "" }
          return {
            write = function(_, bytes)
              decoder:feed(bytes)
              return true
            end,
            close_stdin = function()
              request.on_exit(result)
              return true
            end,
            wait = function()
              return result
            end,
            dispose = function()
              server:eof()
            end,
            terminate = function()
              server:eof()
            end,
          }
        end,
      }
      local execute = interceptor(root, platform):wrap()
      local completed = wait(async.run(function()
        local ok, result = pcall(execute, require("neoagent.tools." .. name).new(), {
          pattern = name == "grep" and "needle" or "*",
        }, context(root))
        return { executed = ok, value = result }
      end))
      assert.is_true(completed.executed, vim.inspect(completed.value))
      local value = completed.value
      assert.is_true(value.isError)
      assert.is_true(value.execution.sandbox.denied)
      assert.matches("blocked by the sandbox", value.content[1].text, 1, true)
      assert.is_nil(vim.inspect(value):find("synthetic private path", 1, true))
    end)
  end

  it("lets executor decorators wrap sandboxed streaming updates", function()
    local root = temporary_root()
    local active_child = child()
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function() return active_child end,
    }
    remote({
      request = function(_, _, _, handlers)
        assert(handlers).on_event({
          name = require("neoagent.rpc.codec").events.update,
          value = { content = { { type = "text", text = "streaming" } } },
        })
        return { content = { { type = "text", text = "complete" } } }
      end,
    })
    local logged = 0
    local published = 0
    local execute = interceptor(root, platform):wrap(function(tool, arguments, ctx)
      local decorated = vim.tbl_extend("force", {}, ctx)
      decorated.on_update = function(update)
        logged = logged + 1
        ctx.on_update(update)
      end
      return tool.execute(arguments, decorated)
    end)
    local active_context = context(root)
    active_context.on_update = function()
      published = published + 1
    end

    local value = wait(async.run(function()
      return execute(restricted_tool(), {
        path = "decorated.txt",
        content = "value",
      }, active_context)
    end))

    assert.are.equal("complete", assert(value.content)[1].text)
    assert.are.equal(1, logged)
    assert.are.equal(1, published)
  end)

  it("lets executor policy short-circuit before starting a worker", function()
    local root = temporary_root()
    local starts = 0
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function()
        starts = starts + 1
        error("short-circuited policy must not start a worker")
      end,
    }
    local execute = interceptor(root, platform):wrap(function()
      return {
        content = { { type = "text", text = "denied by configured policy" } },
        isError = true,
      }
    end)

    local value = wait(async.run(function()
      return execute(restricted_tool(), {
        path = "policy.txt",
        content = "must not run",
      }, context(root))
    end))

    assert.are.equal("denied by configured policy", assert(value.content)[1].text)
    assert.are.equal(0, starts)

    execute = interceptor(root, platform):wrap(function()
      error(util.error("tool", "configured executor failed"), 0)
    end)
    local failed = async.run(function()
      return execute(restricted_tool(), {
        path = "policy.txt",
        content = "must not run",
      }, context(root))
    end)
    assert(vim.wait(1000, function() return failed:is_done() end))
    local failed_value = assert(failed:result())
    assert.is_false(failed_value.ok)
    assert.are.equal("configured executor failed", assert(failed_value.error).message)
    assert.are.equal(0, starts)
  end)

  it("opens a remote worker only for a sandbox-eligible tool", function()
    local root = temporary_root()
    local starts = 0
    ---@type Neoagent.SandboxPlatform<unknown>
    local platform = {
      name = "test",
      check = function()
        return { ok = true, platform = "test", capabilities = {} }
      end,

      start_worker = function(request, services)
        starts = starts + 1
        return assert(services.start_worker)(request)
      end,
    }
    local tool = require("neoagent.tools.write_file").new()
    local selected = composition.compose({ tools = { tool } }, { enabled = true }, {
      platform = platform,
      status = { ok = true, platform = "test", capabilities = {} },
      start_worker = require("neoagent.rpc.worker_lease").start,
      nvim = vim.env.NEOAGENT_NVIM,
    })
    assert(selected)
    local execute = assert(selected.execute_tool)
    local value = wait(async.run(function()
      return execute(assert(selected.tools[1]), {
        path = "remote.txt",
        content = "remote\n",
      }, context(root))
    end))
    assert.is_nil(value.isError)
    assert.are.equal("remote\n", assert(fs.read(root .. "/remote.txt")))
    assert.are.equal(1, starts)
  end)

  it("rejects unregistered restricted tools before resolving a profile or starting a worker", function()
    local root = temporary_root()
    local profiles = 0
    local starts = 0
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function()
        starts = starts + 1
        error("unregistered tools must not start a worker")
      end,
    }
    local execute = interceptor(root, platform, function()
      profiles = profiles + 1
      error("unregistered tools must not resolve a sandbox profile")
    end):wrap(function()
      error("unregistered tools must not execute on the host")
    end)
    local value = wait(async.run(function()
      return execute({
        name = "custom",
        description = "custom restricted Tool",
        input_schema = { type = "object", properties = {} },
        execute = function() error("unregistered Tool implementation ran") end,
      }, {}, context(root))
    end))
    assert.is_true(value.isError)
    assert.matches("unavailable for this Tool", assert(value.content)[1].text)
    assert.are.equal("unsupported_tool", assert(value.execution).sandbox.kind)
    assert.are.equal(0, profiles)
    assert.are.equal(0, starts)
  end)

  it("waits for platform admission before starting the worker handshake", function()
    local root = temporary_root()
    local active_child = child()
    ---@type Neoagent.AwaitCallbacks<true>?
    local admission
    active_child.wait_ready = function()
      return async.await(function(done)
        admission = done
      end)
    end
    local opened = false
    remote({
      open = function()
        opened = true
      end,
    })
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function() return active_child end,
    }
    local execute = interceptor(root, platform):wrap(function(tool, arguments, ctx)
      tool.execute(arguments, ctx)
      return { content = { { type = "text", text = "done" } } }
    end)
    local run = async.run(function()
      return execute(restricted_tool(), { path = "admission.txt", content = "value" }, context(root))
    end)
    assert(vim.wait(1000, function() return admission ~= nil end))
    assert.is_false(opened)
    assert(admission).resolve(true)
    local value = wait(run)
    assert.are.equal("done", value.content[1].text)
    assert.is_true(opened)
  end)

  it("contains platform admission failures and detached cleanup failures", function()
    local root = temporary_root()
    local active_child, child_state = child()
    active_child.wait_ready = function()
      error(util.error("sandbox_unavailable", "native admission failed"), 0)
    end
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function() return active_child end,
    }
    local _, failed_remote = remote()
    local execute = interceptor(root, platform):wrap()
    local value = wait(async.run(function()
      return execute(restricted_tool(), { path = "admission.txt", content = "value" }, context(root))
    end))
    assert.matches("native admission failed", assert(value.content)[1].text)
    assert.is_true(assert(value.execution).sandbox.unavailable)
    assert.are.equal(1, failed_remote.aborted)
    assert.are.equal(1, child_state.closed)
    assert.are.equal(1, child_state.waited)

    active_child, child_state = child()
    active_child.wait_ready = function()
      error(util.error("cancelled", "native admission cancelled"), 0)
    end
    active_child.wait = function()
      child_state.waited = child_state.waited + 1
      error("detached wait failed")
    end
    local _, cancelled_remote = remote({
      cancel = function()
        error("cancel dispatch failed")
      end,
    })
    execute = interceptor(root, platform):wrap()
    local cancelled = async.run(function()
      return execute(restricted_tool(), { path = "admission.txt", content = "value" }, context(root))
    end)
    assert(vim.wait(1000, function() return cancelled:is_done() end))
    local cancelled_result = assert(cancelled:result())
    assert.is_false(cancelled_result.ok)
    assert.are.equal("cancelled", assert(cancelled_result.error).kind)
    assert(vim.wait(1000, function() return child_state.closed == 1 end))
    assert.are.equal(1, child_state.waited)
    assert.are.equal(1, cancelled_remote.aborted)
  end)

  it("preserves bounded worker startup diagnostics in sandbox results", function()
    local root = temporary_root()
    local active_child, child_state = child()
    local denied_worker = vim.fs.joinpath(root, "denied-worker.lua")
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function(request)
        request.on_exit({
          code = 126,
          signal = 0,
          stderr = "sandbox launcher denied " .. denied_worker,
        })
        return active_child
      end,
    }
    local execute = interceptor(root, platform):wrap()

    local value = wait(async.run(function()
      return execute(restricted_tool(), {
        path = "diagnostic.txt",
        content = "blocked",
      }, context(root))
    end))

    assert.is_true(value.isError)
    assert.matches("exited with status 126", value.content[1].text, 1, true)
    assert.matches("Worker diagnostic: sandbox launcher denied", value.content[1].text, 1, true)
    assert.matches(denied_worker, value.content[1].text, 1, true)
    assert.is_true(assert(assert(value.execution).sandbox).unavailable)
    assert.are.equal(1, child_state.closed)
    assert.are.equal(1, child_state.waited)
  end)

  it("rejects explicitly denied typed paths before remote dispatch", function()
    local root = temporary_root()
    local denied = vim.fs.joinpath(root, "denied")
    assert(fs.mkdirp(denied))
    local active_child, child_state = child()
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function() return active_child end,
    }
    local _, remote_state = remote()
    local execute = interceptor(root, platform, {
      id = "denied-path",
      filesystem = {
        default = "read",
        entries = {
          { path = root, access = "write" },
          { path = denied, access = "deny" },
        },
      },
      network = "restricted",
      environment = { clear = true, inherit = {}, set = {} },
    }):wrap()
    local tool = require("neoagent.tools.write_file").new()

    local value = wait(async.run(function()
      return execute(tool, {
        path = "denied/private.txt",
        content = "blocked",
      }, context(root))
    end))

    assert.is_true(value.isError)
    assert.matches("Write access is denied", value.content[1].text, 1, true)
    assert.matches("require_escalation", value.content[1].text, 1, true)
    local failure = assert(assert(value.execution).sandbox)
    assert.is_true(failure.denied)
    assert.is_nil(failure.ran_restricted)
    assert.are.equal("filesystem.write", failure.operation)
    assert.are.equal(vim.fs.joinpath(denied, "private.txt"), failure.path)
    assert.are.equal("deny", failure.granted)
    assert.are.equal(0, remote_state.operations)
    assert.are.equal(0, remote_state.closed)
    assert.are.equal(0, child_state.waited)
    assert.are.equal(0, child_state.closed)
    assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(denied, "private.txt")))
  end)

  it("blocks a restricted call before child creation when worker preparation fails", function()
    local root = temporary_root()
    local starts = 0
    ---@type Neoagent.SandboxPlatform<unknown>
    local platform = {
      name = "test",
      check = function()
        return { ok = true, platform = "test", capabilities = {} }
      end,

      start_worker = function()
        starts = starts + 1
        error("worker preparation must fail first")
      end,
    }
    local selected = assert(composition.compose({
      tools = { require("neoagent.tools.write_file").new() },
    }, { enabled = true }, {
      platform = platform,
      status = { ok = true, platform = "test", capabilities = {} },
      environ = function()
        error("synthetic environment failure")
      end,
    }))
    local value = wait(async.run(function()
      return assert(selected.execute_tool)(assert(selected.tools[1]), {
        path = "blocked.txt",
        content = "must not be written",
      }, context(root))
    end))
    assert.is_true(value.isError)
    local failure = assert(assert(value.execution).sandbox)
    assert.is_true(failure.unavailable)
    assert.are.equal("worker_start", failure.kind)
    assert.are.equal(0, starts)
    assert.is_nil(fs.read(root .. "/blocked.txt"))
  end)

  it("filters inherited state in the launched worker environment", function()
    local root = temporary_root()
    local base_paths = require("neoagent.sandbox.path").posix
    ---@type Neoagent.SandboxPaths
    local case_insensitive_paths = {
      name = base_paths.name,
      normalize = base_paths.normalize,
      is_absolute = base_paths.is_absolute,
      root = base_paths.root,
      key = base_paths.key,
      contains = base_paths.contains,
      depth = base_paths.depth,
      dirname = base_paths.dirname,
      basename = base_paths.basename,
      join = base_paths.join,
      canonical_candidate = base_paths.canonical_candidate,
      realpath = function(value) return value end,
      stat = function() return nil end,
      environment_key = function(value) return value:lower() end,
      validate_component = base_paths.validate_component,
    }
    local configured = {
      id = "environment",
      filesystem = { default = "read", entries = {} },
      network = "restricted",
      environment = {
        clear = false,
        inherit = { "mixed", "ONLY", "GITHUB_TOKEN" },
        set = {
          Mixed = "configured",
          SAFE = "yes",
          API_TOKEN = "configured-token",
          SSH_AUTH_SOCK = "/configured/agent.sock",
        },
      },
    }
    local ambient = {
      PATH = "/bin",
      Mixed = "first",
      MIXED = "second",
      ONLY = "inherited",
      MONKEY = "ordinary",
      GITHUB_TOKEN = "inherited-token",
      OPENAI_API_KEY = "secret",
      USER_PASSWORD = "secret",
    }
    local environment = {}
    local active_child = child()
    remote()
    local selected = require("neoagent.sandbox.interceptor").new({
      profile = configured,
      paths = case_insensitive_paths,
      environ = function() return ambient end,
      nvim = vim.env.NEOAGENT_NVIM,
      platform = {
        name = "test",
        check = function() return { ok = true, platform = "test", capabilities = {} } end,
        start_worker = function(request)
          environment = request.env
          return active_child
        end,
      },
    })
    local value = wait(async.run(function()
      return selected:wrap()(require("neoagent.tools.read_file").new(), { path = "file" }, context(root))
    end))
    assert.are.equal("remote operation", value.content[1].text)
    assert.are.equal("configured", environment.mixed)
    assert.are.equal("inherited", environment.ONLY)
    assert.are.equal("yes", environment.SAFE)
    assert.are.equal("ordinary", environment.MONKEY)
    assert.are.equal("inherited-token", environment.GITHUB_TOKEN)
    assert.are.equal("configured-token", environment.API_TOKEN)
    assert.are.equal("/configured/agent.sock", environment.SSH_AUTH_SOCK)
    assert.is_nil(environment.MIXED)
    assert.is_nil(environment.Mixed)
    assert.is_nil(environment.OPENAI_API_KEY)
    assert.is_nil(environment.USER_PASSWORD)
  end)

  it("resolves fixed compiled profiles only for registered restricted tools", function()
    local root = temporary_root()
    local compiled = 0
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,

      compile = function(value)
        compiled = compiled + 1
        value.id = "compiled"
        return value
      end,
      start_worker = function() error("must not start for a parent-only Tool") end,
    }
    local selected = interceptor(root, platform)
    local executed = selected:wrap()
    local self_granting = {
      name = "local",
      execute = function()
        return { content = { { type = "text", text = "local" } } }
      end,
    }
    rawset(self_granting, "sandbox", false)
    local value = wait(async.run(function()
      return executed(self_granting, {}, context(root))
    end))
    assert.is_true(value.isError)
    assert.matches("unavailable", value.content[1].text:lower())
    assert.are.equal(0, compiled)

    local active_child = child()
    platform.start_worker = function()
      return active_child
    end
    remote()
    value = wait(async.run(function()
      return executed(restricted_tool(), { path = "file", content = "value" }, context(root))
    end))
    assert.are.equal("remote operation", value.content[1].text)
    assert.are.equal(1, compiled)
  end)

  it("contains profile, context, and native child setup failures without host fallback", function()
    local root = temporary_root()
    local function platform(start_worker)
      return {
        name = "test",
        check = function() return { ok = true, platform = "test", capabilities = {} } end,
        start_worker = start_worker,
      }
    end
    local tool = restricted_tool()

    local profile_failure = interceptor(root, platform(function() error("must not start") end), function()
      error("profile exploded")
    end):wrap()
    local value = wait(async.run(function()
      return profile_failure(tool, {}, context(root))
    end))
    assert.is_true(assert(value.execution).sandbox.unavailable)
    assert.matches("profile exploded", value.content[1].text)

    local context_failure = interceptor(root, platform(function() error("must not start") end)):wrap()
    value = wait(async.run(function()
      return context_failure(tool, {}, { context = {} })
    end))
    assert.is_true(assert(value.execution).sandbox.unavailable)
    assert.matches("workspace", value.content[1].text)

    local child_failure = interceptor(root, platform(function()
      error("native launch exploded")
    end)):wrap()
    value = wait(async.run(function()
      return child_failure(tool, { path = "child.txt", content = "value" }, context(root))
    end))
    assert.is_true(assert(value.execution).sandbox.unavailable)
    assert.matches("native launch exploded", value.content[1].text)

    local invalid_child = interceptor(root, platform(function()
      return {}
    end)):wrap()
    value = wait(async.run(function()
      return invalid_child(tool, { path = "child.txt", content = "value" }, context(root))
    end))
    assert.is_true(assert(value.execution).sandbox.unavailable)
    assert.matches("invalid worker lease", value.content[1].text)
  end)

  it("reaps failed worker leases and classifies open and close failures", function()
    local root = temporary_root()
    local active_child, child_state = child()
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function() return active_child end,
    }
    local _, remote_state = remote({ open = function()
      error(util.error("worker_start", "handshake failed"), 0)
    end,
    })
    local execute = interceptor(root, platform):wrap()
    local value = wait(async.run(function()
      return execute(restricted_tool(), { path = "open.txt", content = "value" }, context(root))
    end))
    assert.is_true(assert(value.execution).sandbox.unavailable)
    assert.matches("handshake failed", value.content[1].text)
    assert.are.equal(1, remote_state.aborted)
    assert.are.equal(1, child_state.waited)
    assert.are.equal(1, child_state.closed)

    active_child, child_state = child()
    platform.start_worker = function() return active_child end
    _, remote_state = remote({ open = function()
      error(util.error("worker_start", "direct handshake failed"), 0)
    end,
    })
    value = interceptor(root, platform):wrap()(restricted_tool(), {
      path = "open.txt", content = "value",
    }, context(root))
    assert.is_true(assert(value.execution).sandbox.unavailable)
    assert.are.equal(1, child_state.waited)
    assert.are.equal(1, child_state.closed)

    active_child, child_state = child()
    platform.start_worker = function() return active_child end
    _, remote_state = remote({ close = function()
      error(util.error("protocol", "shutdown failed"), 0)
    end,
    })
    execute = interceptor(root, platform):wrap(function(tool, arguments, ctx)
      tool.execute(arguments, ctx)
      return {
        content = { { type = "text", text = "done" } },
        details = { changed_paths = { "written.txt" } },
      }
    end)
    value = wait(async.run(function()
      return execute(restricted_tool(), { path = "close.txt", content = "value" }, context(root))
    end))
    assert.is_nil(value.isError)
    assert.are.equal("done", assert(value.content[1]).text)
    assert.matches("cleanup failed", assert(value.content[2]).text:lower(), 1, true)
    assert.are.same({ "written.txt" }, assert(value.details).changed_paths)
    local cleanup = assert(assert(value.execution).sandbox)
    assert.is_true(cleanup.cleanup_failed)
    assert.is_true(cleanup.unavailable)
    assert.is_true(cleanup.ran_restricted)
    assert.are.equal(1, remote_state.aborted)
    assert.are.equal(1, child_state.waited)

  end)

  it("retains failed-startup cleanup when its waiting Run is cancelled", function()
    local root = temporary_root()
    local lease, state = child()
    local waiters = {}
    local reaped = false
    lease.wait = function()
      state.waited = state.waited + 1
      local value = async.await(function(done)
        waiters[done] = true
        return function() waiters[done] = nil end
      end)
      reaped = true
      return value
    end
    remote({ open = function()
      error(util.error("worker_start", "handshake failed"), 0)
    end,
    })
    local execute = interceptor(root, {
      name = "test", start_worker = function() return lease end,
    }):wrap()
    local run = async.run(function()
      return execute(restricted_tool(), { path = "file", content = "value" }, context(root))
    end)
    local checked, check_err = pcall(function()
      assert(vim.wait(1000, function() return state.waited == 1 end))
      run:cancel()
      assert(vim.wait(1000, function() return run:is_done() and state.waited == 2 end))
      assert.are.equal(1, state.closed)
      assert.is_false(reaped)
    end)
    run:cancel()
    for waiter in pairs(waiters) do
      waiter.resolve({ code = 137, signal = 9, stderr = "" })
    end
    assert(vim.wait(1000, function() return reaped end))
    assert.are.equal(1, state.closed)
    assert.is_true(checked, tostring(check_err))
  end)

  it("distinguishes unverified mutations from acknowledged worker denials", function()
    package.loaded["neoagent.rpc.connection"] = original_remote
    local protocol = require("neoagent.rpc.protocol")
    local framing = require("neoagent.ipc.framing")
    local root = temporary_root()
    for _, corruption in ipairs({ "frame", "sequence", "result", "artifact", "denial" }) do
      local active_child, child_state = child()
      ---@type Neoagent.ToolDependencyOverrides
      local dependencies = {}
      if corruption == "denial" then
        assert(fs.write_all(root .. "/denial.txt", "original content"))
        dependencies.fs = util.copy(fs)
        dependencies.fs.atomic_replace = function() return nil, "EACCES: permission denied" end
      end
      ---@type Neoagent.SandboxPlatform<unknown>
      local platform = {
        name = "test",
        ---@param request Neoagent.SandboxWorkerRequest
        start_worker = function(request)
          local output = request.on_stdout
          assert(output)
          local server = require("neoagent.rpc.server").new({
            dependencies = dependencies,
            send = function(message)
              if message.type == "response" then
                if corruption == "frame" then
                  output("\0\0\0\1\255")
                  return
                elseif corruption == "sequence" then
                  output(protocol.encode({
                    type = "event", call_id = message.call_id,
                    request_id = message.request_id, sequence = 2,
                    name = "tool_update", value = { content = {} },
                  }))
                  return
                end
                message.value = corruption == "artifact" and {
                  content = { {
                    type = "image", file_id = string.rep("a", 64),
                    bytes = 1, mime_type = "image/png",
                  },
                      },
                } or {}
              end
              output(framing.encode(message))
            end,
          })
          local decoder = protocol.decoder(function(message)
            server:receive(message)
          end)
          active_child.write = function(_, bytes)
            decoder:feed(bytes)
            return true
          end
          return active_child
        end,
      }
      local execute = interceptor(root, platform):wrap()
      local value = wait(async.run(function()
        return execute(restricted_tool(), {
          path = corruption .. ".txt", content = "committed mutation",
        }, context(root))
      end))
      assert.is_true(value.isError)
      local failure = assert(assert(value.execution).sandbox)
      if corruption == "denial" then
        assert.are.equal("original content", assert(fs.read(root .. "/denial.txt")))
        assert.is_true(failure.denied)
        assert.is_true(failure.can_escalate)
        assert.is_nil(failure.outcome_uncertain)
        assert.are.equal(0, child_state.closed)
      else
        assert.are.equal("committed mutation", assert(fs.read(root .. "/" .. corruption .. ".txt")))
        assert.is_true(failure.outcome_uncertain, corruption)
        assert.are.equal(corruption == "artifact" and "artifact" or "protocol", failure.cause_kind)
        assert.is_nil(failure.can_escalate)
        assert.matches("not retried", value.content[1].text)
        assert.are.equal(1, child_state.closed)
      end
      assert.are.equal(1, child_state.waited)
    end
  end)

  it("keeps read-only RPC failures separate from uncertain mutations", function()
    local root = temporary_root()
    for _, name in ipairs({ "read_file", "grep", "find" }) do
      for _, kind in ipairs({ "protocol", "artifact" }) do
        local active_child, state = child()
        local platform = {
          name = "test", start_worker = function() return active_child end,
        }
        remote({ request = function()
          error(util.error(kind, "unusable worker response"), 0)
        end })
        local execute = interceptor(root, platform):wrap()
        local value = wait(async.run(function()
          return execute(require("neoagent.tools." .. name).new(), {
            path = "file", pattern = "needle",
          }, context(root))
        end))
        assert.is_true(value.isError)
        local failure = assert(value.execution).sandbox
        assert.are.equal(kind, failure.kind)
        assert.is_nil(failure.outcome_uncertain)
        assert.is_nil(value.content[1].text:find("effects may be incomplete", 1, true))
        assert.are.equal(1, state.waited)
      end
    end
  end)

  it("keeps cleanup diagnostics separate from operation denial evidence", function()
    local root = temporary_root()
    local active_child = child()
    remote({
      request = function()
        return {
          isError = true,
          content = { { type = "text", text = "ordinary command failed" } },
          details = { exit_code = 1 },
        }
      end,
      close = function()
        error(util.error("protocol", "shutdown failed"), 0)
      end,
    })
    local execute = interceptor(root, {
      name = "test", start_worker = function() return active_child end,
    }):wrap()
    local value = wait(async.run(function()
      return execute(require("neoagent.tools.shell").new(), { command = "exit 1" }, context(root))
    end))
    assert.is_true(value.isError)
    assert.are.equal("ordinary command failed", value.content[1].text)
    assert.matches("Sandbox cleanup failed", value.content[2].text, 1, true)
    assert.is_true(assert(assert(value.execution).sandbox).cleanup_failed)
    assert.are.equal(1, assert(value.details).exit_code)
  end)

  it("retains and disposes a worker when post-close waiting is cancelled", function()
    local root = temporary_root()
    local state = {
      completed = 0,
      disposed = 0,
      result = nil,
      waited = 0,
      waiters = {},
    }
    ---@type Neoagent.WorkerLease
    local lease = {
      write = function() return true end,
      close_stdin = function() return true end,
      terminate = function() end,
      wait = function()
        state.waited = state.waited + 1
        if state.result then
          return state.result
        end
        return async.await(function(done)
          state.waiters[#state.waiters + 1] = done
          return function()
            for index, waiter in ipairs(state.waiters) do
              if waiter == done then
                table.remove(state.waiters, index)
                break
              end
            end
          end
        end)
      end,
      dispose = function()
        state.disposed = state.disposed + 1
        if state.result then
          return
        end
        state.completed = state.completed + 1
        state.result = { code = 137, signal = 9, stderr = "" }
        local waiters = state.waiters
        state.waiters = {}
        for _, waiter in ipairs(waiters) do
          waiter.resolve(state.result)
        end
      end,
    }
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function() return lease end,
    }
    remote()

    local original_new_timer = vim.uv.new_timer
    ---@class Neoagent.TestDeferredTimer
    ---@field closed boolean
    ---@field timeout? integer
    ---@field callback? fun()
    ---@field start fun(self: Neoagent.TestDeferredTimer, timeout: integer, repeat_interval: integer, callback: fun())
    ---@field stop fun(self: Neoagent.TestDeferredTimer)
    ---@field close fun(self: Neoagent.TestDeferredTimer)
    ---@field is_closing fun(self: Neoagent.TestDeferredTimer): boolean
    ---@type Neoagent.TestDeferredTimer[]
    local timers = {}
    vim.uv.new_timer = function()
      ---@type Neoagent.TestDeferredTimer
      local timer = {
        closed = false,
        start = function(self, timeout, _, callback)
          self.timeout = timeout
          self.callback = callback
        end,
        stop = function() end,
        close = function(self)
          self.closed = true
        end,
        is_closing = function(self)
          return self.closed
        end,
      }
      timers[#timers + 1] = timer
      return timer --[[@as uv.uv_timer_t]]
    end

    local ok, err = pcall(function()
      local execute = interceptor(root, platform):wrap(function(tool, arguments, ctx)
        tool.execute(arguments, ctx)
        return { content = { { type = "text", text = "complete" } } }
      end)
      local completions = 0
      local run = async.run(function()
        return execute(restricted_tool(), { path = "wait.txt", content = "value" }, context(root))
      end, {
        on_done = function()
          completions = completions + 1
        end,
      })
      assert(vim.wait(1000, function() return state.waited == 1 end))
      run:cancel()
      assert(vim.wait(1000, function() return run:is_done() and state.waited == 2 end))
      local value = wait(run)
      assert.matches("complete", assert(value.content)[1].text, 1, true)
      assert(vim.wait(1000, function() return completions == 1 end))
      local cleanup_timers = vim.tbl_filter(function(timer)
        return timer.timeout == 10000 and not timer.closed
      end, timers)
      assert.are.equal(1, #cleanup_timers)
      local callback = assert(assert(cleanup_timers[1]).callback)
      callback()
      callback()
      assert(vim.wait(1000, function() return #state.waiters == 0 end))
      assert.are.equal(1, state.disposed)
      assert.are.equal(1, state.completed)
      assert.are.equal(2, state.waited)
      assert.are.equal(1, completions)
    end)
    vim.uv.new_timer = original_new_timer
    assert.is_true(ok, tostring(err))
  end)

  for _, fail_channel in ipairs({ false, true }) do
    it("bounds acknowledged artifact imports after deadline expiry with channel failure=" .. tostring(fail_channel), function()
      package.loaded["neoagent.rpc.connection"] = original_remote
      local root = temporary_root()
      local protocol = require("neoagent.rpc.protocol")
      local codec = require("neoagent.rpc.codec")
      local data = "synthetic attachment"
      local file = { file_id = vim.fn.sha256(data), bytes = #data }
      ---@type Neoagent.AwaitCallbacks<Neoagent.LocalFile>?
      local publication
      ---@type fun(string)?
      local feed
      ---@type fun()?
      local expire
      local disposed, cancelled, updates = 0, false, 0
      local original_new_timer = vim.uv.new_timer
      vim.uv.new_timer = function()
        local timer = assert(original_new_timer())
        return {
          start = function(_, milliseconds, interval, callback)
            if milliseconds == 30000 then expire = callback end
            return timer:start(milliseconds, interval, callback)
          end,
          stop = function() return timer:stop() end,
          close = function() return timer:close() end,
          is_closing = function() return timer:is_closing() end,
        } --[[@as uv.uv_timer_t]]
      end
      local execute = interceptor(root, {
        name = "test",
        start_worker = function(request)
          feed = assert(request.on_stdout)
          local function emit(message) assert(feed)(protocol.encode(message)) end
          emit({ type = "ready", marker = protocol.MARKER })
          local decoder = protocol.decoder(function(message)
            if message.type == "open" then
              emit({ type = "opened", call_id = message.call_id })
            elseif message.type == "request" then
              local events = {
                { name = codec.events.artifact_begin,
                  value = { artifact_id = 1, file_id = file.file_id, bytes = file.bytes } },
                { name = codec.events.artifact_chunk, value = { artifact_id = 1, data = data } },
                { name = codec.events.artifact_end, value = { artifact_id = 1 } },
              }
              for sequence, event in ipairs(events) do
                emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
                  sequence = sequence, name = event.name, value = event.value })
              end
              emit({ type = "response", call_id = message.call_id, request_id = message.request_id,
                value = codec.result({ content = { {
                  type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png",
                } } }) })
            end
          end)
          return {
            write = function(_, bytes) decoder:feed(bytes) return true end,
            close_stdin = function() return true end,
            terminate = function() end,
            wait = function() return { code = 137, signal = 9, stderr = "" } end,
            dispose = function() disposed = disposed + 1 end,
          }
        end,
      }):wrap()
      local ctx = context(root)
      assert(ctx.context).files.put = function()
        return async.await(function(done)
          publication = done
          return function() cancelled = true end
        end)
      end
      ctx.on_update = function() updates = updates + 1 end
      local run = async.run(function()
        return execute(require("neoagent.tools.read_file").new(), { path = "image.png" }, ctx)
      end)
      owner_runs[#owner_runs + 1] = run
      local checked, failure = pcall(function()
        assert(vim.wait(1000, function() return publication ~= nil end, 5))
        if fail_channel then assert(feed)("\0\0\0\0") end
        assert(expire)()
        assert(vim.wait(1000, function() return run:is_done() end, 5), "filesystem deadline left import pending")
        local value = assert(run:result())
        assert.is_true(value.isError, vim.inspect(value))
        assert.are.equal("tool_timeout", assert(value.execution).sandbox.kind)
        assert.is_true(value.execution.sandbox.timed_out)
        assert.is_true(cancelled)
        assert.is_false(run:is_cancelled(), "deadline cancelled the calling Run")
        assert.is_false(assert(publication).resolve(file), "late artifact import was accepted")
        assert.are.equal(0, updates)
        assert.are.equal(1, disposed)
        for _, block in ipairs(value.content) do assert.are_not.equal("image", block.type) end
      end)
      vim.uv.new_timer = original_new_timer
      run:cancel()
      assert(vim.wait(1000, function() return run:is_done() end, 5))
      assert.is_true(checked, tostring(failure))
    end)
  end

  it("disposes a failed channel's lease while acknowledged artifacts are still being validated", function()
    local root = temporary_root()
    local protocol = require("neoagent.rpc.protocol")
    local codec = require("neoagent.rpc.codec")
    local data = "synthetic attachment"
    local file = { file_id = vim.fn.sha256(data), bytes = #data }
    ---@type Neoagent.AwaitCallbacks<Neoagent.LocalFile>?
    local publication
    ---@type fun(data: string)?
    local feed
    local disposed, updates = 0, 0
    local execute = interceptor(root, {
      name = "test",
      start_worker = function(request)
        feed = assert(request.on_stdout)
        local function emit(message) assert(feed)(protocol.encode(message)) end
        emit({ type = "ready", marker = protocol.MARKER })
        local decoder = protocol.decoder(function(message)
          if message.type == "open" then
            emit({ type = "opened", call_id = message.call_id })
          elseif message.type == "close" then
            emit({ type = "closed", call_id = message.call_id })
          elseif message.type == "request" then
            local events = {
              { name = codec.events.artifact_begin,
                value = { artifact_id = 1, file_id = file.file_id, bytes = file.bytes } },
              { name = codec.events.artifact_chunk, value = { artifact_id = 1, data = data } },
              { name = codec.events.artifact_end, value = { artifact_id = 1 } },
              { name = codec.events.update, value = { content = { { type = "text", text = "ready" } } } },
            }
            for sequence, event in ipairs(events) do
              emit({ type = "event", call_id = message.call_id, request_id = message.request_id,
                sequence = sequence, name = event.name, value = event.value })
            end
            emit({ type = "response", call_id = message.call_id, request_id = message.request_id,
              value = codec.result({ content = { {
                type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png",
              } } }),
            })
          end
        end)
        return {
          write = function(_, bytes) decoder:feed(bytes) return true end,
          close_stdin = function() return true end,
          terminate = function() end,
          wait = function() return { code = 137, signal = 9, stderr = "" } end,
          dispose = function() disposed = disposed + 1 end,
        }
      end,
    }):wrap()
    local ctx = context(root)
    local composition_context = assert(ctx.context)
    composition_context.files.put = function()
      return async.await(function(done)
        publication = done
        return function() end
      end)
    end
    ctx.on_update = function() updates = updates + 1 end
    local run = async.run(function()
      return execute(require("neoagent.tools.read_file").new(), { path = "image.png" }, ctx)
    end)
    owner_runs[#owner_runs + 1] = run
    assert(vim.wait(1000, function() return publication ~= nil end, 5))
    assert(feed)("\0\0\0\0")
    assert.are.equal(1, disposed, "channel failure did not release its native lease")
    assert.is_false(run:is_done(), "result escaped before artifact verification")
    assert.is_true(assert(publication).resolve(file))
    local result = wait(run)
    assert.are.equal(file.file_id, result.content[1].file_id)
    assert.is_true(result.execution.sandbox.cleanup_failed)
    assert.are.equal(0, updates)
    assert.are.equal(1, disposed, "worker lease was disposed twice")
  end)

  it("retains a completed mutation when the worker exits before cleanup", function()
    local root = temporary_root()
    package.loaded["neoagent.rpc.connection"] = original_remote
    ---@type Neoagent.SandboxPlatform<unknown>
    local platform = {
      name = "test",
      check = function()
        return { ok = true, platform = "test", capabilities = {} }
      end,

      start_worker = function(request)
        local protocol = require("neoagent.rpc.protocol")
        local child_result = { code = 0, signal = 0, stderr = "" }
        local server = require("neoagent.rpc.server").new({
          send = function(message)
            request.on_stdout(protocol.encode(message))
            if message.type == "response" then
              child_result = {
                code = 70,
                signal = 0,
                stderr = "crash after completed write",
              }
              request.on_exit(child_result)
            end
          end,
        })
        local decoder = protocol.decoder(function(message)
          server:receive(message)
        end)
        return {
          write = function(_, bytes)
            decoder:feed(bytes)
            return true
          end,
          close_stdin = function()
            return true
          end,
          terminate = function() end,
          wait = function()
            return child_result
          end,
          dispose = function() end,
        }
      end,
    }
    local execute = interceptor(root, platform):wrap()
    local value = wait(async.run(function()
      return execute(require("neoagent.tools.write_file").new(), {
        path = "completed.txt",
        content = "write completed\n",
      }, context(root))
    end))

    assert.is_nil(value.isError)
    assert.matches("Successfully wrote", assert(value.content[1]).text)
    assert.matches("cleanup failed", assert(value.content[2]).text:lower(), 1, true)
    assert.are.same({ root .. "/completed.txt" }, assert(value.details).changed_paths)
    assert.is_true(assert(assert(value.execution).sandbox).cleanup_failed)
    assert.are.equal("write completed\n", assert(fs.read(root .. "/completed.txt")))
  end)

  for _, phase in ipairs({ "response", "close", "wait" }) do
    it("commits acknowledged mutations when worker " .. phase .. " cleanup is cancelled", function()
      package.loaded["neoagent.rpc.connection"] = original_remote
      local root = temporary_root()
      local session = assert(require("neoagent.session").new())
      local fake_model = require("tests.helpers.fake_model")
      local model = fake_model.new({ {
        result = fake_model.assistant({
          { type = "toolCall", id = "written", name = "write_file",
            arguments = { path = "completed.txt", content = "committed bytes\n" },
            },
          { type = "toolCall", id = "later", name = "write_file",
            arguments = { path = "must-not-exist.txt", content = "unexpected" },
            },
        }, "toolUse"),
      },
      })
      ---@type Neoagent.ChatRun?
      local active_run
      local cleanup_started = false
      local disposed = 0
      local reaped = false
      ---@type (fun())?
      local finish_worker
      ---@type Neoagent.SandboxPlatform<unknown>
      local platform = {
        name = "test",
        start_worker = function(request)
          local protocol = require("neoagent.rpc.protocol")
          ---@type Neoagent.AwaitCallbacks<Neoagent.WorkerResult>[]
          local waiters = {}
          finish_worker = function()
            if reaped then return end
            reaped = true
            local completed = { code = 0, signal = 0, stderr = "" }
            assert(request.on_exit)(completed)
            for _, done in ipairs(waiters) do done.resolve(completed) end
            waiters = {}
          end
          local server = require("neoagent.rpc.server").new({
            send = function(message)
              if phase == "close" and message.type == "closed" then
                cleanup_started = true
                return
              end
              assert(request.on_stdout)(protocol.encode(message))
              if phase == "response" and message.type == "response" then
                cleanup_started = true
                assert(active_run):cancel()
              end
            end,
          })
          local decoder = protocol.decoder(function(message) server:receive(message) end)
          return {
            write = function(_, bytes) decoder:feed(bytes)
              return true end,
            close_stdin = function() return true end,
            terminate = function() end,
            ---@async
            wait = function()
              if reaped then return { code = 0, signal = 0, stderr = "" } end
              cleanup_started = true
              return async.await(function(done)
                waiters[#waiters + 1] = done
                return function()
                  for index, waiter in ipairs(waiters) do
                    if waiter == done then table.remove(waiters, index)
                      break end
                  end
                end
              end)
            end,
            dispose = function()
              disposed = disposed + 1
              assert(finish_worker)()
            end,
          }
        end,
      }
      local run = require("neoagent.chat").run(session, "write once", {
        model = model,
        tools = { restricted_tool() },
        execute_tool = interceptor(root, platform):wrap(),
        context = { workspace = Workspace.new({ root = root }), files = session:files() },
      })
      active_run = run
      owner_runs[#owner_runs + 1] = run
      local checked, check_err = pcall(function()
        assert(vim.wait(3000, function() return cleanup_started end))
        assert.are.equal("committed bytes\n", assert(fs.read(root .. "/completed.txt")))
        run:cancel()
        assert(vim.wait(3000, function() return run:is_done() end))
        local completed = assert(run:result())
        assert.is_false(completed.ok)
        assert.are.equal("cancelled", assert(completed.error).kind)
        local messages = session:messages()
        assert.are.equal(3, #messages, "acknowledged write result was not committed")
        local result = assert(messages[3])
        assert.are.equal("toolResult", result.role)
        assert.are.equal("written", result.toolCallId)
        assert.is_false(result.isError)
        assert.are.same({ root .. "/completed.txt" }, assert(result.details).changed_paths)
        local cleanup = assert(assert(result.execution).sandbox)
        assert.is_true(cleanup.cleanup_unobserved)
        assert.is_nil(cleanup.cleanup_failed)
        assert.is_nil(cleanup.unavailable)
        assert.is_nil((util.text_content(result.content):find("cleanup failed", 1, true)))
        assert.is_nil(fs.read(root .. "/must-not-exist.txt"))
        assert.are.equal(1, #model.requests)
      end)
      run:cancel()
      assert(finish_worker)()
      assert(vim.wait(3000, function() return run:is_done() and reaped end))
      assert.is_true(disposed <= 1)
      assert.is_true(checked, tostring(check_err))
    end)
  end

  it("preserves successful results across every worker reap failure", function()
    local function execute_with_wait(wait_worker)
      local root = temporary_root()
      local active_child, child_state = child()
      active_child.wait = function()
        child_state.waited = child_state.waited + 1
        return wait_worker()
      end
      ---@type Neoagent.SandboxPlatform<unknown>
      local platform = {
        name = "test",
        check = function()
          return { ok = true, platform = "test", capabilities = {} }
        end,

        start_worker = function() return active_child end,
      }
      remote()
      local execute = interceptor(root, platform):wrap(function(tool, arguments, ctx)
        tool.execute(arguments, ctx)
        return {
          content = { { type = "text", text = "operation complete" } },
          details = { changed_paths = { "complete.txt" } },
        }
      end)
      local value = wait(async.run(function()
        return execute(restricted_tool(), {
          path = "complete.txt", content = "complete\n",
        }, context(root))
      end))
      return value, child_state
    end

    local value, failed_state = execute_with_wait(function()
      error("worker wait failed")
    end)
    assert.are.equal("operation complete", assert(value.content[1]).text)
    assert.matches("worker wait failed", assert(value.content[2]).text)
    assert.is_true(assert(assert(value.execution).sandbox).cleanup_failed)
    assert(vim.wait(1000, function() return failed_state.closed == 1 end))
    assert.are.equal(2, failed_state.waited)

    value = execute_with_wait(function()
      return {
        code = 0, signal = 0, stderr = "",
        error = util.error("sandbox_unavailable", "guardian wait failed"),
      }
    end)
    assert.are.equal("operation complete", assert(value.content[1]).text)
    assert.matches("guardian wait failed", assert(value.content[2]).text)

    value = execute_with_wait(function()
      return { code = 9, signal = 0, stderr = "worker diagnostic" }
    end)
    assert.are.equal("operation complete", assert(value.content[1]).text)
    assert.matches("failed during shutdown", assert(value.content[2]).text)

    local original_new_timer = vim.uv.new_timer
    vim.uv.new_timer = function()
      local closed = false
      local timer = {
        start = function(_, _, _, callback)
          callback()
        end,
        stop = function() end,
        close = function()
          closed = true
        end,
        is_closing = function()
          return closed
        end,
      }
      return timer --[[@as uv.uv_timer_t]]
    end
    ---@type Neoagent.ToolResult?
    local forced_value
    ---@type table?
    local forced_state
    local forced_ok, forced_err = pcall(function()
      forced_value, forced_state = execute_with_wait(function()
        return { code = 0, signal = 0, stderr = "" }
      end)
    end)
    vim.uv.new_timer = original_new_timer
    assert.is_true(forced_ok, vim.inspect(forced_err))
    local completed = assert(forced_value)
    local state = assert(forced_state)
    assert.are.equal("operation complete", assert(completed.content[1]).text)
    assert.are.equal(1, state.closed)
  end)

  it("classifies private denial evidence outside truncated result text", function()
    local root = temporary_root()
    local active_child = child()
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function() return active_child end,
    }
    remote({
      request = function(_, _, _, handlers)
        handlers.on_event({
          name = require("neoagent.rpc.codec").events.policy,
          value = { denial_output = "permission denied" },
        })
        return {
          isError = true,
          content = { { type = "text", text = "ordinary output tail" } },
        }
      end,
    })
    local execute = interceptor(root, platform):wrap(function(tool, arguments, ctx)
      return tool.execute(arguments, ctx)
    end)

    local value = wait(async.run(function()
      return execute(restricted_tool(), {
        path = "private.txt",
        content = "value",
      }, context(root))
    end))

    assert.matches("ordinary output tail", assert(value.content)[1].text, 1, true)
    assert.matches("blocked by the sandbox", assert(value.content)[1].text, 1, true)
    local failure = assert(assert(value.execution).sandbox)
    assert.is_true(failure.ran_restricted)
    assert.is_nil(value.details)
    assert.is_nil(vim.inspect(value):find("private%-value"))
  end)

  it("propagates cancellation and distinguishes denial from uncertain mutation", function()
    local root = temporary_root()
    local active_child, child_state = child()
    local platform = {
      name = "linux",
      check = function() return { ok = true, platform = "linux", capabilities = {} } end,
      start_worker = function() return active_child end,
    }
    local function after_remote(callback)
      return function(tool, _, ctx)
        tool.execute({ path = "operation.txt", content = "value" }, ctx)
        return callback()
      end
    end

    remote()
    local execute = interceptor(root, platform):wrap(after_remote(function()
      error(util.error("outcome_uncertain", "worker disappeared", "partial mutation"), 0)
    end))
    local value = wait(async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end))
    local failure = assert(assert(value.execution).sandbox)
    assert.is_true(failure.outcome_uncertain)
    assert.matches("partial mutation", value.content[1].text)
    assert.matches("not retried", value.content[1].text)

    active_child = child()
    remote()
    execute = interceptor(root, platform):wrap(after_remote(function()
      local err = util.error("tool", "permission denied by operation")
      rawset(err, "code", "EACCES")
      error(err, 0)
    end))
    value = wait(async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end))
    failure = assert(assert(value.execution).sandbox)
    assert.is_true(failure.denied)
    assert.is_true(failure.can_escalate)

    active_child = child()
    remote()
    execute = interceptor(root, platform):wrap(after_remote(function()
      return {
        isError = true,
        content = { { type = "text", text = "write failed: permission denied" } },
      }
    end))
    value = wait(async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end))
    assert.matches("write failed: permission denied", assert(value.content)[1].text, 1, true)
    assert.matches("blocked by the sandbox", assert(value.content)[1].text, 1, true)
    failure = assert(assert(value.execution).sandbox)
    assert.is_true(failure.ran_restricted)

    active_child = child()
    remote()
    execute = interceptor(root, platform):wrap(after_remote(function()
      return {
        isError = true,
        content = { { type = "text", text = "ordinary tool failure" } },
      }
    end))
    value = wait(async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end))
    assert.are.equal("ordinary tool failure", assert(value.content)[1].text)
    assert.is_nil(value.details)

    active_child = child()
    remote()
    execute = interceptor(root, platform):wrap(after_remote(function()
      local constants = (vim.uv --[[@as {constants?: table<string, integer>}]]).constants
        or error("libuv constants unavailable")
      local sigsys = constants.SIGSYS or error("SIGSYS unavailable")
      return { isError = true, details = { exit_code = 128 + sigsys } }
    end))
    value = wait(async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end))
    assert.matches("blocked by the sandbox", assert(value.content)[1].text)

    active_child = child()
    remote({ close = function()
      error(util.error("cancelled", "close cancelled"), 0)
    end,
    })
    execute = interceptor(root, platform):wrap(after_remote(function()
      return { content = { { type = "text", text = "done" } } }
    end))
    local cancelled = async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end)
    assert(vim.wait(1000, function()
      return cancelled:is_done()
    end))
    local cancelled_value = assert(cancelled:result())
    assert.are.equal("done", assert(cancelled_value.content)[1].text)
    assert.is_true(assert(assert(cancelled_value.execution).sandbox).cleanup_unobserved)
    assert.are.equal("cancelled", assert(assert(cancelled_value.execution).sandbox).kind)

    active_child = child()
    remote({ open = function()
      error(util.error("cancelled", "open cancelled"), 0)
    end,
    })
    execute = interceptor(root, platform):wrap()
    cancelled = async.run(function()
      return execute(restricted_tool(), { path = "operation.txt", content = "value" }, context(root))
    end)
    assert(vim.wait(1000, function()
      return cancelled:is_done()
    end))
    cancelled_value = assert(cancelled:result())
    assert.is_false(cancelled_value.ok)
    assert.are.equal("cancelled", assert(cancelled_value.error).kind)

    active_child = child()
    remote()
    execute = interceptor(root, platform):wrap(after_remote(function()
      error(util.error("sandbox", "generic sandbox failure"), 0)
    end))
    value = wait(async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end))
    assert.is_true(assert(value.execution).sandbox.unavailable)
    assert.are.equal("sandbox", assert(value.execution).sandbox.kind)

    active_child, child_state = child()
    local _, cancelled_remote = remote()
    execute = interceptor(root, platform):wrap(after_remote(function()
      error(util.error("cancelled", "execution cancelled"), 0)
    end))
    cancelled = async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end)
    assert(vim.wait(1000, function() return cancelled:is_done() end))
    cancelled_value = assert(cancelled:result())
    assert.is_false(cancelled_value.ok)
    assert.are.equal("cancelled", assert(cancelled_value.error).kind)
    assert.are.equal(1, cancelled_remote.cancelled)
    assert.are.equal(0, cancelled_remote.aborted)
    assert.are.equal(1, child_state.waited)
    assert.are.equal(0, child_state.closed)

    active_child = child()
    remote()
    execute = interceptor(root, platform):wrap(after_remote(function()
      error(util.error("unexpected", "unexpected execution failure"), 0)
    end))
    local unexpected = async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end)
    assert(vim.wait(1000, function() return unexpected:is_done() end))
    local unexpected_value = assert(unexpected:result())
    assert.is_false(unexpected_value.ok)
    assert.are.equal("unexpected", assert(unexpected_value.error).kind)
  end)

  it("retains a cancelled POSIX worker until its cleanup exits", function()
    if jit.os == "Windows" then return end
    local root = temporary_root()
    local started = vim.fs.joinpath(root, "started")
    local stopping = vim.fs.joinpath(root, "stopping")
    local release = vim.fs.joinpath(root, "release")
    local cleaned = vim.fs.joinpath(root, "cleaned")
    local late = vim.fs.joinpath(root, "late")
    cleanup_releases[#cleanup_releases + 1] = release
    -- Hold cleanup until the parent observes cancellation and SIGTERM. The
    -- detached writer reports a leak if the worker dies before cleaning it up.
    local program = table.concat({
      "import pathlib, signal, subprocess, sys, time",
      "late, cleaned, started, stopping, release = sys.argv[1:]",
      "writer = subprocess.Popen([",
      "    sys.executable, '-c',",
      "    \"import pathlib, sys; sys.stdin.buffer.read(); pathlib.Path(sys.argv[1]).write_text('late')\",",
      "    late,",
      "], start_new_session=True, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)",
      "def stop(_signal, _frame):",
      "    pathlib.Path(stopping).write_text('stopping')",
      "    deadline = time.monotonic() + 10",
      "    while not pathlib.Path(release).exists():",
      "        if time.monotonic() >= deadline:",
      "            raise RuntimeError('cleanup was not released')",
      "        time.sleep(0.01)",
      "    writer.kill()",
      "    writer.wait()",
      "    pathlib.Path(cleaned).write_text('cleaned')",
      "    raise SystemExit(0)",
      "signal.signal(signal.SIGTERM, stop)",
      "pathlib.Path(started).write_text('started')",
      "while True:",
      "    time.sleep(1)",
    }, "\n")
    ---@type Neoagent.WorkerResult?
    local worker_exit
    local platform = {
      name = "test",
      check = function() return { ok = true, platform = "test", capabilities = {} } end,
      start_worker = function(request)
        local active_child = require("neoagent.rpc.worker_lease").start({
          argv = { assert(vim.fn.exepath("python3")), "-c", program, late, cleaned, started, stopping, release },
          cwd = root,
          env = require("tests.helpers.tool_worker").environment(),
          clear_env = true,
          kill_grace_ms = 5000,
          on_stdout = request.on_stdout,
          on_stderr = request.on_stderr,
          on_exit = function(result)
            worker_exit = result
            if request.on_exit then request.on_exit(result) end
          end,
        })
        live_children[#live_children + 1] = active_child
        return active_child
      end,
    }
    remote()
    ---@async
    local function suspend(tool, _, ctx)
      tool.execute({ path = "operation.txt", content = "value" }, ctx)
      return async.await(function() end)
    end
    local execute = interceptor(root, platform):wrap(suspend)
    local cancelled = async.run(function()
      return execute(restricted_tool(), {}, context(root))
    end)
    owner_runs[#owner_runs + 1] = cancelled
    assert(vim.wait(3000, function()
      return vim.uv.fs_stat(started) ~= nil or cancelled:is_done()
    end, 5))
    assert.is_false(cancelled:is_done(), vim.inspect(cancelled:result()))

    cancelled:cancel()

    assert(vim.wait(3000, function() return cancelled:is_done() end, 5))
    local cancelled_result = assert(cancelled:result())
    assert.is_false(cancelled_result.ok)
    assert.are.equal("cancelled", assert(cancelled_result.error).kind)
    assert(vim.wait(5000, function()
      return vim.uv.fs_stat(stopping) ~= nil or worker_exit ~= nil
    end, 5))
    assert.is_nil(worker_exit, vim.inspect(worker_exit))
    assert.is_not_nil(vim.uv.fs_stat(stopping))
    assert.is_nil(vim.uv.fs_stat(cleaned))
    assert.are.equal(0, vim.fn.writefile({ "release" }, release))
    assert(vim.wait(5000, function() return worker_exit ~= nil end, 5))
    local exit = assert(worker_exit)
    assert.are.equal(0, exit.code, vim.inspect(exit))
    assert.are.equal(0, exit.signal)
    assert.is_not_nil(vim.uv.fs_stat(cleaned))
    assert.is_nil(vim.uv.fs_stat(late))
  end)

  it("appends sandbox metadata to results without text or details", function()
    local result = require("neoagent.sandbox.result")
    local value = result.append({
      content = { { type = "image", file_id = string.rep("a", 64), bytes = 1, mime_type = "image/png" } },
    },
      "sandbox note", { backend = "test" })
    assert.are.equal("sandbox note", (value.content[1] or error("missing text block")).text)
    assert.are.equal("test", assert(assert(value.execution).sandbox).backend)
  end)
end)
