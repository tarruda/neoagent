local request_preparation = require("neoagent.api.request_preparation")
local async = require("neoagent.async")
local plan = require("neoagent.compaction.plan")
local reduction = require("neoagent.compaction.reduction")
local summary = require("neoagent.compaction.summary")
local tree = require("neoagent.session_tree")
local util = require("neoagent.util")

local M = {}

local instruction = [[Pause the current task and output only a context checkpoint. Do not continue the work, answer earlier questions, or call tools.

The messages above are the portion being compacted. More recent messages are omitted from this request and will remain available after the checkpoint. Include the current request and the progress needed to understand those messages. If the conversation begins with an earlier checkpoint, update it with the newer information and preserve its still-relevant requirements and decisions.

]] .. summary.checkpoint_prompt

---@param selection Neoagent.LocalCompactionSelection
---@return Neoagent.LocalCheckpointPlan
local function assemble(selection)
  return {
    known_summary = "",
    generations = 1,
    build = function(max_output_tokens)
      ---@type Neoagent.Message[]
      local messages = {}
      for _, entry in ipairs(selection.consumed) do
        vim.list_extend(messages, tree.to_llm(tree.entry_messages(entry)))
      end
      return {
        kind = "prefix",
        messages = messages,
        first_kept_entry_id = selection.first_kept_entry_id,
        tokens_before = selection.tokens_before,
        settings = selection.settings,
        max_output_tokens = max_output_tokens,
      }
    end,
  }
end

---@param opts Neoagent.CompactionRunOptions
---@return Neoagent.Run<Neoagent.CompactionResult, Neoagent.CompactionEvent>
local function run(opts)
  return async.run(function(run)
    local preparation = opts.preparation
    if preparation.kind ~= "prefix" then
      return { ok = false, error = util.error("compaction", "Prefix compaction requires prefix preparation") }
    end
    ---@cast preparation Neoagent.PrefixCompactionPreparation
    local prompt = instruction
    if opts.instructions and util.trim(opts.instructions) ~= "" then
      prompt = prompt .. "\n\nAdditional focus: " .. opts.instructions
    end
    local call = request_preparation.copy(opts.model_options or {})
    ---@cast call Neoagent.StreamOptions
    call._preparation = request_preparation.new()
    call.messages = util.copy(preparation.messages)
    call.messages[#call.messages + 1] = {
      role = "user",
      content = { { type = "text", text = prompt } },
      timestamp = util.now_ms(),
    }
    call.system_prompt = opts.system_prompt
    call.tools = util.copy(opts.tools or {})
    local planned_output =
      math.min(preparation.max_output_tokens, plan.summary_output_limit(opts.model, preparation.settings))
    call = summary.generation_options(opts.model, call, planned_output)
    if opts.model.context_window then
      local bounded, err = reduction.request(opts.model, call, opts.model.context_window - planned_output)
      if not bounded then
        return { ok = false, error = err }
      end
      call.messages = bounded
    end
    local generated, err = summary.generate(run, opts.model, call, "history")
    if not generated then
      return { ok = false, error = err }
    end
    return {
      ok = true,
      summary = generated.text,
      usage = generated.usage,
      first_kept_entry_id = preparation.first_kept_entry_id,
      tokens_before = preparation.tokens_before,
    }
  end, { on_event = opts.on_event, on_done = opts.on_done, report = opts.report, error_kind = "compaction" })
end

---@type Neoagent.CompactionComponent
M.component = {
  evaluate = plan.evaluate_budget,
  prepare = function(options)
    return plan.prepare_local(options, assemble)
  end,
  run = run,
}

return M
