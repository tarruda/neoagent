local M = {}

local function wrapped_lines(text, width)
  width = math.max(20, width)
  local result = {}
  for _, source in ipairs(vim.split(tostring(text or ""), "\n",
    { plain = true })) do
    if source == "" then
      result[#result + 1] = ""
    else
      local remaining = source
      while vim.fn.strdisplaywidth(remaining) > width do
        local count = 1
        while count < vim.fn.strchars(remaining)
            and vim.fn.strdisplaywidth(
              vim.fn.strcharpart(remaining, 0, count + 1)) <= width do
          count = count + 1
        end
        result[#result + 1] = vim.fn.strcharpart(remaining, 0, count)
        remaining = vim.fn.strcharpart(remaining, count)
      end
      result[#result + 1] = remaining
    end
  end
  return result
end

local function content()
  return { lines = {}, highlights = {}, line_groups = {} }
end

local function add(result, text, group, line_group)
  local row = #result.lines
  result.lines[#result.lines + 1] = text
  if group and text ~= "" then
    result.highlights[#result.highlights + 1] = {
      row = row,
      col = 0,
      end_col = #text,
      group = group,
    }
  end
  if line_group then result.line_groups[row] = line_group end
end

local function queue_text(snapshot)
  if not snapshot.queue_count or snapshot.queue_count <= 0 then return nil end
  return string.format("%d more dialog%s pending", snapshot.queue_count,
    snapshot.queue_count == 1 and "" or "s")
end

local function transcript(snapshot, width)
  local dialog = snapshot.active
  local result = content()
  local background = "NeoagentDialogBackground"
  add(result, string.rep("─", math.max(1, width)), nil, background)
  add(result, dialog.title, "NeoagentDialogTitle", background)
  add(result, "", nil, background)
  for _, line in ipairs(wrapped_lines(dialog.body, width)) do
    add(result, line, nil, background)
  end
  add(result, "", nil, background)
  for _, action in ipairs(dialog.actions) do
    add(result, string.format("[%s] %s", action.key, action.label),
      "NeoagentDialogAction", background)
  end
  local queued = queue_text(snapshot)
  if queued then add(result, queued, "NeoagentMuted", background) end
  return { content = result }
end

local function floating(snapshot, width)
  local dialog = snapshot.active
  local result = content()
  for _, line in ipairs(wrapped_lines(dialog.body, width - 2)) do
    add(result, line, nil, "NormalFloat")
  end
  if dialog.input then
    if #result.lines > 0 then add(result, "", nil, "NormalFloat") end
    add(result, dialog.input.label, "NeoagentDialogTitle", "NormalFloat")
  end
  add(result, "", nil, "NormalFloat")
  local action_lines = {}
  for _, action in ipairs(dialog.actions) do
    action_lines[#action_lines + 1] =
      string.format("[%s] %s", action.key, action.label)
  end
  add(result, table.concat(action_lines, "  "),
    "NeoagentDialogAction", "NormalFloat")
  local queued = queue_text(snapshot)
  if queued then add(result, queued, "NeoagentMuted", "NormalFloat") end
  return {
    content = result,
    title = " " .. dialog.title .. " ",
  }
end

function M.render(snapshot, opts)
  if opts.surface == "float" then
    return floating(snapshot, opts.width)
  end
  return transcript(snapshot, opts.width)
end

return M
