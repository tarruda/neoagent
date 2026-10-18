local Applet = require("applet")
local util = require("neoagent.util")

---@class Neoagent.ToolStyledText
---@field text string
---@field style? string|string[]
---@field group? string

---@class Neoagent.ToolViewPresentation
---@field default? boolean
---@field status? boolean
---@field title? true|Neoagent.ToolStyledText[]
---@field command? string
---@field lines? Neoagent.ToolStyledText[][]
---@field animated? boolean

---@class Neoagent.ToolViewOptions
---@field state? string
---@field presentation_surface? 'transcript'|'details'
---@field width? integer
---@field spinner? string

---@class Neoagent.ToolTextPresentation
---@field kind 'text'
---@field title? string
---@field lines? string[]
---@field include_output? boolean

local M = {}
local display = Applet.Pane.text
local EDIT_PREVIEW_LINES = 10
local SEARCH_PREVIEW_RESULTS = 3
local compact_activities = {
  command = true,
  read = true,
  search = true,
}

---@param value string
---@return boolean
local function one_line(value)
  return not value:find("[\r\n]")
end

---@param state? string
---@return boolean
local function active(state)
  return state ~= "success" and state ~= "error"
end

---@param text? string
---@param available integer
---@return string[]
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

---@param text? string
---@param width integer
---@return string[]
local function compact_characters(text, width)
  text = (text or ""):gsub("\t", "    ")
  if text == "" then
    return { "" }
  end
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

---@param value Neoagent.ToolActivityPresentation
---@param opts Neoagent.ToolViewOptions
---@return Neoagent.ToolViewPresentation?
local function activity(value, opts)
  if
    type(value.operation) ~= "string"
    or type(value.ongoing) ~= "string"
    or not one_line(value.ongoing)
    or type(value.complete) ~= "string"
    or not one_line(value.complete)
    or type(value.subject) ~= "string"
    or not one_line(value.subject)
    or value.command ~= nil and type(value.command) ~= "string"
  then
    return nil
  end
  local verb = active(opts.state) and value.ongoing or value.complete
  local details = opts.presentation_surface == "details"
  ---@type Neoagent.ToolViewPresentation
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
    result.title = { { text = verb, style = "bold" } }
    result.command = value.command
  end
  return result
end

---@param value Neoagent.ToolPlanPresentation
---@param opts Neoagent.ToolViewOptions
---@param codex boolean
---@return Neoagent.ToolStyledText[]?
local function plan_body(value, opts, codex)
  if not util.is_list(value.plan) then
    return nil
  end
  if value.explanation ~= nil and type(value.explanation) ~= "string" then
    return nil
  end
  ---@type Neoagent.ToolStyledText[]
  local body = {}
  local body_width = opts.presentation_surface == "transcript" and math.max(1, (opts.width or 80) - (codex and 4 or 2))
    or nil
  ---@param text? string
  ---@param width? integer
  ---@return string[]
  local function lines(text, width)
    if width then
      return compact_words(text, width)
    end
    return display.lines(text or "")
  end
  local explanation = type(value.explanation) == "string" and util.trim(value.explanation) or ""
  if explanation ~= "" then
    for _, line in ipairs(lines(explanation, body_width)) do
      body[#body + 1] = { text = line, style = { "muted", "italic" } }
    end
  end
  local steps = assert(value.plan)
  if #steps == 0 then
    body[#body + 1] = {
      text = "(no steps provided)",
      style = { "muted", "italic" },
    }
  else
    for _, item in ipairs(steps) do
      if
        type(item) ~= "table"
        or type(item.step) ~= "string"
        or item.status ~= "pending" and item.status ~= "in_progress" and item.status ~= "completed"
      then
        return nil
      end
      local marker = codex and (item.status == "completed" and "✔ " or "□ ")
        or (item.status == "completed" and "[x] " or "[ ] ")
      local style = item.status == "completed" and { "muted", "strike" }
        or item.status == "in_progress" and (codex and { "cyan", "bold" } or "bold")
        or "muted"
      local marker_width = codex and 2 or 4
      local available = body_width and body_width - marker_width or nil
      for index, line in ipairs(lines(item.step, available)) do
        body[#body + 1] = {
          text = (index == 1 and marker or string.rep(" ", marker_width)) .. line,
          style = style,
        }
      end
    end
  end
  return body
end

---@param value Neoagent.ToolPlanPresentation
---@param opts Neoagent.ToolViewOptions
---@param codex boolean
---@return Neoagent.ToolViewPresentation?
local function plan(value, opts, codex)
  if value.plan == nil and active(opts.state) then
    if not codex then
      return nil
    end
    return {
      animated = true,
      title = {
        { text = opts.spinner or "⠋", style = "cyan" },
        { text = " Updating plan", style = "muted" },
      },
    }
  end
  local body = plan_body(value, opts, codex)
  if not body then
    return nil
  end
  ---@type Neoagent.ToolStyledText[][]
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

---@param path string
---@param added integer
---@param removed integer
---@return Neoagent.ToolStyledText[]
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

---@param rows Neoagent.EditPatchRow[]
---@param width? integer
---@param maximum_lines? integer
---@return_overload Neoagent.ToolStyledText[][], integer
---@return_overload nil, nil
local function edit_rows(rows, width, maximum_lines)
  ---@type Neoagent.ToolStyledText[][]
  local result = {}
  local omitted, maximum = 0, 1
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
    elseif
      type(row.number) ~= "number"
      or type(row.text) ~= "string"
      or row.kind ~= "add" and row.kind ~= "delete" and row.kind ~= "context"
    then
      return nil
    elseif maximum_lines and #result >= maximum_lines then
      omitted = omitted + 1
    else
      local style = row.kind == "add" and "green" or row.kind == "delete" and "red" or nil
      local sign = row.kind == "add" and "+" or row.kind == "delete" and "-" or " "
      local chunks = available and compact_characters(row.text, available) or { row.text }
      for index, chunk in ipairs(chunks) do
        if maximum_lines and #result >= maximum_lines then
          omitted = omitted + 1
        else
          ---@type Neoagent.ToolStyledText[]
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

---@param value Neoagent.ToolEditPresentation
---@param opts Neoagent.ToolViewOptions
---@return Neoagent.ToolViewPresentation?
local function edit(value, opts)
  if type(value.path) ~= "string" or not one_line(value.path) or not util.is_list(value.rows) then
    return nil
  end
  if
    type(value.added) ~= "number"
    or value.added < 0
    or value.added % 1 ~= 0
    or type(value.removed) ~= "number"
    or value.removed < 0
    or value.removed % 1 ~= 0
    or value.truncated ~= nil and type(value.truncated) ~= "boolean"
  then
    return nil
  end
  local compact = opts.presentation_surface == "transcript"
  local maximum = compact and EDIT_PREVIEW_LINES or nil
  local lines, omitted = edit_rows(value.rows, compact and (opts.width or 80) or nil, maximum)
  if not lines then
    return nil
  end
  if omitted > 0 then
    lines[#lines + 1] = {
      {
        text = string.format("   [... %d more line%s]", omitted, omitted == 1 and "" or "s"),
        style = "muted",
      },
    }
  end
  if value.truncated then
    lines[#lines + 1] = {
      { text = "   [... patch truncated]", style = "muted" },
    }
  end
  return {
    title = edit_summary(value.path, value.added, value.removed),
    lines = lines,
    status = true,
  }
end

---@param value Neoagent.ToolPatchPresentation
---@param opts Neoagent.ToolViewOptions
---@return Neoagent.ToolViewPresentation?
local function patch(value, opts)
  if not util.is_list(value.files) or #value.files == 0 then
    return nil
  end
  local added, removed, applied = 0, 0, 0
  local lines = {}
  for _, file in ipairs(value.files) do
    if
      type(file) ~= "table"
      or type(file.path) ~= "string"
      or file.kind ~= "add" and file.kind ~= "delete" and file.kind ~= "update"
      or file.status ~= "pending" and file.status ~= "applied" and file.status ~= "failed" and file.status ~= "partial"
      or file.destination ~= nil and (type(file.destination) ~= "string" or not one_line(file.destination))
      or file.error ~= nil and type(file.error) ~= "string"
    then
      return nil
    end
    local path = file.path .. (file.destination and " → " .. file.destination or "")
    local preview = edit({
      kind = "edit",
      path = path,
      rows = file.rows,
      added = file.added,
      removed = file.removed,
      truncated = file.truncated,
    }, opts)
    if not preview then
      return nil
    end
    if file.status == "applied" then
      applied = applied + 1
    end
    if file.status == "applied" or file.status == "partial" then
      added, removed = added + file.added, removed + file.removed
    end
    local verb = file.destination and "Moved" or file.kind == "add" and "Added" or file.kind == "delete" and "Deleted"
      or "Edited"
    local action = file.destination and "move" or file.kind == "add" and "add" or file.kind == "delete" and "delete"
      or "edit"
    if file.status == "pending" then
      verb = "Pending " .. action
    elseif file.status == "failed" then
      verb = "Failed to " .. action
    elseif file.status == "partial" then
      verb = "Partially " .. verb:lower()
    end
    if #lines > 0 then
      lines[#lines + 1] = { { text = "" } }
    end
    local title = preview.title
    assert(type(title) == "table")
    assert(title[1]).text = "   " .. verb
    lines[#lines + 1] = title
    vim.list_extend(lines, assert(preview.lines))
    if file.error then
      local width = opts.presentation_surface == "transcript" and math.max(1, (opts.width or 80) - 3) or nil
      for _, line in ipairs(width and compact_words(file.error, width) or display.lines(file.error)) do
        lines[#lines + 1] = { { text = "   " .. line, style = "red" } }
      end
    end
  end
  return {
    title = edit_summary(applied .. "/" .. #value.files .. " files", added, removed),
    lines = lines,
    status = true,
  }
end

---@param value Neoagent.ToolTextPresentation
---@return Neoagent.ToolViewPresentation?
local function text(value)
  if
    value.title ~= nil and type(value.title) ~= "string"
    or type(value.title) == "string" and not one_line(value.title)
    or value.lines ~= nil and not util.is_list(value.lines)
    or value.include_output ~= nil and type(value.include_output) ~= "boolean"
  then
    return nil
  end
  if value.include_output and value.lines ~= nil then
    return nil
  end
  local lines
  if value.lines then
    lines = {}
    for _, line in ipairs(value.lines) do
      if type(line) ~= "string" or line:find("[\r\n]") then
        return nil
      end
      lines[#lines + 1] = { { text = line } }
    end
  end
  if value.title == nil and lines == nil then
    return nil
  end
  return {
    default = value.include_output == true or nil,
    title = value.title and { { text = value.title, style = "bold" } } or nil,
    lines = lines,
    status = true,
  }
end

---@param value Neoagent.ToolWebSearchPresentation
---@param opts Neoagent.ToolViewOptions
---@return Neoagent.ToolViewPresentation?
local function web_search(value, opts)
  if
    type(value.backend) ~= "string"
    or not one_line(value.backend)
    or type(value.query) ~= "string"
    or not one_line(value.query)
    or value.sources ~= nil and not util.is_list(value.sources)
    or value.truncated ~= nil and type(value.truncated) ~= "boolean"
  then
    return nil
  end
  for _, source in ipairs(value.sources or {}) do
    if
      type(source) ~= "table"
      or type(source.title) ~= "string"
      or not one_line(source.title)
      or type(source.url) ~= "string"
      or not one_line(source.url)
    then
      return nil
    end
  end
  local failed = opts.state == "error"
  local verb = failed and "Web search failed" or active(opts.state) and "Searching web" or "Searched web"
  local title = {
    { text = verb, style = "bold" },
    { text = " · " .. value.backend, style = "muted" },
  }
  local sources = value.sources
  if opts.state == "success" and sources then
    title[#title + 1] = {
      text = " · " .. #sources .. (#sources == 1 and " result" or " results"),
      style = "muted",
    }
  end
  if opts.presentation_surface == "details" or failed or opts.state == "success" and not sources then
    title[#title + 1] = { text = ": " .. value.query, style = "accent" }
    return { title = title, default = true, status = true }
  end
  local width = math.max(1, (opts.width or 80) - 2)
  local lines = {}
  for _, line in ipairs(compact_characters(value.query, math.max(1, width - 2))) do
    lines[#lines + 1] = { { text = "  " .. line, style = "accent" } }
  end
  if opts.state == "success" and sources then
    if #sources == 0 then
      lines[#lines + 1] = { { text = "  No results found.", style = "muted" } }
    end
    for index = 1, math.min(#sources, SEARCH_PREVIEW_RESULTS) do
      local source = assert(sources[index])
      lines[#lines + 1] = {
        { text = "  " .. index .. ". ", style = "muted" },
        {
          text = display.truncate(source.title ~= "" and source.title or "(untitled)", math.max(1, width - 5)),
          style = "bold",
        },
      }
      lines[#lines + 1] = {
        { text = "     " .. display.truncate(source.url, math.max(1, width - 5)), style = "muted" },
      }
    end
    local remaining = #sources - SEARCH_PREVIEW_RESULTS
    if remaining > 0 then
      lines[#lines + 1] = {
        { text = "  … +" .. remaining .. (remaining == 1 and " more result" or " more results"), style = "muted" },
      }
    end
    if value.truncated then
      lines[#lines + 1] = { { text = "  Search output truncated", style = "muted" } }
    end
  end
  return { title = title, lines = lines, status = true }
end

---@param value unknown
---@param opts Neoagent.ToolViewOptions
---@param codex boolean
---@return Neoagent.ToolViewPresentation?
local function present(value, opts, codex)
  if type(value) ~= "table" or type(value.kind) ~= "string" then
    return nil
  end
  if value.kind == "activity" then
    ---@cast value Neoagent.ToolActivityPresentation
    return codex and activity(value, opts) or nil
  elseif value.kind == "plan" then
    ---@cast value Neoagent.ToolPlanPresentation
    return plan(value, opts, codex)
  elseif value.kind == "edit" then
    ---@cast value Neoagent.ToolEditPresentation
    return codex and edit(value, opts) or nil
  elseif value.kind == "patch" then
    ---@cast value Neoagent.ToolPatchPresentation
    return patch(value, opts)
  elseif value.kind == "text" then
    ---@cast value Neoagent.ToolTextPresentation
    return text(value)
  elseif value.kind == "web_search" then
    ---@cast value Neoagent.ToolWebSearchPresentation
    return web_search(value, opts)
  end
end

---@param value unknown
---@param opts Neoagent.ToolViewOptions
---@return Neoagent.ToolViewPresentation?
function M.pi(value, opts)
  return present(value, opts, false)
end

---@param value unknown
---@param opts Neoagent.ToolViewOptions
---@return Neoagent.ToolViewPresentation?
function M.codex(value, opts)
  return present(value, opts, true)
end

return M
