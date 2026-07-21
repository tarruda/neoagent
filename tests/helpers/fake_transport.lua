local async = require("neoagent.async")

local M = {}

function M.new(responses)
  local fake = { requests = {}, responses = responses or {} }
  function fake.request(opts)
    fake.requests[#fake.requests + 1] = opts.request
    local response = table.remove(fake.responses, 1) or {}
    return async.run(function()
      for _, chunk in ipairs(response.chunks or {}) do
        opts.on_chunk(chunk)
      end
      if response.error then
        return { ok = false, error = response.error }
      end
      return { ok = true, response = { code = 0 } }
    end)
  end
  return fake
end

return M
