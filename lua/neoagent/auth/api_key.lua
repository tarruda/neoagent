local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

local function await_prompt(interaction, prompt)
  return async.await(function(done)
    return interaction.prompt(prompt, done)
  end)
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.name) == "string" and opts.name ~= "", "API key method name is required")
  assert(opts.prompt == nil or (type(opts.prompt) == "string" and opts.prompt ~= ""),
    "API key prompt must be a non-empty string")
  assert(opts.request_opts == nil or type(opts.request_opts) == "function",
    "API key request_opts must be a function")

  return {
    type = "api_key",
    name = opts.name,
    login = function(interaction)
      return async.run(function()
        local key = await_prompt(interaction, {
          type = "secret",
          message = opts.prompt or ("Enter " .. opts.name .. ":"),
        })
        if type(key) ~= "string" or util.trim(key) == "" then
          error(util.error("auth", "API key is required"), 0)
        end
        return { ok = true, credential = { type = "api_key", key = util.trim(key) } }
      end, { error_kind = "auth" })
    end,
    request_opts = function(credential)
      if opts.request_opts then return opts.request_opts(credential) end
      return { headers = { Authorization = "Bearer " .. credential.key } }
    end,
  }
end

return M
