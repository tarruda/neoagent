local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.ApiKeyOptions
---@field name string
---@field prompt? string
---@field request_opts? fun(credential: Neoagent.ApiKeyCredential, scope?: string): Neoagent.RequestOverride

---@async
---@param interaction Neoagent.LoginInteraction
---@param prompt Neoagent.LoginPrompt
---@return string?
local function await_prompt(interaction, prompt)
  return async.await(
  ---@param done Neoagent.AwaitCallbacks<string?>
  function(done)
    return interaction.prompt(prompt, done)
  end)
end

---@param opts Neoagent.ApiKeyOptions
---@return Neoagent.AuthMethod<Neoagent.ApiKeyCredential>
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
    ---@param interaction Neoagent.LoginInteraction
    login = function(interaction)
      return async.run(
      ---@return Neoagent.CredentialSuccess<Neoagent.ApiKeyCredential>
      function()
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
    request_opts = function(credential, scope)
      if opts.request_opts then return opts.request_opts(credential, scope) end
      return { headers = { Authorization = "Bearer " .. credential.key } }
    end,
    cache_identity = function(credential)
      return credential.key
    end,
  }
end

return M
