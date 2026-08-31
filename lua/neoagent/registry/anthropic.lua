local common = require("neoagent.registry.anthropic_common")

local CLOUD_TTL_MS = 14 * 24 * 60 * 60 * 1000

return {
  api = "anthropic-messages",
  base_url = "https://api.anthropic.com/v1",
  api_key = function() return vim.env.ANTHROPIC_API_KEY end,
  auth = "anthropic",
  catalog = {
    ttl_ms = CLOUD_TTL_MS,
    discover = require("neoagent.providers.anthropic").discover_models,
    transform_model = common.transform,
  },
  request_opts = common.request_opts(),
  models = {},
  service = require("neoagent.providers.anthropic").new,
}
