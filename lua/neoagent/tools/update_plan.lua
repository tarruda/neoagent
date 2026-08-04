local util = require("neoagent.util")

local statuses = {
  pending = true,
  in_progress = true,
  completed = true,
}

local function validate(arguments)
  if type(arguments) ~= "table"
      or next(arguments) ~= nil and util.is_list(arguments) then
    error("update_plan arguments must be an object")
  end
  for key in pairs(arguments) do
    if key ~= "explanation" and key ~= "plan" then
      error("unsupported update_plan argument: " .. tostring(key))
    end
  end
  if arguments.explanation ~= nil and arguments.explanation ~= vim.NIL
      and type(arguments.explanation) ~= "string" then
    error("explanation must be a string")
  end
  if not util.is_list(arguments.plan) then
    error("plan must be a list")
  end
  for index, item in ipairs(arguments.plan) do
    if type(item) ~= "table"
        or next(item) ~= nil and util.is_list(item) then
      error("plan item " .. index .. " must be an object")
    end
    for key in pairs(item) do
      if key ~= "step" and key ~= "status" then
        error("unsupported plan item " .. index .. " field: " .. tostring(key))
      end
    end
    if type(item.step) ~= "string" then
      error("plan item " .. index .. " step must be a string")
    end
    if not statuses[item.status] then
      error("plan item " .. index
        .. " status must be pending, in_progress, or completed")
    end
  end
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

local function wrap_text(text, available)
  local result = {}
  available = math.max(1, available)
  for _, source in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local line = ""
    for word in source:gmatch("%S+") do
      local candidate = line == "" and word or line .. " " .. word
      if line ~= "" and vim.fn.strdisplaywidth(candidate) > available then
        result[#result + 1] = line
        line = word
      else
        line = candidate
      end
    end
    result[#result + 1] = line
  end
  return result
end

local function presentation(opts)
  if type(opts) ~= "table" or opts.state ~= "success" then return nil end
  local result = opts.result
  local details = result and type(result.details) == "table"
      and result.details.plan ~= nil and result.details or nil
  local arguments = accepted(details or opts.arguments)
  if not arguments then return nil end

  local lines = { {
    { text = " • ", style = "muted" },
    { text = "Updated Plan", style = "bold" },
  } }
  local body = {}
  local body_width = math.max(1, (opts.width or 80) - 4)
  local explanation = type(arguments.explanation) == "string"
      and util.trim(arguments.explanation) or ""
  if explanation ~= "" then
    for _, line in ipairs(wrap_text(explanation, body_width)) do
      body[#body + 1] = { text = line, style = { "muted", "italic" } }
    end
  end
  if #arguments.plan == 0 then
    body[#body + 1] = {
      text = "(no steps provided)",
      style = { "muted", "italic" },
    }
  else
    for _, item in ipairs(arguments.plan) do
      local marker = item.status == "completed" and "✔ " or "□ "
      local style = item.status == "completed" and { "muted", "strike" }
        or item.status == "in_progress" and { "accent", "bold" }
        or "muted"
      for index, line in ipairs(wrap_text(item.step, body_width - 2)) do
        body[#body + 1] = {
          text = (index == 1 and marker or "  ") .. line,
          style = style,
        }
      end
    end
  end
  for index, item in ipairs(body) do
    lines[#lines + 1] = {
      { text = index == 1 and "   └ " or "     ", style = "muted" },
      { text = item.text, style = item.style },
    }
  end
  return { card = false, lines = lines }
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
    input_schema = {
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
    },
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
