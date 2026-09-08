local async = require("neoagent.async")

---@param headers? table<string, string>
---@return fun(scope?: string): Neoagent.Run<Neoagent.AuthResolution, nil>
local function auth(headers)
  return function()
    return async.run(function()
      if not headers then return { ok = true, configured = false } end
      return {
        ok = true,
        configured = true,
        method = "test",
        credential_type = "api_key",
        request_opts = { headers = headers },
      }
    end)
  end
end

return auth
