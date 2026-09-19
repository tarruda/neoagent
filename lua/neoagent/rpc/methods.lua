local M = {}

---@class Neoagent.ToolRpcMethod
---@field name string
---@field token table
---@field validate_request fun(value: unknown): table
---@field run async fun(request: table, call: Neoagent.ToolOperationCall, dependencies: Neoagent.ToolDependencies): Neoagent.ToolResult

---@type Neoagent.ToolRpcMethod[]
M.list = {}

---@type table<string, Neoagent.ToolRpcMethod>
M.by_name = {}

---@type table<table, Neoagent.ToolRpcMethod>
M.by_token = {}

---@type table<string, string>
M.names = {}

---@param name string
---@param module table
local function register(name, module)
  local descriptor = {
    name = name,
    token = assert(module._implementation),
    validate_request = assert(module.validate_request),
    run = assert(module.run),
  }
  M.list[#M.list + 1] = descriptor
  M.by_name[name] = descriptor
  M.by_token[descriptor.token] = descriptor
  M.names[name] = name
end

register("read_file", require("neoagent.tools.read_file"))
register("write_file", require("neoagent.tools.write_file"))
register("edit_file", require("neoagent.tools.edit_file"))
register("shell", require("neoagent.tools.shell"))
register("grep", require("neoagent.tools.grep"))
register("find", require("neoagent.tools.find"))

return M
