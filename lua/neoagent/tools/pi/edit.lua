-- Model-facing contract adapted from Pi 3390bd9363 (MIT).
local M = {}

---@return Neoagent.Tool<unknown>
function M.new()
  local tool = require("neoagent.tools.edit_file").new()
  tool.name = "edit"
  tool.description =
    "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes."
  tool.prompt_snippet =
    "Make precise file edits with exact text replacement, including multiple disjoint edits in one call"
  tool.prompt_guidelines = {
    "Use edit for precise changes (edits[].oldText must match exactly)",
    "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls",
    "Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
    "Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.",
  }
  return tool
end

return M
