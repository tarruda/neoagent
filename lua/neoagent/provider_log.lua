local fs = require("neoagent.fs")

local M = {}

local MAX_BYTES = 1024 * 1024
local fields = {
  "type", "timestamp", "api", "provider", "model", "request_attempt",
  "request_max_attempts", "stream_attempt", "kind", "message", "code",
  "status", "retryable", "retry_after_ms", "request_id", "cf_ray",
  "authorization_error", "exit_code",
}

local function scalar(value)
  local kind = type(value)
  return kind == "string" or kind == "number" or kind == "boolean"
end

local function sanitized(event)
  local result = {}
  for _, name in ipairs(fields) do
    local value = event[name]
    if scalar(value) then
      if type(value) == "string" and #value > 2000 then
        value = value:sub(1, 1997) .. "..."
      end
      result[name] = value
    end
  end
  return result
end

local function prepare(path)
  local directory = vim.fs.dirname(path)
  local existed = vim.uv.fs_stat(directory) ~= nil
  local ok, result = pcall(vim.fn.mkdir, directory, "p", 448)
  if not ok or result == 0 and not vim.uv.fs_stat(directory) then
    return nil, ok and "failed to create diagnostic log directory" or result
  end
  if not existed then pcall(vim.uv.fs_chmod, directory, 448) end
  local stat = vim.uv.fs_stat(path)
  if stat then pcall(vim.uv.fs_chmod, path, 384) end
  if stat and stat.size >= MAX_BYTES then
    pcall(vim.uv.fs_unlink, path .. ".1")
    local renamed, rename_err = vim.uv.fs_rename(path, path .. ".1")
    if not renamed then return nil, rename_err end
    pcall(vim.uv.fs_chmod, path .. ".1", 384)
  end
  return true
end

function M.append(path, event)
  assert(type(path) == "string" and path ~= "", "diagnostic log path is required")
  assert(type(event) == "table", "diagnostic event is required")
  local ready, prepare_err = prepare(path)
  if not ready then return nil, prepare_err end
  local encoded, encode_err
  local ok, result = pcall(vim.json.encode, sanitized(event))
  if ok then encoded = result else encode_err = result end
  if not encoded then return nil, encode_err end
  local written, write_err = fs.write_all(path, encoded .. "\n", "a", 384)
  if not written then return nil, write_err end
  pcall(vim.uv.fs_chmod, path, 384)
  return true
end

function M.callback(path)
  local warned = false
  return function(event)
    local ok, err = M.append(path, event)
    if not ok and not warned then
      warned = true
      vim.schedule(function()
        vim.notify("neoagent diagnostic log failed: " .. tostring(err), vim.log.levels.WARN)
      end)
    end
  end
end

function M.codex_path()
  return vim.fn.stdpath("state") .. "/neoagent/codex.log"
end

return M
