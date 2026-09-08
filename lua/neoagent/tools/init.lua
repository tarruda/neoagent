local M = {}

---@class Neoagent.ToolPresetOptions
---@field shell_timeout? number|false

---@alias Neoagent.BundledToolName "read_file"|"write_file"|"edit_file"|"shell"|"grep"|"find"|"read_agent_documentation"|"update_plan"

---@type table<Neoagent.BundledToolName, fun(options: Neoagent.ToolPresetOptions): Neoagent.Tool<unknown>>
local constructors = {
  read_file = function() return require("neoagent.tools.read_file").new() end,
  write_file = function() return require("neoagent.tools.write_file").new() end,
  edit_file = function() return require("neoagent.tools.edit_file").new() end,
  shell = function(options)
    return require("neoagent.tools.shell").new({ default_timeout = options.shell_timeout })
  end,
  grep = function() return require("neoagent.tools.grep").new() end,
  find = function() return require("neoagent.tools.find").new() end,
  read_agent_documentation = function() return require("neoagent.tools.read_agent_documentation").new() end,
  update_plan = function() return require("neoagent.tools.update_plan").new() end,
}

---@param names Neoagent.BundledToolName[]
---@param options? Neoagent.ToolPresetOptions
---@return Neoagent.Tool<unknown>[]
local function tools(names, options)
  options = options or {}
  assert(type(options) == "table", "tool options must be a table")
  ---@type Neoagent.Tool<unknown>[]
  local result = {}
  for _, name in ipairs(names) do
    result[#result + 1] = constructors[name](options)
  end
  return result
end

---@param options? Neoagent.ToolPresetOptions
---@return Neoagent.Tool<unknown>[]
function M.coding(options)
  return tools({
    "read_file", "write_file", "edit_file", "shell",
    "read_agent_documentation",
  }, options)
end

---@return Neoagent.Tool<unknown>[]
function M.read_only()
  return tools({ "read_file", "grep", "find" })
end

---@return Neoagent.Tool<unknown>
function M.update_plan()
  return constructors.update_plan({})
end

---@param options? Neoagent.ToolPresetOptions
---@return Neoagent.Tool<unknown>[]
function M.all(options)
  return tools({
    "read_file", "write_file", "edit_file", "shell", "grep", "find",
    "read_agent_documentation", "update_plan",
  }, options)
end

return M
