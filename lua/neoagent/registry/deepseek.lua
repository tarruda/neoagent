local metadata = require("neoagent.providers.deepseek.model_metadata")
local no_source_options = require("neoagent.model_catalog.source").no_options

---@type Neoagent.DiscoveredModel[]
local seed = {}
for _, id in ipairs({
  "deepseek-v4-flash",
  "deepseek-v4-pro",
  "deepseek-v4-flash-vision-exp",
}) do
  seed[#seed + 1] = { id = id }
end

---@param model Neoagent.DiscoveredModel
---@return Neoagent.ModelConfigInput
local function transform(model)
  local defaults = metadata.for_id(model.id)
  local result = require("neoagent.util").deep_merge(defaults, model)
  ---@cast result Neoagent.ModelConfigInput
  return result
end

---@type Neoagent.ProviderDefinition
local provider = {
  api = "openai-completions",
  base_url = "https://api.deepseek.com",
  api_key = function()
    return vim.env.DEEPSEEK_API_KEY
  end,
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

return provider
