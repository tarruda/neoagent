if vim.g.loaded_neoagent then return end
vim.g.loaded_neoagent = true

local function toggle() return require("neoagent").toggle() end
local function cycle() return require("neoagent").show_agents() end
local function report_error(err)
  if not err then return end
  local message = type(err) == "table" and err.message or tostring(err)
  if type(message) ~= "string" then message = tostring(err) end
  if type(err) == "table" and err.detail then
    message = message .. ": " .. tostring(err.detail)
  end
  require("neoagent").notify(message, vim.log.levels.ERROR)
end

vim.api.nvim_create_user_command("Neoagent", toggle, {})
local function map(lhs, callback, desc)
  vim.keymap.set("n", lhs, callback, { silent = true, desc = desc })
end
map("<Plug>(NeoagentToggle)", toggle, "Toggle Neoagent")
map("<Plug>(NeoagentCycle)", cycle, "Select a Neoagent Agent")
vim.api.nvim_create_user_command("NeoagentCycle", cycle, {})
vim.api.nvim_create_user_command("NeoagentResume", function(opts)
  local neoagent = require("neoagent")
  local resumed, err = neoagent.resume(
    opts.args ~= "" and opts.args or nil)
  if resumed and opts.args ~= "" then neoagent.open() end
  if not resumed then report_error(err) end
end, {
  nargs = "?", complete = "file",
})
vim.api.nvim_create_user_command("NeoagentCopySession", function()
  local copied, err = require("neoagent").copy_session()
  if not copied then report_error(err) end
end, {})
vim.api.nvim_create_user_command("NeoagentStop", function() require("neoagent").stop() end, {})
vim.api.nvim_create_user_command("NeoagentSandboxInfo", function()
  require("neoagent").show_sandbox_info()
end, {})
vim.api.nvim_create_user_command("NeoagentToggleSandbox", function()
  require("neoagent").toggle_sandbox()
end, {})
-- One user-command argument preserves the complete raw tail, including spaces.
vim.api.nvim_create_user_command("NeoagentCompact", function(opts)
  require("neoagent").compact(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })
vim.api.nvim_create_user_command("NeoagentBranch", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.select_branch() else neoagent.branch(opts.args) end
end, { nargs = "?" })
vim.api.nvim_create_user_command("NeoagentFork", function(opts)
  local neoagent = require("neoagent")
  local forked, err
  if opts.args == "" then
    forked, err = neoagent.select_fork()
  else
    forked, err = neoagent.fork(opts.args, "before")
  end
  if not forked then report_error(err) end
end, { nargs = "?" })
vim.api.nvim_create_user_command("NeoagentModel", function(opts)
  local neoagent = require("neoagent")
  if opts.args == "" then neoagent.select_model() return end
  local provider, model = opts.args:match("^([^/]+)/(.+)$")
  if not provider then
    neoagent.notify("expected provider/model", vim.log.levels.ERROR)
    return
  end
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
  local shell = neoagent.applet():provider_shell()
  if not shell then return {} end
  local before = type(command_line) == "string"
    and command_line:sub(1, cursor_pos or #command_line) or ""
  local tail = before:match("^%s*NeoagentProvider!?%s+(.*)$") or ""
  local operation, args = tail:match("^(%S+)%s+(.*)$")
  if operation then
    return shell:completion(operation, arg_lead, args)
  end
  local operations = shell:operations()
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
  local shell = neoagent.applet():provider_shell()
  if not shell then return end
  if opts.bang then
    shell:cancel()
  elseif opts.args == "" then
    neoagent.toggle_provider_shell()
  else
    local operation, args = opts.args:match("^(%S+)%s*(.*)$")
    shell:run(operation, args ~= "" and args or nil)
  end
end, {
  -- Provider operation arguments form one raw tail after the operation ID.
  nargs = "?",
  bang = true,
  complete = provider_operation_completion,
})
