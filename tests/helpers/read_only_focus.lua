local config = require("neoagent.config")
local ui = require("neoagent.ui")
local view_handles = require("tests.helpers.view_handles")

local surface = assert(vim.env.NEOAGENT_FOCUS_SURFACE,
  "read-only surface is required")
assert(surface == "transcript" or surface == "provider",
  "read-only surface must be transcript or provider")

local configured = config.setup({
    persistence = { enabled = false },
    ui = { position = "center" },
  }).ui
local view = ui.new({
  config = configured,
})
assert(view:open())
local shell
if surface == "provider" then
  shell = require("neoagent.ui.provider_shell").new({ config = configured })
  assert(shell:set({
    id = "fake",
    name = "Fake provider",
    state = { blocks = {
      { type = "status", text = "ready", level = "success" },
    } },
    operations = {},
  }, {
    { id = "fake", name = "Fake provider", selected = true, enabled = true },
  }))
  assert(shell:open())
end

local function finish(ok, err)
  vim.cmd("stopinsert")
  if shell then shell:destroy() end
  view:destroy()
  if not ok then
    io.stderr:write(tostring(err) .. "\n")
    vim.cmd("cquit 1")
    return
  end
  vim.cmd("qa!")
end

view:focus_input()
vim.defer_fn(function()
  local ok, err = xpcall(function()
    assert(vim.api.nvim_get_mode().mode:sub(1, 1) == "i",
      "input did not enter Insert mode")
    local target = surface == "provider"
      and assert(shell:pane("provider")):native().window
      or view_handles.window(view, "transcript")
    vim.api.nvim_set_current_win(target)
  end, debug.traceback)
  if not ok then finish(false, err) return end

  local normal, mode_err = xpcall(function()
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_mode().mode == "n"
    end), surface .. " retained Insert mode after direct focus")
  end, debug.traceback)
  finish(normal, mode_err)
end, 20)
