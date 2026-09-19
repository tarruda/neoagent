local activity = require("neoagent.tools.activity_presentation")

---@class Neoagent.EditPatchLine
---@field kind "add"|"delete"|"context"
---@field number integer
---@field text string

---@class Neoagent.EditPatchSeparator
---@field kind "separator"

---@alias Neoagent.EditPatchRow Neoagent.EditPatchLine|Neoagent.EditPatchSeparator

---@class Neoagent.ToolEditPresentation
---@field kind "edit"
---@field path string
---@field rows Neoagent.EditPatchRow[]
---@field added integer
---@field removed integer
---@field truncated boolean

local M = {}

---@param patch unknown
---@return Neoagent.EditPatchRow[]
local function patch_rows(patch)
  if type(patch) ~= "string" or patch == "" then
    return {}
  end
  ---@type Neoagent.EditPatchRow[]
  local rows = {}
  local old_number, new_number = 0, 0
  local have_hunk = false
  for _, line in ipairs(vim.split(patch, "\n", { plain = true })) do
    local old_start, new_start = line:match("^@@ %-(%d+)[^ ]* %+(%d+)[^ ]* @@")
    if old_start then
      if have_hunk and #rows > 0 then
        rows[#rows + 1] = { kind = "separator" }
      end
      old_number, new_number = math.floor(assert(tonumber(old_start))), math.floor(assert(tonumber(new_start)))
      have_hunk = true
    elseif have_hunk then
      local marker = line:sub(1, 1)
      if marker == "+" then
        rows[#rows + 1] = {
          kind = "add",
          number = new_number,
          text = line:sub(2),
        }
        new_number = new_number + 1
      elseif marker == "-" then
        rows[#rows + 1] = {
          kind = "delete",
          number = old_number,
          text = line:sub(2),
        }
        old_number = old_number + 1
      elseif marker == " " then
        rows[#rows + 1] = {
          kind = "context",
          number = new_number,
          text = line:sub(2),
        }
        old_number, new_number = old_number + 1, new_number + 1
      end
    end
  end
  return rows
end

---@param value unknown
---@return integer?
local function count(value)
  if type(value) == "number" and value >= 0 and value % 1 == 0 then
    ---@cast value integer
    return value
  end
end

---@param rows Neoagent.EditPatchRow[]
---@return integer, integer
local function row_counts(rows)
  local added, removed = 0, 0
  for _, row in ipairs(rows) do
    if row.kind == "add" then
      added = added + 1
    elseif row.kind == "delete" then
      removed = removed + 1
    end
  end
  return added, removed
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.ToolActivityPresentation|Neoagent.ToolEditPresentation|nil
function M.render(opts)
  local fallback = activity.edit(opts)
  if type(opts) ~= "table" or opts.state ~= "success" then
    return fallback
  end
  local arguments = type(opts.arguments) == "table" and opts.arguments or {}
  if type(arguments.path) ~= "string" then
    return fallback
  end
  local details = type(opts.result) == "table" and type(opts.result.details) == "table" and opts.result.details or {}
  local rows = patch_rows(rawget(details, "patch"))
  if #rows == 0 then
    return fallback
  end
  local row_added, row_removed = row_counts(rows)
  return {
    kind = "edit",
    path = arguments.path,
    rows = rows,
    added = count(rawget(details, "added_lines")) or row_added,
    removed = count(rawget(details, "removed_lines")) or row_removed,
    truncated = rawget(details, "patch_truncated") == true,
  }
end

return M
