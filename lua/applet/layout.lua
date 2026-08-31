local Pane = require("applet.pane")
local util = require("applet.util")

local M = {}

local function node(kind, opts)
  util.expect(type(opts) == "table", "Applet " .. kind,
    "options must be a table", 4)
  local result = util.copy(opts)
  result.type = kind
  return result
end

for _, kind in ipairs({ "frame", "split", "scope", "layer" }) do
  M[kind] = function(opts) return node(kind, opts) end
end

function M.mount(pane, opts)
  util.expect(Pane.is(pane), "Applet mount.pane",
    "must be a Pane instance", 3)
  opts = opts or {}
  util.expect(type(opts) == "table", "Applet mount",
    "options must be a table", 3)
  local result = util.copy(opts)
  result.type = "mount"
  result.pane = pane
  return result
end

M.compile = require("applet.layout.compile").compile

return M
