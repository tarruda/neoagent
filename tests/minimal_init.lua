local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/.deps/luacov/src/?.lua;" .. root .. "/.deps/luacov/src/?/init.lua;" .. package.path

local plenary = vim.env.PLENARY_DIR
if not plenary or plenary == "" then
  plenary = root .. "/.deps/plenary.nvim"
end
assert(vim.fn.isdirectory(plenary) == 1, "Plenary not found; run `make deps` or set PLENARY_DIR")
vim.opt.runtimepath:prepend(plenary)
vim.cmd("runtime plugin/plenary.vim")

vim.env.XDG_CONFIG_HOME = root .. "/.test-data/config"
vim.env.XDG_DATA_HOME = root .. "/.test-data/data"
vim.env.XDG_STATE_HOME = root .. "/.test-data/state"
vim.env.XDG_CACHE_HOME = root .. "/.test-data/cache"
vim.opt.shadafile = "NONE"

if vim.env.NEOAGENT_COVERAGE == "1" then
  vim.fn.mkdir(root .. "/.coverage", "p")
  local runner = require("luacov.runner")
  runner((vim.env.LUACOV_CONFIG or (root .. "/.luacov")))
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function() runner.shutdown() end,
  })
end
