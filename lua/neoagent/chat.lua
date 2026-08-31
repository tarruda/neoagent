local agent_loop = require("neoagent.agent_loop")
local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}
local active = setmetatable({}, { __mode = "k" })

local function diagnostic_report(report)
  if not report then return nil end
  return function(diagnostic)
    report("callback failed during " .. diagnostic.phase .. ": "
      .. diagnostic.message, vim.log.levels.ERROR)
  end
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
  copied.message._neoagent_entry_id = entry.id
  return copied
end

function M.send(session, prompt, opts)
  opts = opts or {}
  assert(type(opts.model) == "table", "model is required")
  assert(opts.report == nil or type(opts.report) == "function",
    "report must be a function")
  local reporter = diagnostic_report(opts.report)
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
      report = reporter,
      error_kind = "session",
    })
    return run
  end)
end

local function run_agent(session, opts)
  opts = opts or {}
  assert(type(opts.model) == "table", "model is required")
  local reporter = diagnostic_report(opts.report)
  local run
  run = async.run(function()
    local storage_error
    local child = agent_loop.run({
      model = opts.model,
      messages = context_messages(session, opts),
      system_prompt = opts.system_prompt,
      tools = opts.tools,
      model_options = opts.model_options,
      context = opts.context,
      execute_tool = opts.execute_tool,
      get_steering_messages = opts.get_steering_messages,
      on_event = function(event)
        if event.type == "message_end" and not storage_error then
          local ok, err, entry = session:append(event.message)
          if not ok then
            storage_error = err
          else
            event = persisted_event(event, entry)
          end
        end
        if not storage_error then
          run:emit(event)
        end
      end,
      report = reporter,
    })
    local result = child:await()
    if storage_error then
      return finish_result({
        ok = false,
        new_messages = result.new_messages or {},
        message = result.message,
        error = storage_error,
      }, session)
    end
    return finish_result(result, session)
  end, {
    on_event = opts.on_event,
    on_done = function(result)
      release(session, run)
      if opts.on_done then opts.on_done(result) end
    end,
    report = reporter,
    error_kind = "session",
  })
  return run
end


function M.run(session, prompt, opts)
  opts = opts or {}
  assert(opts.report == nil or type(opts.report) == "function",
    "report must be a function")
  local reservation, entry = begin(session, prompt, opts.session_state)
  accepted(opts, entry)
  return start_reserved(session, reservation, function()
    return run_agent(session, opts)
  end)
end

function M.continue(session, opts)
  opts = opts or {}
  assert(opts.report == nil or type(opts.report) == "function",
    "report must be a function")
  local reservation = reserve(session)
  return start_reserved(session, reservation, function()
    return run_agent(session, opts)
  end)
end

return M
