local identities = require("neoagent.tools.identities")
local schema = require("neoagent.api.tool_schema")
local truncate = require("neoagent.tools.truncate")
local util = require("neoagent.util")
local search = require("neoagent.web_search")
local M = {}

---@class Neoagent.WebSearchToolEnvironment
---@field web_search? Neoagent.WebSearch

---@class Neoagent.WebSearchSource: Neoagent.JsonObject
---@field title string
---@field url string

---@class Neoagent.ToolWebSearchPresentation
---@field kind 'web_search'
---@field backend string
---@field query string
---@field sources? Neoagent.WebSearchSource[]
---@field truncated? boolean

---@param value string
---@return string
local function preview_text(value)
  return (truncate.line((value:gsub("[%c%s]+", " ")), 512))
end

---@param opts? Neoagent.ToolPresentationOptions
---@param backend string
---@return Neoagent.ToolWebSearchPresentation?
local function presentation(opts, backend)
  if type(opts) ~= "table" then
    return nil
  end
  local args = type(opts.arguments) == "table" and opts.arguments or {}
  local details = opts.result and opts.result.details
  ---@type Neoagent.ToolWebSearchPresentation
  local value = {
    kind = "web_search",
    backend = backend,
    query = type(args.query) == "string" and preview_text(args.query) or "…",
  }
  if type(details) ~= "table" then
    return value
  end
  if type(details.backend_name) == "string" then
    value.backend = preview_text(details.backend_name)
  end
  if type(details.query) == "string" then
    value.query = preview_text(details.query)
  end
  local sources = details.sources
  if type(sources) ~= "table" or not util.is_list(sources) then
    return value
  end
  local previews = {}
  for _, source in ipairs(sources) do
    if type(source) ~= "table" or type(source.title) ~= "string" or type(source.url) ~= "string" then
      return value
    end
    previews[#previews + 1] = { title = preview_text(source.title), url = preview_text(source.url) }
  end
  value.sources = previews
  value.truncated = details.truncated == true
  return value
end

---@param opts? Neoagent.WebSearchOptions
---@return Neoagent.Tool<Neoagent.WebSearchToolEnvironment>
function M.new(opts)
  if opts == nil then
    opts = {}
  end
  search.validate_options(opts)
  local backend = opts.backend or "deepseek"
  local definition = search.definition(backend)
  ---@type Neoagent.ToolSchema
  local input = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "Search query, 1–"
          .. definition.max_query_chars
          .. " characters. Use the backend's search syntax to narrow results.",
      },
      count = {
        type = "integer",
        description = "Maximum number of results, 1–" .. definition.max_count .. ". Defaults to 10.",
      },
      include_content = {
        type = "boolean",
        description = "Include available page content in addition to summaries. Defaults to false.",
      },
    },
    required = { "query" },
    additionalProperties = false,
  }
  return identities.bind_parent({
    name = "web_search",
    description = "Search the public web using "
      .. definition.name
      .. ". Returns source URLs and summaries; cite the source URLs when using results.",
    prompt_snippet = "Search the web for current information",
    input_schema = input,
    render = function(options)
      return presentation(options, definition.name)
    end,
    execute = function(arguments, ctx)
      local valid, message = schema.validate(input, arguments)
      assert(valid, message)
      local query = arguments.query
      assert(
        type(query) == "string"
          and util.is_valid_utf8(query)
          and util.trim(query) ~= ""
          and vim.fn.strchars(query) <= definition.max_query_chars,
        "query must contain 1–" .. definition.max_query_chars .. " Unicode characters and cannot be blank"
      )
      local count = arguments.count or 10
      assert(
        type(count) == "number" and count >= 1 and count <= definition.max_count,
        "count must be between 1 and " .. definition.max_count
      )
      local execute = ctx.context and ctx.context.web_search
      assert(execute, "web_search requires the composed search capability")
      local result =
        execute(backend, { query = query, count = count, include_content = arguments.include_content == true }):await()
      if result.ok == false then
        error(result.error, 0)
      end
      local parts = { "Search results for: " .. query }
      local sources = {}
      for index, entry in ipairs(result.results) do
        -- Keep bounded source labels for replayable cards, without duplicating page content.
        sources[index] = { title = preview_text(entry.title), url = preview_text(entry.url) }
        parts[#parts + 1] = index
          .. ". "
          .. entry.title
          .. "\n"
          .. entry.url
          .. (entry.published_at and "\nPublished: " .. entry.published_at or "")
          .. "\n"
          .. entry.summary
          .. (entry.content and "\n\n" .. entry.content or "")
      end
      if #result.results == 0 then
        parts[#parts + 1] = "No results found."
      end
      local output = truncate.head(table.concat(parts, "\n\n"))
      local content = output.content
      if output.truncated then
        content = content .. "\n\n[Search output truncated; narrow the query or request fewer results.]"
      end
      return {
        content = { { type = "text", text = content } },
        details = {
          backend = backend,
          backend_name = definition.name,
          query = query,
          result_count = #result.results,
          sources = sources,
          truncated = output.truncated,
        },
      }
    end,
  })
end

return M
