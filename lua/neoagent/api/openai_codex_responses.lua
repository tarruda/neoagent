local responses = require("neoagent.api.openai_responses")
local util = require("neoagent.util")

local M = {}

local function base_url(value)
  local normalized = value:gsub("/+$", "")
  if normalized:sub(-10) == "/responses" then normalized = normalized:sub(1, -11) end
  if normalized:sub(-6) ~= "/codex" then normalized = normalized .. "/codex" end
  return normalized
end

function M.new(opts)
  opts = util.copy(opts or {})
  assert(type(opts.base_url) == "string" and opts.base_url ~= "", "base_url is required")
  opts.base_url = base_url(opts.base_url)
  opts.profile = "codex"
  local model = responses.new(opts)
  model.api = "openai-codex-responses"
  return model
end

return M
