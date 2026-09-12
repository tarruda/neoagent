local async = require("neoagent.async")
local http_client = require("neoagent.transport.http")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.HuggingFaceOptions
---@field token? string
---@field base_url? string
---@field transport? Neoagent.ByteBackend

---@class Neoagent.HuggingFaceSearchEntry
---@field id string
---@field downloads number

---@class Neoagent.HuggingFaceQuantization
---@field name string
---@field size? number

---@class Neoagent.HuggingFaceDetails
---@field id string
---@field gated "auto"|"manual"|false
---@field quantizations Neoagent.HuggingFaceQuantization[]

---@class Neoagent.HuggingFaceResponse
---@field ok true
---@field value? Neoagent.JsonValue

local DEFAULT_BASE_URL = "https://huggingface.co"
local REQUEST_TIMEOUT_MS = 15000
local QUANTIZATION_ALTS = {
  "IQ%d[_A-Z0-9]+",
  "Q%d[_A-Z0-9]+",
  "BF16",
  "F16",
  "F32",
  "MXFP%d[_A-Z0-9]*",
}
local SHARD_SUFFIX_PATTERN = "%-%d+%-of%-%d+$"

---@param path string
---@return string?
local function read_token(path)
  local value = fs.read(path)
  if not value then
    return nil
  end
  value = util.trim(value)
  return value ~= "" and value or nil
end

---@param env? table<string, string>
---@return string?
function M.find_token(env)
  local environment = env or vim.env
  -- Neovim environment reads return strings or nil.
  ---@cast environment table<string, string>
  local from_environment = util.trim(environment.HF_TOKEN or "")
  if from_environment ~= "" then
    return from_environment
  end
  local paths = {}
  ---@param path? string
  local function add(path)
    if type(path) == "string" and path ~= "" then
      paths[#paths + 1] = path
    end
  end
  add(environment.HF_TOKEN_PATH)
  add(environment.HF_HOME and fs.join(environment.HF_HOME, "token"))
  add(environment.XDG_CACHE_HOME and fs.join(environment.XDG_CACHE_HOME, "huggingface", "token"))
  local home_directory = vim.fn.expand("~")
  -- expand without the list flag returns a string.
  ---@cast home_directory string
  add(fs.join(home_directory, ".cache", "huggingface", "token"))
  local seen = {}
  for _, path in ipairs(paths) do
    if not seen[path] then
      seen[path] = true
      local token = read_token(path)
      if token then
        return token
      end
    end
  end
end

---@param payload? Neoagent.JsonValue
---@param fallback string
---@return string
local function payload_error(payload, fallback)
  if type(payload) ~= "table" then
    return fallback
  end
  local error = payload.error
  return type(error) == "string" and error ~= "" and error or fallback
end

---@async
---@param run Neoagent.Run<Neoagent.HuggingFaceResponse|Neoagent.AsyncFailure, nil>
---@return Neoagent.HuggingFaceResponse
local function await_ok(run)
  local result = run:await()
  if not result.ok then
    error(result.error, 0)
  end
  return result
end

---@param value string
---@return string
local function uri_encode_component(value)
  return (tostring(value):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

---@param id string
---@return string
local function encoded_id(id)
  local parts = {}
  for part in vim.gsplit(id, "/") do
    parts[#parts + 1] = uri_encode_component(part)
  end
  return table.concat(parts, "/")
end

---@class Neoagent.HuggingFaceClient
---@field token? string
---@field base_url string
---@field transport Neoagent.HttpClient
local Client = {}
Client.__index = Client

---@param value unknown
---@return TypeGuard<string>
local function safe_id(value)
  return type(value) == "string"
    and value ~= ""
    and #value <= 512
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

---@param path string
---@return Neoagent.Run<Neoagent.HuggingFaceResponse|Neoagent.AsyncFailure, nil>
function Client:request(path)
  return async.run(
    ---@return Neoagent.HuggingFaceResponse
    function()
      local headers = {}
      if self.token then
        headers.Authorization = "Bearer " .. self.token
      end
      local fetched = self.transport
        .fetch({
          request = {
            url = self.base_url .. path,
            method = "GET",
            headers = headers,
            timeout_ms = REQUEST_TIMEOUT_MS,
          },
        })
        :await()
      if not fetched.ok then
        error(fetched.error, 0)
      end
      if fetched.status and (fetched.status < 200 or fetched.status >= 300) then
        local payload = fetched.body
        local fallback = "Hugging Face returned HTTP " .. tostring(fetched.status)
        error(util.error("provider", payload_error(payload, fallback)), 0)
      end
      return { ok = true, value = fetched.body }
    end,
    { error_kind = "provider" }
  )
end

---@param query string
---@return Neoagent.Run<Neoagent.HuggingFaceSearchEntry[], nil>
function Client:search(query)
  local params = {
    "search=" .. uri_encode_component(query),
    "filter=gguf",
    "sort=downloads",
    "direction=-1",
    "limit=20",
  }
  return async.run(
    ---@return Neoagent.HuggingFaceSearchEntry[]
    function()
      local payload = await_ok(self:request("/api/models?" .. table.concat(params, "&"))).value
      if type(payload) ~= "table" or not util.is_list(payload) then
        error(util.error("provider", "Hugging Face returned invalid search results"), 0)
      end
      local result = {}
      for _, value in ipairs(payload) do
        if type(value) == "table" and safe_id(value.id) then
          result[#result + 1] = {
            id = value.id,
            downloads = tonumber(value.downloads) or 0,
          }
        end
      end
      return result
    end,
    { error_kind = "provider" }
  )
end

---@param stem string
---@return string?
local function quantization_name(stem)
  for _, alternative in ipairs(QUANTIZATION_ALTS) do
    local matched = stem:match("(UD%-" .. alternative .. ")$")
    if matched then
      return matched:upper()
    end
    matched = stem:match("(" .. alternative .. ")$")
    if matched then
      return matched:upper()
    end
  end
end

---@param siblings? Neoagent.JsonValue
---@return Neoagent.HuggingFaceQuantization[]
local function quantization_size(siblings)
  assert(siblings == nil or type(siblings) == "table", "Hugging Face model files must be a list")
  local sizes = {}
  for _, value in ipairs(siblings or {}) do
    if type(value) == "table" and type(value.rfilename) == "string" then
      local filename = value.rfilename:match("([^/]+)$") or value.rfilename
      if filename:lower():sub(-5) == ".gguf" and filename:lower():sub(1, 6) ~= "mmproj" then
        local stem = filename:sub(1, -6):gsub(SHARD_SUFFIX_PATTERN, "")
        local quantization = quantization_name(stem)
        if quantization then
          local current = sizes[quantization] or { total = 0, complete = true }
          if type(value.size) == "number" then
            current.total = current.total + value.size
          else
            current.complete = false
          end
          sizes[quantization] = current
        end
      end
    end
  end
  local result = {}
  for name, size in pairs(sizes) do
    result[#result + 1] = {
      name = name,
      size = size.complete and size.total or nil,
    }
  end
  table.sort(result, function(left, right)
    local left_recommended = left.name == "Q4_K_M"
    local right_recommended = right.name == "Q4_K_M"
    if left_recommended ~= right_recommended then
      return left_recommended
    end
    local left_size = left.size or math.huge
    local right_size = right.size or math.huge
    if left_size ~= right_size then
      return left_size < right_size
    end
    return left.name < right.name
  end)
  return result
end

---@param id string
---@return Neoagent.Run<Neoagent.HuggingFaceDetails, nil>
function Client:details(id)
  assert(safe_id(id), "Hugging Face model id must be safe non-empty text")
  return async.run(
    ---@return Neoagent.HuggingFaceDetails
    function()
      local payload = await_ok(self:request("/api/models/" .. encoded_id(id) .. "?blobs=true")).value
      if type(payload) ~= "table" then
        error(util.error("provider", "Hugging Face returned invalid model details"), 0)
      end
      ---@type "auto"|"manual"|false
      local gated = false
      if payload.gated == "auto" or payload.gated == "manual" then
        gated = payload.gated
      end
      return {
        id = safe_id(payload.id) and payload.id or id,
        gated = gated,
        quantizations = quantization_size(payload.siblings),
      }
    end,
    { error_kind = "provider" }
  )
end

---@param opts? Neoagent.HuggingFaceOptions
---@return Neoagent.HuggingFaceClient
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    token = opts.token,
    base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/+$", ""),
    transport = http_client.new(opts.transport),
  }, Client)
end

return M
