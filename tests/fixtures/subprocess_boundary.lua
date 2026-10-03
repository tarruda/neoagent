-- Install the boundary before loading any product modules. A fresh Neovim
-- prevents a previously cached dependency from bypassing the loader.
local blocked = {
  "neoagent.rpc",
  "neoagent.sandbox",
  "neoagent.tools",
  "neoagent.agent",
  "neoagent.session",
  "neoagent.provider",
  "neoagent.authentication",
  "applet",
  "neoagent.ui",
}
table.insert(package.loaders, 1, function(name)
  for _, prefix in ipairs(blocked) do
    if name:sub(1, #prefix) == prefix then
      error("forbidden dependency: " .. name)
    end
  end
end)

local subprocess = require("neoagent.subprocess_common")
local run = require("neoagent.async").run(function()
  return subprocess.run({
    argv = { "sh", "-c", "printf local" },
    cwd = assert(vim.uv.cwd()),
    stdio = { kind = "pipes" },
    timeout_ms = 1000,
  }, { capture = { max_bytes = 10 } })
end)
assert(
  vim.wait(5000, function()
    return run:is_done()
  end, 5),
  "local process did not settle"
)
local result = assert(run:result())
assert(result.ok ~= false, vim.inspect(result))
assert(result.code == 0, vim.inspect(result))
io.stdout:write(result.stdout)
