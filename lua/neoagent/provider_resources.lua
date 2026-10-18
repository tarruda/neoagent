local util = require("neoagent.util")
local runtimes = require("neoagent.provider_runtimes")
local M = {}

---@class Neoagent.ProviderResourcesOptions
---@field auth? Neoagent.AuthManager
---@field transport? Neoagent.ByteBackend
---@field store? Neoagent.CatalogStorage
---@field startup? boolean
---@field report fun(message: string, level?: integer): unknown

---@class Neoagent.ProviderResources
---@field auth Neoagent.AuthManager
---@field runtimes Neoagent.ProviderRuntimes
---@field recorder? Neoagent.Recorder
---@field destroy fun(self: Neoagent.ProviderResources)

-- The composition owns this bundle. Reporting is borrowed so a direct Agent
-- and the Provider Shell can retain their own diagnostic lifetimes.
---@param configured Neoagent.Config<Neoagent.AgentToolEnvironment>
---@param options Neoagent.ProviderResourcesOptions
---@return Neoagent.ProviderResources
function M.new(configured, options)
  ---@type Neoagent.Recorder?
  local recorder
  ---@return Neoagent.ProviderResources
  local function compose()
    local transport = options.transport
    if configured.recording.enabled then
      recorder = assert(require("neoagent.http_recording").new({
        config = configured.recording,
        report = options.report,
      }))
      transport = recorder:transport(transport or require("neoagent.transport.curl"))
    end
    local auth = options.auth
      or require("neoagent.auth").configured({ auth = configured.auth }, { transport = transport })
    local providers, err = runtimes.compose(configured, {
      auth = auth,
      store = options.store or require("neoagent.state_store").new({
        directory = vim.fn.stdpath("state") .. "/neoagent/provider/state",
      }),
      startup = options.startup,
      report = options.report,
      transport = transport,
    })
    if not providers then
      error(err, 0)
    end
    local destroyed = false
    return {
      auth = auth,
      runtimes = providers,
      recorder = recorder,
      destroy = function()
        if destroyed then
          return
        end
        destroyed = true
        runtimes.destroy(providers)
        if recorder then
          recorder:destroy()
        end
      end,
    }
  end
  local ok, resources = pcall(compose)
  if not ok then
    if recorder then
      recorder:destroy()
    end
    error(util.normalize_error(resources, "provider"), 0)
  end
  return resources
end

return M
