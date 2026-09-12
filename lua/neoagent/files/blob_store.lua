local async = require("neoagent.async")
local digest = require("neoagent.files.digest")
local files = require("neoagent.files")
local fs = require("neoagent.fs")
local file_lock = require("neoagent.file_lock")
local M = {}

---@param opts {directory: string, prepare: fun(): true?, Neoagent.Error?}
---@return Neoagent.Files
function M.new(opts)
  local directory = fs.normalize(opts.directory)
  ---@type Neoagent.Error?
  local blocked
  ---@param id string
  ---@return string
  local function path(id)
    assert(files.valid_id(id), "attachment file ID must be a SHA-256 digest")
    return fs.join(directory, id, "content")
  end
  ---@param id string
  ---@return Neoagent.LocalFile?, Neoagent.Error?
  local function inspect(id)
    local target = path(id)
    local root = vim.uv.fs_lstat(directory)
    local parent = vim.uv.fs_lstat(assert(vim.fs.dirname(target)))
    if not root or root.type ~= "directory" or not parent or parent.type ~= "directory" then
      return nil, files.error("Attachment directory is missing or invalid: " .. id)
    end
    local file, err = fs.open_regular(target)
    if not file then
      return nil, files.error("Attachment is missing or invalid: " .. id, err)
    end
    local stat, stat_err = file:verify_path()
    local closed, close_err = file:close()
    if not closed then
      return nil, files.error("Could not close attachment metadata", close_err)
    end
    if not stat then
      return nil, files.error("Could not inspect attachment", stat_err)
    end
    return { file_id = id, bytes = stat.size }
  end
  ---@param id string
  ---@param maximum integer
  ---@return Neoagent.FileReader?, Neoagent.Error?
  local function open(id, maximum)
    files.check_limit(maximum)
    local metadata, inspect_err = inspect(id)
    if not metadata then
      return nil, inspect_err
    end
    if metadata.bytes > maximum then
      return nil, files.error("Attachment exceeds the byte limit")
    end
    local file, open_err = fs.open_regular(path(id))
    if not file then
      return nil, files.error("Could not open attachment", open_err)
    end
    return files.reader(metadata, maximum, function(limit)
      local chunks, size = {}, 0
      while true do
        local chunk, err = file:read_chunk(math.min(65536, limit - size + 1), size)
        if not chunk then
          return nil, files.error("Could not read attachment", err)
        end
        if chunk == "" then
          break
        end
        size = size + #chunk
        if size > limit then
          return nil, files.error("Attachment exceeds the byte limit")
        end
        chunks[#chunks + 1] = chunk
        if async.current() then
          async.yield()
        end
      end
      local verified, verify_err = file:verify_path()
      if not verified then
        return nil, files.error("Attachment changed during read", verify_err)
      end
      return table.concat(chunks)
    end, function()
      local closed, err = file:close()
      if not closed then
        return nil, files.error("Could not close attachment", err)
      end
      return true
    end)
  end
  ---@type Neoagent.Files
  local store
  store = {
    identity = "workspace:" .. fs.canonical(directory),
    inspect = inspect,
    open = open,
    put = function(data)
      assert(type(data) == "string", "attachment bytes must be a string")
      if blocked then
        return nil, blocked
      end
      local ready, prepare_err = opts.prepare()
      if not ready then
        return nil, prepare_err
      end
      local id = digest.sha256(data)
      if blocked then
        return nil, blocked
      end
      local target = path(id)
      local parent = assert(vim.fs.dirname(target))
      for _, dir in ipairs({ directory, parent }) do
        local created, create_err = fs.ensure_private_directory(dir, 448)
        if not created then
          return nil, files.error("Could not create attachment directory", create_err)
        end
        local synced, sync_err = fs.sync_directory(assert(vim.fs.dirname(dir)))
        if not synced then
          blocked = files.error("Could not publish attachment directory", sync_err)
          return nil, blocked
        end
      end
      local lock = file_lock.new({ path = fs.join(parent, "publish.lock") })
      ---@async
      ---@return Neoagent.LocalFile?, Neoagent.Error?
      local function publish()
        if blocked then
          return nil, blocked
        end
        if vim.uv.fs_lstat(target) then
          local existing, err = files.read(store, id, #data)
          if not existing then
            return nil, err
          end
          return { file_id = id, bytes = #existing }
        end
        local written, err = fs.atomic_replace(target, data, { mode = 384, durable = true })
        if not written then
          blocked = files.error("Could not publish attachment; further writes are blocked", err)
          return nil, blocked
        end
        return { file_id = id, bytes = #data }
      end
      local lease = lock:acquire_async()
      local result, err = lease:run(publish)
      if not result and err and err.kind == "file_lock" then
        blocked = files.error("Attachment publication lock failed; further writes are blocked", err)
        return nil, blocked
      end
      return result, err
    end,
  }
  return store
end

return M
