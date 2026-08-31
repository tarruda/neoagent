local M = {}

local function integer(value)
  return type(value) == "number" and value % 1 == 0
end

local function rectangles_for(range, lines)
  if range.rectangles == nil then return nil end
  if type(range.rectangles) ~= "table" or not vim.islist(range.rectangles) then
    return false
  end
  local result = {}
  for _, rectangle in ipairs(range.rectangles) do
    if type(rectangle) ~= "table"
        or not integer(rectangle.row) or rectangle.row < range.first
        or not integer(rectangle.col) or rectangle.col < 0
        or not integer(rectangle.width) or rectangle.width < 1
        or not integer(rectangle.height) or rectangle.height < 1
        or rectangle.row + rectangle.height > range.last
        or rectangle.row + rectangle.height > #lines then
      return false
    end
    result[#result + 1] = rectangle
  end
  return result
end

local function filetype_for(range, lines)
  if range.language and range.language:match("^[%w_.-]+$") then return range.language end
  if not range.path or range.path == "" then return nil end
  local contents = vim.list_slice(lines, range.first + 1, range.last)
  local ok, filetype = pcall(vim.filetype.match, {
    filename = range.path,
    contents = contents,
  })
  if ok and type(filetype) == "string" and filetype:match("^[%w_.-]+$") then
    return filetype
  end
end

local function clear_current_buffer()
  for index = 1, tonumber(vim.b.applet_source_regions) or 0 do
    vim.cmd("silent! syntax clear AppletSourceContent" .. index)
  end
  vim.b.applet_source_regions = 0
end

function M.clear(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then return end
  vim.api.nvim_buf_call(buffer, clear_current_buffer)
end

function M.apply(buffer, ranges, lines)
  local valid, requested = {}, {}
  for _, range in ipairs(ranges or {}) do
    if type(range.first) == "number" and type(range.last) == "number"
        and range.first >= 0 and range.last >= range.first and range.last <= #lines then
      local filetype = filetype_for(range, lines)
      local rectangles = rectangles_for(range, lines)
      if filetype and rectangles ~= false then
        valid[#valid + 1] = {
          range = range,
          filetype = filetype,
          rectangles = rectangles,
        }
        requested[filetype] = true
      end
    end
  end
  return vim.api.nvim_buf_call(buffer, function()
    clear_current_buffer()
    local loaded, indexes = {}, {}
    for _, filetype in ipairs(vim.b.applet_source_filetypes or {}) do
      loaded[#loaded + 1] = filetype
      indexes[filetype] = #loaded
    end
    local current = vim.b.current_syntax
    for filetype in pairs(requested) do
      if not indexes[filetype] then
        local index = #loaded + 1
        vim.b.current_syntax = nil
        if pcall(vim.cmd, "syntax include @AppletSource" .. index
            .. " syntax/" .. filetype .. ".vim") then
          loaded[index], indexes[filetype] = filetype, index
        end
      end
    end
    vim.b.current_syntax = current
    vim.b.applet_source_filetypes = loaded
    vim.cmd("syntax sync clear")
    local count = 0
    local function linewise_region(item, syntax_index)
      count = count + 1
      local first = "\\%" .. tostring(item.range.first + 1) .. "l"
      local following = item.range.last + 1
      local last = following <= #lines
          and "\\%" .. tostring(following) .. "l" or "\\%$"
      pcall(vim.cmd, "syntax region AppletSourceContent" .. count
        .. " start=/" .. first .. "/ end=/" .. last
        .. "/ keepend contains=@AppletSource" .. syntax_index)
    end

    local function rectangular_regions(item, syntax_index)
      for _, rectangle in ipairs(item.rectangles) do
        for row = rectangle.row,
            rectangle.row + rectangle.height - 1 do
          count = count + 1
          local first = ("\\%%%dl\\%%%dv"):format(
            row + 1, rectangle.col + 1)
          local last = ("\\%%%dl\\%%%dv"):format(
            row + 1, rectangle.col + rectangle.width + 1)
          pcall(vim.cmd, "syntax region AppletSourceContent" .. count
            .. " start=/" .. first .. "/ end=/" .. last
            .. "/ oneline keepend contains=@AppletSource" .. syntax_index)
        end
      end
    end

    for _, item in ipairs(valid) do
      local syntax_index = indexes[item.filetype]
      if syntax_index and item.range.last > item.range.first then
        if item.range.linewise ~= false or item.rectangles == nil then
          linewise_region(item, syntax_index)
        else
          rectangular_regions(item, syntax_index)
        end
      end
    end
    vim.b.applet_source_regions = count
    return count > 0
  end)
end

return M
