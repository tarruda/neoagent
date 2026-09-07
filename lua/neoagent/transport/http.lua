local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local sse = require("neoagent.transport.sse")
local util = require("neoagent.util")

local M = {}
local DETAIL_LIMIT = 64 * 1024

local function decode(body)
  return pcall(vim.json.decode, body)
end

local function response_error(message, response, detail)
  local err = util.error("protocol", message, detail)
  err.response = { status = response.status, headers = response.headers or {} }
  return err
end

-- The byte backend owns I/O and recording. Consumers see HTTP metadata and
-- decoded JSON, regardless of whether the bytes came from curl or replay.
function M.new(backend)
  backend = backend or curl
  assert(type(backend) == "table" and
    (type(backend.request) == "function" or type(backend.fetch) == "function"),
    "HTTP backend requires request or fetch")
  local client = {}

  function client.with_context(context)
    return M.new(type(backend.with_context) == "function"
      and backend.with_context(context) or backend)
  end

  function client.fetch(opts)
    return async.run(function()
      local result = backend.fetch({ request = opts.request }):await()
      if not result.ok then return result end
      local body = result.body
      if type(body) ~= "string" then
        error(response_error("HTTP response body must be text", result), 0)
      end
      local maximum = opts.request.max_response_bytes
      if maximum and #body > maximum then
        error(response_error("HTTP response exceeds " .. maximum .. " bytes", result), 0)
      end
      if body == "" and (result.status == 204 or result.status == 304) then
        return { ok = true, status = result.status, headers = result.headers or {} }
      end
      local ok, value = decode(body)
      if not ok and (not result.status or result.status >= 200 and result.status < 300) then
        error(response_error("HTTP response contains invalid JSON", result,
          body:sub(1, DETAIL_LIMIT)), 0)
      end
      if not ok then value = nil end
      return {
        ok = true, status = result.status, headers = result.headers or {},
        body = value,
        detail = not ok and body:sub(1, DETAIL_LIMIT) or nil,
      }
    end, { on_done = opts.on_done, error_kind = "transport" })
  end

  function client.stream(opts)
    assert(type(opts.on_event) == "function", "HTTP stream requires on_event")
    return async.run(function(run)
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
          if not alive() then return end
          if payload == "[DONE]" then
            if opts.on_done_marker then opts.on_done_marker() end
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
        return backend.request({
          request = opts.request,
          on_chunk = function(chunk)
            if not alive() then return end
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
            if not ok then error(util.error("protocol", err), 0) end
          end,
        }):await()
      end)
      local response = completed and (result.response
        or result.error and result.error.response) or nil
      response = response or {}
      local status = response.status
      local failed_http = status and (status < 200 or status >= 300)
      local decoded, value
      if json_body then decoded, value = decode(json_body) end
      if completed and result.ok then
        local finished, failure = pcall(function()
          if mode == "json" then
            if not failed_http then
              if not decoded then
                error(response_error("HTTP response contains invalid JSON", response, tail), 0)
              end
              opts.on_event(value)
            end
          else
            local ok, err = parser:finish()
            if not ok then error(response_error(err, response), 0) end
          end
        end)
        if not finished then
          result = { ok = false, error = util.normalize_error(failure, "protocol") }
          result.error.response = { status = status, headers = response.headers or {} }
        end
      end
      active = false
      if not completed then error(result, 0) end
      if not result.ok then
        if failed_http and tail ~= "" then result.error.detail = tail end
        return result
      end
      if not decoded then value = nil end
      return {
        ok = true, status = status, headers = response.headers or {},
        body = value, detail = failed_http and tail or nil,
      }

    end, { on_done = opts.on_done, error_kind = "transport" })
  end

  return client
end

return M
