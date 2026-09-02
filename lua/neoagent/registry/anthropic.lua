local common = require("neoagent.registry.anthropic_common")
local no_source_options = require("neoagent.model_catalog.source").no_options

local CLOUD_TTL_MS = 14 * 24 * 60 * 60 * 1000

return {
  api = "anthropic-messages",
  base_url = "https://api.anthropic.com/v1",
  api_key = function() return vim.env.ANTHROPIC_API_KEY end,
  auth = "anthropic",
  catalog = {
    source_id = "anthropic-models",
    source_revision = 1,
    source_options = no_source_options,
    account_scoped = true,
    ttl_ms = CLOUD_TTL_MS,
    discover = require("neoagent.providers.anthropic").discover_models,
    transform_model = common.transform,
  },
  request_opts = common.request_opts(),
  models = {},
  service = require("neoagent.providers.anthropic").new,
}
