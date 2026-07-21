local agent = require("neoagent.agent")
local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local active = setmetatable({}, { __mode = "k" })

local function begin(session, prompt)
  assert(type(session) == "table" and type(session.append) == "function", "session is required")
  assert(type(prompt) == "string", "prompt must be a string")
  if active[session] then
    error(util.error("session", "Session already has an active run"), 0)
  end
  local ok, err = session:append({ role = "user", content = prompt, timestamp = util.now_ms() })
  if not ok then
    error(err, 0)
  end
end

local function finish_result(result, session)
  result = util.copy(result)
  result.session = session
  return result
end

function M.send(session, prompt, opts)
  opts = opts or {}
  assert(type(opts.model) == "table", "model is required")
  begin(session, prompt)
  local run
  run = async.run(function()
    local model_opts = util.copy(opts.model_options or {})
    model_opts.messages = session:messages()
    model_opts.system_prompt = opts.system_prompt
    model_opts.on_event = function(event) run:emit(event) end
    local result = opts.model:stream(model_opts):await()
    if result.message then
      local ok, err = session:append(result.message)
      if not ok then
        active[session] = nil
        return finish_result({ ok = false, message = result.message, error = err }, session)
      end
      run:emit({ type = "message_end", message = util.copy(result.message) })
    end
    active[session] = nil
    return finish_result(result, session)
  end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "session" })
  active[session] = run
  if run:is_done() then
    active[session] = nil
  end
  return run
end

function M.run(session, prompt, opts)
  opts = opts or {}
  assert(type(opts.model) == "table", "model is required")
  begin(session, prompt)
  local run
  run = async.run(function()
    local storage_error
    local child = agent.run({
      model = opts.model,
      messages = session:messages(),
      system_prompt = opts.system_prompt,
      tools = opts.tools,
      model_options = opts.model_options,
      context = opts.context,
      execute_tool = opts.execute_tool,
      max_rounds = opts.max_rounds,
      on_event = function(event)
        if event.type == "message_end" and not storage_error then
          local ok, err = session:append(event.message)
          if not ok then
            storage_error = err
          end
        end
        if not storage_error then
          run:emit(event)
        end
      end,
    })
    local result = child:await()
    active[session] = nil
    if storage_error then
      return finish_result({
        ok = false,
        new_messages = result.new_messages or {},
        message = result.message,
        error = storage_error,
      }, session)
    end
    return finish_result(result, session)
  end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "session" })
  active[session] = run
  if run:is_done() then
    active[session] = nil
  end
  return run
end

return M
