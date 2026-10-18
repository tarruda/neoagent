-- Patch language and contextual matching adapted from OpenAI Codex.
-- Copyright 2025 OpenAI. Licensed under Apache-2.0.
-- This Lua port rejects shell wrappers and repeated paths and preserves CRLF.
local util = require("neoagent.util")
local async = require("neoagent.async")

local M = {}

M.grammar = [=[
start: begin_patch hunk+ end_patch
begin_patch: "*** Begin Patch" LF
end_patch: "*** End Patch" LF?

hunk: add_hunk | delete_hunk | update_hunk
add_hunk: "*** Add File: " filename LF add_line+
delete_hunk: "*** Delete File: " filename LF
update_hunk: "*** Update File: " filename LF change_move? change?

filename: /(.+)/
add_line: "+" /(.*)/ LF -> line

change_move: "*** Move to: " filename LF
change: (change_context | change_line)+ eof_line?
change_context: ("@@" | "@@ " /(.+)/) LF
change_line: ("+" | "-" | " ") /(.*)/ LF
eof_line: "*** End of File" LF

%import common.LF
]=]

---@class Neoagent.PatchChunk
---@field context? string
---@field old string[]
---@field new string[]
---@field contexts {old: integer, new: integer}[]
---@field eof boolean

---@class Neoagent.PatchOperation
---@field kind 'add'|'delete'|'update'
---@field path string
---@field destination? string
---@field content? string
---@field chunks Neoagent.PatchChunk[]

---@param path string
---@return string
local function path_name(path)
  assert(path ~= "" and not path:find("[%z\r\n]"), "Invalid patch path")
  return path
end

---@param patch string
---@return Neoagent.PatchOperation[]
function M.parse(patch)
  assert(type(patch) == "string", "Patch must be UTF-8 text")
  assert(#patch <= require("neoagent.tools.limits").MAX_INPUT_BYTES, "Patch exceeded the aggregate request limit")
  assert(util.is_valid_utf8(patch) and not patch:find("%z"), "Patch must be UTF-8 text")
  local lines = vim.split(util.trim(patch):gsub("\r\n", "\n"), "\n", { plain = true })
  lines[1] = util.trim(assert(lines[1]))
  lines[#lines] = util.trim(assert(lines[#lines]))
  ---@param index integer
  ---@return string
  local function at(index)
    return (assert(lines[index], "Unexpected end of patch"))
  end
  assert(
    lines[1] == "*** Begin Patch" and lines[#lines] == "*** End Patch",
    "Patch must start with *** Begin Patch and end with *** End Patch"
  )
  ---@type Neoagent.PatchOperation[]
  local operations = {}
  local index = 2
  while index < #lines do
    local header = at(index)
    local kind, path = header:match("^%*%*%* (%w+) File: (.+)$")
    assert(kind == "Add" or kind == "Delete" or kind == "Update", "Invalid file header at patch line " .. index)
    ---@type Neoagent.PatchOperation
    local operation = {
      kind = kind == "Add" and "add" or kind == "Delete" and "delete" or "update",
      path = path_name(assert(path)),
      chunks = {},
    }
    index = index + 1
    if operation.kind == "add" then
      local added = {}
      while index < #lines and at(index):sub(1, 1) == "+" do
        added[#added + 1] = at(index):sub(2)
        index = index + 1
      end
      operation.content = #added > 0 and table.concat(added, "\n") .. "\n" or ""
    elseif operation.kind == "update" then
      local destination = at(index):match("^%*%*%* Move to: (.+)$")
      if destination then
        operation.destination = path_name(destination)
        index = index + 1
      end
      while index < #lines and at(index):sub(1, 4) ~= "*** " do
        ---@type Neoagent.PatchChunk
        local chunk = { old = {}, new = {}, contexts = {}, eof = false }
        local line = at(index)
        if line == "@@" or line:sub(1, 3) == "@@ " then
          chunk.context = line ~= "@@" and line:sub(4) or nil
          index = index + 1
        end
        while index < #lines do
          line = at(index)
          if line == "*** End of File" then
            chunk.eof = true
            index = index + 1
            break
          end
          if line:sub(1, 4) == "*** " or line == "@@" or line:sub(1, 3) == "@@ " then
            break
          end
          local prefix, text = line:sub(1, 1), line:sub(2)
          if line == "" then
            prefix = " "
          end
          assert(prefix == " " or prefix == "+" or prefix == "-", "Invalid hunk line " .. index)
          if prefix ~= "+" then
            chunk.old[#chunk.old + 1] = text
          end
          if prefix ~= "-" then
            chunk.new[#chunk.new + 1] = text
          end
          if prefix == " " then
            chunk.contexts[#chunk.contexts + 1] = { old = #chunk.old, new = #chunk.new }
          end
          index = index + 1
        end
        assert(#chunk.old > 0 or #chunk.new > 0, "Empty update hunk for " .. operation.path)
        operation.chunks[#operation.chunks + 1] = chunk
        if chunk.eof then
          break
        end
      end
      assert(#operation.chunks > 0 or operation.destination, "Empty update for " .. operation.path)
    end
    operations[#operations + 1] = operation
  end
  assert(#operations > 0, "Patch contains no files")
  return operations
end

local unicode_groups = {
  { "‐", "‑", "‒", "–", "—", "―", "−", replacement = "-" },
  { "‘", "’", "‚", "‛", replacement = "'" },
  { "“", "”", "„", "‟", replacement = '"' },
  { "\194\160", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", " ", "　", replacement = " " },
}

---@param line string
---@param pass integer
---@return string
local function normalize(line, pass)
  if pass == 1 then
    return line
  end
  if pass == 4 then
    for _, group in ipairs(unicode_groups) do
      for _, char in ipairs(group) do
        line = line:gsub(char, group.replacement)
      end
    end
  end
  return pass == 2 and line:gsub("%s+$", "") or util.trim(line)
end

---@async
---@param lines string[]
---@param pattern string[]
---@param start integer
---@param eof boolean
---@param checkpoint async fun()
---@return integer?
local function seek(lines, pattern, start, eof, checkpoint)
  local last = #lines - #pattern + 1
  start = eof and math.max(start, last) or start
  if start > last then
    return nil
  end
  if #pattern == 0 then
    return start
  end
  for pass = 1, 4 do
    local expected, prefix = {}, { 0 }
    for index, line in ipairs(pattern) do
      checkpoint()
      expected[index] = normalize(line, pass)
    end
    -- Prefix lengths retain overlapping context without comparing the whole
    -- hunk at every position. Each normalization pass scans lines once.
    for index = 2, #expected do
      checkpoint()
      local matched = assert(prefix[index - 1])
      while matched > 0 and expected[matched + 1] ~= expected[index] do
        matched = assert(prefix[matched])
      end
      if expected[matched + 1] == expected[index] then
        matched = matched + 1
      end
      prefix[index] = matched
    end
    local matched = 0
    for index = start, #lines do
      checkpoint()
      local line = normalize(assert(lines[index]), pass)
      while matched > 0 and expected[matched + 1] ~= line do
        matched = assert(prefix[matched])
      end
      if expected[matched + 1] == line then
        matched = matched + 1
      end
      if matched == #expected then
        return index - matched + 1
      end
    end
  end
end

---@async
---@param original string
---@param operation Neoagent.PatchOperation
---@return string
function M.update(original, operation)
  local binary_error = "Cannot patch a binary file: " .. operation.path
  assert(not original:find("%z"), binary_error)
  if #operation.chunks == 0 then
    assert(util.is_valid_utf8(original), binary_error)
    return original
  end
  local work = 0
  ---@async
  local function checkpoint()
    work = work + 1
    if work >= 512 then
      work = 0
      async.yield()
    end
  end
  local bom = original:sub(1, 3) == "\239\187\191" and original:sub(1, 3) or ""
  local lines, raw, endings = {}, {}, {}
  local position = #bom + 1
  while position <= #original do
    checkpoint()
    local boundary = original:find("[\r\n]", position)
    if boundary and original:sub(boundary, boundary + 1) == "\r\n" then
      boundary = boundary + 1
    end
    local finish = boundary or #original
    local value = original:sub(position, finish)
    assert(util.is_valid_utf8(value), binary_error)
    local ending = boundary and (value:sub(-2) == "\r\n" and "\r\n" or value:sub(-1)) or ""
    raw[#raw + 1] = value
    endings[#endings + 1] = ending
    lines[#lines + 1] = value:sub(1, #value - #ending)
    position = finish + 1
  end
  local default_ending = endings[1] and endings[1] ~= "" and endings[1] or "\n"
  ---@async
  ---@param line integer
  ---@return string
  local function source(line)
    checkpoint()
    return raw[line] .. (endings[line] == "" and default_ending or "")
  end
  ---@type {index: integer, old: string[], new: string[], contexts: {old: integer, new: integer}[], order: integer}[]
  local replacements = {}
  local cursor = 1
  for order, chunk in ipairs(operation.chunks) do
    checkpoint()
    local start = cursor
    if chunk.context then
      start = assert(
        seek(lines, { chunk.context }, start, false, checkpoint),
        "Failed to find context in " .. operation.path
      ) + 1
    end
    local old, new = util.copy(chunk.old), util.copy(chunk.new)
    local index = #old == 0 and #lines + 1 or seek(lines, old, start, chunk.eof, checkpoint)
    if not index and old[#old] == "" then
      table.remove(old)
      if new[#new] == "" then
        table.remove(new)
      end
      index = seek(lines, old, start, chunk.eof, checkpoint)
    end
    assert(index and index >= cursor, "Failed to find expected lines in " .. operation.path)
    replacements[#replacements + 1] = { index = index, old = old, new = new, contexts = chunk.contexts, order = order }
    -- An append has no source region to consume. Later hunks still search
    -- from the last replacement (or an explicit jump context).
    cursor = #chunk.old == 0 and start or index + #old
  end
  table.sort(replacements, function(left, right)
    if left.index == right.index then
      return left.order < right.order
    end
    return left.index < right.index
  end)
  local output = {}
  cursor = 1
  for _, replacement in ipairs(replacements) do
    local index, old, new = replacement.index, replacement.old, replacement.new
    for line = cursor, index - 1 do
      output[#output + 1] = source(line)
    end
    local old_position, new_position = 1, 1
    ---@async
    ---@param old_end integer
    ---@param new_end integer
    local function replace(old_end, new_end)
      local ending = endings[index + old_position - 1] or endings[index + old_position - 2] or default_ending
      for line = new_position, new_end do
        checkpoint()
        -- A replacement inherits the terminator of the line it replaces.
        -- Insertions use the adjacent terminator. Updates retain the patch
        -- language's final-newline behavior for previously unterminated files.
        local source = index + math.min(old_position + line - new_position, old_end) - 1
        local selected = old_end >= old_position and endings[source] or ending
        output[#output + 1] = new[line] .. (selected and selected ~= "" and selected or default_ending)
      end
      old_position, new_position = old_end + 1, new_end + 1
    end
    for _, context in ipairs(replacement.contexts) do
      if context.old <= #old and context.new <= #new then
        replace(context.old - 1, context.new - 1)
        output[#output + 1] = source(index + context.old - 1)
        old_position, new_position = context.old + 1, context.new + 1
      end
    end
    replace(#old, #new)
    cursor = index + #old
  end
  for line = cursor, #lines do
    output[#output + 1] = source(line)
  end
  return bom .. table.concat(output)
end

return M
