local async = require("neoagent.async")
local compaction = require("neoagent.compaction")
local tree = require("neoagent.session_tree")

-- Force a late fitting suffix with a constant-time Model estimate so this
-- measures planning overhead independently of a provider's tokenizer.
-- Keep headroom for shared hosts; these catch large regressions, while the
-- printed CPU measurements support comparisons under similar conditions.
local budgets = { [128] = 300, [256] = 750, [512] = 2000 }
for _, count in ipairs({ 128, 256, 512 }) do
  ---@type Neoagent.JournalEntry[]
  local path = {}
  for index = 1, count do
    path[index] = { type = "message", id = tostring(index),
      parent_id = index == 1 and vim.NIL or tostring(index - 1), created_at = 1,
      message = index % 2 == 1 and { role = "user", content = string.rep("u", 64) }
        or { role = "assistant", content = { { type = "text", text = string.rep("a", 64) } } },
    }
  end
  local estimates = 0
  ---@type Neoagent.Model
  local model = { api = "benchmark", provider = "benchmark", id = "benchmark", input = { "text" },
    context_window = count * 128,
    stream = function() error("Planning must not call inference") end,
    estimate_request = function(self, options)
      estimates = estimates + 1
      return #options.messages > 4 and math.floor(assert(self.context_window) * 2) or 100
    end,
  }
  local options = { configured = { reserve_tokens = 1000, keep_recent_tokens = count * 12 },
    model = model, path = path, messages = tree.context_messages(path) }
  collectgarbage("collect")
  local elapsed, cpu = vim.uv.hrtime(), os.clock()
  local run = async.run(function()
    ---@type Neoagent.CompactionPlanningOptions
    local planning = vim.tbl_extend("force", options, { budget = compaction.local_component.evaluate(options) })
    local preparation, err = compaction.local_component.prepare(planning)
    assert(preparation, err and err.message)
    assert(preparation.first_kept_entry_id == tostring(count - 2), "Planner skipped the fitting suffix")
    return { ok = true }
  end)
  assert(vim.wait(30000, function() return run:is_done() end, 1), "Compaction planning did not finish")
  local result = assert(run:result())
  assert(result.ok, vim.inspect(result))
  local measurement = { entries = count, estimates = estimates,
    cpu_ms = (os.clock() - cpu) * 1000, elapsed_ms = (vim.uv.hrtime() - elapsed) / 1e6 }
  print(vim.json.encode(measurement))
  if vim.env.NEOAGENT_COMPACTION_BENCH_ENFORCE == "1" then
    assert(measurement.cpu_ms <= budgets[count], "Compaction planning exceeded its CPU budget")
  end
end
