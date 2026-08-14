local util = require("neoagent.util")

local M = {}

local required_methods = {
  "render_block",
  "render_details",
  "render_dialog",
}

local optional_methods = {
  "define_highlights",
  "render_focus",
  "render_status",
}

local function failure(message)
  return nil, util.error("ui", message)
end

function M.validate(value)
  if type(value) ~= "table" then
    return failure("Renderer must be a table")
  end
  if type(value.name) ~= "string" or value.name == "" then
    return failure("Renderer name must be a non-empty string")
  end
  for _, method in ipairs(required_methods) do
    if type(value[method]) ~= "function" then
      return failure("Renderer must implement " .. method)
    end
  end
  for _, method in ipairs(optional_methods) do
    if value[method] ~= nil and type(value[method]) ~= "function" then
      return failure("Renderer " .. method .. " must be a function")
    end
  end
  return value
end

function M.assert(value, prefix)
  local renderer, err = M.validate(value)
  assert(renderer, (prefix and prefix .. ": " or "")
    .. (err and err.message or "invalid Renderer"))
  return renderer
end

local semantic_block_fields = {
  "kind", "content", "text", "extra", "error", "name", "state", "call",
  "raw", "update", "message", "finished", "summary", "tokens_before",
}

function M.copy_block(block)
  local result = {}
  for _, key in ipairs(semantic_block_fields) do
    if block[key] ~= nil then result[key] = util.copy(block[key]) end
  end
  return result
end

local function validate_content(value, label, optional)
  if value == nil and optional then return value end
  if type(value) ~= "table" then
    return failure(label .. " must return a presentation table")
  end
  value = util.copy(value)
  if value.highlights == nil then value.highlights = {} end
  if value.line_groups == nil then value.line_groups = {} end
  if not util.is_list(value.lines) then
    return failure(label .. " presentation lines must be a list")
  end
  for _, line in ipairs(value.lines) do
    if type(line) ~= "string" or line:find("[\r\n]")
        or not util.is_valid_utf8(line) then
      return failure(label
        .. " presentation lines must contain physical UTF-8 strings")
    end
  end
  if not util.is_list(value.highlights) then
    return failure(label .. " presentation highlights must be a list")
  end
  for _, span in ipairs(value.highlights) do
    if type(span) ~= "table" or type(span.row) ~= "number"
        or span.row < 0 or span.row % 1 ~= 0
        or type(span.col) ~= "number" or span.col < 0
        or span.col % 1 ~= 0 or type(span.end_col) ~= "number"
        or span.end_col < span.col or span.end_col % 1 ~= 0
        or type(span.group) ~= "string" or span.group == ""
        or not value.lines[span.row + 1]
        or span.end_col > #value.lines[span.row + 1] then
      return failure(label .. " presentation contains an invalid highlight")
    end
    if span.priority ~= nil and (type(span.priority) ~= "number"
        or span.priority < 0 or span.priority % 1 ~= 0) then
      return failure(label
        .. " presentation contains an invalid highlight priority")
    end
  end
  if type(value.line_groups) ~= "table" then
    return failure(label .. " presentation line_groups must be a table")
  end
  for row, group in pairs(value.line_groups) do
    if type(row) ~= "number" or row < 0 or row % 1 ~= 0
        or not value.lines[row + 1] or type(group) ~= "string"
        or group == "" then
      return failure(label .. " presentation contains an invalid line group")
    end
  end
  local function row(candidate)
    return type(candidate) == "number" and candidate >= 0
      and candidate % 1 == 0
  end
  if value.card ~= nil then
    local card = value.card
    if type(card) ~= "table" or not row(card.first) or not row(card.last)
        or card.first > card.last or not value.lines[card.last + 1]
        or card.after ~= nil and (not row(card.after)
          or not value.lines[card.after + 1]) then
      return failure(label .. " presentation contains invalid card metadata")
    end
  end
  if value.separators ~= nil then
    if type(value.separators) ~= "table" then
      return failure(label
        .. " presentation contains invalid separator metadata")
    end
    for side, separator in pairs(value.separators) do
      if (side ~= "before" and side ~= "after") or not row(separator)
          or not value.lines[separator + 1] then
        return failure(label
          .. " presentation contains invalid separator metadata")
      end
    end
  end
  if value.source ~= nil then
    local source = value.source
    if type(source) ~= "table" or type(source.path) ~= "string"
        or source.path == "" or not row(source.first) or not row(source.last)
        or source.first > source.last or not value.lines[source.last + 1] then
      return failure(label .. " presentation contains invalid source metadata")
    end
  end
  if value.animated ~= nil and type(value.animated) ~= "boolean" then
    return failure(label .. " presentation animated must be a boolean")
  end
  if value.background ~= nil and (type(value.background) ~= "string"
      or value.background == "") then
    return failure(label .. " presentation background must be a highlight group")
  end
  if value.focus ~= nil then
    local focus = value.focus
    if type(focus) ~= "table"
        or focus.header ~= nil and type(focus.header) ~= "string"
        or focus.resting_header ~= nil
          and type(focus.resting_header) ~= "string"
        or focus.overflow ~= nil and type(focus.overflow) ~= "boolean"
        or focus.inline_multiline_tool_outline ~= nil
          and type(focus.inline_multiline_tool_outline) ~= "boolean"
        or focus.inline_single_line_tool_hint ~= nil
          and type(focus.inline_single_line_tool_hint) ~= "boolean" then
      return failure(label .. " presentation contains invalid focus metadata")
    end
  end
  return value
end

local function invoke(renderer, method, block, opts, optional)
  local copied = M.copy_block(block)
  local options = util.copy(opts or {})
  if options.previous then options.previous = M.copy_block(options.previous) end
  if options.following then options.following = M.copy_block(options.following) end
  local ok, value = pcall(renderer[method], renderer, copied, options)
  if not ok then
    return failure("Renderer " .. renderer.name .. " " .. method
      .. " failed: " .. tostring(value))
  end
  return validate_content(value,
    "Renderer " .. renderer.name .. " " .. method, optional)
end

function M.render_block(renderer, block, opts)
  return invoke(renderer, "render_block", block, opts, false)
end

function M.render_details(renderer, block, opts)
  return invoke(renderer, "render_details", block, opts, true)
end

function M.render_dialog(renderer, snapshot, opts)
  local ok, value = pcall(renderer.render_dialog, renderer,
    util.copy(snapshot), util.copy(opts or {}))
  if not ok then
    return failure("Renderer " .. renderer.name
      .. " render_dialog failed: " .. tostring(value))
  end
  if type(value) ~= "table" then
    return failure("Renderer " .. renderer.name
      .. " render_dialog must return a dialog presentation")
  end
  local content, err = validate_content(value.content,
    "Renderer " .. renderer.name .. " render_dialog", false)
  if not content then return nil, err end
  if value.title ~= nil and (type(value.title) ~= "string"
      or value.title:find("[\r\n]")
      or not util.is_valid_utf8(value.title)) then
    return failure("Renderer " .. renderer.name
      .. " dialog title must be a physical UTF-8 string")
  end
  return {
    content = content,
    title = value.title,
  }
end

function M.render_status(renderer, status, opts)
  if type(renderer.render_status) ~= "function" then return nil end
  local ok, value = pcall(renderer.render_status, renderer,
    util.copy(status), util.copy(opts or {}))
  if not ok then
    return failure("Renderer " .. renderer.name
      .. " render_status failed: " .. tostring(value))
  end
  return validate_content(value,
    "Renderer " .. renderer.name .. " render_status", true)
end

local positions = {
  overlay = true,
  eol = true,
  right_align = true,
  inline = true,
}

local function validate_decorations(value, label, lines)
  if not util.is_list(value) then
    return failure(label .. " must return a decoration list")
  end
  lines = lines or {}
  for _, decoration in ipairs(value) do
    if type(decoration) ~= "table"
        or type(decoration.row) ~= "number" or decoration.row < 0
        or decoration.row % 1 ~= 0 or not lines[decoration.row + 1]
        or not util.is_list(decoration.chunks) or #decoration.chunks == 0
        or decoration.position ~= nil
          and not positions[decoration.position]
        or decoration.win_col ~= nil
          and (type(decoration.win_col) ~= "number"
            or decoration.win_col < 0 or decoration.win_col % 1 ~= 0)
        or decoration.priority ~= nil
          and (type(decoration.priority) ~= "number"
            or decoration.priority < 0 or decoration.priority % 1 ~= 0) then
      return failure(label .. " contains an invalid decoration")
    end
    for _, chunk in ipairs(decoration.chunks) do
      if type(chunk) ~= "table" or type(chunk.text) ~= "string"
          or chunk.text:find("[\r\n]")
          or not util.is_valid_utf8(chunk.text)
          or type(chunk.group) ~= "string" or chunk.group == "" then
        return failure(label .. " contains an invalid decoration chunk")
      end
    end
  end
  return util.copy(value)
end

function M.render_focus(renderer, block, opts)
  if type(renderer.render_focus) ~= "function" then return {} end
  local options = util.copy(opts or {})
  local ok, value = pcall(renderer.render_focus, renderer,
    M.copy_block(block), options)
  if not ok then
    return failure("Renderer " .. renderer.name
      .. " render_focus failed: " .. tostring(value))
  end
  return validate_decorations(value,
    "Renderer " .. renderer.name .. " render_focus", options.lines)
end

function M.define_highlights(renderer)
  if type(renderer.define_highlights) ~= "function" then return true end
  local ok, err = pcall(renderer.define_highlights, renderer)
  if not ok then
    return failure("Renderer " .. renderer.name
      .. " define_highlights failed: " .. tostring(err))
  end
  return true
end

return M
