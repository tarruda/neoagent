local async = require("neoagent.async")

---@class Neoagent.TestByteResponse
---@field chunks? string[]
---@field body? string
---@field error? Neoagent.Error
---@field status? number
---@field headers? table<string, string>

---@class Neoagent.TestByteBackend: Neoagent.ByteBackend
---@field requests Neoagent.HttpRequest[]
---@field fetch_requests Neoagent.HttpRequest[]
---@field responses Neoagent.TestByteResponse[]
---@field fetches Neoagent.TestByteResponse[]

local M = {}

---@param responses? Neoagent.TestByteResponse[]
---@return Neoagent.TestByteBackend
function M.new(responses)
  ---@type Neoagent.TestByteBackend
  local fake = {
    requests = {},
    fetch_requests = {},
    responses = responses or {},
    fetches = {},
  }
  ---@param opts Neoagent.ByteStreamOptions
  ---@return Neoagent.Run<Neoagent.ByteStreamResult, nil>
  function fake.request(opts)
    fake.requests[#fake.requests + 1] = opts.request
    local response = table.remove(fake.responses, 1) or {}
    return async.run(function()
      for _, chunk in ipairs(response.chunks or {}) do
        if opts.on_chunk then opts.on_chunk(chunk) end
      end
      if response.error then
        return { ok = false, error = response.error }
      end
      return { ok = true, response = { status = response.status or 200, headers = response.headers or {} } }
    end)
  end
  ---@param opts Neoagent.ByteFetchOptions
  ---@return Neoagent.Run<Neoagent.ByteFetchResult, nil>
  function fake.fetch(opts)
    fake.fetch_requests[#fake.fetch_requests + 1] = opts.request
    local response = table.remove(fake.fetches, 1) or {}
    return async.run(function()
      if response.error then
        return { ok = false, error = response.error }
      end
      return {
        ok = true,
        status = response.status or 200,
        body = response.body or "",
        headers = response.headers or {},
      }
    end)
  end
  return fake
end

return M
