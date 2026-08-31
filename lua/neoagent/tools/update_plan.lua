local tool_schema = require("neoagent.api.tool_schema")
local util = require("neoagent.util")

local input_schema = {
  type = "object",
  properties = {
    explanation = {
      type = "string",
      description = "Optional explanation for this plan update.",
    },
    plan = {
      type = "array",
      description = "The list of steps",
      items = {
        type = "object",
        properties = {
          step = { type = "string", description = "Task step text." },
          status = {
            type = "string",
            enum = { "pending", "in_progress", "completed" },
            description = "Step status.",
          },
        },
        required = { "step", "status" },
        additionalProperties = false,
      },
    },
  },
  required = { "plan" },
  additionalProperties = false,
}

local function validate(arguments)
  local valid, message = tool_schema.validate(input_schema, arguments)
  if not valid then error(message, 0) end
end

local function accepted(arguments)
  local ok = pcall(validate, arguments)
  return ok and util.copy(arguments) or nil
end

local function session_id(ctx)
  local context = type(ctx) == "table" and (ctx.context or ctx) or nil
  return context and context.session_id or nil
end

local function latest(messages)
  local calls = {}
  local current
  for _, message in ipairs(messages or {}) do
    if message.role == "assistant" then
      for _, block in ipairs(message.content or {}) do
        if block.type == "toolCall" and block.name == "update_plan"
            and type(block.id) == "string" then
          calls[block.id] = block.arguments
        end
      end
    elseif message.role == "toolResult" and message.toolName == "update_plan"
        and message.isError ~= true then
      local details = type(message.details) == "table"
          and message.details.plan ~= nil and message.details or nil
      local value = accepted(calls[message.toolCallId] or details)
      if value then current = value end
    end
  end
  return current
end

local function presentation(opts)
  if type(opts) ~= "table" then return nil end
  if opts.state == "pending" or opts.state == "running" then
    return { kind = "plan" }
  end
  if opts.state ~= "success" then return nil end
  local result = opts.result
  local details = result and type(result.details) == "table"
      and result.details.plan ~= nil and result.details or nil
  local arguments = accepted(details or opts.arguments)
  if not arguments then return nil end

  return {
    kind = "plan",
    explanation = type(arguments.explanation) == "string"
      and arguments.explanation or nil,
    plan = util.copy(arguments.plan),
  }
end

local function new()
  local states = setmetatable({}, { __mode = "k" })
  return {
    name = "update_plan",
    description = table.concat({
      "Updates the task plan.",
      "Provide an optional explanation and a list of plan items, each with a step and status.",
      "At most one step can be in_progress at a time.",
    }, "\n"),
    input_schema = util.copy(input_schema),
    execute = function(arguments)
      validate(arguments)
      return {
        content = { { type = "text", text = "Plan updated" } },
        details = util.copy(arguments),
      }
    end,
    on_messages = function(messages, ctx)
      local id = session_id(ctx)
      if id then states[id] = latest(messages) end
    end,
    current = function(ctx)
      local id = session_id(ctx)
      return id and util.copy(states[id]) or nil
    end,
    render = presentation,
  }
end

local M = new()
M.new = new
return M
