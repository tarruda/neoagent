local async = require("neoagent.async")
local decoder = require("neoagent.api.openai_responses.decoder")
local model_contract = require("neoagent.model")
local request_builder = require("neoagent.api.openai_responses.request")
local request_context = require("neoagent.api.request_context")
local semantic_message = require("neoagent.semantic_message")
local http = require("neoagent.transport.http")
local http_response = require("neoagent.api.http_response")
local util = require("neoagent.util")

local M = {}

---@alias Neoagent.ResponseStatus fun(headers: table<string, string>): string?, Neoagent.JsonObject?

---@class Neoagent.ResponsesOptions: Neoagent.ApiModelOptions
---@field reasoning? boolean
---@field reasoning_effort? string
---@field reasoning_summary? string
---@field reasoning_context? string
---@field profile? "codex"
---@field responses_lite? boolean
---@field text_verbosity? string
---@field response_status? Neoagent.ResponseStatus

---@class Neoagent.ResponsesModel: Neoagent.Model
---@field _base_url string
---@field _api_key? string|fun(): string?
---@field _max_output_tokens? number
---@field _reasoning boolean
---@field _reasoning_effort? string
---@field _reasoning_summary? string
---@field _reasoning_context? string
---@field _profile? "codex"
---@field _responses_lite boolean
---@field _text_verbosity? string
---@field _response_status? Neoagent.ResponseStatus
---@field _request_opts Neoagent.RequestLayer[]
---@field _request_context? Neoagent.RequestIdentity
---@field _transport Neoagent.HttpClient
local Model = {}
Model.__index = Model

---@param call_opts Neoagent.StreamOptions
---@return Neoagent.ApiRequest, Neoagent.RequestIdentity?
function Model:_request(call_opts)
  return request_builder.build(self, call_opts)
end

---@param opts Neoagent.StreamOptions
---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
function Model:stream(opts)
  opts = opts or {}
  assert(type(opts.messages) == "table", "messages are required")
  ---@type Neoagent.ResponsesDecoder?
  local stream
  return async.run(
  ---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
  ---@return Neoagent.ModelResult
  function(run)
    local ok, outcome = pcall(function()
      local request, identity = self:_request(opts)
      local transport = request_context.bind_transport(self._transport, identity)
      stream = decoder.new(self, function(event) run:emit(event) end)
      local child = transport.stream({
        request = {
          url = request.url,
          headers = request.headers,
          body = util.json_encode(request.body),
        },
        on_event = stream.process,
      })
      local transport_ok, transport_result = pcall(function() return child:await() end)
      if not transport_ok then error(transport_result, 0) end
      local response = http_response.check(transport_result)
      if self._response_status then
        local status, details = self._response_status(
          response.headers)
        if type(status) == "string" and status ~= ""
            or type(details) == "table" then
          run:emit({
            type = "provider_status",
            text = type(status) == "string" and status or nil,
            details = type(details) == "table" and details or nil,
          })
        end
      end
      if not stream.is_terminal() then
        error(util.error("protocol", "Stream ended before a terminal response event"), 0)
      end
      return stream.message
    end)

    if not ok then
      local err = util.normalize_error(outcome, "model")
      local partial = stream and stream.partial() or nil
      if partial then
        partial.stopReason = err.kind == "cancelled" and "aborted" or "error"
        partial.errorMessage = err.message
        partial = semantic_message.normalize_partial_assistant(partial)
      end
      return { ok = false, message = partial, error = err }
    end
    local normalized, message_err =
      semantic_message.normalize_model_response(outcome)
    if not normalized then
      return {
        ok = false,
        error = message_err,
      }
    end
    return { ok = true, message = normalized,
      text = util.text_content(normalized.content) }
  end, {
    on_event = opts.on_event,
    on_done = opts.on_done,
    error_kind = "model",
  })
end

---@param opts Neoagent.ResponsesOptions
---@return Neoagent.ResponsesModel
function M.new(opts)
  opts = opts or {}
  assert(type(opts.provider) == "string" and opts.provider ~= "", "provider is required")
  assert(type(opts.model) == "string" and opts.model ~= "", "model is required")
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  local layers = {}
  for _, layer in ipairs(opts.request_opts_layers or {}) do layers[#layers + 1] = layer end
  if opts.request_opts ~= nil then layers[#layers + 1] = opts.request_opts end
  local result = model_contract.assert(setmetatable({
    api = "openai-responses",
    provider = opts.provider,
    id = opts.model,
    input = util.copy(opts.input or { "text", "image" }),
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
    _request_context = request_context.copy(opts.request_context),
    _transport = http.new(opts.transport),
  }, Model), "OpenAI Responses constructor")
  ---@cast result Neoagent.ResponsesModel
  return result
end

M._encode_messages = request_builder.encode_messages

return M
