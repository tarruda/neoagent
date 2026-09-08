local async = require("neoagent.async")
local util = require("neoagent.util")

---@class Neoagent.TestModelResponse
---@field events? Neoagent.ModelEvent[]
---@field result Neoagent.ModelResult

local M = {}

---@param responses? Neoagent.TestModelResponse[]
---@return Neoagent.TestModel
function M.new(responses)
  ---@class Neoagent.TestModel: Neoagent.Model
  ---@field requests Neoagent.StreamOptions[]
  ---@field responses Neoagent.TestModelResponse[]
  local model = {
    api = "fake",
    provider = "fake",
    id = "fake",
    input = { "text" },
    requests = {},
    responses = responses or {},
  }
  ---@param opts Neoagent.StreamOptions
  ---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
  function model:stream(opts)
    self.requests[#self.requests + 1] = util.copy(opts)
    local response = table.remove(self.responses, 1)
    assert(response, "fake model has no scripted response")
    return async.run(function(run)
      for _, event in ipairs(response.events or {}) do
        run:emit(util.copy(event))
      end
      return util.copy(response.result)
    end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
  end
  return model
end

---@param content Neoagent.AssistantBlock[]
---@param stop_reason? string
---@return Neoagent.ModelSuccess
function M.assistant(content, stop_reason)
  ---@type Neoagent.AssistantMessage
  local message = {
    role = "assistant",
    content = content,
    api = "fake",
    provider = "fake",
    model = "fake",
    usage = {
      input = 0, output = 0, cacheRead = 0, cacheWrite = 0, totalTokens = 0,
      cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 },
    },
    stopReason = stop_reason or "stop",
    timestamp = 1,
  }
  return { ok = true, message = message, text = util.text_content(content) }
end

return M
