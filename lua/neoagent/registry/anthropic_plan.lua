local common = require("neoagent.registry.anthropic_common")

return {
  api = "anthropic-messages",
  base_url = "https://api.anthropic.com/v1",
  api_key = function() return vim.env.ANTHROPIC_OAUTH_TOKEN end,
  auth = "anthropic-plan",
  request_opts = common.request_opts({ claude_code_identity = true }),
  models = common.models(),
}
