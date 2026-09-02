local async = require("neoagent.async")
local client = require("neoagent.providers.llama.client")
local util = require("neoagent.util")

local M = {}

local DEFAULT_SERVER_URL = "http://127.0.0.1:8080"

local function await_prompt(interaction, prompt)
  return async.await(function(done)
    return interaction.prompt(prompt, done)
  end)
end

local function server_url(credential)
  local value = credential and credential.env
    and credential.env.LLAMA_BASE_URL or nil
  if type(value) == "string" and util.trim(value) ~= "" then
    return client.normalize_server_url(value)
  end
end

function M.new()
  return {
    type = "api_key",
    name = "llama.cpp server",
    login = function(interaction)
      return async.run(function()
        local entered_url = await_prompt(interaction, {
          type = "text",
          message = "llama.cpp server URL",
        })
        local selected = util.trim(entered_url or "")
        if selected == "" then
          selected = util.trim(vim.env.LLAMA_BASE_URL or DEFAULT_SERVER_URL)
        end
        selected = client.normalize_server_url(selected)
        local key = "anonymous"
        local anonymous = true
        local listed = client.new({ server_url = selected }):list():await()
        if not listed.ok then
          local err = listed.error or util.error("auth",
            "llama.cpp server check failed")
          if err.status ~= 401 and err.status ~= 403 then error(err, 0) end
          local entered_key = await_prompt(interaction, {
            type = "secret",
            message = "llama.cpp API key",
          })
          key = util.trim(entered_key or "")
          if key == "" then
            error(util.error("auth", "API key is required"), 0)
          end
          local verified = client.new({
            server_url = selected,
            api_key = key,
          }):list():await()
          if not verified.ok then error(verified.error, 0) end
          anonymous = false
        end
        return {
          ok = true,
          credential = {
            type = "api_key",
            key = key,
            env = {
              LLAMA_BASE_URL = selected,
              LLAMA_ANONYMOUS = anonymous and "1" or nil,
            },
          },
        }
      end, { error_kind = "auth" })
    end,
    request_opts = function(credential)
      local value = server_url(credential)
      local result = {
        url = value and client.inference_url(value) .. "/chat/completions" or nil,
      }
      if not (credential.env and credential.env.LLAMA_ANONYMOUS == "1") then
        result.headers = { Authorization = "Bearer " .. credential.key }
      end
      return result
    end,
    public_metadata = function(credential)
      local value = server_url(credential)
      if not value then return nil end
      return { server_url = value }
    end,
    cache_identity = function(credential)
      local value = server_url(credential) or DEFAULT_SERVER_URL
      return tostring(#value) .. ":" .. value .. ":" .. credential.key
    end,
  }
end

return M
