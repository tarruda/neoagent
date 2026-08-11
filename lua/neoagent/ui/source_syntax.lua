local M = {}

local function source_filetype(source, lines)
  if type(source) ~= "table" or type(source.path) ~= "string"
      or type(source.first) ~= "number" or type(source.last) ~= "number"
      or source.first < 0 or source.last < source.first
      or source.last >= #lines then return nil end
  local contents = vim.list_slice(
    lines, source.first + 1, source.last + 1)
  local ok, filetype = pcall(vim.filetype.match, {
    filename = source.path,
    contents = contents,
  })
  if not ok or type(filetype) ~= "string"
      or not filetype:match("^[%w_.-]+$") then return nil end
  return filetype
end

local function source_list(value)
  if type(value) ~= "table" then return {} end
  if value.path ~= nil then return { value } end
  return value
end

function M.apply(buffer, sources, lines)
  local valid, filetypes, requested = {}, {}, {}
  for _, source in ipairs(source_list(sources)) do
    local filetype = source_filetype(source, lines)
    if filetype then
      valid[#valid + 1] = { source = source, filetype = filetype }
      if not requested[filetype] then
        filetypes[#filetypes + 1] = filetype
        requested[filetype] = true
      end
    end
  end

  return vim.api.nvim_buf_call(buffer, function()
    for index = 1, tonumber(vim.b.neoagent_source_regions) or 0 do
      vim.cmd("silent! syntax clear NeoagentSourceContent" .. index)
    end

    local loaded, indexes = {}, {}
    for _, filetype in ipairs(vim.b.neoagent_source_filetypes or {}) do
      loaded[#loaded + 1] = filetype
      indexes[filetype] = #loaded
    end
    local current_syntax = vim.b.current_syntax
    for _, filetype in ipairs(filetypes) do
      if not indexes[filetype] then
        local index = #loaded + 1
        vim.b.current_syntax = nil
        local included = pcall(vim.cmd, "syntax include @NeoagentSource"
          .. index .. " syntax/" .. filetype .. ".vim")
        if included then
          loaded[index] = filetype
          indexes[filetype] = index
        end
      end
    end
    vim.b.current_syntax = current_syntax
    vim.b.neoagent_source_filetypes = loaded

    local regions = 0
    for _, item in ipairs(valid) do
      if indexes[item.filetype] then
        regions = regions + 1
        local first = "\\%" .. tostring(item.source.first + 1) .. "l"
        local following = item.source.last + 2
        local last = following <= #lines
          and "\\%" .. tostring(following) .. "l" or "\\%$"
        pcall(vim.cmd, "syntax region NeoagentSourceContent" .. regions
          .. " start=/" .. first .. "/ end=/" .. last
          .. "/ keepend contains=@NeoagentSource"
          .. indexes[item.filetype])
      end
    end
    vim.b.neoagent_source_regions = regions
    return regions > 0
  end)
end

return M
