local util = require("neoagent.util")

local M = {}

local defaults = {
  default_registry = true,
  providers = {},
  apis = {},
  auth = {
    path = vim.fn.stdpath("state") .. "/neoagent/auth.json",
    methods = {
      ["openai-codex"] = require("neoagent.auth.openai_codex").new(),
    },
  },
  persistence = {
    enabled = true,
    directory = vim.fn.stdpath("state") .. "/neoagent/sessions",
  },
  max_tool_rounds = 12,
  ui = {
    position = "auto",
    margin = 1,
    input_height = 5,
    border = "rounded",
    mappings = {
      submit = "<C-s>",
      cancel_input = "<C-c>",
      toggle_focus = "<C-w>w",
      expand_tools = "<C-o>",
      dock_left = "<C-w>H",
      dock_bottom = "<C-w>J",
      dock_top = "<C-w>K",
      dock_right = "<C-w>L",
      dock_center = "<C-w>=",
      close = "q",
    },
  },
}

local current

local function validate_dimension(value, name)
  if value == nil then return end
  if type(value) ~= "number" or value <= 0 or (value > 1 and value % 1 ~= 0) then
    error(name .. " must be a fraction in (0, 1] or an integer greater than one")
  end
end

local function validate(opts)
  assert(type(opts.default_registry) == "boolean", "default_registry must be boolean")
  if opts.default_model ~= nil then
    assert(type(opts.default_model) == "table", "default_model must be a table")
    assert(type(opts.default_model.provider) == "string", "default_model.provider is required")
    assert(type(opts.default_model.model) == "string", "default_model.model is required")
  end
  assert(type(opts.providers) == "table", "providers must be a table")
  for id, provider in pairs(opts.providers) do
    assert(type(id) == "string" and type(provider) == "table", "providers must be keyed tables")
    assert(type(provider.api) == "string" and provider.api ~= "", "provider " .. id .. " requires api")
    assert(type(provider.models) == "table", "provider " .. id .. " requires models")
    if provider.api == "openai-completions" or provider.api == "openai-responses"
        or provider.api == "openai-codex-responses" then
      assert(type(provider.base_url) == "string" and provider.base_url ~= "", "provider " .. id .. " requires base_url")
    end
    if provider.auth ~= nil then
      assert(type(provider.auth) == "string" and provider.auth ~= "", "provider auth must be a method name")
    end
    if provider.api_key ~= nil then
      assert(type(provider.api_key) == "string" or type(provider.api_key) == "function", "api_key must be a string or function")
    end
    if provider.request_opts ~= nil then
      assert(type(provider.request_opts) == "table" or type(provider.request_opts) == "function", "request_opts must be a table or function")
    end
    for model_id, model in pairs(provider.models) do
      assert(type(model_id) == "string" and type(model) == "table", "models must be keyed tables")
      if provider.api == "openai-responses" or provider.api == "openai-codex-responses" then
        if model.reasoning ~= nil then assert(type(model.reasoning) == "boolean", "model reasoning must be boolean") end
        if model.reasoning_effort ~= nil then
          assert(type(model.reasoning_effort) == "string" and model.reasoning_effort ~= "",
            "model reasoning_effort must be a non-empty string")
        end
        if model.reasoning_summary ~= nil then
          assert(type(model.reasoning_summary) == "string" and model.reasoning_summary ~= "",
            "model reasoning_summary must be a non-empty string")
        end
        if provider.api == "openai-codex-responses" and model.text_verbosity ~= nil then
          assert(type(model.text_verbosity) == "string" and model.text_verbosity ~= "",
            "model text_verbosity must be a non-empty string")
        end
      end
      if model.request_opts ~= nil then
        assert(type(model.request_opts) == "table" or type(model.request_opts) == "function", "model request_opts must be a table or function")
      end
    end
  end
  assert(type(opts.apis) == "table", "apis must be a table")
  for name, factory in pairs(opts.apis) do
    assert(type(name) == "string" and type(factory) == "function", "apis must contain functions")
  end
  assert(type(opts.auth) == "table", "auth must be a table")
  assert(type(opts.auth.path) == "string" and opts.auth.path ~= "", "auth.path is required")
  assert(type(opts.auth.methods) == "table", "auth.methods must be a table")
  for id, method in pairs(opts.auth.methods) do
    assert(type(id) == "string" and type(method) == "table", "auth methods must be keyed tables")
    assert(type(method.name) == "string" and method.name ~= "", "auth method name is required")
    assert(type(method.login) == "function" and type(method.refresh) == "function"
      and type(method.request_opts) == "function", "auth methods require login, refresh, and request_opts")
  end
  for id, provider in pairs(opts.providers) do
    if provider.auth ~= nil then
      assert(opts.auth.methods[provider.auth] ~= nil,
        "provider " .. id .. " uses unknown auth method " .. provider.auth)
    end
  end
  assert(type(opts.max_tool_rounds) == "number" and opts.max_tool_rounds >= 1 and opts.max_tool_rounds % 1 == 0, "max_tool_rounds must be a positive integer")
  assert(type(opts.persistence) == "table", "persistence must be a table")
  assert(type(opts.persistence.enabled) == "boolean", "persistence.enabled must be boolean")
  assert(type(opts.persistence.directory) == "string" and opts.persistence.directory ~= "", "persistence.directory is required")
  local positions = { auto = true, left = true, right = true, top = true, bottom = true, center = true }
  assert(positions[opts.ui.position], "invalid ui.position")
  validate_dimension(opts.ui.width, "ui.width")
  validate_dimension(opts.ui.height, "ui.height")
  assert(type(opts.ui.margin) == "number" and opts.ui.margin >= 0 and opts.ui.margin % 1 == 0, "ui.margin must be a non-negative integer")
  assert(type(opts.ui.input_height) == "number" and opts.ui.input_height >= 1 and opts.ui.input_height % 1 == 0, "ui.input_height must be a positive integer")
  for action, mapping in pairs(opts.ui.mappings) do
    assert(type(action) == "string" and (type(mapping) == "string" or mapping == false), "UI mappings must be strings or false")
  end
  if opts.tools ~= nil then assert(type(opts.tools) == "table", "tools must be an array") end
  if opts.system_prompt ~= nil then assert(type(opts.system_prompt) == "string" or type(opts.system_prompt) == "function", "system_prompt must be a string or function") end
  if opts.execute_tool ~= nil then assert(type(opts.execute_tool) == "function", "execute_tool must be a function") end
  if opts.interaction ~= nil then assert(type(opts.interaction) == "function", "interaction must be a function") end
end

function M.setup(opts)
  opts = opts or {}
  local configured = util.deep_merge(defaults, opts)
  configured.providers = require("neoagent.registry").compose(opts.providers or {}, configured.default_registry)
  configured._tools_supplied = opts.tools ~= nil
  validate(configured)
  current = configured
  return M.get()
end

function M.get()
  if not current then M.setup({}) end
  return util.copy(current)
end

function M._reset()
  current = nil
end

return M
