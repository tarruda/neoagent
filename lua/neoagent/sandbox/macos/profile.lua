local M = {}

local base = [[
(version 1)
(deny default)

(allow process-exec)
(allow process-fork)
(allow signal (target same-sandbox))
(allow process-info* (target same-sandbox))
(allow sysctl-read)
(allow sysctl-write
  (sysctl-name "kern.grade_cputype"))

(allow file-read*
  (literal "/dev/null")
  (literal "/dev/urandom")
  (literal "/dev/random"))
(allow file-write-data
  (require-all
    (literal "/dev/null")
    (vnode-type CHARACTER-DEVICE)))

(allow mach-lookup
  (global-name "com.apple.PowerManagement.control")
  (global-name "com.apple.system.opendirectoryd.libinfo"))
(allow iokit-open
  (iokit-registry-entry-class "RootDomainUserClient"))
(allow ipc-posix-sem)
(allow ipc-posix-shm-read-data
  ipc-posix-shm-write-create
  ipc-posix-shm-write-unlink
  (ipc-posix-name-regex #"^/__KMP_REGISTERED_LIB_[0-9]+$"))

(allow pseudo-tty)
(allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
(allow file-read* file-write*
  (require-all
    (regex #"^/dev/ttys[0-9]+")
    (extension "com.apple.sandbox.pty")))
(allow file-ioctl (regex #"^/dev/ttys[0-9]+"))

(allow ipc-posix-shm-read* (ipc-posix-name-prefix "apple.cfprefs."))
(allow mach-lookup
  (global-name "com.apple.cfprefsd.daemon")
  (global-name "com.apple.cfprefsd.agent")
  (local-name "com.apple.cfprefsd.agent"))
(allow user-preference-read)
]]

local function contains(root, path)
  return root == "/" or path == root
    or path:sub(1, #root + 1) == root .. "/"
end

local function effective_entries(profile)
  local result = {
    { path = "/", access = profile.filesystem.default },
  }
  for _, entry in ipairs(profile.filesystem.entries) do
    result[#result + 1] = entry
  end
  table.sort(result, function(left, right)
    if #left.path ~= #right.path then return #left.path < #right.path end
    return left.path < right.path
  end)
  return result
end

function M.compile(profile, internal)
  local parameters, sections = {}, { base }
  local function parameter(path)
    local name = string.format("PATH_%03d", #parameters + 1)
    parameters[#parameters + 1] = { name = name, value = path }
    return name
  end
  local function matcher(path)
    local name = parameter(path)
    return string.format(
      '(require-any (literal (param "%s")) (subpath (param "%s")))',
      name, name)
  end
  local entries = effective_entries(profile)
  local function exclusions(root, predicate)
    local result = {}
    for _, entry in ipairs(entries) do
      if entry.path ~= root and contains(root, entry.path)
          and predicate(entry.access) then
        result[#result + 1] = entry.path
      end
    end
    return result
  end
  local function grant(operation, path, excluded)
    local rules = { matcher(path) }
    for _, child in ipairs(excluded or {}) do
      local name = parameter(child)
      rules[#rules + 1] =
        '(require-not (literal (param "' .. name .. '")))'
      rules[#rules + 1] =
        '(require-not (subpath (param "' .. name .. '")))'
    end
    sections[#sections + 1] = string.format(
      "(allow %s\n  (require-all\n    %s))",
      operation, table.concat(rules, "\n    "))
  end
  for _, entry in ipairs(entries) do
    if entry.access == "read" or entry.access == "write" then
      grant("file-read*", entry.path, exclusions(entry.path,
        function(access) return access == "deny" end))
    end
    if entry.access == "write" then
      grant("file-write*", entry.path, exclusions(entry.path,
        function(access) return access ~= "write" end))
    end
  end
  for _, entry in ipairs(internal or {}) do
    grant("file-read*", entry.path)
    if entry.access == "write" then grant("file-write*", entry.path) end
  end
  if profile.network == "enabled" then
    sections[#sections + 1] = "(allow network-outbound)"
    sections[#sections + 1] = "(allow network-inbound)"
  end
  return table.concat(sections, "\n"), parameters
end

function M.argv(sandbox_exec, policy, parameters)
  local argv = { sandbox_exec, "-p", policy }
  for _, parameter in ipairs(parameters) do
    argv[#argv + 1] = "-D" .. parameter.name .. "=" .. parameter.value
  end
  argv[#argv + 1] = "--"
  return argv
end

return M
