local backend = require("neoagent.files.http_backend")
local manager_module = require("neoagent.files.manager")
local request_module = require("neoagent.files.request")
local service_module = require("neoagent.provider_service")
local util = require("neoagent.util")
local M = {}

local image_mimes = { ["image/png"] = true, ["image/jpeg"] = true, ["image/gif"] = true, ["image/webp"] = true }

-- Responses documents this precise code. Do not infer file rejection from a
-- generic HTTP status, an arbitrary message, or an ambiguous disconnect.
---@param result Neoagent.HttpResult
---@return number?, unknown
local function rejection(result)
  local code, body
  if result.ok then
    code, body = result.status, result.body
  else
    local response = rawget(result.error, "response")
    code = type(response) == "table" and response.status or nil
    local detail = rawget(result.error, "detail")
    if type(detail) == "string" and #detail <= 65536 then
      local ok, value = pcall(vim.json.decode, detail)
      if ok then
        body = value
      end
    end
  end
  return code, body
end

---@param result Neoagent.HttpResult
---@return boolean
local function openai_rejection(result)
  local code, body = rejection(result)
  return (code == 400 or code == 404)
    and type(body) == "table"
    and type(body.error) == "table"
    and body.error.code == "image_file_not_found"
end

---@param result Neoagent.HttpResult
---@return boolean
local function anthropic_rejection(result)
  local code, body = rejection(result)
  return code == 404
    and type(body) == "table"
    and type(body.error) == "table"
    and body.error.type == "not_found_error"
    and type(body.error.message) == "string"
    and body.error.message:match("^File `[%w_-]+` not found%.$") ~= nil
end

---@param result Neoagent.HttpResult
---@return boolean
local function deepseek_missing(result)
  local code, body = rejection(result)
  return code == 400
    and type(body) == "table"
    and type(body.error) == "table"
    and body.error.code == "invalid_request_error"
    and body.error.type == "invalid_request_error"
    and body.error.message == "file_id does not exist or is not created under your account"
end

---@param headers? table<string, unknown>
---@param name string
---@return string?
---@return boolean valid
local function header(headers, name)
  local found
  for key, value in pairs(headers or {}) do
    if key:lower() == name then
      if found or type(value) ~= "string" or value == "" or value:find("[%c]") then
        return nil, false
      end
      found = value
    end
  end
  return found, true
end

---@param id string
---@param provider Neoagent.ProviderDefinition
---@param service Neoagent.ProviderService
---@param opts {transport?: Neoagent.ByteBackend, auth_type?: string, report?: fun(message: string, level: integer)}
---@return Neoagent.ProviderFiles?
function M.new(id, provider, service, opts)
  if provider.file_uploads == false then
    return nil
  end
  local codex = id == "openai-codex"
  local anthropic = id == "anthropic"
  if id ~= "openai" and id ~= "deepseek" and not codex and not anthropic then
    return nil
  end
  if provider.auth ~= nil and opts.auth_type ~= (codex and "oauth" or "api_key") then
    return nil
  end
  local base = (provider.base_url or ""):gsub("/+$", "")
  local openai = id == "openai"
  if openai and base ~= "https://api.openai.com/v1" then
    return nil
  end
  if codex and base ~= "https://chatgpt.com/backend-api" then
    return nil
  end
  if anthropic and base ~= "https://api.anthropic.com/v1" then
    return nil
  end
  if
    not openai
    and not codex
    and not anthropic
    and base ~= "https://api.deepseek.com"
    and base ~= "https://api.deepseek.com/v1"
    and base ~= "https://api.deepseek.com/anthropic/v1"
  then
    return nil
  end
  local files_url = openai and "https://api.openai.com/v1/files" or "https://api.deepseek.com/files"
  local transport = opts.transport
  if transport and transport.with_context then
    transport = transport.with_context({ provider = id, origin = "provider-files" })
  end
  local remote = codex and require("neoagent.providers.codex.files").new({ transport = transport })
    or anthropic and require("neoagent.providers.anthropic.files").new({ transport = transport })
    or backend.new({
      url = files_url,
      purpose = openai and "vision" or "user_data",
      missing = not openai and deepseek_missing or nil,
      transport = transport,
    })
  remote.optimistic = openai or anthropic
  ---@type table<string, Neoagent.FileManager>
  local managers = {}
  local retired = false
  ---@param dependencies Neoagent.StreamOptions
  ---@return Neoagent.FileManager
  local function manager_for(dependencies)
    assert(not retired, "provider file runtime is retired")
    local source = assert(dependencies.files, "attachment file reader is required")
    local cache = dependencies.file_cache
    assert(
      cache == nil
        or type(cache.read) == "function" and type(cache.publish) == "function" and cache.scope == source.identity,
      "upload cache must belong to the request's workspace"
    )
    local manager = managers[source.identity]
    if not manager then
      manager = manager_module.new({
        backend = remote,
        scope = source.identity,
        store = cache,
        acquire = function()
          return service_module.acquire_use(service)
        end,
      })
      managers[source.identity] = manager
    elseif cache and not manager.store then
      manager.store = cache
      for _, record in pairs(manager.records) do
        cache:publish(record)
      end
    end
    return manager
  end
  return {
    retire = function()
      retired = true
      for _, manager in pairs(managers) do
        manager:retire()
      end
      managers = {}
    end,
    bind = function(api, model)
      -- Resolved modalities include explicit model additions and overrides.
      if not vim.tbl_contains(model.input or {}, "image") then
        return nil
      end
      if codex then
        if api ~= "openai-codex-responses" then
          return nil
        end
        api = "openai-responses"
      end
      if openai and api ~= "openai-responses" then
        return nil
      end
      if anthropic and api ~= "anthropic-messages" then
        return nil
      end
      if api ~= "openai-responses" and api ~= "openai-completions" and api ~= "anthropic-messages" then
        return nil
      end
      local suffix = codex and "/codex/responses"
        or api == "openai-responses" and "/responses"
        or api == "openai-completions" and "/chat/completions"
        or "/messages"
      if api == "anthropic-messages" and not anthropic and base ~= "https://api.deepseek.com/anthropic/v1" then
        return nil
      end
      if api ~= "anthropic-messages" and base == "https://api.deepseek.com/anthropic/v1" then
        return nil
      end
      return request_module.new(manager_for, {
        api = api,
        max_file_bytes = anthropic and 500 * 1024 * 1024 or (openai or codex) and 512 * 1024 * 1024 or 64 * 1024 * 1024,
        max_body_bytes = anthropic and 32 * 1024 * 1024
          or not codex and (openai and 512 * 1024 * 1024 or 48 * 1024 * 1024)
          or nil,
        max_images = anthropic and model.context_window == 200000 and 100
          or not codex and (openai and 1500 or 600)
          or nil,
        max_total_bytes = not codex and not anthropic and (openai and 512 * 1024 * 1024 or 200 * 1024 * 1024) or nil,
        headers = api == "anthropic-messages" and not anthropic and function(request)
          local beta = header(request.headers, "anthropic-beta")
          local required = "files-api-2025-04-14"
          for flag in ((beta or "") .. ","):gmatch("([^,]*),") do
            if vim.trim(flag) == required then
              return {}
            end
          end
          return { ["anthropic-beta"] = beta and beta .. "," .. required or required }
        end or nil,
        rejected = openai and openai_rejection or anthropic and anthropic_rejection or nil,
        bind = function(request)
          if request.url ~= base .. suffix or not request.body or request.body.model ~= model.id then
            return nil
          end
          local authorization, valid = header(request.headers, "authorization")
          if not valid then
            return nil
          end
          local bearer = authorization and authorization:match("^Bearer (.+)$") or nil
          ---@type string?
          local key
          if api == "anthropic-messages" then
            key, valid = header(request.headers, "x-api-key")
            if not valid then
              return nil
            end
          end
          if key and bearer and key ~= bearer then
            return nil
          end
          key = key or bearer
          if not key then
            return nil
          end
          ---@type table<string, string>
          local headers = anthropic and { ["x-api-key"] = key, ["anthropic-version"] = "2023-06-01" }
            or { Authorization = "Bearer " .. key }
          if anthropic then
            local workspace
            workspace, valid = header(request.headers, "anthropic-workspace-id")
            if not valid then
              return nil
            end
            headers["anthropic-workspace-id"] = workspace
            -- One API key can access multiple provider workspaces. Files and
            -- their preparation must retain the request's selected scope.
            return { storage_scope = vim.fn.sha256(util.json_encode({ id, key, workspace or "" })), headers = headers }
          end
          if codex then
            local account
            account, valid = header(request.headers, "chatgpt-account-id")
            if not valid or not account then
              return nil
            end
            headers["chatgpt-account-id"] = account
            -- File access belongs to the selected ChatGPT account. OAuth token
            -- rotation changes the request credential, not the object namespace.
            return { storage_scope = vim.fn.sha256(util.json_encode({ id, account })), headers = headers }
          end
          local project, organization
          if openai then
            project, valid = header(request.headers, "openai-project")
            if not valid then
              return nil
            end
            organization, valid = header(request.headers, "openai-organization")
            if not valid then
              return nil
            end
          end
          if project then
            headers["OpenAI-Project"] = project
          end
          if organization then
            headers["OpenAI-Organization"] = organization
          end
          return {
            storage_scope = vim.fn.sha256(util.json_encode({ id, key, project or "", organization or "" })),
            headers = headers,
          }
        end,
        accepts = function(image)
          return image_mimes[image.mime_type] == true
        end,
      })
    end,
  }
end

return M
