-- One journal transaction owns admission and release facts. Callers hold the
-- machine coordinator's mutex throughout each operation on this owner.
local M = {}

---@alias Neoagent.WindowsAuthorityGuard fun()

---@class Neoagent.WindowsAuthorityDependencies
---@field mark_execution fun(id: string) Retain volatile machine evidence before launch becomes possible.
---@field execution_exists fun(id: string): boolean False proves a full shutdown since permission to execute.
---@field clear_execution fun(id: string) Remove only after durable confirmation of emptiness.
---@field save fun(state: Neoagent.WindowsRuntimeState)
---@field retire fun(lease: Neoagent.WindowsAuthorityLease)
---@field prune fun(state: Neoagent.WindowsRuntimeState)
---@field acquire fun(id: string): Neoagent.WindowsAuthorityGuard? Returns an owned guard's release operation, or nil for a live peer.
---@field new_job fun(id: string): Neoagent.WindowsJobEvidence
---@field failure fun(stage: string, code?: integer): never
---@field path_key fun(path: string): string
---@field contains fun(root: string, path: string): boolean
---@field overlap fun(left: string, right: string): boolean

---@class Neoagent.WindowsAuthorityJournal
---@field _state Neoagent.WindowsRuntimeState
---@field _deps Neoagent.WindowsAuthorityDependencies
local Journal = {}
Journal.__index = Journal

-- Independent domains must preserve protected objects even when a read-only
-- peer has no write roots. A writer cannot replace its protected pathnames.
---@param protected Neoagent.WindowsAuthorityPolicy
---@param writer Neoagent.WindowsAuthorityPolicy
---@return boolean
function Journal:_conflicting(protected, writer)
  local contains, overlap = self._deps.contains, self._deps.overlap
  for _, boundary in ipairs(protected.deny_write) do
    for _, root in ipairs(writer.write_roots) do
      if overlap(root, boundary) then
        local intersection = contains(root, boundary) and boundary or root
        local denied = false
        for _, denial in ipairs(writer.deny_write) do
          if contains(root, denial) and contains(denial, intersection) then
            denied = true
          end
        end
        if not denied then
          return true
        end
      end
    end
  end
  return false
end

---@param left string[]
---@param right string[]
---@return boolean
function Journal:_same_paths(left, right)
  if #left ~= #right then
    return false
  end
  local key = self._deps.path_key
  local keys = {}
  for _, path in ipairs(left) do
    keys[key(path)] = true
  end
  for _, path in ipairs(right) do
    if not keys[key(path)] then
      return false
    end
  end
  return true
end

-- Same-volume moves retain DACLs. Overlapping writers therefore share one
-- complete write policy; independent policies require disjoint write roots.
---@param left Neoagent.WindowsAuthorityPolicy
---@param right Neoagent.WindowsAuthorityPolicy
---@return boolean
function Journal:_compatible(left, right)
  if self:_same_paths(left.write_roots, right.write_roots) and self:_same_paths(left.deny_write, right.deny_write) then
    return true
  end
  for _, first in ipairs(left.write_roots) do
    for _, second in ipairs(right.write_roots) do
      if self._deps.overlap(first, second) then
        return false
      end
    end
  end
  return not self:_conflicting(left, right) and not self:_conflicting(right, left)
end

---@param policy Neoagent.WindowsAuthorityPolicy
function Journal:admit(policy)
  for _, lease in pairs(self._state.leases) do
    if not self:_compatible(lease.policy, policy) then
      self._deps.failure("lease-policy-conflict", 5)
    end
  end
end

---@param id string
---@param lease Neoagent.WindowsAuthorityLease
function Journal:reserve(id, lease)
  assert(not self._state.leases[id] and lease.job == "unstarted", "Authority already reserved")
  self._state.leases[id] = lease
  self._deps.save(self._state)
end

---@param lease Neoagent.WindowsAuthorityLease
---@param fact "unconfirmed"|"empty"
function Journal:_record(lease, fact)
  local previous = lease.job
  lease.job = fact
  local ok, err = pcall(self._deps.save, self._state)
  if not ok then
    -- An unsuccessful write cannot become an in-memory release proof on a
    -- later cleanup attempt. The native owner still retains its evidence.
    lease.job = previous
    error(err, 0)
  end
end

-- A crash after this write can leave uncertainty even before native creation.
-- Recovery cannot distinguish that interval by probing a missing Job name.
---@param id string
function Journal:permit_launch(id)
  local lease = assert(self._state.leases[id])
  assert(lease.job == "unstarted", "Authority cannot launch another target")
  self._deps.mark_execution(id)
  self:_record(lease, "unconfirmed")
end

---@param id string
---@param job? Neoagent.WindowsJobEvidence
function Journal:finish(id, job)
  local lease = assert(self._state.leases[id])
  if lease.job == "unconfirmed" and (not job or not job:is_empty()) then
    self._deps.failure("lease-job-unconfirmed", 0)
  end
  if job and not job:is_empty() then
    self._deps.failure("lease-job-unconfirmed", 0)
  end
  if lease.job ~= "empty" then
    -- Keep the native observation handle until this fact survives the host.
    self:_record(lease, "empty")
  end
  self._deps.clear_execution(id)
  if job then
    job:close()
  end
  self._deps.retire(lease)
  self._state.leases[id] = nil
  self._deps.prune(self._state)
  self._deps.save(self._state)
end

---@param selected? string Recover one owned invocation without retiring unrelated reservations.
function Journal:recover(selected)
  for id, lease in pairs(self._state.leases) do
    local release = (not selected or selected == id) and self._deps.acquire(id)
    if release then
      local ok, err = pcall(function()
        if lease.job == "unconfirmed" and not self._deps.execution_exists(id) then
          -- Only the protected volatile execution key can establish a full
          -- machine shutdown. A missing Job name during the same boot cannot.
          self:_record(lease, "empty")
          self:finish(id)
        elseif lease.job == "unconfirmed" then
          local job = self._deps.new_job(id)
          if not job:open() then
            self._deps.failure("lease-job-unconfirmed", 2)
          end
          job:stop()
          self:finish(id, job)
        else
          -- Unstarted leases never permitted execution; empty leases carry
          -- durable confirmation. Neither relies on native name availability.
          self:finish(id)
        end
      end)
      release()
      if not ok then
        error(err, 0)
      end
    end
  end
end

---@param state Neoagent.WindowsRuntimeState
---@param deps Neoagent.WindowsAuthorityDependencies
---@return Neoagent.WindowsAuthorityJournal
function M.new(state, deps)
  return setmetatable({ _state = state, _deps = deps }, Journal)
end

return M
