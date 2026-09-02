local agent_loop = require("neoagent.agent_loop")
local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local active = setmetatable({}, { __mode = "k" })

local function persisted_message(message, entry)
  if not entry or type(entry.id) ~= "string" or entry.id == "" then
    return message
  end
  local copied = util.copy(message)
  copied._neoagent_entry_id = entry.id
  return copied
end

local function session_commit(session)
  return function(message)
    local ok, err, entry = session:append(message)
    if not ok then return nil, err end
    return true, nil, persisted_message(message, entry)
  end
end

local function diagnostic_report(report)
  if not report then return nil end
  return function(diagnostic)
    report("callback failed during " .. diagnostic.phase .. ": "
      .. diagnostic.message, vim.log.levels.ERROR)
  end
end

local function preflight(opts, tools, commit_message)
  assert(opts.report == nil or type(opts.report) == "function",
    "report must be a function")
  assert(opts.on_accept == nil or type(opts.on_accept) == "function",
    "on_accept must be a function")
  assert(opts.context_messages == nil
      or type(opts.context_messages) == "function"
      or type(opts.context_messages) == "table"
        and util.is_list(opts.context_messages),
    "context_messages must be a list or function")
  local prepared = agent_loop.prepare({
    model = opts.model,
    messages = {},
    system_prompt = opts.system_prompt,
    tools = tools,
    model_options = opts.model_options,
    context = opts.context,
    execute_tool = opts.execute_tool,
    get_steering_messages = opts.get_steering_messages,
    commit_message = commit_message,
    on_event = opts.on_event,
    on_done = opts.on_done,
    report = diagnostic_report(opts.report),
  })
  return {
    model = prepared.model,
    system_prompt = prepared.system_prompt,
    tools = prepared.tools,
    model_options = prepared.model_options,
    context = prepared.context,
    execute_tool = prepared.execute_tool,
    get_steering_messages = prepared.get_steering_messages,
    commit_message = prepared.commit_message,
    on_event = prepared.on_event,
    on_done = prepared.on_done,
    report = opts.report,
    diagnostic_report = prepared.report,
    on_accept = opts.on_accept,
    context_messages = type(opts.context_messages) == "table"
        and util.copy(opts.context_messages) or opts.context_messages,
    session_state = opts.session_state and util.copy(opts.session_state) or nil,
  }
end

local function release(session, owner)
  if active[session] == owner then active[session] = nil end
end

local function reserve(session)
  assert(type(session) == "table" and type(session.append) == "function", "session is required")
  if active[session] then
    error(util.error("session", "Session already has an active run"), 0)
  end
  local reservation = {}
  active[session] = reservation
  return reservation
end

local function context_messages(session, opts)
  local source = opts.context_messages
  local messages
  local err
  if type(source) == "function" then
    messages, err = source(session)
  elseif type(source) == "table" then
    messages = util.copy(source)
  elseif type(session.context_messages) == "function" then
    messages, err = session:context_messages()
  else
    messages = session:messages()
  end
  if not messages then error(util.normalize_error(err, "session"), 0) end
  return messages
end

local function begin(session, prompt, state)
  assert(type(prompt) == "string", "prompt must be a string")
  local reservation = reserve(session)
  local called, ok, err, entry = pcall(session.append, session, {
    role = "user",
    content = prompt,
    timestamp = util.now_ms(),
  }, state)
  if not called then
    release(session, reservation)
    error(ok, 0)
  end
  if not ok then
    release(session, reservation)
    error(err, 0)
  end
  return reservation, entry
end

local function accepted(opts, entry)
  if type(opts.on_accept) ~= "function" then return end
  local ok, err = pcall(opts.on_accept, entry)
  if not ok and type(opts.report) == "function" then
    pcall(opts.report,
      "accepted message callback failed: " .. tostring(err),
      vim.log.levels.ERROR)
  end
end

local function install(session, reservation, run)
  assert(active[session] == reservation, "Session reservation was lost")
  active[session] = run
  if run:is_done() then release(session, run) end
  return run
end

local function start_reserved(session, reservation, fn)
  local ok, result = pcall(fn)
  if not ok then
    release(session, reservation)
    error(result, 0)
  end
  return install(session, reservation, result)
end

local function finish_result(result, session)
  result = util.copy(result)
  result.session = session
  return result
end

local function persisted_event(event, entry)
  if not entry or type(entry.id) ~= "string" or entry.id == "" then
    return event
  end
  local copied = util.copy(event)
  copied.message = persisted_message(copied.message, entry)
  return copied
end

function M.send(session, prompt, opts)
  opts = opts or {}
  opts = preflight(opts, {}, session_commit(session))
  local reservation, entry = begin(session, prompt, opts.session_state)
  accepted(opts, entry)
  return start_reserved(session, reservation, function()
    local run
    run = async.run(function()
      local model_opts = util.copy(opts.model_options or {})
      model_opts.messages = context_messages(session, opts)
      model_opts.system_prompt = opts.system_prompt
      model_opts.on_event = function(event) run:emit(event) end
      local result = opts.model:stream(model_opts):await()
      if result.message then
        local ok, err, appended = session:append(result.message)
        if not ok then
          return finish_result({
            ok = false,
            message = result.message,
            error = err,
          }, session)
        end
        run:emit(persisted_event({
          type = "message_end",
          message = util.copy(result.message),
        }, appended))
      end
      return finish_result(result, session)
    end, {
      on_event = opts.on_event,
      on_done = function(result)
        release(session, run)
        if opts.on_done then opts.on_done(result) end
      end,
      report = opts.diagnostic_report,
      error_kind = "session",
    })
    return run
  end)
end

local function run_agent(session, opts)
  opts = opts or {}
  assert(type(opts.model) == "table", "model is required")
  local run
  run = async.run(function()
    local child = agent_loop.run({
      model = opts.model,
      messages = context_messages(session, opts),
      system_prompt = opts.system_prompt,
      tools = opts.tools,
      model_options = opts.model_options,
      context = opts.context,
      execute_tool = opts.execute_tool,
      get_steering_messages = opts.get_steering_messages,
      commit_message = opts.commit_message,
      on_event = function(event)
        run:emit(event)
      end,
      report = opts.diagnostic_report,
    })
    local result = child:await()
    return finish_result(result, session)
  end, {
    on_event = opts.on_event,
    on_done = function(result)
      release(session, run)
      if opts.on_done then opts.on_done(result) end
    end,
    report = opts.diagnostic_report,
    error_kind = "session",
  })
  return run
end


function M.run(session, prompt, opts)
  opts = opts or {}
  opts = preflight(opts, opts.tools or {}, session_commit(session))
  local reservation, entry = begin(session, prompt, opts.session_state)
  accepted(opts, entry)
  return start_reserved(session, reservation, function()
    return run_agent(session, opts)
  end)
end

function M.continue(session, opts)
  opts = opts or {}
  opts = preflight(opts, opts.tools or {}, session_commit(session))
  local reservation = reserve(session)
  return start_reserved(session, reservation, function()
    return run_agent(session, opts)
  end)
end

return M
