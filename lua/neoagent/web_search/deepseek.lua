local async = require("neoagent.async")
local auth_headers = require("neoagent.providers.auth_headers")
local http = require("neoagent.providers.http")
local provider_service = require("neoagent.provider_service")
local util = require("neoagent.util")

---@class Neoagent.DeepSeekSearchOptions
---@field auth Neoagent.AuthManager
---@field runtime? Neoagent.ProviderRuntime

---@class Neoagent.DeepSeekSearchDefinition: Neoagent.WebSearchBackendDefinition
---@field create fun(options: Neoagent.DeepSeekSearchOptions): Neoagent.WebSearchBackend

---@param value unknown
---@return TypeGuard<string>
local function text(value)
  return type(value) == "string" and util.is_valid_utf8(value)
end

---@param value Neoagent.JsonValue
---@param request Neoagent.WebSearchRequest
---@return Neoagent.WebSearchEntry[]
local function results(value, request)
  assert(
    type(value) == "table"
      and type(value.results) == "table"
      and util.is_list(value.results)
      and #value.results <= request.count,
    "DeepSeek returned invalid search results"
  )
  ---@type Neoagent.WebSearchEntry[]
  local entries = {}
  for _, entry in ipairs(value.results) do
    assert(
      type(entry) == "table"
        and text(entry.title)
        and text(entry.url)
        and entry.url:match("^https?://[^/%s]+")
        and text(entry.summary)
        and text(entry.snippet)
        and text(entry.content)
        and (entry.date == nil or entry.date == vim.NIL or text(entry.date)),
      "DeepSeek returned an invalid search result"
    )
    entries[#entries + 1] = {
      title = entry.title,
      url = entry.url,
      summary = entry.summary ~= "" and entry.summary or entry.snippet,
      content = request.include_content and entry.content ~= "" and entry.content or nil,
      published_at = type(entry.date) == "string" and entry.date or nil,
    }
  end
  return entries
end

---@param options Neoagent.DeepSeekSearchOptions
---@return Neoagent.WebSearchBackend
local function create(options)
  local runtime = assert(options.runtime, "The DeepSeek provider must be configured for web search")
  local provider = runtime.definition
  local settings = http.service_options(provider.service_opts, "deepseek")
  -- Search uses the API root even when inference selects a versioned or
  -- Anthropic-compatible endpoint on the same configured provider.
  local base_url = (provider.base_url or "https://api.deepseek.com"):gsub("/+$", "")
  base_url = base_url:gsub("/v1$", ""):gsub("/anthropic$", "")
  local transport = runtime.transport
  if transport and transport.with_context then
    transport = transport.with_context({ provider = "deepseek", origin = "web-search" })
  end
  local client = http.new({
    name = "DeepSeek",
    base_url = base_url,
    transport = transport,
    timeout_ms = settings.timeout_ms or 30000,
    max_response_bytes = settings.max_response_bytes or 2 * 1024 * 1024,
    status_message = function(status)
      if status == 401 then
        return "DeepSeek web search requires a valid API key"
      elseif status == 402 then
        return "DeepSeek account balance is exhausted"
      elseif status == 429 then
        return "DeepSeek web search was rate limited; retry later"
      end
    end,
  })
  return function(request)
    ---@type Neoagent.ProviderUseLease?
    local lease
    return async.run(function()
      local acquired, err = provider_service.acquire_use(runtime.service)
      if not acquired then
        error(err, 0)
      end
      lease = acquired
      local resolved = auth_headers
        .resolve({
          resolve_auth = function()
            if provider.auth then
              return options.auth:resolve(provider.auth, { optional = true })
            end
            return async.run(function()
              return { ok = true, configured = false }
            end, { error_kind = "auth" })
          end,
        }, {
          name = "DeepSeek",
          environment = "DEEPSEEK_API_KEY",
          ambient_api_key = function()
            return runtime.credentials:ambient_api_key()
          end,
          missing_message = "Log in to the DeepSeek provider or set DEEPSEEK_API_KEY to use web search",
        })
        :await()
      if resolved.ok == false then
        error(resolved.error, 0)
      end
      local fetched = client
        :post("/v1/tools/search", "web search", {
          query = request.query,
          count = request.count,
          need_content = request.include_content,
        }, resolved.headers)
        :await()
      if fetched.ok == false then
        error(fetched.error, 0)
      end
      return { ok = true, results = results(fetched.value, request) }
    end, {
      error_kind = "provider",
      on_done = function()
        if lease then
          lease:release()
        end
      end,
    })
  end
end

---@type Neoagent.DeepSeekSearchDefinition
local backend = { name = "DeepSeek", max_query_chars = 128, max_count = 50, create = create }
return backend
