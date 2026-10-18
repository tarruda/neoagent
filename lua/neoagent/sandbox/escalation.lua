local result = require("neoagent.sandbox.result")
local summaries = require("neoagent.sandbox.approval_summary")
local identities = require("neoagent.tools.identities")
local invocations = require("neoagent.tools.invocation")
local util = require("neoagent.util")

local M = {}
---@alias Neoagent.SandboxShellKind 'posix'|'cmd'|'powershell'

---@class Neoagent.SandboxPrefixRule
---@field kind Neoagent.SandboxShellKind
---@field shell string
---@field tokens string[]

---@class Neoagent.SandboxPrefixCandidate: Neoagent.SandboxPrefixRule
---@field command string

---@class Neoagent.SandboxEscalationRequest
---@field justification string
---@field prefix_rule? string[]

---@class Neoagent.SandboxDecisionMetadata
---@field presenter_unavailable? boolean
---@field input? string

---@class Neoagent.SandboxEscalationOptions<C>
---@field summarize? fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): string

---@class Neoagent.SandboxEscalation<C>
---@field _summarize fun(tool: Neoagent.Tool<C>, arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<C>): string
---@field _rules Neoagent.SandboxPrefixRule[]
---@field _default_session table
---@field _session_key? unknown
local Escalation = {}
Escalation.__index = Escalation

---@param value unknown
---@return TypeGuard<Neoagent.JsonObject>
local function is_object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

---@param value unknown
---@param limit integer
---@return string
local function bounded(value, limit)
  value = tostring(value or "")
  value = value:gsub("[%z\1-\31\127]", function(character)
    return string.format("\\x%02X", character:byte())
  end)
  if #value > limit then
    value = value:sub(1, limit - 3) .. "..."
  end
  return value
end

---@generic C
---@param ctx Neoagent.ToolContext<C>
---@return string?
local function workspace_cwd(ctx)
  local context = ctx and ctx.context
  local workspace = type(context) == "table" and rawget(context, "workspace") or context
  return type(workspace) == "table" and type(workspace.cwd) == "string" and workspace.cwd or nil
end

---@param shell string
---@return Neoagent.SandboxShellKind?
local function shell_kind(shell)
  local name = shell:gsub("\\", "/"):match("([^/]+)$")
  name = name and name:lower():gsub("%.exe$", "") or ""
  if name == "cmd" or name == "cmd.exe" then
    return "cmd"
  end
  if name == "powershell" or name == "powershell.exe" or name == "pwsh" or name == "pwsh.exe" then
    return "powershell"
  end
  if name == "sh" or name == "bash" or name == "dash" or name == "ksh" or name == "zsh" then
    return "posix"
  end
end

---@param shell string
---@return string
local function shell_key(shell)
  shell = shell:gsub("\\", "/")
  return jit.os == "Windows" and shell:lower() or shell
end

---@param buffer string[]
---@param character string
local function append(buffer, character)
  buffer[#buffer + 1] = character
end

---@param command string
---@param partial? boolean
---@return string[]?, string?
local function parse_posix(command, partial)
  local tokens, buffer = {}, {}
  local quote, started, index = nil, false, 1
  local failure
  local function emit()
    if started then
      tokens[#tokens + 1] = table.concat(buffer)
      buffer, started = {}, false
    end
  end
  while index <= #command do
    local character = command:sub(index, index)
    if quote == "single" then
      if character == "'" then
        quote = nil
      else
        append(buffer, character)
      end
    elseif quote == "double" then
      if character == '"' then
        quote = nil
      elseif character == "$" or character == "`" then
        failure = "shell expansion is not supported"
      elseif character == "\\" then
        local following = command:sub(index + 1, index + 1)
        if following == "" then
          failure = "trailing escape"
        elseif following == "$" or following == "`" or following == '"' or following == "\\" then
          append(buffer, following)
          index = index + 1
        else
          append(buffer, character)
        end
      else
        append(buffer, character)
      end
    elseif character:match("%s") then
      emit()
    elseif character == "'" then
      quote, started = "single", true
    elseif character == '"' then
      quote, started = "double", true
    elseif character == "\\" then
      local following = command:sub(index + 1, index + 1)
      if following == "" then
        failure = "trailing escape"
      else
        append(buffer, following)
        started, index = true, index + 1
      end
    elseif character == "$" or character == "`" then
      failure = "shell expansion is not supported"
    elseif character:match("[&|;<>%(%){}]") or character == "#" then
      failure = "shell operators are not supported"
    else
      append(buffer, character)
      started = true
    end
    if failure then
      break
    end
    index = index + 1
  end
  if not failure and quote then
    failure = "unterminated quote"
  end
  if failure and not partial then
    return nil, failure
  end
  emit()
  if #tokens == 0 then
    return nil, failure or "prefix is empty"
  end
  return tokens
end

---@param command string
---@param partial? boolean
---@return string[]?, string?
local function parse_cmd(command, partial)
  local tokens, buffer = {}, {}
  local quoted, started = false, false
  local failure
  local function emit()
    if started then
      tokens[#tokens + 1] = table.concat(buffer)
      buffer, started = {}, false
    end
  end
  for index = 1, #command do
    local character = command:sub(index, index)
    if character == '"' then
      if index > 1 and command:sub(index - 1, index - 1) == "\\" then
        failure = "escaped quotes are not supported"
        break
      end
      quoted, started = not quoted, true
    elseif character == "%" or character == "!" or character == "^" then
      failure = "cmd expansion is not supported"
      break
    elseif not quoted and character:match("%s") then
      emit()
    elseif not quoted and character:match("[&|<>()]") then
      failure = "cmd operators are not supported"
      break
    else
      append(buffer, character)
      started = true
    end
  end
  if not failure and quoted then
    failure = "unterminated quote"
  end
  if failure and not partial then
    return nil, failure
  end
  emit()
  if #tokens == 0 then
    return nil, failure or "prefix is empty"
  end
  return tokens
end

---@param command string
---@param partial? boolean
---@return string[]?, string?
local function parse_powershell(command, partial)
  local tokens, buffer = {}, {}
  local quote, started, index = nil, false, 1
  local failure
  local function emit()
    if started then
      tokens[#tokens + 1] = table.concat(buffer)
      buffer, started = {}, false
    end
  end
  while index <= #command do
    local character = command:sub(index, index)
    if quote == "single" then
      if character == "'" and command:sub(index + 1, index + 1) == "'" then
        append(buffer, "'")
        index = index + 1
      elseif character == "'" then
        quote = nil
      else
        append(buffer, character)
      end
    elseif quote == "double" then
      if character == '"' then
        quote = nil
      elseif character == "$" or character == "`" then
        failure = "PowerShell expansion is not supported"
      else
        append(buffer, character)
      end
    elseif character:match("%s") then
      emit()
    elseif character == "'" then
      quote, started = "single", true
    elseif character == '"' then
      quote, started = "double", true
    elseif character == "$" or character == "`" then
      failure = "PowerShell expansion is not supported"
    elseif character:match("[&|;<>%(%){}@,]") then
      failure = "PowerShell operators are not supported"
    else
      append(buffer, character)
      started = true
    end
    if failure then
      break
    end
    index = index + 1
  end
  if not failure and quote then
    failure = "unterminated quote"
  end
  if failure and not partial then
    return nil, failure
  end
  emit()
  if #tokens == 0 then
    return nil, failure or "prefix is empty"
  end
  return tokens
end

---@param command unknown
---@param kind Neoagent.SandboxShellKind
---@param partial? boolean
---@return string[]?, string?
local function parse_command(command, kind, partial)
  if type(command) ~= "string" then
    return nil, "command must be a string"
  end
  if #command > 16384 then
    return nil, "command is too long"
  end
  if partial then
    local cut = command:find("[%z\1-\8\10-\31\127]")
    if cut then
      command = command:sub(1, cut - 1)
    end
  else
    if command:find("[%z\1-\8\11\12\14-\31\127]") then
      return nil, "control characters are not supported"
    end
    if command:find("[\r\n]") then
      return nil, "multiple commands are not supported"
    end
  end
  if kind == "posix" then
    return parse_posix(command, partial)
  end
  if kind == "cmd" then
    return parse_cmd(command, partial)
  end
  return parse_powershell(command, partial)
end

---@param tokens string[]
---@param prefix string[]
---@return boolean
local function starts_with(tokens, prefix)
  if #prefix > #tokens then
    return false
  end
  for index, token in ipairs(prefix) do
    if tokens[index] ~= token then
      return false
    end
  end
  return true
end

---@param tool Neoagent.Tool<C>
---@param arguments unknown
---@return Neoagent.JsonObject?, string?, Neoagent.SandboxEscalationRequest?
function Escalation:_extract(tool, arguments)
  if not is_object(arguments) then
    return nil, "tool arguments must be an object"
  end
  local copied = util.copy(arguments)
  local identity = identities.identity(tool)
  if not identity or identity.token ~= identities.exec_command then
    return copied
  end
  local requested, justification = copied.sandbox_permissions, copied.justification
  local prefix = copied.prefix_rule
  copied.sandbox_permissions, copied.justification, copied.prefix_rule = nil, nil, nil
  if requested == nil or requested == "use_default" then
    if justification ~= nil or prefix ~= nil then
      return nil, "justification and prefix_rule require sandbox_permissions = require_escalated"
    end
    return copied
  end
  if requested ~= "require_escalated" then
    return nil, "unsupported sandbox_permissions"
  end
  if type(justification) ~= "string" or util.trim(justification) == "" or #justification > 1000 then
    return nil, "justification must be non-empty text of at most 1000 bytes"
  end
  if prefix ~= nil then
    if type(prefix) ~= "table" or not util.is_list(prefix) or #prefix == 0 then
      return nil, "prefix_rule must be a nonempty list"
    end
    for _, word in ipairs(prefix) do
      if type(word) ~= "string" or word == "" then
        return nil, "prefix_rule must contain nonempty strings"
      end
    end
  end
  local words
  if prefix then
    words = {}
    for index = 1, #prefix do
      local value = prefix[index]
      assert(type(value) == "string", "prefix_rule must contain strings")
      words[#words + 1] = value
    end
  end
  return copied, nil, { justification = justification, prefix_rule = words }
end

---@param tool Neoagent.Tool<C>
---@param arguments Neoagent.JsonObject
---@param ctx Neoagent.ToolContext<C>
---@return Neoagent.SandboxPrefixCandidate?
function Escalation:_candidate(tool, arguments, ctx)
  local identity = identities.identity(tool)
  if not identity then
    return
  end
  ---@type string?, string?, Neoagent.SandboxShellKind?
  local command, shell, kind
  if identity.token == identities.exec_command or identity.token == identities.shell then
    local call = require("neoagent.tools.common").call(ctx)
    local prepared = invocations.current(tool.execute, ctx) or assert(invocations.prepare(tool, arguments, ctx))
    local spec = invocations.request(prepared, call)
    local argv = rawget(spec, "argv")
    assert(type(argv) == "table", "Command argv must be a list")
    shell = assert(argv[1])
    assert(type(shell) == "string", "Command shell must be a string")
    kind = shell_kind(shell)
    local source = prepared.arguments
    local value = identity.token == identities.exec_command and source.cmd or source.command
    if type(value) == "string" then
      command = value
    end
  end
  if not kind or type(command) ~= "string" then
    return
  end
  local tokens = parse_command(command, kind, true)
  if not tokens then
    return
  end
  return { command = command, kind = kind, shell = shell_key(assert(shell)), tokens = tokens }
end

---@param tool Neoagent.Tool<C>
---@param arguments Neoagent.JsonObject
---@param escalation Neoagent.SandboxEscalationRequest
---@param ctx Neoagent.ToolContext<C>
---@return Neoagent.DialogRequest, Neoagent.SandboxPrefixCandidate?
function Escalation:_request(tool, arguments, escalation, ctx)
  local agent = ctx and ctx.context and ctx.context.agent or "Neoagent"
  local summary
  local ok, value = pcall(self._summarize, tool, arguments, ctx)
  if ok and type(value) == "string" and util.trim(value) ~= "" then
    summary = value
  else
    summary = "Run " .. tostring(tool.name) .. " with its current arguments"
  end
  local body = {
    "Run this tool once outside the sandbox?",
    "",
    "Tool: " .. bounded(tool.name, 128),
  }
  local cwd = workspace_cwd(ctx)
  if cwd then
    body[#body + 1] = "Working directory: " .. bounded(cwd, 2000)
  end
  body[#body + 1] = "Agent justification: " .. bounded(escalation.justification, 1000)
  body[#body + 1] = ""
  body[#body + 1] = bounded(summary, 2000)
  body[#body + 1] = ""
  body[#body + 1] =
    "This grants the tool your full user filesystem, process, environment, and network authority for this call."
  local identity = identities.identity(tool)
  if identity and identity.token == identities.exec_command then
    body[#body + 1] =
      "The started process retains this authority until it exits or is terminated, including after sandbox toggles."
  end
  local candidate = self:_candidate(tool, arguments, ctx)
  if candidate and escalation.prefix_rule then
    if starts_with(candidate.tokens, escalation.prefix_rule) then
      local quoted = {}
      for _, token in ipairs(escalation.prefix_rule) do
        if candidate.kind == "posix" then
          quoted[#quoted + 1] = "'" .. token:gsub("'", "'\\''") .. "'"
        else
          quoted[#quoted + 1] = '"' .. token:gsub('"', '\\"') .. '"'
        end
      end
      candidate.command = table.concat(quoted, " ")
    else
      candidate = nil
    end
  end
  local actions = {
    { id = "approve", label = "approve", key = "y" },
    { id = "deny", label = "deny", key = "n" },
    { id = "deny_all", label = "deny all pending", key = "N" },
  }
  if candidate then
    table.insert(actions, 2, {
      id = "approve_prefix",
      label = "yes and don't ask again for commands starting with",
      key = "p",
    })
  end
  return {
    placement = "transcript",
    title = "Approval required · " .. bounded(agent, 128),
    body = table.concat(body, "\n"),
    default_action = "deny",
    actions = actions,
  },
    candidate
end

---@param value unknown
---@param actions Neoagent.DialogAction[]
---@return string?, Neoagent.Error?, Neoagent.SandboxDecisionMetadata?
---@async
local function await_decision(value, actions)
  local metadata = {}
  if type(value) == "table" and type(value.await) == "function" then
    local run = value --[[@as Neoagent.DialogRun]]
    if run:is_done() then
      value = run:result()
    elseif require("neoagent.async").current() then
      value = run:await()
    else
      run:cancel()
      return nil, util.error("sandbox_approval", "Approval requires a running neoagent.async coroutine")
    end
  end
  if type(value) == "table" and value.ok ~= nil then
    local response = value --[[@as Neoagent.DialogResult]]
    if not response.ok then
      metadata.presenter_unavailable = response.presenter_unavailable == true
      return nil, response.error or util.error("sandbox_approval", "Dialog failed"), metadata
    end
    metadata.input = response.input
    value = response.action
  end
  if value == true then
    value = "approve"
  end
  if value == false then
    value = "deny"
  end
  local allowed = {}
  for _, action in ipairs(actions or {}) do
    allowed[action.id] = true
  end
  if type(value) ~= "string" or not allowed[value] then
    return nil, util.error("sandbox_approval", "Dialog returned an invalid action"), metadata
  end
  return value, nil, metadata
end

---@param request Neoagent.DialogRequest
---@param ctx Neoagent.ToolContext<C>
---@return string?, Neoagent.Error?, Neoagent.SandboxDecisionMetadata?
---@async
function Escalation:_decision(request, ctx)
  local dialogs = ctx and (ctx --[[@as Neoagent.DialogToolContext<C>]]).dialog
  if type(dialogs) ~= "table" or type(dialogs.show) ~= "function" or type(dialogs.choose_pending) ~= "function" then
    return nil, util.error("sandbox_approval", "Dialog capability is unavailable")
  end
  local ok, value = pcall(dialogs.show, dialogs, util.copy(request))
  if not ok then
    return nil, util.normalize_error(value, "sandbox_approval")
  end
  return await_decision(value, request.actions)
end

---@param value string
---@param reason? string
---@return Neoagent.DialogRequest
function Escalation:_prefix_dialog(value, reason)
  local body = "Edit the command prefix to remember for this session."
  if reason then
    body = "That prefix cannot be remembered: " .. bounded(reason, 1000) .. "\n\n" .. body
  end
  return {
    placement = "float",
    title = "Remember command prefix",
    body = body,
    input = {
      label = "Command prefix",
      value = value,
      multiline = false,
    },
    actions = {
      { id = "accept_prefix", label = "accept", key = "<CR>" },
      { id = "cancel_prefix", label = "cancel", key = "<C-c>" },
    },
  }
end

---@param value unknown
---@param candidate Neoagent.SandboxPrefixCandidate
---@return Neoagent.SandboxPrefixRule?, string?
function Escalation:_validate_prefix(value, candidate)
  local tokens, parse_err = parse_command(value, candidate.kind)
  if not tokens then
    return nil, parse_err
  end
  if not starts_with(candidate.tokens, tokens) then
    return nil, "the prefix must match the current command"
  end
  return {
    kind = candidate.kind,
    shell = candidate.shell,
    tokens = tokens,
  }
end

---@param candidate Neoagent.SandboxPrefixCandidate
---@param ctx Neoagent.ToolContext<C>
---@return Neoagent.SandboxPrefixRule|false|nil, Neoagent.Error?, Neoagent.SandboxDecisionMetadata?
---@async
function Escalation:_choose_prefix(candidate, ctx)
  local value = candidate.command
  local reason
  for _ = 1, 16 do
    local decision, decision_err, metadata = self:_decision(self:_prefix_dialog(value, reason), ctx)
    if not decision or metadata and metadata.presenter_unavailable then
      return nil, decision_err, metadata
    end
    if decision == "cancel_prefix" then
      return false
    end
    local input = metadata and metadata.input
    local rule, validation_err = self:_validate_prefix(input, candidate)
    if rule then
      return rule
    end
    reason = validation_err
    value = type(input) == "string" and input or candidate.command
  end
  return nil, util.error("sandbox_approval", "Too many invalid command prefixes")
end

---@param ctx Neoagent.ToolContext<C>
function Escalation:_sync_session(ctx)
  local context = ctx and ctx.context
  local key = type(context) == "table" and context.session_id or self._default_session
  if self._session_key ~= key then
    self._session_key = key
    self._rules = {}
  end
end

---@param rule Neoagent.SandboxPrefixRule
function Escalation:_remember(rule)
  local retained = {}
  for _, existing in ipairs(self._rules) do
    if existing.shell ~= rule.shell or not starts_with(existing.tokens, rule.tokens) then
      retained[#retained + 1] = existing
    end
  end
  retained[#retained + 1] = rule
  self._rules = retained
end

---@param tool Neoagent.Tool<C>
---@param arguments Neoagent.JsonObject
---@param ctx Neoagent.ToolContext<C>
---@return boolean
function Escalation:_matches(tool, arguments, ctx)
  local candidate = self:_candidate(tool, arguments, ctx)
  if not candidate then
    return false
  end
  local tokens = parse_command(candidate.command, candidate.kind)
  if not tokens then
    return false
  end
  for _, rule in ipairs(self._rules) do
    if rule.shell == candidate.shell and starts_with(tokens, rule.tokens) then
      return true
    end
  end
  return false
end

---@param executors {restricted: Neoagent.ToolExecutor<C>, elevated: Neoagent.ToolExecutor<C>}
---@return Neoagent.ToolExecutor<C>
function Escalation:wrap(executors)
  assert(
    type(executors) == "table" and type(executors.restricted) == "function" and type(executors.elevated) == "function",
    "sandbox escalation requires restricted and elevated executors"
  )
  ---@async
  ---@param tool Neoagent.Tool<C>
  ---@param arguments Neoagent.JsonObject
  ---@param ctx Neoagent.ToolContext<C>
  ---@return Neoagent.ToolResult
  local function execute(tool, arguments, ctx)
    local stripped, strip_err, escalation = self:_extract(tool, arguments)
    if not stripped then
      return result.sandbox("Malformed sandbox options: " .. strip_err, {
        invalid_escalation = true,
      })
    end
    self:_sync_session(ctx)
    ctx = invocations.context(ctx, invocations.prepare(tool, stripped, ctx))
    ---@type Neoagent.ToolResult?
    local preflight_result
    if not escalation then
      preflight_result = executors.restricted(tool, stripped, ctx)
      local evidence = preflight_result.execution and preflight_result.execution.sandbox
      if not evidence or type(evidence) ~= "table" or evidence.preflight_denied ~= true then
        return assert(preflight_result)
      end
      escalation = { justification = "The workspace policy denied this operation before execution." }
    end
    local decision, approval_err, decision_metadata
    if self:_matches(tool, stripped, ctx) then
      decision = "approve"
    else
      local resolved = false
      for _ = 1, 16 do
        local request, candidate = self:_request(tool, stripped, escalation, ctx)
        decision, approval_err, decision_metadata = self:_decision(request, ctx)
        if decision ~= "approve_prefix" then
          resolved = true
          break
        end
        local rule
        rule, approval_err, decision_metadata = self:_choose_prefix((assert(candidate)), ctx)
        if rule then
          self:_remember(rule)
          decision = "approve"
          resolved = true
          break
        elseif rule == nil then
          decision = nil
          resolved = true
          break
        end
      end
      if not resolved then
        decision = nil
        approval_err = util.error("sandbox_approval", "Too many cancelled command-prefix approvals")
      end
    end
    if not decision or decision_metadata and decision_metadata.presenter_unavailable then
      local message = approval_err and approval_err.message or "Dialog presenter became unavailable"
      if preflight_result then
        return result.append(preflight_result, message .. "\nUnrestricted execution did not occur.", {
          approval_unavailable = true,
        })
      end
      return result.sandbox(message .. "\nUnrestricted execution did not occur.", {
        approval_unavailable = true,
      })
    elseif decision == "deny_all" then
      local dialogs = (ctx --[[@as Neoagent.DialogToolContext<C>]]).dialog
      local called, selected, select_err =
        pcall(dialogs.choose_pending, dialogs, "deny", "denied together with another sandbox request")
      if not called then
        select_err = util.normalize_error(selected, "sandbox_approval")
        selected = nil
      end
      if not selected then
        return result.sandbox(assert(select_err).message .. "\nUnrestricted execution did not occur.", {
          approval_unavailable = true,
        })
      end
      decision = "deny"
    end
    if decision == "deny" then
      return result.sandbox(result.USER_DENIED, {
        denied_by_user = true,
        elevated = false,
        tool = tool.name,
      })
    end
    local ok, value = pcall(executors.elevated, tool, stripped, ctx)
    if not ok then
      error(value, 0)
    end
    return value
  end
  return execute
end

---@param next_execute_tool Neoagent.ToolExecutor<C>
---@return Neoagent.ToolExecutor<C>
function Escalation:bypass(next_execute_tool)
  assert(type(next_execute_tool) == "function", "sandbox bypass executor must be a function")
  ---@async
  return function(tool, arguments, ctx)
    local stripped, strip_err = self:_extract(tool, arguments)
    if not stripped then
      return result.sandbox("Malformed sandbox options: " .. strip_err, {
        invalid_escalation = true,
      })
    end
    return next_execute_tool(tool, stripped, ctx)
  end
end

---@generic C
---@param opts? Neoagent.SandboxEscalationOptions<C>
---@return Neoagent.SandboxEscalation<C>
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "sandbox escalation options must be a table")
  return setmetatable({
    _summarize = opts.summarize or summaries.for_tool,
    _rules = {},
    _default_session = {},
  }, Escalation)
end

return M
