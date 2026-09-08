local Transcript = require("neoagent.ui.panes.transcript")
local renderers = require("neoagent.ui.renderers")

local iterations = tonumber(vim.env.NEOAGENT_TRANSCRIPT_BENCH_ITERATIONS) or 60
assert(iterations >= 1 and iterations % 1 == 0,
  "NEOAGENT_TRANSCRIPT_BENCH_ITERATIONS must be a positive integer")
---@cast iterations integer

-- Allow CI scheduling headroom around the measured long-response baseline.
-- Native rebuild and splice budgets independently guard incremental updates.
local budgets = { frame_ms = 250, retained_kb_per_frame = 16, full_rebuilds = 0 }
local transcript = Transcript.new({
  renderer = renderers.codex, config = { show_thinking = true },
})
local window = vim.api.nvim_get_current_win()
local original_buffer = vim.api.nvim_get_current_buf()
local buffer = vim.api.nvim_create_buf(false, true)

local ok, measurement = xpcall(function()
  ---@type Neoagent.TranscriptMessage[]
  local messages = {}
  for index = 1, 200 do
    messages[#messages + 1] = {
      role = "user", content = "Inspect synthetic module " .. index,
    }
    messages[#messages + 1] = { role = "assistant", content = { {
      type = "text", text = ("### Module %d\n\n- Check input validation.\n"
        .. "- Preserve cancellation.\n\n```lua\nlocal value = %d\nreturn value\n```\n")
        :format(index, index),
    } } }
  end
  transcript:set_messages(messages)
  vim.api.nvim_win_set_buf(window, buffer)
  transcript.pane:_connect({
    buffer = buffer, window = function() return window end,
    owns_buffer = true, buffer_options = { buftype = "nofile" },
    window_options = { wrap = false },
  })
  assert(transcript.pane:flush())
  transcript:apply({ type = "text_delta", index = 0,
    text = string.rep("- Existing streamed response text.\n", 2000) })
  assert(transcript.pane:flush())
  for _ = 1, 10 do
    transcript:apply({ type = "text_delta", index = 0, text = "warmup\n" })
    assert(transcript.pane:flush())
  end
  local initial_rows = vim.api.nvim_buf_line_count(buffer)
  collectgarbage("collect")
  local memory = collectgarbage("count")
  local before = transcript.pane:_stats()
  local started = vim.uv.hrtime()
  for index = 1, iterations do
    transcript:apply({ type = "text_delta", index = 0,
      text = ("streamed continuation %d\n"):format(index) })
    assert(transcript.pane:flush())
  end
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  collectgarbage("collect")
  local retained = math.max(0, collectgarbage("count") - memory)
  local after = transcript.pane:_stats()
  local final_rows = vim.api.nvim_buf_line_count(buffer)
  local tail = table.concat(vim.api.nvim_buf_get_lines(
    buffer, math.max(0, final_rows - 4), -1, false), "\n")
  assert(tail:find("streamed continuation " .. iterations, 1, true),
    "transcript did not publish the final delta")
  return {
    iterations = iterations, history_messages = #messages,
    initial_rows = initial_rows, final_rows = final_rows,
    frame_ms = elapsed / iterations,
    retained_kb_per_frame = retained / iterations,
    full_rebuilds = after.full_rebuilds - before.full_rebuilds,
    line_splices = after.line_splices - before.line_splices,
  }
end, debug.traceback)

vim.api.nvim_win_set_buf(window, original_buffer)
transcript:destroy()
if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
assert(ok, measurement)
vim.api.nvim_out_write("TRANSCRIPT_BENCHMARK " .. vim.json.encode(measurement) .. "\n")
if vim.env.NEOAGENT_TRANSCRIPT_BENCH_ENFORCE == "1" then
  for name, budget in pairs(budgets) do
    assert(measurement[name] <= budget,
      ("Transcript %s budget exceeded: %.3f > %.3f"):format(name, measurement[name], budget))
  end
  assert(measurement.line_splices <= iterations, "transcript repeated native splices")
end
