local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local TURN_STATE_HEADER = "x-codex-turn-state"

---@param headers? table<string, string>
---@param name string
---@return string?
local function header(headers, name)
  for key, value in pairs(headers or {}) do
    if key:lower() == name then
      return value
    end
  end
end

---@param value unknown
---@param maximum integer
---@return TypeGuard<string>
local function valid_header(value, maximum)
  return type(value) == "string"
    and #value > 0
    and #value <= maximum
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

---@param turn Neoagent.Run<unknown, unknown>
local function require_active(turn)
  if turn:is_done() or turn:is_cancelled() then
    local err = util.error("model", "Codex request turn has finished")
    err.retryable = false
    error(err, 0)
  end
end

---@param context Neoagent.RequestOptionsInput
---@return Neoagent.RequestOverride
function M.request_opts(context)
  local session = context.request_context and rawget(context.request_context, "session_id")
  if session == nil then
    return {}
  end
  assert(valid_header(session, 512), "Codex request session_id must be a non-empty header-safe string")
  return {
    headers = { ["session-id"] = session, ["thread-id"] = session },
    body = { prompt_cache_key = #session > 64 and vim.fn.sha256(session) or session },
  }
end

---@class Neoagent.CodexAffinityState
---@field owner string
---@field token? string

-- The adapter retains opaque routing state. The borrowed Run identifies its
-- lifetime without exposing provider state to Chat, the Loop, or the Agent.
---@return fun(transport: Neoagent.HttpClient, options: Neoagent.RequestOptions): Neoagent.HttpClient
function M.new()
  ---@type table<Neoagent.Run<unknown, unknown>, table<string, Neoagent.CodexAffinityState>>
  local turns = setmetatable({}, { __mode = "k" })

  ---@param turn Neoagent.Run<unknown, unknown>
  ---@return table<string, Neoagent.CodexAffinityState>
  local function states(turn)
    local current = turns[turn]
    if current then
      return current
    end
    current = {}
    turns[turn] = current
    local remove_cancel
    local function release()
      turns[turn] = nil
      for _, state in pairs(current) do
        state.token = nil
      end
      if remove_cancel then
        remove_cancel()
        remove_cancel = nil
      end
    end
    remove_cancel = turn:on_cancel(release)
    turn:_listen(release)
    return current
  end

  ---@param transport Neoagent.HttpClient
  ---@param options Neoagent.RequestOptions
  ---@return Neoagent.HttpClient
  local function bind(transport, options)
    local turn = assert(options._turn, "Codex request turn is required")
    require_active(turn)
    local current = states(turn)
    return {
      fetch = transport.fetch,
      with_context = function(context)
        return bind(transport.with_context(context), options)
      end,
      stream = function(call)
        require_active(turn)
        local request = util.copy(call.request)
        local session = header(request.headers, "session-id") or ""
        local account = header(request.headers, "chatgpt-account-id")
        local owner = request.url
          .. "\0"
          .. (account and account ~= "" and account or header(request.headers, "authorization") or "")
        local state = current[session]
        if not state or state.owner ~= owner then
          if state then
            state.token = nil
          end
          state = { owner = owner }
          current[session] = state
        end
        request.headers = request.headers or {}
        for name in pairs(request.headers) do
          if name:lower() == TURN_STATE_HEADER then
            request.headers[name] = nil
          end
        end
        request.headers[TURN_STATE_HEADER] = state.token
        return async.run(function(run)
          local result = transport
            .stream({
              request = request,
              response_type = call.response_type,
              on_event = call.on_event,
              on_done_marker = call.on_done_marker,
              max_buffer = call.max_buffer,
              max_event_bytes = call.max_event_bytes,
            })
            :await()
          ---@type Neoagent.HttpError?
          local failure = not result.ok and result.error or nil
          local response = result.ok and result or failure and failure.response
          local token = response and header(response.headers, TURN_STATE_HEADER)
          if
            not run:is_cancelled()
            and not turn:is_done()
            and not turn:is_cancelled()
            and turns[turn] == current
            and current[session] == state
            and not state.token
            and valid_header(token, 8192)
          then
            state.token = token
          end
          return result
        end, { on_done = call.on_done, error_kind = "model" })
      end,
    }
  end
  return bind
end

return M
