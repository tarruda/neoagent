local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local sse = require("neoagent.transport.sse")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.HttpSuccess: Neoagent.HttpMetadata
---@field ok true
---@field body? Neoagent.JsonValue
---@field detail? string

---@alias Neoagent.HttpResult Neoagent.HttpSuccess|Neoagent.AsyncFailure

---@class Neoagent.HttpFetchOptions
---@field request Neoagent.HttpRequest
---@field response_type? "json"|"text" Defaults to JSON; text preserves storage response bytes.
---@field on_done? fun(result: Neoagent.HttpResult)

---@class Neoagent.HttpStreamOptions: Neoagent.HttpFetchOptions
---@field on_event fun(value: Neoagent.JsonValue)
---@field on_done_marker? fun()
---@field max_buffer? integer
---@field max_event_bytes? integer

---@class Neoagent.HttpClient
---@field with_context fun(context?: Neoagent.RequestIdentity): Neoagent.HttpClient
---@field fetch fun(opts: Neoagent.HttpFetchOptions): Neoagent.Run<Neoagent.HttpResult, nil>
---@field stream fun(opts: Neoagent.HttpStreamOptions): Neoagent.Run<Neoagent.HttpResult, nil>

local DETAIL_LIMIT = 64 * 1024

---@param body string
---@return boolean ok
---@return Neoagent.JsonValue value_or_error
local function decode(body)
  local ok, value = pcall(vim.json.decode, body)
  return ok, value
end

---@param message string
---@param response Neoagent.HttpMetadata
---@param detail? unknown
---@return Neoagent.HttpError
local function response_error(message, response, detail)
  ---@type Neoagent.HttpError
  local err = util.error("protocol", message, detail)
  err.response = { status = response.status, headers = response.headers or {} }
  return err
end

-- The byte backend owns I/O and recording. Consumers see HTTP metadata and
-- decoded JSON or explicitly requested bytes, from either curl or replay.
---@param backend? Neoagent.ByteBackend
---@return Neoagent.HttpClient
function M.new(backend)
  backend = backend or curl
  assert(
    type(backend) == "table" and (type(backend.request) == "function" or type(backend.fetch) == "function"),
    "HTTP backend requires request or fetch"
  )
  local client = {}

  ---@param context? Neoagent.RequestIdentity
  ---@return Neoagent.HttpClient
  function client.with_context(context)
    return M.new(type(backend.with_context) == "function" and backend.with_context(context) or backend)
  end

  ---@param opts Neoagent.HttpFetchOptions
  ---@return Neoagent.Run<Neoagent.HttpResult, nil>
  function client.fetch(opts)
    return async.run(
      ---@return Neoagent.HttpResult
      function()
        assert(
          opts.response_type == nil or opts.response_type == "json" or opts.response_type == "text",
          "HTTP response_type must be json or text"
        )
        local fetch = assert(backend.fetch, "HTTP backend does not support fetch")
        local result = fetch({ request = opts.request }):await()
        if not result.ok then
          return result
        end
        local body = result.body
        if type(body) ~= "string" then
          error(response_error("HTTP response body must be text", result), 0)
        end
        local maximum = opts.request.max_response_bytes
        if maximum and #body > maximum then
          error(response_error("HTTP response exceeds " .. maximum .. " bytes", result), 0)
        end
        if opts.response_type == "text" then
          return { ok = true, status = result.status, headers = result.headers or {}, body = body }
        end
        if body == "" and (result.status == 204 or result.status == 304) then
          return { ok = true, status = result.status, headers = result.headers or {} }
        end
        local ok, decoded = decode(body)
        if not ok and (not result.status or result.status >= 200 and result.status < 300) then
          error(response_error("HTTP response contains invalid JSON", result, body:sub(1, DETAIL_LIMIT)), 0)
        end
        local value
        if ok then
          value = decoded
        end
        return {
          ok = true,
          status = result.status,
          headers = result.headers or {},
          body = value,
          detail = not ok and body:sub(1, DETAIL_LIMIT) or nil,
        }
      end,
      { on_done = opts.on_done, error_kind = "transport" }
    )
  end

  ---@param opts Neoagent.HttpStreamOptions
  ---@return Neoagent.Run<Neoagent.HttpResult, nil>
  function client.stream(opts)
    assert(type(opts.on_event) == "function", "HTTP stream requires on_event")
    return async.run(
      ---@param run Neoagent.Run<Neoagent.HttpResult, nil>
      ---@return Neoagent.HttpResult
      function(run)
        local request = assert(backend.request, "HTTP backend does not support streaming")
        local active = true
        local tail, prefix = "", ""
        local json_body
        local mode
        local function alive()
          return active and not run:is_cancelled() and not run:is_done()
        end
        local parser = sse.new({
          max_buffer = opts.max_buffer,
          max_event_bytes = opts.max_event_bytes,
          on_event = function(payload)
            if not alive() then
              return
            end
            if payload == "[DONE]" then
              if opts.on_done_marker then
                opts.on_done_marker()
              end
              return
            end
            local ok, value = decode(payload)
            if not ok then
              error(util.error("protocol", "Invalid JSON in SSE response", payload), 0)
            end
            opts.on_event(value)
          end,
        })
        local completed, result = pcall(function()
          return request({
            request = opts.request,
            on_chunk = function(chunk)
              if not alive() then
                return
              end
              tail = (tail .. chunk):sub(-DETAIL_LIMIT)
              if not mode then
                prefix = prefix .. chunk
                local first = prefix:match("%S")
                if not first then
                  if #prefix > DETAIL_LIMIT then
                    error(util.error("protocol", "HTTP stream prefix exceeds limit"), 0)
                  end
                  return
                end
                mode = (first == "{" or first == "[") and "json" or "sse"
                chunk, prefix = prefix, ""
              end
              if mode == "json" then
                json_body = (json_body or "") .. chunk
                if #json_body > (opts.request.max_response_bytes or 1024 * 1024) then
                  error(util.error("protocol", "HTTP JSON response exceeds limit"), 0)
                end
                return
              end
              local ok, err = parser:feed(chunk)
              if not ok then
                error(util.error("protocol", err), 0)
              end
            end,
          }):await()
        end)
        if not completed then
          active = false
          error(result, 0)
        end
        local response
        ---@type Neoagent.HttpError?
        local failure = not result.ok and result.error or nil
        if result.ok then
          response = result.response
        elseif failure then
          response = failure.response
        end
        response = response or { headers = {} }
        local status = response.status
        local failed_http = status and (status < 200 or status >= 300)
        local decoded, value
        if json_body then
          decoded, value = decode(json_body)
        end
        if result.ok then
          local finished, finish_error = pcall(function()
            if mode == "json" then
              if not failed_http then
                if not decoded then
                  error(response_error("HTTP response contains invalid JSON", response, tail), 0)
                end
                -- A successfully decoded JSON value cannot be nil.
                ---@cast value Neoagent.JsonValue
                opts.on_event(value)
              end
            else
              local ok, err = parser:finish()
              if not ok then
                error(response_error(err, response), 0)
              end
            end
          end)
          if not finished then
            ---@type Neoagent.HttpError
            local err = util.normalize_error(finish_error, "protocol")
            err.response = { status = status, headers = response.headers or {} }
            failure = err
          end
        end
        active = false
        if failure then
          if failed_http and tail ~= "" then
            failure.detail = tail
          end
          return { ok = false, error = failure }
        end
        if not decoded then
          value = nil
        end
        return {
          ok = true,
          status = status,
          headers = response.headers or {},
          body = value,
          detail = failed_http and tail or nil,
        }
      end,
      { on_done = opts.on_done, error_kind = "transport" }
    )
  end

  return client
end

return M
