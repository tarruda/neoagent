local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.termguicolors = true
vim.cmd("highlight Normal guifg=#ffffff guibg=#000000")
vim.cmd("highlight NormalFloat guifg=#ffffff guibg=#000000")
vim.cmd("highlight FloatBorder guifg=#00ff00 guibg=#000000")

local backend = assert(vim.env.NEOAGENT_IMAGE_HARNESS_BACKEND)
local layout_mode = vim.env.NEOAGENT_IMAGE_HARNESS_LAYOUT or "native"
local ready_path = assert(vim.env.NEOAGENT_IMAGE_HARNESS_READY)
local state_path = assert(vim.env.NEOAGENT_IMAGE_HARNESS_STATE)
local source_path = assert(vim.env.NEOAGENT_IMAGE_HARNESS_SOURCE)
local frame_dir = assert(vim.env.NEOAGENT_IMAGE_HARNESS_FRAME_DIR)
local stop_path = assert(vim.env.NEOAGENT_IMAGE_HARNESS_STOP)
local action_path = assert(vim.env.NEOAGENT_IMAGE_HARNESS_ACTION)
local lifecycle_path = assert(vim.env.NEOAGENT_IMAGE_HARNESS_LIFECYCLE)

local function lifecycle(event)
  vim.fn.writefile({ vim.json.encode({
    event = event,
    current_window = vim.api.nvim_get_current_win(),
    windows = vim.api.nvim_tabpage_list_wins(0),
    dying = vim.v.dying,
  }) }, lifecycle_path, "a")
end

vim.api.nvim_create_autocmd("WinClosed", {
  callback = function(event) lifecycle("WinClosed:" .. event.match) end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function() lifecycle("VimLeavePre") end,
})

assert(loadfile("scripts/applet-image-harness.lua"))()
local active = applet_image_harness(backend, layout_mode)
assert(active.fixture.palette_target == 256)
assert(active.fixture.true_color == true)
assert(vim.fn.mkdir(frame_dir, "p") == 1 or vim.fn.isdirectory(frame_dir) == 1)
local function write_source(path, data)
  local descriptor = assert(vim.uv.fs_open(path, "w", 384))
  assert(vim.uv.fs_write(descriptor, data, 0))
  assert(vim.uv.fs_close(descriptor))
end
write_source(source_path, active.fixture.png)
for index, frame in ipairs(active.fixture.frames) do
  write_source(frame_dir .. "/" .. index .. ".png", frame.png)
end

local errors = active.errors or {}
local layer_order = { "main", "detail", "badge" }

local function publish(path, value)
  local temporary = path .. ".tmp"
  assert(vim.fn.writefile({ vim.json.encode(value) }, temporary) == 0)
  assert(vim.uv.fs_rename(temporary, path))
end

local function layer_window(layer)
  return active.layer_window(layer)
end

local function placements(layer)
  layer = layer or active.layers.main
  local presentation = active.images.backend.owners[layer.pane]
  local result = {}
  for _, placement in ipairs(presentation and presentation.placements or {}) do
    if placement.key == layer.image_key then
      result[#result + 1] = placement
    end
  end
  return result
end

local function image_visible(layer)
  layer = layer or active.layers.main
  local window = layer_window(layer)
  if not window then return false end
  if vim.api.nvim_win_get_config(window).hide then return false end
  local image = layer.pane.layout
    and layer.pane.layout.images[layer.image_key]
  if not image then return false end
  local view = vim.api.nvim_win_call(window, vim.fn.winsaveview)
  local first_row = (view.topline or 1) - 1
  local first_col = view.leftcol or 0
  for _, rectangle in ipairs(image.visible or { {
    row = 0,
    col = 0,
    width = image.width,
    height = image.height,
  } }) do
    local row = image.row + rectangle.row
    local col = image.col + rectangle.col
    if row < first_row + vim.api.nvim_win_get_height(window)
        and row + rectangle.height > first_row
        and col < first_col + vim.api.nvim_win_get_width(window)
        and col + rectangle.width > first_col then
      return true
    end
  end
  return false
end

local function settled()
  local image_stats = active.images:_stats()
  if image_stats.pending_preparations ~= 0 then return false end
  for _, name in ipairs(layer_order) do
    local layer = active.layers[name]
    local current = placements(layer)
    local image = layer.pane.layout
      and layer.pane.layout.images[layer.image_key]
    local presented = active.images:snapshot(layer.pane).presented[layer.image_key]
    if image and image.source_identity ~= active.source_identity then
      return false
    end
    if image and presented ~= active.source_identity then
      return false
    end
    if not image and (#current > 0 or presented) then return false end
    for _, value in ipairs(current) do
      if not value.record or value.record.content_id == nil then return false end
    end
  end
  return active.images.backend.output_operation == nil
    and next(active.images.backend.pending) == nil
end

local acknowledged_action = 0
local pending_action
local drained_action
local view_signature
local view_changed = vim.uv.hrtime()

local input_sentinel = "gZ"
vim.keymap.set("n", input_sentinel, function()
  drained_action = pending_action
  view_changed = vim.uv.hrtime()
end, {
  buffer = active.buffer,
  nowait = true,
  silent = true,
})

local function snapshot(is_settled)
  local function layer_snapshot(layer)
    local window = layer_window(layer)
    local actual_image = layer.pane.layout
      and layer.pane.layout.images[layer.image_key]
    local image = active.snapshot_image(layer)
    local line = actual_image and layer.buffer and vim.api.nvim_buf_get_lines(
      layer.buffer, actual_image.row, actual_image.row + 1, false)[1] or ""
    local current = placements(layer)
    local geometries = {}
    for _, placement in ipairs(current) do
      geometries[#geometries + 1] = placement.geometry
    end
    local marks = layer.buffer and vim.api.nvim_buf_is_valid(layer.buffer)
      and vim.api.nvim_buf_get_extmarks(
        layer.buffer, layer.pane.image_namespace, 0, -1, { details = true })
      or {}
    local mark = marks[1]
    local first = current[1]
    return {
      open = layer.open == true and window ~= nil,
      image = image,
      source_identity = actual_image and actual_image.source_identity or nil,
      geometry = geometries[1],
      geometries = geometries,
      placement = first and {
        id = first.id,
        content_id = first.record.content_id,
      } or nil,
      fragments = #current,
      position = window and actual_image and vim.fn.screenpos(
        window, actual_image.row + 1,
        require("applet.util").byte_col(line, actual_image.col) + 1) or nil,
      view = active.layer_view(layer),
      window = window and vim.fn.getwininfo(window)[1] or nil,
      config = active.layer_config(layer),
      visible = image_visible(layer),
      marks = {
        count = #marks,
        first = mark and {
          row = mark[2],
          col = mark[3],
          position = mark[4].virt_text_pos,
          window_col = mark[4].virt_text_win_col,
          characters = mark[4].virt_text
            and vim.fn.strchars(mark[4].virt_text[1][1]) or 0,
        } or nil,
      },
    }
  end
  local layers = {}
  for _, name in ipairs(layer_order) do
    layers[name] = layer_snapshot(active.layers[name])
  end
  local main = layers.main
  return vim.tbl_extend("force", main, {
    backend = backend,
    layout_mode = layout_mode,
    layers = layers,
    cells = active.images.backend.cell_dimensions
      and active.images.backend:cell_dimensions() or nil,
    centered = active.centered == true,
    horizontal_gutter = active.horizontal_gutter,
    settled = is_settled == true,
    action = acknowledged_action,
    errors = errors,
    frame = {
      index = active.frame_index,
      revision = active.frame_revision,
      pending = active.frame_pending == true,
      source_identity = active.source_identity,
    },
    image_stats = active.images:_stats(),
  })
end

local function read_action()
  if vim.fn.filereadable(action_path) ~= 1 then return end
  local content = table.concat(vim.fn.readfile(action_path), "\n")
  local ok, action = pcall(vim.json.decode, content)
  if not ok or type(action) ~= "table" or type(action.id) ~= "number"
      or action.id <= acknowledged_action
      or pending_action and action.id <= pending_action then return end
  if type(action.keys) ~= "string" or action.keys == "" then
    error("terminal image harness action requires keys", 0)
  end
  pending_action = action.id
  drained_action = nil
  view_changed = vim.uv.hrtime()
  vim.api.nvim_input(vim.api.nvim_replace_termcodes(
    action.keys, true, false, true) .. input_sentinel)
end

local timer = vim.uv.new_timer()
local started = vim.uv.hrtime()
local last_state = 0
local ready = false
timer:start(10, 10, vim.schedule_wrap(function()
  if #errors > 0 then error(vim.inspect(errors), 0) end
  read_action()
  active.flush()
  local now = vim.uv.hrtime()
  local is_settled = settled()
  local signature = {}
  for _, name in ipairs(layer_order) do
    local layer = active.layers[name]
    local window = layer_window(layer)
    local view = active.layer_view(layer) or {}
    local current = placements(layer)
    signature[#signature + 1] = table.concat({
      name,
      window or 0,
      layer.row,
      layer.col,
      layer.open and 1 or 0,
      view.topline or 0,
      view.leftcol or 0,
      image_visible(layer) and 1 or 0,
      #current,
      current[1] and current[1].record.content_id or 0,
      layer.pane.layout and layer.pane.layout.images[layer.image_key]
        and layer.pane.layout.images[layer.image_key].source_identity or "",
    }, ":")
  end
  local current_signature = table.concat(signature, "|")
  if current_signature ~= view_signature then
    view_signature = current_signature
    view_changed = now
  end
  if pending_action and drained_action == pending_action
      and is_settled and now - view_changed >= 100 * 1e6 then
    acknowledged_action = pending_action
    pending_action = nil
    drained_action = nil
  end
  if now - last_state >= 20 * 1e6 then
    last_state = now
    publish(state_path, snapshot(is_settled))
  end
  if not ready and active.centered and is_settled then
    ready = true
    publish(ready_path, snapshot(true))
  end
  if vim.fn.filereadable(stop_path) == 1 then
    timer:stop()
    timer:close()
    active.close()
    vim.cmd("qa!")
  elseif now - started > 600 * 1e9 then
    timer:stop()
    timer:close()
    active.close()
    vim.api.nvim_err_writeln("terminal image harness timed out")
    vim.cmd("cquit")
  end
end))
