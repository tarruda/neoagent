local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local workers = require("neoagent.rpc.worker_lease")
local relays = require("neoagent.sandbox.relay_lease")
local sessions = require("neoagent.process_sessions")

describe("retained sandbox host startup", function()
  ---@type Neoagent.ProcessSessions
  local owner
  ---@type Neoagent.WorkerLease[]
  local hosts
  local failure
  local new_timer, new_pipe, spawn, read_start = vim.uv.new_timer, vim.uv.new_pipe, vim.uv.spawn, vim.uv.read_start

  before_each(function()
    hosts = {}
    local placement = require("neoagent.sandbox.placement").new({
      profile = {
        id = "failed-native-host", network = "restricted",
        filesystem = { default = "read", entries = {} },
        environment = { clear = false, inherit = {}, set = {} },
      },
      platform = {
        name = "native-host-contract",
        paths = require("neoagent.sandbox.path").for_os(jit.os),
        check = function() return { ok = true, platform = "native-host-contract" } end,
        create_worker = function(request)
          local relay = relays.new({ on_failure = request.on_failure,
            cleanup = function(result)
              if result.execution == "not_started" then return true end
              return nil, "Native execution was not ruled out"
            end,
            start = function(relay)
          if failure == "timer allocation" then
            vim.uv.new_timer = function() return nil end
          elseif failure == "pipe allocation" then
            vim.uv.new_pipe = function() return nil end
          elseif failure == "spawn exception" then
            vim.uv.spawn = function() error("native launch result unavailable") end
          elseif failure == "output observation" then
            vim.uv.read_start = function() return nil, "EIO" end
          end
          local launched, host = pcall(workers.start, {
            argv = failure == "missing executable" and { vim.fs.joinpath(assert(vim.uv.cwd()), "__missing_native_host__") }
              or { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n" },
            cwd = assert(vim.uv.cwd()), env = {}, clear_env = false, kill_grace_ms = 0,
            on_stdout = function(bytes) relay:feed(bytes) end,
            on_exit = function(result) relay:host_exited(result) end,
          })
          vim.uv.new_timer, vim.uv.new_pipe, vim.uv.spawn, vim.uv.read_start = new_timer, new_pipe, spawn, read_start
          if not launched then error(host, 0) end
          hosts[#hosts + 1] = host
          relay:attach(host)
            end,
          })
          return relay
        end,
      },
      nvim = vim.v.progpath,
    })
    owner = sessions.new({ capacity = 1 }, nil, require("neoagent.sandbox.process_session").factory(placement, {}))
  end)

  after_each(function()
    vim.uv.new_timer, vim.uv.new_pipe, vim.uv.spawn, vim.uv.read_start = new_timer, new_pipe, spawn, read_start
    owner:close("failed-host test finished")
    helper.complete(function() return owner:wait_cleanup(5000) end, 6000)
    for _, host in ipairs(hosts) do
      host:dispose("failed-host test finished")
      assert.is_true(helper.complete(function() return host:wait_release() end, 5000))
    end
  end)

  for _, mode in ipairs({ "timer allocation", "pipe allocation", "missing executable" }) do
    it("reuses capacity after " .. mode .. " prevents native host execution", function()
      failure = mode
      for attempt = 1, 3 do
        local result = helper.complete(function()
          return helper.admit(owner, helper.spec("unused", { argv = { vim.v.progpath } }), 0)
        end)
        assert.is_false(result.ok)
        assert.are.equal(attempt, #hosts, vim.inspect(result))
        local host_result = helper.success(function() return assert(hosts[#hosts]):wait() end)
        assert.are.equal("worker_start", assert(host_result.error).kind)
        helper.complete(function() return owner:wait_cleanup(1000) end, 2000)
        assert(vim.wait(1000, function() return owner:status().reserved == 0 end, 5), vim.inspect(owner:status()))
        assert.are.equal(0, owner:status().quarantined)
        assert.is_nil(owner:status().cleanup_error)
      end
      assert.are.equal(3, #hosts)
    end)
  end

  for _, mode in ipairs({ "output observation", "spawn exception" }) do
    it("keeps authority quarantined when " .. mode .. " cannot rule out execution", function()
      failure = mode
      local result = helper.complete(function()
        return helper.admit(owner, helper.spec("unused", { argv = { vim.v.progpath } }), 0)
      end)
      assert.is_false(result.ok)
      assert.are.equal(1, #hosts, vim.inspect(result))
      helper.complete(function() return owner:wait_cleanup(1000) end, 2000)
      assert(vim.wait(1000, function() return owner:status().quarantined == 1 end, 5), vim.inspect(owner:status()))
      assert.are.equal(1, owner:status().reserved)
      assert.are.equal("Native execution was not ruled out", assert(owner:status().cleanup_error).detail)
    end)
  end
end)
