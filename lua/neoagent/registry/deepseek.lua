local util = require("neoagent.util")

local thinking = {
  off = { body = { thinking = { type = "disabled" } } },
  high = { body = { thinking = { type = "enabled" }, reasoning_effort = "high" } },
  max = { body = { thinking = { type = "enabled" }, reasoning_effort = "max" } },
}

local models = {}
for _, id in ipairs({ "deepseek-v4-flash", "deepseek-v4-pro" }) do
  models[id] = {
    context_window = 1000000,
    max_output_tokens = 384000,
    thinking = util.copy(thinking),
  }
end

return {
  api = "openai-completions",
  base_url = "https://api.deepseek.com",
  api_key = function() return vim.env.DEEPSEEK_API_KEY end,
  auth = "deepseek",
  request_opts = { body = { stream_options = { include_usage = true } } },
  models = models,
}
