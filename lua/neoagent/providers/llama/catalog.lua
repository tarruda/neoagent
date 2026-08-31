local async = require("neoagent.async")
local client_module = require("neoagent.providers.llama.client")
local util = require("neoagent.util")

local M = {}

local function safe_text(value, maximum)
  if type(value) == "string" and value ~= "" and #value <= maximum
      and util.is_valid_utf8(value)
      and value:find("[%z\1-\31\127]") == nil then
    return value
  end
end

local function numeric_arg(args, names, equals_pattern)
  if type(args) ~= "table" then return nil end
  for index, argument in ipairs(args) do
    if names[argument] then
      local value = tonumber(args[index + 1])
      if value and value > 0 then return math.floor(value) end
    elseif type(argument) == "string" then
      local value = tonumber(argument:match(equals_pattern))
      if value and value > 0 then return math.floor(value) end
    end
  end
end

local function has_unified_kv(args)
  local unified = false
  for _, argument in ipairs(type(args) == "table" and args or {}) do
    if argument == "-kvu" or argument == "--kv-unified" then
      unified = true
    elseif argument == "-no-kvu" or argument == "--no-kv-unified" then
      unified = false
    end
  end
  return unified
end

local function context_from_args(args)
  local value = numeric_arg(args, {
    ["--ctx-size"] = true,
    ["-c"] = true,
    ["-ctx"] = true,
  }, "^%-%-ctx%-size=(%d+)$")
  local per_slot = numeric_arg(args, {
    ["--kv-unified-per-slot"] = true,
  }, "^%-%-kv%-unified%-per%-slot=(%d+)$")
  if not value then return per_slot end

  local parallel = numeric_arg(args, {
    ["--parallel"] = true,
    ["-np"] = true,
  }, "^%-%-parallel=(%d+)$")
  if parallel and parallel > 1 and not has_unified_kv(args) then
    value = math.floor(value / parallel)
  end
  if per_slot then value = math.min(value, per_slot) end
  return value
end

function M.reported_context(model)
  local reported = type(model.meta) == "table" and model.meta.n_ctx or nil
  local value = tonumber(reported) or tonumber(model.context_window)
    or context_from_args(type(model.status) == "table" and model.status.args)
  return value and value > 0 and math.floor(value) or nil
end

function M.normalize_model(model)
  if type(model) ~= "table" or util.is_list(model) then return nil end
  local id = safe_text(model.id, 512)
  local status = type(model.status) == "table" and model.status or {}
  local status_value = safe_text(status.value, 64)
  if not id or not status_value then return nil end
  local result = {
    id = id,
    status = { value = status_value },
    context_window = M.reported_context(model),
  }
  if status.failed == true then result.status.failed = true end
  if type(status.exit_code) == "number" and status.exit_code % 1 == 0 then
    result.status.exit_code = status.exit_code
  end
  if model.source == "preset" or model.source == "models_dir" then
    result.source = model.source
  end
  if type(model.meta) == "table" and type(model.meta.size) == "number"
      and model.meta.size >= 0 then
    result.meta = { size = model.meta.size }
  end
  local modalities = type(model.architecture) == "table"
    and model.architecture.input_modalities or nil
  if type(modalities) == "table" and util.is_list(modalities) then
    local input = { "text" }
    if vim.tbl_contains(modalities, "image") then
      input = { "text", "image" }
    end
    result.architecture = { input_modalities = input }
  end
  return result
end

function M.normalize(models)
  if type(models) ~= "table" or not util.is_list(models) then return nil end
  local result, seen = {}, {}
  for _, model in ipairs(models) do
    local normalized = M.normalize_model(model)
    if not normalized or seen[normalized.id] then return nil end
    seen[normalized.id] = true
    result[#result + 1] = normalized
  end
  table.sort(result, function(left, right) return left.id < right.id end)
  return result
end

local function bearer_key(resolved)
  local headers = type(resolved) == "table"
    and type(resolved.request_opts) == "table"
    and resolved.request_opts.headers or nil
  local value = type(headers) == "table"
    and (headers.Authorization or headers.authorization) or nil
  return type(value) == "string" and value:match("^[Bb]earer%s+(.+)$") or nil
end

function M.discover(ctx)
  return async.run(function()
    local resolved = ctx.resolve_auth():await()
    if resolved.ok == false then error(resolved.error, 0) end
    local server_url = ctx.provider.base_url
    local metadata = type(resolved) == "table" and resolved.metadata or nil
    if type(metadata) == "table" and type(metadata.server_url) == "string" then
      server_url = metadata.server_url
    end
    local client = client_module.new({
      server_url = client_module.normalize_server_url(server_url),
      api_key = bearer_key(resolved),
      transport = ctx.transport,
    })
    local listed = client:list():await()
    if listed.ok == false then error(listed.error, 0) end
    local models = M.normalize(listed.value)
    if not models then
      error(util.error("provider",
        "llama.cpp returned an invalid model catalog"), 0)
    end
    return { ok = true, models = models }
  end, { error_kind = "provider" })
end

function M.transform(model)
  local source = util.copy(model)
  local input = { "text" }
  local modalities = type(source.architecture) == "table"
    and source.architecture.input_modalities or nil
  if type(modalities) == "table" and vim.tbl_contains(modalities, "image") then
    input = { "text", "image" }
  end
  return {
    id = source.id,
    input = input,
    context_window = M.reported_context(source),
  }
end

return M
