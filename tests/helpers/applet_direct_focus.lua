local Applet = require("applet")
local layout = Applet.layout
local ui = Applet.Pane.nodes

local host_kind = assert(vim.env.APPLET_HOST, "Applet Host is required")
assert(host_kind == "floating" or host_kind == "tab",
  "Applet Host must be floating or tab")

local function component(name, mode)
  local value = Applet.Pane.new({
    key = name,
    buffer_mode = mode,
    render = function()
      return ui.text({
        key = "content",
        text = name == "first" and "first\nmiddle\nlast" or name,
      })
    end,
  })
  value:set_state({})
  return value
end

local first = component("first", "managed")
local second = component("second", "editable")
local host = host_kind == "floating"
    and Applet.host.floating({ width = 60, height = 20 })
  or Applet.host.tab({ label = "Direct focus" })
local applet = Applet.new({ name = "direct-focus", host = host })
applet:update({
  root = layout.frame({
    key = "frame",
    child = layout.split({
      key = "main",
      axis = "vertical",
      children = {
        { key = "first", grow = 1, child = layout.mount(first, {
          required = true,
          buffer = { name = "first" }, focus = { mode = "normal" },
        }) },
        { key = "second", basis = 3, grow = 0, child = layout.mount(second, {
          required = true,
          buffer = { name = "second" }, focus = { mode = "insert" },
        }) },
      },
    }),
  }),
  bindings = {
    {
      mode = "n",
      lhs = "K",
      action = ui.action("applet.focus", { pane = "first" }),
    },
  },
  focus = { initial = "second" },
})
assert(applet:open())

local function finish(ok, err)
  vim.cmd("stopinsert")
  applet:destroy()
  first:destroy()
  second:destroy()
  if not ok then
    io.stderr:write(tostring(err) .. "\n")
    vim.cmd("cquit 1")
  else
    vim.cmd("qa!")
  end
end

local function await(predicate, message)
  local deadline = vim.uv.hrtime() + 1000000000
  while not predicate() do
    if vim.uv.hrtime() >= deadline then error(message, 2) end
    coroutine.yield()
  end
end

local task = coroutine.create(function()
  local ok, err = xpcall(function()
    await(function()
      return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
    end, "editable Pane did not enter Insert mode")
    vim.cmd("stopinsert")
    await(function() return vim.api.nvim_get_mode().mode == "n" end,
      "editable Pane did not retain user-selected Normal mode")

    local first_window = applet:pane("first"):native().window
    local second_window = applet:pane("second"):native().window
    vim.api.nvim_set_current_win(first_window)
    await(function()
      return vim.api.nvim_get_current_win() == first_window
        and applet:focused_pane() == "first"
        and vim.api.nvim_get_mode().mode == "n"
    end, "managed Pane did not settle after direct focus")

    vim.api.nvim_set_current_win(second_window)
    await(function()
      return vim.api.nvim_get_current_win() == second_window
        and applet:focused_pane() == "second"
        and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
    end, "editable Pane did not restore Insert mode")

    vim.api.nvim_win_set_cursor(first_window, { 1, 0 })
    vim.api.nvim_input(vim.api.nvim_replace_termcodes(
      "<C-o>KG", true, false, true))
    await(function()
      return vim.api.nvim_get_current_win() == first_window
        and applet:focused_pane() == "first"
        and vim.api.nvim_get_mode().mode == "n"
    end, "managed Pane retained temporary Insert intent")
    assert(vim.api.nvim_win_get_cursor(first_window)[1] == 3,
      "managed Pane handled G as Insert-mode input")
  end, debug.traceback)
  finish(ok, err)
end)

local function pump()
  if coroutine.status(task) == "dead" then return end
  local ok, err = coroutine.resume(task)
  if not ok then finish(false, debug.traceback(task, err)) return end
  if coroutine.status(task) ~= "dead" then vim.defer_fn(pump, 5) end
end

pump()
