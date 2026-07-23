local request_opts = require("neoagent.api.request_opts")
local tool_schema = require("neoagent.api.tool_schema")
local util = require("neoagent.util")

local M = {}

local function input_content(content)
  local result = util.list()
  if type(content) == "string" then
    result[1] = { type = "input_text", text = content }
    return result
  end
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      result[#result + 1] = { type = "input_text", text = block.text or "" }
    elseif block.type == "image" then
      result[#result + 1] = {
        type = "input_image",
        detail = "auto",
        image_url = "data:" .. block.mimeType .. ";base64," .. block.data,
      }
    end
  end
  return result
end

local function signature_id(signature, fallback)
  if type(signature) ~= "string" or signature == "" then return fallback end
  if signature:sub(1, 1) ~= "{" then return signature end
  local ok, value = pcall(vim.json.decode, signature)
  return ok and type(value) == "table" and type(value.id) == "string" and value.id or fallback
end

local function split_call_id(value)
  local call_id, item_id = tostring(value or ""):match("^([^|]+)|(.+)$")
  return call_id or tostring(value or ""), item_id
end

local function encode_messages(messages, system_prompt, include_system)
  local result = util.list()
  if include_system ~= false and system_prompt and system_prompt ~= "" then
    result[#result + 1] = { role = "system", content = system_prompt }
  end
  for message_index, message in ipairs(messages) do
    if message.role == "user" then
      local content = input_content(message.content)
      if #content > 0 then result[#result + 1] = { role = "user", content = content } end
    elseif message.role == "assistant" then
      local text_index = 0
      for _, block in ipairs(message.content or {}) do
        if block.type == "thinking" and type(block.thinkingSignature) == "string" then
          local ok, item = pcall(vim.json.decode, block.thinkingSignature)
          if not ok or type(item) ~= "table" or item.type ~= "reasoning" then
            error(util.error("model", "Invalid reasoning signature"), 0)
          end
          result[#result + 1] = item
        elseif block.type == "text" then
          text_index = text_index + 1
          local item = {
            type = "message",
            role = "assistant",
            status = "completed",
            id = signature_id(block.textSignature,
              string.format("msg_neoagent_%d_%d", message_index, text_index)),
            content = { {
              type = "output_text",
              text = block.text or "",
              annotations = util.list(),
            } },
          }
          if type(block.phase) == "string" and block.phase ~= "" then item.phase = block.phase end
          result[#result + 1] = item
        elseif block.type == "toolCall" then
          local call_id, item_id = split_call_id(block.id)
          local item = {
            type = "function_call",
            call_id = call_id,
            name = block.name,
            arguments = util.json_encode(block.arguments or vim.empty_dict()),
          }
          if item_id then item.id = item_id end
          result[#result + 1] = item
        end
      end
    elseif message.role == "toolResult" then
      local call_id = split_call_id(message.toolCallId)
      local text = {}
      local output = util.list()
      for _, block in ipairs(message.content or {}) do
        if block.type == "text" then
          text[#text + 1] = block.text or ""
        elseif block.type == "image" then
          output[#output + 1] = {
            type = "input_image",
            detail = "auto",
            image_url = "data:" .. block.mimeType .. ";base64," .. block.data,
          }
        end
      end
      local joined = table.concat(text, "\n")
      if #output > 0 then
        if joined ~= "" then table.insert(output, 1, { type = "input_text", text = joined }) end
      else
        output = joined ~= "" and joined or "(no tool output)"
      end
      result[#result + 1] = { type = "function_call_output", call_id = call_id, output = output }
    else
      error(util.error("model", "Unsupported message role: " .. tostring(message.role)), 0)
    end
  end
  return result
end

local function encode_tools(tools, strict)
  local result = util.list()
  if strict == nil then strict = false end
  for _, tool in ipairs(tools or {}) do
    result[#result + 1] = {
      type = "function",
      name = tool.name,
      description = tool.description,
      parameters = tool_schema.normalize(tool.input_schema),
      strict = strict,
    }
  end
  return result
end

local function developer_message(text)
  return {
    type = "message",
    role = "developer",
    content = { { type = "input_text", text = text } },
  }
end

local function prepend_input(prefix, input)
  local result = util.list()
  vim.list_extend(result, prefix or {})
  vim.list_extend(result, input or {})
  return result
end

function M.build(self, call_opts)
  local headers = {
    ["Accept"] = "text/event-stream",
    ["Content-Type"] = "application/json",
  }
  local api_key = self._api_key
  if type(api_key) == "function" then api_key = api_key() end
  if api_key ~= nil and api_key ~= "" then headers.Authorization = "Bearer " .. api_key end

  local codex = self._profile == "codex"
  local responses_lite = codex and self._responses_lite == true
  local body = {
    model = self.id,
    input = encode_messages(call_opts.messages, call_opts.system_prompt, not codex),
    stream = true,
    store = false,
  }
  local tools = encode_tools(call_opts.tools, codex and vim.NIL or false)
  if codex then
    body.text = { verbosity = self._text_verbosity or "low" }
    body.include = { "reasoning.encrypted_content" }
    body.tool_choice = "auto"
    if responses_lite then
      headers["x-openai-internal-codex-responses-lite"] = "true"
      local prefix = util.list({ { type = "additional_tools", role = "developer", tools = tools } })
      if call_opts.system_prompt and call_opts.system_prompt ~= "" then
        prefix[#prefix + 1] = developer_message(call_opts.system_prompt)
      end
      body.input = prepend_input(prefix, body.input)
      body.parallel_tool_calls = false
    else
      body.instructions = call_opts.system_prompt or "You are a helpful assistant."
      body.parallel_tool_calls = true
      if #tools > 0 then body.tools = tools end
    end
  elseif #tools > 0 then
    body.tools = tools
  end
  if self._max_output_tokens then body.max_output_tokens = math.max(16, self._max_output_tokens) end
  if self._reasoning then
    local reasoning = { effort = self._reasoning_effort or "medium" }
    if self._reasoning_summary ~= "none" then reasoning.summary = self._reasoning_summary or "auto" end
    if self._reasoning_context or responses_lite then
      reasoning.context = self._reasoning_context or "all_turns"
    end
    body.reasoning = reasoning
    body.include = { "reasoning.encrypted_content" }
  end

  local request = {
    url = self._base_url .. "/responses",
    headers = headers,
    body = body,
  }
  local context = {
    model = self,
    messages = util.copy(call_opts.messages),
    system_prompt = call_opts.system_prompt,
    tools = util.copy(call_opts.tools or {}),
  }
  for _, layer in ipairs(self._request_opts) do
    request = request_opts.apply(request, layer, context)
  end
  request = request_opts.apply(request, call_opts.request_opts, context)
  local reasoning_context = self._reasoning_context or (responses_lite and "all_turns" or nil)
  if reasoning_context and type(request.body) == "table" and type(request.body.reasoning) == "table"
      and request.body.reasoning.context == nil then
    request.body.reasoning.context = reasoning_context
  end
  return request
end

M.encode_messages = encode_messages

return M
