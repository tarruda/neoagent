local semantic = require("neoagent.context_estimate")

local M = {}

---@param messages Neoagent.RequestMessage[]
---@return integer
function M.messages(messages)
  local tokens = 0
  for _, message in ipairs(messages) do
    tokens = tokens + semantic.estimate_tokens(message)
  end
  return tokens
end

-- Count the shaped body and any encoder-owned prompt prefix without reading
-- attachments or preparing remote files. These are character-based estimates;
-- provider tokenization and opaque context still require overflow recovery.
---@param request Neoagent.ApiRequest
---@param messages Neoagent.RequestMessage[]
---@param prefix? string|Neoagent.JsonObject[]
---@return integer
function M.shaped(request, messages, prefix)
  local characters = #vim.json.encode(request.body or {})
  if prefix then
    characters = characters + (type(prefix) == "string" and #prefix or #vim.json.encode(prefix))
  end
  return M.messages(messages) + math.ceil(characters / 4)
end

---@param system_prompt? string
---@param tools? Neoagent.ToolDefinition[]
---@return integer
function M.overhead(system_prompt, tools)
  local characters = #(system_prompt or "")
  for _, tool in ipairs(tools or {}) do
    characters = characters + #(tool.name or "") + #(tool.description or "")
    characters = characters + #vim.json.encode(tool.input_schema or {})
  end
  return math.ceil(characters / 4)
end

---@async
---@param model Neoagent.Model
---@param options Neoagent.RequestOptions
---@param operation? "compact"
---@return integer
function M.request(model, options, operation)
  if model.estimate_request then
    local tokens = model:estimate_request(options, operation)
    assert(type(tokens) == "number" and tokens >= 0 and tokens < math.huge and tokens % 1 == 0,
      "Model request estimate must be a finite non-negative integer")
    return tokens
  end
  return M.messages(options.messages) + M.overhead(options.system_prompt, options.tools)
end

return M
