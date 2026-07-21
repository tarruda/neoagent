local async = require("neoagent.async")
local tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}

M.defaults = {
  auto = true,
  reserve_tokens = 16384,
  keep_recent_tokens = 20000,
}

M.system_prompt = [[You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.]]

local summary_prompt = [[The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

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

local update_summary_prompt = [[The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use the same structured format as the existing summary. Keep each section concise.]]

local turn_prefix_prompt = [[This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

Summarize the prefix to provide context for the retained suffix:

## Original Request
[What did the user ask for in this turn?]

## Early Progress
- [Key decisions and work done in the prefix]

## Context for Suffix
- [Information needed to understand the retained recent work]

Be concise. Focus on what's needed to understand the kept suffix.]]

local function content_chars(content)
  if type(content) == "string" then return vim.fn.strchars(content) end
  local count = 0
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      count = count + vim.fn.strchars(block.text or "")
    elseif block.type == "image" then
      count = count + 4800
    end
  end
  return count
end

function M.usage_tokens(usage)
  if type(usage) ~= "table" then return nil end
  if type(usage.totalTokens) == "number" and usage.totalTokens > 0 then return usage.totalTokens end
  local total = 0
  for _, key in ipairs({ "input", "output", "cacheRead", "cacheWrite" }) do
    if type(usage[key]) == "number" then total = total + usage[key] end
  end
  return total > 0 and total or nil
end

function M.estimate_tokens(message)
  if message.role == "user" or message.role == "toolResult" or message.role == "custom" then
    return math.ceil(content_chars(message.content) / 4)
  end
  if message.role == "assistant" then
    local chars = 0
    for _, block in ipairs(message.content or {}) do
      if block.type == "text" then
        chars = chars + vim.fn.strchars(block.text or "")
      elseif block.type == "thinking" then
        chars = chars + vim.fn.strchars(block.thinking or "")
      elseif block.type == "toolCall" then
        local ok, encoded = pcall(vim.json.encode, block.arguments or {})
        chars = chars + #(block.name or "") + (ok and #encoded or 16)
      end
    end
    return math.ceil(chars / 4)
  end
  if message.role == "bashExecution" then
    return math.ceil((#(message.command or "") + #(message.output or "")) / 4)
  end
  if message.role == "branchSummary" or message.role == "compactionSummary" then
    return math.ceil(#(message.summary or "") / 4)
  end
  return 0
end

local function valid_assistant_usage(message)
  if message.role ~= "assistant" or message.stopReason == "aborted" or message.stopReason == "error" then return nil end
  return M.usage_tokens(message.usage)
end

function M.estimate_context(messages)
  for index = #messages, 1, -1 do
    local usage = valid_assistant_usage(messages[index])
    if usage then
      local trailing = 0
      for trailing_index = index + 1, #messages do
        trailing = trailing + M.estimate_tokens(messages[trailing_index])
      end
      return { tokens = usage + trailing, usage_tokens = usage, trailing_tokens = trailing, last_usage_index = index }
    end
  end
  local total = 0
  for _, message in ipairs(messages) do total = total + M.estimate_tokens(message) end
  return { tokens = total, usage_tokens = 0, trailing_tokens = total }
end

function M.settings(configured, context_window)
  configured = util.deep_merge(M.defaults, configured or {})
  local reserve = configured.reserve_tokens
  local keep = configured.keep_recent_tokens
  if type(context_window) == "number" and context_window > 0 then
    reserve = math.min(reserve, math.max(1, math.floor(context_window / 4)))
    keep = math.min(keep, math.max(1, math.floor((context_window - reserve) / 2)))
  end
  return { auto = configured.auto, reserve_tokens = reserve, keep_recent_tokens = keep }
end

function M.should_compact(context_tokens, context_window, settings)
  return settings.auto and context_window > 0 and context_tokens > context_window - settings.reserve_tokens
end

local function entry_message(entry)
  if entry.type == "compaction" then return nil end
  return tree.entry_messages(entry)[1]
end

local function is_cut_point(entry)
  if entry.type == "branch_summary" or entry.type == "custom_message" then return true end
  if entry.type ~= "message" then return false end
  local role = entry.message.role
  return role == "user" or role == "assistant" or role == "bashExecution"
      or role == "custom" or role == "branchSummary" or role == "compactionSummary"
end

local function is_turn_start(entry)
  if entry.type == "branch_summary" or entry.type == "custom_message" then return true end
  return entry.type == "message" and (entry.message.role == "user" or entry.message.role == "bashExecution")
end

function M.find_turn_start(entries, entry_index, start_index)
  for index = entry_index, start_index, -1 do
    if is_turn_start(entries[index]) then return index end
  end
end

function M.find_cut_point(entries, start_index, end_index, keep_recent_tokens)
  local cut_points = {}
  for index = start_index, end_index do
    if is_cut_point(entries[index]) then cut_points[#cut_points + 1] = index end
  end
  if #cut_points == 0 then
    return { first_kept_index = start_index, split_turn = false }
  end
  local accumulated = 0
  local cut_index = cut_points[1]
  for index = end_index, start_index, -1 do
    local entry = entries[index]
    if entry.type == "message" then
      accumulated = accumulated + M.estimate_tokens(entry.message)
    end
    if accumulated >= keep_recent_tokens then
      for _, candidate in ipairs(cut_points) do
        if candidate >= index then cut_index = candidate break end
      end
      break
    end
  end
  while cut_index > start_index do
    local previous = entries[cut_index - 1]
    if previous.type == "compaction" or previous.type == "message" then break end
    cut_index = cut_index - 1
  end
  local turn_start
  if not is_turn_start(entries[cut_index]) then
    turn_start = M.find_turn_start(entries, cut_index, start_index)
  end
  return {
    first_kept_index = cut_index,
    turn_start_index = turn_start,
    split_turn = turn_start ~= nil,
  }
end

function M.prepare(path_entries, settings)
  if #path_entries == 0 or path_entries[#path_entries].type == "compaction" then return nil end
  local previous_index
  for index = #path_entries, 1, -1 do
    if path_entries[index].type == "compaction" then previous_index = index break end
  end
  local boundary_start = 1
  local previous_summary
  if previous_index then
    local previous = path_entries[previous_index]
    previous_summary = previous.summary
    for index, entry in ipairs(path_entries) do
      if entry.id == previous.firstKeptEntryId then boundary_start = index break end
    end
    if boundary_start == 1 and path_entries[1].id ~= previous.firstKeptEntryId then
      boundary_start = previous_index + 1
    end
  end
  local context = tree.to_llm(tree.messages(path_entries, true))
  local cut = M.find_cut_point(path_entries, boundary_start, #path_entries, settings.keep_recent_tokens)
  local first_kept = path_entries[cut.first_kept_index]
  if not first_kept then return nil, util.error("compaction", "No context entry can be retained") end
  local history_end = cut.split_turn and cut.turn_start_index or cut.first_kept_index
  local messages = {}
  for index = boundary_start, history_end - 1 do
    local message = entry_message(path_entries[index])
    if message then messages[#messages + 1] = message end
  end
  local turn_prefix = {}
  if cut.split_turn then
    for index = cut.turn_start_index, cut.first_kept_index - 1 do
      local message = entry_message(path_entries[index])
      if message then turn_prefix[#turn_prefix + 1] = message end
    end
  end
  if #messages == 0 and #turn_prefix == 0 then
    return nil, util.error("compaction", "Nothing can be compacted while retaining the recent context")
  end
  return {
    first_kept_entry_id = first_kept.id,
    messages = messages,
    turn_prefix = turn_prefix,
    split_turn = cut.split_turn,
    tokens_before = M.estimate_context(context).tokens,
    previous_summary = previous_summary,
    settings = util.copy(settings),
  }
end

local function content_text(content)
  local parts = {}
  for _, block in ipairs(type(content) == "string" and { { type = "text", text = content } } or content or {}) do
    if block.type == "text" then parts[#parts + 1] = block.text or "" end
  end
  return table.concat(parts)
end

local function truncate(text, maximum)
  if vim.fn.strchars(text) <= maximum then return text end
  local omitted = vim.fn.strchars(text) - maximum
  return vim.fn.strcharpart(text, 0, maximum) .. "\n\n[... " .. omitted .. " more characters truncated]"
end

function M.serialize(messages)
  local parts = {}
  for _, message in ipairs(tree.to_llm(messages)) do
    if message.role == "user" then
      local text = content_text(message.content)
      if text ~= "" then parts[#parts + 1] = "[User]: " .. text end
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
      if #thinking > 0 then parts[#parts + 1] = "[Assistant thinking]: " .. table.concat(thinking, "\n") end
      if #text > 0 then parts[#parts + 1] = "[Assistant]: " .. table.concat(text) end
      if #calls > 0 then parts[#parts + 1] = "[Assistant tool calls]: " .. table.concat(calls, "; ") end
    elseif message.role == "toolResult" then
      local text = content_text(message.content)
      if text ~= "" then parts[#parts + 1] = "[Tool result]: " .. truncate(text, 2000) end
    end
  end
  return table.concat(parts, "\n\n")
end

local function add_usage(first, second)
  if not first then return util.copy(second) end
  if not second then return util.copy(first) end
  local result = {}
  for _, key in ipairs({
    "input", "output", "cacheRead", "cacheWrite", "cacheWrite1h", "reasoning", "totalTokens",
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

local function prompt(messages, previous_summary, instructions, suffix)
  local text = "<conversation>\n" .. M.serialize(messages) .. "\n</conversation>\n\n"
  if previous_summary then
    text = text .. "<previous-summary>\n" .. previous_summary .. "\n</previous-summary>\n\n"
  end
  text = text .. suffix
  if instructions and util.trim(instructions) ~= "" then text = text .. "\n\nAdditional focus: " .. instructions end
  return text
end

local function summarize(run, opts, messages, previous, instructions, suffix, phase)
  local model_options = util.copy(opts.model_options or {})
  model_options.messages = { {
    role = "user",
    content = { { type = "text", text = prompt(messages, previous, instructions, suffix) } },
    timestamp = util.now_ms(),
  } }
  model_options.system_prompt = M.system_prompt
  model_options.tools = {}
  model_options.on_event = function(event)
    if event.type == "text_delta" then
      run:emit({ type = "compaction_delta", phase = phase, text = event.text })
    elseif event.type == "provider_status" then
      run:emit(event)
    end
  end
  local result = opts.model:stream(model_options):await()
  if not result.ok then return nil, util.normalize_error(result.error, "compaction") end
  local text = result.text or (result.message and content_text(result.message.content)) or ""
  text = util.trim(text)
  if text == "" then return nil, util.error("compaction", "Summarization returned no text") end
  return { text = text, usage = result.message and result.message.usage }
end

function M.run(opts)
  assert(type(opts) == "table" and type(opts.preparation) == "table", "preparation is required")
  assert(type(opts.model) == "table" and type(opts.model.stream) == "function", "model is required")
  return async.run(function(run)
    local preparation = opts.preparation
    local summary
    local usage
    if preparation.split_turn and #preparation.turn_prefix > 0 then
      local history = "No prior history."
      if #preparation.messages > 0 then
        local generated, err = summarize(run, opts, preparation.messages, preparation.previous_summary,
          opts.instructions, preparation.previous_summary and update_summary_prompt or summary_prompt, "history")
        if not generated then return { ok = false, error = err } end
        history, usage = generated.text, generated.usage
      end
      local prefix, err = summarize(run, opts, preparation.turn_prefix, nil, nil, turn_prefix_prompt, "turn_prefix")
      if not prefix then return { ok = false, error = err } end
      summary = history .. "\n\n---\n\n**Turn Context (split turn):**\n\n" .. prefix.text
      usage = add_usage(usage, prefix.usage)
    else
      local generated, err = summarize(run, opts, preparation.messages, preparation.previous_summary,
        opts.instructions, preparation.previous_summary and update_summary_prompt or summary_prompt, "history")
      if not generated then return { ok = false, error = err } end
      summary, usage = generated.text, generated.usage
    end
    return {
      ok = true,
      summary = summary,
      first_kept_entry_id = preparation.first_kept_entry_id,
      tokens_before = preparation.tokens_before,
      usage = usage,
    }
  end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "compaction" })
end

return M
