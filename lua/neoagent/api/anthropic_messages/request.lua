local messages = require("neoagent.api.messages")
local request_context = require("neoagent.api.request_context")
local request_opts = require("neoagent.api.request_opts")
local tool_schema = require("neoagent.api.tool_schema")
local util = require("neoagent.util")

local M = {}

---@param id? string
---@return string
local function normalize_tool_id(id)
  return tostring(id or ""):gsub("[^%w_-]", "_"):sub(1, 64)
end

---@param value? Neoagent.JsonObject
---@return Neoagent.JsonObject
local function object(value)
  value = value or {}
  if type(value) ~= "table" or (next(value) ~= nil and util.is_list(value)) then
    error(util.error("model", "Tool arguments must be an object"), 0)
  end
  local result = util.copy(value)
  if next(result) == nil then return vim.empty_dict() end
  return result
end

---@param content? string|(Neoagent.TextBlock|Neoagent.ImageBlock)[]
---@param empty_text? string
---@return string|Neoagent.JsonObject[]
local function content_blocks(content, empty_text)
  if type(content) == "string" then return content end
  ---@type Neoagent.JsonObject[]
  local result = {}
  local has_text = false
  ---@type string[]
  local text = {}
  local has_image = false
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      has_text = true
      local value = block.text or ""
      text[#text + 1] = value
      result[#result + 1] = { type = "text", text = value }
    elseif block.type == "image" then
      has_image = true
      result[#result + 1] = {
        type = "image",
        source = {
          type = "base64",
          media_type = block.mimeType,
          data = block.data,
        },
      }
    end
  end
  if has_image and not has_text then
    table.insert(result, 1, { type = "text", text = "(see attached image)" })
  end
  if #result == 0 then return empty_text or "" end
  if not has_image then return table.concat(text, "\n") end
  return result
end

---@param message Neoagent.AssistantMessage
---@return Neoagent.JsonObject[]
local function assistant_blocks(message)
  ---@type Neoagent.JsonObject[]
  local result = {}
  for _, block in ipairs(message.content or {}) do
    if block.type == "text" and type(block.text) == "string" and block.text ~= "" then
      result[#result + 1] = { type = "text", text = block.text }
    elseif block.type == "thinking" then
      local thinking = type(block.thinking) == "string" and block.thinking or ""
      local signature = type(block.thinkingSignature) == "string" and block.thinkingSignature or ""
      if block.redacted and signature ~= "" then
        result[#result + 1] = { type = "redacted_thinking", data = signature }
      elseif signature ~= "" then
        result[#result + 1] = { type = "thinking", thinking = thinking, signature = signature }
      elseif thinking ~= "" then
        result[#result + 1] = { type = "text", text = thinking }
      end
    elseif block.type == "toolCall" then
      result[#result + 1] = {
        type = "tool_use",
        id = normalize_tool_id(block.id),
        name = block.name,
        input = object(block.arguments),
      }
    end
  end
  return result
end

---@param block Neoagent.ToolResultMessage
---@return Neoagent.JsonObject
local function tool_result(block)
  local result = {
    type = "tool_result",
    tool_use_id = normalize_tool_id(block.toolCallId),
    content = content_blocks(block.content, "(no tool output)"),
  }
  if block.isError == true then result.is_error = true end
  return result
end

---@param messages Neoagent.Message[]
---@return Neoagent.JsonObject[]
local function encode_messages(messages)
  ---@type Neoagent.JsonObject[]
  local result = {}
  ---@type Neoagent.JsonObject[]?
  local tool_results
  for _, message in ipairs(messages) do
    if message.role == "toolResult" then
      if not tool_results then
        tool_results = {}
        result[#result + 1] = { role = "user", content = tool_results }
      end
      tool_results[#tool_results + 1] = tool_result(message)
    else
      tool_results = nil
      if message.role == "user" then
        result[#result + 1] = {
          role = "user", content = content_blocks(message.content),
        }
      elseif message.role == "assistant" then
        local blocks = assistant_blocks(message)
        if #blocks > 0 then
          result[#result + 1] = { role = "assistant", content = blocks }
        end
      else
        error(util.error("model", "Unsupported message role: " .. tostring(message.role)), 0)
      end
    end
  end
  return result
end

---@param tools? Neoagent.ToolDefinition[]
---@return Neoagent.JsonObject[]
local function encode_tools(tools)
  ---@type Neoagent.JsonObject[]
  local result = {}
  for _, tool in ipairs(tools or {}) do
    result[#result + 1] = {
      name = tool.name,
      description = tool.description,
      input_schema = tool_schema.normalize(tool.input_schema),
    }
  end
  return result
end

---@param model Neoagent.AnthropicModel
---@param call_opts Neoagent.StreamOptions
---@return Neoagent.ApiRequest, Neoagent.RequestIdentity?
function M.build(model, call_opts)
  local headers = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = model._anthropic_version,
  }
  local api_key = model._api_key
  if type(api_key) == "function" then api_key = api_key() end
  if api_key ~= nil and api_key ~= "" then
    headers["x-api-key"] = api_key
  end

  ---@type Neoagent.JsonObject
  local body = {
    model = model.id,
    messages = encode_messages(messages.for_model(call_opts.messages, model)),
    max_tokens = model._max_output_tokens,
    stream = true,
  }
  if call_opts.system_prompt and call_opts.system_prompt ~= "" then
    body.system = call_opts.system_prompt
  end
  local tools = encode_tools(call_opts.tools)
  if #tools > 0 then body.tools = tools end

  ---@type Neoagent.ApiRequest
  local request = {
    url = model._base_url .. "/messages",
    headers = headers,
    body = body,
  }
  ---@type Neoagent.RequestOptionsInput
  local context = {
    model = model,
    messages = util.copy(call_opts.messages),
    system_prompt = call_opts.system_prompt,
    tools = util.copy(call_opts.tools or {}),
    request_context = request_context.resolve(
      model._request_context, call_opts.request_context),
  }
  for _, layer in ipairs(model._request_opts) do
    request = request_opts.apply(request, layer, context)
  end
  request = request_opts.apply(request, call_opts.request_opts, context)
  return request, context.request_context
end

M.encode_messages = encode_messages
M.normalize_tool_id = normalize_tool_id

return M
