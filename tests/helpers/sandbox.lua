local async = require("neoagent.async")

local M = {}
local leases = {}

---@class Neoagent.TestSandboxCommandOptions: Neoagent.ProcessOptions, Neoagent.SandboxCheckServices
---@field profile Neoagent.SandboxProfile
---@field os? string
---@field env table<string, string>
---@field cwd string

-- Native enforcement scenarios exercise the launcher's streaming lease.
-- Tool scenarios use the interceptor and real Tool RPC server separately.
---@async
---@param argv string[]
---@param opts Neoagent.TestSandboxCommandOptions
---@return Neoagent.ProcessResult
function M.execute(argv, opts)
  local platform = assert(require("neoagent.sandbox.platform").select(opts.os))
  local paths = platform.paths or require("neoagent.sandbox.path").posix
  local profile = require("neoagent.sandbox.profile").resolve(opts.profile, nil, { paths = paths })
  local services = {
    fs = require("neoagent.fs"),
    nvim = opts.nvim or vim.env.NEOAGENT_NVIM,
    capabilities = opts.capabilities,
  }
  if not services.capabilities then
    local status = platform.check(services)
    assert(status.ok, status.message)
    services.capabilities = status.capabilities
  end
  if platform.compile then
    profile = platform.compile(profile, nil, services)
  end
  local stdout, stderr, output = "", "", ""
  local function receive(data, is_stderr)
    if opts.capture ~= false then
      if is_stderr then
        stderr = stderr .. data
      else
        stdout = stdout .. data
      end
      output = output .. data
    end
    if opts.on_output then
      opts.on_output(data, is_stderr, stdout, stderr, output)
    end
  end
  local lease = platform.start_worker({
    argv = argv,
    cwd = opts.cwd,
    env = opts.env,
    profile = profile,
    kill_grace_ms = opts.kill_grace_ms,
    on_stdout = function(data)
      receive(data, false)
    end,
    on_stderr = function(data)
      receive(data, true)
    end,
  }, services)
  leases[#leases + 1] = lease
  local timed_out = false
  local timer
  local completed, value = pcall(function()
    if lease.wait_ready then
      lease:wait_ready()
    end
    if opts.timeout_ms then
      timer = assert(vim.uv.new_timer())
      timer:start(opts.timeout_ms, 0, function()
        timed_out = true
        lease:dispose("native command deadline")
      end)
    end
    if type(opts.stdin) == "string" and opts.stdin ~= "" then
      assert(lease:write(opts.stdin))
    end
    assert(lease:close_stdin())
    return lease:wait()
  end)
  if timer then
    timer:stop()
    timer:close()
  end
  if not completed then
    lease:dispose("native command failed or was cancelled")
    error(value, 0)
  end
  if value.error and not timed_out then
    error(value.error, 0)
  end
  return {
    code = value.code,
    signal = value.signal,
    stdout = stdout,
    stderr = stderr,
    output = output,
    timed_out = timed_out,
  }
end

function M.cleanup()
  for _, lease in ipairs(leases) do
    lease:dispose("native scenario teardown")
    local run = async.run(function()
      return lease:wait()
    end)
    assert(
      vim.wait(10000, function()
        return run:is_done()
      end, 5),
      "native lease cleanup did not settle"
    )
  end
  leases = {}
end

return M
