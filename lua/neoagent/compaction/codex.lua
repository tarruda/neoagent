local request_preparation = require("neoagent.api.request_preparation")
local async = require("neoagent.async")
local checkpoint = require("neoagent.compaction.checkpoint")
local compaction = require("neoagent.compaction")
local reduction = require("neoagent.compaction.reduction")
local tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}

---@param path Neoagent.JournalEntry[]
---@param settings Neoagent.CompactionSettings
---@param source_messages Neoagent.RequestMessage[]
---@param request_messages Neoagent.RequestMessage[]
---@return Neoagent.NativeCompactionPreparation?
local function prepare(path, settings, source_messages, request_messages)
  if #path == 0 then
    return nil
  end
  local last = assert(path[#path])
  if last.type == "compaction" and not last.native then
    return nil
  end
  local entries = tree.context_entries(path)
  -- Reconsider a terminal native checkpoint after an immediate inference
  -- overflow. Its encrypted item is opaque, so only the retained user prefix
  -- can be reduced without changing the journal.
  local remaining = last.type == "compaction" and 0 or settings.keep_recent_tokens
  ---@type Neoagent.RetainedUser[]
  local retained = {}
  for index = #entries, 1, -1 do
    local entry = assert(entries[index])
    if entry.type == "message" and entry.message.role == "user" then
      local message = entry.message
      local text_chars, image_tokens = 0, 0
      if type(message.content) == "string" then
        text_chars = vim.fn.strchars(message.content)
      else
        for _, block in ipairs(message.content) do
          if block.type == "text" then
            text_chars = text_chars + vim.fn.strchars(block.text)
          elseif block.type == "image" then
            image_tokens = image_tokens + compaction.estimate_tokens({ role = "user", content = { block } })
          end
        end
      end
      local tokens = compaction.estimate_tokens(message)
      local kept_chars = math.min(text_chars, math.max(0, remaining - image_tokens) * 4)
      if image_tokens <= remaining and (kept_chars > 0 or image_tokens > 0) then
        table.insert(retained, 1, { entry_id = entry.id, text_chars = kept_chars })
      end
      remaining = remaining - tokens
      if remaining <= 0 then
        break
      end
    end
  end
  return {
    kind = "native",
    source_messages = util.copy(source_messages),
    request_messages = request_messages,
    retained_users = retained,
    tokens_before = math.ceil(compaction.estimate_context(tree.context_messages(path)).tokens),
    settings = util.copy(settings),
  }
end

---@async
---@param model Neoagent.Model
---@param messages Neoagent.RequestMessage[]
---@param system_prompt? string
---@param tools? Neoagent.ToolDefinition[]
---@param force_reduce? boolean
---@param fraction? number
---@param inherited? Neoagent.StreamOverrides
---@return Neoagent.RequestMessage[]?, Neoagent.Error?
local function bounded_request(model, messages, system_prompt, tools, force_reduce, fraction, inherited)
  local estimate = require("neoagent.api.request_estimate")
  local call = request_preparation.copy(inherited or {})
  ---@cast call Neoagent.StreamOptions
  call.messages, call.system_prompt, call.tools = messages, system_prompt, tools
  local target = model.context_window or math.huge
  if force_reduce then
    local tokens = estimate.request(model, call, "compact") + 32
    target =
      math.min(math.floor(target * (fraction or 1)), 32 + math.floor(math.max(0, tokens - 32) * (fraction or 0.5)))
  end
  return reduction.request(model, call, target, true, "compact")
end

---@param options Neoagent.CompactionRunOptions
---@return Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
local function run(options)
  return async.run(function(run)
    local model = options.model
    if model.api ~= "openai-codex-responses" or type(model.compact) ~= "function" then
      return {
        ok = false,
        error = util.error("compaction", "Codex Profile requires a Codex Model with native compaction"),
      }
    end
    if options.instructions and util.trim(options.instructions) ~= "" then
      return { ok = false, error = util.error("compaction", "Native compaction does not support custom instructions") }
    end
    local preparation = options.preparation
    if preparation.kind ~= "native" then
      return { ok = false, error = util.error("compaction", "Codex compaction requires native preparation") }
    end
    ---@cast preparation Neoagent.NativeCompactionPreparation
    local bounded = util.copy(preparation.request_messages)
    local inherited = options.model_options or {}
    ---@type Neoagent.NativeCompactionOptions
    local model_options = {
      messages = bounded,
      _preparation = request_preparation.new(),
      files = inherited.files,
      file_cache = inherited.file_cache,
      request_context = inherited.request_context,
      system_prompt = options.system_prompt,
      tools = util.copy(options.tools or {}),
      timeout_ms = inherited.timeout_ms,
      request_opts = inherited.request_opts,
      thinking_level = inherited.thinking_level,
    }
    model_options.on_event = function(event)
      if event.type == "provider_status" or event.type == "inference_stats" then
        run:emit(event)
      end
    end
    local result
    for attempt = 0, 2 do
      require("neoagent.api.request_estimate").request(model, model_options, "compact")
      result = model:compact(model_options):await()
      if result.ok then
        break
      end
      if attempt == 2 or not require("neoagent.model").is_context_overflow(result.error) then
        if attempt == 2 then
          result.error.retry_exhausted = "native_reduction"
        end
        return { ok = false, error = result.error }
      end
      local reduced = bounded_request(
        model,
        preparation.source_messages,
        options.system_prompt,
        options.tools,
        true,
        attempt == 0 and 0.75 or 0.5,
        options.model_options
      )
      if not reduced or vim.deep_equal(reduced, bounded) then
        result.error.retry_exhausted = "native_reduction"
        return { ok = false, error = result.error }
      end
      bounded = reduced
      model_options.messages = bounded
    end
    assert(result and result.ok)
    return {
      ok = true,
      native = result.item,
      retained_users = util.copy(preparation.retained_users),
      tokens_before = preparation.tokens_before,
      usage = result.usage,
    }
  end, {
    on_event = options.on_event,
    on_done = options.on_done,
    report = options.report,
    error_kind = "compaction",
  })
end

---@async
---@param candidate Neoagent.CompactionSuccess
---@param options Neoagent.CheckpointAcceptanceOptions
---@return Neoagent.CompactionSuccess?, Neoagent.Error?
local function fit(candidate, options)
  candidate = util.copy(candidate)
  local limit = options.model.context_window and options.model.context_window - options.settings.reserve_tokens
    or math.huge
  ---@async
  local function evaluate()
    return checkpoint.evaluate(candidate, options)
  end
  local tokens, messages = evaluate()
  if not tokens then
    return nil, messages --[[@as Neoagent.Error]]
  end
  local retained = candidate.native and candidate.retained_users
  while tokens > limit and retained and #retained > 0 do
    async.yield()
    local first = assert(retained[1])
    local user = assert(messages[1]) --[[@as Neoagent.UserMessage]]
    local total, images = 0, false
    if type(user.content) == "string" then
      total = vim.fn.strchars(user.content)
    else
      for _, block in ipairs(user.content) do
        if block.type == "text" then
          total = total + vim.fn.strchars(block.text)
        elseif block.type == "image" then
          images = true
        end
      end
    end
    first.text_chars = 0
    local minimum, projected = evaluate()
    if not minimum then
      return nil, projected --[[@as Neoagent.Error]]
    end
    if minimum <= limit then
      local kept, low, high = 0, 1, total - 1
      tokens, messages = minimum, projected
      while low <= high do
        async.yield()
        local middle = math.floor((low + high) / 2)
        first.text_chars = middle
        local current, current_messages = evaluate()
        if not current then
          return nil, current_messages --[[@as Neoagent.Error]]
        end
        if current <= limit then
          kept, tokens, messages = middle, current, current_messages
          low = middle + 1
        else
          high = middle - 1
        end
      end
      first.text_chars = kept
      if kept > 0 or images then
        break
      end
    end
    -- Retention is a newest-first contiguous selection. Drop an oversized
    -- boundary (including its images), never backfill older journal entries.
    table.remove(retained, 1)
    tokens, messages = evaluate()
    if not tokens then
      return nil, messages --[[@as Neoagent.Error]]
    end
  end
  return candidate
end

---@type Neoagent.CompactionComponent
M.component = {
  fit = fit,
  evaluate = compaction.evaluate_budget,
  prepare = function(options)
    local bounded, err = bounded_request(
      options.model,
      options.messages,
      options.system_prompt,
      options.tools,
      nil,
      nil,
      options.model_options
    )
    if not bounded then
      return nil, err
    end
    return prepare(options.path, options.budget.settings, options.messages, bounded)
  end,
  run = run,
  require_native = true,
  required_api = "openai-codex-responses",
}

return M
