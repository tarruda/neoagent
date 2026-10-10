-- Run inside the actual restricted Neovim. Keep libuv's native pipe creation
-- distinct from child execution so permission failures identify their boundary.
local results = {}
for _, nonblock in ipairs({ false, true }) do
  local pair, err = vim.uv.pipe({ nonblock = nonblock }, { nonblock = nonblock })
  results["pipe-" .. tostring(nonblock)] = pair and true or err
  if pair then
    for _, descriptor in ipairs({ pair.read, pair.write }) do
      local handle = assert(vim.uv.new_pipe(false))
      local opened, open_error = handle:open(descriptor)
      if not opened then results["pipe-" .. tostring(nonblock)] = open_error end
      handle:close()
    end
  end
end
for _, redirected in ipairs({ false, true }) do
  ---@type uv.uv_pipe_t[]
  local pipes = {}
  ---@type { [1]: uv.spawn.options.stdio, [2]: uv.spawn.options.stdio, [3]: uv.spawn.options.stdio }
  local stdio = { 0, 1, 2 }
  if redirected then
    for index = 1, 3 do
      pipes[index] = assert(vim.uv.new_pipe(false))
    end
    stdio = { pipes[1], pipes[2], pipes[3] }
  end
  local done = false
  local code
  local process, err = vim.uv.spawn("cmd.exe", {
    args = { "/d", "/c", "exit 0" }, stdio = stdio,
    cwd = assert(vim.uv.cwd()), detached = false, hide = false, verbatim = false,
  }, function(value)
    done, code = true, value
  end)
  for _, pipe in ipairs(pipes) do pipe:close() end
  if process then
    if not vim.wait(5000, function() return done end, 5) then
      process:kill(9)
      assert(vim.wait(5000, function() return done end, 5), "child termination did not settle")
    end
    process:close()
    results["spawn-" .. tostring(redirected)] = code == 0 and true or code
  else
    results["spawn-" .. tostring(redirected)] = err
  end
end
io.stdout:write(vim.json.encode(results), "\n")
io.stdout:flush()
