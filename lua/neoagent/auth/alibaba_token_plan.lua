local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

local function plan_key(value)
  value = type(value) == "string" and util.trim(value) or ""
  if value == "" then
    return nil, util.error("auth", "API key is required")
  end
  if not vim.startswith(value, "sk-sp-") then
    return nil, util.error("auth",
      "Alibaba Cloud Token Plan API keys must start with sk-sp-")
  end
  return value
end

function M.new()
  return {
    type = "api_key",
    name = "Alibaba Cloud Token Plan API key",
    login_label = "Login",
    logout_label = "Logout",
    login = function(interaction)
      return async.run(function()
        local key = async.await(function(done)
          return interaction.prompt({
            type = "secret",
            message = "Enter Alibaba Cloud Token Plan API key:",
          }, done)
        end)
        local selected, err = plan_key(key)
        if not selected then error(err, 0) end
        return { ok = true, credential = {
          type = "api_key",
          key = selected,
        } }
      end, { error_kind = "auth" })
    end,
    request_opts = function(credential)
      local key, err = plan_key(credential.key)
      if not key then error(err, 0) end
      return { headers = { Authorization = "Bearer " .. key } }
    end,
    cache_identity = function(credential)
      return credential.key
    end,
    validate_credential = function(credential)
      return plan_key(credential.key) ~= nil
    end,
  }
end

return M
