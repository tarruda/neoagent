local assert = require("luassert")
local agent_loop = require("neoagent.agent_loop")
local async = require("neoagent.async")
local composition = require("neoagent.sandbox.composition")
local fake_model = require("tests.helpers.fake_model")
local fs = require("neoagent.fs")

describe("restricted shell deadlines", function()
  local platform = require("neoagent.sandbox.platform").select()
  local status = platform and platform.check({ fs = fs }) or nil
  local native_test = platform and status and status.ok
    and (platform.name == "linux" or platform.name == "macos") and it or pending
  local roots = {}
  ---@type Neoagent.WorkerLease[]
  local leases = {}
  ---@type Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>[]
  local runs = {}

  after_each(function()
    for _, run in ipairs(runs) do run:cancel() end
    for _, lease in ipairs(leases) do
      lease:dispose("shell deadline regression teardown")
      local cleanup = async.run(function() return lease:wait() end)
      assert(vim.wait(15000, function() return cleanup:is_done() end, 10))
    end
    for _, run in ipairs(runs) do
      assert(vim.wait(5000, function() return run:is_done() end, 10))
    end
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots, leases, runs = {}, {}, {}
  end)

  for _, explicit in ipairs({ false, true }) do
    native_test("enforces a " .. (explicit and "requested" or "default") .. " timeout when the command stops its worker", function()
      local root = vim.fn.tempname()
      roots[#roots + 1] = root
      assert(fs.mkdirp(root))
      root = assert(vim.uv.fs_realpath(root))
      local started = root .. "/started"
      local shell = require("neoagent.tools.shell").new({ default_timeout = not explicit and 0.05 or false })
      local selected = assert(platform)
      ---@type Neoagent.SandboxCompositionOptions<unknown>
      local options = {
        platform = vim.tbl_extend("force", selected, {
          start_worker = function(request, services)
            local lease = selected.start_worker(request, services)
            leases[#leases + 1] = lease
            return lease
          end,
        }),
        status = status,
      }
      local toolset = composition.compose({ tools = { shell } }, { enabled = true }, options)
      local execute = assert(toolset.execute_tool)
      ---@type Neoagent.ToolCallBlock
      local call = {
        type = "toolCall", id = "timeout", name = "shell", arguments = {
          command = 'kill -STOP "$PPID"; printf started > ' .. vim.fn.shellescape(started) .. "; sleep 30",
        },
      }
      if explicit then call.arguments.timeout = 0.05 end
      ---@type Neoagent.ToolResult?
      local result
      local run = agent_loop.run({
        model = fake_model.new({
          { result = fake_model.assistant({ call }, "toolUse") },
          { result = fake_model.assistant({}) },
        }),
        tools = toolset.tools, messages = {},
        context = { workspace = { root = root, cwd = root } },
        commit_message = function() return true end,
        execute_tool = function(tool, arguments, ctx)
          result = execute(tool, arguments, ctx)
          return result
        end,
      })
      runs[#runs + 1] = run
      assert(vim.wait(30000, function() return fs.read(started) == "started" or run:is_done() end, 10))
      assert.are.equal("started", fs.read(started), vim.inspect(run:result()))
      assert(vim.wait(7000, function() return run:is_done() end, 10), "stopped worker bypassed the shell timeout")
      assert.is_true(assert(run:result()).ok, vim.inspect(run:result()))
      assert(result)
      assert.is_true(result.isError)
      local sandbox = assert(assert(result.details).sandbox)
      assert.is_true(sandbox.timed_out)
      assert.is_true(sandbox.outcome_uncertain)
      assert.are.equal("outcome_uncertain", sandbox.kind)
      local reaped = async.run(function() return assert(leases[1]):wait() end)
      assert.is_true(reaped:is_done(), "timeout returned before native worker cleanup settled")
    end)
  end
end)
