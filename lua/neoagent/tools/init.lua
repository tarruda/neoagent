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

local function tools(names)
  local result = {}
  for _, name in ipairs(names) do
    result[#result + 1] = require(modules[name]).new()
  end
  return result
end

function M.coding()
  return tools({
    "read_file", "write_file", "edit_file", "shell",
    "read_agent_documentation",
  })
end

function M.read_only()
  return tools({ "read_file", "grep", "find" })
end

function M.all()
  return tools({
    "read_file", "write_file", "edit_file", "shell", "grep", "find",
    "read_agent_documentation",
  })
end

return M
