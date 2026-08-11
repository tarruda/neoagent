local models = {
  ["moonshotai/kimi-k3"] = {
    context_window = 1048576,
    max_output_tokens = 1048576,
    input = { "text", "image" },
  },
  ["zai-org/glm-5.2"] = { context_window = 1048576, max_output_tokens = 131072 },
  ["deepseek/deepseek-v4-flash-0731"] = { context_window = 1048576, max_output_tokens = 393216 },
}

for _, model in pairs(models) do
  model.input = model.input or { "text" }
end

return {
  api = "openai-completions",
  base_url = "https://api.novita.ai/openai",
  api_key = function() return vim.env.NOVITA_API_KEY end,
  auth = "novita",
  models = models,
}
