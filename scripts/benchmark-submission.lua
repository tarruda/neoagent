local neoagent = require("neoagent")
local bit = require("bit")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local directory = vim.fn.tempname()
local previous_state = vim.env.XDG_STATE_HOME
vim.env.XDG_STATE_HOME = directory .. "/state"
local selection = { provider = "deepseek", model = "deepseek-v4.1-flash-expires-on-0910" }
-- Leave headroom for CI scheduling; measure native publication independently
-- of durable acceptance and the eventual provider request.
local budgets = { accepted_ms = 200, visible_ms = 300, request_ms = 400,
  storage_ms = 500, resume_ms = 1500 }
---@type Neoagent.Agent?
local agent
---@type Neoagent.NeoagentApplet?
local owner

local ok, measurement = xpcall(function()
  assert(fs.mkdirp(directory))
  local created_at = 1788825600000
  local store = require("neoagent.storage").new({ directory = directory .. "/storage", cwd = vim.fn.getcwd() })
  local workspace = store:workspace_storage()
  assert(workspace.prepare())
  assert(fs.ensure_private_directory(workspace.sessions_directory, 448))
  local path = store:metadata().path
  local records = { vim.json.encode({
    type = "session", format = "neoagent-session", id = store:metadata().id, created_at = created_at,
    cwd = vim.fn.getcwd(), metadata = { neoagent = { profileId = "neo" } },
  }) }
  local image_seed, image_bytes = 20260908, {}
  for index = 1, 1182 do
    image_seed = bit.bxor(image_seed, bit.lshift(image_seed, 13))
    image_seed = bit.bxor(image_seed, bit.rshift(image_seed, 17))
    image_seed = bit.bxor(image_seed, bit.lshift(image_seed, 5))
    image_bytes[index] = string.char(bit.band(image_seed, 255))
  end
  local image_data = table.concat(image_bytes):rep(1000)
  local source = string.rep('local item = "synthetic value"\n', 100)
  local thinking = string.rep("Inspect the synthetic module and verify its behavior.\n", 36)
  local text_bytes = 0
  ---@param message Neoagent.Message
  local function append(message)
    local index = #records
    records[#records + 1] = vim.json.encode({
      type = "message", id = tostring(index),
      parent_id = index == 1 and vim.NIL or tostring(index - 1),
      created_at = created_at, message = message,
      request = message.role == "user" and { model = selection } or nil,
    })
  end
  local call = 0
  for round = 0, 177 do
    if round % 30 == 0 then append({ role = "user", content = "Inspect the synthetic project." }) end
    ---@type Neoagent.AssistantBlock[]
    local content = { round < 112 and { type = "thinking", thinking = thinking }
      or { type = "text", text = string.rep("The synthetic module has been checked.\n", 10) } }
    ---@type Neoagent.ToolResultMessage[]
    local results = {}
    for _ = 1, round < 31 and 2 or round < 177 and 1 or 0 do
      local name = call < 36 and "read_file" or call < 56 and "write_file"
        or call < 128 and "edit_file" or call < 207 and "shell" or "update_plan"
      local source_path = "synthetic-" .. call .. ".lua"
      ---@type table<string, unknown>
      local arguments = { path = source_path }
      if name == "write_file" then arguments = { path = source_path, content = source:rep(3) }
      elseif name == "edit_file" then
        arguments = { path = source_path,
          edits = { { oldText = source, newText = (source:gsub("value", "result")) } } }
      elseif name == "shell" then arguments = { command = "printf synthetic" }
      elseif name == "update_plan" then arguments = { plan = { { step = "Inspect synthetic code", status = "completed" } } } end
      content[#content + 1] = { type = "toolCall", id = "call-" .. call, name = name, arguments = arguments }
      ---@type Neoagent.ToolResultMessage
      local result = { role = "toolResult", toolCallId = "call-" .. call, toolName = name,
        content = { { type = "text", text = string.rep("Synthetic operation completed.\n", 7) } } }
      if name == "read_file" then
        local publication = async.run(function()
          local file, err = workspace.files.put(image_data .. ("%04d"):format(call))
          if not file then error(err, 0) end
          return { ok = true, file = file }
        end)
        assert(vim.wait(10000, function() return publication:is_done() end, 1))
        local stored = assert(publication:result())
        if stored.ok == false then error(vim.inspect(stored.error), 0) end
        result.content[#result.content + 1] = { type = "image", mime_type = "image/png",
          file_id = stored.file.file_id, bytes = stored.file.bytes }
      end
      results[#results + 1] = result
      text_bytes = text_bytes + #util.json_encode(arguments)
      call = call + 1
    end
    append({ role = "assistant", content = content, stopReason = #results > 0 and "toolUse" or "stop",
      api = "openai-completions", provider = selection.provider, model = selection.model,
      usage = { input = 325200, output = 0, totalTokens = 325200 } })
    for _, result in ipairs(results) do append(result) end
  end
  assert(fs.atomic_replace(path, table.concat(records, "\n") .. "\n", { mode = 384 }))
  records = {}
  local uploads, inspections, requests = 0, 0, 0
  local remote = {}
  ---@type number?
  local started
  ---@type number?
  local accepted_ms
  ---@type number?
  local request_ms
  local published = false
  local prompt = ""
  ---@type integer?
  local transcript_buffer
  local function assert_published()
    local buffer = assert(transcript_buffer)
    local rows = vim.api.nvim_buf_line_count(buffer)
    local tail = table.concat(vim.api.nvim_buf_get_lines(buffer, math.max(0, rows - 12), -1, false), "\n")
    assert(tail:find(prompt, 1, true), "provider preparation preceded native prompt publication")
  end
  ---@type Neoagent.ByteBackend
  local backend = {
    fetch = function(opts)
      assert_published()
      return async.run(function()
        local id
        if opts.request.method == "POST" then
          uploads = uploads + 1
          id = "file-synthetic-" .. uploads
          remote[id] = { object = "file", id = id, bytes = #image_data + 4,
            purpose = "user_data", expires_at = os.time() + 86400 }
        else
          inspections = inspections + 1
          id = opts.request.url:match("([^/]+)$")
        end
        return { ok = true, status = 200, headers = {}, body = util.json_encode(assert(remote[id])) }
      end)
    end,
    request = function(opts)
      assert(published and accepted_ms, "request preceded durable message publication")
      assert_published()
      request_ms = (vim.uv.hrtime() - assert(started)) / 1e6
      requests = requests + 1
      assert(#assert(opts.request.body) < 2 * 1024 * 1024, "retained images were inlined again")
      return async.run(function()
        assert(opts.on_chunk)('data: {"choices":[{"delta":{"content":"Synthetic verification complete"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
        return { ok = true, response = { status = 200, headers = {} } }
      end)
    end,
  }
  owner = neoagent._setup({
    workspace_trust = false, default_registry = false, persistence = { enabled = false },
    default_model = selection, providers = { deepseek = {
      api = "openai-completions", base_url = "https://api.deepseek.com", auth = "deepseek",
      api_key = "synthetic-key", models = { [selection.model] = { input = { "text", "image" }, context_window = 1000000 } },
    } },
    agent_instructions = false, skills = false, sandbox = { enabled = false },
    compaction = { auto = true }, ui = { images = false },
  }, { transport = backend, startup = false })
  local storage = require("neoagent.storage")
  local open = storage.open
  local storage_ms
  storage.open = function(...)
    local start = vim.uv.hrtime()
    local store, err = open(...)
    storage_ms = (vim.uv.hrtime() - start) / 1e6
    return store, err
  end
  collectgarbage("collect")
  local resume_started = vim.uv.hrtime()
  local resumed, result, resume_error = pcall(owner.resume, owner, path)
  storage.open = open
  assert(resumed, result)
  assert(type(result) == "table", vim.inspect(resume_error))
  agent = result
  local active = result
  local pane = assert(assert(owner:view()):pane("transcript"))
  assert(pane:flush())
  vim.cmd("stopinsert")
  local resume_ms = (vim.uv.hrtime() - resume_started) / 1e6
  local buffer = assert(assert(pane:native()).buffer)
  transcript_buffer = buffer
  active:subscribe(function(update)
    if update.type == "messages" then
      local messages = assert(update.messages)
      if assert(messages[#messages]).content == prompt then published = true end
    elseif update.type == "submission_accepted" then
      accepted_ms = (vim.uv.hrtime() - assert(started)) / 1e6
    end
  end)
  local trials = {}
  for iteration = 1, 2 do
    prompt = "Inspect the synthetic result " .. iteration
    assert(owner:view()):set_input(prompt)
    accepted_ms, request_ms, published = nil, nil, false
    collectgarbage("collect")
    started = vim.uv.hrtime()
    local run = assert(owner:send(prompt))
    assert(type(run) == "table")
    local visible_ms
    assert(vim.wait(10000, function()
      if not visible_ms then
        local rows = vim.api.nvim_buf_line_count(buffer)
        local tail = table.concat(vim.api.nvim_buf_get_lines(buffer, math.max(0, rows - 12), -1, false), "\n")
        if tail:find(prompt, 1, true) then visible_ms = (vim.uv.hrtime() - assert(started)) / 1e6 end
      end
      return run:is_done() and visible_ms ~= nil
    end, 1), "submission did not complete and appear in the native transcript")
    local finished = assert(run:result())
    if finished.ok == false then error(vim.inspect(finished.error), 0) end
    trials[iteration] = { accepted_ms = assert(accepted_ms), request_ms = assert(request_ms),
      visible_ms = assert(visible_ms), total_ms = (vim.uv.hrtime() - started) / 1e6 }
  end
  assert(uploads == 36 and inspections == 0 and requests == 2, "unexpected image reuse or request count")
  return { history_messages = 392, tool_results = 208, tool_argument_bytes = text_bytes,
    image_count = 36, image_bytes = (#image_data + 4) * 36, cold = trials[1], warm = trials[2],
    accepted_ms = math.max(trials[1].accepted_ms, trials[2].accepted_ms),
    visible_ms = math.max(trials[1].visible_ms, trials[2].visible_ms), request_ms = trials[2].request_ms,
    storage_ms = assert(storage_ms), resume_ms = resume_ms }
end, debug.traceback)

if owner then owner:destroy() end
vim.env.XDG_STATE_HOME = previous_state
vim.fn.delete(directory, "rf")
assert(ok, measurement)
vim.api.nvim_out_write("SUBMISSION_BENCHMARK " .. vim.json.encode(measurement) .. "\n")
if vim.env.NEOAGENT_SUBMISSION_BENCH_ENFORCE == "1" then
  for name, budget in pairs(budgets) do
    assert(measurement[name] <= budget,
      ("Submission %s budget exceeded: %.3f > %.3f"):format(name, measurement[name], budget))
  end
end
