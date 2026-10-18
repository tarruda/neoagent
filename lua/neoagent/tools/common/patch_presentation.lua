local edit = require("neoagent.tools.edit_presentation")
local util = require("neoagent.util")

---@class Neoagent.PatchEffect: Neoagent.JsonObject
---@field kind 'add'|'delete'|'update'
---@field path string
---@field patch string
---@field status 'pending'|'applied'|'failed'|'partial'
---@field error? string
---@field added integer
---@field removed integer
---@field truncated boolean
---@field escaped_bytes? integer

---@class Neoagent.PatchChange: Neoagent.PatchEffect
---@field destination? string
---@field effects? Neoagent.PatchEffect[]

---@class Neoagent.ToolPatchFilePresentation
---@field kind 'add'|'delete'|'update'
---@field path string
---@field destination? string
---@field rows Neoagent.EditPatchRow[]
---@field status 'pending'|'applied'|'failed'|'partial'
---@field error? string
---@field added integer
---@field removed integer
---@field truncated boolean

---@class Neoagent.ToolPatchPresentation
---@field kind 'patch'
---@field files Neoagent.ToolPatchFilePresentation[]

local M = {}

---@param value string
---@return string
local function label(value)
  return (util.text_from_bytes(value):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t"))
end

---@param opts? Neoagent.ToolPresentationOptions
---@return Neoagent.ToolPatchPresentation|Neoagent.ToolActivityPresentation|nil
function M.render(opts)
  if type(opts) ~= "table" then
    return nil
  end
  local details = opts.result and opts.result.details
  local changes = type(details) == "table" and details.changes
  if type(changes) ~= "table" or not util.is_list(changes) or #changes == 0 then
    return {
      kind = "activity",
      operation = "edit",
      ongoing = "Applying",
      complete = opts.state == "error" and "Failed to apply" or "Applied",
      subject = "patch",
    }
  end
  ---@type Neoagent.ToolPatchFilePresentation[]
  local files = {}
  for _, change in ipairs(changes) do
    if
      type(change) ~= "table"
      or type(change.path) ~= "string"
      or change.kind ~= "add" and change.kind ~= "delete" and change.kind ~= "update"
      or change.status ~= "pending" and change.status ~= "applied" and change.status ~= "failed" and change.status ~= "partial"
      or change.destination ~= nil and type(change.destination) ~= "string"
      or change.error ~= nil and type(change.error) ~= "string"
      or type(change.patch) ~= "string"
      or type(change.added) ~= "number"
      or change.added < 0
      or change.added % 1 ~= 0
      or type(change.removed) ~= "number"
      or change.removed < 0
      or change.removed % 1 ~= 0
      or type(change.truncated) ~= "boolean"
    then
      return nil
    end
    files[#files + 1] = {
      kind = change.kind,
      path = label(change.path),
      destination = change.destination and label(change.destination) or nil,
      status = change.status,
      error = change.error and util.text_from_bytes(change.error) or nil,
      added = change.added,
      removed = change.removed,
      truncated = change.truncated,
      rows = edit.patch_rows(change.patch),
    }
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return { kind = "patch", files = files }
end

return M
