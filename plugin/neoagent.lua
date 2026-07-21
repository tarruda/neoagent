if vim.g.loaded_neoagent then return end
vim.g.loaded_neoagent = true

vim.api.nvim_create_user_command("Neoagent", function() require("neoagent").toggle() end, {})
vim.api.nvim_create_user_command("NeoagentNew", function() require("neoagent").new_session() end, {})
vim.api.nvim_create_user_command("NeoagentResume", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.resume() return end
  if neoagent.resume(opts.args) then neoagent.open() end
end, {
  nargs = "?", complete = "file",
})
vim.api.nvim_create_user_command("NeoagentStop", function() require("neoagent").stop() end, {})
vim.api.nvim_create_user_command("NeoagentModel", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.select_model() return end
  local provider, model = opts.args:match("^([^/]+)/(.+)$")
  if not provider then vim.notify("neoagent: expected provider/model", vim.log.levels.ERROR) return end
  if neoagent.set_model(provider, model) then neoagent.open() end
end, { nargs = "?" })
