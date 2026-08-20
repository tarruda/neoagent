local async = require("neoagent.async")
local client_module = require("neoagent.providers.llama.client")
local huggingface = require("neoagent.providers.llama.huggingface")
local provider_catalog = require("neoagent.provider_catalog")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}
local ACTIVITY_LIMIT = 50
local DEFAULT_CATALOG_TTL_MS = 60 * 1000
local FALLBACK_CONTEXT_WINDOW = 4096

local function trimmed(value)
  return type(value) == "string" and util.trim(value) or ""
end

local function loaded(model)
  return model.status.value == "loaded" or model.status.value == "sleeping"
end

local function context_from_args(args)
  if type(args) ~= "table" then return nil end
  for index, argument in ipairs(args) do
    if argument == "--ctx-size" or argument == "-c" or argument == "-ctx" then
      local value = tonumber(args[index + 1])
      if value and value > 0 then return math.floor(value) end
    elseif type(argument) == "string" then
      local value = tonumber(argument:match("^%-%-ctx%-size=(%d+)$"))
      if value and value > 0 then return math.floor(value) end
    end
  end
end

local function reported_context(model)
  local reported = type(model.meta) == "table"
    and (model.meta.n_ctx or model.meta.n_ctx_train) or nil
  local value = tonumber(reported) or tonumber(model.context_window)
    or context_from_args(type(model.status) == "table" and model.status.args)
  return value and value > 0 and math.floor(value) or nil
end

local function safe_text(value, maximum)
  if type(value) ~= "string" or value == "" or #value > maximum
      or not util.is_valid_utf8(value)
      or value:find("[%z\1-\31\127]") then
    return nil
  end
  return value
end

local function bounded_text(value, maximum)
  value = tostring(value or "")
  value = value:gsub("[%z\1-\31\127]", " ")
  if not util.is_valid_utf8(value) then return "Invalid provider text" end
  if #value <= maximum then return value end
  local limit = maximum - 3
  local result = value:sub(1, limit)
  while result ~= "" and not util.is_valid_utf8(result) do
    result = result:sub(1, -2)
  end
  return result .. "..."
end

-- Router responses can include command lines, filesystem paths, presets, and
-- environment-derived values. Runtime state and the persisted cache retain
-- only the fields used to construct Models and render provider status.
local function normalized_model(model)
  if type(model) ~= "table" then return nil end
  local id = safe_text(model.id, 512)
  local status = type(model.status) == "table" and model.status or {}
  local status_value = safe_text(status.value, 64)
  if not id or not status_value then return nil end
  local result = {
    id = id,
    status = { value = status_value },
    context_window = reported_context(model),
  }
  if status.failed == true then result.status.failed = true end
  if type(status.exit_code) == "number" then
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
  if type(modalities) == "table" and vim.tbl_contains(modalities, "image") then
    result.architecture = { input_modalities = { "text", "image" } }
  end
  return result
end

local function normalized_catalog(raw)
  local result = {}
  for _, model in ipairs(type(raw) == "table" and raw or {}) do
    local normalized = normalized_model(model)
    if normalized then result[#result + 1] = normalized end
  end
  return result
end

local function cached_catalog(models, checked_at)
  return {
    version = 1,
    models = models,
    checked_at = checked_at == nil and util.now_ms() or checked_at,
  }
end

-- Definitions with an alias id route inference to the router model id while
-- keeping the alias as the selectable Neoagent model id.
local function definition_request_opts(definition)
  if definition.router_id == definition.id then
    return definition.request_opts
  end
  local layer = type(definition.request_opts) == "table"
    and util.copy(definition.request_opts) or {}
  layer.body = util.deep_merge(layer.body or {}, { model = definition.router_id })
  return layer
end

local function to_model_entry(model, definition)
  local context_window = definition and definition.context_window or nil
  if not context_window then
    context_window = reported_context(model)
  end
  if not context_window or context_window <= 0 then
    context_window = FALLBACK_CONTEXT_WINDOW
  end
  local input = { "text" }
  local architecture = model.architecture
  if type(architecture) == "table"
      and type(architecture.input_modalities) == "table" then
    for _, modality in ipairs(architecture.input_modalities) do
      if modality == "image" then
        input = { "text", "image" }
        break
      end
    end
  end
  if definition and definition.input ~= nil then
    input = util.copy(definition.input)
  end
  local entry = {
    id = definition and definition.id or model.id,
    input = input,
    context_window = math.floor(context_window + 0.5),
  }
  if definition then
    if definition.max_output_tokens ~= nil then
      entry.max_output_tokens = definition.max_output_tokens
    end
    if definition.request_timeout_ms ~= nil then
      entry.request_timeout_ms = definition.request_timeout_ms
    end
    if definition.thinking ~= nil then
      entry.thinking = util.copy(definition.thinking)
    end
    if definition.request_opts ~= nil or definition.router_id ~= definition.id then
      entry.request_opts = definition_request_opts(definition)
    end
  end
  return entry
end

local function context_label(model)
  local value = reported_context(model)
  if value then
    return value >= 1000 and string.format("%dk", math.floor(value / 1000 + 0.5))
      or string.format("%d", value)
  end
end

local function model_description(model)
  local details = {}
  if model.source == "preset" then
    details[#details + 1] = "server preset"
  elseif model.source == "models_dir" then
    details[#details + 1] = "models dir"
  end
  if loaded(model) then
    details[#details + 1] = "loaded"
  elseif model.status.failed then
    details[#details + 1] = "failed"
  elseif model.status.value ~= "unloaded" then
    details[#details + 1] = model.status.value
  end
  local context = context_label(model)
  if context then details[#details + 1] = context .. " context" end
  local size = type(model.meta) == "table" and model.meta.size or nil
  if type(size) == "number" and size > 0 then
    details[#details + 1] = client_module.format_bytes(size)
  end
  return table.concat(details, " · ")
end

local function auth_request_opts(resolved)
  if not resolved or resolved.configured ~= true then return nil end
  return resolved.request_opts or {}
end

local function bearer_key(request_opts)
  if type(request_opts) ~= "table" or type(request_opts.headers) ~= "table" then
    return nil
  end
  for name, value in pairs(request_opts.headers) do
    if name:lower() == "authorization" and type(value) == "string" then
      local key = value:match("^Bearer%s+(.+)$")
      if key then return key end
    end
  end
end

local function interact_await(method, options)
  return async.await(function(done)
    return method(options, done)
  end)
end

local function await_ok(run)
  local result = run:await()
  if not result.ok then error(result.error, 0) end
  return result
end

local function await_value(run)
  local result = run:await()
  if type(result) == "table" and result.ok == false then
    error(result.error, 0)
  end
  return result
end

local function interact_value(method, options)
  local ok, value = pcall(interact_await, method, options)
  if not ok then
    if type(value) == "table" and value.kind == "cancelled" then return nil end
    error(value, 0)
  end
  return value
end

local function interact_select(ctx, options)
  return interact_value(ctx.interact.select, options)
end

local function interact_input(ctx, options)
  return interact_value(ctx.interact.input, options)
end

local function interact_confirm(ctx, options)
  return interact_value(ctx.interact.confirm, options)
end

local function progress(ctx, operation)
  ctx.interact.progress(operation)
end

local function parse_huggingface_model(value)
  local slash = value:find("/")
  if not slash then return value end
  local colon = value:find(":", slash + 1)
  if not colon then return value end
  return value:sub(1, colon - 1), value:sub(colon + 1)
end

-- Model definitions are plain tables under `providers["llama.cpp"].models`.
-- Each definition may name an HF source, recommended router load parameters,
-- and the inference parameters the openai-completions model entries accept.
local LOAD_LABELS = {
  ctx_size = "ctx",
  gpu_layers = "gpu-layers",
  threads = "threads",
  flash_attn = "flash-attn",
}

local LOAD_ORDER = { "ctx_size", "gpu_layers", "threads", "flash_attn" }
local LOAD_INDEX = {}
for index, name in ipairs(LOAD_ORDER) do LOAD_INDEX[name] = index end

local function load_names(load)
  local names = {}
  for name in pairs(load or {}) do names[#names + 1] = name end
  table.sort(names, function(left, right)
    local left_index = LOAD_INDEX[left]
    local right_index = LOAD_INDEX[right]
    if left_index or right_index then
      if not left_index then return false end
      if not right_index then return true end
      return left_index < right_index
    end
    return left < right
  end)
  return names
end

local function definition_error(id, message)
  return "llama.cpp model definition " .. id .. ": " .. message
end

local function validate_load(id, value)
  if value == nil then return nil end
  assert(type(value) == "table" and not util.is_list(value),
    definition_error(id, "load must be an object"))
  local result = {}
  for name, entry in pairs(value) do
    assert(type(name) == "string" and name:match("^[%a][%w_-]*$"),
      definition_error(id, "load parameter names must contain letters, numbers, _ or -"))
    assert(name ~= "model" and name ~= "hf_repo" and name ~= "hf-repo",
      definition_error(id, "load parameter " .. name .. " is managed by the definition"))
    local kind = type(entry)
    assert(kind == "boolean" or kind == "string" or kind == "number",
      definition_error(id, "load " .. name .. " must be a string, number, or boolean"))
    if kind == "string" then
      assert(entry ~= "" and #entry <= 4096 and util.is_valid_utf8(entry)
          and not entry:find("[%z\1-\31\127]"),
        definition_error(id, "load " .. name .. " must be safe non-empty text"))
    elseif kind == "number" then
      assert(entry > -math.huge and entry < math.huge,
        definition_error(id, "load " .. name .. " must be finite"))
    end
    if name == "ctx_size" or name == "threads" then
      assert(kind == "number" and entry % 1 == 0 and entry > 0,
        definition_error(id, "load " .. name .. " must be positive"))
    elseif name == "gpu_layers" then
      assert(kind == "number" and entry % 1 == 0 and entry >= 0,
        definition_error(id, "load gpu_layers must be a non-negative integer"))
    elseif name == "flash_attn" then
      assert(kind == "boolean",
        definition_error(id, "load flash_attn must be a boolean"))
    end
    result[name] = entry
  end
  return result
end

local function validate_input(id, value)
  if value == nil then return nil end
  assert(util.is_list(value) and #value > 0,
    definition_error(id, "input must be a non-empty list"))
  local seen = {}
  for _, modality in ipairs(value) do
    assert(modality == "text" or modality == "image",
      definition_error(id, "input entries must be text or image"))
    assert(not seen[modality],
      definition_error(id, "input entries must be unique"))
    seen[modality] = true
  end
  return util.copy(value)
end

local function model_definition(id, value)
  assert(type(id) == "string" and id ~= "" and #id <= 512
      and util.is_valid_utf8(id) and not id:find("[%z\1-\31\127]"),
    "llama.cpp model ids must be safe non-empty strings of at most 512 bytes")
  assert(type(value) == "table" and not util.is_list(value),
    definition_error(id, "must be an object"))
  local hf_repo, quantization
  if value.hf_repo ~= nil then
    assert(type(value.hf_repo) == "string" and value.hf_repo ~= ""
        and #value.hf_repo <= 512 and util.is_valid_utf8(value.hf_repo)
        and not value.hf_repo:find("[%z\1-\31\127]"),
      definition_error(id, "hf_repo must be safe non-empty text"))
    hf_repo, quantization = parse_huggingface_model(value.hf_repo)
    assert(hf_repo:find("/") ~= nil,
      definition_error(id, "hf_repo must use the org/repo form"))
  end
  if value.quantization ~= nil then
    assert(type(value.quantization) == "string"
      and value.quantization:match("^[%w._-]+$")
      and #value.quantization <= 64,
      definition_error(id, "quantization must be a non-empty tag"))
    assert(quantization == nil or quantization == value.quantization,
      definition_error(id, "quantization conflicts with hf_repo"))
    quantization = value.quantization
  end
  if value.context_window ~= nil then
    assert(type(value.context_window) == "number"
      and value.context_window > 0 and value.context_window % 1 == 0,
      definition_error(id, "context_window must be a positive integer"))
  end
  if value.max_output_tokens ~= nil then
    assert(type(value.max_output_tokens) == "number"
      and value.max_output_tokens > 0 and value.max_output_tokens % 1 == 0,
      definition_error(id, "max_output_tokens must be a positive integer"))
  end
  if value.request_timeout_ms ~= nil then
    assert(type(value.request_timeout_ms) == "number"
      and value.request_timeout_ms > 0 and value.request_timeout_ms % 1 == 0,
      definition_error(id, "request_timeout_ms must be a positive integer"))
  end
  if value.thinking ~= nil and value.thinking ~= false then
    assert(type(value.thinking) == "table",
      definition_error(id, "thinking must be a table or false"))
  end
  if value.request_opts ~= nil then
    assert(type(value.request_opts) == "table"
      or type(value.request_opts) == "function",
      definition_error(id, "request_opts must be a table or function"))
  end
  local definition = {
    id = id,
    router_id = hf_repo
      and (hf_repo .. (quantization and ":" .. quantization or "")) or id,
    hf_repo = hf_repo,
    quantization = quantization,
    load = validate_load(id, value.load),
    input = validate_input(id, value.input),
    context_window = value.context_window,
    max_output_tokens = value.max_output_tokens,
    request_timeout_ms = value.request_timeout_ms,
    thinking = value.thinking,
    request_opts = value.request_opts,
  }
  if definition.router_id ~= id
      and type(definition.request_opts) == "function" then
    error(definition_error(id,
      "request_opts must be a table when the id aliases an HF source"), 0)
  end
  return definition
end

local function definitions_of(models)
  local result = {}
  local order = {}
  local aliases = {}
  for id, value in pairs(models or {}) do
    local definition = model_definition(id, value)
    result[id] = definition
    order[#order + 1] = id
    if definition.router_id ~= id then aliases[#aliases + 1] = definition end
  end
  table.sort(order)
  return result, order, aliases
end

local function validate_service_opts(value)
  value = value or {}
  assert(type(value) == "table"
      and (next(value) == nil or not util.is_list(value)),
    "llama.cpp service_opts must be an object")
  local allowed = {
    wait_timeout_ms = true,
    download_timeout_ms = true,
    poll_interval_ms = true,
  }
  for name, entry in pairs(value) do
    assert(allowed[name], "unknown llama.cpp service option: " .. tostring(name))
    assert(type(entry) == "number" and entry > 0 and entry % 1 == 0,
      "llama.cpp service option " .. name .. " must be a positive integer")
  end
  return util.copy(value)
end

local function validate_catalog_cache(value)
  if value == false then return false end
  value = value or { ttl_ms = DEFAULT_CATALOG_TTL_MS }
  assert(type(value) == "table"
      and (next(value) == nil or not util.is_list(value)),
    "llama.cpp catalog_cache must be false or an object")
  for name in pairs(value) do
    assert(name == "ttl_ms",
      "unknown llama.cpp catalog cache option: " .. tostring(name))
  end
  local ttl_ms = value.ttl_ms
  if ttl_ms == nil then ttl_ms = DEFAULT_CATALOG_TTL_MS end
  assert(type(ttl_ms) == "number" and ttl_ms >= 0
      and ttl_ms % 1 == 0,
    "llama.cpp catalog_cache.ttl_ms must be a non-negative integer")
  return { ttl_ms = ttl_ms }
end

local function load_summary(definition)
  local parts = {}
  for _, name in ipairs(load_names(definition.load)) do
    local load = definition.load
    local value
    if load ~= nil then value = load[name] end
    if value ~= nil then
      local label = LOAD_LABELS[name] or name:gsub("_", "-")
      if value == true then
        parts[#parts + 1] = label
      elseif value == false then
        parts[#parts + 1] = "no-" .. label
      else
        parts[#parts + 1] = label .. " " .. tostring(value)
      end
    end
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

local function definition_summary(definition)
  local parts = {}
  if definition.router_id ~= definition.id then
    parts[#parts + 1] = definition.router_id
  end
  local load = load_summary(definition)
  if load then parts[#parts + 1] = load end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

-- The router applies load parameters through its own server-side preset, so
-- defined load values render as the matching `--models-preset` INI section.
local function preset_ini(definitions, order)
  local lines = { "version = 1", "" }
  local sections = 0
  for _, id in ipairs(order) do
    local definition = definitions[id]
    if definition.load and next(definition.load) ~= nil then
      sections = sections + 1
      lines[#lines + 1] = "[" .. definition.router_id .. "]"
      if definition.hf_repo then
        lines[#lines + 1] = "hf-repo = " .. definition.router_id
      end
      local load = definition.load
      for _, name in ipairs(load_names(load)) do
        local key = LOAD_LABELS[name] or name:gsub("_", "-")
        if name == "ctx_size" then key = "c" end
        if name == "gpu_layers" then key = "n-gpu-layers" end
        if name == "threads" then key = "t" end
        local value = load[name]
        if name == "flash_attn" then value = value and "on" or "off" end
        lines[#lines + 1] = key .. " = " .. tostring(value)
      end
      lines[#lines + 1] = ""
    end
  end
  return sections > 0 and table.concat(lines, "\n") or ""
end

function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local models = {}
  local catalog = {}
  local display_server_url = client_module.normalize_server_url(opts.base_url or "")
  local connection = {
    type = "status",
    text = "Connecting to router",
    level = "muted",
  }
  local event_stream = "Waiting for catalog"
  local model_progress = {}
  local request_progress = {}
  local next_request_id = 0
  local last_response
  local activity = {}
  local destroyed = false
  local definitions, definition_order, alias_definitions =
    definitions_of(opts.models)
  local service_opts = validate_service_opts(opts.service_opts)
  local catalog_cache = validate_catalog_cache(opts.catalog_cache)
  local dashboard = provider_state.new({ blocks = {
    util.copy(connection),
    { type = "field", label = "Endpoint", value = display_server_url },
    { type = "field", label = "Events", value = event_stream },
  } })

  local function state_blocks()
    local blocks = {
      util.copy(connection),
      { type = "field", label = "Endpoint", value = display_server_url },
      { type = "field", label = "Events", value = event_stream },
    }
    if last_response then blocks[#blocks + 1] = util.copy(last_response) end
    local progress_models = {}
    for model_id in pairs(model_progress) do
      progress_models[#progress_models + 1] = model_id
    end
    table.sort(progress_models)
    for _, model_id in ipairs(progress_models) do
      blocks[#blocks + 1] = util.copy(model_progress[model_id])
    end
    local request_ids = {}
    for request_id in pairs(request_progress) do
      request_ids[#request_ids + 1] = request_id
    end
    table.sort(request_ids)
    for _, request_id in ipairs(request_ids) do
      blocks[#blocks + 1] = util.copy(request_progress[request_id])
    end
    if #activity > 0 then
      local entries = {}
      for index = math.max(1, #activity - 7), #activity do
        entries[#entries + 1] = util.copy(activity[index])
      end
      blocks[#blocks + 1] = {
        type = "activity",
        title = "Recent activity",
        entries = entries,
      }
    end
    return blocks
  end

  local function publish()
    if destroyed then return end
    local ok, err = dashboard:push({ blocks = state_blocks() })
    if not ok then
      vim.notify("neoagent llama.cpp dashboard failed: "
        .. tostring(err and err.message or err), vim.log.levels.ERROR)
    end
  end

  local function activity_add(message, level)
    local bounded = bounded_text(message, 512)
    local previous = activity[#activity]
    if previous and previous.message == bounded then
      previous.level = level or "info"
      previous.timestamp = util.now_ms()
      return
    end
    activity[#activity + 1] = {
      level = level or "info",
      message = bounded,
      timestamp = util.now_ms(),
    }
    while #activity > ACTIVITY_LIMIT do table.remove(activity, 1) end
  end

  local function set_catalog(raw, resolved_server_url)
    if type(resolved_server_url) == "string"
        and resolved_server_url ~= "" then
      display_server_url = resolved_server_url
    end
    catalog = normalized_catalog(raw)
    table.sort(catalog, function(left, right)
      local left_loaded = loaded(left) and 1 or 0
      local right_loaded = loaded(right) and 1 or 0
      if left_loaded ~= right_loaded then return left_loaded > right_loaded end
      return left.id < right.id
    end)
    models = {}
    local claimed = {}
    for _, id in ipairs(definition_order) do
      local definition = definitions[id]
      local entry_model
      for _, model in ipairs(catalog) do
        if model.id == definition.router_id then
          entry_model = model
          break
        end
      end
      models[#models + 1] = to_model_entry(entry_model or {
        id = definition.router_id,
        status = { value = "unloaded" },
      }, definition)
      claimed[definition.router_id] = true
    end
    for _, model in ipairs(catalog) do
      if not claimed[model.id] then
        models[#models + 1] = to_model_entry(model, nil)
      end
    end
    connection = {
      type = "status",
      text = "Router ready",
      level = "success",
    }
    publish()
  end

  local service = {
    id = resources.provider_id or "llama.cpp",
    name = "llama.cpp",
    operations = {},
  }

  local status_client
  local watcher_run
  local watcher_generation = 0
  local subscriber_count = 0
  local ensure_watcher

  local function client_from_auth(resolved)
    local server_url = opts.base_url
    local request_opts = auth_request_opts(resolved)
    local metadata = resolved and resolved.metadata
    if type(metadata) == "table" and type(metadata.server_url) == "string"
        and trimmed(metadata.server_url) ~= "" then
      server_url = client_module.normalize_server_url(metadata.server_url)
    end
    return client_module.new({
      server_url = client_module.normalize_server_url(server_url),
      api_key = bearer_key(request_opts),
      transport = resources.transport,
      wait_timeout_ms = service_opts.wait_timeout_ms,
      download_timeout_ms = service_opts.download_timeout_ms,
      poll_interval_ms = service_opts.poll_interval_ms,
    })
  end

  local function catalog_entry(model_id)
    for _, entry in ipairs(catalog) do
      if entry.id == model_id then return entry end
    end
  end

  local function update_catalog_status(model_id, status, data)
    local entry = catalog_entry(model_id)
    if not entry then
      entry = {
        id = model_id,
        status = { value = status },
      }
      catalog[#catalog + 1] = entry
    else
      entry.status = vim.tbl_extend("force", entry.status or {}, {
        value = status,
      })
    end
    if type(data) == "table" and type(data.exit_code) == "number" then
      entry.status.exit_code = data.exit_code
      if data.exit_code ~= 0 then entry.status.failed = true end
    end
    local info = type(data) == "table" and data.info or nil
    if type(info) == "table" and type(info.meta) == "table" then
      entry.meta = info.meta
    end
  end

  local function router_event(event)
    local model_id = safe_text(event.model, 512)
    if not model_id then return end
    local data = type(event.data) == "table" and event.data or {}
    local status = type(data.status) == "string" and data.status or nil
    if event.event == "download_progress" then
      local update = client_module.parse_download_progress(data)
      model_progress[model_id] = {
        type = "progress",
        label = bounded_text("Downloading " .. model_id, 512),
        value = update and update.ratio or nil,
        detail = update and update.detail or nil,
      }
      publish()
      return
    end
    if event.event == "download_finished" then
      model_progress[model_id] = nil
      update_catalog_status(model_id, "unloaded", data)
      activity_add("Downloaded " .. model_id, "success")
      set_catalog(catalog)
      return
    end
    if event.event == "download_failed" then
      model_progress[model_id] = nil
      activity_add("Download failed for " .. model_id, "error")
      publish()
      return
    end
    if event.event ~= "model_status" and event.event ~= "status_change" then
      return
    end
    if status == "loading" then
      local update = client_module.parse_load_progress(data)
      model_progress[model_id] = {
        type = "progress",
        label = bounded_text("Loading " .. model_id, 512),
        value = update and update.ratio or nil,
        detail = update and update.message or "Starting model worker",
      }
      update_catalog_status(model_id, status, data)
      publish()
    elseif status == "downloading" then
      model_progress[model_id] = {
        type = "progress",
        label = bounded_text("Downloading " .. model_id, 512),
      }
      update_catalog_status(model_id, status, data)
      publish()
    elseif status == "loaded" or status == "sleeping" then
      model_progress[model_id] = nil
      update_catalog_status(model_id, status, data)
      activity_add((status == "loaded" and "Loaded " or "Sleeping ")
        .. model_id, "success")
      set_catalog(catalog)
    elseif status == "unloaded" then
      model_progress[model_id] = nil
      update_catalog_status(model_id, status, data)
      local failed = type(data.exit_code) == "number" and data.exit_code ~= 0
      activity_add((failed and "Model failed: " or "Unloaded ")
        .. model_id, failed and "error" or "info")
      set_catalog(catalog)
    end
  end

  local function stop_watcher(next_state)
    watcher_generation = watcher_generation + 1
    if watcher_run then watcher_run:cancel() end
    watcher_run = nil
    if next_state then event_stream = next_state end
  end

  ensure_watcher = function()
    if destroyed or subscriber_count == 0 or watcher_run then return end
    watcher_generation = watcher_generation + 1
    local generation = watcher_generation
    local client = status_client
    event_stream = client and "Live" or "Connecting"
    publish()
    watcher_run = async.run(function()
      if not client then
        local resolved
        if type(resources.auth) == "table"
            and type(resources.auth.resolve) == "function" then
          resolved = resources.auth:resolve(opts.auth or "llama", {
            optional = opts.auth_optional == true,
          }):await()
          if resolved.ok == false then error(resolved.error, 0) end
        end
        client = client_from_auth(resolved)
        status_client = client
        event_stream = "Live"
        publish()
      end
      return client:watch(router_event):await()
    end, {
      on_done = function(result)
        if generation ~= watcher_generation then return end
        watcher_run = nil
        event_stream = result.ok and "Disconnected"
          or "Disconnected · " .. bounded_text(
            result.error and result.error.message or "event stream failed", 200)
        publish()
      end,
      error_kind = "provider",
    })
  end

  local function resolved_client(ctx)
    local resolved
    if type(ctx.resolve_auth) == "function" then
      resolved = ctx.resolve_auth():await()
      if resolved.ok == false then error(resolved.error, 0) end
    end
    local client = client_from_auth(resolved)
    if watcher_run then stop_watcher("Connecting") end
    status_client = client
    ensure_watcher()
    return client
  end

  function service:state()
    return dashboard:state()
  end

  function service:get_models()
    return util.copy(models)
  end

  function service:refresh_models(ctx)
    return async.run(function()
      if ctx.stored and type(ctx.stored) == "table"
          and util.is_list(ctx.stored.models) then
        local restored = normalized_catalog(ctx.stored.models)
        if vim.deep_equal(restored, ctx.stored.models) then
          set_catalog(restored)
        else
          local migrated, migrate_err = ctx.publish({
            update = function() set_catalog(restored) end,
            persist = cached_catalog(restored, ctx.stored.checked_at),
          })
          if migrated == nil then error(migrate_err, 0) end
        end
      end
      if not ctx.allow_network then return { ok = true } end
      local client = resolved_client(ctx)
      local current = await_ok(client:list({ reload = ctx.force })).value
      local safe = normalized_catalog(current)
      local resolved_server_url = client.server_url
      local published, publish_err = ctx.publish({
        update = function() set_catalog(safe, resolved_server_url) end,
        persist = cached_catalog(safe),
      })
      if published == nil then error(publish_err, 0) end
      return { ok = true, models = safe }
    end, { error_kind = "provider" })
  end

  function service:subscribe(listener)
    local unsubscribe = dashboard:subscribe(listener)
    subscriber_count = subscriber_count + 1
    ensure_watcher()
    local active = true
    return function()
      if not active then return end
      active = false
      unsubscribe()
      subscriber_count = math.max(0, subscriber_count - 1)
      if subscriber_count == 0 then
        stop_watcher(status_client and "Paused" or "Waiting for catalog")
      end
    end
  end

  local startup_run

  function service:destroy()
    destroyed = true
    if startup_run then startup_run:cancel() end
    startup_run = nil
    stop_watcher()
    dashboard:destroy()
    subscriber_count = 0
    models = {}
    catalog = {}
    activity = {}
    model_progress = {}
    request_progress = {}
    status_client = nil
  end

  local function known_model_status(model_id)
    local entry = catalog_entry(model_id)
    return entry and entry.status and entry.status.value or nil
  end

  local function response_usage(usage)
    if type(usage) ~= "table" then return nil end
    local input = tonumber(usage.inputTokens or usage.input_tokens)
    local output = tonumber(usage.outputTokens or usage.output_tokens)
    if not input and not output then return nil end
    local parts = {}
    if input then parts[#parts + 1] = tostring(input) .. " in" end
    if output then parts[#parts + 1] = tostring(output) .. " out" end
    return {
      type = "field",
      label = "Last response",
      value = table.concat(parts, " · "),
    }
  end

  -- The wrapper publishes inference lifecycle events and removes transport
  -- deadlines while the local router starts a requested model.
  function service:wrap_model(model)
    assert(type(model) == "table" and type(model.stream) == "function",
      "provider model wrapper requires a Model")
    local router_id = definitions[model.id]
      and definitions[model.id].router_id or model.id
    local wrapped = {
      api = model.api,
      provider = model.provider,
      id = model.id,
      input = util.copy(model.input),
      context_window = model.context_window,
      thinking = util.copy(model.thinking),
      timeout_ms = model.timeout_ms,
    }
    function wrapped:stream(opts)
      opts = opts or {}
      local has_timeout_override = opts.timeout_ms ~= nil
      local timeout = has_timeout_override and opts.timeout_ms
        or model.timeout_ms
      return async.run(function(run)
        next_request_id = next_request_id + 1
        local request_id = next_request_id
        local status = known_model_status(router_id)
        local inner = util.copy(opts)
        local generating = false
        request_progress[request_id] = {
          type = "progress",
          label = bounded_text("Request · " .. router_id, 512),
          detail = (status == "loaded" or status == "sleeping")
            and "Waiting for first token" or "Waiting for model worker",
        }
        publish()
        inner.on_event = function(event)
          if not generating and type(event) == "table"
              and (event.type == "text_delta"
                or event.type == "thinking_delta"
                or event.type == "tool_call_delta") then
            generating = true
            request_progress[request_id] = {
              type = "progress",
              label = bounded_text("Request · " .. router_id, 512),
              detail = "Generating response",
            }
            publish()
          elseif type(event) == "table" and event.type == "usage" then
            last_response = response_usage(event.usage) or last_response
          end
          run:emit(event)
        end
        inner.on_done = nil
        if not has_timeout_override
            and type(timeout) == "number" and timeout > 0
            and status ~= "loaded" and status ~= "sleeping" then
          inner.timeout_ms = false
        end
        local ok, result = pcall(function()
          return model:stream(inner):await()
        end)
        request_progress[request_id] = nil
        if ok and result.ok then
          last_response = response_usage(result.message and result.message.usage)
            or last_response
          activity_add("Completed response · " .. router_id, "success")
        elseif ok and result.error and result.error.kind ~= "cancelled" then
          activity_add("Request failed · " .. router_id, "error")
        end
        publish()
        if not ok then error(result, 0) end
        return result
      end, {
        on_event = opts.on_event,
        on_done = opts.on_done,
        error_kind = "model",
      })
    end
    wrapped._llama_service = service
    wrapped._llama_router_id = router_id
    return wrapped
  end

  local catalog_options = { service = service }
  if catalog_cache ~= false then
    catalog_options.store = resources.store
    catalog_options.ttl_ms = catalog_cache.ttl_ms
  end
  local catalog_helper = provider_catalog.new(catalog_options)

  local function catalog_publication(current, server_url)
    local safe = normalized_catalog(current)
    return {
      update = function() set_catalog(safe, server_url) end,
      persist = cached_catalog(safe),
    }
  end

  local function publish_catalog(current, server_url)
    local published, err = catalog_helper:publish(
      catalog_publication(current, server_url))
    if published == nil then error(err, 0) end
    return util.copy(catalog)
  end

  function service:refresh_catalog(refresh_opts)
    refresh_opts = refresh_opts or {}
    local resolve_auth = refresh_opts.resolve_auth
    if not resolve_auth and type(resources.auth) == "table"
        and type(resources.auth.resolve) == "function" then
      resolve_auth = function()
        return resources.auth:resolve(opts.auth or "llama", {
          optional = opts.auth_optional == true,
        })
      end
    end
    return catalog_helper:refresh({
      allow_network = refresh_opts.allow_network ~= false,
      force = refresh_opts.force == true,
      resolve_auth = resolve_auth,
      on_done = refresh_opts.on_done,
    })
  end

  service.operations.refresh = {
    label = "Refresh catalog",
    description = "Reload the llama.cpp router catalog",
    mutating = false,
    run = function(ctx)
      return async.run(function()
        local operation = {
          id = "refresh", label = "Refresh catalog",
          state = "running", message = "Refreshing catalog",
        }
        progress(ctx, operation)
        local result = await_ok(catalog_helper:refresh({
          allow_network = true,
          force = true,
          resolve_auth = ctx.resolve_auth,
        }))
        if not result.ok then error(result.error, 0) end
        return { ok = true }
      end, { error_kind = "provider" })
    end,
  }

  local function select_model(ctx, client, catalog_snapshot, target)
    local loaded_models = {}
    for _, model in ipairs(catalog_snapshot) do
      if loaded(model) then loaded_models[#loaded_models + 1] = model end
    end
    if #loaded_models > 0 then
      local choice = interact_select(ctx, {
        prompt = string.format("%d model%s loaded",
          #loaded_models, #loaded_models == 1 and " is" or "s are"),
        items = {
          { id = "replace", label = "Unload all and load" },
          { id = "keep", label = "Keep loaded and load" },
          { id = "cancel", label = "Cancel" },
        },
      })
      if not choice or choice == "cancel" then return false end
      if choice == "replace" then
        for _, model in ipairs(loaded_models) do
          await_ok(client:unload_and_wait(model.id))
        end
      end
    end
    return true
  end

  local function definition_for(model_id)
    local direct = definitions[model_id]
    if direct then return direct end
    for _, definition in ipairs(alias_definitions) do
      if definition.router_id == model_id then return definition end
    end
  end

  local function select_description(model)
    local description = model_description(model)
    local definition = definition_for(model.id)
    local summary = definition and definition_summary(definition) or nil
    if not summary then return description end
    return (description ~= "" and description .. " · " or "") .. summary
  end

  service.operations.catalog = {
    label = "Browse catalog",
    description = "Inspect router models in a floating selector",
    mutating = false,
    run = function(ctx)
      return async.run(function()
        local client = resolved_client(ctx)
        local current = await_ok(client:list()).value
        current = publish_catalog(current, client.server_url)
        local items = vim.tbl_map(function(entry)
          return {
            id = entry.id,
            label = entry.id,
            description = select_description(entry),
          }
        end, current)
        local seen = {}
        for _, item in ipairs(items) do seen[item.id] = true end
        for _, id in ipairs(definition_order) do
          if not seen[id] then
            items[#items + 1] = {
              id = id,
              label = id,
              description = definition_summary(definitions[id])
                or "configured model",
            }
          end
        end
        table.sort(items, function(left, right) return left.label < right.label end)
        interact_select(ctx, {
          prompt = "llama.cpp model catalog",
          items = items,
        })
        return { ok = true }
      end, { error_kind = "provider" })
    end,
  }

  local function complete_catalog(predicate)
    local result = {}
    for _, model in ipairs(catalog) do
      if predicate(model) then result[#result + 1] = model.id end
    end
    table.sort(result)
    return result
  end

  service.operations.load = {
    label = "Load model",
    description = "Load an unloaded router model",
    mutating = true,
    complete = function()
      return complete_catalog(function(model)
        return model.status.value == "unloaded"
      end)
    end,
    run = function(ctx)
      return async.run(function()
        local client = resolved_client(ctx)
        local current = await_ok(client:list()).value
        current = publish_catalog(current, client.server_url)
        local unloaded = {}
        for _, model in ipairs(current) do
          if model.status.value == "unloaded" then unloaded[#unloaded + 1] = model end
        end
        local selected = ctx.args
        if selected == nil or selected == "" then
          if #unloaded == 0 then
            activity_add("No unloaded models", "warn")
            publish()
            error(util.error("provider", "No unloaded models"), 0)
          end
          local options = {
            prompt = "Load model",
            items = vim.tbl_map(function(model)
              return { id = model.id, label = model.id, description = select_description(model) }
            end, unloaded),
          }
          selected = interact_select(ctx, options)
          if not selected then return { ok = true, cancelled = true } end
        end
        local definition = definitions[selected]
        if definition and definition.router_id ~= selected then
          selected = definition.router_id
        end
        local target
        for _, model in ipairs(current) do
          if model.id == selected then target = model break end
        end
        if not target then error(util.error("provider", "Unknown model: " .. selected), 0) end
        if not select_model(ctx, client, current, target) then
          return { ok = true, cancelled = true }
        end
        local operation = {
          id = "load", label = "Load model",
          state = "running", message = "Loading " .. target.id,
        }
        progress(ctx, operation)
        local result = await_ok(client:load_and_wait(target.id, function(update)
          operation.message = update.message
          operation.ratio = update.ratio
          operation.detail = update.detail
          progress(ctx, operation)
        end))
        activity_add("Loaded " .. target.id, "info")
        publish()
        await_ok(catalog_helper:refresh({
          allow_network = true,
          force = true,
          resolve_auth = ctx.resolve_auth,
        }))
        return { ok = true, model = result.value }
      end, { error_kind = "provider" })
    end,
  }

  service.operations.unload = {
    label = "Unload model",
    description = "Unload a loaded router model",
    mutating = true,
    complete = function()
      return complete_catalog(loaded)
    end,
    run = function(ctx)
      return async.run(function()
        local client = resolved_client(ctx)
        local current = await_ok(client:list()).value
        current = publish_catalog(current, client.server_url)
        local loaded_models = {}
        for _, model in ipairs(current) do
          if loaded(model) then loaded_models[#loaded_models + 1] = model end
        end
        local selected = ctx.args
        if selected == nil or selected == "" then
          if #loaded_models == 0 then
            activity_add("No loaded models", "warn")
            publish()
            error(util.error("provider", "No loaded models"), 0)
          end
          selected = interact_select(ctx, {
            prompt = "Unload model",
            items = vim.tbl_map(function(model)
              return { id = model.id, label = model.id, description = select_description(model) }
            end, loaded_models),
          })
          if not selected then return { ok = true, cancelled = true } end
        end
        local definition = definitions[selected]
        if definition and definition.router_id ~= selected then
          selected = definition.router_id
        end
        if not interact_confirm(ctx, { prompt = "Unload model?", message = selected }) then
          return { ok = true, cancelled = true }
        end
        local operation = {
          id = "unload", label = "Unload model",
          state = "running", message = "Unloading " .. selected,
        }
        progress(ctx, operation)
        await_ok(client:unload_and_wait(selected))
        activity_add("Unloaded " .. selected, "info")
        publish()
        await_ok(catalog_helper:refresh({
          allow_network = true,
          force = true,
          resolve_auth = ctx.resolve_auth,
        }))
        return { ok = true }
      end, { error_kind = "provider" })
    end,
  }

  service.operations.download = {
    label = "Download model",
    description = "Download a defined or Hugging Face GGUF model",
    mutating = true,
    complete = function()
      return util.copy(definition_order)
    end,
    run = function(ctx)
      return async.run(function()
        local client = resolved_client(ctx)
        local huggingface_client = huggingface.new({
          token = huggingface.find_token(),
          transport = resources.transport,
        })
        local query = ctx.args
        if query == nil or query == "" then
          query = interact_input(ctx, {
            prompt = "Model definition or Hugging Face search",
          })
          if not query then return { ok = true, cancelled = true } end
        end
        local model
        local checked_details
        local definition = definitions[query]
        local function choose_quantization(details, quantization)
          if quantization or #details.quantizations == 0 then
            return quantization, true
          end
          local options = {
            prompt = "Select quantization\n" .. details.id,
            items = vim.tbl_map(function(entry)
              local detail = {}
              if entry.size then
                detail[#detail + 1] = client_module.format_bytes(entry.size)
              end
              if entry.name == "Q4_K_M" then
                detail[#detail + 1] = "recommended"
              end
              return {
                id = entry.name,
                label = entry.name,
                description = #detail > 0
                  and table.concat(detail, " · ") or nil,
              }
            end, details.quantizations),
          }
          local selected = interact_select(ctx, options)
          return selected, selected ~= nil
        end
        if definition and definition.hf_repo then
          local details = await_value(
            huggingface_client:details(definition.hf_repo))
          local quantization, selected = choose_quantization(
            details, definition.quantization)
          if not selected then return { ok = true, cancelled = true } end
          model = quantization and (details.id .. ":" .. quantization)
            or details.id
          checked_details = details
        else
          local results = await_value(huggingface_client:search(query))
          if #results == 0 then
            error(util.error("provider", "No GGUF models found"), 0)
          end
          local selected = interact_select(ctx, {
            prompt = "Select model",
            items = vim.tbl_map(function(found)
              return {
                id = found.id,
                label = found.id,
                description = string.format("%d downloads", found.downloads),
              }
            end, results),
          })
          if not selected then return { ok = true, cancelled = true } end
          local repository, quantization = parse_huggingface_model(selected)
          local details = await_value(huggingface_client:details(repository))
          local selected_quantization
          quantization, selected_quantization = choose_quantization(
            details, quantization)
          if not selected_quantization then
            return { ok = true, cancelled = true }
          end
          model = quantization and (details.id .. ":" .. quantization) or details.id
          checked_details = details
        end

        local function gated_choice(details)
          if not details.gated then return true end
          local message = details.gated == "manual"
            and "Manual approval is required"
            or "Accept the access terms"
          local choice = interact_select(ctx, {
            prompt = "Hugging Face access required\n" .. details.id .. "\n\n"
              .. message .. " at:\nhttps://huggingface.co/" .. details.id
              .. "\n\nThe llama.cpp server needs HF_TOKEN with access.",
            items = {
              { id = "continue", label = "Continue" },
              { id = "back", label = "Back" },
            },
          })
          return choice == "continue"
        end

        if not checked_details then
          local repository = parse_huggingface_model(model)
          checked_details = await_value(huggingface_client:details(repository))
        end
        if not gated_choice(checked_details) then
          return { ok = true, cancelled = true }
        end
        local operation = {
          id = "download", label = "Download model",
          state = "running", message = "Downloading " .. model,
        }
        progress(ctx, operation)
        local result = await_ok(client:download_and_wait(model, function(update)
          operation.message = update.message
          operation.ratio = update.ratio
          operation.detail = update.detail
          progress(ctx, operation)
        end))
        publish_catalog(result.value, client.server_url)
        activity_add("Downloaded " .. model, "info")
        publish()
        return { ok = true, models = result.value }
      end, { error_kind = "provider" })
    end,
  }

  service.operations.preset = {
    label = "Router preset",
    description = "Render server-side load parameters for defined models",
    mutating = false,
    run = function(ctx)
      return async.run(function()
        local ini = preset_ini(definitions, definition_order)
        if ini == "" then
          error(util.error("provider",
            "No model definitions with load parameters"), 0)
        end
        activity_add("Rendered router preset", "info")
        publish()
        return {
          ok = true,
          artifact = {
            kind = "document",
            name = "llama.cpp router preset",
            filetype = "dosini",
            content = ini,
          },
        }
      end, { error_kind = "provider" })
    end,
  }

  -- Read the short-lived provider catalog at startup and expose an explicit
  -- router reload. Startup work is scoped to explicitly configured and
  -- default-model providers.
  local provider_id = resources.provider_id or "llama.cpp"
  local startup_fetch = resources.startup ~= false
    and (resources.explicit == true
      or (type(resources.default_model) == "table"
        and resources.default_model.provider == provider_id))
  set_catalog({})
  activity = {}
  connection = {
    type = "status",
    text = "Catalog unavailable",
    level = "muted",
  }
  publish()
  if startup_fetch and type(resources.auth) == "table"
      and type(resources.auth.resolve) == "function" then
    startup_run = async.run(function()
      return service:refresh_catalog({ allow_network = true }):await()
    end, {
      on_done = function(result)
        startup_run = nil
        if not result.ok then
          connection = {
            type = "status",
            text = "Catalog unavailable",
            level = "error",
          }
          activity_add("Catalog refresh failed: "
            .. tostring(result.error and result.error.message or "unknown error"),
            "error")
          publish()
        end
      end,
      error_kind = "provider",
    })
  end
  return service
end

M.normalize_server_url = client_module.normalize_server_url
M.inference_url = client_module.inference_url

return M
