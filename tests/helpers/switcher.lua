local M = {}

local function buffer_name(key)
  return "/agent%-switcher%-" .. key .. "$"
end

function M.buffer(key)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer)
        and vim.api.nvim_buf_get_name(buffer):match(buffer_name(key)) then
      return buffer
    end
  end
end

function M.window(key)
  local buffer = M.buffer(key)
  if not buffer then return nil end
  for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
    if vim.api.nvim_win_is_valid(window) then return window end
  end
end

function M.is_open()
  return M.window("filter") ~= nil and M.window("results") ~= nil
end

function M.lines()
  local buffer = M.buffer("results")
  return buffer and vim.api.nvim_buf_get_lines(buffer, 0, -1, false) or {}
end

function M.set_filter(value)
  local buffer = assert(M.buffer("filter"))
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { value })
  local window = assert(M.window("filter"))
  vim.api.nvim_win_set_cursor(window, { 1, #value })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buffer })
  assert(vim.wait(1000, function()
    local text = table.concat(M.lines(), "\n")
    for token in value:gmatch("%S+") do
      if not text:find(token, 1, true) then return false end
    end
    return true
  end, 5))
  return value
end

function M.press(keys)
  local window = assert(M.window("filter"))
  vim.api.nvim_set_current_win(window)
  vim.cmd("startinsert")
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

return M
