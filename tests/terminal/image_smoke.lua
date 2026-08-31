local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.termguicolors = true
vim.cmd("highlight Normal guifg=#ffffff guibg=#000000")
vim.cmd("highlight SmokeBorder guifg=#00ff00 guibg=#000000")

local Applet = require("applet")
local ui = Applet.Pane.nodes
local backend = assert(vim.env.NEOAGENT_IMAGE_SMOKE_BACKEND)
local source_path = assert(vim.env.NEOAGENT_IMAGE_SMOKE_SOURCE)
local ready_path = assert(vim.env.NEOAGENT_IMAGE_SMOKE_READY)
local stop_path = assert(vim.env.NEOAGENT_IMAGE_SMOKE_STOP)
local state_path = assert(vim.env.NEOAGENT_IMAGE_SMOKE_STATE)
assert(backend == "kitty", "invalid image smoke backend")

local images = require("applet.image").new({
  backend = backend,
})
local kitty = images.backend
local source = {
  kind = "png_file",
  path = source_path,
  revision = 1,
}
local errors = {}
local pane = Applet.Pane.new({
  key = "terminal-image-smoke",
  image_system = images,
  on_error = function(err) errors[#errors + 1] = err end,
})
local buffer = vim.api.nvim_create_buf(false, true)
local width = math.min(80, math.max(20, vim.o.columns - 6))
local height = math.min(24, math.max(10, vim.o.lines - vim.o.cmdheight - 6))
local window = vim.api.nvim_open_win(buffer, true, {
  relative = "editor",
  row = 2,
  col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  width = width,
  height = height,
  style = "minimal",
  border = "single",
})
vim.wo[window].winhighlight = "Normal:Normal,FloatBorder:SmokeBorder"
pane:_connect({
  buffer = buffer,
  window = function() return window end,
  owns_buffer = true,
  buffer_options = { buftype = "nofile" },
  window_options = { wrap = false },
})
local function move(lines)
  if not vim.api.nvim_win_is_valid(window) then return end
  vim.api.nvim_win_call(window, function()
    vim.cmd(("normal! %d%s"):format(math.abs(lines), lines < 0 and "k" or "j"))
  end)
end
vim.keymap.set("n", "<M-j>", function() move(8) end, {
  buffer = buffer,
  nowait = true,
})
vim.keymap.set("n", "<M-k>", function() move(-8) end, {
  buffer = buffer,
  nowait = true,
})
pane:update(ui.panel({
  key = "image:panel",
  padding = { left = 4 },
  child = ui.column({
    key = "transcript",
    gap = 1,
    children = {
      ui.text({
        key = "before",
        text = table.concat(vim.fn.map(vim.fn.range(1, 6),
          function(_, value) return "before image " .. value end), "\n"),
      }),
      ui.image({
        key = "image",
        source = source,
        alt = "terminal image smoke",
        width = "native",
        height = "auto",
        fit = "fill",
        align = "left",
      }),
      ui.text({
        key = "after",
        text = table.concat(vim.fn.map(vim.fn.range(1, 24),
          function(_, value) return "after image " .. value end), "\n"),
      }),
    },
  }),
}))
assert(pane:flush())

local rendered = vim.wait(5000, function()
  if #errors > 0 then error(vim.inspect(errors), 0) end
  pane:flush()
  local presented = images:snapshot(pane).presented.image
  local owner = kitty.owners[pane]
  return presented and owner and #owner.placements > 0
end, 10)
assert(rendered, backend .. " image did not become ready")

local image = assert(pane.layout.images.image)
local function placement()
  local owner = kitty.owners[pane]
  for _, value in ipairs(owner and owner.placements or {}) do
    if value.key == "image" then return value end
  end
end

local function placement_state()
  local value = placement()
  return value and {
    key = value.key,
    id = value.id,
    content_id = value.record.content_id,
    geometry = value.geometry,
  } or nil
end

local function scroll(line, visible)
  vim.api.nvim_win_call(window, function()
    vim.api.nvim_win_set_cursor(0, {
      math.max(1, math.min(line, vim.api.nvim_buf_line_count(buffer))), 0,
    })
    vim.cmd("normal! zt")
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", {})
  assert(vim.wait(2000, function()
    if #errors > 0 then error(vim.inspect(errors), 0) end
    pane:flush()
    return (placement() ~= nil) == visible
  end, 10), ("image placement did not follow transcript scrolling "
    .. "at line %d (topline %d, visible %s, window %dx%d, image %d:%d %dx%d)")
    :format(line, vim.fn.getwininfo(window)[1].topline, tostring(visible),
      vim.api.nvim_win_get_width(window), vim.api.nvim_win_get_height(window),
      image.row, image.col, image.width, image.height))
  vim.cmd("redraw")
end

assert(vim.wait(10000, function()
  if #errors > 0 then error(vim.inspect(errors), 0) end
  pane:flush()
  local marks = vim.api.nvim_buf_get_extmarks(
    buffer, pane.image_namespace, 0, -1, {})
  local current = placement()
  return current and current.record.content_id ~= nil
    and #marks == 0
    and kitty.output_operation == nil
end, 10), "Kitty direct placement did not finish")

for _ = 1, 12 do
  scroll(image.row + image.height + 2, false)
  scroll(image.row + 1, true)
end
local image_line = vim.api.nvim_buf_get_lines(
  buffer, image.row, image.row + 1, false)[1] or ""
local function ready_state()
  local current_placement = placement()
  return {
    image = image,
    placement = placement_state(),
    position = vim.fn.screenpos(window, image.row + 1,
      require("applet.util").byte_col(image_line, image.col) + 1),
    marks = vim.api.nvim_buf_get_extmarks(
      buffer, pane.image_namespace, 0, -1, { details = true }),
    geometry = current_placement and current_placement.geometry or nil,
    window = vim.fn.getwininfo(window)[1],
    cells = kitty.cell_dimensions and kitty:cell_dimensions() or nil,
    stats = images:_stats(),
  }
end

local timer = vim.uv.new_timer()
local started = vim.uv.hrtime()
local last_state = 0
local repaint_started = false
local ready_written = false
local function write_state()
  vim.fn.writefile({ vim.json.encode({
    backend = images:snapshot(pane).backend,
    presented = images:snapshot(pane).presented,
    pending = vim.tbl_count(kitty.pending),
    scheduled = kitty.output_operation ~= nil,
    placement = placement_state(),
    stats = images:_stats(),
    window = vim.fn.getwininfo(window)[1],
    cursor = vim.api.nvim_win_get_cursor(window),
    errors = errors,
  }) }, state_path)
end
local function finish(command)
  timer:stop()
  timer:close()
  pane:destroy()
  images:destroy()
  vim.cmd(command)
end
timer:start(10, 10, vim.schedule_wrap(function()
  local now = vim.uv.hrtime()
  if not repaint_started then
    repaint_started = true
    pane.force_images = true
    pane:flush()
  elseif not ready_written and kitty.output_operation == nil
      and next(kitty.pending) == nil then
    ready_written = true
    vim.fn.writefile({ vim.json.encode(ready_state()) }, ready_path)
  end
  if now - last_state >= 100 * 1e6 then
    last_state = now
    write_state()
  end
  if vim.fn.filereadable(stop_path) == 1 then
    finish("qa!")
  elseif vim.uv.hrtime() - started > 15 * 1e9 then
    vim.api.nvim_err_writeln("terminal image smoke agent timed out")
    finish("cquit")
  end
end))
