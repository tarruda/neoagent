local M = {}

local function executable(name, required)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(name .. " is available")
    return true
  elseif required then
    vim.health.error(name .. " is required but was not found")
  else
    vim.health.warn(name .. " is unavailable; image resizing will be disabled")
  end
  return false
end

local function at_least(version, minimum)
  for index = 1, math.max(#version, #minimum) do
    local actual = version[index] or 0
    local required = minimum[index] or 0
    if actual ~= required then return actual > required end
  end
  return true
end

local function curl()
  if not executable("curl", true) then return end
  local output = vim.fn.system({ "curl", "--version" })
  local major, minor, patch = output:match("^curl%s+(%d+)%.(%d+)%.(%d+)")
  if vim.v.shell_error ~= 0 or not major then
    vim.health.error("could not determine the curl version")
  elseif at_least({ tonumber(major), tonumber(minor), tonumber(patch) }, { 7, 76, 0 }) then
    vim.health.ok(string.format("curl %s.%s.%s satisfies the 7.76+ requirement", major, minor, patch))
  else
    vim.health.error(string.format("curl %s.%s.%s is too old; version 7.76+ is required", major, minor, patch))
  end
end

local function check_configuration()
  local configured = require("neoagent.config").get()
  local manager = require("neoagent.auth").configured(configured)
  local provider_services = require("neoagent.provider_services")
  local services, service_err = provider_services.compose(configured, {
    auth = manager,
    startup = false,
  })
  if not services then error(service_err, 0) end
  local ok, err = pcall(function()
    local selected = configured.default_model
    if not selected then return end
    local provider = configured.providers[selected.provider]
    if not provider then
      error("Unknown provider: " .. tostring(selected.provider), 0)
    end
    local defined = type(provider.models[selected.model]) == "table"
    local discovered = false
    local service = services[selected.provider]
    if service and type(service.get_models) == "function" then
      local models = service:get_models()
      for _, model in ipairs(models or {}) do
        if type(model) == "table" and model.id == selected.model then
          discovered = true
          break
        end
      end
    end
    if not defined and not discovered
        and service and type(service.refresh_catalog) == "function" then
      vim.health.warn("default model " .. selected.provider .. "/"
        .. selected.model .. " awaits the dynamic provider catalog")
      return
    end
    require("neoagent.models").resolve(selected.provider, selected.model,
      configured, manager, services)
  end)
  provider_services.destroy(services)
  if not ok then error(err, 0) end
end

function M.check()
  vim.health.start("neoagent")
  if vim.fn.has("nvim-0.10") == 1 then vim.health.ok("Neovim 0.10+ detected")
  else vim.health.error("Neovim 0.10 or newer is required") end
  curl()
  executable("rg", true)
  executable("fd", true)
  executable("magick", false)
  local ok, err = pcall(check_configuration)
  if ok then vim.health.ok("configuration is valid") else vim.health.error("configuration error: " .. tostring(err)) end
end

return M
