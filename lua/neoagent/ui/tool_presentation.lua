local Applet = require("applet")
local util = require("neoagent.util")

local M = {}
local display = Applet.Pane.text
local EDIT_PREVIEW_LINES = 10
local compact_activities = {
  command = true,
  read = true,
  search = true,
}

local function active(state)
  return state ~= "success" and state ~= "error"
end

local function compact_words(text, available)
  local result = {}
  available = math.max(1, available)
  for _, source in ipairs(display.lines(text or "")) do
    local line = ""
    for word in source:gmatch("%S+") do
      local candidate = line == "" and word or line .. " " .. word
      if line ~= "" and display.width(candidate) > available then
        result[#result + 1] = line
        line = word
      else
        line = candidate
      end
    end
    result[#result + 1] = line
  end
  return result
end

local function compact_characters(text, width)
  text = (text or ""):gsub("\t", "    ")
  if text == "" then return { "" } end
  local result, current, current_width = {}, "", 0
  width = math.max(1, width)
  for character in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local character_width = display.width(character)
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

local function activity(value, opts)
  if type(value.operation) ~= "string"
      or type(value.ongoing) ~= "string" or type(value.complete) ~= "string"
      or type(value.subject) ~= "string"
      or value.command ~= nil and type(value.command) ~= "string" then
    return nil
  end
  local verb = active(opts.state) and value.ongoing or value.complete
  local details = opts.presentation_surface == "details"
  local result = {
    default = not compact_activities[value.operation] or details,
    status = true,
    title = {
      { text = verb, style = "bold" },
      { text = " " .. value.subject },
    },
  }
  if value.command then
    result.default = nil
    result.title = { result.title[1] }
    result.command = value.command
  end
  return result
end

local function plan_body(value, opts, codex)
  if not util.is_list(value.plan) then return nil end
  if value.explanation ~= nil and type(value.explanation) ~= "string" then
    return nil
  end
  local body = {}
  local body_width = opts.presentation_surface == "transcript"
      and math.max(1, (opts.width or 80) - (codex and 4 or 2)) or nil
  local function lines(text, width)
    if width then return compact_words(text, width) end
    return display.lines(text or "")
  end
  local explanation = type(value.explanation) == "string"
      and util.trim(value.explanation) or ""
  if explanation ~= "" then
    for _, line in ipairs(lines(explanation, body_width)) do
      body[#body + 1] = { text = line, style = { "muted", "italic" } }
    end
  end
  if #value.plan == 0 then
    body[#body + 1] = {
      text = "(no steps provided)",
      style = { "muted", "italic" },
    }
  else
    for _, item in ipairs(value.plan) do
      if type(item) ~= "table" or type(item.step) ~= "string"
          or item.status ~= "pending" and item.status ~= "in_progress"
            and item.status ~= "completed" then
        return nil
      end
      local marker = codex and (item.status == "completed" and "✔ " or "□ ")
        or (item.status == "completed" and "[x] " or "[ ] ")
      local style = item.status == "completed" and { "muted", "strike" }
        or item.status == "in_progress"
          and (codex and { "cyan", "bold" } or "bold")
        or "muted"
      local marker_width = codex and 2 or 4
      local available = body_width and body_width - marker_width or nil
      for index, line in ipairs(lines(item.step, available)) do
        body[#body + 1] = {
          text = (index == 1 and marker
            or string.rep(" ", marker_width)) .. line,
          style = style,
        }
      end
    end
  end
  return body
end

local function plan(value, opts, codex)
  if value.plan == nil and active(opts.state) then
    if not codex then return nil end
    return {
      animated = true,
      title = {
        { text = opts.spinner or "⠋", style = "cyan" },
        { text = " Updating plan", style = "muted" },
      },
    }
  end
  local body = plan_body(value, opts, codex)
  if not body then return nil end
  local lines = {}
  if codex then
    for index, item in ipairs(body) do
      lines[#lines + 1] = {
        { text = index == 1 and "   └ " or "     ", style = "muted" },
        { text = item.text, style = item.style },
      }
    end
  else
    for _, item in ipairs(body) do
      lines[#lines + 1] = { { text = item.text, style = item.style } }
    end
  end
  return {
    title = codex and { { text = "Updated Plan", style = "bold" } } or true,
    lines = lines,
  }
end

local function row_counts(rows)
  local added, removed = 0, 0
  for _, row in ipairs(rows) do
    if row.kind == "add" then added = added + 1 end
    if row.kind == "delete" then removed = removed + 1 end
  end
  return added, removed
end

local function edit_summary(path, added, removed)
  return {
    { text = "Edited", style = "bold" },
    { text = " " .. path .. " (" },
    { text = "+" .. added, style = "green" },
    { text = " " },
    { text = "-" .. removed, style = "red" },
    { text = ")" },
  }
end

local function edit_rows(rows, width, maximum_lines)
  local result, omitted, maximum = {}, 0, 1
  for _, row in ipairs(rows) do
    if type(row.number) == "number" then
      maximum = math.max(maximum, row.number)
    end
  end
  local gutter_width = #tostring(maximum)
  local available = width and math.max(1, width - gutter_width - 5) or nil
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
    elseif type(row.number) ~= "number" or type(row.text) ~= "string"
        or row.kind ~= "add" and row.kind ~= "delete"
          and row.kind ~= "context" then
      return nil
    elseif maximum_lines and #result >= maximum_lines then
      omitted = omitted + 1
    else
      local style = row.kind == "add" and "green"
        or row.kind == "delete" and "red" or nil
      local sign = row.kind == "add" and "+"
        or row.kind == "delete" and "-" or " "
      local chunks = available and compact_characters(row.text, available)
        or { row.text }
      for index, chunk in ipairs(chunks) do
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

local function edit(value, opts)
  if type(value.path) ~= "string" or not util.is_list(value.rows) then return nil end
  local compact = opts.presentation_surface == "transcript"
  local maximum = compact and EDIT_PREVIEW_LINES or nil
  local lines, omitted = edit_rows(
    value.rows, compact and (opts.width or 80) or nil, maximum)
  if not lines then return nil end
  if omitted > 0 then
    lines[#lines + 1] = { {
      text = string.format("   [... %d more line%s]",
        omitted, omitted == 1 and "" or "s"),
      style = "muted",
    } }
  end
  local added, removed = row_counts(value.rows)
  return {
    title = edit_summary(value.path, added, removed),
    lines = lines,
    status = true,
  }
end

local function text(value)
  if value.title ~= nil and type(value.title) ~= "string"
      or value.lines ~= nil and not util.is_list(value.lines)
      or value.include_output ~= nil and type(value.include_output) ~= "boolean" then
    return nil
  end
  if value.include_output and value.lines ~= nil then return nil end
  local lines
  if value.lines then
    lines = {}
    for _, line in ipairs(value.lines) do
      if type(line) ~= "string" or line:find("[\r\n]") then return nil end
      lines[#lines + 1] = { { text = line } }
    end
  end
  if value.title == nil and lines == nil then return nil end
  return {
    default = value.include_output == true or nil,
    title = value.title and { { text = value.title, style = "bold" } } or nil,
    lines = lines,
    status = true,
  }
end

local function present(value, opts, codex)
  if type(value) ~= "table" or type(value.kind) ~= "string" then return nil end
  if value.kind == "activity" then
    return codex and activity(value, opts) or nil
  elseif value.kind == "plan" then
    return plan(value, opts, codex)
  elseif value.kind == "edit" then
    return codex and edit(value, opts) or nil
  elseif value.kind == "text" then
    return text(value)
  end
end

function M.pi(value, opts)
  return present(value, opts, false)
end

function M.codex(value, opts)
  return present(value, opts, true)
end

return M
