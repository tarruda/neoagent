local common = require("neoagent.tools.common")
local fs = require("neoagent.fs")

local function normalize_lf(text)
  return text:gsub("\r\n", "\n"):gsub("\r", "\n")
end

local function fuzzy(text)
  local replacements = {
    ["\226\128\152"] = "'", ["\226\128\153"] = "'", ["\226\128\154"] = "'", ["\226\128\155"] = "'",
    ["\226\128\156"] = '"', ["\226\128\157"] = '"', ["\226\128\158"] = '"', ["\226\128\159"] = '"',
    ["\226\128\144"] = "-", ["\226\128\145"] = "-", ["\226\128\146"] = "-", ["\226\128\147"] = "-",
    ["\226\128\148"] = "-", ["\226\128\149"] = "-", ["\226\136\146"] = "-",
    ["\194\160"] = " ", ["\226\128\175"] = " ", ["\226\129\159"] = " ", ["\227\128\128"] = " ",
  }
  for from, to in pairs(replacements) do
    text = text:gsub(from, to)
  end
  local lines = vim.split(text, "\n", { plain = true })
  for index, line in ipairs(lines) do
    lines[index] = line:gsub("%s+$", "")
  end
  return table.concat(lines, "\n")
end

local function occurrences(content, needle)
  local count, from = 0, 1
  while true do
    local start = content:find(needle, from, true)
    if not start then break end
    count = count + 1
    from = start + math.max(1, #needle)
  end
  return count
end

local function line_spans(content)
  local spans = {}
  local start = 1
  while start <= #content do
    local ending = content:find("\n", start, true)
    local finish = ending and ending or #content
    spans[#spans + 1] = { start = start, finish = finish }
    start = finish + 1
  end
  if #content == 0 then spans[1] = { start = 1, finish = 0 } end
  return spans
end

local function replacement_lines(spans, replacement)
  local first, last
  local ending = replacement.start + replacement.length - 1
  for index, span in ipairs(spans) do
    if not first and replacement.start >= span.start and replacement.start <= span.finish + 1 then
      first = index
    end
    if replacement.start <= span.finish + 1 and ending >= span.start then
      last = index
    end
  end
  return first or 1, last or #spans
end

local function apply_group(content, replacements, offset)
  for index = #replacements, 1, -1 do
    local replacement = replacements[index]
    local start = replacement.start - offset
    content = content:sub(1, start - 1) .. replacement.newText .. content:sub(start + replacement.length)
  end
  return content
end

local function preserve_lines(original, normalized, replacements)
  local original_lines = vim.split(original, "\n", { plain = true })
  local normalized_lines = vim.split(normalized, "\n", { plain = true })
  if #original_lines ~= #normalized_lines then
    error("Cannot preserve fuzzy-matched lines")
  end
  local spans = line_spans(normalized)
  local groups = {}
  for _, replacement in ipairs(replacements) do
    local first, last = replacement_lines(spans, replacement)
    local group = groups[#groups]
    if group and first <= group.last then
      group.last = math.max(group.last, last)
      group.replacements[#group.replacements + 1] = replacement
    else
      groups[#groups + 1] = { first = first, last = last, replacements = { replacement } }
    end
  end
  local result = {}
  local line = 1
  for _, group in ipairs(groups) do
    for index = line, group.first - 1 do result[#result + 1] = original_lines[index] end
    local segment = table.concat(vim.list_slice(normalized_lines, group.first, group.last), "\n")
    local offset = spans[group.first].start - 1
    result[#result + 1] = apply_group(segment, group.replacements, offset)
    line = group.last + 1
  end
  for index = line, #original_lines do result[#result + 1] = original_lines[index] end
  return table.concat(result, "\n")
end

local function apply(content, edits, path)
  local normalized_edits = {}
  local any_fuzzy = false
  for index, edit in ipairs(edits) do
    if type(edit) ~= "table" or type(edit.oldText) ~= "string" or type(edit.newText) ~= "string" then
      error("edits[" .. index .. "] must contain string oldText and newText")
    end
    if edit.oldText == "" then error("edits[" .. index .. "].oldText must not be empty in " .. path) end
    local old = normalize_lf(edit.oldText)
    if not content:find(old, 1, true) then any_fuzzy = true end
    normalized_edits[index] = { oldText = old, newText = normalize_lf(edit.newText) }
  end
  local base = any_fuzzy and fuzzy(content) or content
  local replacements = {}
  for index, edit in ipairs(normalized_edits) do
    local needle = any_fuzzy and fuzzy(edit.oldText) or edit.oldText
    local count = occurrences(base, needle)
    if count == 0 then
      error("Could not find edits[" .. index .. "] in " .. path .. ". The oldText must match exactly including all whitespace and newlines.")
    elseif count > 1 then
      error("Found " .. count .. " occurrences of edits[" .. index .. "] in " .. path .. ". Each oldText must be unique.")
    end
    local start = assert(base:find(needle, 1, true))
    replacements[#replacements + 1] = { index = index, start = start, length = #needle, newText = edit.newText }
  end
  table.sort(replacements, function(a, b) return a.start < b.start end)
  for index = 2, #replacements do
    local previous, current = replacements[index - 1], replacements[index]
    if previous.start + previous.length > current.start then
      error(string.format("edits[%d] and edits[%d] overlap in %s", previous.index, current.index, path))
    end
  end
  local changed = any_fuzzy and preserve_lines(content, base, replacements) or apply_group(base, replacements, 0)
  if changed == content then error("No changes made to " .. path .. ". The replacements produced identical content.") end
  return changed
end

local function first_changed(old, new)
  local before, after = vim.split(old, "\n", { plain = true }), vim.split(new, "\n", { plain = true })
  for index = 1, math.max(#before, #after) do
    if before[index] ~= after[index] then return index end
  end
end

local function diff_details(path, old, new)
  local ok, patch = pcall(vim.diff, old, new, { result_type = "unified", ctxlen = 4 })
  if not ok then patch = "--- " .. path .. "\n+++ " .. path end
  local display = {}
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" or line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
      display[#display + 1] = line
    end
  end
  return { diff = table.concat(display, "\n"), patch = patch, firstChangedLine = first_changed(old, new) }
end

local function new()
  return {
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
    execute = function(arguments, ctx)
      local path = common.require_string(arguments, "path")
      if type(arguments.edits) ~= "table" or not require("neoagent.util").is_list(arguments.edits) or #arguments.edits == 0 then
        error("edits must contain at least one replacement")
      end
      local absolute = common.workspace(ctx):resolve(path)
      local raw, err = fs.read(absolute)
      if not raw then error("Could not edit file " .. path .. ": " .. tostring(err)) end
      local bom = raw:sub(1, 3) == "\239\187\191" and raw:sub(1, 3) or ""
      if bom ~= "" then raw = raw:sub(4) end
      local ending = raw:find("\r\n", 1, true) and "\r\n" or "\n"
      local content = normalize_lf(raw)
      local changed = apply(content, arguments.edits, path)
      local restored = ending == "\r\n" and changed:gsub("\n", "\r\n") or changed
      local ok
      ok, err = fs.write_all(absolute, bom .. restored, "w", 420)
      if not ok then error("Could not edit file " .. path .. ": " .. tostring(err)) end
      return {
        content = { { type = "text", text = string.format("Successfully replaced %d block(s) in %s.", #arguments.edits, path) } },
        details = diff_details(path, content, changed),
      }
    end,
  }
end

local M = new()
M.new = new
M._apply = apply
M._fuzzy = fuzzy
return M
