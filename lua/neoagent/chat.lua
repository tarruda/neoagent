local agent_loop = require("neoagent.agent_loop")
local async = require("neoagent.async")
local request_context = require("neoagent.api.request_context")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.ChatSuccess: Neoagent.ModelSuccess
---@field session Neoagent.Session
---@field new_messages? Neoagent.Message[]

---@class Neoagent.ChatFailure: Neoagent.AgentLoopFailure
---@field session? Neoagent.Session
---@field text? string

---@alias Neoagent.ChatResult Neoagent.ChatSuccess|Neoagent.ChatFailure
---@alias Neoagent.ChatRun Neoagent.Run<Neoagent.ChatResult, Neoagent.AgentLoopEvent>
---@alias Neoagent.ContextMessages Neoagent.Message[]|fun(session: Neoagent.Session): Neoagent.Message[]?, Neoagent.Error?

---@class Neoagent.ChatOptions<C>
---@field model Neoagent.Model
---@field system_prompt? string
---@field tools? Neoagent.Tool<C>[]
---@field model_options? Neoagent.StreamOverrides
---@field context? C
---@field execute_tool? Neoagent.ToolExecutor<C>
---@field get_steering_messages? Neoagent.SteeringMessages
---@field on_event? fun(event: Neoagent.AgentLoopEvent)
---@field on_done? fun(result: Neoagent.ChatResult)
---@field on_accept? fun(entry?: Neoagent.JournalEntry)
---@field report? fun(message: string, level: integer)
---@field context_messages? Neoagent.ContextMessages
---@field session_state? Neoagent.RequestStateInput

---@class Neoagent.PreparedChat<C>
---@field model Neoagent.Model
---@field system_prompt? string
---@field tools Neoagent.Tool<C>[]
---@field model_options Neoagent.StreamOverrides
---@field context? C
---@field execute_tool Neoagent.ToolExecutor<C>
---@field get_steering_messages Neoagent.SteeringMessages
---@field commit_message Neoagent.MessageCommit
---@field on_event? fun(event: Neoagent.AgentLoopEvent)
---@field on_done? fun(result: Neoagent.ChatResult)
---@field on_accept? fun(entry?: Neoagent.JournalEntry)
---@field report? fun(message: string, level: integer)
---@field diagnostic_report? fun(diagnostic: Neoagent.AsyncDiagnostic)
---@field context_messages? Neoagent.ContextMessages
---@field session_state? Neoagent.RequestStateInput

---@type table<Neoagent.Session, table>
local active = setmetatable({}, { __mode = "k" })

---@param message Neoagent.Message
---@param entry? Neoagent.JournalEntry
---@return Neoagent.ObservedMessage
local function persisted_message(message, entry)
  ---@type Neoagent.ObservedMessage
  local copied = util.copy(message)
  copied._neoagent_entry_id = entry and entry.id or nil
  return copied
end

---@param session Neoagent.Session
---@return Neoagent.MessageCommit
local function session_commit(session)
  return function(message)
    local ok, err, entry = session:append(message)
    if not ok then
      return nil, err
    end
    return true, nil, persisted_message(message, entry)
  end
end

---@param session Neoagent.Session
---@param overrides? Neoagent.StreamOverrides
---@return Neoagent.StreamOverrides
local function model_options(session, overrides)
  local result = util.copy(overrides or {})
  local files = session:files()
  assert(
    result.files == nil or result.files.identity == files.identity,
    "Chat Model and Session must share attachment storage"
  )
  assert(
    result.file_cache == nil or result.file_cache.scope == files.identity,
    "Chat upload cache must belong to the Session's workspace"
  )
  result.files, result.file_cache = files, session:file_cache()
  result.request_context = request_context.resolve({ session_id = session:id() }, result.request_context)
  return result
end

---@param report? fun(message: string, level: integer)
---@return (fun(diagnostic: Neoagent.AsyncDiagnostic))?
local function diagnostic_report(report)
  if not report then
    return nil
  end
  return function(diagnostic)
    report("callback failed during " .. diagnostic.phase .. ": " .. diagnostic.message, vim.log.levels.ERROR)
  end
end

---@generic C
---@param session Neoagent.Session
---@param opts Neoagent.ChatOptions<C>
---@param tools Neoagent.Tool<C>[]
---@param commit_message Neoagent.MessageCommit
---@return Neoagent.PreparedChat<C>
local function preflight(session, opts, tools, commit_message)
  assert(opts.report == nil or type(opts.report) == "function", "report must be a function")
  assert(opts.on_done == nil or type(opts.on_done) == "function", "on_done must be a function")
  assert(opts.on_accept == nil or type(opts.on_accept) == "function", "on_accept must be a function")
  assert(
    opts.context_messages == nil
      or type(opts.context_messages) == "function"
      or type(opts.context_messages) == "table" and util.is_list(opts.context_messages),
    "context_messages must be a list or function"
  )
  ---@type Neoagent.AgentLoopOptions<C>
  local loop_options = {
    model = opts.model,
    messages = {},
    system_prompt = opts.system_prompt,
    tools = tools,
    model_options = model_options(session, opts.model_options),
    context = opts.context,
    execute_tool = opts.execute_tool,
    get_steering_messages = opts.get_steering_messages,
    commit_message = commit_message,
    on_event = opts.on_event,
    report = diagnostic_report(opts.report),
  }
  local prepared = agent_loop.prepare(loop_options)
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
    on_done = opts.on_done,
    report = opts.report,
    diagnostic_report = prepared.report,
    on_accept = opts.on_accept,
    context_messages = type(opts.context_messages) == "table" and util.copy(opts.context_messages)
      or opts.context_messages,
    session_state = opts.session_state and util.copy(opts.session_state) or nil,
  }
end

---@param session Neoagent.Session
---@param owner? table
local function release(session, owner)
  if active[session] == owner then
    active[session] = nil
  end
end

---@param session Neoagent.Session
---@return table
local function reserve(session)
  assert(
    type(session) == "table"
      and type(session.append) == "function"
      and type(session.context_messages) == "function"
      and type(session.id) == "function",
    "session is required"
  )
  if active[session] then
    error(util.error("session", "Session already has an active run"), 0)
  end
  local reservation = {}
  active[session] = reservation
  return reservation
end

---@generic C
---@param session Neoagent.Session
---@param opts Neoagent.PreparedChat<C>
---@return Neoagent.Message[]
local function context_messages(session, opts)
  local source = opts.context_messages
  local messages
  local err
  if type(source) == "function" then
    messages, err = source(session)
  elseif type(source) == "table" then
    messages = util.copy(source)
  else
    messages, err = session:context_messages()
  end
  if not messages then
    error(util.normalize_error(err, "session"), 0)
  end
  return messages
end

---@param session Neoagent.Session
---@param prompt string
---@param state? Neoagent.RequestStateInput
---@return table, Neoagent.JournalEntry?
local function begin(session, prompt, state)
  assert(type(prompt) == "string", "prompt must be a string")
  ---@type Neoagent.Message
  local message = {
    role = "user",
    content = prompt,
    timestamp = util.now_ms(),
  }
  local reservation = reserve(session)
  local called, ok, err, entry = pcall(session.append, session, message, state)
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

---@generic C
---@param opts Neoagent.PreparedChat<C>
---@param entry? Neoagent.JournalEntry
local function accepted(opts, entry)
  if type(opts.on_accept) ~= "function" then
    return
  end
  local ok, err = pcall(opts.on_accept, entry)
  if not ok and type(opts.report) == "function" then
    pcall(opts.report, "accepted message callback failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

---@param session Neoagent.Session
---@param reservation table
---@param run Neoagent.ChatRun
---@return Neoagent.ChatRun
local function install(session, reservation, run)
  assert(active[session] == reservation, "Session reservation was lost")
  active[session] = run
  return run
end

---@param session Neoagent.Session
---@param reservation table
---@param fn fun(): Neoagent.ChatRun
---@return Neoagent.ChatRun
local function start_reserved(session, reservation, fn)
  local ok, run = pcall(fn)
  if not ok then
    release(session, reservation)
    error(run, 0)
  end
  return install(session, reservation, run)
end

---@param result Neoagent.ModelSuccess|Neoagent.ModelFailure|Neoagent.AgentLoopSuccess|Neoagent.AgentLoopFailure
---@param session Neoagent.Session
---@return Neoagent.ChatResult
local function finish_result(result, session)
  ---@type Neoagent.Message[]?
  local new_messages = rawget(result, "new_messages")
  ---@type string?
  local text = rawget(result, "text")
  if result.ok == false then
    ---@cast result Neoagent.AgentLoopFailure
    local failure = result
    return {
      ok = false,
      error = util.copy(failure.error),
      message = util.copy(failure.message),
      text = text,
      new_messages = util.copy(new_messages),
      session = session,
    }
  end
  ---@cast result Neoagent.ModelSuccess
  local success = result
  return {
    ok = true,
    message = util.copy(success.message),
    text = text,
    new_messages = util.copy(new_messages),
    session = session,
  }
end

---@param event Neoagent.MessageEndEvent
---@param entry? Neoagent.JournalEntry
---@return Neoagent.MessageEndEvent
local function persisted_event(event, entry)
  local copied = util.copy(event)
  copied.message = persisted_message(copied.message, entry)
  return copied
end

---@generic C
---@param session Neoagent.Session
---@param prompt string
---@param opts Neoagent.ChatOptions<C>
---@return Neoagent.ChatRun
function M.send(session, prompt, opts)
  opts = opts or {}
  local prepared = preflight(session, opts, {}, session_commit(session))
  local reservation, entry = begin(session, prompt, prepared.session_state)
  accepted(prepared, entry)
  return start_reserved(session, reservation, function()
    ---@type Neoagent.ChatRun
    local run
    run = async.run(
      ---@return Neoagent.ChatResult
      function()
        async.yield()
        local model_opts = model_options(session, prepared.model_options)
        ---@cast model_opts Neoagent.StreamOptions
        model_opts.messages = context_messages(session, prepared)
        model_opts.system_prompt = prepared.system_prompt
        model_opts.on_event = function(event)
          run:emit(event)
        end
        local result = prepared.model:stream(model_opts):await()
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
      end,
      {
        on_event = prepared.on_event,
        on_done = function(result)
          release(session, run)
          if prepared.on_done then
            prepared.on_done(result)
          end
        end,
        report = prepared.diagnostic_report,
        error_kind = "session",
      }
    )
    return run
  end)
end

---@generic C
---@param session Neoagent.Session
---@param opts Neoagent.PreparedChat<C>
---@return Neoagent.ChatRun
local function run_agent(session, opts)
  opts = opts or {}
  assert(type(opts.model) == "table", "model is required")
  ---@type Neoagent.ChatRun
  local run
  run = async.run(
    ---@return Neoagent.ChatResult
    function()
      async.yield()
      ---@type Neoagent.AgentLoopOptions<C>
      local child_options = {
        model = opts.model,
        messages = context_messages(session, opts),
        system_prompt = opts.system_prompt,
        tools = opts.tools,
        model_options = model_options(session, opts.model_options),
        context = opts.context,
        execute_tool = opts.execute_tool,
        get_steering_messages = opts.get_steering_messages,
        commit_message = opts.commit_message,
        on_event = function(event)
          run:emit(event)
        end,
        report = opts.diagnostic_report,
      }
      local child = agent_loop.run(child_options)
      local result = child:await()
      return finish_result(result, session)
    end,
    {
      on_event = opts.on_event,
      on_done = function(result)
        release(session, run)
        if opts.on_done then
          opts.on_done(result)
        end
      end,
      report = opts.diagnostic_report,
      error_kind = "session",
    }
  )
  return run
end

---@generic C
---@param session Neoagent.Session
---@param prompt string
---@param opts Neoagent.ChatOptions<C>
---@return Neoagent.ChatRun
function M.run(session, prompt, opts)
  opts = opts or {}
  local prepared = preflight(session, opts, opts.tools or {}, session_commit(session))
  local reservation, entry = begin(session, prompt, prepared.session_state)
  accepted(prepared, entry)
  return start_reserved(session, reservation, function()
    return run_agent(session, prepared)
  end)
end

---@generic C
---@param session Neoagent.Session
---@param opts Neoagent.ChatOptions<C>
---@return Neoagent.ChatRun
function M.continue(session, opts)
  opts = opts or {}
  local prepared = preflight(session, opts, opts.tools or {}, session_commit(session))
  local reservation = reserve(session)
  return start_reserved(session, reservation, function()
    return run_agent(session, prepared)
  end)
end

return M
