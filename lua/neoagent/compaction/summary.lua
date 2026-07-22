local async = require("neoagent.async")
local tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}

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

local function summarize(run, opts, messages, previous, instructions, suffix, phase, system_prompt)
  local model_options = util.copy(opts.model_options or {})
  model_options.messages = { {
    role = "user",
    content = { { type = "text", text = prompt(messages, previous, instructions, suffix) } },
    timestamp = util.now_ms(),
  } }
  model_options.system_prompt = system_prompt or M.system_prompt
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

function M.run(opts, system_prompt)
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
          opts.instructions, preparation.previous_summary and update_summary_prompt or summary_prompt, "history",
          system_prompt)
        if not generated then return { ok = false, error = err } end
        history, usage = generated.text, generated.usage
      end
      local prefix, err = summarize(run, opts, preparation.turn_prefix, nil, nil, turn_prefix_prompt,
        "turn_prefix", system_prompt)
      if not prefix then return { ok = false, error = err } end
      summary = history .. "\n\n---\n\n**Turn Context (split turn):**\n\n" .. prefix.text
      usage = add_usage(usage, prefix.usage)
    else
      local generated, err = summarize(run, opts, preparation.messages, preparation.previous_summary,
        opts.instructions, preparation.previous_summary and update_summary_prompt or summary_prompt, "history",
        system_prompt)
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
