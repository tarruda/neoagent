local common = require("neoagent.tools.common")
local identities = require("neoagent.tools.identities")
local schema = require("neoagent.api.tool_schema")
local result_receipt = require("neoagent.result_receipt")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.ToolProcesses
---@field reserve fun(self: Neoagent.ToolProcesses, spec: Neoagent.SubprocessSpec): Neoagent.ProcessAdmission
---@field begin_interaction fun(self: Neoagent.ToolProcesses, id: string): Neoagent.ProcessInteraction

---@class Neoagent.ProcessToolDetails: Neoagent.JsonObject
---@field session_id? string
---@field exit_code? integer
---@field signal? integer
---@field wall_time_seconds number
---@field output string
---@field truncated boolean
---@field dropped_bytes integer
---@field error? Neoagent.JsonObject
---@field cleanup_error? Neoagent.JsonObject
---@field release_error? Neoagent.JsonObject
---@field request_error? Neoagent.JsonObject Failure of this Tool call, independent of the target outcome.
---@field execution Neoagent.NativeExecution
---@field outcome_uncertain boolean
---@field done boolean
---@field cleanup_done boolean
---@field released boolean

---@param ctx Neoagent.ToolContext<unknown>
---@return Neoagent.ToolProcesses
local function processes(ctx)
  local value = type(ctx.context) == "table" and rawget(ctx.context, "processes") or nil
  assert(
    type(value) == "table" and type(value.reserve) == "function" and type(value.begin_interaction) == "function",
    "Process Tools require an Agent process manager"
  )
  ---@cast value Neoagent.ToolProcesses
  return value
end

---@param err? Neoagent.Error
---@return Neoagent.JsonObject?
local function error_details(err)
  if err then
    return {
      kind = err.kind,
      code = err.code,
      message = util.safe_message(err.message),
      detail = err.detail and util.safe_message(err.detail) or nil,
    }
  end
end

---@param value unknown
---@param default integer
---@param maximum integer
---@param name string
---@return integer
local function budget(value, default, maximum, name)
  if value == nil then
    return default
  end
  local result = common.integer(value, name, true)
  assert(result <= maximum, name .. " must not exceed " .. maximum)
  return result
end

---@param arguments Neoagent.JsonObject
---@return string[]
local function command(arguments)
  return require("neoagent.tools.command").argv(
    common.require_string(arguments, "cmd"),
    arguments.shell and common.path(arguments.shell, "shell") or nil,
    arguments.login ~= false
  )
end

---@param observation Neoagent.ProcessSessionResult
---@param started number
---@param tokens integer
---@param request_error? Neoagent.Error
---@return Neoagent.ToolResult
local function result(observation, started, tokens, request_error)
  local shortened = require("neoagent.tools.truncate").tail(observation.text, { max_bytes = tokens * 4 })
  local output = shortened.content
  if shortened.truncated or observation.dropped_bytes > 0 then
    output = "[Output truncated]\n" .. output
  end
  local outcome = observation.outcome
  local uncertain = observation.execution ~= "not_started"
    and outcome == nil
    and (observation.done or observation.error ~= nil or request_error ~= nil and observation.session_id == nil)
  local id = not observation.done and observation.session_id or nil
  local elapsed = (vim.uv.hrtime() - started) / 1e9
  local lines = { string.format("Wall time: %.3f seconds", elapsed) }
  if id then
    lines[#lines + 1] = "Process running with session ID " .. id
  elseif outcome then
    lines[#lines + 1] = "Process exited with code " .. outcome.code
    if outcome.signal ~= 0 then
      lines[#lines + 1] = "Signal: " .. outcome.signal
    end
    if outcome.timed_out then
      lines[#lines + 1] = "Command timed out"
    end
  elseif observation.execution == "not_started" then
    lines[#lines + 1] = "Command did not start"
  elseif request_error and not observation.done then
    lines[#lines + 1] = "Target completion has not been observed"
  else
    lines[#lines + 1] = "Process session ended; exit status is unconfirmed"
  end
  local failure = observation.error
  if failure then
    lines[#lines + 1] = "Process error: " .. util.safe_message(failure.message)
  end
  if request_error then
    lines[#lines + 1] = "Request error: " .. util.safe_message(request_error.message)
  end
  lines[#lines + 1] = "Output:\n" .. output
  if uncertain then
    lines[#lines + 1] = "The command outcome is unconfirmed; effects may have completed. Do not retry automatically."
  end
  local cleanup = observation.cleanup_error or observation.release_error
  if cleanup then
    lines[#lines + 1] = "Cleanup notice: " .. util.safe_message(cleanup.message)
    if observation.release_error then
      lines[#lines + 1] = "Native release is unconfirmed: " .. util.safe_message(observation.release_error.message)
    end
  end
  if outcome and (cleanup or request_error) then
    lines[#lines + 1] = "The command outcome above remains authoritative; do not retry it automatically."
  end
  return {
    content = { { type = "text", text = table.concat(lines, "\n") } },
    isError = request_error ~= nil
      or failure ~= nil
      or observation.done and outcome == nil
      or outcome ~= nil and (outcome.code ~= 0 or outcome.signal ~= 0 or outcome.timed_out),
    details = {
      session_id = id,
      exit_code = outcome and outcome.code,
      signal = outcome and outcome.signal,
      wall_time_seconds = elapsed,
      output = output,
      truncated = shortened.truncated or observation.dropped_bytes > 0,
      dropped_bytes = observation.dropped_bytes,
      error = error_details(observation.error),
      cleanup_error = error_details(observation.cleanup_error),
      release_error = error_details(observation.release_error),
      request_error = error_details(request_error),
      execution = observation.execution,
      outcome_uncertain = uncertain,
      done = observation.done,
      cleanup_done = observation.cleanup_done,
      released = observation.released,
    },
  }
end

-- Recovery precedes abandonment, so it observes execution before disposal
-- can change the outcome. Interactions preserve their already-published ID.
---@param state? Neoagent.ProcessControllerState
---@param err Neoagent.Error
---@param started number
---@param id? string
---@return Neoagent.ToolResult
local function request_failed(state, err, started, id)
  if not state then
    return { content = { { type = "text", text = util.safe_message(err.message) } }, isError = true }
  end
  return result({
    session_id = id,
    events = {},
    text = "",
    dropped_bytes = 0,
    done = state.done,
    cleanup_done = state.cleanup_done,
    released = state.released,
    stdin_writable = state.stdin_writable,
    resize_supported = state.resize_supported,
    execution = state.execution,
    outcome = state.outcome,
    error = state.error,
    cleanup_error = state.cleanup_error,
    release_error = state.release_error,
  }, started, 0, err)
end

---@param tool_schema Neoagent.ToolSchema
---@param arguments Neoagent.JsonObject
local function validate(tool_schema, arguments)
  local valid, err = schema.validate(tool_schema, arguments)
  assert(valid, err)
  common.request(arguments, "Process Tool arguments")
end

---@return Neoagent.Tool<unknown>
local function exec_command()
  local input = {
    type = "object",
    properties = {
      cmd = { type = "string", description = "Shell command to execute." },
      workdir = { type = "string", description = "Working directory; defaults to the workspace cwd." },
      shell = { type = "string", description = "Shell executable; defaults to Neovim's shell." },
      login = {
        type = "boolean",
        description = "Use POSIX login mode or load PowerShell profiles. Defaults to true; overrides configured login/NoProfile flags.",
      },
      tty = {
        type = "boolean",
        description = "Allocate a PTY for interactive input. Defaults to false (closed stdin).",
      },
      yield_time_ms = {
        type = "integer",
        description = "Initial wait, 0–30000 ms. Defaults to 10000. This does not stop the command.",
      },
      max_output_tokens = {
        type = "integer",
        description = "Approximate output budget, 0–10000 tokens (four bytes each). Defaults to 10000.",
      },
      timeout_ms = {
        type = "integer",
        description = "Optional process lifetime limit in milliseconds. Omit for no lifetime limit.",
      },
    },
    required = { "cmd" },
    additionalProperties = false,
  }
  ---@param arguments Neoagent.JsonObject
  ---@param _ table
  ---@param call Neoagent.ToolOperationCall
  ---@return Neoagent.SubprocessSpec
  local function prepare(arguments, _, call)
    validate(input, arguments)
    local argv = require("neoagent.tools.command").resolve(command(arguments), call)
    return {
      argv = argv,
      cwd = arguments.workdir and common.resolve_path(common.require_string(arguments, "workdir"), call)
        or call.workspace.cwd,
      stdio = arguments.tty and { kind = "pty", columns = 80, rows = 24 } or { kind = "pipes" },
      timeout_ms = arguments.timeout_ms ~= nil and common.integer(arguments.timeout_ms, "timeout_ms") or nil,
    }
  end
  ---@async
  ---@param request Neoagent.SubprocessSpec
  ---@param arguments Neoagent.JsonObject
  ---@param ctx Neoagent.ToolContext<unknown>
  ---@return Neoagent.ToolResult
  local function run(request, arguments, ctx)
    validate(input, arguments)
    local wait_ms = budget(arguments.yield_time_ms, 10000, 30000, "yield_time_ms")
    local tokens = budget(arguments.max_output_tokens, 10000, 10000, "max_output_tokens")
    local owner = processes(ctx)
    assert(type(ctx.on_result) == "function", "exec_command requires Tool result acceptance")
    local on_result = ctx.on_result
    ---@type Neoagent.ProcessAdmission?
    local admission
    ---@type string?
    local offered_id
    local started = vim.uv.hrtime()
    on_result({
      finish = function(accepted, receipt)
        if admission then
          if accepted and receipt and receipt.session_id == offered_id then
            admission.commit(receipt.output == true)
          else
            admission.abort("Tool result was not accepted")
          end
        end
      end,
      recover = function(err)
        return request_failed(admission and admission.state(), err, started)
      end,
    })
    admission = owner:reserve(request)
    local observation = admission.start(wait_ms)
    offered_id = not observation.done and observation.session_id or nil
    return result_receipt.bind(result(observation, started, tokens), { session_id = offered_id, output = true })
  end
  return identities.bind({
    name = "exec_command",
    description = "Run a shell command, returning output and a session ID if it is still running. Use write_stdin to poll, send PTY input, or interrupt. New commands use the Agent's sandbox policy; retained processes keep their admitted authority.",
    input_schema = input,
    render = require("neoagent.tools.activity_presentation").exec_command,
  }, { token = identities.exec_command, settings = {}, prepare = identities.workspace_prepare(prepare), run = run })
end

---@return Neoagent.Tool<unknown>
function M.exec_command()
  return exec_command()
end

---@return Neoagent.Tool<unknown>
function M.write_stdin()
  local input = {
    type = "object",
    properties = {
      session_id = { type = "string", description = "Exact session ID returned by exec_command in this Agent." },
      chars = {
        type = "string",
        description = "PTY input (up to 65536 bytes). Empty polls; a single Ctrl-C interrupts pipes or PTYs.",
      },
      terminate = {
        type = "boolean",
        description = "End the owned process with forced escalation if needed. Cannot be combined with nonempty chars.",
      },
      yield_time_ms = {
        type = "integer",
        description = "Wait budget. Empty polls default to 5000 ms (maximum 300000); input defaults to 250 ms (maximum 30000).",
      },
      max_output_tokens = {
        type = "integer",
        description = "Approximate output budget, 0–10000 tokens (four bytes each). Defaults to 10000.",
      },
    },
    required = { "session_id" },
    additionalProperties = false,
  }
  ---@param arguments Neoagent.JsonObject
  local function prepare(arguments)
    validate(input, arguments)
    local chars = arguments.chars and common.require_string(arguments, "chars", true) or ""
    assert(#chars <= 65536, "chars must not exceed 65536 bytes")
    assert(not arguments.terminate or chars == "", "terminate cannot be combined with chars")
    local wait_ms =
      budget(arguments.yield_time_ms, chars == "" and 5000 or 250, chars == "" and 300000 or 30000, "yield_time_ms")
    local tokens = budget(arguments.max_output_tokens, 10000, 10000, "max_output_tokens")
    local id = common.require_string(arguments, "session_id")
    ---@type Neoagent.ProcessControl?
    local control
    if arguments.terminate then
      control = { kind = "terminate", reason = "Terminated through write_stdin" }
    elseif chars == "\3" then
      control = { kind = "interrupt" }
    elseif chars ~= "" then
      control = { kind = "write", data = chars }
    end
    return { id = id, wait_ms = wait_ms, tokens = tokens, control = control }
  end
  ---@async
  ---@param request {id: string, wait_ms: integer, tokens: integer, control?: Neoagent.ProcessControl}
  ---@param _ Neoagent.JsonObject
  ---@param ctx Neoagent.ToolContext<unknown>
  ---@return Neoagent.ToolResult
  local function run(request, _, ctx)
    local owner = processes(ctx)
    local started = vim.uv.hrtime()
    ---@type Neoagent.ProcessInteraction?
    local interaction
    assert(ctx.on_result, "write_stdin requires Tool result acceptance")({
      finish = function(accepted, receipt)
        if interaction then
          if accepted and receipt and receipt.output == true then
            interaction.commit()
          else
            interaction.abort()
          end
        end
      end,
      recover = function(err)
        return request_failed(interaction and interaction.state(), err, started, request.id)
      end,
    })
    interaction = owner:begin_interaction(request.id)
    local observation = interaction.collect(request.wait_ms, request.control)
    return result_receipt.bind(result(observation, started, request.tokens), { output = true })
  end
  return identities.bind({
    name = "write_stdin",
    description = "Send input to an existing process, poll new output, or terminate it. Cancelling this wait preserves the process and unpublished output. Sessions belong to this Agent and are unavailable after the Agent is destroyed or the editor restarts.",
    input_schema = input,
  }, {
    token = identities.write_stdin,
    settings = {},
    prepare = prepare,
    run = run,
  })
end

return M
