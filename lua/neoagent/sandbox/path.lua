local M = {}

local function invalid(message)
  error("Invalid sandbox path: " .. message, 0)
end

local function value(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
    invalid("expected a non-empty string without NUL bytes")
  end
  return path
end

local function canonical_candidate(paths, path, realpath)
  local resolved = realpath(path)
  if resolved then return paths.normalize(resolved) end
  local current, suffix = path, {}
  while true do
    local parent = paths.dirname(current)
    if parent == current then break end
    table.insert(suffix, 1, paths.basename(current))
    current = parent
    resolved = realpath(current)
    if resolved then
      local result = paths.normalize(resolved)
      for _, part in ipairs(suffix) do
        result = paths.join(result, part)
      end
      return paths.normalize(result)
    end
  end
  return paths.normalize(path)
end

local posix = { name = "posix" }

function posix.normalize(path)
  return vim.fs.normalize(value(path))
end

function posix.is_absolute(path)
  return type(path) == "string" and path:sub(1, 1) == "/"
end

function posix.root(path)
  return posix.is_absolute(path) and "/" or nil
end

function posix.key(path)
  return posix.normalize(path)
end

function posix.contains(root, path)
  root, path = posix.key(root), posix.key(path)
  return root == "/" or path == root
    or path:sub(1, #root + 1) == root .. "/"
end

function posix.depth(path)
  local normalized = posix.normalize(path)
  local count = 0
  for _ in normalized:gmatch("[^/]+") do count = count + 1 end
  return count
end

function posix.dirname(path)
  return vim.fs.dirname(posix.normalize(path))
end

function posix.basename(path)
  return vim.fs.basename(posix.normalize(path))
end

function posix.join(...)
  return posix.normalize(vim.fs.joinpath(...))
end

function posix.canonical_candidate(path)
  return canonical_candidate(
    posix, posix.normalize(path), vim.uv.fs_realpath)
end

function posix.realpath(path)
  local resolved = vim.uv.fs_realpath(posix.normalize(path))
  return resolved and posix.normalize(resolved) or nil
end

function posix.stat(path)
  return vim.uv.fs_stat(path)
end

function posix.environment_key(name)
  return name
end

function posix.validate_component(part)
  value(part)
  if part:find("/", 1, true) then
    invalid("POSIX components cannot contain separators")
  end
  return part
end

M.posix = posix

local reserved = {
  con = true,
  prn = true,
  aux = true,
  nul = true,
  com1 = true,
  com2 = true,
  com3 = true,
  com4 = true,
  com5 = true,
  com6 = true,
  com7 = true,
  com8 = true,
  com9 = true,
  ["com¹"] = true,
  ["com²"] = true,
  ["com³"] = true,
  lpt1 = true,
  lpt2 = true,
  lpt3 = true,
  lpt4 = true,
  lpt5 = true,
  lpt6 = true,
  lpt7 = true,
  lpt8 = true,
  lpt9 = true,
  ["lpt¹"] = true,
  ["lpt²"] = true,
  ["lpt³"] = true,
}

local function windows_component(part)
  if part:find('[<>:"|?*%z\1-\31]') then
    invalid("Windows components contain unsupported characters")
  end
  if part:match("[%. ]$") then
    invalid("Windows components cannot end in a dot or space")
  end
  local stem = (part:match("^([^%.]+)") or part):lower()
  if reserved[stem] then
    invalid("Windows device names are unsupported")
  end
end

local function windows_parts(path)
  path = value(path):gsub("/", "\\")
  if path:sub(1, 8):lower() == "\\\\?\\unc\\" then
    path = "\\\\" .. path:sub(9)
  elseif path:sub(1, 4) == "\\\\?\\" then
    path = path:sub(5)
  elseif path:sub(1, 4) == "\\\\.\\" or path:sub(1, 4) == "\\??\\" then
    invalid("Windows device paths are unsupported")
  end

  local root, suffix
  local drive, tail = path:match("^([A-Za-z]):\\(.*)$")
  if drive then
    root = drive:upper() .. ":\\"
    suffix = tail
  elseif path:sub(1, 2) == "\\\\" then
    local server, share, rest =
      path:match("^\\\\([^\\]+)\\([^\\]+)\\?(.*)$")
    if not server or not share then
      invalid("UNC paths require a server and share")
    end
    windows_component(server)
    windows_component(share)
    root = "\\\\" .. server .. "\\" .. share .. "\\"
    suffix = rest
  else
    invalid("Windows paths must use a drive root or UNC share")
  end

  local parts = {}
  for part in suffix:gmatch("[^\\]+") do
    if part == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif part ~= "." then
      windows_component(part)
      parts[#parts + 1] = part
    end
  end
  return root, parts
end

function M.windows(opts)
  opts = opts or {}
  local realpath = opts.realpath or vim.uv.fs_realpath
  local stat = opts.stat or vim.uv.fs_stat
  local paths = { name = "windows" }

  function paths.normalize(path)
    local root, parts = windows_parts(path)
    if #parts == 0 then return root end
    return root .. table.concat(parts, "\\")
  end

  function paths.is_absolute(path)
    if type(path) ~= "string" or path == "" then return false end
    return pcall(paths.normalize, path)
  end

  function paths.root(path)
    local root = windows_parts(path)
    return root
  end

  function paths.key(path)
    return vim.fn.tolower(paths.normalize(path))
  end

  function paths.contains(root, path)
    root, path = paths.key(root), paths.key(path)
    if root:sub(-1) == "\\" then
      return path == root or path:sub(1, #root) == root
    end
    return path == root
      or path:sub(1, #root + 1) == root .. "\\"
  end

  function paths.depth(path)
    local _, parts = windows_parts(path)
    return #parts
  end

  function paths.dirname(path)
    local root, parts = windows_parts(path)
    if #parts == 0 then return root end
    table.remove(parts)
    if #parts == 0 then return root end
    return root .. table.concat(parts, "\\")
  end

  function paths.basename(path)
    local root, parts = windows_parts(path)
    return parts[#parts] or root
  end

  function paths.join(first, ...)
    local result = value(first)
    for _, part in ipairs({ ... }) do
      part = value(part)
      if paths.is_absolute(part) then
        result = part
      else
        result = result:gsub("[\\/]+$", "") .. "\\" .. part
      end
    end
    return paths.normalize(result)
  end

  function paths.canonical_candidate(path)
    return canonical_candidate(paths, paths.normalize(path), realpath)
  end

  function paths.realpath(path)
    local resolved = realpath(paths.normalize(path))
    return resolved and paths.normalize(resolved) or nil
  end

  function paths.stat(path)
    return stat(path)
  end

  function paths.environment_key(name)
    return vim.fn.toupper(name)
  end

  function paths.validate_component(part)
    windows_component(value(part))
    return part
  end

  return paths
end

function M.for_os(os)
  if os == "Windows" then return M.windows() end
  return M.posix
end

return M
