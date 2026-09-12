local async = require("neoagent.async")
local object = require("neoagent.files.object")
local waiting = require("neoagent.files.wait")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.FileObjectResult
---@field ok true
---@field object? Neoagent.RemoteFile Absent when inspection confirms deletion.

---@class Neoagent.FileBackend
---@field identity string Storage endpoint, API binding and purpose.
---@field optimistic? boolean Explicit stale-input rejection is established for this backend.
---@field upload fun(asset: Neoagent.FileAsset, access: Neoagent.FileAccess, timeout_ms: integer): Neoagent.Run<Neoagent.FileObjectResult, nil>
---@field inspect fun(object: Neoagent.RemoteFile, access: Neoagent.FileAccess, timeout_ms: integer): Neoagent.Run<Neoagent.FileObjectResult, nil>

---@class Neoagent.FileProducer
---@field run? Neoagent.Run<Neoagent.FileRecord, nil>
---@field waiters integer

---@class Neoagent.FileValidation
---@field operation string Content and credential snapshot identity.
---@field at number Monotonic time of the last remote check.

---@class Neoagent.FileManager
---@field backend Neoagent.FileBackend
---@field scope string
---@field store? Neoagent.FileCache
---@field acquire fun(): Neoagent.ProviderUseLease?, Neoagent.Error?
---@field now fun(): number UTC milliseconds.
---@field monotonic fun(): number Milliseconds.
---@field budget_ms integer
---@field concurrency integer
---@field active integer
---@field retired boolean
---@field operations table<string, Neoagent.FileProducer>
---@field records table<string, Neoagent.FileRecord>
---@field validated table<string, Neoagent.FileValidation>
---@field invalidated table<string, table<string, boolean>>
---@field clock_wall number
---@field clock_mono number
local Manager = {}
Manager.__index = Manager

---@param asset Neoagent.FileAsset
---@param access Neoagent.FileAccess
---@return string
function Manager:key(asset, access)
  assert(asset.source.identity == self.scope, "file manager requires its bound workspace")
  assert(object.key(asset.file_id), "file asset requires a SHA-256 identity")
  return vim.fn.sha256(util.json_encode({ self.backend.identity, access.storage_scope, "image", asset.mime_type }))
    .. "/"
    .. asset.file_id
end

-- Persistent mappings may survive credential rotation. Active work and its
-- validation freshness belong to the exact access snapshot that performs it.
---@param key string
---@param access Neoagent.FileAccess
---@return string
local function preparation_key(key, access)
  local names = vim.tbl_keys(access.headers)
  table.sort(names)
  local headers = {}
  for _, name in ipairs(names) do
    headers[#headers + 1] = { name, access.headers[name] }
  end
  return key .. "/" .. vim.fn.sha256(util.json_encode(headers))
end

---@param key string
---@param generation string
function Manager:invalidate(key, generation)
  self.invalidated[key] = self.invalidated[key] or {}
  self.invalidated[key][generation] = true
  if self.records[key] and self.records[key].generation == generation then
    self.records[key], self.validated[key] = nil, nil
  end
end

---@param deadline number
---@return integer
function Manager:remaining(deadline)
  local value = math.floor(deadline - self.monotonic())
  if value <= 0 then
    error(util.error("files", "Image preparation timed out"), 0)
  end
  return math.min(30000, value)
end

---@async
---@param key string
---@param operation_key string
---@param asset Neoagent.FileAsset
---@param access Neoagent.FileAccess
---@param producer Neoagent.FileProducer
---@return Neoagent.FileRecord
function Manager:produce(key, operation_key, asset, access, producer)
  local run = assert(async.current())
  local deadline = self.monotonic() + self.budget_ms
  local lease, lease_err = self.acquire()
  if not lease then
    error(lease_err, 0)
  end
  local active = false
  ---@type number?
  local checked_at
  ---@type Neoagent.Run<Neoagent.FileObjectResult, nil>?
  local child
  ---@async
  ---@param stage Neoagent.Run<Neoagent.FileObjectResult, nil>
  ---@return Neoagent.RunResult<Neoagent.FileObjectResult>
  local function await_stage(stage)
    child = stage
    local result = stage:await()
    checked_at = self.monotonic()
    return result
  end
  local ok, value = pcall(function()
    waiting.until_ready(function()
      return self.active < self.concurrency
    end, deadline, self.monotonic)
    self.active, active = self.active + 1, true
    local wall, mono = self.now(), self.monotonic()
    if math.abs(wall - self.clock_wall - (mono - self.clock_mono)) > 5000 then
      self.validated = {}
    end
    self.clock_wall, self.clock_mono = wall, mono
    local memory_record = self.records[key]
    local record = memory_record or self.store and self.store:read(key)
    local previous = record and record.generation
    local validation = self.validated[key]
    checked_at = validation and validation.operation == operation_key and validation.at or nil
    ---@type Neoagent.RemoteFile?
    local current = record and record.object
    if record and self.invalidated[key] and self.invalidated[key][record.generation] then
      current = nil
    end
    local margin = 60000 + math.max(0, deadline - mono)
    if current and current.state == "failed" then
      error(util.error("files", "Uploaded image processing failed"), 0)
    end
    if current and current.lifetime.kind == "deadline" and assert(current.lifetime.at) <= wall + margin then
      current = nil
    end
    if
      current
      and (
        current.state ~= "ready"
        or not self.backend.optimistic
          and (not checked_at or mono - checked_at >= 300000 or current.lifetime.kind == "unknown")
      )
    then
      local inspected = await_stage(self.backend.inspect(current, access, self:remaining(deadline)))
      if inspected.ok == false then
        error(inspected.error, 0)
      end
      current = inspected.object
      if current and not object.valid(current) then
        error(util.error("files", "Invalid file inspection metadata"), 0)
      end
    end
    if current and current.lifetime.kind == "deadline" and assert(current.lifetime.at) <= self.now() + margin then
      current = nil
    end
    if not current then
      local uploaded = await_stage(self.backend.upload(asset, access, self:remaining(deadline)))
      if uploaded.ok == false then
        error(uploaded.error, 0)
      end
      current = uploaded.object
      if not object.valid(current) then
        error(util.error("files", "Invalid file upload metadata"), 0)
      end
    end
    while current.state == "processing" do
      local poll_at = self.monotonic() + 250
      waiting.until_ready(function()
        return self.monotonic() >= poll_at
      end, deadline, self.monotonic)
      local inspected = await_stage(self.backend.inspect(current, access, self:remaining(deadline)))
      if inspected.ok == false then
        error(inspected.error, 0)
      end
      current = inspected.object
      if not object.valid(current) then
        error(util.error("files", "Uploaded image disappeared during processing"), 0)
      end
    end
    if not object.usable(current, self.now(), 60000) then
      error(util.error("files", "Uploaded image is not ready or expires before dispatch"), 0)
    end
    if self.retired or run:is_cancelled() or self.operations[operation_key] ~= producer then
      error(util.copy(async.cancelled_error), 0)
    end
    ---@type Neoagent.FileRecord
    local result = {
      format = "neoagent-provider-file",
      key = key,
      generation = record and vim.deep_equal(record.object, current) and record.generation
        or vim.fn.sha256((assert(vim.uv.random(32)):gsub(".", function(c)
          return string.format("%02x", c:byte())
        end))),
      object = util.copy(current),
    }
    -- Another credential may finish preparing this content while we await
    -- the backend or cache publication. Keep its newer mapping intact.
    local function can_publish()
      return self.records[key] == memory_record
        and not (self.invalidated[key] and self.invalidated[key][result.generation])
    end
    if self.store and can_publish() and (not record or not vim.deep_equal(record, result)) then
      self.store:publish(result, previous)
    end
    if self.retired or run:is_cancelled() or self.operations[operation_key] ~= producer then
      error(util.copy(async.cancelled_error), 0)
    end
    if can_publish() then
      self.records[key] = result
      self.validated[key] = checked_at and { operation = operation_key, at = checked_at } or nil
    end
    return result
  end)
  local function release()
    if active then
      self.active, active = self.active - 1, false
    end
    lease:release()
  end
  if child and not child:is_done() then
    child:_listen(release)
  else
    release()
  end
  if not ok then
    error(value, 0)
  end
  return value
end

-- Await the producer as a subscriber, never as its parent Run. Cancellation of
-- one subscriber must not propagate to work another request still needs.
---@async
---@param asset Neoagent.FileAsset
---@param access Neoagent.FileAccess
---@param deadline number
---@return Neoagent.FileRecord
function Manager:get(asset, access, deadline)
  if self.retired then
    error(util.error("files", "File manager is retired"), 0)
  end
  asset, access = util.copy(asset), util.copy(access)
  local key = self:key(asset, access)
  local operation_key = preparation_key(key, access)
  ---@type Neoagent.FileProducer?
  local producer = self.operations[operation_key]
  if producer and producer.run and producer.run:is_done() then
    self.operations[operation_key], producer = nil, nil
  end
  if not producer then
    producer = { waiters = 0 }
    self.operations[operation_key] = producer
    ---@async
    ---@param run Neoagent.Run<Neoagent.FileRecord, nil>
    ---@return Neoagent.FileRecord
    local function produce(run)
      producer.run = run
      return self:produce(key, operation_key, asset, access, producer)
    end
    async.run(produce, {
      error_kind = "files",
      on_done = function()
        if self.operations[operation_key] == producer then
          self.operations[operation_key] = nil
        end
      end,
    })
  end
  ---@cast producer Neoagent.FileProducer
  producer.waiters = producer.waiters + 1
  local ok, value = pcall(function()
    local result = waiting.completed(assert(producer.run), deadline, self.monotonic)
    if result.ok == false then
      error(result.error, 0)
    end
    return util.copy(result)
  end)
  producer.waiters = producer.waiters - 1
  if producer.waiters == 0 and not assert(producer.run):is_done() then
    if self.operations[operation_key] == producer then
      self.operations[operation_key] = nil
    end
    assert(producer.run):cancel()
  end
  if not ok then
    error(value, 0)
  end
  return value
end

function Manager:retire()
  if self.retired then
    return
  end
  self.retired = true
  for _, producer in pairs(self.operations) do
    if producer.run then
      producer.run:cancel()
    end
  end
  self.operations, self.records, self.validated, self.invalidated = {}, {}, {}, {}
end

---@class Neoagent.FileManagerOptions
---@field backend Neoagent.FileBackend
---@field scope string
---@field store? Neoagent.FileCache
---@field acquire fun(): Neoagent.ProviderUseLease?, Neoagent.Error?
---@field now? fun(): number
---@field monotonic? fun(): number
---@field budget_ms? integer
---@field concurrency? integer

---@param opts Neoagent.FileManagerOptions
---@return Neoagent.FileManager
function M.new(opts)
  assert(
    type(opts.backend) == "table"
      and type(opts.backend.identity) == "string"
      and type(opts.backend.upload) == "function"
      and type(opts.backend.inspect) == "function",
    "invalid Files backend"
  )
  assert(
    type(opts.scope) == "string" and opts.scope ~= "" and type(opts.acquire) == "function",
    "invalid file manager dependencies"
  )
  assert(
    opts.store == nil
      or type(opts.store) == "table"
        and type(opts.store.read) == "function"
        and type(opts.store.publish) == "function"
        and opts.store.scope == opts.scope,
    "file cache must belong to the manager's workspace"
  )
  local budget, concurrency = opts.budget_ms or 120000, opts.concurrency or 2
  assert(budget > 0 and budget < math.huge and budget % 1 == 0, "invalid preparation budget")
  assert(concurrency > 0 and concurrency < math.huge and concurrency % 1 == 0, "invalid upload concurrency")
  local now, monotonic = opts.now or util.now_ms, opts.monotonic or waiting.now
  return setmetatable(
    {
      backend = opts.backend,
      scope = opts.scope,
      store = opts.store,
      acquire = opts.acquire,
      now = now,
      monotonic = monotonic,
      budget_ms = budget,
      concurrency = concurrency,
      active = 0,
      retired = false,
      operations = {},
      records = {},
      validated = {},
      invalidated = {},
      clock_wall = now(),
      clock_mono = monotonic(),
    },
    Manager
  )
end

return M
