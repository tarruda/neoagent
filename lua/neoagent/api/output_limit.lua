local util = require("neoagent.util")

local M = {}

-- A per-call output limit is a hard constraint, independent of the caller's
-- purpose. Model defaults and wire overrides remain ordinary request layers.
---@param request Neoagent.ApiRequest
---@param context Neoagent.RequestOptionsInput
---@param limit? integer
---@param thinking_limit? integer Caps explicit protocol thinking budgets, independent of effort selection.
---@return Neoagent.ApiRequest
function M.apply(request, context, limit, thinking_limit)
  if limit ~= nil and (type(limit) ~= "number" or limit % 1 ~= 0 or limit < 1 or limit == math.huge) then
    error(util.error("model", "Output limit must be a positive integer"), 0)
  end
  if
    thinking_limit ~= nil
    and (
      type(thinking_limit) ~= "number"
      or thinking_limit % 1 ~= 0
      or thinking_limit < 1
      or thinking_limit == math.huge
    )
  then
    error(util.error("model", "Thinking token limit must be a positive integer"), 0)
  end
  local model = context.model
  local body = assert(request.body)
  if model.api == "anthropic-messages" then
    body.max_tokens = limit or body.max_tokens
    local manual = body.thinking
    if type(manual) == "table" and manual.type == "enabled" and type(manual.budget_tokens) == "number" then
      local ceiling =
        math.min(thinking_limit or math.huge, type(body.max_tokens) == "number" and body.max_tokens - 1 or math.huge)
      if ceiling < 1024 then
        body.thinking = { type = "disabled" }
      else
        manual.budget_tokens = math.min(manual.budget_tokens, ceiling)
      end
    end
  elseif model.api == "openai-completions" then
    body.max_completion_tokens = limit or body.max_completion_tokens
  elseif limit then
    if limit < 16 then
      error(util.error("model", "Responses requests require at least 16 output tokens"), 0)
    end
    body.max_output_tokens = limit
  end
  return request
end

return M
