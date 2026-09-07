local common = require("neoagent.tools.common")
local presentation = require("neoagent.tools.edit_presentation")

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
  local bytes, starts, finishes = {}, {}, {}
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
    if not byte then width, byte = 1, text:sub(index, index) end
    if byte == "\n" then trim_line() end
    bytes[#bytes + 1] = byte
    starts[#starts + 1], finishes[#finishes + 1] = index, index + width - 1
    index = index + width
  end
  trim_line()
  return table.concat(bytes), starts, finishes
end

local function occurrences(content, needle)
  local count, from, first = 0, 1, nil
  if needle == "" then return count end
  while true do
    local start = content:find(needle, from, true)
    if not start then break end
    count = count + 1
    first = first or start
    from = start + 1
  end
  return count, first
end

local function apply_group(content, replacements)
  for index = #replacements, 1, -1 do
    local replacement = replacements[index]
    local start = replacement.start
    content = content:sub(1, start - 1) .. replacement.newText .. content:sub(start + replacement.length)
  end
  return content
end

local function apply(content, edits, path)
  local normalized, starts, finishes
  local replacements = {}
  for index, edit in ipairs(edits) do
    if type(edit) ~= "table" or type(edit.oldText) ~= "string" or type(edit.newText) ~= "string" then
      error("edits[" .. index .. "] must contain string oldText and newText")
    end
    if edit.oldText == "" then error("edits[" .. index .. "].oldText must not be empty in " .. path) end
    local needle = normalize_lf(edit.oldText)
    local count, start = occurrences(content, needle)
    local length = #needle
    if count == 0 then
      if not normalized then normalized, starts, finishes = fuzzy(content) end
      needle = fuzzy(needle)
      count, start = occurrences(normalized, needle)
      if start then
        length = finishes[start + #needle - 1] - starts[start] + 1
        start = starts[start]
      end
    end
    if count == 0 then
      error("Could not find edits[" .. index .. "] in " .. path .. ". The oldText must match exactly including all whitespace and newlines.")
    elseif count > 1 then
      error("Found " .. count .. " occurrences of edits[" .. index .. "] in " .. path .. ". Each oldText must be unique.")
    end
    replacements[#replacements + 1] = {
      index = index, start = start, length = length, newText = normalize_lf(edit.newText),
    }
  end
  table.sort(replacements, function(a, b) return a.start < b.start end)
  for index = 2, #replacements do
    local previous, current = replacements[index - 1], replacements[index]
    if previous.start + previous.length > current.start then
      error(string.format("edits[%d] and edits[%d] overlap in %s", previous.index, current.index, path))
    end
  end
  local changed = apply_group(content, replacements)
  if changed == content then error("No changes made to " .. path .. ". The replacements produced identical content.") end
  return changed
end

local function diff_details(path, old, new)
  local ok, patch = pcall(vim.diff, old, new, { result_type = "unified", ctxlen = 4 })
  if not ok then patch = "--- " .. path .. "\n+++ " .. path end
  return {
    patch = patch,
    changed_paths = { path },
  }
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
      local fs = common.fs(ctx)
      local raw, err = fs.read(absolute)
      if not raw then error("Could not edit file " .. path .. ": " .. tostring(err)) end
      local original_fingerprint = require("neoagent.fs").content_fingerprint(raw)
      local bom = raw:sub(1, 3) == "\239\187\191" and raw:sub(1, 3) or ""
      if bom ~= "" then raw = raw:sub(4) end
      local ending = raw:find("\r\n", 1, true) and "\r\n" or "\n"
      local content = normalize_lf(raw)
      local changed = apply(content, arguments.edits, path)
      local restored = ending == "\r\n" and changed:gsub("\n", "\r\n") or changed
      local ok
      ok, err = fs.atomic_replace(absolute, bom .. restored, {
        preserve_mode = true,
        new_mode = 420,
        require_existing = true,
        expected_content_fingerprint = original_fingerprint,
      })
      if not ok then error("Could not edit file " .. path .. ": " .. tostring(err)) end
      return {
        content = { { type = "text", text = string.format("Successfully replaced %d block(s) in %s.", #arguments.edits, path) } },
        details = diff_details(path, content, changed),
      }
    end,
    render = presentation.render,
  }
end

local M = new()
M.new = new
M._apply = apply
M._fuzzy = fuzzy
return M
