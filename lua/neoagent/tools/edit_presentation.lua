local activity = require("neoagent.tools.activity_presentation")

local M = {}

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

function M.render(opts)
  local fallback = activity.edit(opts)
  if type(opts) ~= "table" or opts.state ~= "success" then return fallback end
  local arguments = type(opts.arguments) == "table" and opts.arguments or {}
  if type(arguments.path) ~= "string" then return fallback end
  local details = type(opts.result) == "table"
      and type(opts.result.details) == "table" and opts.result.details or {}
  local rows = patch_rows(details.patch)
  if #rows == 0 then
    rows = diff_rows(details.diff, details.firstChangedLine)
  end
  if #rows == 0 then return fallback end
  return {
    kind = "edit",
    path = arguments.path,
    rows = rows,
  }
end

return M
