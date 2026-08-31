local M = {}

local sequence = 0

local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

function M.refresh_file(path)
  assert(type(path) == "string" and path ~= "",
    "host file path must be a non-empty string")
  local target = canonical(path)
  local result = { refreshed = 0, modified = {}, failures = {} }
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" and canonical(name) == target then
        if vim.bo[buffer].modified then
          result.modified[#result.modified + 1] = name
        else
          local ok, err = pcall(vim.api.nvim_buf_call, buffer, function()
            vim.cmd("silent keepalt edit!")
          end)
          if ok then
            result.refreshed = result.refreshed + 1
          else
            result.failures[#result.failures + 1] = tostring(err)
          end
        end
      end
    end
  end
  return result
end

function M.open_document(document)
  assert(type(document) == "table", "host document must be a table")
  assert(type(document.name) == "string" and document.name ~= "",
    "host document name must be a non-empty string")
  assert(type(document.filetype) == "string",
    "host document filetype must be a string")
  assert(type(document.content) == "string",
    "host document content must be a string")
  local ok, err = pcall(function()
    vim.cmd("tabnew")
    vim.bo.filetype = document.filetype
    vim.bo.bufhidden = "wipe"
    vim.bo.swapfile = false
    pcall(vim.api.nvim_buf_set_name, 0, document.name)
    vim.api.nvim_buf_set_lines(0, 0, -1, false,
      vim.split(document.content, "\n", { plain = true, trimempty = true }))
    vim.bo.modified = false
  end)
  if not ok then return nil, err end
  return true
end

function M.on_exit(callback)
  assert(type(callback) == "function", "host exit callback must be a function")
  sequence = sequence + 1
  local group = vim.api.nvim_create_augroup(
    "AppletHostEffects" .. sequence, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = callback,
  })
  local active = true
  return function()
    if not active then return end
    active = false
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
end

return M
