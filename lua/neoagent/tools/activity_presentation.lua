local M = {}

local function active(state)
  return state ~= "success" and state ~= "error"
end

local function single_line(value)
  return value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
end

local function presentation(verb, value)
  return {
    default = true,
    title = {
      { text = verb, style = "bold" },
      { text = " " .. single_line(value) },
    },
  }
end

local function arguments(opts)
  return type(opts) == "table" and type(opts.arguments) == "table"
      and opts.arguments or {}
end

local function string_argument(values, name, fallback)
  return type(values[name]) == "string" and values[name] or fallback
end

local function activity(opts, ongoing, complete, value, compact)
  if type(opts) ~= "table" or opts.style ~= "codex" then return nil end
  local result = presentation(
    active(opts.state) and ongoing or complete, value)
  result.default = compact ~= true or opts.full == true
  result.status = true
  return result
end

function M.read(opts)
  local values = arguments(opts)
  return activity(opts, "Reading", "Read",
    string_argument(values, "path", "…"), true)
end

function M.write(opts)
  local values = arguments(opts)
  return activity(opts, "Writing", "Written",
    string_argument(values, "path", "…"))
end

function M.edit(opts)
  local values = arguments(opts)
  return activity(opts, "Editing", "Edited",
    string_argument(values, "path", "…"))
end

function M.grep(opts)
  local values = arguments(opts)
  local value = string_argument(values, "pattern", "…")
    .. " in " .. string_argument(values, "path", ".")
  if type(values.glob) == "string" then
    value = value .. " (" .. values.glob .. ")"
  end
  return activity(opts, "Searching", "Searched", value, true)
end

function M.find(opts)
  local values = arguments(opts)
  local value = string_argument(values, "pattern", "…")
    .. " in " .. string_argument(values, "path", ".")
  return activity(opts, "Finding", "Found", value, true)
end

function M.shell(opts)
  local values = arguments(opts)
  local command = string_argument(values, "command", "…")
  local result = activity(opts, "Running", "Ran", command, true)
  if result and opts.full ~= true then
    result.title = { result.title[1] }
    result.command = command
  end
  return result
end

return M
