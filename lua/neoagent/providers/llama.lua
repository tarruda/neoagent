local async = require("neoagent.async")
local model_definitions = require("neoagent.providers.llama.definitions")
local llama_catalog = require("neoagent.providers.llama.catalog")
local client_module = require("neoagent.providers.llama.client")
local huggingface = require("neoagent.providers.llama.huggingface")
local provider_state = require("neoagent.provider_state")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.LlamaServiceOptions
---@field wait_timeout_ms? integer
---@field download_timeout_ms? integer
---@field poll_interval_ms? integer

---@class Neoagent.LlamaServiceConfig: Neoagent.ProviderServiceConfig, Neoagent.ProviderAuthConfig
---@field catalog? {additions?: table<string, unknown>}

---@class Neoagent.LlamaServiceResources: Neoagent.ProviderServiceResources
---@field catalog Neoagent.ModelCatalog
---@field auth? Neoagent.AuthManager


---@param value unknown
---@return string
local function trimmed(value)
  return type(value) == "string" and util.trim(value) or ""
end

---@param model Neoagent.LlamaCatalogModel
---@return boolean
local function loaded(model)
  return model.status.value == "loaded" or model.status.value == "sleeping"
end

---@param value unknown
---@param maximum integer
---@return string?
local function safe_text(value, maximum)
  if type(value) ~= "string" or value == "" or #value > maximum
      or not util.is_valid_utf8(value)
      or value:find("[%z\1-\31\127]") then
    return nil
  end
  return value
end

---@param value unknown
---@param maximum integer
---@return string
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
---@param model unknown
---@return Neoagent.LlamaCatalogModel?
local function normalized_model(model)
  return llama_catalog.normalize_model(model)
end

---@param raw unknown
---@return Neoagent.LlamaCatalogModel[]
local function normalized_catalog(raw)
  local result = {}
  for _, model in ipairs(type(raw) == "table" and raw or {}) do
    local normalized = normalized_model(model)
    if normalized then result[#result + 1] = normalized end
  end
  return result
end

---@param model Neoagent.LlamaCatalogModel
---@return string?
local function context_label(model)
  local value = llama_catalog.reported_context(model)
  if value then
    return value >= 1000 and string.format("%dk", math.floor(value / 1000 + 0.5))
      or string.format("%d", value)
  end
end

---@param model Neoagent.LlamaCatalogModel
---@return string
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

---@param resolved? Neoagent.AuthConfigured|Neoagent.AuthUnconfigured
---@return Neoagent.RequestOverride?
local function auth_request_opts(resolved)
  if not resolved or resolved.configured ~= true then return nil end
  return resolved.request_opts or {}
end

---@param request_opts? Neoagent.RequestOverride
---@return string?
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

---@async
---@generic O, V
---@param method fun(options: O, done: Neoagent.AwaitCallbacks<V>): fun()?
---@param options O
---@return V
local function interact_await(method, options)
  return async.await(function(done)
    return method(options, done)
  end)
end

---@async
---@generic T
---@param run Neoagent.Run<Neoagent.LlamaValueSuccess<T>|Neoagent.AsyncFailure, nil>
---@return Neoagent.LlamaValueSuccess<T>
local function await_ok(run)
  local result = run:await()
  if not result.ok then error(result.error, 0) end
  return result
end

---@async
---@generic T
---@param run Neoagent.Run<T|Neoagent.AsyncFailure, nil>
---@return T
local function await_value(run)
  local result = run:await()
  if type(result) == "table" and result.ok == false then
    error(result.error, 0)
  end
  return result
end

---@async
---@generic O, V
---@param method fun(options: O, done: Neoagent.AwaitCallbacks<V>): fun()?
---@param options O
---@return V?
local function interact_value(method, options)
  local ok, value = pcall(interact_await, method, options)
  if not ok then
    if type(value) == "table" and value.kind == "cancelled" then return nil end
    error(value, 0)
  end
  return value
end

---@async
---@param ctx Neoagent.ProviderOperationContext
---@param options Neoagent.SelectRequest
---@return string?
local function interact_select(ctx, options)
  return interact_value(ctx.interact.select, options)
end

---@async
---@param ctx Neoagent.ProviderOperationContext
---@param options Neoagent.InputRequest
---@return string?
local function interact_input(ctx, options)
  return interact_value(ctx.interact.input, options)
end

---@async
---@param ctx Neoagent.ProviderOperationContext
---@param options Neoagent.ConfirmRequest
---@return boolean?
local function interact_confirm(ctx, options)
  return interact_value(ctx.interact.confirm, options)
end

---@param ctx Neoagent.ProviderOperationContext
---@param operation Neoagent.ProviderOperationStatus
local function progress(ctx, operation)
  ctx.interact.progress(operation)
end

---@param override? Neoagent.RequestOverride
---@param router_id string
---@return Neoagent.RequestOverride
local function alias_request(override, router_id)
  local result = util.copy(override or {})
  ---@type Neoagent.JsonObject
  local body = { model = router_id }
  result.body = util.deep_merge(body, result.body)
  return result
end

---@param value unknown
---@return Neoagent.LlamaServiceOptions
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
  ---@cast value Neoagent.LlamaServiceOptions
  return util.copy(value)
end

---@param opts Neoagent.LlamaServiceConfig
---@param resources Neoagent.LlamaServiceResources
---@return Neoagent.LlamaService
function M.new(opts, resources)
  opts = opts or {}
  resources = resources or {}
  local model_catalog = assert(resources.catalog,
    "llama.cpp model catalog is required")
  local catalog = normalized_catalog(model_catalog:discoveries())
  local display_server_url = client_module.normalize_server_url(opts.base_url or "")
  ---@type Neoagent.ProviderLevel
  local connection_level = "muted"
  ---@type table<string, Neoagent.ProviderProgressBlock>
  local model_progress = {}
  ---@type table<integer, Neoagent.ProviderProgressBlock>
  local request_progress = {}
  local next_request_id = 0
  ---@type Neoagent.ProviderFieldBlock?
  local last_response
  local destroyed = false
  local definitions, definition_order, alias_definitions =
    model_definitions.collect(opts.catalog and opts.catalog.additions)
  local service_opts = validate_service_opts(opts.service_opts)
  local report = resources.report or function() end
  local dashboard = provider_state.new({ blocks = { {
    type = "field",
    label = "Endpoint",
    value = display_server_url,
    level = connection_level,
  } } }, { report = report })

  ---@return Neoagent.ProviderBlock[]
  local function state_blocks()
    ---@type Neoagent.ProviderBlock[]
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

  ---@param raw unknown
  ---@param resolved_server_url? string
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

  ---@class Neoagent.LlamaService: Neoagent.ProviderService
  local service = {
    id = resources.provider_id or "llama.cpp",
    name = "llama.cpp",
    operations = {},
  }

  ---@type Neoagent.LlamaClient?
  local status_client
  ---@type Neoagent.Run<Neoagent.AsyncSuccess|Neoagent.AsyncFailure, nil>?
  local watcher_run
  local watcher_generation = 0
  local subscriber_count = 0
  ---@type fun()
  local ensure_watcher
  ---@type fun(models: unknown, server_url?: string): Neoagent.LlamaCatalogModel[]
  local publish_catalog

  ---@param resolved? Neoagent.AuthConfigured|Neoagent.AuthUnconfigured
  ---@return Neoagent.LlamaClient
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

  ---@param model_id string
  ---@return Neoagent.LlamaCatalogModel?
  local function catalog_entry(model_id)
    for _, entry in ipairs(catalog) do
      if entry.id == model_id then return entry end
    end
  end

  ---@param model_id string
  ---@param status string
  ---@param data unknown
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

  ---@param event Neoagent.LlamaModelEvent
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

  ---@async
  ---@param ctx Neoagent.ProviderAuthContext
  ---@return Neoagent.LlamaClient
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

  ---@async
  ---@param client Neoagent.LlamaClient
  ---@param list_opts? {reload?: boolean}
  ---@return Neoagent.LlamaModelInfo[]
  local function fetch_catalog(client, list_opts)
    local result = client:list(list_opts):await()
    if not result.ok then
      connection_level = "error"
      publish()
      error(result.error, 0)
    end
    return result.value
  end

  ---@return Neoagent.ProviderState
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

  ---@param model_id string
  ---@return string?
  local function known_model_status(model_id)
    local entry = catalog_entry(model_id)
    return entry and entry.status and entry.status.value or nil
  end

  ---@param usage unknown
  ---@return Neoagent.ProviderFieldBlock?
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
  ---@param model Neoagent.Model
  ---@return Neoagent.Model
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
    ---@param opts Neoagent.StreamOptions
    ---@return Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
    function wrapped:stream(opts)
      opts = opts or {}
      local has_timeout_override = opts.timeout_ms ~= nil
      local timeout = has_timeout_override and opts.timeout_ms
        or model.timeout_ms
      return async.run(
      ---@param run Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
      ---@return Neoagent.ModelResult
      function(run)
        next_request_id = next_request_id + 1
        local request_id = next_request_id
        local status = known_model_status(router_id)
        local inner = util.copy(opts)
        if router_id ~= model.id then
          local request_opts = inner.request_opts
          if type(request_opts) == "function" then
            inner.request_opts = function(context)
              local selected_context = util.copy(context)
              selected_context.request.body = util.deep_merge(
                context.request.body, { model = router_id })
              return alias_request(request_opts(selected_context), router_id)
            end
          else
            inner.request_opts = alias_request(request_opts, router_id)
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
          ---@cast event Neoagent.ModelEvent
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
        if not ok then
          publish()
          error(result, 0)
        end
        if result.ok then
          last_response = response_usage(result.message and result.message.usage)
            or last_response
        end
        publish()
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

  ---@async
  ---@param ctx Neoagent.ProviderOperationContext
  ---@param client Neoagent.LlamaClient
  ---@param catalog_snapshot Neoagent.LlamaCatalogModel[]
  ---@param target Neoagent.LlamaCatalogModel
  ---@return boolean
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

  ---@param model_id string
  ---@return Neoagent.LlamaDefinition?
  local function definition_for(model_id)
    local direct = definitions[model_id]
    if direct then return direct end
    for _, definition in ipairs(alias_definitions) do
      if definition.router_id == model_id then return definition end
    end
  end

  ---@param model Neoagent.LlamaCatalogModel
  ---@return string
  local function select_description(model)
    local description = model_description(model)
    local definition = definition_for(model.id)
    local summary = definition and model_definitions.summary(definition) or nil
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
        local current = publish_catalog(fetch_catalog(client), client.server_url)
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
              description = model_definitions.summary(definitions[id])
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

  ---@param predicate fun(model: Neoagent.LlamaCatalogModel): boolean
  ---@return string[]
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
        local current = publish_catalog(fetch_catalog(client), client.server_url)
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
        local current = publish_catalog(fetch_catalog(client), client.server_url)
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
        ---@async
        ---@param details Neoagent.HuggingFaceDetails
        ---@param quantization? string
        ---@return string?, boolean
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
          local repository, quantization = model_definitions.parse_source(selected)
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

        ---@async
        ---@param details Neoagent.HuggingFaceDetails
        ---@return boolean
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
        local ini = model_definitions.preset_ini(definitions, definition_order)
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
