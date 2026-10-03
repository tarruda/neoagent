local ffi = require("ffi")
local bit = require("bit")
local validate = require("neoagent.subprocess.validate")
local strings = require("neoagent.subprocess.windows_text")
local M = {}

ffi.cdef([[
unsigned long __stdcall GetFileAttributesW(const unsigned short *);
]])

---@class Neoagent.WindowsExecutableKernel
---@field GetFileAttributesW fun(path: ffi.cdata*): integer
local kernel = ffi.load("kernel32") --[[@as Neoagent.WindowsExecutableKernel]]

---@param path string
---@return boolean
local function candidate_exists(path)
  local wide = strings.wide(path)
  if not wide then
    error(validate.error("process_start", "Process executable path conversion failed"), 0)
  end
  -- Match libuv's candidate selection before execution. Following a dangling
  -- file link here would skip it and could launch a different PATH candidate.
  local attributes = kernel.GetFileAttributesW(wide)
  return attributes ~= 0xffffffff and bit.band(attributes, 0x10) == 0
end

---@param directory string
---@param path string
---@return string
local function join(directory, path)
  if directory == "" or directory:find("[/\\:]$") then
    return directory .. path
  end
  return directory .. "\\" .. path
end

---@param path string
---@param cwd string
---@return string
local function absolute(path, cwd)
  if path:match("^[/\\][/\\]") or path:match("^%a:[/\\]") then
    return path
  elseif path:match("^[/\\]") then
    return cwd:sub(1, 2) .. path
  elseif path:match("^%a:") then
    if path:sub(1, 2):lower() ~= cwd:sub(1, 2):lower() then
      return path
    end
    path = path:sub(3)
  end
  return join(cwd, path)
end

---@param path string
---@return string[]
local function windows_path(path)
  local entries = {}
  local offset = 1
  while offset <= #path do
    local quote = path:sub(offset, offset)
    local quoted_end = (quote == '"' or quote == "'") and (path:find(quote, offset + 1, true) or #path + 1)
    local ending = path:find(";", quoted_end or offset, true) or #path + 1
    local entry = path:sub(offset, ending - 1)
    if entry ~= "" then
      entry = entry:gsub("^[\"']", ""):gsub("[\"']$", "")
      entries[#entries + 1] = entry
    end
    offset = ending + 1
  end
  return entries
end

-- CreateProcessW receives an explicit application name. Match libuv's cwd,
-- quoted PATH, and .com/.exe lookup so pipe and PTY modes select the same
-- executable, independently of ambient PATHEXT and command-line parsing.
---@param spec Neoagent.SubprocessSpec
---@param env table<string, string>
---@return string application
function M.resolve(spec, env)
  -- Windows normalizes relative components before traversing junctions.
  -- Preserve the caller's spelling, as libuv does, instead of resolving it.
  local cwd = spec.cwd
  local program = assert(spec.argv[1])
  if program == "." then
    -- libuv rejects this name before its .com/.exe search.
    error(validate.error("process_start", "Process executable lookup failed (ENOENT)"), 0)
  end
  local directories = {}
  if program:find("/", 1, true) or program:find("\\", 1, true) or program:find(":", 1, true) then
    directories[1] = ""
  else
    if vim.uv.os_getenv("NoDefaultCurrentDirectoryInExePath") == nil then
      directories[#directories + 1] = ""
    end
    vim.list_extend(directories, windows_path(env.PATH or ""))
  end
  local filename = program:gsub("\\", "/"):match("([^/]+)$") or program
  local extensions = filename:find("%..") and { "", ".com", ".exe" } or { ".com", ".exe" }
  for _, directory in ipairs(directories) do
    local path = absolute(join(directory, program), cwd)
    for _, extension in ipairs(extensions) do
      local suffix = extension
      if path:sub(-1) == "." then
        suffix = suffix:gsub("^%.", "")
      end
      local candidate = path .. suffix
      if candidate_exists(candidate) then
        return candidate
      end
    end
  end
  error(validate.error("process_start", "Process executable lookup failed (ENOENT)"), 0)
end

return M
