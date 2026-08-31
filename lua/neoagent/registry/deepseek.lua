local metadata = require("neoagent.providers.deepseek.model_metadata")

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
    ttl_ms = 14 * 24 * 60 * 60 * 1000,
    seed = seed,
    discover = require("neoagent.providers.deepseek").discover_models,
    transform_model = transform,
  },
  request_opts = { body = { stream_options = { include_usage = true } } },
  models = {},
  service = require("neoagent.providers.deepseek").new,
}
