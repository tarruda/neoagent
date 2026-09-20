local assert = require("luassert")
local async = require("neoagent.async")
local common = require("neoagent.tools.common")
local fs = require("neoagent.fs")

describe("Tool worker execution policy", function()
  it("preserves network roots when preparing relative file targets", function()
    local call = {
      workspace = { root = "//server/share", cwd = "//server/share/workspace" },
      on_update = function() end,
    }
    for _, invocation in ipairs({
      { name = "write_file", arguments = { path = "file.txt", content = "contents" }, settings = {} },
      { name = "edit_file", arguments = {
        path = "file.txt", edits = { { oldText = "old", newText = "new" } },
      }, settings = {} },
      { name = "read_file", arguments = { path = "file.txt" }, settings = {
        max_image_input_bytes = 1024, max_image_pixels = 1024, max_image_output_bytes = 1024,
      } },
      { name = "grep", arguments = { path = "file.txt", pattern = "needle" }, settings = {} },
      { name = "find", arguments = { path = "file.txt", pattern = "*" }, settings = {} },
    }) do
      local implementation = require("neoagent.tools." .. invocation.name)
      local prepared = implementation.prepare(invocation.arguments, invocation.settings, call)
      assert.are.equal("//server/share/workspace/file.txt", prepared.resolved_path)
      invocation.arguments.path = "//server/share/file.txt"
      prepared = implementation.prepare(invocation.arguments, invocation.settings, call)
      assert.are.equal("//server/share/file.txt", prepared.resolved_path)
    end
    local root = jit.os == "Windows" and "C:/" or "/"
    call.workspace = { root = root, cwd = root }
    local prepared = require("neoagent.tools.write_file").prepare({ path = "file.txt", content = "contents" }, {}, call)
    assert.are.equal(root .. "file.txt", prepared.resolved_path)
  end)

  it("keeps resolved search targets when the execution environment changes", function()
    local original = vim.env.NEOAGENT_SEARCH_ROOT
    local root = vim.fn.tempname()
    assert(fs.mkdirp(root .. "/chosen"))
    assert(fs.mkdirp(root .. "/other"))
    assert(fs.write_all(root .. "/chosen/parent.txt", "parent needle\n"))
    assert(fs.write_all(root .. "/other/worker.txt", "worker needle\n"))
    local ctx = {
      context = { workspace = { root = root, cwd = root } }, on_update = function() end,
    } --[[@as Neoagent.ToolContext<unknown>]]
    local call = common.call(ctx)
    local succeeded, failure = pcall(function()
      for _, name in ipairs({ "find", "grep" }) do
        vim.env.NEOAGENT_SEARCH_ROOT = "chosen"
        local implementation = require("neoagent.tools." .. name)
        local proxy = assert(require("neoagent.rpc.registry").proxy(implementation.new(), {
          call = call,
          invoke = function(_, request, operation_call)
            vim.env.NEOAGENT_SEARCH_ROOT = "other"
            return implementation.run(
              implementation.validate_request(request), operation_call, implementation._dependencies()
            )
          end,
        }))
        local run = async.run(function()
          return proxy.execute({
            pattern = name == "find" and "*.txt" or "needle", path = "$NEOAGENT_SEARCH_ROOT",
          }, ctx)
        end)
        assert(vim.wait(3000, function() return run:is_done() end))
        local value = assert(run:result())
        if value.ok == false then error(value.error, 0) end
        local first = value.content[1]
        if not first or first.type ~= "text" then error("search did not return text") end
        local text = first.text
        assert.matches("parent.txt", text, 1, true)
        assert.is_nil((text:find("worker.txt", 1, true)))
      end
    end)
    vim.env.NEOAGENT_SEARCH_ROOT = original
    vim.fn.delete(root, "rf")
    assert.is_true(succeeded, tostring(failure))
  end)

  it("applies the same request budget before local and restricted writes", function()
    local protocol = require("neoagent.rpc.protocol")
    local limits = require("neoagent.tools.limits")
    local original_limit = limits.MAX_INPUT_BYTES
    local root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    root = assert(vim.uv.fs_realpath(root))
    local tool = require("neoagent.tools.write_file").new()
    local ctx = {
      context = { workspace = { root = root, cwd = root } },
      on_update = function() end,
    } --[[@as Neoagent.ToolContext<unknown>]]
    local call = common.call(ctx)
    local policy = require("neoagent.sandbox.api_policy").new({
      profile = {
        id = "budget", filesystem = { default = "read", entries = { { path = root, access = "write" } } },
        network = "restricted", environment = { clear = true, inherit = {}, set = {} },
      },
      paths = require("neoagent.sandbox.path").for_os(jit.os), platform = "test",
    })
    local executed, failure = pcall(function()
      limits.MAX_INPUT_BYTES = 1024
      local arguments = { path = "file.txt", content = string.rep("x", 1025) }
      local local_ok = pcall(tool.execute, arguments, ctx)
      local connection = require("neoagent.rpc.connection").new()
      local server = require("neoagent.rpc.server").new({
        send = function(message) connection:feed(protocol.encode(message)) end,
      })
      local decoder = protocol.decoder(function(message) server:receive(message) end)
      connection:attach({
        write = function(_, bytes) decoder:feed(bytes) return true end,
        close_stdin = function() return true end,
        terminate = function() server:eof() end,
        dispose = function() server:eof() end,
        wait = function() return { code = 0, signal = 0, stderr = "" } end,
      } --[[@as Neoagent.WorkerLease]])
      local proxy = assert(require("neoagent.rpc.registry").proxy(tool, {
        call = call,
        invoke = function(method, request, operation_call)
          return require("neoagent.rpc.tool_client").invoke(
            connection, method, policy:authorize(method, request, operation_call), operation_call
          )
        end,
      }))
      local run = async.run(function()
        connection:open(require("neoagent.rpc.codec").encode_context(call))
        local remote_ok = pcall(proxy.execute, arguments, ctx)
        local accepted = { path = "accepted.txt", content = string.rep("x", 512) }
        local local_accepted, local_result = pcall(tool.execute, accepted, ctx)
        local remote_accepted, remote_result = pcall(proxy.execute, accepted, ctx)
        pcall(connection.close, connection)
        return {
          remote_ok = remote_ok,
          local_accepted = local_accepted, local_result = local_result,
          remote_accepted = remote_accepted, remote_result = remote_result,
        }
      end)
      assert(vim.wait(3000, function() return run:is_done() end))
      local result = assert(run:result())
      assert.are.equal(local_ok, result.remote_ok, "local and restricted acceptance differ")
      assert.is_true(result.local_accepted, vim.inspect(result.local_result))
      assert.is_true(result.remote_accepted, vim.inspect(result.remote_result))
    end)
    limits.MAX_INPUT_BYTES = original_limit
    vim.fn.delete(root, "rf")
    assert.is_true(executed, tostring(failure))
  end)

  it("keeps the platform command encoder when the worker supplies process execution", function()
    local module = jit.os == "Windows" and "neoagent.process.windows" or "neoagent.process.posix"
    local saved_tree = package.loaded[module]
    local saved_process = package.loaded["neoagent.process"]
    local saved_system = vim.system
    local root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    local encoded = false
    local executed, failure = pcall(function()
      package.loaded[module] = {
        detach = false,
        new = function()
          return { attach = function() return true end, close = function() end }
        end,
        spawn = function(_, _, on_exit)
          encoded = true
          vim.schedule(function() on_exit({ code = 0, signal = 0 }) end)
          return { pid = 123, kill = function() end }
        end,
      }
      package.loaded["neoagent.process"] = nil
      vim.system = function() error("platform command encoder was bypassed") end
      ---@type table?
      local response
      local server = require("neoagent.rpc.server").new({
        send = function(message)
          if message.type == "response" or message.type == "request_error" then response = message end
        end,
      })
      server:receive({ type = "open", call_id = "encoder", context = { workspace = { root = root, cwd = root } } })
      server:receive({
        type = "request", call_id = "encoder", request_id = 1, method = "shell",
        payload = { argv = { "cmd.exe", "/d", "/s", "/c", 'echo "quoted value"' } },
      })
      assert(vim.wait(3000, function() return response ~= nil end))
      assert.is_true(encoded, "worker bypassed the platform command encoder")
      local terminal = response or error("missing worker response")
      assert.are.equal("response", terminal.type)
      server:receive({ type = "close", call_id = "encoder" })
    end)
    package.loaded[module] = saved_tree
    package.loaded["neoagent.process"] = saved_process
    vim.system = saved_system
    vim.fn.delete(root, "rf")
    assert.is_true(executed, tostring(failure))
  end)
end)
