local util = require("applet.util")

local M = {}

local sequence = 0

local function canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function safe_document_name(value)
  if type(value) ~= "string" or value == "" or #value > 256
      or value:find("[/\\]") or value:find("[%z\1-\31\127]") then
    return false
  end
  return pcall(util.validate_text, value, "host document name")
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
  assert(safe_document_name(document.name),
    "host document name must be safe text without path separators")
  assert(type(document.filetype) == "string",
    "host document filetype must be a string")
  assert(type(document.content) == "string",
    "host document content must be a string")
  local original_tab = vim.api.nvim_get_current_tabpage()
  local candidate_tab
  local candidate_buffer
  local ok, err = pcall(function()
    vim.cmd("tabnew")
    candidate_tab = vim.api.nvim_get_current_tabpage()
    candidate_buffer = vim.api.nvim_get_current_buf()
    sequence = sequence + 1
    vim.api.nvim_buf_set_name(candidate_buffer,
      "neoagent://provider/" .. tostring(sequence) .. "/" .. document.name)
    vim.bo[candidate_buffer].buftype = "nofile"
    vim.bo[candidate_buffer].buflisted = false
    vim.bo[candidate_buffer].bufhidden = "wipe"
    vim.bo[candidate_buffer].swapfile = false
    vim.bo[candidate_buffer].modifiable = true
    vim.bo[candidate_buffer].filetype = document.filetype
    vim.api.nvim_buf_set_lines(candidate_buffer, 0, -1, false,
      vim.split(document.content, "\n", { plain = true, trimempty = false }))
    vim.bo[candidate_buffer].modified = false
    vim.bo[candidate_buffer].modifiable = true
  end)
  if not ok then
    if candidate_tab and vim.api.nvim_tabpage_is_valid(candidate_tab) then
      pcall(function()
        vim.api.nvim_set_current_tabpage(candidate_tab)
        vim.cmd("tabclose!")
      end)
    end
    if vim.api.nvim_tabpage_is_valid(original_tab) then
      pcall(vim.api.nvim_set_current_tabpage, original_tab)
    end
    if candidate_buffer and vim.api.nvim_buf_is_valid(candidate_buffer) then
      pcall(vim.api.nvim_buf_delete, candidate_buffer, { force = true })
    end
    return nil, err
  end
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
