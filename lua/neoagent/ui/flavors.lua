local M = {}

local function pi_tool_background(state)
  if state == "error" then return "NeoagentToolErrorBackground" end
  if state == "success" then return "NeoagentToolSuccessBackground" end
  return "NeoagentToolPendingBackground"
end

local function prose(kind)
  return kind == "assistant" or kind == "thinking"
end

M.pi = {
  name = "pi",
  user_background = function() return "NeoagentUserBackground" end,
  compaction_background = function() return "NeoagentUserBackground" end,
  tool_background = pi_tool_background,
  tool_title = function(parts) return parts end,
  plain_output_group = function(error)
    return error and "NeoagentError" or "NeoagentToolOutput"
  end,
  write_output_group = function() return "NeoagentToolOutput" end,
  read_source_syntax = false,
  write_source_syntax = false,
  inline_single_line_tool_hint = false,
  inline_multiline_tool_outline = false,
  separator = function() end,
}

M.codex = {
  name = "codex",
  user_background = function() return "NeoagentCodexUserBackground" end,
  compaction_background = function() end,
  tool_background = function() end,
  plain_output_group = function() return "Normal" end,
  write_output_group = function() end,
  read_source_syntax = true,
  write_preview_lines = 3,
  write_source_syntax = true,
  inline_single_line_tool_hint = true,
  inline_multiline_tool_outline = true,
  tool_title = function(parts, status)
    local group, style = "NeoagentMuted", "muted"
    if status == "success" then
      group, style = "NeoagentCodexToolSuccess", "codex_tool_success"
    elseif status == "error" then
      group, style = "NeoagentCodexToolError", "codex_tool_error"
    end
    local title = {
      { text = "•", group = group, style = style },
      { text = " " },
    }
    vim.list_extend(title, parts)
    return title
  end,
  separator = function(previous, current)
    if not previous or not current then return nil end
    if previous.kind == "tool" and prose(current.kind) then
      return "after_previous"
    end
    if prose(previous.kind) and current.kind == "tool" then
      return "before_current"
    end
  end,
}

local values = { pi = M.pi, codex = M.codex }

function M.get(name)
  return values[name]
end

function M.names()
  return { "pi", "codex" }
end

return M
