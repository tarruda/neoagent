local async = require("neoagent.async")
local decoder = require("neoagent.api.openai_responses.decoder")
local request_builder = require("neoagent.api.openai_responses.request")
local curl = require("neoagent.transport.curl")
local sse = require("neoagent.transport.sse")
local util = require("neoagent.util")

local M = {}

local function has_content(message)
  return message and #message.content > 0
end

local Model = {}
Model.__index = Model

function Model:_request(call_opts)
  return request_builder.build(self, call_opts)
end

function Model:stream(opts)
  opts = opts or {}
  assert(type(opts.messages) == "table", "messages are required")
  local transport = self._transport
  local message
  return async.run(function(run)
    local ok, outcome = pcall(function()
      local request = self:_request(opts)
      local stream = decoder.new(self, function(event) run:emit(event) end)
      message = stream.message
      local parser = sse.new({ on_event = stream.process })
      local child = transport.request({
        request = {
          url = request.url,
          headers = request.headers,
          body = vim.json.encode(request.body),
        },
        on_chunk = function(chunk)
          local parsed, err = parser:feed(chunk)
          if not parsed then error(util.error("protocol", err), 0) end
        end,
      })
      local transport_ok, transport_result = pcall(function() return child:await() end)
      if transport_ok and transport_result.ok then parser:finish() end
      if not transport_ok then error(transport_result, 0) end
      if not transport_result.ok then error(transport_result.error, 0) end
      if self._response_status then
        local status = self._response_status(transport_result.response.headers or {})
        if type(status) == "string" and status ~= "" then
          run:emit({ type = "provider_status", text = status })
        end
      end
      if not stream.is_terminal() then
        error(util.error("protocol", "Stream ended before a terminal response event"), 0)
      end
      return message
    end)

    if not ok then
      local err = util.normalize_error(outcome, "model")
      local partial = type(message) == "table" and message or nil
      if partial and has_content(partial) then
        partial.stopReason = err.kind == "cancelled" and "aborted" or "error"
        partial.errorMessage = err.message
      else
        partial = nil
      end
      return { ok = false, message = partial, error = err }
    end
    return { ok = true, message = outcome, text = util.text_content(outcome.content) }
  end, {
    on_event = opts.on_event,
    on_done = opts.on_done,
    error_kind = "model",
  })
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.provider) == "string" and opts.provider ~= "", "provider is required")
  assert(type(opts.model) == "string" and opts.model ~= "", "model is required")
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  local layers = {}
  for _, layer in ipairs(opts.request_opts_layers or {}) do layers[#layers + 1] = layer end
  if opts.request_opts ~= nil then layers[#layers + 1] = opts.request_opts end
  return setmetatable({
    api = "openai-responses",
    provider = opts.provider,
    id = opts.model,
    context_window = opts.context_window,
    _base_url = opts.base_url:gsub("/+$", ""),
    _api_key = opts.api_key,
    _max_output_tokens = opts.max_output_tokens,
    _reasoning = opts.reasoning == true,
    _reasoning_effort = opts.reasoning_effort,
    _reasoning_summary = opts.reasoning_summary,
    _reasoning_context = opts.reasoning_context,
    _profile = opts.profile,
    _responses_lite = opts.responses_lite == true,
    _text_verbosity = opts.text_verbosity,
    _response_status = opts.response_status,
    thinking = util.copy(opts.thinking),
    _request_opts = layers,
    _transport = opts.transport or curl,
  }, Model)
end

M._encode_messages = request_builder.encode_messages

return M
