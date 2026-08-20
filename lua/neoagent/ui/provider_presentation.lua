local util = require("neoagent.util")

local M = {}

local level_groups = {
  info = "NeoagentAccent",
  success = "NeoagentGreen",
  warn = "DiagnosticWarn",
  error = "NeoagentError",
  muted = "NeoagentMuted",
}

local level_symbols = {
  info = "●",
  success = "●",
  warn = "!",
  error = "×",
  muted = "○",
}

local function content()
  return { lines = {}, highlights = {}, line_groups = {} }
end

local function add_line(result, line, spans)
  local row = #result.lines
  result.lines[#result.lines + 1] = line
  for _, span in ipairs(spans or {}) do
    if span.end_col > span.col then
      result.highlights[#result.highlights + 1] = {
        row = row,
        col = span.col,
        end_col = span.end_col,
        group = span.group,
      }
    end
  end
end

local function separate(result)
  if #result.lines > 0 and result.lines[#result.lines] ~= "" then
    add_line(result, "")
  end
end

local function progress_bar(value, width)
  if type(value) ~= "number" then return "···" end
  local suffix = " " .. tostring(math.floor(value * 100 + 0.5)) .. "%"
  local available = math.max(1, math.min(40, (width or 46)
    - vim.fn.strdisplaywidth(suffix)))
  local filled = math.floor(value * available + 0.5)
  local complete = string.rep("█", filled)
  local remaining = string.rep("─", available - filled)
  return complete .. remaining .. suffix, #complete, #complete + #remaining
end

local function add_progress(result, block, width)
  local line = block.label
  if block.detail and block.detail ~= "" then
    line = line .. "  " .. block.detail
  end
  add_line(result, line, {
    { col = 0, end_col = #block.label, group = "NeoagentMarkdownBold" },
    { col = #block.label, end_col = #line, group = "NeoagentMuted" },
  })
  local bar, complete_end, meter_end = progress_bar(block.value, width)
  local group = level_groups[block.level or "info"] or "NeoagentAccent"
  local spans
  if complete_end then
    spans = {
      { col = 0, end_col = complete_end, group = group },
      { col = complete_end, end_col = meter_end, group = "NeoagentMuted" },
      { col = meter_end, end_col = #bar, group = "NeoagentMuted" },
    }
  else
    spans = { { col = 0, end_col = #bar, group = group } }
  end
  add_line(result, bar, spans)
end

local function add_status(result, block)
  local symbol = level_symbols[block.level] or level_symbols.info
  local line = symbol .. " " .. block.text
  add_line(result, line, {
    {
      col = 0,
      end_col = #symbol,
      group = level_groups[block.level] or "NeoagentAccent",
    },
    { col = #symbol + 1, end_col = #line, group = "NeoagentMarkdownBold" },
  })
end

local function add_field(result, block)
  local line = block.label .. "  " .. block.value
  add_line(result, line, {
    { col = 0, end_col = #block.label, group = "NeoagentMuted" },
    { col = #block.label + 2, end_col = #line, group = "Normal" },
  })
end

local function add_list(result, block)
  add_line(result, block.title, {
    { col = 0, end_col = #block.title, group = "NeoagentMarkdownBold" },
  })
  for _, item in ipairs(block.items) do
    local line = "  " .. item.label
    if item.detail and item.detail ~= "" then
      line = line .. " · " .. item.detail
    end
    add_line(result, line, {
      { col = 0, end_col = #line, group = "NeoagentMuted" },
    })
  end
end

local function add_activity(result, block)
  add_line(result, block.title, {
    { col = 0, end_col = #block.title, group = "NeoagentMarkdownBold" },
  })
  for _, entry in ipairs(block.entries) do
    local symbol = level_symbols[entry.level] or level_symbols.info
    local line = "  " .. symbol .. " " .. entry.message
    add_line(result, line, {
      {
        col = 2,
        end_col = 2 + #symbol,
        group = level_groups[entry.level] or "NeoagentMuted",
      },
      { col = 3 + #symbol, end_col = #line, group = "NeoagentMuted" },
    })
  end
end

local function add_block(result, block, width, previous)
  local grouped_field = block.type == "field" and previous == "field"
  if not grouped_field then separate(result) end
  if block.type == "status" then
    add_status(result, block)
  elseif block.type == "field" then
    add_field(result, block)
  elseif block.type == "progress" then
    add_progress(result, block, width)
  elseif block.type == "list" then
    add_list(result, block)
  elseif block.type == "activity" then
    add_activity(result, block)
  end
end

local function add_operation(result, operation, width)
  if not operation then return end
  separate(result)
  add_progress(result, {
    label = operation.label,
    value = operation.ratio,
    detail = operation.message or operation.state,
    level = operation.state == "failed" and "error"
      or operation.state == "succeeded" and "success" or "info",
  }, width)
  if operation.detail and operation.detail ~= "" then
    add_line(result, operation.detail, {
      { col = 0, end_col = #operation.detail, group = "NeoagentMuted" },
    })
  end
end

function M.render(snapshot, opts)
  opts = opts or {}
  local result = content()
  local state = snapshot and snapshot.state
  if state and state ~= false then
    local previous
    for _, block in ipairs(state.blocks or {}) do
      add_block(result, block, opts.width, previous)
      previous = block.type
    end
    add_operation(result, state.operation, opts.width)
  end

  local selectable
  local operations = snapshot and snapshot.operations
  if type(operations) == "table" and util.is_list(operations)
      and #operations > 0 then
    separate(result)
    add_line(result, "Operations", {
      { col = 0, end_col = 10, group = "NeoagentMarkdownBold" },
    })
    for _, operation in ipairs(operations) do
      local line = "  " .. operation.label
      local description = operation.description or ""
      if description ~= "" then line = line .. " · " .. description end
      local group = operation.enabled == false and "NeoagentMuted" or "Normal"
      add_line(result, line, {
        { col = 0, end_col = #line, group = group },
      })
      if operation.enabled ~= false then
        selectable = selectable or {}
        selectable[#result.lines - 1] = {
          kind = "operation",
          id = operation.id,
        }
      end
    end
  end

  if #result.lines == 0 then
    add_line(result, "No provider information", {
      { col = 0, end_col = 23, group = "NeoagentMuted" },
    })
  end

  return {
    title = snapshot and snapshot.name or "Provider",
    content = result,
    selectable = selectable,
  }
end

return M
