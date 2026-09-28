local request_preparation = require("neoagent.api.request_preparation")
local async = require("neoagent.async")
local plan = require("neoagent.compaction.plan")
local tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}

M.split_summary_separator = "\n\n---\n\n**Turn Context (split turn):**\n\n"

---@class Neoagent.GeneratedSummary
---@field text string
---@field usage? Neoagent.Usage

M.system_prompt =
  [[You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.]]

M.checkpoint_prompt =
  [[The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.]]

local update_summary_prompt =
  [[The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use the same structured format as the existing summary. Keep each section concise.]]

local turn_prefix_prompt =
  [[This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

Summarize the prefix to provide context for the retained suffix:

## Original Request
[What did the user ask for in this turn?]

## Early Progress
- [Key decisions and work done in the prefix]

## Context for Suffix
- [Information needed to understand the retained recent work]

Be concise. Focus on what's needed to understand the kept suffix.]]

---@param content? (Neoagent.InputBlock|Neoagent.AssistantBlock)[]
---@return string
local function content_text(content)
  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      parts[#parts + 1] = block.text or ""
    end
  end
  return table.concat(parts)
end

---@param messages Neoagent.Message[]
---@return Neoagent.InputBlock[]
local function serialize_blocks(messages)
  ---@type Neoagent.InputBlock[]
  local blocks = {}
  local parts = {}
  local first = true
  ---@param value string
  local function add_text(value)
    parts[#parts + 1] = value
  end
  local function separate()
    if not first then
      add_text("\n\n")
    end
    first = false
  end
  ---@param image Neoagent.ImageBlock
  local function add_image(image)
    local text = table.concat(parts)
    if text ~= "" then
      blocks[#blocks + 1] = { type = "text", text = text }
    end
    parts = {}
    blocks[#blocks + 1] = util.copy(image)
  end
  for _, message in ipairs(tree.to_llm(messages)) do
    if message.role == "user" then
      if type(message.content) == "string" then
        if message.content ~= "" then
          separate()
          add_text("[User]: " .. message.content)
        end
      elseif #message.content > 0 then
        separate()
        add_text("[User]: ")
        for _, block in ipairs(message.content) do
          if block.type == "text" then
            add_text(block.text or "")
          elseif block.type == "image" then
            add_text("[Image attachment] ")
            add_image(block)
          end
        end
      end
    elseif message.role == "assistant" then
      local thinking, calls, text = {}, {}, {}
      for _, block in ipairs(message.content or {}) do
        if block.type == "thinking" then
          thinking[#thinking + 1] = block.thinking or ""
        elseif block.type == "text" then
          text[#text + 1] = block.text or ""
        elseif block.type == "toolCall" then
          local fields = {}
          for key, value in pairs(block.arguments or {}) do
            local ok, encoded = pcall(vim.json.encode, value)
            fields[#fields + 1] = key .. "=" .. (ok and encoded or "[unserializable]")
          end
          table.sort(fields)
          calls[#calls + 1] = tostring(block.name) .. "(" .. table.concat(fields, ", ") .. ")"
        end
      end
      if #thinking > 0 then
        separate()
        add_text("[Assistant thinking]: " .. table.concat(thinking, "\n"))
      end
      if #text > 0 then
        separate()
        add_text("[Assistant]: " .. table.concat(text))
      end
      if #calls > 0 then
        separate()
        add_text("[Assistant tool calls]: " .. table.concat(calls, "; "))
      end
    elseif message.role == "toolResult" then
      local text = content_text(message.content)
      if text ~= "" or #message.content > 0 then
        separate()
        add_text("[Tool result]: ")
        local remaining = 2000
        for _, block in ipairs(message.content) do
          if block.type == "text" then
            local chars = vim.fn.strchars(block.text or "")
            if remaining > 0 then
              add_text(vim.fn.strcharpart(block.text or "", 0, remaining))
              remaining = math.max(0, remaining - chars)
            end
          elseif block.type == "image" then
            add_text("[Image attachment] ")
            add_image(block)
          end
        end
        if vim.fn.strchars(text) > 2000 then
          add_text("\n\n[... " .. (vim.fn.strchars(text) - 2000) .. " more characters truncated]")
        end
      end
    end
  end
  local text = table.concat(parts)
  if text ~= "" then
    blocks[#blocks + 1] = { type = "text", text = text }
  end
  return blocks
end

---@param messages Neoagent.Message[]
---@return string
function M.serialize(messages)
  local text = {}
  for _, block in ipairs(serialize_blocks(messages)) do
    if block.type == "text" then
      text[#text + 1] = block.text
    end
  end
  return table.concat(text)
end

---@param selection Neoagent.LocalCompactionSelection
---@return Neoagent.LocalCheckpointPlan
local function assemble(selection)
  local split_turn = selection.turn_start_entry_id ~= nil
  local known, generations = "", 1
  if split_turn then
    local has_history = false
    for _, entry in ipairs(selection.consumed) do
      if entry.id == selection.turn_start_entry_id then
        break
      end
      if entry.type == "message" then
        has_history = true
        break
      end
    end
    known = M.split_summary_separator
    if has_history then
      generations = 2
    else
      known = (selection.previous_summary or "No prior history.") .. known
    end
  end
  return {
    known_summary = known,
    generations = generations,
    build = function(max_output_tokens)
      ---@type Neoagent.CompactionPreparation
      local preparation = {
        kind = "summary",
        messages = {},
        turn_prefix = {},
        split_turn = split_turn,
        first_kept_entry_id = selection.first_kept_entry_id,
        previous_summary = selection.previous_summary,
        tokens_before = selection.tokens_before,
        settings = selection.settings,
        max_output_tokens = max_output_tokens,
      }
      local prefix = false
      for _, entry in ipairs(selection.consumed) do
        prefix = prefix or entry.id == selection.turn_start_entry_id
        if entry.type == "message" then
          local target = prefix and preparation.turn_prefix or preparation.messages
          target[#target + 1] = util.copy(entry.message)
        end
      end
      return preparation
    end,
  }
end

---@async
---@param options Neoagent.CompactionPlanningOptions
---@return Neoagent.AnyCompactionPreparation?, Neoagent.Error?
function M.prepare(options)
  return plan.prepare_local(options, assemble)
end

---@param first? Neoagent.Usage
---@param second? Neoagent.Usage
---@return Neoagent.Usage?
local function add_usage(first, second)
  if not first then
    return util.copy(second)
  end
  if not second then
    return util.copy(first)
  end
  ---@type Neoagent.Usage
  local result = {}
  for _, key in ipairs({
    "input",
    "output",
    "cacheRead",
    "cacheWrite",
    "reasoning",
    "totalTokens",
  }) do
    result[key] = (first[key] or 0) + (second[key] or 0)
  end
  if first.cost or second.cost then
    result.cost = {}
    for _, key in ipairs({ "input", "output", "cacheRead", "cacheWrite", "total" }) do
      result.cost[key] = ((first.cost or {})[key] or 0) + ((second.cost or {})[key] or 0)
    end
  end
  return result
end

---@param messages Neoagent.Message[]
---@param previous_summary? string
---@param instructions? string
---@param suffix string
---@return Neoagent.InputBlock[]
local function prompt(messages, previous_summary, instructions, suffix)
  ---@type Neoagent.InputBlock[]
  local content = { { type = "text", text = "<conversation>\n" } }
  vim.list_extend(content, serialize_blocks(messages))
  local text = "\n</conversation>\n\n"
  if previous_summary then
    text = text .. "<previous-summary>\n" .. previous_summary .. "\n</previous-summary>\n\n"
  end
  text = text .. suffix
  if instructions and util.trim(instructions) ~= "" then
    text = text .. "\n\nAdditional focus: " .. instructions
  end
  content[#content + 1] = { type = "text", text = text }
  return content
end

-- Strategies select summary effort; Models translate the selected level.
-- A lower inherited selection (including off) must never be raised.
---@param model Neoagent.Model
---@param options Neoagent.StreamOptions
---@param output_limit integer
---@return Neoagent.StreamOptions
function M.generation_options(model, options, output_limit)
  local call = request_preparation.copy(options)
  call.max_output_tokens = output_limit
  local thinking_limit = math.max(1024, math.min(2048, math.floor(output_limit / 4)))
  call.max_thinking_tokens = math.min(call.max_thinking_tokens or thinking_limit, thinking_limit)
  local thinking = require("neoagent.thinking")
  local levels = thinking.levels(model)
  local preferred = levels[1]
  for _, level in ipairs(levels) do
    if level ~= "off" then
      preferred = level
      break
    end
  end
  if vim.tbl_contains(levels, "low") then
    preferred = "low"
  end
  if call.thinking_level and call.thinking_level ~= "off" and preferred then
    for _, level in ipairs(thinking.order) do
      if level == call.thinking_level then
        break
      end
      if level == preferred then
        call.thinking_level = preferred
        break
      end
    end
  end
  return call
end

---@async
---@param run Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
---@param model Neoagent.Model
---@param model_options Neoagent.StreamOptions
---@param phase "history"|"turn_prefix"
---@return Neoagent.GeneratedSummary?, Neoagent.Error?
---@return_overload Neoagent.GeneratedSummary
---@return_overload nil, Neoagent.Error
function M.generate(run, model, model_options, phase)
  model_options._preparation = model_options._preparation or request_preparation.new()
  local tokens = require("neoagent.api.request_estimate").request(model, model_options) + 32
  for _, message in ipairs(model_options.messages) do
    if (message.role == "user" or message.role == "toolResult") and type(message.content) == "table" then
      for _, block in ipairs(message.content) do
        if block.type == "image" and not vim.tbl_contains(model.input, "image") then
          return nil, util.error("compaction", "The summarizing Model cannot read consumed images")
        end
      end
    end
  end
  if model.context_window and tokens + assert(model_options.max_output_tokens) > model.context_window then
    return nil, util.error("compaction", "The summary request exceeds the Model window")
  end
  ---@param event Neoagent.ModelEvent
  model_options.on_event = function(event)
    if event.type == "text_delta" then
      ---@cast event Neoagent.ModelTextDelta
      run:emit({ type = "compaction_delta", phase = phase, text = event.text })
    elseif event.type == "provider_status" then
      ---@cast event Neoagent.ModelProviderStatus
      run:emit(event)
    elseif event.type == "inference_stats" then
      ---@cast event Neoagent.ModelInferenceStats
      run:emit(event)
    end
  end
  local result = model:stream(model_options):await()
  if
    not result.ok
    and result.error
    and rawget(result.error, "retryable") == true
    and not result.error.retry_exhausted
  then
    async.yield()
    result = model:stream(model_options):await()
    if not result.ok then
      result.error.retry_exhausted = result.error.retry_exhausted or "summary"
    end
  end
  if not result.ok then
    return nil, util.normalize_error(result.error, "compaction")
  end
  if result.message and result.message.stopReason == "length" then
    return nil, util.error("compaction", "Summarization exceeded its output limit")
  end
  local has_tool_call = result.message and result.message.stopReason == "toolUse"
  for _, block in ipairs(result.message and result.message.content or {}) do
    if block.type == "toolCall" then
      has_tool_call = true
    end
  end
  if has_tool_call then
    return nil, util.error("compaction", "Summarization returned a Tool call")
  end
  local text = result.text or (result.message and content_text(result.message.content)) or ""
  text = util.trim(text)
  if text == "" then
    return nil, util.error("compaction", "Summarization returned no text")
  end
  return { text = text, usage = result.message and result.message.usage }
end

---@async
---@param run Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
---@param opts Neoagent.CompactionRunOptions
---@param messages Neoagent.Message[]
---@param previous? string
---@param instructions? string
---@param suffix string
---@param phase "history"|"turn_prefix"
---@param system_prompt? string
---@return Neoagent.GeneratedSummary?, Neoagent.Error?
---@return_overload Neoagent.GeneratedSummary
---@return_overload nil, Neoagent.Error
local function summarize(run, opts, messages, previous, instructions, suffix, phase, system_prompt)
  local model_options = request_preparation.copy(opts.model_options or {})
  ---@cast model_options Neoagent.StreamOptions
  model_options._preparation = request_preparation.new()
  model_options.messages = {
    {
      role = "user",
      content = prompt(messages, previous, instructions, suffix),
      timestamp = util.now_ms(),
    },
  }
  model_options.system_prompt = system_prompt or M.system_prompt
  model_options.tools = {}
  local preparation = opts.preparation --[[@as Neoagent.CompactionPreparation]]
  local output_limit = plan.summary_output_limit(opts.model, preparation.settings)
  local planned_output = math.min(preparation.max_output_tokens or output_limit, output_limit)
  model_options = M.generation_options(opts.model, model_options, planned_output)
  return M.generate(run, opts.model, model_options, phase)
end

---@param opts Neoagent.CompactionRunOptions
---@param system_prompt? string
---@return Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
function M.run(opts, system_prompt)
  assert(type(opts) == "table" and type(opts.preparation) == "table", "preparation is required")
  assert(type(opts.model) == "table" and type(opts.model.stream) == "function", "model is required")
  assert(opts.report == nil or type(opts.report) == "function", "report must be a function")
  return async.run(
    ---@param run Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
    ---@return Neoagent.CompactionSuccess|Neoagent.AsyncFailure
    function(run)
      local preparation = opts.preparation
      if preparation.kind ~= "summary" then
        return { ok = false, error = util.error("compaction", "Summary compaction requires summary preparation") }
      end
      ---@cast preparation Neoagent.CompactionPreparation
      local summary
      local usage
      if preparation.split_turn and #preparation.turn_prefix > 0 then
        local history = preparation.previous_summary or "No prior history."
        if #preparation.messages > 0 then
          local generated, err = summarize(
            run,
            opts,
            preparation.messages,
            preparation.previous_summary,
            opts.instructions,
            preparation.previous_summary and update_summary_prompt or M.checkpoint_prompt,
            "history",
            system_prompt
          )
          if not generated then
            return { ok = false, error = err }
          end
          history, usage = generated.text, generated.usage
        end
        local prefix, err =
          summarize(run, opts, preparation.turn_prefix, nil, nil, turn_prefix_prompt, "turn_prefix", system_prompt)
        if not prefix then
          return { ok = false, error = err }
        end
        summary = history .. M.split_summary_separator .. prefix.text
        usage = add_usage(usage, prefix.usage)
      else
        local generated, err = summarize(
          run,
          opts,
          preparation.messages,
          preparation.previous_summary,
          opts.instructions,
          preparation.previous_summary and update_summary_prompt or M.checkpoint_prompt,
          "history",
          system_prompt
        )
        if not generated then
          return { ok = false, error = err }
        end
        summary, usage = generated.text, generated.usage
      end
      return {
        ok = true,
        summary = summary,
        first_kept_entry_id = preparation.first_kept_entry_id,
        tokens_before = preparation.tokens_before,
        usage = usage,
      }
    end,
    {
      on_event = opts.on_event,
      on_done = opts.on_done,
      report = opts.report,
      error_kind = "compaction",
    }
  )
end

return M
