local codec = require("neoagent.rpc.codec")
local common = require("neoagent.tools.common")

local M = {}

---@class Neoagent.TestToolRpcConnection: Neoagent.RpcConnection
---@field open_tool async fun(self: Neoagent.TestToolRpcConnection, call: Neoagent.ToolOperationCall)
---@field read_file async fun(self: Neoagent.TestToolRpcConnection, request: Neoagent.ReadFileRequest, call: Neoagent.ToolOperationCall): Neoagent.ToolResult
---@field write_file async fun(self: Neoagent.TestToolRpcConnection, request: Neoagent.WriteFileRequest, call: Neoagent.ToolOperationCall): Neoagent.ToolResult
---@field edit_file async fun(self: Neoagent.TestToolRpcConnection, request: Neoagent.EditFileRequest, call: Neoagent.ToolOperationCall): Neoagent.ToolResult
---@field shell async fun(self: Neoagent.TestToolRpcConnection, request: Neoagent.ShellRequest, call: Neoagent.ToolOperationCall): Neoagent.ToolResult
---@field grep async fun(self: Neoagent.TestToolRpcConnection, request: Neoagent.GrepRequest, call: Neoagent.ToolOperationCall): Neoagent.ToolResult
---@field find async fun(self: Neoagent.TestToolRpcConnection, request: Neoagent.FindRequest, call: Neoagent.ToolOperationCall): Neoagent.ToolResult

---@param opts? Neoagent.RpcConnectionOptions
---@return Neoagent.TestToolRpcConnection
function M.new(opts)
  local connection = require("neoagent.rpc.connection").new(opts)
  local raw_open = connection.open
  ---@async
  local function open_tool(self, call)
    return raw_open(self, codec.encode_context(common.validate_call(call)))
  end
  rawset(connection, "open_tool", open_tool)
  for name, method in pairs(codec.methods) do
    local selected = method
    ---@async
    local function execute(self, request, call)
      return require("neoagent.rpc.registry").invoke(
        self,
        selected,
        request,
        common.validate_call(call)
      )
    end
    rawset(connection, name, execute)
  end
  return connection --[[@as Neoagent.TestToolRpcConnection]]
end

return M
