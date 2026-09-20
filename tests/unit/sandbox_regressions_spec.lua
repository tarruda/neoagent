local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

describe("restricted filesystem execution", function()
  ---@type string
  local root
  ---@type Neoagent.Run<Neoagent.ToolResult, unknown>[]
  local runs = {}
  ---@type Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>[]
  local owners = {}
  ---@type Neoagent.RpcServer[]
  local servers = {}
  local new_timer = vim.uv.new_timer

  before_each(function()
    root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    root = assert(vim.uv.fs_realpath(root))
  end)

  after_each(function()
    vim.uv.new_timer = new_timer
    for _, run in ipairs(runs) do run:cancel() end
    for _, owner in ipairs(owners) do owner:cancel() end
    for _, server in ipairs(servers) do
      server:eof()
      assert(vim.wait(3000, function() return server:is_quiescent() end))
    end
    runs, owners, servers = {}, {}, {}
    vim.fn.delete(root, "rf")
  end)

  ---@param name string
  ---@param arguments Neoagent.JsonObject
  ---@param dispatch? async fun(method: string, payload: unknown, call: Neoagent.ToolOperationCall, deps: Neoagent.ToolDependencyOverrides): Neoagent.ToolResult
  ---@param dependencies? Neoagent.ToolDependencyOverrides
  local function execute(name, arguments, dispatch, dependencies)
    local state = { disposed = 0, waited = 0, started = false }
    ---@type Neoagent.SandboxPlatform<unknown>
    local platform = {
      name = "test",
      start_worker = function(request)
        local protocol = require("neoagent.rpc.protocol")
        local options = {
          dependencies = dependencies,
          send = function(message) request.on_stdout(protocol.encode(message)) end,
        }
        local server_module = require("neoagent.rpc.server")
        local server = dispatch and server_module._new(options, function(method, payload, call, deps)
          state.started = true
          return dispatch(method, payload, call, deps)
        end) or server_module.new(options)
        servers[#servers + 1] = server
        local decoder = protocol.decoder(function(message) server:receive(message) end)
        return {
          write = function(_, data) decoder:feed(data) return true end,
          close_stdin = function()
            request.on_exit({ code = 0, signal = 0, stderr = "" })
            return true
          end,
          terminate = function() server:eof() end,
          dispose = function()
            state.disposed = state.disposed + 1
            server:eof()
          end,
          wait = function()
            state.waited = state.waited + 1
            return { code = 0, signal = 0, stderr = "" }
          end,
        }
      end,
    }
    ---@type Neoagent.SandboxInterceptorOptions<unknown>
    local interceptor_options = {
      platform = platform,
      profile = {
        id = "filesystem-regression",
        filesystem = { default = "read", entries = { { path = root, access = "write" } } },
        network = "restricted",
        environment = { clear = true, inherit = {}, set = {} },
      },
      nvim = vim.env.NEOAGENT_NVIM,
    }
    local interceptor = require("neoagent.sandbox.interceptor").new(interceptor_options)
    ---@async
    ---@return Neoagent.AgentLoopResult
    local function lifetime()
      return async.await(function() end)
    end
    local owner = async.run(lifetime)
    owners[#owners + 1] = owner
    local run = async.run(function()
      return interceptor:wrap()(require("neoagent.tools." .. name).new(), arguments, {
        model = require("tests.helpers.fake_model").new(),
        run = owner,
        execute_tool = function(tool, args, ctx) return tool.execute(args, ctx) end,
        call = { type = "toolCall", id = "regression", name = name, arguments = arguments },
        context = { workspace = { root = root, cwd = root } },
        on_update = function() end,
      })
    end)
    runs[#runs + 1] = run
    return run, state
  end

  for _, scenario in ipairs({
    { name = "read_file", arguments = { path = "sandbox.lua" } },
    { name = "edit_file", arguments = {
      path = "sandbox.lua", edits = { { oldText = "old", newText = "new" } },
    } },
    { name = "write_file", arguments = { path = "sandbox.lua/child", content = "new" } },
  }) do
    it("keeps ordinary " .. scenario.name .. " failures out of sandbox escalation", function()
      if scenario.name == "write_file" then assert(fs.write_all(root .. "/sandbox.lua", "file")) end
      local run = execute(scenario.name, scenario.arguments)
      assert(vim.wait(3000, function() return run:is_done() end))
      local result = assert(run:result())
      assert.is_false(result.ok, vim.inspect(result))
      local err = assert(result.error)
      assert.are.equal("tool", err.kind)
      assert.matches("sandbox.lua", err.message, 1, true)
      assert.is_nil(rawget(err, "sandbox"))
    end)
  end

  for _, code in ipairs({ "EACCES", "EPERM", "EROFS" }) do
    it("preserves filesystem denial code " .. code .. " over RPC", function()
      local filesystem = util.copy(fs)
      filesystem.read_chunks = function() return nil, code .. ": filesystem access refused" end
      local run = execute("read_file", { path = "denied.txt" }, nil, { fs = filesystem })
      assert(vim.wait(3000, function() return run:is_done() end))
      local result = assert(run:result())
      assert.is_true(result.isError, vim.inspect(result))
      local sandbox = assert(assert(result.details).sandbox)
      assert.is_true(sandbox.denied)
      assert.is_true(sandbox.can_escalate)
    end)
  end

  for _, name in ipairs({ "read_file", "write_file", "edit_file" }) do
    it("bounds a stalled " .. name .. " request and retains mutation uncertainty", function()
      vim.uv.new_timer = function()
        local timer = assert(new_timer())
        return {
          start = function(_, milliseconds, repeat_ms, callback)
            return timer:start(milliseconds == 30000 and 10 or milliseconds, repeat_ms, callback)
          end,
          stop = function() return timer:stop() end,
          close = function() return timer:close() end,
          is_closing = function() return timer:is_closing() end,
        } --[[@as uv.uv_timer_t]]
      end
      local run, state = execute(name, {
        path = "file.txt", content = "new", edits = { { oldText = "old", newText = "new" } },
      }, function()
        if name ~= "read_file" then assert(fs.write_all(root .. "/effect.txt", "effect completed")) end
        return async.await(function() end)
      end)
      assert(vim.wait(1000, function() return run:is_done() end), "stalled filesystem RPC has no execution deadline")
      local result = assert(run:result())
      assert.is_true(state.started)
      assert.is_true(result.isError, vim.inspect(result))
      local sandbox = assert(assert(result.details).sandbox)
      assert.is_true(sandbox.timed_out)
      assert.is_nil(sandbox.can_escalate)
      assert.are.equal(1, state.disposed)
      assert.are.equal(1, state.waited)
      if name ~= "read_file" then
        assert.is_true(sandbox.outcome_uncertain)
        assert.are.equal("effect completed", fs.read(root .. "/effect.txt"))
      else
        assert.is_nil(sandbox.outcome_uncertain)
      end
    end)
  end
end)
