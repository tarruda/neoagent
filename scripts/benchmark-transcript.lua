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

-- Keep both navigable segments small while growing excluded message bodies.
-- Session construction is outside the measurement; Agent snapshots include
-- context display and navigation includes semantic publication.
---@param historical_messages integer
---@return {historical_messages: integer, selected_messages: integer, operation_ms: number, return_latest_ms: number, retained_kb: number}
local function benchmark_projection(historical_messages)
  ---@type Neoagent.JournalEntry[]
  local entries = {}
  ---@param message Neoagent.Message
  local function append(message)
    local previous = entries[#entries]
    entries[#entries + 1] = {
      type = "message",
      id = tostring(#entries + 1),
      parent_id = previous and previous.id or vim.NIL,
      created_at = 1,
      message = message,
    }
  end
  local body = string.rep("Excluded synthetic history.\n", 100)
  for _ = 1, historical_messages do
    append({ role = "user", content = { { type = "text", text = body } } })
  end
  for _, id in ipairs({ "middle", "latest" }) do
    entries[#entries + 1] = {
      type = "compaction",
      id = id,
      parent_id = assert(entries[#entries]).id,
      created_at = 1,
      summary = "Small synthetic checkpoint",
      tokens_before = 100,
    }
    append({ role = "user", content = "Selected request" })
    append({ role = "assistant", content = { { type = "text", text = "Selected answer" } } })
  end
  local session = assert(require("neoagent.session").new({ entries = entries }))
  local model = require("tests.helpers.fake_model").new({})
  model.context_window = 8192
  local agent = require("neoagent").new({
    default_registry = false,
    default_profile = "chat",
    workspace_trust = false,
    sandbox = { enabled = false },
    persistence = { enabled = false },
    recording = { enabled = false },
    agent_instructions = false,
    skills = false,
    tools = {},
    compaction = false,
    default_model = { provider = "fake", model = "test" },
    providers = { fake = { api = "fake-api", models = { test = {} } } },
    _apis = {
      ["fake-api"] = function(resolved)
        model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
        return model
      end,
    },
  }, { session = session })
  local completed, result = xpcall(function()
    assert(agent:prepare())
    assert(#agent:snapshot().messages == 3)
    collectgarbage("collect")
    local memory = collectgarbage("count")
    local started = vim.uv.hrtime()
    local repetitions = 20
    for _ = 1, repetitions do
      assert(#agent:snapshot().messages == 3)
      assert(agent:navigate_transcript("previous"))
      assert(agent:navigate_transcript("latest"))
    end
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    assert(agent:navigate_transcript("first"))
    collectgarbage("collect")
    started = vim.uv.hrtime()
    assert(agent:navigate_transcript("latest"))
    local return_latest_ms = (vim.uv.hrtime() - started) / 1e6
    collectgarbage("collect")
    return {
      historical_messages = historical_messages,
      selected_messages = 3,
      operation_ms = elapsed / (repetitions * 3),
      return_latest_ms = return_latest_ms,
      retained_kb = math.max(0, collectgarbage("count") - memory),
    }
  end, debug.traceback)
  agent:destroy()
  assert(completed, result)
  return result
end

for _, historical_messages in ipairs({ 1000, 10000 }) do
  local projection = benchmark_projection(historical_messages)
  vim.api.nvim_out_write("TRANSCRIPT_PROJECTION_BENCHMARK " .. vim.json.encode(projection) .. "\n")
  if vim.env.NEOAGENT_TRANSCRIPT_BENCH_ENFORCE == "1" then
    assert(projection.operation_ms <= 50, "transcript projection operation exceeded 50ms")
    assert(projection.return_latest_ms <= 50, "returning to the latest transcript exceeded 50ms")
    assert(projection.retained_kb <= 64, "transcript projection retained more than 64KiB")
  end
end
