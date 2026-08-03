local M = {}

local modules = {
  read_file = "neoagent.tools.read_file",
  write_file = "neoagent.tools.write_file",
  edit_file = "neoagent.tools.edit_file",
  shell = "neoagent.tools.shell",
  grep = "neoagent.tools.grep",
  find = "neoagent.tools.find",
  read_agent_documentation = "neoagent.tools.read_agent_documentation",
}

local function tools(names, options)
  options = options or {}
  assert(type(options) == "table", "tool options must be a table")
  local result = {}
  for _, name in ipairs(names) do
    local module = require(modules[name])
    result[#result + 1] = name == "shell"
        and module.new({ default_timeout = options.shell_timeout })
      or module.new()
  end
  return result
end

function M.coding(options)
  return tools({
    "read_file", "write_file", "edit_file", "shell",
    "read_agent_documentation",
  }, options)
end

function M.read_only()
  return tools({ "read_file", "grep", "find" })
end

function M.all(options)
  return tools({
    "read_file", "write_file", "edit_file", "shell", "grep", "find",
    "read_agent_documentation",
  }, options)
end

return M
