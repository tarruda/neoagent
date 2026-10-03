local async = require("neoagent.async")
local subprocess = require("neoagent.subprocess_common")
local root = assert(arg[1])
local stop = root .. "/stop"
local scope = subprocess.scope()
local workers, completed, failures = {}, 0, {}

-- Each libuv worker has its own Lua state but shares libc and the process.
-- Keep native allocation and filesystem work active across the main VM's fork.
local function work(directory, marker, stop_file)
  local uv = require("luv")
  local ffi = require("ffi")
  ffi.cdef("void *malloc(unsigned long); void free(void *);")
  local descriptor = assert(uv.fs_open(marker, "w", 384))
  assert(uv.fs_close(descriptor))
  local deadline = uv.hrtime() + 15e9
  local rounds = 0
  while not uv.fs_stat(stop_file) and uv.hrtime() < deadline do
    local memory = assert(ffi.C.malloc(32768))
    ffi.fill(memory, 32768, 65)
    ffi.C.free(memory)
    assert(uv.fs_stat(directory))
    rounds = rounds + 1
    uv.sleep(1)
  end
  return rounds
end

for index = 1, 4 do
  local worker = vim.uv.new_work(work, function(rounds)
    completed = completed + 1
    if not rounds or rounds < 1 then
      failures[#failures + 1] = "native worker did not run"
    end
  end)
  workers[#workers + 1] = worker
  worker:queue(root, root .. "/worker-" .. index, stop)
end

local ok, failure = pcall(function()
  assert(
    vim.wait(3000, function()
      for index = 1, 4 do
        if not vim.uv.fs_stat(root .. "/worker-" .. index) then
          return false
        end
      end
      return true
    end, 5),
    "native workers did not start"
  )
  local invalid = root .. "/bad-interpreter"
  vim.fn.writefile({ "#!/neoagent-missing-interpreter" }, invalid)
  assert(vim.uv.fs_chmod(invalid, 448))
  local run = async.run(function()
    for index = 1, 48 do
      ---@type Neoagent.SubprocessSpec
      local spec = {
        argv = { "/bin/sh", "-c", "test -t 0 && test -t 1 && test -t 2 && printf ready; exit 23" },
        cwd = root,
        stdio = { kind = "pty", columns = 80, rows = 24 },
        timeout_ms = 2000,
      }
      if index % 3 == 0 then
        spec.argv = { invalid }
        local started, err = pcall(scope.spawn, scope, spec)
        assert(not started and type(err) == "table" and rawget(err, "code") == "process_start", vim.inspect(err))
      else
        local result = scope:run(spec, { capture = { max_bytes = 1024 } })
        assert(result.code == 23 and result.output == "ready", vim.inspect(result))
      end
      assert(completed == 0, "worker pressure ended before spawning completed")
      collectgarbage("collect")
    end
  end)
  assert(
    vim.wait(10000, function()
      return run:is_done()
    end, 5),
    "PTY stress did not settle"
  )
  local result = assert(run:result())
  assert(result.ok ~= false, vim.inspect(result))
end)

vim.fn.writefile({ "stop" }, stop)
scope:close("stress finished")
local cleanup = async.run(function()
  return scope:wait(4000)
end)
assert(
  vim.wait(5000, function()
    return completed == #workers and cleanup:is_done()
  end, 5),
  "stress resources did not settle"
)
assert(cleanup:result() == true, vim.inspect(cleanup:result()))
assert(#failures == 0, table.concat(failures, "; "))
assert(ok, vim.inspect(failure))
io.stdout:write("48 PTY starts under native worker pressure completed\n")
io.stdout:flush()
vim.cmd("qa!")
