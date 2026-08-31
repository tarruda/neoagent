local util = require("applet.util")

local M = {}

local function node(kind, opts)
  util.expect(type(opts) == "table", kind, "options must be a table", 4)
  local result = util.copy(opts)
  result.type = kind
  return result
end

for _, kind in ipairs({
  "region", "text", "column", "row", "container", "responsive", "panel", "source",
  "image", "target", "scope", "virtual",
}) do
  M[kind] = function(opts) return node(kind, opts) end
end

function M.action(name, payload)
  util.expect(util.nonempty_string(name), "action", "name must be a non-empty string", 3)
  return { action = name, payload = payload }
end

function M.tree(root, opts)
  util.expect(type(root) == "table", "tree.root", "must be a node", 3)
  local result = util.copy(opts)
  result.root = root
  return result
end

return M
