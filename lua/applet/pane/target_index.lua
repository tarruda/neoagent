---@class Applet.TargetIndexEntry
---@field key string
---@field target Applet.InputTarget
---@field rank integer
---@field seen integer
---@field rows table<number, Applet.Rectangle[]>
---@field large Applet.Rectangle[]

---@class Applet.TargetIndex
---@field entries table<string, Applet.TargetIndexEntry>
---@field rows table<number, table<string, Applet.TargetIndexEntry>>
---@field large table<string, Applet.TargetIndexEntry>
---@field generation integer
---@field source? table<string, Applet.InputTarget>
---@field order? string[]
local Index = {}
Index.__index = Index
local M = {}
local bucket_height = 64
local maximum_span = 64

---@return Applet.TargetIndex
function M.new()
  return setmetatable({ entries = {}, rows = {}, large = {}, generation = 0 }, Index)
end

---@param self Applet.TargetIndex
---@param entry Applet.TargetIndexEntry
local function remove(self, entry)
  for row in pairs(entry.rows) do
    local bucket = self.rows[row]
    bucket[entry.key] = nil
    if next(bucket) == nil then
      self.rows[row] = nil
    end
  end
  self.large[entry.key] = nil
  self.entries[entry.key] = nil
end

---@param self Applet.TargetIndex
---@param entry Applet.TargetIndexEntry
local function insert(self, entry)
  self.entries[entry.key] = entry
  for _, rectangle in ipairs(entry.target.rectangles) do
    if rectangle.height > 0 then
      local first = math.floor(rectangle.row / bucket_height)
      local last = math.floor((rectangle.row + rectangle.height - 1) / bucket_height)
      -- Large spans stay in one list instead of allocating by document height.
      if last - first > maximum_span then
        entry.large[#entry.large + 1] = rectangle
        self.large[entry.key] = entry
      else
        for row = first, last do
          local rectangles = entry.rows[row]
          if not rectangles then
            rectangles = {}
            entry.rows[row] = rectangles
            self.rows[row] = self.rows[row] or {}
            self.rows[row][entry.key] = entry
          end
          rectangles[#rectangles + 1] = rectangle
        end
      end
    end
  end
end

---@param layout Applet.InputLayout
function Index:refresh(layout)
  local order = layout.hit_order or layout.target_order
  if self.source == layout.targets and self.order == order then
    return
  end
  self.generation = self.generation + 1
  for rank, key in ipairs(order) do
    local target = layout.targets[key]
    local entry = self.entries[key]
    if target and (not entry or entry.seen ~= self.generation) then
      if not entry or entry.target ~= target then
        if entry then
          remove(self, entry)
        end
        entry = { key = key, target = target, rank = rank, seen = self.generation, rows = {}, large = {} }
        insert(self, entry)
      else
        entry.rank = rank
        entry.seen = self.generation
      end
    end
  end
  for _, entry in pairs(self.entries) do
    if entry.seen ~= self.generation then
      remove(self, entry)
    end
  end
  self.source, self.order = layout.targets, order
end

---@param row integer
---@param col integer
---@return Applet.InputTarget?
function Index:at(row, col)
  ---@type Applet.TargetIndexEntry?, Applet.TargetIndexEntry?, number?
  local hit, nearest, distance
  ---@param entry Applet.TargetIndexEntry
  ---@param rectangles Applet.Rectangle[]
  local function visit(entry, rectangles)
    if entry.target.disabled then
      return
    end
    for _, rectangle in ipairs(rectangles) do
      if row >= rectangle.row and row < rectangle.row + rectangle.height then
        if col >= rectangle.col and col < rectangle.col + rectangle.width then
          if not hit or entry.rank < hit.rank then
            hit = entry
          end
        elseif entry.target.role == "menuitem" then
          local candidate = col < rectangle.col and rectangle.col - col or col - (rectangle.col + rectangle.width - 1)
          if not distance or candidate < distance or candidate == distance and entry.rank < assert(nearest).rank then
            nearest, distance = entry, candidate
          end
        end
      end
    end
  end
  local bucket = math.floor(row / bucket_height)
  for _, entry in pairs(self.rows[bucket] or {}) do
    visit(entry, assert(entry.rows[bucket]))
  end
  for _, entry in pairs(self.large) do
    visit(entry, entry.large)
  end
  return hit and hit.target or nearest and nearest.target or nil
end

return M
