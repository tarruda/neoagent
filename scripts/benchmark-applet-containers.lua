local Applet = require("applet")
local compile = Applet.Pane.compile
local ui = Applet.Pane.nodes

local profile = {}
local function instrument(module, name)
  local original = module[name]
  profile[name] = { calls = 0, elapsed = 0 }
  module[name] = function(...)
    local started = vim.uv.hrtime()
    local values = { original(...) }
    local elapsed = vim.uv.hrtime() - started
    profile[name].calls = profile[name].calls + 1
    profile[name].elapsed = profile[name].elapsed + elapsed
    return unpack(values)
  end
end
if vim.env.APPLET_BENCH_PROFILE == "1" then
  local compiler = require("applet.pane.compile")
  local reconciler = require("applet.pane.reconcile")
  local retained_scene = require("applet.pane.scene")
  instrument(require("applet.pane.canvas"), "compose")
  instrument(compiler, "project_scene")
  instrument(reconciler, "changes")
  instrument(reconciler, "retain")
  instrument(retained_scene, "update")
  instrument(retained_scene, "reposition")
  local util = require("applet.util")
  for _, name in ipairs({ "equal", "display_width", "byte_col", "characters" }) do
    instrument(util, name)
  end
end

local iterations = tonumber(vim.env.APPLET_BENCH_ITERATIONS) or 100
assert(iterations >= 1 and iterations % 1 == 0,
  "APPLET_BENCH_ITERATIONS must be a positive integer")

local budgets = {
  tree = { frame_ms = 0.05, retained_kb_per_frame = 8 },
  compile = { frame_ms = 0.75, retained_kb_per_frame = 64 },
  retained_position = {
    frame_ms = 0.05,
    retained_kb_per_frame = 8,
    composed_cells = 0,
  },
  full_update = { frame_ms = 0.75, retained_kb_per_frame = 32 },
}

local width = math.max(40, vim.api.nvim_win_get_width(0))
local height = math.max(12, vim.api.nvim_win_get_height(0))
local document_width = width * 3
local document_height = height * 6
local document_line = string.rep("document ", math.ceil(document_width / 9))
  :sub(1, document_width)
local document = table.concat(
  vim.fn["repeat"]({ document_line }, document_height), "\n")

local function scene(frame)
  return ui.container({
    key = "benchmark:stage",
    width = width,
    height = height,
    layers = {
      ui.container({
        key = "benchmark:document",
        position = {
          mode = "absolute",
          row = -(frame % (document_height - height + 1)),
          col = 0,
          zindex = 0,
        },
        width = document_width,
        height = document_height,
        child = ui.text({
          key = "benchmark:document:text",
          text = document,
          wrap = "none",
        }),
      }),
      ui.container({
        key = "benchmark:overlay",
        position = {
          mode = "absolute",
          row = frame % math.max(1, height - 8),
          col = frame % math.max(1, width - 30),
          zindex = 20,
        },
        width = 28,
        height = 6,
        padding = 1,
        background = "NormalFloat",
        border = { kind = "single", title = " benchmark " },
        child = ui.text({
          key = "benchmark:overlay:text",
          text = "movable layered content",
        }),
      }),
    },
  })
end

local function measure(callback)
  collectgarbage("collect")
  local before_kb = collectgarbage("count")
  local started = vim.uv.hrtime()
  for frame = 1, iterations do callback(frame) end
  local elapsed = vim.uv.hrtime() - started
  local retained_kb = collectgarbage("count") - before_kb
  return {
    total_ms = elapsed / 1e6,
    frame_ms = elapsed / iterations / 1e6,
    retained_kb = retained_kb,
    retained_kb_per_frame = math.max(0, retained_kb) / iterations,
  }
end

for frame = 1, 5 do scene(frame) end
local tree = measure(function(frame) scene(frame) end)

local compile_cache = {}
local compile_stats = {
  region_compilations = 0,
  region_reuses = 0,
  layer_compilations = 0,
  layer_reuses = 0,
  composed_cells = 0,
}
compile({
  tree = scene(0),
  width = width,
  height = height,
  cache = compile_cache,
  stats = compile_stats,
})
local compilation = measure(function(frame)
  compile({
    tree = scene(frame),
    width = width,
    height = height,
    cache = compile_cache,
    stats = compile_stats,
  })
end)

local base_window = vim.api.nvim_get_current_win()
local base_buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(base_window, base_buffer)
vim.api.nvim_buf_set_lines(
  base_buffer, 0, -1, false, vim.split(document, "\n", { plain = true }))
local overlay_buffer = vim.api.nvim_create_buf(false, true)
local overlay_window = vim.api.nvim_open_win(overlay_buffer, false, {
  relative = "editor",
  row = 0,
  col = 0,
  width = 28,
  height = 6,
  style = "minimal",
  border = "single",
})
for frame = 1, 10 do
  vim.api.nvim_win_call(base_window, function()
    vim.fn.winrestview({
      topline = frame % (document_height - height + 1) + 1,
      leftcol = 0,
    })
  end)
  vim.api.nvim_win_set_config(overlay_window, {
    relative = "editor",
    row = frame % math.max(1, height - 8),
    col = frame % math.max(1, width - 30),
  })
end
local native = measure(function(frame)
  vim.api.nvim_win_call(base_window, function()
    vim.fn.winrestview({
      topline = frame % (document_height - height + 1) + 1,
      leftcol = 0,
    })
  end)
  vim.api.nvim_win_set_config(overlay_window, {
    relative = "editor",
    row = frame % math.max(1, height - 8),
    col = frame % math.max(1, width - 30),
  })
end)
local native_position = measure(function(frame)
  vim.api.nvim_win_set_config(overlay_window, {
    relative = "editor",
    row = frame % math.max(1, height - 8),
    col = frame % math.max(1, width - 30),
  })
end)

local pane = Applet.Pane.new({ key = "container-benchmark" })
pane:_connect({
  buffer = base_buffer,
  window = function() return base_window end,
  owns_buffer = true,
  buffer_options = { buftype = "nofile" },
  window_options = { wrap = false },
})
pane:update(scene(0))
assert(pane:flush())
local retained_before = pane:_stats()
local retained_position = measure(function(frame)
  assert(pane:set_position("benchmark:overlay", {
    row = frame % math.max(1, height - 8),
    col = frame % math.max(1, width - 30),
  }))
  assert(pane:flush())
end)
local retained_after = pane:_stats()
retained_position.composed_cells =
  retained_after.composed_cells - retained_before.composed_cells
local full_update = measure(function(frame)
  pane:update(scene(frame))
  assert(pane:flush())
end)
local pane_stats = pane:_stats()
pane:destroy()
vim.api.nvim_win_close(overlay_window, true)

local result = {
  iterations = iterations,
  dimensions = {
    width = width,
    height = height,
    document_width = document_width,
    document_height = document_height,
  },
  tree = tree,
  compile = compilation,
  native = native,
  native_position = native_position,
  retained_position = retained_position,
  full_update = full_update,
  ratio = full_update.frame_ms / native.frame_ms,
  budgets = budgets,
  compile_stats = compile_stats,
  pane_stats = pane_stats,
  profile = profile,
}

if vim.env.APPLET_BENCH_ENFORCE == "1" then
  for operation, limits in pairs(budgets) do
    local measured = assert(result[operation], "missing benchmark " .. operation)
    for metric, limit in pairs(limits) do
      assert(measured[metric] <= limit,
        ("Applet %s %s budget exceeded: %.6f > %.6f")
          :format(operation, metric, measured[metric], limit))
    end
  end
end
vim.api.nvim_out_write("APPLET_CONTAINER_BENCHMARK "
  .. vim.json.encode(result) .. "\n")
