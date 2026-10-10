-- Interrupt elevated setup immediately after a successful persistent native
-- effect. The parent verifies that later setup attempts reuse its ownership.
local ffi = require("ffi")
local load = ffi.load
local phase = assert(vim.env.NEOAGENT_SETUP_TEST_PHASE)
local record = assert(vim.env.NEOAGENT_SETUP_TEST_RECORD)

---@param pointer ffi.cdata*
---@return string
local function name(pointer)
  local value = ffi.cast("unsigned short *", pointer) --[[@as Neoagent.FfiArray<integer>]]
  local bytes = {}
  for index = 0, 255 do
    if value[index] == 0 then return table.concat(bytes) end
    bytes[#bytes + 1] = string.char(value[index])
  end
  error("unterminated setup principal name")
end

local function effect(kind, identity)
  local file = assert(io.open(record, "ab"))
  file:write(vim.json.encode({ kind = kind, identity = identity }) .. "\n")
  file:close()
  if phase == kind then os.exit(137) end
end

ffi.load = function(library_name, global)
  local library = load(library_name, global)
  if library_name == "netapi32" then
    return setmetatable({
      NetUserAdd = function(server, level, info, parameter)
        local code = library.NetUserAdd(server, level, info, parameter)
        if code == 0 then
          local value = ffi.cast("USER_INFO_1 *", info) --[[@as Neoagent.FfiArray<Neoagent.Win32.USER_INFO_1>]]
          effect("launcher", name(assert(value[0].usri1_name)))
        end
        return code
      end,
      NetLocalGroupAdd = function(server, level, info, parameter)
        local code = library.NetLocalGroupAdd(server, level, info, parameter)
        if code == 0 then
          local value = ffi.cast("NASamGroup *", info) --[[@as Neoagent.FfiArray<Neoagent.WindowsSamGroup>]]
          effect("group", name(value[0].name))
        end
        return code
      end,
    }, { __index = library })
  elseif library_name == "advapi32" then
    return setmetatable({
      LsaAddAccountRights = function(policy, sid, rights, count)
        local code = library.LsaAddAccountRights(policy, sid, rights, count)
        if code == 0 then effect("rights", "launcher") end
        return code
      end,
    }, { __index = library })
  elseif library_name == "fwpuclnt" then
    return setmetatable({
      FwpmFilterAdd0 = function(engine, filter, descriptor, id)
        local code = library.FwpmFilterAdd0(engine, filter, descriptor, id)
        if code == 0 then
          local value = ffi.new("GUID[1]", filter.filterKey)
          local bytes = ffi.string(value, 16)
          effect("filter", (bytes:gsub(".", function(byte) return ("%02x"):format(byte:byte()) end)))
        end
        return code
      end,
      FwpmTransactionCommit0 = function(engine)
        local code = library.FwpmTransactionCommit0(engine)
        if code == 0 then effect("firewall", "committed") end
        return code
      end,
    }, { __index = library })
  end
  return library
end

local source = assert(debug.getinfo(1, "S")).source:sub(2)
local checkout = assert(vim.fs.dirname(assert(vim.fs.dirname(assert(vim.fs.dirname(source))))))
dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_runtime.lua"))
