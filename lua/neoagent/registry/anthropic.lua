local common = require("neoagent.registry.anthropic_common")

return {
  api = "anthropic-messages",
  base_url = "https://api.anthropic.com/v1",
  api_key = function() return vim.env.ANTHROPIC_API_KEY end,
  auth = "anthropic",
  request_opts = common.request_opts(),
  models = common.models(),
}
