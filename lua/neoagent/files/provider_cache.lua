local fs = require("neoagent.fs")
local file_lock = require("neoagent.file_lock")
local object = require("neoagent.files.object")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.FileCache
---@field scope string
---@field read fun(self: Neoagent.FileCache, key: string): Neoagent.FileRecord?
---@field publish fun(self: Neoagent.FileCache, record: Neoagent.FileRecord, previous?: string): boolean

-- Capability copies share this store's private failure state, just as local
-- file readers and writers retain their owned resources through closures.
---@param opts {directory: string, scope: string, report?: fun(message: string, level: integer)}
---@return Neoagent.FileCache
function M.new(opts)
  assert(type(opts.directory) == "string" and opts.directory ~= "", "file cache directory is required")
  assert(type(opts.scope) == "string" and opts.scope ~= "", "file cache scope is required")
  local directory = fs.normalize(opts.directory)
  local report = opts.report or function(message, level)
    vim.notify(message, level)
  end
  local blocked = false

  ---@param key string
  ---@return string
  local function path(key)
    assert(object.cache_key(key), "file cache key requires namespace and content SHA-256 digests")
    return fs.join(directory, key .. ".json")
  end

  ---@param key string
  ---@return Neoagent.FileRecord?
  local function read(key)
    local handle = fs.open_regular(path(key))
    if not handle then
      return nil
    end
    local stat = handle:stat()
    local chunks, size = {}, 0
    local ok = stat
      and stat.size <= 16384
      and handle:read_chunks(function(chunk)
        size = size + #chunk
        assert(size <= 16384, "file cache record exceeds limit")
        chunks[#chunks + 1] = chunk
      end)
    local closed = handle:close()
    if not ok or not closed then
      return nil
    end
    local decoded, value = pcall(vim.json.decode, table.concat(chunks))
    if decoded and object.record(value, key) then
      return value
    end
    return nil
  end

  return {
    scope = opts.scope,
    read = function(_, key)
      return read(key)
    end,
    -- All failures disable writes, including uncertain publication or lock
    -- release. Current uploads remain usable independently of this cache.
    ---@async
    publish = function(_, record, previous)
      assert(object.record(record, record.key), "invalid file cache record")
      if blocked then
        return false
      end
      local ok, saved = pcall(function()
        assert(fs.ensure_private_directory(directory, 448))
        assert(fs.ensure_private_directory(assert(vim.fs.dirname(path(record.key))), 448))
        local lease = file_lock.new({ path = path(record.key) .. ".lock" }):acquire_async()
        local result, err = lease:run(function()
          if blocked then
            return false
          end
          local current = read(record.key)
          if (current and current.generation or nil) ~= previous then
            return false
          end
          local written, write_err =
            fs.atomic_replace(path(record.key), util.json_encode(record) .. "\n", { mode = 384 })
          if not written then
            error(write_err, 0)
          end
          return true
        end)
        if err then
          error(err, 0)
        end
        return result
      end)
      if not ok then
        blocked = true
        pcall(report, "File upload reuse could not be saved; cache writes are disabled", vim.log.levels.WARN)
        return false
      end
      return saved == true
    end,
  }
end

return M
