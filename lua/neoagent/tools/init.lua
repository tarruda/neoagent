local M = {}

---@class Neoagent.ToolPresetOptions
---@field shell_timeout? number|false
---@field shell? string Explicit command interpreter for the Pi preset.

---@alias Neoagent.BundledToolName "read_file"|"write_file"|"edit_file"|"shell"|"grep"|"find"|"read_agent_documentation"|"update_plan"|"exec_command"|"write_stdin"

---@type table<Neoagent.BundledToolName, fun(options: Neoagent.ToolPresetOptions): Neoagent.Tool<unknown>>
local constructors = {
  exec_command = function()
    return require("neoagent.tools.process").exec_command()
  end,
  write_stdin = function()
    return require("neoagent.tools.process").write_stdin()
  end,
  read_file = function()
    return require("neoagent.tools.read_file").new()
  end,
  write_file = function()
    return require("neoagent.tools.write_file").new()
  end,
  edit_file = function()
    return require("neoagent.tools.edit_file").new()
  end,
  shell = function(options)
    return require("neoagent.tools.shell").new({ default_timeout = options.shell_timeout })
  end,
  grep = function()
    return require("neoagent.tools.grep").new()
  end,
  find = function()
    return require("neoagent.tools.find").new()
  end,
  read_agent_documentation = function()
    return require("neoagent.tools.read_agent_documentation").new()
  end,
  update_plan = function()
    return require("neoagent.tools.update_plan").new()
  end,
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
  return require("neoagent.tools.pi").coding(options)
end

---@return Neoagent.Tool<unknown>[]
function M.codex()
  return require("neoagent.tools.codex").coding()
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
    "read_file",
    "write_file",
    "edit_file",
    "shell",
    "grep",
    "find",
    "read_agent_documentation",
    "update_plan",
    "exec_command",
    "write_stdin",
  }, options)
end

return M
