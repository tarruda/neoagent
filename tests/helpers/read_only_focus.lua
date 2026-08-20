local config = require("neoagent.config")
local ui = require("neoagent.ui")

local surface = assert(vim.env.NEOAGENT_FOCUS_SURFACE,
  "read-only surface is required")
assert(surface == "transcript" or surface == "provider",
  "read-only surface must be transcript or provider")

local view = ui.new({
  config = config.setup({
    persistence = { enabled = false },
    ui = { position = "center" },
  }).ui,
})
view:set_provider({
  id = "fake",
  name = "Fake provider",
  state = { blocks = {
    { type = "status", text = "ready", level = "success" },
  } },
  operations = {},
})
assert(view:open())
assert(view:set_provider_open(true))

local function finish(ok, err)
  vim.cmd("stopinsert")
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
      and view.provider_win or view.transcript_win
    vim.api.nvim_set_current_win(target)
  end, debug.traceback)
  if not ok then finish(false, err) return end

  vim.defer_fn(function()
    local normal, mode_err = xpcall(function()
      assert(vim.api.nvim_get_mode().mode == "n",
        surface .. " retained Insert mode after direct focus")
    end, debug.traceback)
    finish(normal, mode_err)
  end, 20)
end, 20)
