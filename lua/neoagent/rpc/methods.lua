local identities = require("neoagent.tools.identities")

local M = {}

---@class Neoagent.ToolRpcMethod
---@field name string
---@field token table
---@field execute async fun(payload: unknown, call: Neoagent.ToolOperationCall, options: Neoagent.ToolDependencyOverrides): Neoagent.ToolResult

-- Each fixed adapter keeps the concrete request and dependency types together.
---@type table<string, Neoagent.ToolRpcMethod>
M.by_name = {
  read_file = {
    name = "read_file",
    token = identities.read_file,
    ---@async
    execute = function(payload, call, options)
      local read_file = require("neoagent.tools.read_file")
      return read_file.run(read_file.validate_request(payload), call, read_file._dependencies(options))
    end,
  },
  write_file = {
    name = "write_file",
    token = identities.write_file,
    ---@async
    execute = function(payload, call, options)
      local write_file = require("neoagent.tools.write_file")
      return write_file.run(write_file.validate_request(payload), call, write_file._dependencies(options))
    end,
  },
  edit_file = {
    name = "edit_file",
    token = identities.edit_file,
    ---@async
    execute = function(payload, call, options)
      local edit_file = require("neoagent.tools.edit_file")
      return edit_file.run(edit_file.validate_request(payload), call, edit_file._dependencies(options))
    end,
  },
  shell = {
    name = "shell",
    token = identities.shell,
    ---@async
    execute = function(payload, call, options)
      local shell = require("neoagent.tools.shell")
      return shell.run(shell.validate_request(payload), call, shell._dependencies(options))
    end,
  },
  grep = {
    name = "grep",
    token = identities.grep,
    ---@async
    execute = function(payload, call, options)
      local grep = require("neoagent.tools.grep")
      return grep.run(grep.validate_request(payload), call, grep._dependencies(options))
    end,
  },
  find = {
    name = "find",
    token = identities.find,
    ---@async
    execute = function(payload, call, options)
      local find = require("neoagent.tools.find")
      return find.run(find.validate_request(payload), call, find._dependencies(options))
    end,
  },
}

---@type table<table, Neoagent.ToolRpcMethod>
M.by_token = {}
---@type table<string, string>
M.names = {}
for name, descriptor in pairs(M.by_name) do
  M.by_token[descriptor.token] = descriptor
  M.names[name] = name
end

return M
