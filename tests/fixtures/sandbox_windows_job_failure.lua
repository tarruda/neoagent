-- Keep failure injection at native ownership and persistence boundaries;
-- the ordinary runtime still owns recovery and finalization.
local ffi = require("ffi")
local load = ffi.load
local phase = vim.env.NEOAGENT_JOB_TEST_FAILURE or "missing"
local persistence_failed = false
---@type number?
local persistence_started
local termination_observed = false
local read_failed = false
local open = vim.uv.fs_open
local hrtime = vim.uv.hrtime
local admission_expired = false
vim.uv.hrtime = function()
  return hrtime() + (admission_expired and 10000000000 or 0)
end
vim.uv.fs_open = function(name, flags, mode)
  if phase == "read" and termination_observed and not read_failed and flags == "r" and name:match("state%.json$") then
    read_failed = true
    return nil, "EACCES: transient journal read failure", "EACCES"
  end
  return open(name, flags, mode)
end
---@param value Neoagent.FfiArray<integer>
---@return string
local function path(value)
  local length = 0
  while value[length] ~= 0 do length = length + 1 end
  return assert(vim.iconv(ffi.string(value, length * 2), "utf-16le", "utf-8"))
end

---@type ffi.cdata*?
local owned_job
ffi.load = function(name, global)
  local library = load(name, global)
  if name == "advapi32" and (phase == "admission" or phase == "creation_expired") then
    return setmetatable({ CreateProcessAsUserW = function(...)
      if phase == "admission" then
        load("kernel32").SetLastError(5)
        return 0
      end
      local result = library.CreateProcessAsUserW(...)
      if result ~= 0 then admission_expired = true end
      return result
    end }, { __index = library })
  end
  if name ~= "kernel32" then return library end
  return setmetatable({
    ResumeThread = function(handle)
      if phase == "resume" then
        library.SetLastError(5)
        return 0xffffffff
      end
      return library.ResumeThread(handle)
    end,
    QueryInformationJobObject = function(handle, kind, info, size, returned)
      local result = library.QueryInformationJobObject(handle, kind, info, size, returned)
      if phase == "read" and handle == owned_job and result ~= 0 and kind == 1
          and info.ActiveProcesses == 0 then
        local file = assert(io.open(vim.fs.joinpath(assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json"), "rb"))
        local state = vim.json.decode((file:read("*a")))
        file:close()
        local record = assert(io.open(assert(vim.env.NEOAGENT_JOB_TEST_RECORD), "wb"))
        record:write(vim.json.encode({ id = assert(next(state.leases)), job = "empty" }))
        record:close()
        termination_observed = true
      end
      return result
    end,
    MoveFileExW = function(from, to, flags)
      local delayed = (phase == "persist_delay" or phase == "admission")
        and (not persistence_started or vim.uv.hrtime() - persistence_started
          < (phase == "admission" and 11500000000 or 1500000000))
      if delayed or phase == "persist_deadline" or phase == "persist" and not persistence_failed then
        local file = assert(io.open(path(from), "rb"))
        local state = vim.json.decode((file:read("*a")))
        file:close()
        local id, lease = next(state.leases)
        if lease and lease.job == "empty" then
          -- Capture the native observation only for teardown of the failing
          -- baseline. No extra Job handle helps production finalization.
          local record = assert(io.open(assert(vim.env.NEOAGENT_JOB_TEST_RECORD), "wb"))
          record:write(vim.json.encode({ id = id, job = lease.job }))
          record:close()
          persistence_failed = true
          persistence_started = persistence_started or vim.uv.hrtime()
          library.SetLastError(32) -- ERROR_SHARING_VIOLATION.
          return 0
        end
      end
      return library.MoveFileExW(from, to, flags)
    end,
    OpenJobObjectW = function(access, inherit, job_name)
      if phase == "missing" then
        library.SetLastError(2) -- ERROR_FILE_NOT_FOUND.
        return nil
      end
      local job = library.OpenJobObjectW(access, inherit, job_name)
      if job ~= nil then
        owned_job = job
        if phase == "admission_expired" then admission_expired = true end
      end
      return job
    end,
    CloseHandle = function(handle)
      local closed = library.CloseHandle(handle)
      if phase == "closed" and handle == owned_job then
        local path = vim.fs.joinpath(assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE), "state.json")
        local file = assert(io.open(path, "rb"))
        local state = vim.json.decode((file:read("*a")))
        file:close()
        local id, lease = next(state.leases)
        local record = assert(io.open(assert(vim.env.NEOAGENT_JOB_TEST_RECORD), "wb"))
        record:write(vim.json.encode({ id = id, job = lease and lease.job }))
        record:close()
        os.exit(137)
      end
      return closed
    end,
  }, { __index = library })
end

local source = assert(debug.getinfo(1, "S")).source:sub(2)
local checkout = assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(source))))))
dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_runtime.lua"))
