local dialog_presentation = require("neoagent.ui.dialog_presentation")
local focus_presentation = require("neoagent.ui.focus_presentation")
local provider_presentation = require("neoagent.ui.provider_presentation")
local render = require("neoagent.ui.render")
local status_presentation = require("neoagent.ui.status_presentation")
local tool_presentation = require("neoagent.ui.tool_presentation")

local M = {}

local function prose(kind)
  return kind == "assistant" or kind == "thinking"
end

local pi = {
  name = "pi",
  user_background = function() return "NeoagentUserBackground" end,
  compaction_background = function() return "NeoagentUserBackground" end,
  tool_background = function(state)
    if state == "error" then return "NeoagentToolErrorBackground" end
    if state == "success" then return "NeoagentToolSuccessBackground" end
    return "NeoagentToolPendingBackground"
  end,
  tool_title = function(parts) return parts end,
  plain_output_group = function(error)
    return error and "NeoagentError" or "NeoagentToolOutput"
  end,
  write_output_group = function() return "NeoagentToolOutput" end,
  read_source_syntax = false,
  write_source_syntax = false,
  inline_single_line_tool_hint = false,
  inline_multiline_tool_outline = false,
  present_tool = tool_presentation.pi,
  separator = function() end,
}

local codex = {
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
  present_tool = tool_presentation.codex,
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

local function complete(content)
  if not content then return content end
  content.lines = content.lines or {}
  content.highlights = content.highlights or {}
  content.line_groups = content.line_groups or {}
  return content
end

local function context(policy, opts)
  local spinner = opts.spinner or "⠋"
  return {
    policy = policy,
    config = {
      mappings = { card_details = opts.details_key },
      wrap_cards = opts.wrap_cards == true,
    },
    resolve_tool = function() return opts.tool end,
    spinner_frames = { spinner },
    spinner_frame = 1,
    _content_width = function() return opts.width end,
  }
end

local function new(policy)
  return {
    name = policy.name,
    define_highlights = function()
      render.define_highlights()
    end,
    render_block = function(_, block, opts)
      local content = complete(render.block(context(policy, opts), block, {
        previous = opts.previous,
        next = opts.following,
      }))
      if content.card and content.card.last < content.card.first then
        content.card = nil
      end
      content.focus = {
        header = block.header,
        resting_header = block.resting_header,
        overflow = block.overflow == true,
        inline_multiline_tool_outline =
          policy.inline_multiline_tool_outline == true,
        inline_single_line_tool_hint =
          policy.inline_single_line_tool_hint == true,
      }
      return content
    end,
    render_details = function(_, block, opts)
      local content, background = render.details(
        context(policy, opts), block, { width = opts.width })
      content = complete(content)
      if content then content.background = background end
      return content
    end,
    render_dialog = function(_, snapshot, opts)
      return dialog_presentation.render(snapshot, opts)
    end,
    render_focus = function(_, block, opts)
      return focus_presentation.render(block, opts)
    end,
    render_status = function(_, status, opts)
      return status_presentation.render(status, opts)
    end,
    render_provider = function(_, snapshot, opts)
      return provider_presentation.render(snapshot, opts)
    end,
  }
end

M.pi = new(pi)
M.codex = new(codex)

local values = { pi = M.pi, codex = M.codex }

function M.get(name)
  return values[name]
end

function M.names()
  return { "pi", "codex" }
end

return M
