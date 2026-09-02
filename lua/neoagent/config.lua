local util = require("neoagent.util")
local api_key = require("neoagent.auth.api_key")
local agent_loop = require("neoagent.agent_loop")
local model_config = require("neoagent.model_config")

local M = {}

local renderer_styles = { codex = true, pi = true }

local defaults = {
  default_registry = true,
  shell_timeout = 300,
  sandbox = {
    enabled = false,
  },
  workspace_trust = {
    path = vim.fn.stdpath("state") .. "/neoagent/trust.json",
  },
  default_thinking_level = "medium",
  providers = {},
  _apis = {},
  auth = {
    path = vim.fn.stdpath("state") .. "/neoagent/auth.json",
    methods = {
      openai = api_key.new({ name = "OpenAI API key" }),
      deepseek = api_key.new({ name = "DeepSeek API key" }),
      zai = api_key.new({ name = "Z.AI API and Plan key" }),
      anthropic = api_key.new({
        name = "Anthropic API key",
        request_opts = function(credential)
          return { headers = { ["x-api-key"] = credential.key } }
        end,
      }),
      ["opencode-go"] = api_key.new({
        name = "OpenCode Go API key",
        request_opts = function(credential)
          return { headers = {
            Authorization = "Bearer " .. credential.key,
            ["x-api-key"] = credential.key,
          } }
        end,
      }),
      ["openai-codex"] = require("neoagent.auth.openai_codex").new(),
      llama = require("neoagent.providers.llama.auth").new(),
    },
  },
  persistence = {
    enabled = true,
    workspace_settings = true,
    directory = vim.fn.stdpath("state") .. "/neoagent/workspaces",
  },
  recording = {
    enabled = false,
    format = "auto",
    directory = vim.fn.stdpath("state")
      .. "/neoagent/workspaces/recordings",
  },
  agent_instructions = {
    global_files = { vim.fn.stdpath("config") .. "/AGENTS.md" },
    project_filenames = { "AGENTS.md" },
  },
  skills = {
    global_dirs = {
      vim.fn.expand("~/.agents/skills"),
      vim.fn.stdpath("config") .. "/neoagent/skills",
    },
    project_dirs = { ".agents/skills" },
  },
  retry = {
    enabled = true,
    max_retries = 3,
    base_delay_ms = 2000,
  },
  compaction = {
    auto = true,
    reserve_tokens = 16384,
    keep_recent_tokens = 20000,
  },
  ui = {
    style = "codex",
    position = "center",
    margin = 1,
    input_height = 7,
    scroll_on_submit = true,
    scroll_on_transcript_leave = true,
    scroll_on_reopen = true,
    wrap_cards = false,
    show_thinking = true,
    images = { backend = "kitty", display = "always" },
    provider_shell = {
      position = "center",
      width = 0.75,
      height = 0.75,
    },
    completion = true,
    border = "rounded",
    mappings = {
      help = "<C-g>?",
      submit = "<CR>",
      complete = "<Tab>",
      interrupt = "<C-c>",
      close_input = "<Esc><Esc>",
      close_empty = "<C-d>",
      card_details = "<CR>",
      card_raw = "r",
      card_follow = "<A-f>",
      card_center = "zz",
      card_previous = { "<A-k>", "<C-Up>" },
      card_next = { "<A-j>", "<C-Down>" },
      focus_input = "<C-w>j",
      focus_transcript = "<C-w>k",
      provider_previous = "<C-k>",
      provider_next = "<C-j>",
      menu_previous = "K",
      menu_next = "J",
      cycle_thinking = "<S-Tab>",
      agents = "<A-n>",
      select_model = "<A-m>",
      resume_session = "<A-r>",
      history_previous = { "<Up>", "<C-k>" },
      history_next = "<Down>",
      select_history = "<C-r>",
      dequeue_steering = "<A-Up>",
      toggle_provider_shell = "<A-p>",
      provider_close = "q",
      close = "q",
    },
  },
  _view = nil,
}

local input_fields = {
  default_registry = true,
  shell_timeout = true,
  sandbox = true,
  workspace_trust = true,
  default_thinking_level = true,
  default_model = true,
  providers = true,
  auth = true,
  persistence = true,
  recording = true,
  agent_instructions = true,
  skills = true,
  retry = true,
  compaction = true,
  ui = true,
  name = true,
  tools = true,
  system_prompt = true,
  execute_tool = true,
  _apis = true,
  _view = true,
}

local current
local built_in_apis = {
  ["openai-completions"] = true,
  ["openai-responses"] = true,
  ["openai-codex-responses"] = true,
  ["anthropic-messages"] = true,
}

local provider_fields = {
  api = true,
  api_key = true,
  auth = true,
  auth_optional = true,
  base_url = true,
  catalog = true,
  diagnostics = true,
  models = true,
  request_opts = true,
  service = true,
  service_opts = true,
}

local catalog_fields = {
  account_scoped = true,
  discover = true,
  seed = true,
  source_id = true,
  source_options = true,
  source_revision = true,
  ttl_ms = true,
  transform_model = true,
}

local function provider_uses_api(provider, name)
  if provider.api == name then return true end
  for _, model in pairs(provider.models or {}) do
    if type(model) == "table" and model.api == name then return true end
  end
  return false
end

local function validate_dimension(value, name)
  if value == nil then return end
  if type(value) ~= "number" or value <= 0 or (value > 1 and value % 1 ~= 0) then
    error(name .. " must be a fraction in (0, 1] or an integer greater than one")
  end
end

local function validate(opts)
  assert(opts.name == nil or (type(opts.name) == "string" and opts.name ~= ""),
    "name must be a non-empty string")
  assert(type(opts.default_registry) == "boolean", "default_registry must be boolean")
  assert(opts.shell_timeout == false
      or type(opts.shell_timeout) == "number"
        and opts.shell_timeout > 0 and opts.shell_timeout < math.huge,
    "shell_timeout must be false or a positive finite number")
  assert(type(opts.sandbox) == "table" and not util.is_list(opts.sandbox),
    "sandbox must be a table")
  assert(type(opts.sandbox.enabled) == "boolean",
    "sandbox.enabled must be boolean")
  for key in pairs(opts.sandbox) do
    assert(key == "enabled" or key == "profile",
      "unsupported sandbox setting: " .. tostring(key))
  end
  assert(opts.sandbox.profile == nil
      or type(opts.sandbox.profile) == "table"
      or type(opts.sandbox.profile) == "function",
    "sandbox.profile must be a table or function")
  assert(opts.workspace_trust == false
      or (type(opts.workspace_trust) == "table"
        and not util.is_list(opts.workspace_trust)),
    "workspace_trust must be false or a table")
  if opts.workspace_trust then
    for key in pairs(opts.workspace_trust) do
      assert(key == "path",
        "unsupported workspace_trust setting: " .. tostring(key))
    end
    assert(type(opts.workspace_trust.path) == "string"
        and opts.workspace_trust.path ~= "",
      "workspace_trust.path is required")
  end
  assert(require("neoagent.thinking").is_level(opts.default_thinking_level),
    "default_thinking_level must be off, minimal, low, medium, high, xhigh, max, or ultra")
  if opts.default_model ~= nil then
    assert(type(opts.default_model) == "table", "default_model must be a table")
    assert(model_config.safe_provider_id(opts.default_model.provider),
      "default_model.provider must be safe text without path separators")
    assert(model_config.safe_id(opts.default_model.model),
      "default_model.model must be safe non-empty text")
  end
  assert(type(opts.providers) == "table", "providers must be a table")
  assert(type(opts.retry) == "table", "retry must be a table")
  assert(type(opts.retry.enabled) == "boolean", "retry.enabled must be boolean")
  assert(type(opts.retry.max_retries) == "number" and opts.retry.max_retries >= 0
    and opts.retry.max_retries % 1 == 0, "retry.max_retries must be a non-negative integer")
  assert(type(opts.retry.base_delay_ms) == "number" and opts.retry.base_delay_ms > 0
    and opts.retry.base_delay_ms % 1 == 0, "retry.base_delay_ms must be a positive integer")
  if opts.compaction ~= false then
    assert(type(opts.compaction) == "table", "compaction must be false or a table")
    assert(type(opts.compaction.auto) == "boolean", "compaction.auto must be boolean")
    for _, key in ipairs({ "reserve_tokens", "keep_recent_tokens" }) do
      local value = opts.compaction[key]
      assert(type(value) == "number" and value > 0 and value % 1 == 0,
        "compaction." .. key .. " must be a positive integer")
    end
    for key in pairs(opts.compaction) do
      assert(key == "auto" or key == "reserve_tokens"
          or key == "keep_recent_tokens",
        "unsupported compaction setting: " .. tostring(key))
    end
  end
  for id, provider in pairs(opts.providers) do
    assert(model_config.safe_provider_id(id) and type(provider) == "table",
      "providers must use safe text keys without path separators")
    for name in pairs(provider) do
      assert(provider_fields[name],
        "unsupported provider setting: " .. tostring(name))
    end
    assert(type(provider.api) == "string" and provider.api ~= "", "provider " .. id .. " requires api")
    assert(type(provider.models) == "table", "provider " .. id .. " requires models")
    assert(provider.service == nil or type(provider.service) == "function",
      "provider " .. id .. " service must be a function")
    assert(provider.service_opts == nil
        or type(provider.service_opts) == "table" and not util.is_list(provider.service_opts),
      "provider " .. id .. " service_opts must be a table")
    assert(type(provider.catalog) == "table"
        and (next(provider.catalog) == nil
          or not util.is_list(provider.catalog)),
      "provider " .. id .. " catalog must be an object")
    for name in pairs(provider.catalog) do
      assert(catalog_fields[name],
        "unsupported provider catalog setting: " .. tostring(name))
    end
    local ttl_ms = provider.catalog.ttl_ms
    assert(ttl_ms == nil or type(ttl_ms) == "number"
        and ttl_ms > 0 and ttl_ms % 1 == 0 and ttl_ms < math.huge,
      "provider " .. id .. " catalog.ttl_ms must be a positive integer")
    assert(provider.catalog.discover == nil
        or type(provider.catalog.discover) == "function",
      "provider " .. id .. " catalog.discover must be a function")
    assert(provider.catalog.source_options == nil
        or type(provider.catalog.source_options) == "function",
      "provider " .. id .. " catalog.source_options must be a function")
    assert(not (provider.catalog.discover
          and next(provider.service_opts or {}) ~= nil)
        or type(provider.catalog.source_options) == "function",
      "provider " .. id
        .. " discovery with service_opts requires catalog.source_options")
    local source_id = provider.catalog.source_id
    local source_revision = provider.catalog.source_revision
    assert(source_id == nil or type(source_id) == "string" and source_id ~= ""
        and #source_id <= 256 and util.is_valid_utf8(source_id)
        and not source_id:find("[%z\1-\31\127]"),
      "provider " .. id .. " catalog.source_id must be safe text")
    assert(source_revision == nil or type(source_revision) == "number"
        and source_revision >= 1 and source_revision % 1 == 0
        and source_revision < math.huge,
      "provider " .. id
        .. " catalog.source_revision must be a positive integer")
    assert((source_id == nil) == (source_revision == nil),
      "provider " .. id
        .. " catalog source_id and source_revision must be supplied together")
    assert(provider.catalog.discover == nil or source_id ~= nil,
      "provider " .. id
        .. " discovery requires catalog source_id and source_revision")
    assert(provider.catalog.account_scoped == nil
        or type(provider.catalog.account_scoped) == "boolean",
      "provider " .. id .. " catalog.account_scoped must be boolean")
    assert(provider.catalog.account_scoped ~= true or provider.auth ~= nil,
      "provider " .. id .. " account-scoped catalog requires auth")
    assert(provider.catalog.transform_model == nil
        or type(provider.catalog.transform_model) == "function",
      "provider " .. id .. " catalog.transform_model must be a function")
    if provider.catalog.seed ~= nil then
      local seed, seed_err = model_config.normalize_discoveries(
        id, provider.catalog.seed)
      assert(seed, seed_err and seed_err.message
        or "provider catalog seed is invalid")
    end
    local uses_built_in_api = built_in_apis[provider.api] == true
    for _, model in pairs(provider.models) do
      if type(model) == "table" and built_in_apis[model.api] then
        uses_built_in_api = true
        break
      end
    end
    if uses_built_in_api then
      assert(type(provider.base_url) == "string" and provider.base_url ~= "", "provider " .. id .. " requires base_url")
    end
    if provider.auth ~= nil then
      assert(type(provider.auth) == "string" and provider.auth ~= "", "provider auth must be a method name")
    end
    assert(provider.auth_optional == nil
        or type(provider.auth_optional) == "boolean",
      "provider auth_optional must be boolean")
    assert(provider.auth_optional ~= true or provider.auth ~= nil,
      "provider auth_optional requires auth")
    if provider.api_key ~= nil then
      assert(type(provider.api_key) == "string" or type(provider.api_key) == "function", "api_key must be a string or function")
    end
    if provider.request_opts ~= nil then
      assert(type(provider.request_opts) == "table" or type(provider.request_opts) == "function", "request_opts must be a table or function")
    end
    if provider_uses_api(provider, "openai-codex-responses")
        and provider.diagnostics ~= nil
        and provider.diagnostics ~= false then
      assert(type(provider.diagnostics) == "table", "provider diagnostics must be false or a table")
      assert(type(provider.diagnostics.path) == "string" and provider.diagnostics.path ~= "",
        "provider diagnostics.path is required")
    end
    for model_id, model in pairs(provider.models) do
      assert(model_config.safe_id(model_id)
          and (model == false or type(model) == "table"),
        "models must contain keyed tables or false")
      if model ~= false then
        local validated, model_err = model_config.validate(id, model_id, model)
        assert(validated, model_err and model_err.message
          or "model configuration is invalid")
      end
    end
  end
  assert(type(opts._apis) == "table", "_apis must be a table")
  for name, factory in pairs(opts._apis) do
    assert(type(name) == "string" and type(factory) == "function",
      "_apis must contain functions")
  end
  assert(type(opts.auth) == "table", "auth must be a table")
  assert(type(opts.auth.path) == "string" and opts.auth.path ~= "", "auth.path is required")
  assert(type(opts.auth.methods) == "table", "auth.methods must be a table")
  for id, method in pairs(opts.auth.methods) do
    assert(type(id) == "string" and type(method) == "table", "auth methods must be keyed tables")
    assert(type(method.name) == "string" and method.name ~= "", "auth method name is required")
    assert(method.type == nil or method.type == "api_key" or method.type == "oauth",
      "auth method type must be api_key or oauth")
    assert(type(method.login) == "function" and type(method.request_opts) == "function",
      "auth methods require login and request_opts")
    assert(method.public_metadata == nil or type(method.public_metadata) == "function",
      "auth method public_metadata must be a function")
    assert(method.cache_identity == nil or type(method.cache_identity) == "function",
      "auth method cache_identity must be a function")
    assert(method._with_transport == nil
        or type(method._with_transport) == "function",
      "auth method _with_transport must be a function")
    if method.type == "api_key" then
      assert(method.refresh == nil or type(method.refresh) == "function",
        "API key auth method refresh must be a function")
    else
      assert(type(method.refresh) == "function", "OAuth auth methods require refresh")
    end
  end
  for id, provider in pairs(opts.providers) do
    if provider.auth ~= nil then
      assert(opts.auth.methods[provider.auth] ~= nil,
        "provider " .. id .. " uses unknown auth method " .. provider.auth)
    end
  end
  assert(type(opts.persistence) == "table", "persistence must be a table")
  assert(type(opts.persistence.enabled) == "boolean", "persistence.enabled must be boolean")
  assert(type(opts.persistence.workspace_settings) == "boolean", "persistence.workspace_settings must be boolean")
  assert(type(opts.persistence.directory) == "string" and opts.persistence.directory ~= "", "persistence.directory is required")
  assert(type(opts.recording) == "table" and not util.is_list(opts.recording),
    "recording must be a table")
  for key in pairs(opts.recording) do
    assert(key == "enabled" or key == "format" or key == "directory",
      "unsupported recording setting: " .. tostring(key))
  end
  assert(type(opts.recording.enabled) == "boolean",
    "recording.enabled must be boolean")
  assert(opts.recording.format == "auto" or opts.recording.format == "yaml"
      or opts.recording.format == "json",
    "recording.format must be auto, yaml, or json")
  assert(type(opts.recording.directory) == "string"
      and opts.recording.directory ~= "",
    "recording.directory is required")
  local function string_list(value, name)
    assert(util.is_list(value), name .. " must be a list")
    for _, item in ipairs(value) do
      assert(type(item) == "string" and item ~= "", name .. " must contain non-empty strings")
    end
  end
  assert(opts.agent_instructions == false
      or type(opts.agent_instructions) == "table",
    "agent_instructions must be a table or false")
  if opts.agent_instructions then
    string_list(opts.agent_instructions.global_files,
      "agent_instructions.global_files")
    string_list(opts.agent_instructions.project_filenames,
      "agent_instructions.project_filenames")
  end
  assert(opts.skills == false or type(opts.skills) == "table", "skills must be a table or false")
  if opts.skills then
    string_list(opts.skills.global_dirs, "skills.global_dirs")
    string_list(opts.skills.project_dirs, "skills.project_dirs")
  end
  if opts.ui.renderer ~= nil then
    require("neoagent.ui.renderer").assert(opts.ui.renderer, "ui.renderer")
  else
    assert(renderer_styles[opts.ui.style],
      "ui.style must be pi or codex")
  end
  local positions = { auto = true, left = true, right = true, top = true, bottom = true, center = true }
  assert(positions[opts.ui.position], "invalid ui.position")
  validate_dimension(opts.ui.width, "ui.width")
  validate_dimension(opts.ui.height, "ui.height")
  assert(type(opts.ui.margin) == "number" and opts.ui.margin >= 0 and opts.ui.margin % 1 == 0, "ui.margin must be a non-negative integer")
  assert(type(opts.ui.input_height) == "number" and opts.ui.input_height >= 1 and opts.ui.input_height % 1 == 0, "ui.input_height must be a positive integer")
  assert(type(opts.ui.scroll_on_submit) == "boolean", "ui.scroll_on_submit must be boolean")
  assert(type(opts.ui.scroll_on_transcript_leave) == "boolean",
    "ui.scroll_on_transcript_leave must be boolean")
  assert(type(opts.ui.scroll_on_reopen) == "boolean", "ui.scroll_on_reopen must be boolean")
  assert(type(opts.ui.wrap_cards) == "boolean", "ui.wrap_cards must be boolean")
  assert(type(opts.ui.show_thinking) == "boolean", "ui.show_thinking must be boolean")
  assert(opts.ui.images == false
      or type(opts.ui.images) == "table" and not util.is_list(opts.ui.images),
    "ui.images must be false or a table")
  if opts.ui.images then
    local images = opts.ui.images
    for key in pairs(images) do
      assert(key == "backend" or key == "display",
        "unsupported ui.images setting: " .. tostring(key))
    end
    assert(images.backend == "kitty",
      "ui.images.backend must be kitty")
    assert(images.display == "always" or images.display == "expanded",
      "ui.images.display must be always or expanded")
  end
  assert(type(opts.ui.provider_shell) == "table"
      and not util.is_list(opts.ui.provider_shell),
    "ui.provider_shell must be a table")
  assert(({ left = true, right = true, top = true, bottom = true,
    center = true })[opts.ui.provider_shell.position],
    "ui.provider_shell.position must be left, right, top, bottom, or center")
  validate_dimension(opts.ui.provider_shell.width, "ui.provider_shell.width")
  validate_dimension(opts.ui.provider_shell.height, "ui.provider_shell.height")
  assert(type(opts.ui.completion) == "boolean",
    "ui.completion must be boolean")
  for action, mapping in pairs(opts.ui.mappings) do
    assert(type(action) == "string", "UI mapping names must be strings")
    if type(mapping) == "table" then
      string_list(mapping, "ui.mappings." .. action)
      assert(#mapping > 0,
        "ui.mappings." .. action .. " must not be empty")
    else
      assert(mapping == false
          or type(mapping) == "string" and mapping ~= "",
        "UI mappings must be non-empty strings, non-empty lists, or false")
    end
  end
  agent_loop.validate_toolset(opts.tools or {}, opts.execute_tool)
  if opts.system_prompt ~= nil then assert(type(opts.system_prompt) == "string" or type(opts.system_prompt) == "function", "system_prompt must be a string or function") end
  if opts._view ~= nil then
    assert(type(opts._view) == "function", "_view must be a function")
  end
end

function M.resolve(opts)
  opts = opts or {}
  assert(type(opts) == "table"
      and (next(opts) == nil or not util.is_list(opts)),
    "configuration must be an object")
  for key in pairs(opts) do
    assert(input_fields[key], "unsupported setting: " .. tostring(key))
  end
  local configured = util.deep_merge(defaults, opts)
  configured.providers = require("neoagent.registry").compose(opts.providers or {}, configured.default_registry)
  configured._tools_supplied = opts.tools ~= nil
  validate(configured)
  return util.copy(configured)
end

function M.setup(opts)
  current = M.resolve(opts)
  return util.copy(current)
end

function M.get()
  if not current then M.setup({}) end
  return util.copy(current)
end

function M._reset()
  current = nil
end

function M._set(value)
  validate(value)
  current = util.copy(value)
end

return M
