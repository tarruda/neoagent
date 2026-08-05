local models = {
  ["deepseek/deepseek-v3.1-terminus"] = { context_window = 131072, max_output_tokens = 32768 },
  ["deepseek/deepseek-v3.2-exp"] = { context_window = 163840, max_output_tokens = 65536 },
  ["deepseek/deepseek-r1-0528"] = { context_window = 163840, max_output_tokens = 32768 },
  ["qwen/qwen3-235b-a22b-instruct-2507"] = { context_window = 131072, max_output_tokens = 16384 },
  ["zai-org/glm-4.6"] = { context_window = 204800, max_output_tokens = 131072 },
  ["moonshotai/kimi-k2-0905"] = { context_window = 262144, max_output_tokens = 100352 },
}

for _, model in pairs(models) do
  model.input = { "text" }
end

return {
  api = "openai-completions",
  base_url = "https://api.novita.ai/openai",
  api_key = function() return vim.env.NOVITA_API_KEY end,
  auth = "novita",
  models = models,
}
