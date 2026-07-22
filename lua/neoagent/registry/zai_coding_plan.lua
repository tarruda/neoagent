local util = require("neoagent.util")
local zai = require("neoagent.registry.zai")

local models = {}
for _, id in ipairs({
  "glm-4.5-air",
  "glm-4.7",
  "glm-5-turbo",
  "glm-5.1",
  "glm-5.2",
  "glm-5v-turbo",
}) do
  models[id] = util.copy(zai.models[id])
end

return {
  api = zai.api,
  base_url = "https://api.z.ai/api/coding/paas/v4",
  api_key = zai.api_key,
  auth = zai.auth,
  request_opts = util.copy(zai.request_opts),
  models = models,
}
