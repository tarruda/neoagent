local M = {}

local function executable(name)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(name .. " is available")
    return true
  end
  vim.health.error(name .. " is required but was not found")
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
  if not executable("curl") then return end
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
  local applet, resources
  local ok, err = pcall(function()
    local profiles, default_profile
    local profile_recipes = require("neoagent.profiles")
    profiles, default_profile, resources = profile_recipes.bundled(configured,
      { startup = false })
    applet = require("neoagent.applet").new({
      profiles = profiles,
      default_profile = default_profile,
      resources = resources,
    })
    assert(#applet:agents() == 0,
      "Profile composition must not construct Agents")
    local selected = configured.default_model
    if not selected then return end
    local runtime = resources.runtimes[selected.provider]
    if not runtime then
      error("Unknown provider: " .. tostring(selected.provider), 0)
    end
    local snapshot = runtime.catalog:snapshot()
    if snapshot.models[selected.model] == nil
        and type(runtime.definition.catalog.discover) == "function" then
      vim.health.warn("default model " .. selected.provider .. "/"
        .. selected.model .. " awaits the " .. selected.provider
        .. " provider catalog")
      return
    end
    require("neoagent.models").resolve(selected.provider, selected.model,
      configured, resources.auth, resources.runtimes)
  end)
  if applet then applet:destroy()
  elseif resources then resources:destroy() end
  if not ok then error(err, 0) end
end

local function check_images()
  local images = require("neoagent.config").get().ui.images
  if images == false then
    vim.health.ok("terminal image display is disabled")
    return
  end
  local diagnostics = require("applet").ImageSystem.diagnostics({
    backend = images.backend,
  })
  for _, diagnostic in ipairs(diagnostics) do
    local report = vim.health[diagnostic.level]
    assert(type(report) == "function",
      "unknown Applet image diagnostic level: " .. tostring(diagnostic.level))
    report(diagnostic.message)
  end
end

function M.check()
  vim.health.start("neoagent")
  if vim.fn.has("nvim-0.10") == 1 then vim.health.ok("Neovim 0.10+ detected")
  else vim.health.error("Neovim 0.10 or newer is required") end
  curl()
  executable("rg")
  executable("fd")
  check_images()
  local ok, err = pcall(check_configuration)
  if ok then
    vim.health.ok("configuration is valid")
  else
    local failure = require("neoagent.util").normalize_error(
      err, "configuration")
    vim.health.error("configuration error: " .. failure.message)
  end
end

return M
