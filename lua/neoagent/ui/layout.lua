local M = {}

local function border_size(border)
  if border == nil or border == "none" or border == "" then return 0 end
  return 2
end

local function dimension(value, available, fallback)
  if value == nil then return math.floor(available * fallback + 0.5) end
  if value <= 1 then return math.floor(available * value + 0.5) end
  return value
end

function M.layout(opts)
  local columns = assert(opts.columns)
  local lines = assert(opts.lines)
  local margin = opts.margin or 1
  local position = opts.position or "right"
  local container = opts.container or { row = 0, col = 0, width = columns, height = lines }
  local horizontal = position == "left" or position == "right"
  local vertical = position == "top" or position == "bottom"
  local default_width = horizontal and 0.45 or position == "center" and 0.95 or 1
  local default_height = vertical and 0.45 or position == "center" and 0.95 or 1
  local available_width = math.max(0, container.width - margin * 2)
  local available_height = math.max(0, container.height - margin * 2)
  local outer_width = math.min(available_width, dimension(opts.width, container.width, default_width))
  local outer_height = math.min(available_height, dimension(opts.height, container.height, default_height))
  local borders = border_size(opts.border)
  local content_width = outer_width - borders
  local input_height = math.min(opts.input_height or 7, outer_height - borders * 2 - 1)
  local transcript_height = outer_height - input_height - borders * 2
  if content_width < 1 or input_height < 1 or transcript_height < 1 then
    return nil, "Neoagent UI does not fit in the available editor area"
  end

  local row, col
  if position == "left" then
    row, col = container.row + margin, container.col + margin
  elseif position == "right" then
    row, col = container.row + margin, container.col + container.width - margin - outer_width
  elseif position == "top" then
    row, col = container.row + margin, container.col + margin
  elseif position == "bottom" then
    row, col = container.row + container.height - margin - outer_height, container.col + margin
  else
    row = container.row + math.floor((container.height - outer_height) / 2)
    col = container.col + math.floor((container.width - outer_width) / 2)
  end
  row = math.max(container.row, row)
  col = math.max(container.col, col)
  local common = {
    relative = "editor",
    style = "minimal",
    focusable = true,
    border = opts.border,
    zindex = opts.zindex or 50,
  }

  local provider
  if opts.provider then
    local provider_position = opts.provider_position or "right"
    if provider_position == "right" then
      local desired = math.min(content_width - 11,
        dimension(opts.provider_width, outer_width, 0.4))
      if desired < 1 or content_width - desired - 1 < 10 then
        return nil, "Provider console does not fit in the available editor area"
      end
      local transcript_width = content_width - desired - 1
      provider = vim.tbl_extend("force", common, {
        row = row,
        col = col + transcript_width + 1,
        width = desired,
        height = transcript_height,
      })
      return {
        transcript = vim.tbl_extend("force", common, {
          row = row,
          col = col,
          width = transcript_width,
          height = transcript_height,
        }),
        provider = provider,
        input = vim.tbl_extend("force", common, {
          row = row + transcript_height + borders,
          col = col,
          width = content_width,
          height = input_height,
        }),
      }
    end
    local desired_height = math.min(transcript_height - 4,
      dimension(opts.provider_height, outer_height, 0.35))
    if desired_height < 1 or transcript_height - desired_height < 4 then
      return nil, "Provider console does not fit in the available editor area"
    end
    local divider = math.max(1, borders)
    local transcript_size = transcript_height - desired_height - divider
    if provider_position == "top" then
      provider = vim.tbl_extend("force", common, {
        row = row,
        col = col,
        width = content_width,
        height = desired_height,
      })
      return {
        transcript = vim.tbl_extend("force", common, {
          row = row + desired_height + divider,
          col = col,
          width = content_width,
          height = transcript_size,
        }),
        provider = provider,
        input = vim.tbl_extend("force", common, {
          row = row + transcript_height + borders,
          col = col,
          width = content_width,
          height = input_height,
        }),
      }
    end
    provider = vim.tbl_extend("force", common, {
      row = row + transcript_size + divider,
      col = col,
      width = content_width,
      height = desired_height,
    })
    return {
      transcript = vim.tbl_extend("force", common, {
        row = row,
        col = col,
        width = content_width,
        height = transcript_size,
      }),
      provider = provider,
      input = vim.tbl_extend("force", common, {
        row = row + transcript_height + borders,
        col = col,
        width = content_width,
        height = input_height,
      }),
    }
  end

  return {
    transcript = vim.tbl_extend("force", common, { row = row, col = col, width = content_width, height = transcript_height }),
    input = vim.tbl_extend("force", common, { row = row + transcript_height + borders, col = col, width = content_width, height = input_height }),
  }
end

return M
