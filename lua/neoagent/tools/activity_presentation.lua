---@class Neoagent.ToolActivityPresentation
---@field kind "activity"
---@field operation "read"|"write"|"edit"|"search"|"command"
---@field ongoing string
---@field complete string
---@field subject string
---@field command? string

local M = {}

---@param value string
---@return string
local function single_line(value)
  return (value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n"))
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.JsonObject
local function arguments(opts)
  return type(opts) == "table" and type(opts.arguments) == "table" and opts.arguments or {}
end

---@param values Neoagent.JsonObject
---@param name string
---@param fallback string
---@return string
local function string_argument(values, name, fallback)
  return type(values[name]) == "string" and values[name] or fallback
end

---@param opts? Neoagent.ToolPresentationOptions
---@param operation "read"|"write"|"edit"|"search"|"command"
---@param ongoing string
---@param complete string
---@param value string
---@param command? boolean
---@return Neoagent.ToolActivityPresentation?
local function activity(opts, operation, ongoing, complete, value, command)
  if type(opts) ~= "table" then
    return nil
  end
  return {
    kind = "activity",
    ongoing = ongoing,
    complete = complete,
    subject = single_line(value),
    operation = operation,
    command = command and value or nil,
  }
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.ToolActivityPresentation?
function M.read(opts)
  local values = arguments(opts)
  return activity(opts, "read", "Reading", "Read", string_argument(values, "path", "…"))
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.ToolActivityPresentation?
function M.write(opts)
  local values = arguments(opts)
  return activity(opts, "write", "Writing", "Written", string_argument(values, "path", "…"))
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.ToolActivityPresentation?
function M.edit(opts)
  local values = arguments(opts)
  return activity(opts, "edit", "Editing", "Edited", string_argument(values, "path", "…"))
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.ToolActivityPresentation?
function M.grep(opts)
  local values = arguments(opts)
  local value = string_argument(values, "pattern", "…") .. " in " .. string_argument(values, "path", ".")
  if type(values.glob) == "string" then
    value = value .. " (" .. values.glob .. ")"
  end
  return activity(opts, "search", "Searching", "Searched", value)
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.ToolActivityPresentation?
function M.find(opts)
  local values = arguments(opts)
  local value = string_argument(values, "pattern", "…") .. " in " .. string_argument(values, "path", ".")
  return activity(opts, "search", "Finding", "Found", value)
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.ToolActivityPresentation?
function M.shell(opts)
  local values = arguments(opts)
  local command = string_argument(values, "command", "…")
  return activity(opts, "command", "Running", "Ran", command, true)
end

return M
