local transport = require("applet.image.transport")
local detect = require("applet.image.detect")
local cell_size = require("applet.image.cell_size")
local geometry = require("applet.image.geometry")

local Kitty = {}
Kitty.__index = Kitty

local uv = vim.uv or vim.loop
local MAX_PORTABLE_ID = 2147483647

local function portable_id(value)
  return ((value - 1) % MAX_PORTABLE_ID) + 1
end

local next_content = portable_id(uv.os_getpid() * 65537 + 1000000)

local function increment(value)
  return (value % MAX_PORTABLE_ID) + 1
end

local function injected_schedule(callback)
  local active = true
  vim.schedule(function()
    if active then callback() end
  end)
  return function() active = false end
end

function Kitty.new(opts)
  opts = opts or {}
  assert(opts.cell_width == nil
      or type(opts.cell_width) == "number" and opts.cell_width > 0,
    "cell_width must be positive")
  assert(opts.cell_height == nil
      or type(opts.cell_height) == "number" and opts.cell_height > 0,
    "cell_height must be positive")
  local explicit_write = opts.write ~= nil
  local output_available
  if explicit_write then
    output_available = true
  else
    output_available = (opts.transport_available or transport.available)()
  end
  local declared = opts.available
  if declared == nil then declared = detect.eligible(opts.uis) end
  local available = output_available and declared
  local schedule_output = opts.schedule_output
  if not schedule_output then
    schedule_output = explicit_write and injected_schedule or transport.schedule
  end
  local content_id
  if opts.first_content_id then
    content_id = portable_id(opts.first_content_id)
  end
  return setmetatable({
    name = "kitty",
    available = available == true,
    write = opts.write or transport.write,
    schedule_output = schedule_output,
    envelope = detect.envelope(opts.env),
    cell_width = opts.cell_width,
    cell_height = opts.cell_height,
    cell_size = opts.cell_size or cell_size.get,
    next_content = content_id,
    next_placement = portable_id(opts.first_placement_id or 1),
    resources = {},
    owners = {},
    pending = {},
    redraws = {},
    sequence = 0,
    destroyed = false,
  }, Kitty)
end

function Kitty:_content_id()
  local id = self.next_content or next_content
  if self.next_content then
    self.next_content = increment(id)
  else
    next_content = increment(id)
  end
  return id
end

function Kitty:_placement_id()
  local id = self.next_placement
  self.next_placement = increment(id)
  return id
end

function Kitty:set_error_handler(callback)
  assert(type(callback) == "function", "error handler must be a function")
  self.on_error = callback
end

function Kitty:_fail(err)
  if self.destroyed or not self.available then return end
  self.available = false
  self.last_error = tostring(err or "terminal output failed")
  for _, record in pairs(self.resources) do record.uploaded = false end
  self.owners = {}
  self.pending = {}
  self.redraws = {}
  if self.on_error then pcall(self.on_error, self.last_error) end
end

function Kitty:_command(parameters, payload)
  return transport.envelope(
    transport.command(parameters, payload), self.envelope)
end

function Kitty:_resource(resource)
  assert(type(resource) == "table" and type(resource.data) == "string",
    "Kitty resources require image bytes")
  local record = self.resources[resource]
  if not record then
    record = {
      resource = resource,
      content_id = self:_content_id(),
      uploaded = false,
      released = false,
    }
    self.resources[resource] = record
  end
  return record
end

function Kitty:_upload(record, output, uploads)
  if record.uploaded or uploads[record] then return end
  uploads[record] = true
  local chunks = transport.chunks(record.resource.data)
  for index, payload in ipairs(chunks) do
    local command = { m = index < #chunks and 1 or 0, q = 2 }
    if index == 1 then
      command.a = "t"
      command.f = 100
      command.i = record.content_id
    end
    output[#output + 1] = self:_command(command, payload)
  end
end

function Kitty:_placement_output(placement)
  local dimensions = placement.geometry
  local command = {
    a = "p",
    C = 1,
    c = dimensions.columns,
    i = placement.record.content_id,
    p = placement.id,
    q = 2,
    r = dimensions.rows,
  }
  if dimensions.source_width then
    command.x = dimensions.source_x
    command.y = dimensions.source_y
    command.w = dimensions.source_width
    command.h = dimensions.source_height
  end
  local sequence = ("\27%s\27[%d;%dH%s\27%s"):format(
    "7", dimensions.screen_row, dimensions.screen_col,
    transport.command(command), "8")
  return transport.envelope(sequence, self.envelope)
end

function Kitty:_delete_placement(placement)
  return self:_command({
    a = "d",
    d = "i",
    i = placement.record.content_id,
    p = placement.id,
    q = 2,
  })
end

function Kitty:_delete_content(record)
  return self:_command({
    a = "d",
    d = "I",
    i = record.content_id,
    q = 2,
  })
end

function Kitty:cell_dimensions()
  local ok, detected = pcall(self.cell_size)
  if not ok or type(detected) ~= "table" then detected = nil end
  return {
    width = self.cell_width or detected and detected.width or 1,
    height = self.cell_height or detected and detected.height or 2,
  }
end

local function sorted_placements(placements)
  local result = {}
  for index, placement in ipairs(placements or {}) do result[index] = placement end
  table.sort(result, function(left, right)
    local a, b = left.geometry, right.geometry
    if a.screen_row == b.screen_row then
      if a.screen_col == b.screen_col then return left.id < right.id end
      return a.screen_col < b.screen_col
    end
    return a.screen_row < b.screen_row
  end)
  return result
end

function Kitty:_candidate(requests)
  local cells = self:cell_dimensions()
  local result = {}
  for _, request in ipairs(requests) do
    local dimensions = geometry.calculate(request,
      request.cell_width or cells.width,
      request.cell_height or cells.height)
    if dimensions then
      result[#result + 1] = {
        key = request.key,
        id = self:_placement_id(),
        record = self:_resource(request.resource),
        geometry = dimensions,
      }
    end
  end
  return sorted_placements(result)
end

function Kitty:_queue(owner, placements)
  self.sequence = self.sequence + 1
  self.pending[owner] = {
    owner = owner,
    placements = placements,
    sequence = self.sequence,
  }
  self.redraws[owner] = nil
  self:_schedule_output()
end

function Kitty:replace(owner, requests)
  assert(not self.destroyed, "Kitty backend is destroyed")
  assert(owner ~= nil, "Kitty presentation owner is required")
  assert(type(requests) == "table" and vim.islist(requests),
    "Kitty placements must be a list")
  self:_queue(owner, self:_candidate(requests))
end

function Kitty:clear(owner)
  if self.destroyed then return false end
  assert(owner ~= nil, "Kitty presentation owner is required")
  local changed = self.pending[owner] ~= nil or self.owners[owner] ~= nil
  if changed then self:_queue(owner, {}) end
  return changed
end

function Kitty:redraw(owner)
  if self.destroyed or self.pending[owner] or not self.owners[owner] then
    return false
  end
  self.sequence = self.sequence + 1
  self.redraws[owner] = self.sequence
  self:_schedule_output()
  return true
end

function Kitty:release(resource)
  if self.destroyed then return end
  local record = self.resources[resource]
  if not record then return end
  record.released = true
  self:_schedule_output()
end

function Kitty:_schedule_output()
  if self.output_operation or self.destroyed or not self.available then return end
  local operation = {}
  self.output_operation = operation
  local ok, cancel = pcall(self.schedule_output, function(err)
    if self.output_operation ~= operation then return end
    self.output_operation = nil
    self:_flush_output(err)
  end)
  if not ok then
    self.output_operation = nil
    self:_fail(cancel)
  elseif self.output_operation == operation then
    operation.cancel = cancel
  end
end

function Kitty:_take_pending()
  local result = {}
  for owner, operation in pairs(self.pending) do
    result[#result + 1] = operation
    self.pending[owner] = nil
  end
  table.sort(result, function(left, right)
    return left.sequence < right.sequence
  end)
  return result
end

function Kitty:_take_redraws(replaced)
  local result = {}
  for owner, sequence in pairs(self.redraws) do
    self.redraws[owner] = nil
    if not replaced[owner] and self.owners[owner] then
      result[#result + 1] = {
        sequence = sequence,
        placements = sorted_placements(self.owners[owner].placements),
      }
    end
  end
  table.sort(result, function(left, right)
    return left.sequence < right.sequence
  end)
  return result
end

local function used_records(owners)
  local result = {}
  for _, presentation in pairs(owners) do
    for _, placement in ipairs(presentation.placements) do
      result[placement.record] = true
    end
  end
  return result
end

function Kitty:_write(output)
  if #output == 0 then return true end
  local ok, result = pcall(self.write, table.concat(output))
  if not ok then return false, result end
  if result == false then return false, "terminal output write failed" end
  return true
end

function Kitty:_flush_output(schedule_error)
  if schedule_error then
    self:_fail(schedule_error)
    return false
  end
  local operations = self:_take_pending()
  local replaced, future = {}, {}
  for owner, presentation in pairs(self.owners) do future[owner] = presentation end
  for _, operation in ipairs(operations) do
    replaced[operation.owner] = true
    future[operation.owner] = #operation.placements > 0
        and { placements = operation.placements } or nil
  end
  local redraws = self:_take_redraws(replaced)
  local output, uploads = {}, {}
  for _, operation in ipairs(operations) do
    for _, placement in ipairs(operation.placements) do
      self:_upload(placement.record, output, uploads)
      output[#output + 1] = self:_placement_output(placement)
    end
  end
  for _, redraw in ipairs(redraws) do
    for _, placement in ipairs(redraw.placements) do
      self:_upload(placement.record, output, uploads)
      output[#output + 1] = self:_placement_output(placement)
    end
  end
  for _, operation in ipairs(operations) do
    local current = self.owners[operation.owner]
    for _, placement in ipairs(current and current.placements or {}) do
      output[#output + 1] = self:_delete_placement(placement)
    end
  end

  local used = used_records(future)
  local unused = {}
  for _, record in pairs(self.resources) do
    if not used[record] then
      unused[#unused + 1] = record
    end
  end
  table.sort(unused, function(left, right)
    return left.content_id < right.content_id
  end)
  for _, record in ipairs(unused) do
    if record.uploaded then
      output[#output + 1] = self:_delete_content(record)
    end
  end

  local written, err = self:_write(output)
  if not written then
    self:_fail(err)
    return false
  end
  for record in pairs(uploads) do record.uploaded = true end
  for _, record in ipairs(unused) do
    record.uploaded = false
    if record.released then self.resources[record.resource] = nil end
  end
  self.owners = future
  return true
end

function Kitty:destroy()
  if self.destroyed then return end
  local operation = self.output_operation
  self.output_operation = nil
  if operation and operation.cancel then pcall(operation.cancel) end
  local output = {}
  for _, record in pairs(self.resources) do
    if record.uploaded then output[#output + 1] = self:_delete_content(record) end
  end
  self:_write(output)
  self.destroyed = true
  self.available = false
  self.resources = {}
  self.owners = {}
  self.pending = {}
  self.redraws = {}
end

local function diagnostics()
  return { {
    level = "ok",
    message = "Kitty graphics backend is selected",
  } }
end

return setmetatable({ new = Kitty.new, diagnostics = diagnostics }, {
  __call = function(_, opts) return Kitty.new(opts) end,
})
