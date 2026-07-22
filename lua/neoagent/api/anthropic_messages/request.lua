local request_opts = require("neoagent.api.request_opts")
local tool_schema = require("neoagent.api.tool_schema")
local util = require("neoagent.util")

local M = {}

local function normalize_tool_id(id)
  return tostring(id or ""):gsub("[^%w_-]", "_"):sub(1, 64)
end

local function object(value)
  value = value or {}
  if type(value) ~= "table" or (next(value) ~= nil and util.is_list(value)) then
    error(util.error("model", "Tool arguments must be an object"), 0)
  end
  local result = util.copy(value)
  if next(result) == nil then return vim.empty_dict() end
  return result
end

local function content_blocks(content, empty_text)
  if type(content) == "string" then return content end
  local result = {}
  local has_text = false
  local has_image = false
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      has_text = true
      result[#result + 1] = { type = "text", text = block.text or "" }
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
  if not has_image then
    local text = {}
    for _, block in ipairs(result) do text[#text + 1] = block.text end
    return table.concat(text, "\n")
  end
  return result
end

local function assistant_blocks(message)
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

local function tool_result(block)
  local result = {
    type = "tool_result",
    tool_use_id = normalize_tool_id(block.toolCallId),
    content = content_blocks(block.content, "(no tool output)"),
  }
  if block.isError == true then result.is_error = true end
  return result
end

local function encode_messages(messages)
  local result = {}
  local index = 1
  while index <= #messages do
    local message = messages[index]
    if message.role == "user" then
      result[#result + 1] = {
        role = "user",
        content = content_blocks(message.content),
      }
    elseif message.role == "assistant" then
      local blocks = assistant_blocks(message)
      if #blocks > 0 then result[#result + 1] = { role = "assistant", content = blocks } end
    elseif message.role == "toolResult" then
      local blocks = {}
      while index <= #messages and messages[index].role == "toolResult" do
        blocks[#blocks + 1] = tool_result(messages[index])
        index = index + 1
      end
      result[#result + 1] = { role = "user", content = blocks }
      index = index - 1
    else
      error(util.error("model", "Unsupported message role: " .. tostring(message.role)), 0)
    end
    index = index + 1
  end
  return result
end

local function encode_tools(tools)
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

function M.build(model, call_opts)
  local headers = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = model._anthropic_version,
  }
  local api_key = model._api_key
  if type(api_key) == "function" then api_key = api_key() end
  if api_key ~= nil and api_key ~= "" then headers["x-api-key"] = api_key end

  local body = {
    model = model.id,
    messages = encode_messages(call_opts.messages),
    max_tokens = model._max_output_tokens,
    stream = true,
  }
  if call_opts.system_prompt and call_opts.system_prompt ~= "" then
    body.system = call_opts.system_prompt
  end
  local tools = encode_tools(call_opts.tools)
  if #tools > 0 then body.tools = tools end

  local request = {
    url = model._base_url .. "/messages",
    headers = headers,
    body = body,
  }
  local context = {
    model = model,
    messages = util.copy(call_opts.messages),
    system_prompt = call_opts.system_prompt,
    tools = util.copy(call_opts.tools or {}),
  }
  for _, layer in ipairs(model._request_opts) do
    request = request_opts.apply(request, layer, context)
  end
  return request_opts.apply(request, call_opts.request_opts, context)
end

M.encode_messages = encode_messages
M.normalize_tool_id = normalize_tool_id

return M
