local validate = require("neoagent.subprocess.validate")
local M = {}

-- libuv inserts ambient values for absent keys on Windows pipe launches.
-- Native PTY creation passes the environment directly to CreateProcessW.
local windows_required = {
  "HOMEDRIVE",
  "HOMEPATH",
  "LOGONSERVER",
  "PATH",
  "SYSTEMDRIVE",
  "SYSTEMROOT",
  "TEMP",
  "USERDOMAIN",
  "USERNAME",
  "USERPROFILE",
  "WINDIR",
}

---@param spec? Neoagent.SubprocessEnvironment
---@return table<string, string>
function M.normalize(spec)
  local result = {}
  local windows = jit.os == "Windows"
  local native_key = windows and require("neoagent.subprocess.windows_environment").key
  if not spec or spec.inherit then
    for name, value in pairs(assert(vim.uv.os_environ())) do
      result[native_key and native_key(name) or name] = value
    end
  end
  local seen = {}
  for name, value in pairs(spec and spec.set or {}) do
    local key = native_key and native_key(name) or name
    if seen[key] then
      error(validate.error("process_validation", "Duplicate process environment name"), 0)
    end
    seen[key] = true
    result[key] = value
  end
  return result
end

---@param values table<string, string>
---@return string[]
function M.for_pipes(values)
  if jit.os == "Windows" then
    for _, name in ipairs(windows_required) do
      if values[name] == nil and vim.uv.os_getenv(name) ~= nil then
        error(validate.error("process_validation", "Windows requires " .. name .. " in an exact environment"), 0)
      end
    end
  end
  return M.list(values)
end

---@param environment table<string, string>
---@return string[]
function M.list(environment)
  local result = {}
  for name, value in pairs(environment) do
    result[#result + 1] = name .. "=" .. value
  end
  table.sort(result)
  return result
end

return M
