local validate = require("neoagent.subprocess.validate")
local M = {}

---@class Neoagent.SubprocessCapture
---@field append fun(event: Neoagent.SubprocessOutputEvent): Neoagent.Error?
---@field result fun(): {stdout: string, stderr: string, output: string}

---@param limit false|{max_bytes: integer}
---@return Neoagent.SubprocessCapture
function M.new(limit)
  local stdout, stderr, output = {}, {}, {}
  local size = 0
  return {
    append = function(event)
      if limit == false then
        return
      end
      if size + #event.data > limit.max_bytes then
        return validate.error("output_limit", "Process output exceeded " .. limit.max_bytes .. " bytes")
      end
      size = size + #event.data
      local stream = event.stream == "stderr" and stderr or stdout
      stream[#stream + 1] = event.data
      output[#output + 1] = event.data
    end,
    result = function()
      return { stdout = table.concat(stdout), stderr = table.concat(stderr), output = table.concat(output) }
    end,
  }
end

return M
