if vim.g.loaded_neoagent then return end
vim.g.loaded_neoagent = true

vim.api.nvim_create_user_command("Neoagent", function() require("neoagent").toggle() end, {})
vim.api.nvim_create_user_command("NeoagentNew", function() require("neoagent").new_session() end, {})
vim.api.nvim_create_user_command("NeoagentResume", function(opts) require("neoagent").resume(opts.args ~= "" and opts.args or nil) end, {
  nargs = "?", complete = "file",
})
vim.api.nvim_create_user_command("NeoagentStop", function() require("neoagent").stop() end, {})
vim.api.nvim_create_user_command("NeoagentModel", function(opts)
  local provider, model = opts.args:match("^([^/]+)/(.+)$")
  if not provider then vim.notify("neoagent: expected provider/model", vim.log.levels.ERROR) return end
  require("neoagent").set_model(provider, model)
end, { nargs = 1 })
