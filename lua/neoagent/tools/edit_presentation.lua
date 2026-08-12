local activity = require("neoagent.tools.activity_presentation")

local M = {}
local PREVIEW_LINES = 10

local function text_lines(text)
  if type(text) ~= "string" or text == "" then return {} end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = vim.split(text, "\n", { plain = true })
  if text:sub(-1) == "\n" then table.remove(lines) end
  return lines
end

local function patch_rows(patch)
  if type(patch) ~= "string" or patch == "" then return {} end
  local rows = {}
  local old_number, new_number
  local have_hunk = false
  for _, line in ipairs(vim.split(patch, "\n", { plain = true })) do
    local old_start, new_start = line:match(
      "^@@ %-(%d+)[^ ]* %+(%d+)[^ ]* @@")
    if old_start then
      if have_hunk and #rows > 0 then
        rows[#rows + 1] = { kind = "separator" }
      end
      old_number, new_number = tonumber(old_start), tonumber(new_start)
      have_hunk = true
    elseif have_hunk then
      local marker = line:sub(1, 1)
      if marker == "+" then
        rows[#rows + 1] = {
          kind = "add", number = new_number, text = line:sub(2),
        }
        new_number = new_number + 1
      elseif marker == "-" then
        rows[#rows + 1] = {
          kind = "delete", number = old_number, text = line:sub(2),
        }
        old_number = old_number + 1
      elseif marker == " " then
        rows[#rows + 1] = {
          kind = "context", number = new_number, text = line:sub(2),
        }
        old_number, new_number = old_number + 1, new_number + 1
      end
    end
  end
  return rows
end

local function diff_rows(diff, first_changed)
  local rows = {}
  local old_number = type(first_changed) == "number" and first_changed or 1
  local new_number = old_number
  for _, line in ipairs(text_lines(diff)) do
    local marker = line:sub(1, 1)
    if marker == "+" then
      rows[#rows + 1] = {
        kind = "add", number = new_number, text = line:sub(2),
      }
      new_number = new_number + 1
    elseif marker == "-" then
      rows[#rows + 1] = {
        kind = "delete", number = old_number, text = line:sub(2),
      }
      old_number = old_number + 1
    elseif marker == " " then
      rows[#rows + 1] = {
        kind = "context", number = new_number, text = line:sub(2),
      }
      old_number, new_number = old_number + 1, new_number + 1
    end
  end
  return rows
end

local function wrap_text(text, width)
  text = (text or ""):gsub("\t", "    ")
  if text == "" then return { "" } end
  local result, current, current_width = {}, "", 0
  width = math.max(1, width)
  for index = 0, vim.fn.strchars(text) - 1 do
    local character = vim.fn.strcharpart(text, index, 1)
    local character_width = vim.fn.strdisplaywidth(character)
    if current ~= "" and current_width + character_width > width then
      result[#result + 1] = current
      current, current_width = "", 0
    end
    current = current .. character
    current_width = current_width + character_width
  end
  result[#result + 1] = current
  return result
end

local function row_counts(rows)
  local added, removed = 0, 0
  for _, row in ipairs(rows) do
    if row.kind == "add" then added = added + 1 end
    if row.kind == "delete" then removed = removed + 1 end
  end
  return added, removed
end

local function summary(path, added, removed)
  return {
    { text = "Edited", style = "bold" },
    { text = " " .. path .. " (" },
    { text = "+" .. added, style = "green" },
    { text = " " },
    { text = "-" .. removed, style = "red" },
    { text = ")" },
  }
end

local function rendered_rows(rows, width, maximum_lines)
  local result = {}
  local omitted = 0
  local maximum = 1
  for _, row in ipairs(rows) do
    if row.number then maximum = math.max(maximum, row.number) end
  end
  local gutter_width = #tostring(maximum)
  local available = math.max(1, width - gutter_width - 5)
  for _, row in ipairs(rows) do
    if row.kind == "separator" then
      if maximum_lines and #result >= maximum_lines then
        omitted = omitted + 1
      else
        result[#result + 1] = {
          { text = "   " .. string.rep(" ", gutter_width + 1) },
          { text = "⋮", style = "muted" },
        }
      end
    elseif maximum_lines and #result >= maximum_lines then
      omitted = omitted + 1
    else
      local style = row.kind == "add" and "green"
        or row.kind == "delete" and "red" or nil
      local sign = row.kind == "add" and "+"
        or row.kind == "delete" and "-" or " "
      for index, chunk in ipairs(wrap_text(row.text, available)) do
        if maximum_lines and #result >= maximum_lines then
          omitted = omitted + 1
        else
          local line = {}
          if index == 1 then
            line[#line + 1] = { text = "   " }
            line[#line + 1] = {
              text = string.format("%" .. gutter_width .. "d ", row.number),
              style = "muted",
            }
            line[#line + 1] = { text = sign, style = style }
          else
            line[#line + 1] = {
              text = "   " .. string.rep(" ", gutter_width + 2),
              style = "muted",
            }
          end
          line[#line + 1] = { text = chunk, style = style }
          result[#result + 1] = line
        end
      end
    end
  end
  return result, omitted
end

local function presentation(path, rows, opts)
  local added, removed = row_counts(rows)
  local maximum
  if opts.full ~= true then maximum = PREVIEW_LINES end
  local lines, omitted = rendered_rows(
    rows, opts.width or 80, maximum)
  if omitted > 0 then
    lines[#lines + 1] = { {
      text = string.format("   [... %d more line%s]",
        omitted, omitted == 1 and "" or "s"),
      style = "muted",
    } }
  end
  return {
    title = summary(path, added, removed),
    lines = lines,
    status = true,
  }
end

function M.render(opts)
  local fallback = activity.edit(opts)
  if type(opts) ~= "table" or opts.style ~= "codex"
      or opts.state ~= "success" then return fallback end
  local arguments = type(opts.arguments) == "table" and opts.arguments or {}
  if type(arguments.path) ~= "string" then return fallback end
  local details = type(opts.result) == "table"
      and type(opts.result.details) == "table" and opts.result.details or {}
  local rows = patch_rows(details.patch)
  if #rows == 0 then
    rows = diff_rows(details.diff, details.firstChangedLine)
  end
  if #rows == 0 then return fallback end
  return presentation(arguments.path, rows, opts)
end

return M
