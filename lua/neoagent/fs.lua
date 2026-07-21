local M = {}

function M.normalize(path)
  return vim.fs.normalize(path)
end

function M.join(...)
  return vim.fs.joinpath(...)
end

function M.read(path)
  local stat, stat_err = vim.uv.fs_stat(path)
  if not stat then
    return nil, stat_err or "file does not exist"
  end
  if stat.type ~= "file" then
    return nil, "not a file"
  end
  local fd, open_err = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil, open_err
  end
  local data, read_err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not data then
    return nil, read_err
  end
  return data
end

function M.mkdirp(path)
  if path == nil or path == "" or path == "." then
    return true
  end
  local ok, result = pcall(vim.fn.mkdir, path, "p")
  if not ok or result == 0 and not vim.uv.fs_stat(path) then
    return nil, ok and "failed to create directory" or result
  end
  return true
end

function M.write_all(path, data, flags, mode)
  local fd, open_err = vim.uv.fs_open(path, flags or "w", mode or 420)
  if not fd then
    return nil, open_err
  end
  local offset = flags == "a" and -1 or 0
  local written = 0
  while written < #data do
    local count, write_err = vim.uv.fs_write(fd, data:sub(written + 1), offset < 0 and -1 or offset + written)
    if not count then
      vim.uv.fs_close(fd)
      return nil, write_err
    end
    written = written + count
  end
  local close_ok, close_err = vim.uv.fs_close(fd)
  if not close_ok then
    return nil, close_err
  end
  return true
end

function M.canonical(path)
  return vim.uv.fs_realpath(path) or M.normalize(path)
end

return M
