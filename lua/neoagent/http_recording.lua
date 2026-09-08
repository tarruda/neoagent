local async = require("neoagent.async")
local fs = require("neoagent.fs")
local body_capture = require("neoagent.http_recording.body")
local sanitization = require("neoagent.http_recording.sanitize")
local util = require("neoagent.util")

---@class Neoagent.RecordedBody
---@field body? Neoagent.JsonValue
---@field body_encoding? string
---@field body_format? string
---@field redacted? boolean

---@class Neoagent.RecordedRequest: Neoagent.RecordedBody
---@field method string
---@field url string
---@field headers? table<string, string>
---@field body_bytes? integer
---@field timeout_ms? number|false
---@field max_response_bytes? integer

---@class Neoagent.RecordedExchange
---@field type 'exchange'
---@field schema string
---@field version integer
---@field id? string
---@field sequence? integer
---@field started_at? string
---@field operation? Neoagent.RecordingOperation
---@field workspace? {root: string}
---@field request Neoagent.RecordedRequest
---@field context? Neoagent.JsonValue
---@field at_us? integer

---@class Neoagent.RecordedChunk
---@field type 'response_chunk'
---@field at_us integer
---@field index integer
---@field bytes integer

---@class Neoagent.RecordedResponseBody: Neoagent.RecordedBody
---@field type 'response_body'
---@field at_us integer
---@field bytes integer

---@class Neoagent.RecordedResponse: Neoagent.HttpMetadata
---@field type 'response'
---@field at_us integer

---@class Neoagent.RecordedError: Neoagent.Error
---@field detail? string
---@field detail_encoding? string
---@field code? string|number|boolean
---@field exit_code? string|number|boolean
---@field retry_after_ms? string|number|boolean
---@field retryable? string|number|boolean
---@field status? string|number|boolean

---@class Neoagent.RecordedCompletion
---@field type 'complete'
---@field at_us integer
---@field ok boolean
---@field error? Neoagent.RecordedError

---@alias Neoagent.RecordedEvent Neoagent.RecordedExchange|Neoagent.RecordedChunk|Neoagent.RecordedResponseBody|Neoagent.RecordedResponse|Neoagent.RecordedCompletion

local M = {}
---@alias Neoagent.RecordingOperation 'fetch'|'request'
---@alias Neoagent.RecordingContext Neoagent.RequestIdentity|(fun(): Neoagent.RequestIdentity?)

---@class Neoagent.RecordingContextData: table<string, unknown>
---@field workspace? unknown
---@field origin? unknown
---@field credential_response_body? unknown

---@class Neoagent.RecordingYq
---@field available fun(): boolean?
---@field convert fun(path: string, write: (fun(chunk: string): boolean), done: fun(ok: boolean)): unknown

---@class Neoagent.RecorderOptions
---@field config? Neoagent.RecordingConfigInput
---@field directory? string
---@field context? Neoagent.RecordingContext
---@field report? fun(message: string, level: integer): unknown
---@field now? fun(): number
---@field hrtime? fun(): number
---@field yq? Neoagent.RecordingYq

---@class Neoagent.RecordingResponse
---@field status? number
---@field headers? table<string, unknown>
---@field body? unknown
---@field stdout? unknown

---@class Neoagent.RecordingExchange
---@field id string
---@field sequence integer
---@field started_ns number
---@field stage_path string
---@field final_path string
---@field file Neoagent.RegularFile
---@field offset integer
---@field body Neoagent.RecordingBody
---@field sanitizer Neoagent.RecordingSanitizer
---@field failed boolean
---@field closed boolean
---@field finished boolean

---@class Neoagent.Recorder
---@field _format 'yaml'|'json'
---@field _retention 'all'|'rolling'
---@field _directory string
---@field _context? Neoagent.RecordingContext
---@field _report? fun(message: string, level: integer): unknown
---@field _now fun(): number
---@field _hrtime fun(): number
---@field _yq Neoagent.RecordingYq
---@field _exchanges table<Neoagent.RecordingExchange, boolean>
---@field _pending_conversions integer
---@field _destroyed boolean
local Recorder = {}
Recorder.__index = Recorder

local DIRECTORY_MODE = 448 -- 0700
local FILE_MODE = 384 -- 0600
local FORMAT_VERSION = 1
local DIAGNOSTIC_LIMIT = 1024
local global_sequence = 0

---@param self Neoagent.Recorder
---@param message unknown
local function report(self, message)
  if not self._report then return end
  local selected = sanitization.safe_string(message):gsub("%s+", " ")
  if #selected > DIAGNOSTIC_LIMIT then
    selected = selected:sub(1, DIAGNOSTIC_LIMIT - 3) .. "..."
  end
  pcall(self._report, "neoagent: HTTP recording: " .. selected,
    vim.log.levels.ERROR)
end

---@param milliseconds integer
---@return string
local function iso_timestamp(milliseconds)
  local seconds = math.floor(milliseconds / 1000)
  return os.date("!%Y-%m-%dT%H:%M:%S", seconds)
    .. string.format(".%03dZ", milliseconds % 1000)
end

---@param milliseconds integer
---@return string
local function filename_timestamp(milliseconds)
  local seconds = math.floor(milliseconds / 1000)
  return os.date("!%Y%m%dT%H%M%S", seconds)
    .. string.format(".%03dZ", milliseconds % 1000)
end

---@param value unknown
---@param fallback? string
---@return string
local function slug(value, fallback)
  local selected = sanitization.safe_string(value):gsub("[^%w._-]+", "-")
    :gsub("^-+", ""):gsub("-+$", "")
  if selected == "" then selected = fallback or "workspace" end
  if #selected > 48 then selected = selected:sub(1, 48) end
  return selected
end

---@param path string
---@return true?, string?
local function ensure_directory(path)
  local ok, err = fs.ensure_private_directory(path, DIRECTORY_MODE)
  if not ok then return nil, err end
  return true
end

---@param name string
---@return boolean
local function final_recording_name(name)
  local extension = name:match("^%d%d%d%d%d%d%d%dT%d%d%d%d%d%d%.%d%d%dZ%-%d+%-%d+%-.+%.([^.]+)$")
  return extension == "yaml" or extension == "jsonl"
end

---@return Neoagent.RecordingYq
local function default_yq()
  return {
    available = function()
      if vim.fn.executable("yq") ~= 1 then return false end
      local result = vim.system({ "yq", "--version" }, { text = true }):wait(2000)
      local version = ((result and result.stdout) or ""):lower()
      local major = version:find("version v4", 1, true)
        or version:find("version 4", 1, true)
      local mike_farah = version:find("mikefarah", 1, true) ~= nil
      return result and result.code == 0
        and mike_farah
        and major ~= nil
    end,
    convert = function(path, write, done)
      local failed = false
      ---@type vim.SystemObj?
      local process
      process = vim.system({ "yq", "-p=json", "-o=yaml", "-P", ".", path }, {
        text = false,
        timeout = 10000,
        stderr = false,
        stdout = function(err, data)
          if failed then return end
          if err or data and not write(data) then
            failed = true
            if process then pcall(process.kill, process, 15) end
          end
        end,
      }, function(completed)
        done(not failed and completed.code == 0)
      end)
      return process
    end,
  }
end

---@param value? Neoagent.RecordingContext
---@return Neoagent.RequestIdentity
local function context_value(value)
  if type(value) == "function" then
    local ok, selected = pcall(value)
    return ok and type(selected) == "table" and selected or {}
  end
  return type(value) == "table" and value or {}
end

---@param left? Neoagent.RecordingContext
---@param right? Neoagent.RecordingContext
---@return Neoagent.RecordingContextData
local function merge_context(left, right)
  local result = util.copy(context_value(left))
  for key, value in pairs(context_value(right)) do result[key] = value end
  return result
end

---@param exchange Neoagent.RecordingExchange
---@param event Neoagent.RecordedEvent
---@return boolean
function Recorder:_append(exchange, event)
  if exchange.failed or exchange.closed then return false end
  local ok, encoded = pcall(util.json_encode, event)
  if not ok then
    self:_abandon(exchange)
    report(self, "failed to encode exchange " .. exchange.id)
    return false
  end
  return self:_write(exchange, encoded .. "\n")
end

---@param exchange Neoagent.RecordingExchange
function Recorder:_abandon(exchange)
  exchange.failed = true
  exchange.finished = true
  pcall(exchange.body.close, exchange.body, false)
  if not exchange.closed then pcall(exchange.file.close, exchange.file) end
  exchange.closed = true
  self._exchanges[exchange] = nil
end

---@param exchange Neoagent.RecordingExchange
---@param data string
---@return boolean
function Recorder:_write(exchange, data)
  if exchange.failed or exchange.closed then return false end
  local written, err = exchange.file:append(data, exchange.offset)
  if not written then
    self:_abandon(exchange)
    report(self, "failed to append exchange " .. exchange.id .. ": "
      .. tostring(err))
    return false
  end
  exchange.offset = exchange.offset + #data
  return true
end

---@param exchange Neoagent.RecordingExchange
---@return integer
function Recorder:_at(exchange)
  return math.max(0, math.floor((self._hrtime() - exchange.started_ns) / 1000))
end

---@param operation Neoagent.RecordingOperation
---@param request Neoagent.HttpRequest
---@param supplied_context? Neoagent.RecordingContext
---@return Neoagent.RecordingExchange?
function Recorder:_start(operation, request, supplied_context)
  if self._destroyed then return nil end
  local context = merge_context(self._context, supplied_context)
  local workspace
  if context.workspace ~= nil then
    assert(type(context.workspace) == "string" and context.workspace ~= "",
      "recording context workspace must be a non-empty string")
    workspace = fs.canonical(context.workspace)
  end
  local sanitizer, recorded_request = sanitization.new(
    request, context, workspace, self._format)
  global_sequence = global_sequence + 1
  local sequence = global_sequence
  local now = math.floor(self._now())
  local selected_context = sanitizer.context
  local provider = slug(selected_context.provider
    or selected_context.auth_method or "http")
  local scope_directory
  local directories = { self._directory }
  local workspace_directory
  if workspace then
    local workspaces_directory = fs.join(self._directory, "workspaces")
    workspace_directory = require("neoagent.workspace_settings").new({
      directory = workspaces_directory,
      root = workspace,
    }).directory
    scope_directory = fs.join(workspace_directory, "recordings")
    directories[#directories + 1] = workspaces_directory
    directories[#directories + 1] = workspace_directory
  else
    local provider_directory = fs.join(self._directory, "provider")
    local recordings_directory = fs.join(provider_directory, "recordings")
    scope_directory = fs.join(recordings_directory, provider)
    directories[#directories + 1] = provider_directory
    directories[#directories + 1] = recordings_directory
  end
  directories[#directories + 1] = scope_directory
  local day = os.date("!%Y-%m-%d", math.floor(now / 1000))
  local group = workspace and day .. "-"
    .. slug(selected_context.session_id or "unscoped", "unscoped") or day
  local day_directory = fs.join(scope_directory, group)
  directories[#directories + 1] = day_directory
  ---@type boolean?
  local ok = true
  local err
  for _, directory in ipairs(directories) do
    ok, err = ensure_directory(directory)
    if not ok then break end
  end
  if not ok then
    report(self, "failed to create recording directory: " .. tostring(err))
    return nil
  end
  local index_path = workspace_directory
      and fs.join(workspace_directory, "workspace.json") or nil
  if index_path and not vim.uv.fs_stat(index_path) then
    local indexed = fs.atomic_replace(index_path, util.json_encode({
      version = FORMAT_VERSION,
      root = sanitizer.workspace,
    }) .. "\n", { mode = FILE_MODE })
    if not indexed then
      report(self, "failed to write Workspace recording index")
    end
  end
  local origin = slug(selected_context.origin or operation)
  local base = string.format("%s-%06d-%08d-%s-%s",
    filename_timestamp(now), vim.uv.os_getpid(), sequence, provider, origin)
  local extension = self._format == "yaml" and ".yaml" or ".jsonl"
  local final_path = fs.join(day_directory, base .. extension)
  local stage_path = fs.join(day_directory, base .. ".partial.ndjson")
  ---@type Neoagent.RecordedExchange
  local first = {
    schema = "neoagent-http-recording",
    version = FORMAT_VERSION,
    type = "exchange",
    id = tostring(vim.uv.os_getpid()) .. "-" .. tostring(sequence),
    sequence = sequence,
    started_at = iso_timestamp(now),
    operation = operation,
    workspace = sanitizer.workspace
      and { root = sanitizer.workspace } or nil,
    context = selected_context,
    request = recorded_request,
  }
  local encoded_ok, encoded = pcall(util.json_encode, first)
  if not encoded_ok then
    report(self, "failed to encode a recording header")
    return nil
  end
  local created, create_err = fs.atomic_replace(
    stage_path, encoded .. "\n", { mode = FILE_MODE })
  if not created then
    report(self, "failed to create a recording: " .. tostring(create_err))
    return nil
  end
  local file, open_err = fs.open_regular(stage_path, { mode = FILE_MODE })
  if not file then
    pcall(vim.uv.fs_unlink, stage_path)
    report(self, "failed to open a recording: " .. tostring(open_err))
    return nil
  end
  ---@type Neoagent.RecordingExchange
  local exchange = {
    id = assert(first.id),
    sequence = sequence,
    started_ns = self._hrtime(),
    stage_path = stage_path,
    final_path = final_path,
    file = file,
    offset = #encoded + 1,
    body = body_capture.new(stage_path .. ".body", sanitizer.sensitive_response_body),
    sanitizer = sanitizer,
    failed = false,
    closed = false,
    finished = false,
  }
  self._exchanges[exchange] = true
  return exchange
end

---@param exchange Neoagent.RecordingExchange?
---@param data unknown
---@param at_us? integer
function Recorder:_chunk(exchange, data, at_us)
  if not exchange or exchange.finished then return end
  local chunk = type(data) == "string" and data or tostring(data or "")
  local captured = pcall(exchange.body.append, exchange.body, chunk)
  if not captured then
    self:_abandon(exchange)
    report(self, "failed to capture response body for exchange " .. exchange.id)
    return
  end
  local event = {
    type = "response_chunk",
    index = exchange.body.count,
    at_us = at_us or self:_at(exchange),
    bytes = #chunk,
  }
  self:_append(exchange, event)
end

---@param exchange Neoagent.RecordingExchange
---@param at_us integer
---@return boolean
function Recorder:_append_spooled_body(exchange, at_us)
  local header = util.json_encode({
    type = "response_body", at_us = at_us,
    bytes = exchange.body.bytes, body_encoding = "base64",
  })
  if not self:_write(exchange, header:sub(1, -2) .. ',"body":"') then return false end
  local written = exchange.body:write_base64(function(data)
    return self:_write(exchange, data)
  end)
  if not written then
    self:_abandon(exchange)
    report(self, "failed to serialize response body for exchange " .. exchange.id)
    return false
  end
  return self:_write(exchange, '"}\n')
end

---@param exchange Neoagent.RecordingExchange
---@param output Neoagent.RecordingBody?
function Recorder:_conversion_done(exchange, output)
  if output then
    local written, write_err
    if output.file then
      local closed, close_err = output:close(false)
      if closed then
        written, write_err = vim.uv.fs_rename(output.path, exchange.final_path)
      else
        write_err = close_err
      end
    else
      written, write_err = fs.atomic_replace(
        exchange.final_path, assert(output:text()), { mode = FILE_MODE })
    end
    if written then
      pcall(vim.uv.fs_unlink, exchange.stage_path)
      self:_published(exchange)
    else
      report(self, "failed to write YAML recording " .. exchange.id .. ": "
        .. tostring(write_err))
    end
  else
    report(self, "failed to convert recording " .. exchange.id)
  end
end

---@param exchange Neoagent.RecordingExchange
function Recorder:_retain(exchange)
  if self._retention == "all" then return end
  local directory = vim.fs.dirname(exchange.final_path)
  local scan = vim.uv.fs_scandir(directory)
  if not scan then
    report(self, "failed to list previous recordings for " .. exchange.id)
    return
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then break end
    local path = fs.join(directory, name)
    if kind == "file" and path ~= exchange.final_path
        and final_recording_name(name) then
      local called, removed, remove_err, remove_code = pcall(
        vim.uv.fs_unlink, path)
      if not called or not removed and remove_code ~= "ENOENT" then
        report(self, "failed to remove a previous recording for "
          .. exchange.id .. ": " .. tostring(remove_err or removed))
      end
    end
  end
end

---@param exchange Neoagent.RecordingExchange
function Recorder:_published(exchange)
  local retained, retain_err = pcall(self._retain, self, exchange)
  if not retained then
    report(self, "failed to retain rolling recording " .. exchange.id .. ": "
      .. tostring(retain_err))
  end
end

---@param exchange Neoagent.RecordingExchange
function Recorder:_publish(exchange)
  if self._format == "json" then
    local moved, err = vim.uv.fs_rename(exchange.stage_path, exchange.final_path)
    if not moved then
      report(self, "failed to publish recording " .. exchange.id .. ": "
        .. tostring(err))
    else
      self:_published(exchange)
    end
    return
  end
  self._pending_conversions = self._pending_conversions + 1
  local settled = false
  local output = body_capture.new(exchange.stage_path .. ".yaml.body", false)
  ---@param success boolean
  local function done(success)
    if settled then return end
    settled = true
    local completed = pcall(self._conversion_done, self, exchange,
      success and output or nil)
    pcall(output.close, output, false)
    self._pending_conversions = math.max(0, self._pending_conversions - 1)
    if not completed then report(self, "failed to publish converted recording " .. exchange.id) end
  end
  ---@param chunk string
  ---@return boolean
  local function write(chunk)
    if settled then return false end
    local written = pcall(output.append, output, chunk)
    if not written then done(false) end
    return written
  end
  local ok = pcall(self._yq.convert, exchange.stage_path, write, done)
  if not ok then done(false) end
end

---@param result unknown
---@param operation Neoagent.RecordingOperation
---@return Neoagent.RecordingResponse?
local function response_from(result, operation)
  if type(result) ~= "table" then return nil end
  if operation == "fetch" then
    if result.status ~= nil or result.headers ~= nil or result.body ~= nil then
      return {
        status = result.status,
        headers = result.headers or {},
        body = result.body,
      }
    end
    if type(result.error) == "table"
        and type(result.error.response) == "table" then
      return result.error.response
    end
    return nil
  end
  if type(result.response) == "table" then return result.response end
  if type(result.error) == "table"
      and type(result.error.response) == "table" then
    return result.error.response
  end
end

---@param exchange Neoagent.RecordingExchange?
---@param result unknown
---@param operation Neoagent.RecordingOperation
function Recorder:_complete(exchange, result, operation)
  if not exchange or exchange.finished then return end
  local settled_at = self:_at(exchange)
  local response = response_from(result, operation) or {}
  if operation == "fetch" and type(response.body) == "string" then
    self:_chunk(exchange, response.body, settled_at)
  elseif operation == "request" and exchange.body.count == 0 then
    local body = type(response.body) == "string" and response.body
      or type(response.stdout) == "string" and response.stdout or nil
    if body then self:_chunk(exchange, body, settled_at) end
  end
  if exchange.finished then return end
  exchange.finished = true
  local spooled = exchange.body.file ~= nil
  local raw_body = exchange.body:text() or ""
  local sanitized = exchange.sanitizer:response(raw_body, response, result)
  local appended
  if spooled then
    appended = self:_append_spooled_body(exchange, settled_at)
  else
    appended = self:_append(exchange, {
      type = "response_body",
      at_us = settled_at,
      body = sanitized.body.body,
      body_encoding = sanitized.body.body_encoding,
      body_format = sanitized.body.body_format,
      bytes = exchange.body.bytes,
      redacted = sanitized.body.redacted,
    })
  end
  if not appended then return end
  local body_closed = exchange.body:close(true)
  if not body_closed then
    self:_abandon(exchange)
    report(self, "failed to close response body for exchange " .. exchange.id)
    return
  end
  if not self:_append(exchange, {
    type = "response",
    at_us = settled_at,
    status = response.status,
    headers = sanitized.headers,
  }) then return end
  ---@type Neoagent.RecordedCompletion
  local completion = {
    type = "complete",
    at_us = settled_at,
    ok = sanitized.ok,
    error = sanitized.error,
  }
  if not self:_append(exchange, completion) then return end
  local verified = exchange.file:verify_path()
  local closed, close_err = exchange.file:close()
  exchange.closed = true
  self._exchanges[exchange] = nil
  if exchange.failed or not verified or not closed then
    report(self, "failed to close recording " .. exchange.id .. ": "
      .. tostring(close_err or "path identity changed"))
    return
  end
  self:_publish(exchange)
end

---@param exchange Neoagent.RecordingExchange?
---@param result unknown
---@param operation Neoagent.RecordingOperation
function Recorder:_finish(exchange, result, operation)
  local completed = pcall(self._complete, self, exchange, result, operation)
  if not completed then
    if exchange then self:_abandon(exchange) end
    report(self, "failed to finish an exchange")
  end
end

---@generic T: table
---@param value T
---@return T
local function shallow_copy(value)
  local result = {}
  for key, entry in pairs(value or {}) do result[key] = entry end
  return result --[[@as T]]
end

---@param base Neoagent.ByteBackend
---@param context? Neoagent.RecordingContext
---@return Neoagent.ByteBackend
function Recorder:transport(base, context)
  assert(type(base) == "table", "recording transport is required")
  local recorder = self
  ---@generic R
  ---@param operation Neoagent.RecordingOperation
  ---@param start? fun(opts: Neoagent.ByteCall<R>): Neoagent.Run<R, nil>
  ---@return (fun(opts: Neoagent.ByteCall<R>): Neoagent.Run<R, nil>)?
  local function wrap(operation, start)
    if type(start) ~= "function" then return nil end
    return function(opts)
      opts = opts or {}
      local selected = shallow_copy(opts)
      local request = assert(opts.request, "request is required")
      local recorded, exchange = pcall(
        recorder._start, recorder, operation, request, context)
      if not recorded then
        report(recorder, "failed to start an exchange")
        exchange = nil
      end
      local on_chunk, on_done = opts.on_chunk, opts.on_done
      if operation == "request" then
        selected.on_chunk = function(chunk)
          local ok = pcall(recorder._chunk, recorder, exchange, chunk)
          if not ok then report(recorder, "failed to record a response chunk") end
          if on_chunk then on_chunk(chunk) end
        end
      end
      selected.on_done = nil
      local started, child = pcall(function() return start(selected) end)
      if not started then
        local ok = pcall(recorder._finish, recorder, exchange, {
          ok = false,
          error = util.normalize_error(child, "transport"),
        }, operation)
        if not ok then report(recorder, "failed to finish an exchange") end
        error(child, 0)
      end
      ---@cast child Neoagent.Run<R, nil>
      return async.run(function()
        local settled, result = pcall(---@async
        function() return child:await() end)
        if not settled then
          local failure = {
            ok = false,
            error = util.normalize_error(result, "transport"),
          }
          local ok = pcall(
            recorder._finish, recorder, exchange, failure, operation)
          if not ok then report(recorder, "failed to finish an exchange") end
          error(failure.error, 0)
        end
        local ok = pcall(
          recorder._finish, recorder, exchange, result, operation)
        if not ok then report(recorder, "failed to finish an exchange") end
        return result
      end, { on_done = on_done, error_kind = "transport" })
    end
  end
  local wrapped = {
    request = wrap("request", base.request),
    fetch = wrap("fetch", base.fetch),
  }
  wrapped.with_context = function(extra)
    return recorder:transport(base, merge_context(context, extra))
  end
  return wrapped
end

---@return "yaml"|"json"
function Recorder:format()
  return self._format
end

---@return boolean
function Recorder:destroy()
  if self._destroyed then return false end
  self._destroyed = true
  local active = {}
  for exchange in pairs(self._exchanges) do active[#active + 1] = exchange end
  for _, exchange in ipairs(active) do
    self:_finish(exchange, {
      ok = false,
      error = util.error("cancelled", "Recording owner was destroyed"),
    }, "request")
  end
  if self._pending_conversions > 0 then
    vim.wait(5000, function() return self._pending_conversions == 0 end, 10)
  end
  return true
end

---@param opts? Neoagent.RecorderOptions
---@return Neoagent.Recorder?, Neoagent.Error?
function M.new(opts)
  opts = opts or {}
  local selected = opts.config
    or { enabled = false, format = "auto", retention = "rolling" }
  assert(type(selected) == "table", "recording configuration is required")
  if selected.enabled ~= true then return nil end
  local yq = opts.yq or default_yq()
  local available = false
  local requested = selected.format or "auto"
  assert(requested == "auto" or requested == "yaml" or requested == "json",
    "recording format must be auto, yaml, or json")
  if requested ~= "json" then
    local ok, value = pcall(yq.available)
    if ok then available = value == true end
  end
  local format = requested == "json" and "json"
    or requested == "yaml" and "yaml"
    or available and "yaml" or "json"
  if format == "yaml" and not available then
    return nil, util.error("configuration",
      "recording.format is yaml but a compatible yq v4 is unavailable")
  end
  local retention = selected.retention or "rolling"
  assert(retention == "rolling" or retention == "all",
    "recording retention must be rolling or all")
  return setmetatable({
    _format = format,
    _retention = retention,
    _directory = fs.normalize(opts.directory
      or selected.directory
      or vim.fn.stdpath("state") .. "/neoagent"),
    _context = opts.context,
    _report = opts.report,
    _now = opts.now or util.now_ms,
    _hrtime = opts.hrtime or vim.uv.hrtime,
    _yq = yq,
    _exchanges = {},
    _pending_conversions = 0,
    _destroyed = false,
  }, Recorder)
end

return M
