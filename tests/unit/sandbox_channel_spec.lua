local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local protocol = require("neoagent.rpc.protocol")
local native = require("neoagent.sandbox.protocol")

describe("sandbox channel failure ordering", function()
  local roots, servers, leases, runs = {}, {}, {}, {}

  after_each(function()
    for _, run in ipairs(runs) do run:cancel() end
    for _, lease in ipairs(leases) do lease:dispose("test teardown") end
    for _, server in ipairs(servers) do
      server:eof()
      assert(vim.wait(3000, function() return server:is_quiescent() end))
    end
    for _, run in ipairs(runs) do
      assert(vim.wait(3000, function() return run:is_done() end))
    end
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots, servers, leases, runs = {}, {}, {}, {}
  end)

  for _, failure in ipairs({ "native protocol", "trailing shutdown data" }) do
    it("preserves mutation certainty across " .. failure, function()
      local root = vim.fn.tempname()
      roots[#roots + 1] = root
      assert(fs.mkdirp(root))
      root = assert(vim.uv.fs_realpath(root))
      local terminated, disposed = 0, 0
      ---@type Neoagent.SandboxPlatform<unknown>
      local platform = {
        name = "test",
        ---@param request Neoagent.SandboxWorkerRequest
        start_worker = function(request)
          local relay = failure == "native protocol" and require("neoagent.sandbox.relay_lease").new({
            on_stdout = request.on_stdout,
            on_exit = request.on_exit,
            on_failure = request.on_failure,
          }) or nil
          local sequence = 0
          local function output(bytes)
            if relay then
              sequence = sequence + 1
              relay:feed(native.encode({ v = 1, type = "output", stream = "stdout", seq = sequence, data = bytes }))
            else
              assert(request.on_stdout)(bytes)
            end
          end
          local ready = native.encode({ v = 1, type = "ready" })
          if relay then relay:feed(ready) end
          local server = require("neoagent.rpc.server").new({
            send = function(message)
              if relay and message.type == "response" then
                relay:feed(ready)
              end
              output(protocol.encode(message))
            end,
          })
          servers[#servers + 1] = server
          local decoder = protocol.decoder(function(message) server:receive(message) end)
          ---@type Neoagent.WorkerResult?
          local result
          ---@type Neoagent.AwaitCallbacks<Neoagent.WorkerResult>[]
          local waiters = {}
          local function finish()
            if result then return end
            result = { code = 0, signal = 0, stderr = "" }
            if relay then
              relay:host_exited(result)
            else
              assert(request.on_exit)(result)
            end
            for _, waiter in ipairs(waiters) do waiter.resolve(result) end
            waiters = {}
          end
          ---@type Neoagent.WorkerLease
          local base = {
            write = function(_, bytes) decoder:feed(bytes) return true end,
            close_stdin = function()
              vim.schedule(function()
                if not relay then output("\0") end
                finish()
              end)
              return true
            end,
            terminate = function() terminated = terminated + 1 end,
            dispose = function()
              disposed = disposed + 1
              server:eof()
              finish()
            end,
            ---@async
            wait = function()
              if result then return result end
              return async.await(function(done) waiters[#waiters + 1] = done end)
            end,
          }
          if relay then relay:attach(base) end
          local lease = relay or base
          leases[#leases + 1] = lease
          return lease
        end,
      }
      local interceptor = require("neoagent.sandbox.interceptor").new({
        platform = platform,
        profile = {
          id = "channel-order", filesystem = { default = "read", entries = { { path = root, access = "write" } } },
          network = "restricted", environment = { clear = true, inherit = {}, set = {} },
        },
        nvim = vim.env.NEOAGENT_NVIM,
      })
      local fake_model = require("tests.helpers.fake_model")
      local run = require("neoagent.agent_loop").run({
        model = fake_model.new({
          { result = fake_model.assistant({ {
            type = "toolCall", id = "write", name = "write_file",
            arguments = { path = "changed.txt", content = "changed once" },
          } }, "toolUse") },
          { result = fake_model.assistant({ { type = "text", text = "done" } }) },
        }),
        messages = {}, tools = { require("neoagent.tools.write_file").new() },
        execute_tool = interceptor:wrap(), context = { workspace = { root = root, cwd = root } },
        commit_message = function() return true end,
      })
      runs[#runs + 1] = run
      assert(vim.wait(3000, function() return run:is_done() end))
      local completed = assert(run:result())
      assert.is_true(completed.ok, vim.inspect(completed))
      local value = assert(assert(completed.new_messages)[2])
      if value.role ~= "toolResult" then error("missing committed Tool result") end
      assert.are.equal("changed once", fs.read(root .. "/changed.txt"))
      local metadata = assert(assert(value.details).sandbox)
      if failure == "native protocol" then
        assert.is_true(value.isError)
        assert.is_true(metadata.outcome_uncertain)
        assert.is_nil(metadata.cleanup_failed)
        assert.are.equal(1, terminated)
        assert.are.equal(1, disposed)
      else
        assert.is_not_true(value.isError)
        assert.is_true(metadata.cleanup_failed)
        assert.is_nil(metadata.outcome_uncertain)
        assert.matches("after acknowledging shutdown", require("neoagent.util").text_content(value.content))
      end
    end)
  end
end)
