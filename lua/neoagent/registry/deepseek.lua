local metadata = require("neoagent.providers.deepseek.model_metadata")
local no_source_options = require("neoagent.model_catalog.source").no_options

local seed = {}
for _, id in ipairs({
  "deepseek-v4-flash", "deepseek-v4-pro",
  "deepseek-v4-flash-vision-exp",
}) do
  seed[#seed + 1] = { id = id }
end

local function transform(model)
  return require("neoagent.util").deep_merge(metadata.for_id(model.id), model)
end

return {
  api = "openai-completions",
  base_url = "https://api.deepseek.com",
  api_key = function() return vim.env.DEEPSEEK_API_KEY end,
  auth = "deepseek",
  catalog = {
    source_id = "deepseek-models",
    source_revision = 1,
    source_options = no_source_options,
    account_scoped = true,
    ttl_ms = 14 * 24 * 60 * 60 * 1000,
    seed = seed,
    discover = require("neoagent.providers.deepseek").discover_models,
    transform_model = transform,
  },
  request_opts = { body = { stream_options = { include_usage = true } } },
  models = {},
  service = require("neoagent.providers.deepseek").new,
}
