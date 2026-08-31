-- Load this file, then call applet_image_harness("kitty", "native") or
-- applet_image_harness("kitty", "pane"). Each call replaces the active
-- harness. Native mode uses three Neovim floating windows; Pane mode renders
-- the same fixture through one Pane container scene.

local ACTIVE_KEY = "__applet_image_harness_active"

local function image_executable()
  for _, executable in ipairs({ "magick", "convert" }) do
    if vim.fn.executable(executable) == 1 then return executable end
  end
  error("applet image harness requires ImageMagick on PATH", 0)
end

local digit_segments = {
  [0] = { "a", "b", "c", "d", "e", "f" },
  [1] = { "b", "c" },
  [2] = { "a", "b", "g", "e", "d" },
  [3] = { "a", "b", "c", "d", "g" },
  [4] = { "f", "g", "b", "c" },
  [5] = { "a", "f", "g", "c", "d" },
  [6] = { "a", "f", "e", "d", "c", "g" },
  [7] = { "a", "b", "c" },
  [8] = { "a", "b", "c", "d", "e", "f", "g" },
  [9] = { "a", "b", "c", "d", "f", "g" },
}

local segment_rectangles = {
  a = { 4, 0, 16, 3 },
  b = { 16, 4, 19, 14 },
  c = { 16, 18, 19, 28 },
  d = { 4, 29, 16, 32 },
  e = { 0, 18, 3, 28 },
  f = { 0, 4, 3, 14 },
  g = { 4, 15, 16, 18 },
}

local function draw_digit(command, digit, x, y)
  for _, segment in ipairs(digit_segments[digit]) do
    local rect = segment_rectangles[segment]
    vim.list_extend(command, {
      "-draw", ("rectangle %d,%d %d,%d"):format(
        x + rect[1], y + rect[2], x + rect[3], y + rect[4]),
    })
  end
end

local frame_palettes = {
  {
    gradient = "gradient:#111827-#e0f2fe",
    colors = {
      "#ef4444c8", "#f97316c8", "#facc15c8", "#22c55ec8",
      "#06b6d4c8", "#3b82f6c8", "#6366f1c8", "#a855f7c8",
      "#ec4899c8", "#f43f5ec8",
    },
    marker = "#22d3ee",
  },
  {
    gradient = "gradient:#450a0a-#fecaca",
    colors = {
      "#7f1d1dc8", "#dc2626c8", "#f97316c8", "#facc15c8",
      "#e11d48c8", "#be123cc8", "#9f1239c8", "#f43f5ec8",
      "#fb7185c8", "#fdba74c8",
    },
    marker = "#facc15",
  },
  {
    gradient = "gradient:#172554-#cffafe",
    colors = {
      "#1d4ed8c8", "#2563ebc8", "#0891b2c8", "#06b6d4c8",
      "#0d9488c8", "#059669c8", "#16a34ac8", "#65a30dc8",
      "#4f46e5c8", "#7c3aedc8",
    },
    marker = "#34d399",
  },
}

local function generated_png(frame)
  local executable = image_executable()
  local palette = assert(frame_palettes[frame])
  local command = {
    executable, "-size", "960x512", palette.gradient,
    "+antialias",
  }
  for index = -2, 8 do
    local top = index * 150 - 80
    local bottom = top + 330
    vim.list_extend(command, {
      "-fill", palette.colors[index % #palette.colors + 1],
      "-stroke", "#0f172a", "-strokewidth", "5",
      "-draw", ("polygon %d,0 %d,0 %d,511 %d,511"):format(
        top, top + 105, bottom + 105, bottom),
    })
  end
  vim.list_extend(command, {
    "-stroke", "none", "-fill", "#020617",
    "-draw", "rectangle 0,0 959,39 rectangle 0,472 959,511",
    "-draw", "rectangle 0,40 31,471 rectangle 928,40 959,471",
    "-fill", "#f8fafc",
  })
  for digit = 0, 9 do
    local x = digit * 96 + 38
    draw_digit(command, digit, x, 4)
    draw_digit(command, digit, x, 476)
  end
  for digit = 0, 7 do
    local y = digit * 54 + 52
    draw_digit(command, digit, 6, y)
    draw_digit(command, digit, 934, y)
  end
  vim.list_extend(command, {
    "-fill", palette.marker,
    "-draw", "rectangle 0,0 7,7 rectangle 952,504 959,511",
    "-fill", "#f43f5e",
    "-draw", "rectangle 952,0 959,7 rectangle 0,504 7,511",
    "-strip", "-depth", "8", "png:-",
  })
  local result = vim.system(command, { text = false }):wait()
  if result.code ~= 0 or not result.stdout or result.stdout == "" then
    local message = result.stderr and result.stderr:gsub("%s+$", "") or ""
    error("ImageMagick could not generate the harness image: " .. message, 0)
  end
  return result.stdout
end

local function character_line(row, width)
  local prefix = ("%03d "):format(row)
  local pattern = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ|"
  local body_width = math.max(0, width - #prefix)
  local body = pattern:rep(math.ceil(body_width / #pattern)):sub(1, body_width)
  return prefix .. body
end

local function character_block(first, count, width)
  local lines = {}
  for offset = 0, count - 1 do
    lines[#lines + 1] = character_line(first + offset, width)
  end
  return table.concat(lines, "\n")
end

local function close_active()
  local active = rawget(_G, ACTIVE_KEY)
  if active and active.close then active.close() end
end

local surface_sequence = 0

local function outside_editor(config)
  if config.relative ~= "editor" then return false end
  local border = config.border and config.border ~= "none" and 2 or 0
  local width = (config.width or 1) + border
  local height = (config.height or 1) + border
  return config.col + width <= 0 or config.row + height <= 0
    or config.col >= vim.o.columns or config.row >= vim.o.lines
end

local function create_surface(opts)
  local logical = vim.deepcopy(opts.config)
  logical.hide = logical.hide == true
  local projected = vim.deepcopy(logical)
  local outside = outside_editor(logical)
  if outside then
    projected.row, projected.col, projected.hide = 0, 0, true
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, opts.name)
  local window = vim.api.nvim_open_win(buffer, opts.enter == true, projected)
  local self = {
    buffer = buffer,
    owns_buffer = false,
    domain = opts.domain,
    buffer_options = vim.deepcopy(opts.buffer_options),
    window_options = vim.deepcopy(opts.window_options),
    _window = window,
    _config = logical,
    _outside = outside,
  }
  self.window = function()
    return self._window and vim.api.nvim_win_is_valid(self._window)
      and self._window or nil
  end
  self.visible = function()
    return self.window() ~= nil and not self._config.hide and not self._outside
  end

  function self:_connect(pane)
    pane:_connect(self)
    self.pane = pane
    self.domain:surfaces_changed()
    return self
  end

  function self:config()
    assert(self.window(), "surface is closed")
    return vim.deepcopy(self._config)
  end

  function self:set_config(config)
    local current = assert(self.window(), "surface is closed")
    for key, value in pairs(config) do
      self._config[key] = vim.deepcopy(value)
    end
    self._outside = outside_editor(self._config)
    if self._config.hide or self._outside then
      vim.api.nvim_win_set_config(current, { hide = true })
    else
      vim.api.nvim_win_set_config(current, self._config)
    end
    self.domain:surfaces_changed()
    return self
  end

  function self:focus()
    local current = self.window()
    if not current or self._config.hide or self._outside then return false end
    vim.api.nvim_set_current_win(current)
    return true
  end

  function self:destroy()
    if self.destroyed then return end
    self.destroyed = true
    if self.group then pcall(vim.api.nvim_del_augroup_by_id, self.group) end
    if self.pane and self.pane.surface
        and self.pane.surface.buffer == self.buffer then
      self.pane:_disconnect()
    end
    self.pane = nil
    local current = self._window
    self._window = nil
    if current and vim.api.nvim_win_is_valid(current) then
      pcall(vim.api.nvim_win_close, current, true)
    end
    if vim.api.nvim_buf_is_valid(self.buffer) then
      pcall(vim.api.nvim_buf_delete, self.buffer, { force = true })
    end
    self.domain:surfaces_changed()
  end

  surface_sequence = surface_sequence + 1
  self.group = vim.api.nvim_create_augroup(
    "AppletImageHarnessSurface" .. surface_sequence, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.group,
    pattern = tostring(window),
    once = true,
    callback = function()
      self._window = nil
      vim.schedule(function()
        if not self.destroyed then self:destroy() end
      end)
    end,
  })
  return self
end

_G.applet_image_harness = function(backend, layout_mode)
  if backend ~= "kitty" then
    error('backend must be "kitty"', 0)
  end
  layout_mode = layout_mode or "native"
  if layout_mode ~= "native" and layout_mode ~= "pane" then
    error('layout mode must be "native" or "pane"', 0)
  end

  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight
  assert(columns >= 32 and lines >= 14,
    "applet image harness needs a terminal of at least 32x14 cells")
  local width = math.min(100, columns - 8)
  local height = math.min(30, lines - 6)
  local frames = {}
  for index = 1, #frame_palettes do
    frames[index] = { index = index, png = generated_png(index) }
  end
  local png = frames[1].png
  local Applet = require("applet")
  local ui = Applet.Pane.nodes
  local ImageSource = require("applet.image.source")

  close_active()
  local domain = Applet.InteractionDomain.new()
  local active
  local held_identity
  local held_start
  local function load_source(value, limits, done)
    local identity = ImageSource.identity(value)
    local operation = { cancelled = false, started = false }
    local function start()
      if operation.cancelled or operation.started then return end
      operation.started = true
      operation.cancel = ImageSource.load_async(value, limits, done)
    end
    if identity == held_identity then
      held_start = start
    else
      start()
    end
    return function()
      if operation.cancelled then return end
      operation.cancelled = true
      if held_start == start then held_start = nil end
      if operation.cancel then operation.cancel() end
    end
  end
  local images = Applet.ImageSystem._new({
    backend = backend,
    _load_source = load_source,
  })
  local closed = false
  local center_timer
  local close
  active = {
    backend = backend,
    layout_mode = layout_mode,
    domain = domain,
    images = images,
    layers = {},
    fixture = {
      png = png,
      frames = frames,
      width = 960,
      height = 512,
      palette_target = 256,
      true_color = true,
    },
  }
  _G[ACTIVE_KEY] = active

  local cells = images:snapshot()
  local function natural_rows(image_width)
    return math.max(3, math.floor(
      512 / 960 * image_width * cells.cell_width
        / cells.cell_height + 0.5))
  end

  local main_row = math.floor((lines - height) / 2)
  local main_col = math.floor((columns - width) / 2)
  local horizontal_gutter = math.min(6, math.floor(width / 6))
  local main_image_width = width - horizontal_gutter * 2
  local main_image_rows = natural_rows(main_image_width)
  local detail_width = math.max(16, math.min(
    width - 4, math.floor(width * 0.62)))
  local detail_image_width = math.max(8, detail_width - 8)
  local detail_image_rows = math.min(
    math.max(3, height - 4), natural_rows(detail_image_width))
  local detail_height = detail_image_rows + 2
  local badge_width = math.max(12, math.min(
    detail_width - 4, math.floor(width * 0.38)))
  local badge_image_width = math.max(4, badge_width - 8)
  local badge_image_rows = math.min(
    math.max(3, math.floor(height * 0.4) - 2),
    natural_rows(badge_image_width))
  local badge_height = badge_image_rows + 2
  local track_width = width * 2 + main_image_width
  local document_height = 1 + height * 4 + main_image_rows
  local image_document_row = 1 + height * 2

  local source = {
    kind = "png_bytes",
    id = "applet-image-harness",
    data = png,
    revision = 1,
  }
  active.frame_index = 1
  active.frame_revision = 1
  active.frame_pending = false
  active.source_identity = ImageSource.identity(source)
  local layer_specs = {
    main = {
      name = "main",
      image_key = "harness:image",
      row = main_row,
      col = main_col,
      width = width,
      height = height,
      image_width = main_image_width,
      image_rows = main_image_rows,
      zindex = 50,
      open = true,
      title = " Applet images: " .. backend
        .. " · hjkl scroll · HJKL detail · gh/gj/gk/gl badge"
        .. " · a frame · A churn · p pending · u release · r reset · q ",
    },
    detail = {
      name = "detail",
      image_key = "harness:detail:image",
      row = main_row + math.max(1,
        math.floor((height - detail_height) / 3)),
      col = main_col + math.max(2,
        math.floor((width - detail_width) / 3)),
      width = detail_width,
      height = detail_height,
      image_width = detail_image_width,
      image_rows = detail_image_rows,
      zindex = 70,
      open = true,
      title = " detail · HJKL · e ",
    },
    badge = {
      name = "badge",
      image_key = "harness:badge:image",
      row = main_row + math.max(2,
        height - badge_height - 2),
      col = main_col + math.max(2,
        width - badge_width - 3),
      width = badge_width,
      height = badge_height,
      image_width = badge_image_width,
      image_rows = badge_image_rows,
      zindex = 90,
      open = true,
      title = " badge · g+hjkl · t ",
    },
  }
  for _, name in ipairs({ "main", "detail", "badge" }) do
    active.layers[name] = layer_specs[name]
  end
  active.horizontal_gutter = horizontal_gutter
  active.scroll = {
    row = math.max(0,
      image_document_row - math.floor((height - main_image_rows) / 2)),
    col = math.max(0, width - horizontal_gutter),
  }

  local errors = {}
  active.errors = errors
  local function report(err)
    errors[#errors + 1] = err
    vim.schedule(function()
      vim.notify("Applet image harness: " .. err.message, vim.log.levels.ERROR)
    end)
  end

  local side_lines = {}
  for row = 1, main_image_rows do
    side_lines[row] = ("|M%02dM|"):format(row % 100)
  end

  local function main_document()
    return ui.column({
      key = "harness:document",
      children = {
        ui.text({
          key = "harness:help",
          text = "hjkl scroll · Alt-j/k jump · HJKL moves detail"
            .. " · g+hjkl moves badge · e/t toggle · q closes"
            .. " · a frame · A churn · p pending · r reset"
            .. " · backend: " .. backend,
          wrap = "native",
        }),
        ui.text({
          key = "harness:before",
          text = character_block(1, height * 2, track_width),
          wrap = "native",
        }),
        ui.row({
          key = "harness:image-row",
          width = track_width,
          children = {
            {
              min_width = width,
              grow = 0,
              node = ui.text({
                key = "harness:left-characters",
                text = table.concat(vim.tbl_map(function(line)
                  return character_line(0, width - #line) .. line
                end, side_lines), "\n"),
                wrap = "native",
              }),
            },
            {
              min_width = main_image_width,
              grow = 0,
              node = ui.image({
                key = "harness:image",
                source = source,
                alt = "generated geometric image",
                width = "fill",
                height = main_image_rows,
                fit = "fill",
                align = "left",
              }),
            },
            {
              min_width = width,
              grow = 0,
              node = ui.text({
                key = "harness:right-characters",
                text = table.concat(vim.tbl_map(function(line)
                  return line .. character_line(0, width - #line)
                end, side_lines), "\n"),
                wrap = "native",
              }),
            },
          },
        }),
        ui.text({
          key = "harness:after",
          text = character_block(height * 2 + 1, height * 2, track_width),
          wrap = "native",
        }),
      },
    })
  end

  local function overlay_tree(layer)
    local left, right = {}, {}
    for row = 1, layer.image_rows do
      left[row] = ("%02d| "):format(row % 100)
      right[row] = (" |%02d"):format(row % 100)
    end
    return ui.column({
      key = "harness:" .. layer.name .. ":root",
      children = {
        ui.text({
          key = "harness:" .. layer.name .. ":top",
          text = character_line(layer.zindex, layer.width),
          wrap = "none",
        }),
        ui.row({
          key = "harness:" .. layer.name .. ":image-row",
          width = layer.width,
          children = {
            {
              min_width = 4,
              grow = 0,
              node = ui.text({
                key = "harness:" .. layer.name .. ":left",
                text = table.concat(left, "\n"),
                wrap = "native",
              }),
            },
            {
              min_width = layer.image_width,
              grow = 0,
              node = ui.image({
                key = layer.image_key,
                source = source,
                alt = layer.name .. " generated geometric image",
                width = "fill",
                height = layer.image_rows,
                fit = "fill",
                align = "left",
              }),
            },
            {
              min_width = 4,
              grow = 0,
              node = ui.text({
                key = "harness:" .. layer.name .. ":right",
                text = table.concat(right, "\n"),
                wrap = "native",
              }),
            },
          },
        }),
        ui.text({
          key = "harness:" .. layer.name .. ":bottom",
          text = character_line(layer.zindex + 1, layer.width),
          wrap = "none",
        }),
      },
    })
  end

  local bindings = {}
  for _, direction in ipairs({ "h", "j", "k", "l" }) do
    bindings[#bindings + 1] = {
      lhs = direction,
      count = true,
      desc = "scroll the image harness " .. direction,
      action = ui.action("harness.scroll", { direction = direction }),
    }
  end
  for _, direction in ipairs({ "j", "k" }) do
    bindings[#bindings + 1] = {
      lhs = "<M-" .. direction .. ">",
      count = true,
      desc = "scroll the image harness 8" .. direction,
      action = ui.action("harness.scroll", {
        direction = direction,
        step = 8,
      }),
    }
  end
  for _, direction in ipairs({ "h", "j", "k", "l" }) do
    bindings[#bindings + 1] = {
      lhs = direction:upper(),
      count = true,
      desc = "move the detail image " .. direction,
      action = ui.action("harness.move", {
        layer = "detail",
        direction = direction,
      }),
    }
    bindings[#bindings + 1] = {
      lhs = "g" .. direction,
      count = true,
      desc = "move the badge image " .. direction,
      action = ui.action("harness.move", {
        layer = "badge",
        direction = direction,
      }),
    }
  end
  for key, layer in pairs({ e = "detail", t = "badge" }) do
    bindings[#bindings + 1] = {
      lhs = key,
      desc = "toggle the " .. layer .. " image",
      action = ui.action("harness.toggle", { layer = layer }),
    }
  end
  for _, frame_binding in ipairs({
    { lhs = "a", action = "harness.frame", desc = "show the next image frame" },
    { lhs = "A", action = "harness.churn", desc = "churn image revisions" },
    { lhs = "p", action = "harness.pending", desc = "hold a pending frame" },
    { lhs = "u", action = "harness.release", desc = "release a pending frame" },
    { lhs = "r", action = "harness.reset", desc = "restore the first frame" },
  }) do
    bindings[#bindings + 1] = {
      lhs = frame_binding.lhs,
      desc = frame_binding.desc,
      action = ui.action(frame_binding.action),
    }
  end
  bindings[#bindings + 1] = {
    lhs = "q",
    desc = "close the image harness",
    action = ui.action("harness.close"),
  }

  local main_pane
  local open_native_layer
  local close_native_layer
  local function native_main_tree()
    return ui.scope({
      key = "harness:scope",
      bindings = bindings,
      child = main_document(),
    })
  end

  local function pane_scene()
    local scene_layers = {
      ui.container({
        key = "harness:document:container",
        position = {
          mode = "absolute",
          row = -active.scroll.row,
          col = -active.scroll.col,
          zindex = 0,
        },
        width = track_width,
        height = document_height,
        child = main_document(),
      }),
    }
    for _, name in ipairs({ "detail", "badge" }) do
      local layer = active.layers[name]
      if layer.open then
        scene_layers[#scene_layers + 1] = ui.container({
          key = "harness:" .. name .. ":container",
          position = {
            mode = "absolute",
            row = layer.row - main_row - 1,
            col = layer.col - main_col - 1,
            zindex = layer.zindex,
          },
          width = layer.width,
          height = layer.height,
          background = "NormalFloat",
          border = {
            kind = "single",
            group = "FloatBorder",
            title = layer.title,
            title_group = "FloatTitle",
            title_pos = "center",
          },
          child = overlay_tree(layer),
        })
      end
    end
    return ui.scope({
      key = "harness:scope",
      bindings = bindings,
      child = ui.container({
        key = "harness:stage",
        width = width,
        height = height,
        background = "NormalFloat",
        layers = scene_layers,
      }),
    })
  end

  local function refresh_pane_scene()
    if layout_mode == "pane" and main_pane then
      main_pane:update(pane_scene())
    end
  end

  local function stop_held_frame()
    held_identity, held_start = nil, nil
    active.frame_pending = false
  end

  local function submit_frame()
    if not main_pane then return end
    if layout_mode == "native" then
      main_pane:update(native_main_tree())
      active.layers.detail.pane:update(overlay_tree(active.layers.detail))
      active.layers.badge.pane:update(overlay_tree(active.layers.badge))
    else
      refresh_pane_scene()
    end
  end

  function active:set_frame(index, hold)
    assert(type(index) == "number" and index % 1 == 0
      and frames[index], "image harness frame must exist")
    assert(hold == nil or type(hold) == "boolean",
      "image harness hold must be boolean")
    stop_held_frame()
    self.frame_index = index
    self.frame_revision = self.frame_revision + 1
    source = {
      kind = "png_bytes",
      id = "applet-image-harness",
      data = frames[index].png,
      revision = self.frame_revision,
    }
    self.source_identity = ImageSource.identity(source)
    if hold then
      held_identity = self.source_identity
      self.frame_pending = true
    end
    submit_frame()
  end

  function active:release_frame()
    local start = held_start
    held_identity, held_start = nil, nil
    self.frame_pending = false
    if not closed and start then start() end
  end

  local function next_frame()
    active:set_frame(active.frame_index % #frames + 1)
  end

  local function churn_frames()
    for _, index in ipairs({ 2, 1, 3 }) do active:set_frame(index) end
  end

  local function pending_frame()
    active:set_frame(active.frame_index % #frames + 1, true)
  end

  local function release_frame()
    active:release_frame()
  end

  local function reset_frame()
    active:set_frame(1)
  end

  local scroll_keys = {
    j = vim.api.nvim_replace_termcodes("<C-e>", true, false, true),
    k = vim.api.nvim_replace_termcodes("<C-y>", true, false, true),
    h = "zh",
    l = "zl",
  }
  local movement = {
    h = { 0, -1 },
    j = { 1, 0 },
    k = { -1, 0 },
    l = { 0, 1 },
  }

  local function scroll(event)
    local count = (event.count or 1) * (event.payload.step or 1)
    local direction = event.payload.direction
    if layout_mode == "native" then
      local window = active.layers.main.surface
        and active.layers.main.surface.window() or nil
      if closed or not window then return end
      vim.api.nvim_win_call(window, function()
        vim.cmd("normal! " .. count .. assert(scroll_keys[direction]))
      end)
      return
    end
    if direction == "j" then
      active.scroll.row = math.min(
        document_height - height, active.scroll.row + count)
    elseif direction == "k" then
      active.scroll.row = math.max(0, active.scroll.row - count)
    elseif direction == "l" then
      active.scroll.col = math.min(
        track_width - width, active.scroll.col + count)
    elseif direction == "h" then
      active.scroll.col = math.max(0, active.scroll.col - count)
    end
    main_pane:set_position("harness:document:container", {
      row = -active.scroll.row,
      col = -active.scroll.col,
    })
  end

  local function move_layer(event)
    local layer = active.layers[event.payload.layer]
    local delta = movement[event.payload.direction]
    if closed or not layer or not delta or not layer.open then return end
    local count = math.max(1, event.count or 1)
    layer.row = layer.row + delta[1] * count
    layer.col = layer.col + delta[2] * count
    if layout_mode == "native" then
      layer.surface:set_config({
        relative = "editor",
        row = layer.row,
        col = layer.col,
      })
    else
      main_pane:set_position("harness:" .. layer.name .. ":container", {
        row = layer.row - main_row - 1,
        col = layer.col - main_col - 1,
      })
    end
  end

  local function toggle_layer(event)
    local layer = active.layers[event.payload.layer]
    if not layer or layer.name == "main" then return end
    if layout_mode == "native" then
      if layer.open then
        close_native_layer(layer)
      else
        open_native_layer(layer, false)
      end
    else
      layer.open = not layer.open
      refresh_pane_scene()
    end
  end

  main_pane = Applet.Pane.new({
    key = "image-harness-main",
    image_system = images,
    handlers = {
      ["harness.scroll"] = scroll,
      ["harness.move"] = move_layer,
      ["harness.toggle"] = toggle_layer,
      ["harness.frame"] = next_frame,
      ["harness.churn"] = churn_frames,
      ["harness.pending"] = pending_frame,
      ["harness.release"] = release_frame,
      ["harness.reset"] = reset_frame,
      ["harness.close"] = function() vim.schedule(function() close() end) end,
    },
    on_error = report,
  })
  active.layers.main.pane = main_pane
  if layout_mode == "native" then
    for _, name in ipairs({ "detail", "badge" }) do
      active.layers[name].pane = Applet.Pane.new({
        key = "image-harness-" .. name,
        image_system = images,
        on_error = report,
      })
    end
    main_pane:update(native_main_tree())
    active.layers.detail.pane:update(overlay_tree(active.layers.detail))
    active.layers.badge.pane:update(overlay_tree(active.layers.badge))
  else
    active.layers.detail.pane = main_pane
    active.layers.badge.pane = main_pane
    refresh_pane_scene()
  end

  local function stop_center_timer()
    local timer = center_timer
    center_timer = nil
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end

  local function surface_config(layer)
    return {
      relative = "editor",
      row = layer.row,
      col = layer.col,
      width = layer.width,
      height = layer.height,
      border = "single",
      style = "minimal",
      title = layer.title,
      title_pos = "center",
      zindex = layer.zindex,
      fixed = true,
    }
  end

  open_native_layer = function(layer, enter)
    if closed or layer.surface then return false end
    local surface = create_surface({
      name = "applet-image-harness-" .. layer.name,
      domain = domain,
      enter = enter == true,
      config = surface_config(layer),
      buffer_options = {
        buftype = "nofile",
        bufhidden = "wipe",
      },
      window_options = {
        wrap = false,
        cursorline = false,
      },
    })
    layer.open = true
    layer.surface = surface
    surface:_connect(layer.pane)
    layer.buffer = surface.buffer
    layer.window = surface.window()
    layer.pane:flush()
    if layer.name == "main" then
      active.pane = layer.pane
      active.surface = surface
      active.buffer = surface.buffer
      active.window = surface.window()
    end
    return true
  end

  close_native_layer = function(layer)
    local surface = layer.surface
    layer.open = false
    layer.surface, layer.buffer, layer.window = nil, nil, nil
    if surface then surface:destroy() end
  end

  local function open_pane_surface()
    local main = active.layers.main
    local surface = create_surface({
      name = "applet-image-harness-main",
      domain = domain,
      enter = true,
      config = surface_config(main),
      buffer_options = {
        buftype = "nofile",
        bufhidden = "wipe",
      },
      window_options = {
        wrap = false,
        cursorline = false,
      },
    })
    surface:_connect(main_pane)
    for _, name in ipairs({ "main", "detail", "badge" }) do
      local layer = active.layers[name]
      layer.surface = surface
      layer.buffer = surface.buffer
      layer.window = surface.window()
    end
    active.pane = main_pane
    active.surface = surface
    active.buffer = surface.buffer
    active.window = surface.window()
    main_pane:flush()
  end

  close = function()
    if closed then return end
    closed = true
    stop_center_timer()
    stop_held_frame()
    if active.group then pcall(vim.api.nvim_del_augroup_by_id, active.group) end
    if layout_mode == "native" then
      for _, name in ipairs({ "badge", "detail", "main" }) do
        close_native_layer(active.layers[name])
      end
      for _, name in ipairs({ "badge", "detail", "main" }) do
        active.layers[name].pane:destroy()
      end
    else
      local surface = active.surface
      for _, name in ipairs({ "main", "detail", "badge" }) do
        local layer = active.layers[name]
        layer.surface, layer.buffer, layer.window = nil, nil, nil
      end
      if surface then surface:destroy() end
      main_pane:destroy()
    end
    images:destroy()
    domain:destroy()
    if rawget(_G, ACTIVE_KEY) == active then _G[ACTIVE_KEY] = nil end
  end
  active.close = close

  if layout_mode == "native" then
    assert(open_native_layer(active.layers.main, true))
    assert(open_native_layer(active.layers.detail, false))
    assert(open_native_layer(active.layers.badge, false))
  else
    open_pane_surface()
  end
  active.layers.main.surface:focus()
  assert(domain:flush())

  function active.layer_window(layer)
    return layer.open and layer.surface and layer.surface.window() or nil
  end

  function active.layer_config(layer)
    if layout_mode == "native" then
      return layer.surface and layer.surface:config() or nil
    end
    return {
      relative = "editor",
      row = layer.row,
      col = layer.col,
      width = layer.width,
      height = layer.height,
      border = "single",
      title = layer.title,
      title_pos = "center",
      zindex = layer.zindex,
      hide = not layer.open,
    }
  end

  function active.layer_view(layer)
    local window = active.layer_window(layer)
    if not window then return nil end
    if layout_mode == "pane" and layer.name == "main" then
      return {
        topline = active.scroll.row + 1,
        leftcol = active.scroll.col,
      }
    end
    return vim.api.nvim_win_call(window, vim.fn.winsaveview)
  end

  function active.snapshot_image(layer)
    local image = layer.pane.layout
      and layer.pane.layout.images[layer.image_key]
    if not image then return nil end
    local result = vim.deepcopy(image)
    if layout_mode == "pane" and layer.name == "main" then
      result.row = result.row + active.scroll.row
      result.col = result.col + active.scroll.col
    end
    return result
  end

  function active.flush()
    if layout_mode == "native" then
      for _, name in ipairs({ "main", "detail", "badge" }) do
        local layer = active.layers[name]
        if layer.surface then layer.pane:flush() end
      end
    elseif active.surface then
      main_pane:flush()
    end
  end

  center_timer = vim.uv.new_timer()
  local attempts = 0
  center_timer:start(10, 20, vim.schedule_wrap(function()
    if active.centered then return end
    local main = active.layers.main
    local window = active.layer_window(main)
    if closed or not window then
      close()
      return
    end
    attempts = attempts + 1
    active.flush()
    local image = main.pane.layout and main.pane.layout.images
      and main.pane.layout.images[main.image_key]
    if image then
      stop_center_timer()
      vim.api.nvim_win_call(window, function()
        local line = vim.api.nvim_buf_get_lines(
          main.buffer, image.row, image.row + 1, false)[1] or ""
        local cursor_col = require("applet.util").byte_col(line, image.col)
        vim.api.nvim_win_set_cursor(window, { image.row + 1, cursor_col })
        if layout_mode == "native" then
          local first = math.max(1,
            image.row + 1 - math.floor((height - image.height) / 2))
          vim.fn.winrestview({
            lnum = image.row + 1,
            col = cursor_col,
            topline = first,
            leftcol = math.max(0, image.col - horizontal_gutter),
          })
        else
          vim.fn.winrestview({
            lnum = image.row + 1,
            col = cursor_col,
            topline = 1,
            leftcol = 0,
          })
        end
        active.centered = true
      end)
      vim.api.nvim_set_current_win(window)
    elseif attempts >= 250 then
      stop_center_timer()
    end
  end))

  active.group = vim.api.nvim_create_augroup(
    "AppletImageHarness", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = active.group,
    pattern = tostring(active.window),
    once = true,
    callback = function() vim.schedule(close) end,
  })
  return active
end
