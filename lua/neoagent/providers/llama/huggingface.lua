local async = require("neoagent.async")
local curl = require("neoagent.transport.curl")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}
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

local function read_token(path)
  local value = fs.read(path)
  if not value then return nil end
  value = util.trim(value)
  return value ~= "" and value or nil
end

function M.find_token(env)
  env = env or vim.env
  local from_environment = util.trim(env.HF_TOKEN or "")
  if from_environment ~= "" then return from_environment end
  local paths = {}
  local function add(path)
    if type(path) == "string" and path ~= "" then paths[#paths + 1] = path end
  end
  add(env.HF_TOKEN_PATH)
  add(env.HF_HOME and fs.join(env.HF_HOME, "token"))
  add(env.XDG_CACHE_HOME and fs.join(env.XDG_CACHE_HOME, "huggingface", "token"))
  add(fs.join(vim.fn.expand("~"), ".cache", "huggingface", "token"))
  local seen = {}
  for _, path in ipairs(paths) do
    if not seen[path] then
      seen[path] = true
      local token = read_token(path)
      if token then return token end
    end
  end
end

local function payload_error(payload, fallback)
  if type(payload) ~= "table" then return fallback end
  local error = payload.error
  return type(error) == "string" and error ~= "" and error or fallback
end

local function await_ok(run)
  local result = run:await()
  if not result.ok then error(result.error, 0) end
  return result
end

local function uri_encode_component(value)
  return (tostring(value):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

local function encoded_id(id)
  local parts = {}
  for part in vim.gsplit(id, "/") do
    parts[#parts + 1] = uri_encode_component(part)
  end
  return table.concat(parts, "/")
end

local Client = {}
Client.__index = Client

local function safe_id(value)
  return type(value) == "string" and value ~= "" and #value <= 512
    and util.is_valid_utf8(value)
    and not value:find("[%z\1-\31\127]")
end

function Client:request(path)
  return async.run(function()
    local headers = {}
    if self.token then headers.Authorization = "Bearer " .. self.token end
    local fetched = self.transport.fetch({
      request = {
        url = self.base_url .. path,
        method = "GET",
        headers = headers,
        timeout_ms = REQUEST_TIMEOUT_MS,
      },
    }):await()
    if not fetched.ok then error(fetched.error, 0) end
    if fetched.status and (fetched.status < 200 or fetched.status >= 300) then
      local ok, payload = pcall(vim.json.decode, fetched.body or "")
      local fallback = "Hugging Face returned HTTP " .. tostring(fetched.status)
      error(util.error("provider",
        ok and payload_error(payload, fallback) or fallback), 0)
    end
    local ok, payload = pcall(vim.json.decode, fetched.body or "")
    if not ok then error(util.error("provider", "Hugging Face returned an invalid response"), 0) end
    return { ok = true, value = payload }
  end, { error_kind = "provider" })
end

function Client:search(query)
  local params = {
    "search=" .. uri_encode_component(query),
    "filter=gguf",
    "sort=downloads",
    "direction=-1",
    "limit=20",
  }
  return async.run(function()
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
  end, { error_kind = "provider" })
end

local function quantization_name(stem)
  for _, alternative in ipairs(QUANTIZATION_ALTS) do
    local matched = stem:match("(UD%-" .. alternative .. ")$")
    if matched then return matched:upper() end
    matched = stem:match("(" .. alternative .. ")$")
    if matched then return matched:upper() end
  end
end

local function quantization_size(siblings)
  local sizes = {}
  for _, value in ipairs(siblings or {}) do
    if type(value) == "table" and type(value.rfilename) == "string" then
      local filename = value.rfilename:match("([^/]+)$") or value.rfilename
      if filename:lower():sub(-5) == ".gguf"
          and filename:lower():sub(1, 6) ~= "mmproj" then
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
    if left.name == "Q4_K_M" then return true end
    if right.name == "Q4_K_M" then return false end
    local left_size = left.size or math.huge
    local right_size = right.size or math.huge
    if left_size ~= right_size then return left_size < right_size end
    return left.name < right.name
  end)
  return result
end

function Client:details(id)
  assert(safe_id(id), "Hugging Face model id must be safe non-empty text")
  return async.run(function()
    local payload = await_ok(self:request("/api/models/" .. encoded_id(id) .. "?blobs=true")).value
    if type(payload) ~= "table" then
      error(util.error("provider", "Hugging Face returned invalid model details"), 0)
    end
    local gated = false
    if payload.gated == "auto" or payload.gated == "manual" then
      gated = payload.gated
    end
    return {
      id = safe_id(payload.id) and payload.id or id,
      gated = gated,
      quantizations = quantization_size(payload.siblings),
    }
  end, { error_kind = "provider" })
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    token = opts.token,
    base_url = (opts.base_url or DEFAULT_BASE_URL):gsub("/+$", ""),
    transport = opts.transport or curl,
  }, Client)
end

return M
