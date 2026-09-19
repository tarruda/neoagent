---@class Neoagent.NormalizedFileText
---@field text string
---@field starts integer[]
---@field finishes integer[]

---@class Neoagent.FileReplacement
---@field index integer
---@field start integer
---@field length integer
---@field newText string

---@class Neoagent.FileEditDetails
---@field patch string
---@field changed_paths string[]
---@field patch_truncated? boolean
---@field patch_bytes? integer
---@field added_lines integer
---@field removed_lines integer

---@class Neoagent.EditFileReplacement
---@field old_text string
---@field new_text string

---@class Neoagent.EditFileRequest
---@field path string
---@field edits Neoagent.EditFileReplacement[]

local common = require("neoagent.tools.common")
local presentation = require("neoagent.tools.edit_presentation")
local truncate = require("neoagent.tools.truncate")
local util = require("neoagent.util")

---@class Neoagent.EditFileTool: Neoagent.Tool<unknown>
---@field execute async fun(arguments: Neoagent.JsonObject, ctx: Neoagent.ToolContext<unknown>): Neoagent.ToolResult
---@field render fun(options?: Neoagent.ToolPresentationOptions): Neoagent.ToolActivityPresentation|Neoagent.ToolEditPresentation|nil
local M = {}
local IMPLEMENTATION = {}
local MAX_PATCH_BYTES = 256 * 1024
-- A byte-bounded string has at most one more logical line than bytes, so this
-- explicit line limit cannot truncate a patch before the byte limit does.
local MAX_PATCH_LINES = MAX_PATCH_BYTES + 1

---@param value unknown
---@return Neoagent.EditFileRequest
local function validate_request(value)
  assert(common.object(value), "edit_file request must be an object")
  ---@cast value table
  common.fields(value, { path = true, edits = true }, "edit_file request")
  assert(type(value.edits) == "table" and util.is_list(value.edits) and #value.edits > 0, "edit_file edits must be a non-empty list")
  ---@type Neoagent.EditFileReplacement[]
  local edits = {}
  for index, edit in ipairs(value.edits) do
    assert(common.object(edit), "edit_file edits[" .. index .. "] must be an object")
    ---@cast edit table
    common.fields(edit, { old_text = true, new_text = true }, "edit_file edits[" .. index .. "]")
    edits[index] = {
      old_text = common.string(edit.old_text, "edit_file edits[" .. index .. "].old_text", true),
      new_text = common.string(edit.new_text, "edit_file edits[" .. index .. "].new_text", true),
    }
  end
  return common.request({
    path = common.path(value.path, "edit_file path"),
    edits = edits,
  }, "edit_file request")
end

---@param arguments Neoagent.JsonObject
---@return Neoagent.EditFileRequest
local function prepare(arguments)
  if type(arguments.edits) ~= "table" or not util.is_list(arguments.edits) or #arguments.edits == 0 then
    error("edits must contain at least one replacement")
  end
  ---@type Neoagent.EditFileReplacement[]
  local edits = {}
  for index, edit in ipairs(arguments.edits) do
    if type(edit) ~= "table" or type(edit.oldText) ~= "string" or type(edit.newText) ~= "string" then
      error("edits[" .. index .. "] must contain string oldText and newText")
    end
    edits[index] = { old_text = edit.oldText, new_text = edit.newText }
  end
  return validate_request({
    path = common.require_string(arguments, "path"),
    edits = edits,
  })
end

---@param text string
---@return string
local function normalize_lf(text)
  return (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

---@param text string
---@return string, integer[], integer[]
function M.fuzzy(text)
  local replacements = {
    ["\226\128\152"] = "'",
    ["\226\128\153"] = "'",
    ["\226\128\154"] = "'",
    ["\226\128\155"] = "'",
    ["\226\128\156"] = '"',
    ["\226\128\157"] = '"',
    ["\226\128\158"] = '"',
    ["\226\128\159"] = '"',
    ["\226\128\144"] = "-",
    ["\226\128\145"] = "-",
    ["\226\128\146"] = "-",
    ["\226\128\147"] = "-",
    ["\226\128\148"] = "-",
    ["\226\128\149"] = "-",
    ["\226\136\146"] = "-",
    ["\194\160"] = " ",
    ["\226\128\175"] = " ",
    ["\226\129\159"] = " ",
    ["\227\128\128"] = " ",
  }
  ---@type string[]
  local bytes = {}
  ---@type integer[]
  local starts, finishes = {}, {}
  local function trim_line()
    while #bytes > 0 and bytes[#bytes] ~= "\n" and bytes[#bytes]:match("%s") do
      bytes[#bytes], starts[#starts], finishes[#finishes] = nil, nil, nil
    end
  end
  local index = 1
  while index <= #text do
    local width = 3
    local byte = replacements[text:sub(index, index + 2)]
    if not byte then
      width = 2
      byte = replacements[text:sub(index, index + 1)]
    end
    if not byte then
      width, byte = 1, text:sub(index, index)
    end
    if byte == "\n" then
      trim_line()
    end
    bytes[#bytes + 1] = byte
    starts[#starts + 1], finishes[#finishes + 1] = index, index + width - 1
    index = index + width
  end
  trim_line()
  return table.concat(bytes), starts, finishes
end

---@param content string
---@param needle string
---@return integer, integer?
local function occurrences(content, needle)
  local count, from, first = 0, 1, nil
  if needle == "" then
    return count
  end
  while true do
    local start = content:find(needle, from, true)
    if not start then
      break
    end
    count = count + 1
    first = first or start
    from = start + 1
  end
  return count, first
end

---@param content string
---@param replacements Neoagent.FileReplacement[]
---@return string
local function apply_group(content, replacements)
  for index = #replacements, 1, -1 do
    local replacement = replacements[index]
    local start = replacement.start
    content = content:sub(1, start - 1) .. replacement.newText .. content:sub(start + replacement.length)
  end
  return content
end

---@param content string
---@param edits Neoagent.EditFileReplacement[]
---@param path string
---@return string
function M.apply(content, edits, path)
  ---@type Neoagent.NormalizedFileText?
  local normalized
  ---@type Neoagent.FileReplacement[]
  local replacements = {}
  for index, edit in ipairs(edits) do
    if edit.old_text == "" then
      error("edits[" .. index .. "].oldText must not be empty in " .. path)
    end
    local needle = normalize_lf(edit.old_text)
    local count, start = occurrences(content, needle)
    local length = #needle
    if count == 0 then
      if not normalized then
        local text, starts, finishes = M.fuzzy(content)
        normalized = { text = text, starts = starts, finishes = finishes }
      end
      needle = M.fuzzy(needle)
      count, start = occurrences(normalized.text, needle)
      if start then
        local original_start = assert(normalized.starts[start])
        local original_finish = assert(normalized.finishes[start + #needle - 1])
        length = original_finish - original_start + 1
        start = original_start
      end
    end
    if not start then
      error(
        "Could not find edits["
          .. index
          .. "] in "
          .. path
          .. ". The oldText must match exactly including all whitespace and newlines."
      )
    elseif count > 1 then
      error("Found " .. count .. " occurrences of edits[" .. index .. "] in " .. path .. ". Each oldText must be unique.")
    end
    replacements[#replacements + 1] = {
      index = index,
      start = start,
      length = length,
      newText = normalize_lf(edit.new_text),
    }
  end
  table.sort(replacements, function(a, b)
    return a.start < b.start
  end)
  ---@type Neoagent.FileReplacement?
  local previous
  for _, current in ipairs(replacements) do
    if previous and previous.start + previous.length > current.start then
      error(string.format("edits[%d] and edits[%d] overlap in %s", previous.index, current.index, path))
    end
    previous = current
  end
  local changed = apply_group(content, replacements)
  if changed == content then
    error("No changes made to " .. path .. ". The replacements produced identical content.")
  end
  return changed
end

---@param path string
---@param old string
---@param new string
---@return Neoagent.FileEditDetails
local function diff_details(path, old, new)
  local ok, patch = pcall(vim.diff, old, new, { result_type = "unified", ctxlen = 4 })
  if not ok or type(patch) ~= "string" then
    patch = "--- " .. path .. "\n+++ " .. path
  end
  local added, removed = 0, 0
  local have_hunk = false
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    if line:find("^@@ ") then
      have_hunk = true
    elseif have_hunk then
      local marker = line:sub(1, 1)
      if marker == "+" then
        added = added + 1
      elseif marker == "-" then
        removed = removed + 1
      end
    end
  end
  local shortened = truncate.head(patch, {
    max_lines = MAX_PATCH_LINES,
    max_bytes = MAX_PATCH_BYTES,
  })
  ---@type Neoagent.FileEditDetails
  local details = {
    patch = shortened.content,
    changed_paths = { path },
    added_lines = added,
    removed_lines = removed,
  }
  if shortened.truncated then
    details.patch_truncated = true
    details.patch_bytes = shortened.totalBytes
  end
  return details
end

---@async
---@param request Neoagent.EditFileRequest
---@param call Neoagent.ToolOperationCall
---@param deps Neoagent.ToolDependencies
---@return Neoagent.ToolResult
local function run(request, call, deps)
  local absolute = deps.workspace(call.workspace):resolve(request.path)
  local raw, err = deps.fs.read(absolute)
  if not raw then
    error("Could not edit file " .. request.path .. ": " .. tostring(err))
  end
  local original_fingerprint = deps.fingerprint(raw)
  local bom = raw:sub(1, 3) == "\239\187\191" and raw:sub(1, 3) or ""
  if bom ~= "" then
    raw = raw:sub(4)
  end
  local ending = raw:find("\r\n", 1, true) and "\r\n" or "\n"
  local content = normalize_lf(raw)
  local changed = M.apply(content, request.edits, request.path)
  local restored = ending == "\r\n" and changed:gsub("\n", "\r\n") or changed
  local details = diff_details(request.path, content, changed)
  local ok, replace_err = deps.fs.atomic_replace(absolute, bom .. restored, {
    preserve_mode = true,
    new_mode = 420,
    require_existing = true,
    expected_content_fingerprint = original_fingerprint,
  })
  if not ok then
    error("Could not edit file " .. request.path .. ": " .. tostring(replace_err))
  end
  return {
    content = {
      {
        type = "text",
        text = string.format("Successfully replaced %d block(s) in %s.", #request.edits, request.path),
      },
    },
    details = details --[[@as Neoagent.JsonObject]],
  }
end

---@return Neoagent.Tool<unknown>
local function new()
  local dependencies = common.dependencies()
  local tool = {
    name = "edit_file",
    description = "Edit one file using unique, exact, non-overlapping replacements matched against the original content.",
    input_schema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Path to the file to edit (relative or absolute)" },
        edits = {
          type = "array",
          minItems = 1,
          items = {
            type = "object",
            properties = { oldText = { type = "string" }, newText = { type = "string" } },
            required = { "oldText", "newText" },
            additionalProperties = false,
          },
        },
      },
      required = { "path", "edits" },
      additionalProperties = false,
    },
    ---@async
    execute = function(arguments, ctx)
      return run(prepare(arguments), common.call(ctx), dependencies)
    end,
    render = presentation.render,
  }
  return common.bind(tool, {
    token = IMPLEMENTATION,
    settings = {},
    prepare = prepare,
  })
end

local tool = new()
for key, value in pairs(tool) do
  M[key] = value
end
M.new = new
M.prepare = prepare
M.validate_request = validate_request
M.run = run
M._implementation = IMPLEMENTATION
return M
