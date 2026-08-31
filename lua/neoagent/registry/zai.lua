local common = require("neoagent.registry.zai_common")

local ids = {
  "glm-4.5", "glm-4.5-air", "glm-4.5-flash", "glm-4.5v", "glm-4.6",
  "glm-4.6v", "glm-4.7", "glm-4.7-flash", "glm-4.7-flashx", "glm-5",
  "glm-5-turbo", "glm-5.1", "glm-5.2", "glm-5.3", "glm-5.3-flash",
  "glm-5v-turbo",
}

return {
  api = "openai-completions",
  base_url = "https://api.z.ai/api/paas/v4",
  api_key = function() return vim.env.ZAI_API_KEY end,
  auth = "zai",
  request_opts = { body = { stream_options = { include_usage = true } } },
  catalog = {
    ttl_ms = 14 * 24 * 60 * 60 * 1000,
    seed = common.seed(ids),
    discover = require("neoagent.providers.zai").discover_models,
    transform_model = common.transform,
  },
  models = {},
  service = require("neoagent.providers.zai").new,
}
