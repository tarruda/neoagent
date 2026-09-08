---@class Applet.SurfaceChange
---@field chrome? boolean

---@class Applet.DomainMember
---@field _flush_requested fun(self: Applet.DomainMember)
---@field surface_changed? fun(self: Applet.DomainMember, opts?: Applet.SurfaceChange): boolean?

---@class Applet.DomainParticipant
---@field value Applet.DomainMember
---@field phase number
---@field order integer
---@field index integer

---@class Applet.DomainOptions
---@field critical? fun(): boolean

---@class Applet.ParticipantOptions
---@field phase? "frame"|"content"|number

---@class Applet.DomainStats
---@field participants integer
---@field active_participants integer
---@field key_observer_active boolean
---@field waiting_for_safe boolean

---@class Applet.InteractionDomain
---@field members table<Applet.DomainMember, Applet.DomainParticipant>
---@field participants Applet.DomainParticipant[]
---@field active table<Applet.DomainMember, true>
---@field active_count integer
---@field next_order integer
---@field dirty table<Applet.DomainMember, true>
---@field group integer
---@field critical? fun(): boolean
---@field scheduled boolean
---@field safe_autocmd? integer
---@field register_pending boolean
---@field key_observer_active boolean
---@field destroyed boolean
---@field key_namespace integer
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

---@param opts? Applet.DomainOptions
---@return Applet.InteractionDomain
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

---@return boolean
function Domain:_start_key_observer()
  if self.key_observer_active or self.destroyed then return false end
  vim.on_key(function(key) self:_track_key(key) end, self.key_namespace)
  self.key_observer_active = true
  return true
end

---@return boolean
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

---@param key string
---@param mode? string
function Domain:_track_key(key, mode)
  if self.destroyed or key ~= '"' then return end
  mode = mode or vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) ~= "n" then return end
  self.register_pending = true
  self:_wait_for_safe()
end

---@param value Applet.DomainMember
---@param opts? Applet.ParticipantOptions
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

---@param value Applet.DomainMember
---@return boolean
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
  for cursor = index, #self.participants do
    local remaining = self.participants[cursor]
    -- The compacted participant array contains every index through its length.
    ---@cast remaining Applet.DomainParticipant
    remaining.index = cursor
  end
  return true
end

---@param value Applet.DomainMember
---@return boolean
function Domain:activate(value)
  assert(not self.destroyed, "interaction domain is destroyed")
  assert(self.members[value], "participant does not belong to this interaction domain")
  if self.active[value] then return false end
  self.active[value] = true
  self.active_count = self.active_count + 1
  if self.active_count == 1 then self:_start_key_observer() end
  return true
end

---@param value Applet.DomainMember
---@return boolean
function Domain:deactivate(value)
  if not self.active[value] then return false end
  self.active[value] = nil
  self.active_count = self.active_count - 1
  assert(self.active_count >= 0, "interaction domain active count is inconsistent")
  if self.active_count == 0 then self:_stop_key_observer() end
  return true
end

---@return Applet.DomainStats
function Domain:_stats()
  return {
    participants = #self.participants,
    active_participants = self.active_count,
    key_observer_active = self.key_observer_active,
    waiting_for_safe = self.safe_autocmd ~= nil,
  }
end

---@return boolean
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

---@param value Applet.DomainMember
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

---@param opts? Applet.SurfaceChange
---@return boolean
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

---@return boolean
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

---@class Applet.DomainModule
local module = { new = Domain.new }

return setmetatable(module, {
  __call = function(_, opts) return Domain.new(opts) end,
})
