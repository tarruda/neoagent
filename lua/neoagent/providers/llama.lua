local async = require("neoagent.async")
local llama_catalog = require("neoagent.providers.llama.catalog")
local client_module = require("neoagent.providers.llama.client")
local huggingface = require("neoagent.providers.llama.huggingface")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}

local function trimmed(value)
  return type(value) == "string" and util.trim(value) or ""
end

local function loaded(model)
  return model.status.value == "loaded" or model.status.value == "sleeping"
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
  return llama_catalog.normalize_model(model)
end

local function normalized_catalog(raw)
  local result = {}
  for _, model in ipairs(type(raw) == "table" and raw or {}) do
    local normalized = normalized_model(model)
    if normalized then result[#result + 1] = normalized end
  end
  return result
end

local function context_label(model)
  local value = llama_catalog.reported_context(model)
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
  local router_id = id
  if hf_repo then
    router_id = hf_repo .. (quantization and ":" .. quantization or "")
  end
  local definition = {
    id = id,
    router_id = router_id,
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
    if value ~= false then
      local definition = model_definition(id, value)
      result[id] = definition
      order[#order + 1] = id
      if definition.router_id ~= id then aliases[#aliases + 1] = definition end
    end
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
  local model_catalog = assert(resources.catalog,
    "llama.cpp model catalog is required")
  local catalog = normalized_catalog(model_catalog:discoveries())
  local display_server_url = client_module.normalize_server_url(opts.base_url or "")
  local connection_level = "muted"
  local model_progress = {}
  local request_progress = {}
  local next_request_id = 0
  local last_response
  local destroyed = false
  local definitions, definition_order, alias_definitions =
    definitions_of(opts.models)
  local service_opts = validate_service_opts(opts.service_opts)
  local report = resources.report or function() end
  local dashboard = provider_state.new({ blocks = { {
    type = "field",
    label = "Endpoint",
    value = display_server_url,
    level = connection_level,
  } } }, { report = report })

  local function state_blocks()
    local blocks = { {
      type = "field",
      label = "Endpoint",
      value = display_server_url,
      level = connection_level,
    } }
    local loaded_ids = {}
    for _, model in ipairs(catalog) do
      if loaded(model) then loaded_ids[#loaded_ids + 1] = model.id end
    end
    table.sort(loaded_ids)
    blocks[#blocks + 1] = {
      type = "field",
      label = #loaded_ids <= 1 and "Loaded model" or "Loaded models",
      value = #loaded_ids == 0 and "No model loaded"
        or bounded_text(table.concat(loaded_ids, ", "), 512),
    }
    blocks[#blocks + 1] = {
      type = "field",
      label = "Models",
      value = tostring(vim.tbl_count(model_catalog:snapshot().models))
        .. " available",
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
    return blocks
  end

  local function publish()
    if destroyed then return end
    local ok, err = dashboard:push({ blocks = state_blocks() })
    if not ok then
      report("neoagent llama.cpp dashboard failed: "
        .. tostring(err and err.message or err), vim.log.levels.ERROR)
    end
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
    connection_level = "success"
    publish()
  end

  local catalog_unsubscribe = model_catalog:subscribe(function()
    set_catalog(model_catalog:discoveries())
  end)

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
  local publish_catalog

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
      publish_catalog(catalog)
      return
    end
    if event.event == "download_failed" then
      model_progress[model_id] = nil
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
      publish_catalog(catalog)
    elseif status == "unloaded" then
      model_progress[model_id] = nil
      update_catalog_status(model_id, status, data)
      publish_catalog(catalog)
    end
  end

  local function stop_watcher()
    watcher_generation = watcher_generation + 1
    if watcher_run then watcher_run:cancel() end
    watcher_run = nil
  end

  ensure_watcher = function()
    if destroyed or subscriber_count == 0 or watcher_run then return end
    watcher_generation = watcher_generation + 1
    local generation = watcher_generation
    local client = status_client
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
      end
      return client:watch(router_event):await()
    end, {
      on_done = function(result)
        if generation ~= watcher_generation then return end
        watcher_run = nil
        connection_level = result.ok and "muted" or "error"
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
    if watcher_run then stop_watcher() end
    status_client = client
    ensure_watcher()
    return client
  end

  local function fetch_catalog(client, list_opts)
    local result = client:list(list_opts):await()
    if not result.ok then
      connection_level = "error"
      publish()
      error(result.error, 0)
    end
    return result.value
  end

  function service:state()
    return dashboard:state()
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
        stop_watcher()
      end
    end
  end

  function service:destroy()
    if destroyed then return end
    destroyed = true
    catalog_unsubscribe()
    stop_watcher()
    dashboard:destroy()
    subscriber_count = 0
    catalog = {}
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
    local input = tonumber(
      usage.inputTokens or usage.input_tokens or usage.input)
    local output = tonumber(
      usage.outputTokens or usage.output_tokens or usage.output)
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
    model = require("neoagent.model").assert(
      model, "llama.cpp input Model")
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
        if router_id ~= model.id then
          local request_opts = inner.request_opts
          if type(request_opts) == "function" then
            inner.request_opts = function(context)
              local selected_context = util.copy(context)
              selected_context.request = util.deep_merge(
                context.request, { body = { model = router_id } })
              return util.deep_merge({ body = { model = router_id } },
                request_opts(selected_context))
            end
          else
            inner.request_opts = util.deep_merge(
              { body = { model = router_id } }, request_opts or {})
          end
        end
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
    return require("neoagent.model").assert(
      wrapped, "llama.cpp Model wrapper")
  end

  publish_catalog = function(current, server_url)
    local safe = normalized_catalog(current)
    if type(server_url) == "string" and server_url ~= "" then
      display_server_url = server_url
    end
    local published, err = model_catalog:publish_discoveries(safe, {
      source = "router",
    })
    if published == nil then error(err, 0) end
    return util.copy(catalog)
  end

  service.operations.reload = {
    label = "Reload router catalog",
    description = "Ask the llama.cpp router to rescan its model sources",
    mutating = true,
    run = function(ctx)
      return async.run(function()
        local operation = {
          id = "reload", label = "Reload router catalog",
          state = "running", message = "Reloading router catalog",
        }
        progress(ctx, operation)
        local client = resolved_client(ctx)
        publish_catalog(fetch_catalog(client, { reload = true }),
          client.server_url)
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
        local current = fetch_catalog(client)
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
        local current = fetch_catalog(client)
        current = publish_catalog(current, client.server_url)
        local unloaded = {}
        for _, model in ipairs(current) do
          if model.status.value == "unloaded" then unloaded[#unloaded + 1] = model end
        end
        local selected = ctx.args
        if selected == nil or selected == "" then
          if #unloaded == 0 then
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
        publish_catalog(fetch_catalog(client), client.server_url)
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
        local current = fetch_catalog(client)
        current = publish_catalog(current, client.server_url)
        local loaded_models = {}
        for _, model in ipairs(current) do
          if loaded(model) then loaded_models[#loaded_models + 1] = model end
        end
        local selected = ctx.args
        if selected == nil or selected == "" then
          if #loaded_models == 0 then
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
        publish_catalog(fetch_catalog(client), client.server_url)
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
          local message = "Accept the access terms"
          if details.gated == "manual" then
            message = "Manual approval is required"
          end
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

  return service
end

M.normalize_server_url = client_module.normalize_server_url
M.inference_url = client_module.inference_url

return M
