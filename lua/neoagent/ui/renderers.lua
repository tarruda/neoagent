local ui = require("applet").Pane.nodes
local markdown = require("neoagent.markdown")
local render = require("neoagent.ui.render")
local tree = require("neoagent.ui.tree")
local tool_presentation = require("neoagent.ui.tool_presentation")

local M = {}
local DETAILS_REGION_TARGET_ROWS = 64

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

local function context(policy, theme, env, continuation, block)
  local spinner = env.spinner or "⠋"
  local previous = type(continuation) == "table"
    and type(continuation.markdown) == "table"
    and continuation.markdown or {}
  local documents = {}
  local value = {
    policy = policy,
    theme = theme,
    config = {
      mappings = { card_details = env.details_key },
      wrap_cards = env.wrap_cards == true,
    },
    resolve_tool = function() return env.tool end,
    spinner_frames = { spinner },
    spinner_frame = 1,
    _content_width = function() return env.width end,
    render_markdown = function(_, key, source, opts)
      local document = previous[key] or markdown.new()
      document:update(source, opts, block.text_epoch)
      documents[key] = document
      return document
    end,
  }
  return value, { markdown = documents }
end

local function decoded_data(block)
  if type(block.data) ~= "string" then return nil end
  local data = block.data
  if data:sub(1, 8) == "\137PNG\r\n\26\n" then return data end
  if vim.base64 and type(vim.base64.decode) == "function" then
    local ok, value = pcall(vim.base64.decode, data)
    if ok and type(value) == "string" then return value end
  end
  return data
end

local function png_data(block)
  local mime = block.mimeType or block.media_type or block.mime_type
  if mime ~= nil and mime ~= "image/png" then return nil end
  local data = decoded_data(block)
  if data and data:sub(1, 8) == "\137PNG\r\n\26\n" then return data end
end

local function byte_size(bytes)
  if bytes < 1024 then return tostring(bytes) .. " B" end
  if bytes < 1024 * 1024 then return string.format("%.1f KiB", bytes / 1024) end
  return string.format("%.1f MiB", bytes / 1024 / 1024)
end

local function image_tag(block, mime, data)
  local format = tostring(mime):match("^image/(.+)$") or tostring(mime)
  local parts = { "Image", format:upper() }
  if data and mime == "image/png" then
    local ok, info = pcall(require("applet").ImageSystem.png_info, data)
    if ok then parts[#parts + 1] = info.width .. "×" .. info.height end
  end
  local decoded = data or decoded_data(block)
  if decoded then parts[#parts + 1] = byte_size(#decoded) end
  return table.concat(parts, " · ")
end

local function identity_component(value)
  value = tostring(value)
  return tostring(#value) .. ":" .. value
end

local function image_slot(value, index)
  if type(value.id) == "string" and value.id ~= "" then
    return identity_component("id") .. identity_component(value.id)
  end
  return identity_component("index") .. identity_component(index)
end

local function image_content(block)
  if type(block.message) == "table" then return block.message.content end
  if type(block.update) == "table" then return block.update.content end
  return block.content
end

local function image_nodes(block, key, native, env)
  local result = {}
  env = env or {}
  local content = image_content(block)
  if type(content) ~= "table" then return result end
  for index, value in ipairs(content) do
    if type(value) == "table" and value.type == "image" then
      local slot = image_slot(value, index)
      local image_key = key .. ":image:" .. slot
      local data = png_data(value)
      local mime = value.mimeType or value.media_type or value.mime_type
        or (data and "image/png") or "image"
      local alt = image_tag(value, mime, data)
      if data and native ~= false then
        local details = env.image_mode == "details"
        local image = ui.image({
          key = image_key,
          source = {
            kind = "png_bytes",
            id = "neoagent:" .. identity_component(
              block.image_scope or "direct")
              .. identity_component(block.key or key)
              .. identity_component(slot),
            data = data,
            revision = value.revision ~= nil and value.revision or 1,
          },
          alt = alt,
          width = details and "native" or "fill",
          height = "auto",
          max_height = not details and 12 or nil,
          fit = "contain",
          align = details and "center" or "left",
          fallback = ui.text({
            key = image_key .. ":fallback",
            runs = { { text = "[" .. alt .. "]", style = "muted" } },
            wrap = "none",
            overflow = "ellipsis",
          }),
        })
        if not details and type(env.width) == "number" and env.width > 1 then
          image = ui.panel({
            key = image_key .. ":inset",
            padding = { left = 1 },
            child = image,
          })
        end
        result[#result + 1] = image
      else
        result[#result + 1] = ui.text({
          key = image_key .. ":fallback",
          runs = { { text = "[" .. alt .. "]", style = "muted" } },
          wrap = "none",
          overflow = "ellipsis",
        })
      end
    end
  end
  return result
end

local function new(policy)
  local theme = tree.theme(render.highlight_definitions)
  local value = {
    name = policy.name,
    theme = theme,
    render_block = function(_, block, env, continuation)
      env = env or {}
      local key = "renderer:" .. tostring(block.key or env.key or "block")
      local render_context, next_continuation = context(
        policy, theme, env, continuation, block)
      local content = render.block(render_context, block, {
        previous = env.previous,
        next = env.following,
      })
      if content.card and content.card.last < content.card.first then
        content.card = nil
      end
      local images = image_nodes(block, key, env.show_images, env)
      local focus = tree.focus(block, content, {
        width = env.surface_width or (env.width and env.width + 2) or 2,
        details_key = env.details_key,
        attachments = #images > 0,
        focus = {
          header = block.header,
          resting_header = block.resting_header,
          overflow = block.overflow == true,
          inline_multiline_tool_outline = policy.inline_multiline_tool_outline == true,
          inline_single_line_tool_hint = policy.inline_single_line_tool_hint == true,
        },
      })
      local node = tree.content(key, content, {
        target_key = "card:" .. tostring(block.key or env.key or "block"),
        action = ui.action("transcript.details", {
          block = block.key or env.key,
        }),
        focus = focus,
        attachments = images,
      })
      return node, next_continuation
    end,
    render_details = function(_, block, env, continuation)
      env = env or {}
      local render_context, next_continuation = context(
        policy, theme, env, continuation, block)
      local content, background = render.details(
        render_context, block, { width = env.width })
      if not content then return nil end
      local details_key = "details:" .. tostring(block.key or env.key or "block")
      local images = image_nodes(
        block, details_key, true,
        vim.tbl_extend("force", env, { image_mode = "details" }))
      local node
      if content.markdown_document then
        node, next_continuation.tree = tree.retained_markdown(
          details_key, content, {
            wrap = "native",
            partition_rows = DETAILS_REGION_TARGET_ROWS,
            line_group = background,
            attachments = images,
          }, continuation and continuation.tree)
      else
        if background then
          content.line_groups = content.line_groups or {}
          for row = 0, #content.lines - 1 do
            content.line_groups[row] = content.line_groups[row] or background
          end
        end
        node = tree.content(details_key, content, {
          wrap = "native",
          partition_rows = DETAILS_REGION_TARGET_ROWS,
          attachments = images,
        })
      end
      return node, next_continuation
    end,
  }
  return value
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
