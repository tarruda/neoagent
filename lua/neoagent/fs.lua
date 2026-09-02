local bit = require("bit")
local util = require("neoagent.util")

local M = {}

function M.content_fingerprint(data)
  assert(type(data) == "string", "fingerprint data must be a string")
  local seeds = {
    0x811c9dc5, 0x9e3779b9, 0x85ebca6b, 0xc2b2ae35,
    0x27d4eb2f, 0x165667b1, 0xd3a2646c, 0xfd7046c5,
  }
  local parts = {}
  for index, seed in ipairs(seeds) do
    local hash = bit.tobit(seed)
    for offset = 1, #data do
      hash = bit.bxor(hash, data:byte(offset) + index - 1)
      hash = bit.tobit(hash + bit.lshift(hash, 1)
        + bit.lshift(hash, 4) + bit.lshift(hash, 7)
        + bit.lshift(hash, 8) + bit.lshift(hash, 24))
      hash = bit.bxor(hash, bit.rshift(hash, 13))
    end
    parts[index] = bit.tohex(hash, 8)
  end
  return table.concat(parts)
end

function M.normalize(path)
  return vim.fs.normalize(path)
end

function M.is_absolute(path, os_name)
  if type(path) ~= "string" or path == "" then return false end
  os_name = os_name or jit.os
  if os_name == "Windows" then
    return path:match("^[A-Za-z]:[/\\]") ~= nil
      or path:sub(1, 2) == "\\\\"
  end
  return path:sub(1, 1) == "/"
end

function M.join(...)
  return vim.fs.joinpath(...)
end

function M.create_temp(prefix, directory)
  local template = M.join(
    directory or vim.uv.os_tmpdir(), (prefix or "neoagent-") .. "XXXXXX")
  local fd, path = vim.uv.fs_mkstemp(template)
  if not fd then return nil, path end
  local ok, err = vim.uv.fs_close(fd)
  if not ok then
    vim.uv.fs_unlink(path)
    return nil, err
  end
  return path
end

function M.create_temp_directory(prefix, directory)
  local template = M.join(
    directory or vim.uv.os_tmpdir(), (prefix or "neoagent-") .. "XXXXXX")
  return vim.uv.fs_mkdtemp(template)
end

function M.read_chunks(path, on_chunk, chunk_size)
  assert(type(on_chunk) == "function", "chunk callback is required")
  chunk_size = chunk_size or 64 * 1024
  assert(type(chunk_size) == "number" and chunk_size > 0 and chunk_size % 1 == 0,
    "chunk size must be a positive integer")
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
  local offset = 0
  local failure
  while true do
    local data, read_err = vim.uv.fs_read(fd, chunk_size, offset)
    if not data then
      failure = read_err
      break
    end
    if data == "" then break end
    local accepted, callback_err = pcall(on_chunk, data, offset)
    if not accepted then
      failure = callback_err
      break
    end
    offset = offset + #data
  end
  local closed, close_err = vim.uv.fs_close(fd)
  if failure then return nil, failure end
  if not closed then return nil, close_err end
  return true
end

function M.read(path)
  local chunks = {}
  local ok, err = M.read_chunks(path, function(data) chunks[#chunks + 1] = data end)
  if not ok then return nil, err end
  return table.concat(chunks)
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

function M.ensure_private_directory(path, requested_mode)
  assert(type(path) == "string" and path ~= "",
    "private directory path is required")
  assert(type(requested_mode) == "number" and requested_mode >= 0
      and requested_mode <= 511 and requested_mode % 1 == 0,
    "private directory mode must be between 0000 and 0777")
  local before, before_err, before_code = vim.uv.fs_lstat(path)
  local absent = before_code == "ENOENT"
    or type(before_err) == "string"
      and before_err:find("ENOENT", 1, true) ~= nil
  if not before and not absent then
    return nil, before_err
  end
  if before and before.type ~= "directory" then
    return nil, "private state path is not a directory"
  end
  local created = before == nil
  local ok, err = M.mkdirp(path)
  if not ok then return nil, err end
  local current, current_err = vim.uv.fs_lstat(path)
  if not current then return nil, current_err or "private directory is missing" end
  if current.type ~= "directory" then
    return nil, "private state path is not a directory"
  end
  if created then
    local secured, secure_err = vim.uv.fs_chmod(path, requested_mode)
    if not secured then
      vim.uv.fs_rmdir(path)
      return nil, secure_err
    end
    current, current_err = vim.uv.fs_lstat(path)
    if not current then return nil, current_err or "private directory is missing" end
    if type(current.mode) == "number"
        and bit.band(current.mode, 511) ~= requested_mode then
      vim.uv.fs_rmdir(path)
      return nil, "private directory has an unexpected permission mode"
    end
  end
  return true, created
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
    if type(count) ~= "number" or count <= 0
        or count > #data - written then
      vim.uv.fs_close(fd)
      return nil, write_err or "invalid write length"
    end
    written = written + count
  end
  local close_ok, close_err = vim.uv.fs_close(fd)
  if not close_ok then
    return nil, close_err
  end
  return true
end

local RegularFile = {}
RegularFile.__index = RegularFile

local function regular_identity(stat)
  if type(stat) ~= "table" or stat.type ~= "file"
      or type(stat.dev) ~= "number" or type(stat.ino) ~= "number" then
    return nil
  end
  return { device = stat.dev, inode = stat.ino }
end

local function same_regular_identity(identity, stat)
  local current = regular_identity(stat)
  return identity and current
    and identity.device == current.device and identity.inode == current.inode
end

function RegularFile:identity()
  return util.copy(self._identity)
end

function RegularFile:stat()
  if self._closed then return nil, "regular file handle is closed" end
  local stat, err = self._uv.fs_fstat(self._fd)
  if not stat then return nil, err end
  if not same_regular_identity(self._identity, stat) then
    return nil, "regular file handle identity changed", "ownership"
  end
  return stat
end

function RegularFile:verify_path()
  local held, held_err, held_code = self:stat()
  if not held then return nil, held_err, held_code end
  local current, current_err = self._uv.fs_lstat(self._path)
  if not current or not same_regular_identity(self._identity, current) then
    return nil, current_err or "regular file path identity changed", "ownership"
  end
  return held
end

function RegularFile:read_all()
  local stat, stat_err, stat_code = self:stat()
  if not stat then return nil, stat_err, stat_code end
  local chunks, offset = {}, 0
  while true do
    local chunk, read_err = self._uv.fs_read(self._fd, 64 * 1024, offset)
    if chunk == nil then return nil, read_err, "read" end
    if chunk == "" then break end
    chunks[#chunks + 1] = chunk
    offset = offset + #chunk
  end
  return table.concat(chunks)
end

function RegularFile:append(data, offset)
  assert(type(data) == "string", "regular file append data must be a string")
  assert(type(offset) == "number" and offset >= 0 and offset % 1 == 0,
    "regular file append offset must be a non-negative integer")
  if self._closed then return nil, "regular file handle is closed", "write" end
  local written = 0
  while written < #data do
    local count, write_err = self._uv.fs_write(
      self._fd, data:sub(written + 1), offset + written)
    if type(count) ~= "number" or count <= 0
        or count > #data - written then
      return nil, write_err or "invalid write length", "write"
    end
    written = written + count
  end
  return true
end

function RegularFile:truncate(size)
  assert(type(size) == "number" and size >= 0 and size % 1 == 0,
    "regular file truncate size must be a non-negative integer")
  if self._closed then return nil, "regular file handle is closed" end
  local truncated, truncate_err = self._uv.fs_ftruncate(self._fd, size)
  if not truncated then return nil, truncate_err, "truncate" end
  local stat, stat_err, stat_code = self:stat()
  if not stat then return nil, stat_err, stat_code end
  if stat.size ~= size then
    return nil, "truncated file has an unexpected size", "truncate"
  end
  return true
end

function RegularFile:close()
  if self._closed then return true end
  local closed, close_err = self._uv.fs_close(self._fd)
  if not closed then return nil, close_err, "close" end
  self._closed = true
  self._fd = nil
  return true
end

function M.open_regular(path, opts)
  assert(type(path) == "string" and path ~= "",
    "regular file path is required")
  opts = opts or {}
  assert(type(opts) == "table" and (next(opts) == nil or not util.is_list(opts)),
    "regular file options must be an object")
  for key in pairs(opts) do
    assert(key == "identity" or key == "mode",
      "unsupported regular file option " .. tostring(key))
  end
  assert(opts.mode == nil or type(opts.mode) == "number"
      and opts.mode >= 0 and opts.mode <= 511 and opts.mode % 1 == 0,
    "regular file mode must be between 0000 and 0777")
  local before, before_err = vim.uv.fs_lstat(path)
  local identity = regular_identity(before)
  if not identity then
    return nil, before_err or "regular file path is not a regular file",
      "ownership"
  end
  if opts.identity and (type(opts.identity) ~= "table"
      or opts.identity.device ~= identity.device
      or opts.identity.inode ~= identity.inode) then
    return nil, "regular file path identity changed", "ownership"
  end
  local fd, open_err = vim.uv.fs_open(path, "r+", opts.mode or 420)
  if not fd then return nil, open_err, "open" end
  local held, held_err = vim.uv.fs_fstat(fd)
  local current, current_err = vim.uv.fs_lstat(path)
  if not same_regular_identity(identity, held)
      or not same_regular_identity(identity, current) then
    vim.uv.fs_close(fd)
    return nil, held_err or current_err
      or "regular file path identity changed during open", "ownership"
  end
  return setmetatable({
    _path = path,
    _fd = fd,
    _identity = identity,
    _uv = vim.uv,
    _closed = false,
  }, RegularFile)
end

function M.truncate(path, size)
  assert(type(size) == "number" and size >= 0 and size % 1 == 0,
    "truncate size must be a non-negative integer")
  local fd, open_err = vim.uv.fs_open(path, "r+", 420)
  if not fd then return nil, open_err end
  local truncated, truncate_err = vim.uv.fs_ftruncate(fd, size)
  local stat, stat_err
  if truncated then stat, stat_err = vim.uv.fs_fstat(fd) end
  local closed, close_err = vim.uv.fs_close(fd)
  if not truncated then return nil, truncate_err end
  if not stat then return nil, stat_err end
  if stat.size ~= size then
    return nil, "truncated file has an unexpected size"
  end
  if not closed then return nil, close_err end
  return true
end

local function mode(value, name)
  assert(type(value) == "number" and value >= 0 and value <= 511
      and value % 1 == 0,
    name .. " must be a permission mode between 0000 and 0777")
  return value
end

local function missing(err, code)
  if code == "ENOENT" then return true end
  return type(err) == "string" and err:find("ENOENT", 1, true) ~= nil
end

local function atomic_policy(value)
  assert(type(value) == "table"
      and (next(value) == nil or not util.is_list(value)),
    "atomic replacement policy must be an object")
  for key in pairs(value) do
    assert(key == "mode" or key == "preserve_mode" or key == "new_mode"
        or key == "require_existing" or key == "expected_content_fingerprint",
      "atomic replacement policy has unsupported field " .. tostring(key))
  end
  assert(value.preserve_mode == nil or type(value.preserve_mode) == "boolean",
    "atomic replacement preserve_mode must be boolean")
  assert(value.require_existing == nil
      or type(value.require_existing) == "boolean",
    "atomic replacement require_existing must be boolean")
  assert(not (value.mode ~= nil and value.preserve_mode == true),
    "atomic replacement mode and preserve_mode are mutually exclusive")
  assert(not (value.mode ~= nil and value.new_mode ~= nil),
    "atomic replacement mode and new_mode are mutually exclusive")
  if value.mode ~= nil then value.mode = mode(value.mode, "atomic replacement mode") end
  if value.new_mode ~= nil then
    value.new_mode = mode(value.new_mode, "atomic replacement new_mode")
  end
  assert(value.mode ~= nil or value.preserve_mode == true,
    "atomic replacement requires mode or preserve_mode")
  assert(value.preserve_mode ~= true or value.new_mode ~= nil,
    "atomic replacement preserve_mode requires new_mode")
  assert(value.expected_content_fingerprint == nil
      or type(value.expected_content_fingerprint) == "string"
        and value.expected_content_fingerprint:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"
          .. "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"
          .. "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"
          .. "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$"),
    "atomic replacement expected_content_fingerprint must be a fingerprint")
  return value
end

local function observation(stat)
  return {
    exists = stat ~= nil,
    type = stat and stat.type or nil,
    device = stat and stat.dev or nil,
    inode = stat and stat.ino or nil,
    mode = stat and type(stat.mode) == "number"
        and bit.band(stat.mode, 511) or nil,
  }
end

local function same_observation(left, right)
  return left.exists == right.exists
    and left.type == right.type
    and left.device == right.device
    and left.inode == right.inode
    and left.mode == right.mode
end

local function fingerprint_file(path, expected)
  local fd, open_err = vim.uv.fs_open(path, "r", 438)
  if not fd then return nil, open_err end
  local stat, stat_err = vim.uv.fs_fstat(fd)
  if not stat then vim.uv.fs_close(fd) return nil, stat_err end
  if not same_observation(expected, observation(stat)) then
    vim.uv.fs_close(fd)
    return nil, "atomic replacement target changed during content verification"
  end
  local chunks, offset = {}, 0
  while true do
    local chunk, read_err = vim.uv.fs_read(fd, 64 * 1024, offset)
    if chunk == nil then vim.uv.fs_close(fd) return nil, read_err end
    if chunk == "" then break end
    chunks[#chunks + 1] = chunk
    offset = offset + #chunk
  end
  local confirmed, confirm_err = vim.uv.fs_fstat(fd)
  local closed, close_err = vim.uv.fs_close(fd)
  if not confirmed then return nil, confirm_err end
  if not same_observation(expected, observation(confirmed)) then
    return nil, "atomic replacement target changed during content verification"
  end
  if not closed then return nil, close_err end
  local current, current_err, current_code = vim.uv.fs_lstat(path)
  if not current and not missing(current_err, current_code) then
    return nil, current_err
  end
  if not same_observation(expected, observation(current)) then
    return nil, "atomic replacement target changed during content verification"
  end
  return M.content_fingerprint(table.concat(chunks))
end

function M._normalize_atomic_policy(policy)
  return atomic_policy(util.copy(policy or {}))
end

local function candidate_mode_matches(actual, expected)
  if type(actual) ~= "number" then return false end
  if jit.os == "Windows" then
    return bit.band(actual, 128) == bit.band(expected, 128)
  end
  return bit.band(actual, 511) == expected
end

local function write_atomic_candidate(path, data, selected_mode, exact_mode)
  local fd, open_err = vim.uv.fs_open(path, "wx", selected_mode)
  if not fd then return nil, open_err, "write" end
  local failure, stage
  local written = 0
  while written < #data do
    local count, write_err = vim.uv.fs_write(
      fd, data:sub(written + 1), written)
    if type(count) ~= "number" or count <= 0
        or count > #data - written then
      failure = write_err or "invalid write length"
      stage = "write"
      break
    end
    written = written + count
  end
  if not failure and exact_mode then
    local secured, secure_err = vim.uv.fs_fchmod(fd, selected_mode)
    if not secured then failure, stage = secure_err, "mode" end
  end
  local stat
  if not failure then
    local stat_err
    stat, stat_err = vim.uv.fs_fstat(fd)
    if not stat then
      failure, stage = stat_err, "inspect"
    elseif not regular_identity(stat) then
      failure, stage = "atomic replacement candidate is not a regular file",
        "inspect"
    elseif stat.size ~= #data then
      failure, stage = "atomic replacement candidate has an unexpected size",
        "inspect"
    elseif exact_mode and not candidate_mode_matches(
        stat.mode, selected_mode) then
      failure, stage = "atomic replacement candidate has an unexpected mode",
        "mode"
    end
  end
  local closed, close_err = vim.uv.fs_close(fd)
  if failure then return nil, failure, stage end
  if not closed then return nil, close_err, "write" end
  return regular_identity(stat)
end

local function remove_atomic_candidate(path, identity)
  if identity then
    local current = vim.uv.fs_lstat(path)
    if not same_regular_identity(identity, current) then return end
  end
  vim.uv.fs_unlink(path)
end

function M.atomic_replace(path, data, policy)
  assert(type(path) == "string" and path ~= "",
    "atomic replacement path is required")
  assert(type(data) == "string", "atomic replacement data must be a string")
  policy = M._normalize_atomic_policy(policy)

  local stat, stat_err, stat_code = vim.uv.fs_lstat(path)
  local target = observation(stat)
  local existed = stat ~= nil
  if not stat and not missing(stat_err, stat_code) then
    return nil, stat_err, "inspect"
  end
  if stat and stat.type == "link" then
    return nil, "atomic replacement target is a symbolic link", "target"
  end
  if stat and stat.type ~= "file" then
    return nil, "atomic replacement target is not a regular file", "target"
  end
  if not stat and policy.require_existing then
    return nil, "atomic replacement target must already exist", "target"
  end

  local selected_mode = policy.mode
    or stat and bit.band(stat.mode, 511) or policy.new_mode
  selected_mode = mode(selected_mode, "atomic replacement selected mode")
  local exact_mode = policy.mode ~= nil
    or policy.preserve_mode == true and existed
  local bytes, random_err = vim.uv.random(16)
  if not bytes then return nil, random_err, "temporary" end
  local suffix = bytes:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end)
  local temporary = path .. "." .. suffix .. ".tmp"
  local identity, write_err, write_stage = write_atomic_candidate(
    temporary, data, selected_mode, exact_mode)
  if not identity then
    remove_atomic_candidate(temporary)
    return nil, write_err, write_stage
  end
  local candidate, candidate_err = vim.uv.fs_lstat(temporary)
  if not same_regular_identity(identity, candidate) then
    remove_atomic_candidate(temporary, identity)
    return nil, candidate_err
      or "atomic replacement candidate identity changed", "target_changed"
  end

  local current, current_err, current_code = vim.uv.fs_lstat(path)
  if not current and not missing(current_err, current_code) then
    remove_atomic_candidate(temporary, identity)
    return nil, current_err, "inspect"
  end
  if current and current.type == "link" then
    remove_atomic_candidate(temporary, identity)
    return nil, "atomic replacement target became a symbolic link", "target"
  end
  if current and current.type ~= "file" then
    remove_atomic_candidate(temporary, identity)
    return nil, "atomic replacement target is not a regular file", "target"
  end
  if not current and policy.require_existing then
    remove_atomic_candidate(temporary, identity)
    return nil, "atomic replacement target must already exist", "target"
  end
  if not same_observation(target, observation(current)) then
    remove_atomic_candidate(temporary, identity)
    return nil, "atomic replacement target changed during preparation",
      "target_changed"
  end
  if policy.expected_content_fingerprint ~= nil then
    if not target.exists then
      remove_atomic_candidate(temporary, identity)
      return nil, "atomic replacement expected target content is missing",
        "target_changed"
    end
    local fingerprint, fingerprint_err = fingerprint_file(path, target)
    if not fingerprint then
      remove_atomic_candidate(temporary, identity)
      return nil, fingerprint_err, "target_changed"
    end
    if fingerprint:lower() ~= policy.expected_content_fingerprint:lower() then
      remove_atomic_candidate(temporary, identity)
      return nil, "atomic replacement target content changed concurrently",
        "target_changed"
    end
  end
  local replaced, replace_err = vim.uv.fs_rename(temporary, path)
  if not replaced then
    remove_atomic_candidate(temporary, identity)
    return nil, replace_err, "rename"
  end
  return true, identity
end

function M.canonical(path)
  return vim.uv.fs_realpath(path) or M.normalize(path)
end

function M.ancestors(path)
  local current = M.canonical(path)
  local marker = vim.fs.find(".git", { path = current, upward = true })[1]
  local stop = marker and M.canonical(vim.fs.dirname(marker)) or nil
  local result = {}
  while true do
    table.insert(result, 1, current)
    if current == stop then break end
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    current = parent
  end
  return result
end

return M
