if vim.g.loaded_neoagent then return end
vim.g.loaded_neoagent = true

vim.api.nvim_create_user_command("Neoagent", function() require("neoagent").toggle() end, {})
vim.api.nvim_create_user_command("NeoagentCycle", function() require("neoagent").cycle_agent() end, {})
vim.api.nvim_create_user_command("NeoagentNew", function() require("neoagent").new_session() end, {})
vim.api.nvim_create_user_command("NeoagentResume", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.resume() return end
  if neoagent.resume(opts.args) then neoagent.open() end
end, {
  nargs = "?", complete = "file",
})
vim.api.nvim_create_user_command("NeoagentStop", function() require("neoagent").stop() end, {})
vim.api.nvim_create_user_command("NeoagentSandboxInfo", function()
  require("neoagent").show_sandbox_info()
end, {})
vim.api.nvim_create_user_command("NeoagentToggleSandbox", function()
  require("neoagent").toggle_sandbox()
end, {})
vim.api.nvim_create_user_command("NeoagentCompact", function(opts)
  require("neoagent").compact(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })
vim.api.nvim_create_user_command("NeoagentBranch", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.select_branch() else neoagent.branch(opts.args) end
end, { nargs = "?" })
vim.api.nvim_create_user_command("NeoagentFork", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.select_fork() return end
  local forked, selected_text = neoagent.fork(opts.args, "before")
  if forked then
    neoagent.default_window():set_input(selected_text or "")
    neoagent.open()
  end
end, { nargs = "?" })
vim.api.nvim_create_user_command("NeoagentModel", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.select_model() return end
  local provider, model = opts.args:match("^([^/]+)/(.+)$")
  if not provider then vim.notify("neoagent: expected provider/model", vim.log.levels.ERROR) return end
  if neoagent.set_model(provider, model) then neoagent.open() end
end, { nargs = "?" })
vim.api.nvim_create_user_command("NeoagentThinking", function(opts)
  local neoagent = require("neoagent")
  local level = opts.args == "" and neoagent.cycle_thinking_level() or neoagent.set_thinking_level(opts.args)
  if level then neoagent.open() end
end, {
  nargs = "?",
  complete = function() return require("neoagent.thinking").order end,
})
vim.api.nvim_create_user_command("NeoagentPosition", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.select_position() else neoagent.set_position(opts.args) end
end, {
  nargs = "?",
  complete = function() return { "auto", "left", "right", "top", "bottom", "center" } end,
})
vim.api.nvim_create_user_command("NeoagentTranscriptStyle", function(opts)
  require("neoagent").set_transcript_style(opts.args)
end, {
  nargs = 1,
  complete = function() return require("neoagent.ui.renderers").names() end,
})
local function provider_operation_completion(arg_lead, command_line, cursor_pos)
  local neoagent = require("neoagent")
  local before = type(command_line) == "string"
    and command_line:sub(1, cursor_pos or #command_line) or ""
  local tail = before:match("^%s*NeoagentProvider!?%s+(.*)$") or ""
  local operation, args = tail:match("^(%S+)%s+(.*)$")
  if operation then
    return neoagent.provider_completion(operation, arg_lead, args)
  end
  local operations = neoagent.provider_operations() or {}
  local result = {}
  for _, operation in ipairs(operations) do
    if arg_lead == "" or vim.startswith(operation.id, arg_lead) then
      result[#result + 1] = operation.id
    end
  end
  return result
end

vim.api.nvim_create_user_command("NeoagentProvider", function(opts)
  local neoagent = require("neoagent")
  if opts.bang then
    neoagent.cancel_provider()
  elseif opts.args == "" then
    neoagent.provider_console()
  else
    local operation, args = opts.args:match("^(%S+)%s*(.*)$")
    neoagent.provider(operation, args ~= "" and args or nil)
  end
end, {
  nargs = "?",
  bang = true,
  complete = provider_operation_completion,
})
local function auth_method_completion()
  local methods = require("neoagent").default():config().auth.methods
  local result = {}
  for id in pairs(methods) do result[#result + 1] = id end
  table.sort(result)
  return result
end

vim.api.nvim_create_user_command("NeoagentLogin", function(opts)
  local neoagent = require("neoagent")
  if opts.bang then neoagent.cancel_login() else neoagent.login(opts.args) end
end, {
  nargs = "?",
  bang = true,
  complete = auth_method_completion,
})
vim.api.nvim_create_user_command("NeoagentLogout", function(opts)
  require("neoagent").logout(opts.args)
end, {
  nargs = "?",
  complete = auth_method_completion,
})
