local root = vim.fn.fnamemodify(assert(debug.getinfo(1, "S")).source:sub(2), ":p:h:h")
local normalized_root = root:gsub("\\", "/"):gsub("/+$", "")
local root_pattern = normalized_root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")

---@type LuaCov.Configuration
local config = {
  statsfile = vim.env.NEOAGENT_COVERAGE == "1"
      and (root .. "/.coverage/raw/%s.out"):format(vim.uv.os_getpid())
    or root .. "/.coverage/luacov.stats.out",
  reportfile = root .. "/.coverage/luacov.report.out",
  include = {
    "^" .. root_pattern .. "/lua/applet/",
    "^" .. root_pattern .. "/lua/neoagent/",
    "^" .. root_pattern .. "/plugin/",
    "^lua/applet/",
    "^lua/neoagent/",
    "^plugin/",
  },
  exclude = {},
  modules = {},
  includeuntestedfiles = false,
}

return config
