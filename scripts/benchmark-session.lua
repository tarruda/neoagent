local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local fs = require("neoagent.fs")

local iterations = tonumber(vim.env.NEOAGENT_SESSION_BENCH_ITERATIONS) or 5
assert(iterations >= 1 and iterations % 1 == 0, "NEOAGENT_SESSION_BENCH_ITERATIONS must be a positive integer")
---@cast iterations integer
local directory = vim.fn.tempname()
local budget_ms = 150

local ok, measurement = xpcall(function()
  local seed = storage.new({ directory = directory, cwd = vim.fn.getcwd() })
  local workspace = seed:workspace_storage()
  assert(workspace.prepare())
  assert(fs.ensure_private_directory(workspace.sessions_directory, 448))
  local metadata = seed:metadata()
  local path = assert(metadata.path)
  local records = { vim.json.encode({
    type = "session", format = "neoagent-session", id = metadata.id,
    cwd = vim.fn.getcwd(), created_at = 1,
  }) }
  ---@type string?
  local parent
  ---@param entry Neoagent.JournalEntryInput
  local function record(entry)
    entry.id = "entry-" .. #records
    entry.parent_id = parent or vim.NIL
    entry.created_at = 1
    parent = entry.id
    records[#records + 1] = vim.json.encode(entry)
  end
  local thinking = (string.rep("Inspect synthetic validation and bounded cancellation. ", 5) .. "\n"):rep(12)
  local output = (string.rep("Synthetic operation completed with a bounded result. ", 10) .. "\n"):rep(8)
  ---@param id string
  ---@return Neoagent.AssistantMessage
  local function assistant(id)
    return { role = "assistant", content = {
      { type = "thinking", thinking = thinking },
      { type = "toolCall", id = id, name = "inspect", arguments = { path = "synthetic.lua" } },
    }, stopReason = "toolUse", model = "synthetic" }
  end
  ---@param id string
  ---@return Neoagent.ToolResultMessage
  local function result(id)
    return { role = "toolResult", toolCallId = id, toolName = "inspect",
      content = { { type = "text", text = output } } }
  end
  record({ type = "message", message = { role = "user", content = "Inspect the synthetic project." } })
  for index = 1, 3500 do
    record({ type = "message", message = assistant("history-" .. index) })
    record({ type = "message", message = result("history-" .. index) })
    if index % 500 == 0 then
      record({
        type = "compaction", tokens_before = 100000,
        native = {
          role = "nativeCompaction", api = "openai-codex-responses",
          provider = "openai-codex", model = "synthetic",
          encrypted_content = "synthetic-checkpoint",
        },
        retained_users = { { entry_id = "entry-1" } },
      })
    end
  end
  assert(fs.atomic_replace(path, table.concat(records, "\n") .. "\n", { mode = 384 }))
  records = {}
  local store = assert(storage.open(path, workspace))
  local session = assert(Session.new({ store = store }))
  local context_messages = #assert(session:context_messages())
  assert(context_messages == 2)
  collectgarbage("collect")
  local started = vim.uv.hrtime()
  for index = 1, iterations do
    local id = "measured-" .. index
    assert(session:append(assistant(id)))
    assert(session:append(result(id)))
  end
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  local messages = session:messages()
  assert(#messages == 7008 + 2 * iterations)
  assert(messages[#messages].role == "toolResult")
  local duplicate, err = session:append(result("measured-" .. iterations))
  assert(not duplicate and err and tostring(err.detail):find("unknown toolCall", 1, true))
  local reopened = assert(Session.new({ store = assert(storage.open(path, workspace)) }))
  assert(#reopened:messages() == #messages)
  return {
    history_messages = 7001, compactions = 7, context_messages = context_messages,
    iterations = iterations, tool_cycle_ms = elapsed / iterations,
  }
end, debug.traceback)
vim.fn.delete(directory, "rf")
assert(ok, measurement)
vim.api.nvim_out_write("SESSION_BENCHMARK " .. vim.json.encode(measurement) .. "\n")
if vim.env.NEOAGENT_SESSION_BENCH_ENFORCE == "1" then
  assert(measurement.tool_cycle_ms <= budget_ms,
    ("Session tool cycle budget exceeded: %.3f > %.3f ms"):format(measurement.tool_cycle_ms, budget_ms))
end
