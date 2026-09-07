local async = require("neoagent.async")
local http_client = require("neoagent.transport.http")
local util = require("neoagent.util")

local M = {}
---@class Neoagent.LlamaClientOptions
---@field server_url string
---@field api_key? string
---@field transport? Neoagent.ByteBackend
---@field wait_timeout_ms? number
---@field download_timeout_ms? number
---@field poll_interval_ms? number

---@class Neoagent.LlamaModelStatus: Neoagent.JsonObject
---@field value string

---@class Neoagent.LlamaModelInfo: Neoagent.JsonObject
---@field id string
---@field status Neoagent.LlamaModelStatus

---@class Neoagent.LlamaModelEvent: Neoagent.JsonObject
---@field model string
---@field event string

---@class Neoagent.LlamaProgress
---@field message string
---@field ratio? number
---@field detail? string

---@class Neoagent.LlamaRequestOptions
---@field method? string
---@field body? string
---@field timeout_ms? number|false

---@class Neoagent.LlamaValueSuccess<T>
---@field ok true
---@field value T

---@alias Neoagent.LlamaRequestSuccess Neoagent.LlamaValueSuccess<Neoagent.JsonValue?>

---@alias Neoagent.LlamaListSuccess Neoagent.LlamaValueSuccess<Neoagent.LlamaModelInfo[]>

---@alias Neoagent.LlamaLoadSuccess Neoagent.LlamaValueSuccess<Neoagent.LlamaModelInfo>

---@alias Neoagent.LlamaUnloadSuccess Neoagent.LlamaValueSuccess<true>

local REQUEST_TIMEOUT_MS = 15000
local WAIT_TIMEOUT_MS = 10 * 60 * 1000
local DOWNLOAD_TIMEOUT_MS = 60 * 60 * 1000
local POLL_INTERVAL_MS = 250

---@param path string
---@return string
local function trim_path(path)
  path = path:gsub("/+$", "")
  if path == "/v1" then path = "" end
  if path:sub(-3) == "/v1" then path = path:sub(1, -4) end
  return path
end

---@param value unknown
---@return string
function M.normalize_server_url(value)
  assert(type(value) == "string" and value ~= "",
    "llama.cpp server URL must be a non-empty string")
  assert(#value <= 512 and util.is_valid_utf8(value)
      and not value:find("[%z\1-\32\127]"),
    "llama.cpp server URL must be safe text of at most 512 bytes")
  local scheme, rest = value:match("^(https?)://(.+)$")
  assert(scheme and rest, "Server URL must use http or https")
  rest = rest:gsub("[?#].*$", "")
  local slash = rest:find("/")
  local authority, path
  if slash then
    authority, path = rest:sub(1, slash - 1), rest:sub(slash)
  else
    authority, path = rest, "/"
  end
  assert(authority ~= "", "Server URL must include a host")
  return scheme .. "://" .. authority .. (trim_path(path) == "" and "" or trim_path(path))
end

---@param server_url string
---@return string
function M.inference_url(server_url)
  return M.normalize_server_url(server_url) .. "/v1"
end

---@param payload? Neoagent.JsonValue
---@param fallback string
---@return string
local function payload_error(payload, fallback)
  if type(payload) ~= "table" then return fallback end
  local error = payload.error
  if type(error) == "table" then
    local message, code = error.message, error.code
    error = message or code
  end
  if type(error) == "string" and error ~= "" then return error end
  return fallback
end

---@param value unknown
---@return TypeGuard<Neoagent.LlamaModelInfo>
local function is_model_info(value)
  if type(value) ~= "table" then return false end
  return type(value.id) == "string"
    and type(value.status) == "table"
    and type(value.status.value) == "string"
end

---@async
---@param milliseconds number
local function sleep(milliseconds)
  return async.await(function(done)
    local timer = assert(vim.uv.new_timer())
    timer:start(math.max(1, math.floor(milliseconds)), 0, function()
      timer:stop()
      if not timer:is_closing() then timer:close() end
      done.resolve(true)
    end)
    return function()
      timer:stop()
      if not timer:is_closing() then timer:close() end
    end
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

---@param timeout_ms number
---@return number
local function deadline(timeout_ms)
  return util.now_ms() + timeout_ms
end

---@param value number
---@param action string
---@param model string
local function check_deadline(value, action, model)
  if util.now_ms() < value then return end
  error(util.error("provider",
    "Timed out waiting to " .. action .. " " .. model), 0)
end

---@param data? Neoagent.JsonValue
---@return Neoagent.LlamaProgress?
local function parse_load_progress(data)
  if type(data) ~= "table" then return nil end
  local progress = data.progress
  if type(progress) ~= "table" then return nil end
  local stage = progress.current
  if type(stage) ~= "string" then stage = progress.stage end
  local stages = {}
  if type(progress.stages) == "table" then
    for _, entry in ipairs(progress.stages) do
      if type(entry) == "string" then stages[#stages + 1] = entry end
    end
  end
  local stage_ratio = tonumber(progress.value)
  if stage_ratio then stage_ratio = math.max(0, math.min(1, stage_ratio)) end
  local ratio = stage_ratio
  if type(stage) == "string" and #stages > 0 then
    for index, candidate in ipairs(stages) do
      if candidate == stage then
        ratio = (index - 1 + (stage_ratio or 0)) / #stages
        break
      end
    end
  end
  return {
    message = type(stage) == "string" and ("Loading " .. stage:gsub("_", " ")) or "Loading model",
    ratio = ratio,
  }
end

---@param data? Neoagent.JsonValue
---@return Neoagent.LlamaProgress?
local function parse_download_progress(data)
  if type(data) ~= "table" then return nil end
  local nested = data.progress
  local files = type(nested) == "table" and nested or data
  ---@type number, number
  local done, total = 0, 0
  for _, value in pairs(files) do
    if type(value) == "table" and type(value.done) == "number"
        and type(value.total) == "number" then
      done = done + value.done
      total = total + value.total
    end
  end
  if total <= 0 then return nil end
  return {
    message = "Downloading model",
    ratio = done / total,
    detail = M.format_bytes(done) .. " / " .. M.format_bytes(total),
  }
end

M.parse_load_progress = parse_load_progress
M.parse_download_progress = parse_download_progress

---@param bytes unknown
---@return string
function M.format_bytes(bytes)
  bytes = tonumber(bytes) or 0
  if bytes < 1024 then return string.format("%d B", bytes) end
  local units = { "KiB", "MiB", "GiB", "TiB" }
  local value, unit = bytes / 1024, units[1]
  for index = 2, #units do
    if value < 1024 then break end
    value = value / 1024
    unit = units[index]
  end
  local decimals = value >= 10 and 1 or 2
  return string.format("%." .. decimals .. "f %s", value, unit)
end

---@class Neoagent.LlamaClient
---@field server_url string
---@field api_key? string
---@field transport Neoagent.HttpClient
---@field wait_timeout_ms number
---@field download_timeout_ms number
---@field poll_interval_ms number
local Client = {}
Client.__index = Client

---@param path string
---@param opts? Neoagent.LlamaRequestOptions
---@return Neoagent.Run<Neoagent.LlamaRequestSuccess|Neoagent.AsyncFailure, nil>
function Client:request(path, opts)
  opts = opts or {}
  return async.run(
  ---@return Neoagent.LlamaRequestSuccess
  function()
    local headers = {}
    if self.api_key then headers.Authorization = "Bearer " .. self.api_key end
    if opts.body ~= nil then headers["Content-Type"] = "application/json" end
    local request = {
      url = self.server_url .. path,
      method = opts.method or "GET",
      headers = headers,
      body = opts.body,
      timeout_ms = opts.timeout_ms == nil and REQUEST_TIMEOUT_MS
        or opts.timeout_ms,
    }
    local fetched = self.transport.fetch({ request = request }):await()
    if not fetched.ok then error(fetched.error, 0) end
    if fetched.status and (fetched.status < 200 or fetched.status >= 300) then
      local payload = fetched.body
      local message = payload_error(payload,
        "llama.cpp returned HTTP " .. tostring(fetched.status))
      ---@type Neoagent.ProviderHttpError
      local err = util.error("provider", message)
      err.status = fetched.status
      error(err, 0)
    end
    return { ok = true, value = fetched.body }
  end, { error_kind = "provider" })
end

---@param opts? {reload?: boolean}
---@return Neoagent.Run<Neoagent.LlamaListSuccess|Neoagent.AsyncFailure, nil>
function Client:list(opts)
  opts = opts or {}
  return async.run(
  ---@return Neoagent.LlamaListSuccess
  function()
    local payload = await_ok(self:request(
      "/models" .. (opts.reload and "?reload=1" or ""))).value
    if type(payload) ~= "table" or type(payload.data) ~= "table"
        or not util.is_list(payload.data) then
      error(util.error("provider", "llama.cpp returned an invalid model catalog"), 0)
    end
    local result = {}
    for _, entry in ipairs(payload.data) do
      if not is_model_info(entry) then
        error(util.error("provider", "Server is not running in llama.cpp router mode"), 0)
      end
      result[#result + 1] = entry
    end
    return { ok = true, value = result }
  end, { error_kind = "provider" })
end

---@param model string
---@return Neoagent.Run<Neoagent.LlamaRequestSuccess|Neoagent.AsyncFailure, nil>
function Client:load(model)
  return self:request("/models/load", {
    method = "POST",
    body = util.json_encode({ model = model }),
  })
end

---@param model string
---@return Neoagent.Run<Neoagent.LlamaRequestSuccess|Neoagent.AsyncFailure, nil>
function Client:unload(model)
  return self:request("/models/unload", {
    method = "POST",
    body = util.json_encode({ model = model }),
  })
end

---@param model string
---@return Neoagent.Run<Neoagent.LlamaUnloadSuccess|Neoagent.AsyncFailure, nil>
function Client:unload_and_wait(model)
  return async.run(
  ---@return Neoagent.LlamaUnloadSuccess
  function()
    local expires = deadline(self.wait_timeout_ms)
    await_ok(self:unload(model))
    while true do
      local entry
      for _, candidate in ipairs(await_ok(self:list()).value) do
        if candidate.id == model then entry = candidate break end
      end
      if not entry or entry.status.value == "unloaded" then
        return { ok = true, value = true }
      end
      check_deadline(expires, "unload", model)
      sleep(self.poll_interval_ms)
    end
  end, { error_kind = "provider" })
end

---@param model string
---@return Neoagent.Run<Neoagent.LlamaRequestSuccess|Neoagent.AsyncFailure, nil>
function Client:download(model)
  return self:request("/models", {
    method = "POST",
    body = util.json_encode({ model = model }),
    timeout_ms = 60000,
  })
end

---@param on_event fun(event: Neoagent.LlamaModelEvent)
---@return Neoagent.Run<Neoagent.NoReturn, nil>
function Client:watch(on_event)
  assert(type(on_event) == "function", "llama watch callback is required")
  return async.run(
  ---@param _run Neoagent.Run<Neoagent.NoReturn, nil>
  function(_run)
    local headers = {}
    if self.api_key then headers.Authorization = "Bearer " .. self.api_key end
    local fetched = self.transport.stream({
      request = {
        url = self.server_url .. "/models/sse",
        method = "GET",
        headers = headers,
        timeout_ms = nil,
      },
      on_event = function(value)
        if type(value) == "table" and type(value.model) == "string"
            and type(value.event) == "string" then
          ---@cast value Neoagent.LlamaModelEvent
          on_event(value)
        end
      end,
    }):await()
    if not fetched.ok then error(fetched.error, 0) end
    if fetched.status and (fetched.status < 200 or fetched.status >= 300) then
      error(util.error("provider", payload_error(fetched.body,
        "llama.cpp returned HTTP " .. fetched.status)), 0)
    end
  end, { error_kind = "provider" })
end

---@param model string
---@param on_progress fun(progress: Neoagent.LlamaProgress)
---@return Neoagent.Run<Neoagent.LlamaLoadSuccess|Neoagent.AsyncFailure, nil>
function Client:load_and_wait(model, on_progress)
  assert(type(on_progress) == "function", "llama load progress callback is required")
  return async.run(
  ---@param run Neoagent.Run<Neoagent.LlamaLoadSuccess|Neoagent.AsyncFailure, nil>
  ---@return Neoagent.LlamaLoadSuccess
  function(run)
    local expires = deadline(self.wait_timeout_ms)
    local event_loaded, event_error, event_exit_code = false, nil, nil
    local watcher = async.run(function()
      local ok, err = pcall(self.watch, self, function(event)
        if event.model ~= model then return end
        if event.event ~= "model_status" and event.event ~= "status_change" then return end
        local data = event.data
        if type(data) == "table" then
          if data.status == "loaded" then event_loaded = true end
          if data.status == "unloaded" then
            event_error = "Model failed to load"
            if type(data.exit_code) == "number" then
              event_exit_code = data.exit_code
            end
          end
        end
        local progress = parse_load_progress(data)
        if progress then on_progress(progress) end
      end)
      if not ok then return end
      return err:await()
    end, { error_kind = "provider" })
    run:on_cancel(function()
      watcher:cancel()
      self:unload(model)
    end)

    local ok, result = pcall(function()
      await_ok(self:load(model))
      on_progress({ message = "Loading model" })
      while true do
        local entry
        for _, candidate in ipairs(await_ok(self:list()).value) do
          if candidate.id == model then entry = candidate break end
        end
        if entry and entry.status.value == "loaded" then
          return { ok = true, value = entry }
        end
        if event_loaded and not entry then
          return { ok = true, value = { id = model, status = { value = "loaded" } } }
        end
        if entry and entry.status.failed or event_error then
          local exit_code = entry and entry.status.exit_code or event_exit_code
          if type(exit_code) ~= "number" then
            error(util.error("provider", event_error or "Model failed to load"), 0)
          end
          error(util.error("provider",
            "Model exited with code " .. tostring(exit_code)), 0)
        end
        check_deadline(expires, "load", model)
        sleep(self.poll_interval_ms)
      end
    end)
    watcher:cancel()
    if not ok then error(result, 0) end
    if result.ok then on_progress({ message = "Model loaded", ratio = 1 }) end
    return result
  end, { error_kind = "provider" })
end

---@param model string
---@param on_progress fun(progress: Neoagent.LlamaProgress)
---@return Neoagent.Run<Neoagent.LlamaListSuccess|Neoagent.AsyncFailure, nil>
function Client:download_and_wait(model, on_progress)
  assert(type(on_progress) == "function", "llama download progress callback is required")
  return async.run(
  ---@param run Neoagent.Run<Neoagent.LlamaListSuccess|Neoagent.AsyncFailure, nil>
  ---@return Neoagent.LlamaListSuccess
  function(run)
    local finished, failure, saw_downloading = false, nil, false
    local expires = deadline(self.download_timeout_ms)
    local watcher = async.run(function()
      local ok, err = pcall(self.watch, self, function(event)
        if event.model ~= model then return end
        if event.event == "download_finished" then
          finished = true
        elseif event.event == "download_failed" then
          failure = payload_error(event.data, "Download failed")
        elseif event.event == "download_progress" then
          saw_downloading = true
          local progress = parse_download_progress(event.data)
          if progress then on_progress(progress) end
        end
      end)
      if not ok then return end
      return err:await()
    end, { error_kind = "provider" })
    run:on_cancel(function()
      watcher:cancel()
      self:unload(model)
    end)

    local ok, result = pcall(function()
      -- Snapshot the router list before the command so a pre-existing idle
      -- model is never mistaken for a completed download by the fallback.
      local prior = {}
      for _, candidate in ipairs(await_ok(self:list()).value) do
        prior[candidate.id] = candidate.status.value
      end
      await_ok(self:download(model))
      on_progress({ message = "Downloading model" })
      while true do
        if failure then
          error(util.error("provider", failure), 0)
        end
        local models = await_ok(self:list()).value
        local entry
        for _, candidate in ipairs(models) do
          if candidate.id == model then entry = candidate break end
        end
        if entry and entry.status.value == "downloading" then
          saw_downloading = true
          local progress = parse_download_progress(entry.status.progress)
          if progress then on_progress(progress) end
        elseif finished or (entry and (saw_downloading
            or prior[model] ~= entry.status.value)) then
          return {
            ok = true,
            value = await_ok(self:list({ reload = true })).value,
          }
        end
        check_deadline(expires, "download", model)
        sleep(self.poll_interval_ms)
      end
    end)
    watcher:cancel()
    if not ok then error(result, 0) end
    if result.ok then on_progress({ message = "Download complete", ratio = 1 }) end
    return result
  end, { error_kind = "provider" })
end

---@param opts Neoagent.LlamaClientOptions
---@return Neoagent.LlamaClient
function M.new(opts)
  opts = opts or {}
  assert(type(opts.server_url) == "string" and opts.server_url ~= "",
    "llama.cpp server URL is required")
  local wait_timeout_ms = opts.wait_timeout_ms or WAIT_TIMEOUT_MS
  local download_timeout_ms = opts.download_timeout_ms or opts.wait_timeout_ms
    or DOWNLOAD_TIMEOUT_MS
  local poll_interval_ms = opts.poll_interval_ms or POLL_INTERVAL_MS
  assert(type(wait_timeout_ms) == "number" and wait_timeout_ms > 0,
    "llama.cpp wait_timeout_ms must be positive")
  assert(type(download_timeout_ms) == "number" and download_timeout_ms > 0,
    "llama.cpp download_timeout_ms must be positive")
  assert(type(poll_interval_ms) == "number" and poll_interval_ms > 0,
    "llama.cpp poll_interval_ms must be positive")
  return setmetatable({
    server_url = M.normalize_server_url(opts.server_url),
    api_key = opts.api_key,
    transport = http_client.new(opts.transport),
    wait_timeout_ms = wait_timeout_ms,
    download_timeout_ms = download_timeout_ms,
    poll_interval_ms = poll_interval_ms,
  }, Client)
end

return M
