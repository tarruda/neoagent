local async = require("neoagent.async")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.WebSearchOptions
---@field backend? string Defaults to deepseek.

---@class Neoagent.WebSearchRequest
---@field query string
---@field count integer
---@field include_content boolean

---@class Neoagent.WebSearchEntry
---@field title string
---@field url string
---@field summary string
---@field content? string
---@field published_at? string

---@class Neoagent.WebSearchSuccess
---@field ok true
---@field results Neoagent.WebSearchEntry[]

---@alias Neoagent.WebSearchResult Neoagent.WebSearchSuccess|Neoagent.AsyncFailure
---@alias Neoagent.WebSearchBackend fun(request: Neoagent.WebSearchRequest): Neoagent.Run<Neoagent.WebSearchResult, nil>
---@alias Neoagent.WebSearchBackendFactory fun(): Neoagent.WebSearchBackend
---@alias Neoagent.WebSearch fun(backend: string, request: Neoagent.WebSearchRequest): Neoagent.Run<Neoagent.WebSearchResult, nil>

---@class Neoagent.WebSearchBackendDefinition
---@field name string
---@field max_query_chars integer
---@field max_count integer

local backends = { deepseek = "neoagent.web_search.deepseek" }

---@param id string
---@return Neoagent.WebSearchBackendDefinition
function M.definition(id)
  local module = backends[id]
  assert(module, "Unknown web search backend: " .. tostring(id))
  return require(module)
end

---@param options Neoagent.WebSearchOptions
function M.validate_options(options)
  assert(
    type(options) == "table" and (next(options) == nil or not util.is_list(options)),
    "web_search must be false or an options object"
  )
  for key in pairs(options) do
    assert(key == "backend", "unsupported web_search setting: " .. tostring(key))
  end
  assert(
    options.backend == nil or type(options.backend) == "string" and options.backend ~= "",
    "web_search.backend must be a non-empty string"
  )
  M.definition(options.backend or "deepseek")
end

-- Composition binds each factory's dependencies. Search only routes requests;
-- optional authentication and transport belong to the selected backend.
---@param factories table<string, Neoagent.WebSearchBackendFactory>
---@return Neoagent.WebSearch
function M.new(factories)
  factories = util.shallow_copy(factories)
  ---@type table<string, Neoagent.WebSearchBackend>
  local instances = {}
  return function(id, request)
    request = util.copy(request)
    return async.run(function()
      local backend = instances[id]
      if not backend then
        local create = factories[id]
        assert(create, "Web search backend is not configured: " .. id)
        backend = create()
        instances[id] = backend
      end
      return backend(request):await()
    end)
  end
end

return M
