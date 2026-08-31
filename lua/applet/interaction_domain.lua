local Domain = {}
Domain.__index = Domain

local blocked_modes = {
  v = true,
  V = true,
  ["\22"] = true,
  s = true,
  S = true,
  ["\19"] = true,
}

local phases = { frame = 1, content = 2 }

local sequence = 0

function Domain.new(opts)
  opts = opts or {}
  sequence = sequence + 1
  local group = vim.api.nvim_create_augroup("AppletDomain" .. sequence, { clear = true })
  local self = setmetatable({
    members = {},
    participants = {},
    active = {},
    active_count = 0,
    next_order = 0,
    dirty = {},
    group = group,
    critical = opts.critical,
    scheduled = false,
    safe_autocmd = nil,
    register_pending = false,
    key_observer_active = false,
    destroyed = false,
  }, Domain)
  self.key_namespace = vim.api.nvim_create_namespace("applet-domain-key-" .. sequence)
  return self
end

function Domain:_start_key_observer()
  if self.key_observer_active or self.destroyed then return false end
  vim.on_key(function(key) self:_track_key(key) end, self.key_namespace)
  self.key_observer_active = true
  return true
end

function Domain:_stop_key_observer()
  if not self.key_observer_active then return false end
  vim.on_key(nil, self.key_namespace)
  self.key_observer_active = false
  self.register_pending = false
  if self.safe_autocmd and next(self.dirty) == nil then
    pcall(vim.api.nvim_del_autocmd, self.safe_autocmd)
    self.safe_autocmd = nil
  end
  return true
end

function Domain:_track_key(key, mode)
  if self.destroyed or key ~= '"' then return end
  mode = mode or vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) ~= "n" then return end
  self.register_pending = true
  self:_wait_for_safe()
end

function Domain:add(value, opts)
  assert(not self.destroyed, "interaction domain is destroyed")
  opts = opts or {}
  assert(type(opts) == "table", "interaction participant options must be a table")
  local phase = opts.phase or "content"
  phase = phases[phase] or phase
  assert(type(phase) == "number" and phase >= 1,
    "interaction participant phase must be frame, content, or a positive number")
  local current = self.members[value]
  if current then
    current.phase = phase
    return
  end
  self.next_order = self.next_order + 1
  local participant = {
    value = value,
    phase = phase,
    order = self.next_order,
    index = #self.participants + 1,
  }
  self.members[value] = participant
  self.participants[#self.participants + 1] = participant
end

function Domain:remove(value)
  local participant = self.members[value]
  self.dirty[value] = nil
  self:deactivate(value)
  self.members[value] = nil
  if not participant then return false end
  local index = participant.index
  assert(self.participants[index] == participant,
    "interaction participant index is inconsistent")
  table.remove(self.participants, index)
  participant.index = nil
  for cursor = index, #self.participants do
    self.participants[cursor].index = cursor
  end
  return true
end

function Domain:activate(value)
  assert(not self.destroyed, "interaction domain is destroyed")
  assert(self.members[value], "participant does not belong to this interaction domain")
  if self.active[value] then return false end
  self.active[value] = true
  self.active_count = self.active_count + 1
  if self.active_count == 1 then self:_start_key_observer() end
  return true
end

function Domain:deactivate(value)
  if not self.active[value] then return false end
  self.active[value] = nil
  self.active_count = self.active_count - 1
  assert(self.active_count >= 0, "interaction domain active count is inconsistent")
  if self.active_count == 0 then self:_stop_key_observer() end
  return true
end

function Domain:_stats()
  return {
    participants = #self.participants,
    active_participants = self.active_count,
    key_observer_active = self.key_observer_active,
    waiting_for_safe = self.safe_autocmd ~= nil,
  }
end

function Domain:is_safe()
  if self.destroyed or self.register_pending then return false end
  if vim.fn.pumvisible() == 1 then return false end
  if self.critical and self.critical() then return false end
  local mode = vim.api.nvim_get_mode().mode
  if blocked_modes[mode] or mode:sub(1, 2) == "no" then return false end
  return true
end

function Domain:_wait_for_safe()
  if self.safe_autocmd or self.destroyed then return end
  local id
  id = vim.api.nvim_create_autocmd("SafeState", {
    group = self.group,
    once = true,
    callback = function()
      if self.safe_autocmd == id then self.safe_autocmd = nil end
      self.register_pending = false
      self:flush()
    end,
  })
  self.safe_autocmd = id
end

function Domain:request(value)
  if self.destroyed then return end
  assert(self.members[value], "participant does not belong to this interaction domain")
  self.dirty[value] = true
  if self.scheduled then return end
  self.scheduled = true
  vim.schedule(function()
    self.scheduled = false
    self:flush()
  end)
end

function Domain:surfaces_changed(opts)
  if self.destroyed then return false end
  local participants = {}
  for index, participant in ipairs(self.participants) do
    participants[index] = participant
  end
  for _, participant in ipairs(participants) do
    local value = participant.value
    if self.members[value] == participant and type(value.surface_changed) == "function" then
      value:surface_changed(opts)
    end
  end
  return true
end

function Domain:flush()
  if self.destroyed then return false end
  if not self:is_safe() then
    self:_wait_for_safe()
    return false
  end
  if self.safe_autocmd then
    pcall(vim.api.nvim_del_autocmd, self.safe_autocmd)
    self.safe_autocmd = nil
  end
  local pending = self.dirty
  self.dirty = {}
  local ordered = {}
  for value in pairs(pending) do
    local participant = self.members[value]
    if participant then ordered[#ordered + 1] = participant end
  end
  table.sort(ordered, function(left, right)
    if left.phase == right.phase then return left.order < right.order end
    return left.phase < right.phase
  end)
  for _, participant in ipairs(ordered) do
    local value = participant.value
    if self.members[value] == participant then value:_flush_requested() end
  end
  return true
end

function Domain:destroy()
  if self.destroyed then return end
  self:_stop_key_observer()
  self.destroyed = true
  pcall(vim.api.nvim_del_augroup_by_id, self.group)
  self.members, self.dirty, self.participants, self.active = {}, {}, {}, {}
  self.active_count = 0
end

return setmetatable({ new = Domain.new }, {
  __call = function(_, opts) return Domain.new(opts) end,
})
