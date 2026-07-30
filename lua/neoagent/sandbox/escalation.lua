local result = require("neoagent.sandbox.result")
local summaries = require("neoagent.sandbox.approval_summary")
local util = require("neoagent.util")

local M = {}
local Escalation = {}
Escalation.__index = Escalation

local function is_object(value)
  return type(value) == "table" and (next(value) == nil or not util.is_list(value))
end

local function copy_context(ctx)
  local copied = {}
  for key, value in pairs(ctx or {}) do copied[key] = value end
  return copied
end

local function bounded(value, limit)
  value = tostring(value or "")
  value = value:gsub("[%z\1-\31\127]", function(character)
    return string.format("\\x%02X", character:byte())
  end)
  if #value > limit then value = value:sub(1, limit - 3) .. "..." end
  return value
end

local function workspace_cwd(ctx)
  local context = ctx and ctx.context
  local workspace = context and context.workspace or context
  return type(workspace) == "table" and workspace.cwd or nil
end

local function escalation_properties()
  return {
    require_escalation = {
      type = "boolean",
      enum = { true },
      description = "Request one unrestricted retry after sandbox restrictions block this call.",
    },
    escalation_justification = {
      type = "string",
      description = "Explain why the task cannot be completed inside the sandbox.",
    },
  }
end

function Escalation:_transform(tool)
  assert(type(tool) == "table", "tool must be a table")
  assert(type(tool.name) == "string" and tool.name ~= "",
    "tool.name is required")
  assert(type(tool.input_schema) == "table",
    "tool.input_schema is required for " .. tool.name)
  assert(tool.input_schema.type == "object",
    "tool input_schema must be object-valued for " .. tool.name)
  local copied = util.copy(tool)
  copied.input_schema.properties = copied.input_schema.properties or {}
  if not is_object(copied.input_schema.properties) then
    error("tool input_schema.properties must be an object for "
      .. tool.name, 0)
  end
  local options = copied.input_schema.properties.options
  local added = options == nil
  if added then
    options = {
      type = "object",
      properties = {},
      additionalProperties = false,
    }
    copied.input_schema.properties.options = options
  elseif type(options) ~= "table" or options.type ~= "object" then
    error("tool options schema must be object-valued for " .. tool.name, 0)
  end
  options.properties = options.properties or {}
  if not is_object(options.properties) then
    error("tool options properties must be an object for "
      .. tool.name, 0)
  end
  for name, schema in pairs(escalation_properties()) do
    if options.properties[name] ~= nil then
      error("tool options schema reserves " .. name .. " for sandbox escalation in "
        .. tool.name, 0)
    end
    options.properties[name] = schema
  end
  copied._neoagent_sandbox_options_added = added
  return copied
end

function Escalation:tools(tools)
  assert(type(tools) == "table" and util.is_list(tools),
    "sandbox tools must be a list")
  local copied = {}
  for index, tool in ipairs(tools) do copied[index] = self:_transform(tool) end
  return copied
end

function Escalation:_extract(tool, arguments)
  if not is_object(arguments) then
    return nil, "tool arguments must be an object"
  end
  local copied = util.copy(arguments)
  local options = copied.options
  if options == nil then return copied end
  if not is_object(options) then return nil, "options must be an object" end
  local requested = options.require_escalation
  local justification = options.escalation_justification
  options.require_escalation = nil
  options.escalation_justification = nil
  if tool._neoagent_sandbox_options_added and next(options) == nil then
    copied.options = nil
  end
  if requested == nil and justification == nil then return copied end
  if requested ~= true then
    return nil, "options.require_escalation must be exactly true"
  end
  if type(justification) ~= "string" or util.trim(justification) == ""
      or #justification > 1000 then
    return nil, "options.escalation_justification must be a non-empty string of at most 1000 bytes"
  end
  return copied, nil, { justification = justification }
end

function Escalation:_request(tool, arguments, escalation, ctx)
  local controller = ctx and ctx.context and ctx.context.controller or "Neoagent"
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
  body[#body + 1] =
    "Agent justification: " .. bounded(escalation.justification, 1000)
  body[#body + 1] = ""
  body[#body + 1] = bounded(summary, 2000)
  body[#body + 1] = ""
  body[#body + 1] =
    "This grants the tool your full user filesystem, process, environment, and network authority for this call."
  return {
    placement = "transcript",
    title = "Approval required · " .. bounded(controller, 128),
    body = table.concat(body, "\n"),
    actions = {
      { id = "approve", label = "approve", key = "y" },
      { id = "deny", label = "deny", key = "n" },
      { id = "deny_all", label = "deny all pending", key = "N" },
    },
  }
end

local function await_decision(value)
  local metadata = {}
  if type(value) == "table" and type(value.await) == "function" then
    if value:is_done() then
      value = value:result()
    elseif require("neoagent.async").current() then
      value = value:await()
    else
      value:cancel()
      return nil, util.error("sandbox_approval",
        "Approval requires a running neoagent.async coroutine")
    end
  end
  if type(value) == "table" and value.ok ~= nil then
    if not value.ok then
      metadata.presenter_unavailable = value.presenter_unavailable == true
      return nil, value.error
        or util.error("sandbox_approval", "Dialog failed"), metadata
    end
    value = value.action
  end
  if value == true then value = "approve" end
  if value == false then value = "deny" end
  if value ~= "approve" and value ~= "deny"
      and value ~= "deny_all" then
    return nil, util.error("sandbox_approval",
      "Dialog returned an invalid action"), metadata
  end
  return value, nil, metadata
end

function Escalation:_decision(request, ctx)
  local dialogs = ctx and ctx.dialog
  if type(dialogs) ~= "table"
      or type(dialogs.show) ~= "function"
      or type(dialogs.choose_pending) ~= "function" then
    return nil, util.error("sandbox_approval",
      "Dialog capability is unavailable")
  end
  local ok, value = pcall(dialogs.show, dialogs, util.copy(request))
  if not ok then
    return nil, util.normalize_error(value, "sandbox_approval")
  end
  return await_decision(value)
end

function Escalation:_elevated_context(ctx)
  local elevated = copy_context(ctx)
  local active = true
  local function require_active()
    if not active then
      error(util.error("sandbox_approval",
        "Elevated capability has expired"), 0)
    end
  end
  local filesystem = {}
  for _, name in ipairs({ "create_temp", "read", "mkdirp", "write_all" }) do
    local method = name
    filesystem[method] = function(...)
      require_active()
      return self._fs[method](...)
    end
  end
  elevated.fs = filesystem
  elevated.process = function(...)
    require_active()
    return self._process(...)
  end
  return elevated, function() active = false end
end

function Escalation:wrap(executors)
  assert(type(executors) == "table"
    and type(executors.restricted) == "function"
    and type(executors.elevated) == "function",
    "sandbox escalation requires restricted and elevated executors")
  return function(tool, arguments, ctx)
    local stripped, strip_err, escalation = self:_extract(tool, arguments)
    if not stripped then
      return result.sandbox("Malformed sandbox options: " .. strip_err, {
        invalid_escalation = true,
      })
    end
    if not escalation then
      return executors.restricted(tool, stripped, ctx)
    end
    local request = self:_request(tool, stripped, escalation, ctx)
    local decision, approval_err, decision_metadata =
      self:_decision(request, ctx)
    if not decision
        or decision_metadata and decision_metadata.presenter_unavailable then
      local message = approval_err and approval_err.message
        or "Dialog presenter became unavailable"
      return result.sandbox(message
        .. "\nUnrestricted execution did not occur.", {
        approval_unavailable = true,
      })
    elseif decision == "deny_all" then
      local called, selected, select_err = pcall(
        ctx.dialog.choose_pending, ctx.dialog,
        "deny", "denied together with another sandbox request")
      if not called then
        select_err = util.normalize_error(selected, "sandbox_approval")
        selected = nil
      end
      if not selected then
        return result.sandbox(select_err.message
          .. "\nUnrestricted execution did not occur.", {
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
    local elevated, revoke = self:_elevated_context(ctx)
    local executed = { pcall(executors.elevated,
      tool, stripped, elevated) }
    revoke()
    local ok = table.remove(executed, 1)
    if not ok then error(executed[1], 0) end
    return unpack(executed)
  end
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "sandbox escalation options must be a table")
  local fs = opts.fs or require("neoagent.fs")
  local process = opts.process or require("neoagent.process").run
  return setmetatable({
    _fs = fs,
    _process = process,
    _summarize = opts.summarize or summaries.for_tool,
  }, Escalation)
end

return M
