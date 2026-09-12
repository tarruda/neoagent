local root = vim.fn.fnamemodify(assert(debug.getinfo(1, "S")).source:sub(2), ":p:h:h")

---@type LuaCov.Configuration
local config = {
  statsfile = vim.env.NEOAGENT_COVERAGE == "1"
      and (root .. "/.coverage/raw/%s.out"):format(vim.uv.os_getpid())
    or root .. "/.coverage/luacov.stats.out",
  reportfile = root .. "/.coverage/luacov.report.out",
  include = {
    "lua/applet/",
    "lua/neoagent/",
    "plugin/",
  },
  exclude = {},
  modules = {},
  includeuntestedfiles = false,
}

return config
