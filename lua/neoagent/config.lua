local util = require("neoagent.util")
local api_key = require("neoagent.auth.api_key")
local alibaba_dashboard_auth = require("neoagent.auth.alibaba_dashboard")
local alibaba_token_plan_auth = require("neoagent.auth.alibaba_token_plan")
local agent_loop = require("neoagent.agent_loop")
local model_config = require("neoagent.model_config")
local provider_auth = require("neoagent.provider_auth")
local MAX_SHELL_TIMEOUT_SECONDS = require("neoagent.subprocess.validate").MAX_TIMEOUT_MS / 1000

---@class Neoagent.ConfiguredPromptContext
---@field session Neoagent.Session
---@field workspace Neoagent.Workspace
---@field prompt string
---@field model? Neoagent.Model
---@field tools Neoagent.Tool<Neoagent.AgentToolEnvironment>[]
---@field agent_instructions Neoagent.InstructionFile[]
---@field skills Neoagent.Skill[]

---@alias Neoagent.UIMapping string|string[]|false

---@class Neoagent.PersistenceConfig
---@field enabled boolean
---@field workspace_settings boolean
---@field directory string

---@class Neoagent.PersistenceConfigInput
---@field enabled? boolean
---@field workspace_settings? boolean
---@field directory? string

---@class Neoagent.RecordingConfig: Neoagent.RecordingConfigInput
---@field enabled boolean
---@field format 'auto'|'yaml'|'json'
---@field retention 'rolling'|'all'
---@field directory string

---@class Neoagent.RecordingConfigInput
---@field enabled? boolean
---@field format? 'auto'|'yaml'|'json'
---@field retention? 'rolling'|'all'
---@field directory? string

---@class Neoagent.RetryConfig
---@field enabled boolean
---@field max_retries integer
---@field base_delay_ms integer

---@class Neoagent.RetryConfigInput
---@field enabled? boolean
---@field max_retries? integer
---@field base_delay_ms? integer

---@alias Neoagent.LocalCompactionStrategy "summary"|"prefix"

---@class Neoagent.CompactionConfig: Neoagent.CompactionOptions
---@field strategy Neoagent.LocalCompactionStrategy
---@field auto boolean
---@field reserve_tokens integer
---@field keep_recent_tokens integer

---@class Neoagent.CompactionConfigInput
---@field strategy? Neoagent.LocalCompactionStrategy
---@field auto? boolean
---@field reserve_tokens? integer
---@field keep_recent_tokens? integer

---@class Neoagent.ProviderShellUIConfig
---@field position 'left'|'right'|'top'|'bottom'|'center'
---@field width? number
---@field height? number

---@class Neoagent.ProviderShellUIConfigInput
---@field position? 'left'|'right'|'top'|'bottom'|'center'
---@field width? number
---@field height? number

---@class Neoagent.UIImageConfig
---@field backend 'kitty'
---@field display 'always'|'expanded'

---@class Neoagent.UIImageConfigInput
---@field backend? 'kitty'
---@field display? 'always'|'expanded'

---@class Neoagent.UIConfig: Neoagent.UIConfigInput
---@field style? string
---@field renderer? Neoagent.Renderer<unknown>
---@field position Neoagent.UiPosition
---@field width? number
---@field height? number
---@field margin integer
---@field input_height integer
---@field scroll_on_submit boolean
---@field scroll_on_transcript_leave boolean
---@field scroll_on_reopen boolean
---@field wrap_cards boolean
---@field show_thinking boolean
---@field images Neoagent.UIImageConfig|false
---@field provider_shell Neoagent.ProviderShellUIConfig
---@field completion boolean
---@field border Applet.WindowBorder
---@field mappings table<string, Neoagent.UIMapping>

---@class Neoagent.UIConfigInput
---@field style? string
---@field renderer? Neoagent.Renderer<unknown>
---@field position? Neoagent.UiPosition
---@field width? number
---@field height? number
---@field margin? integer
---@field input_height? integer
---@field scroll_on_submit? boolean
---@field scroll_on_transcript_leave? boolean
---@field scroll_on_reopen? boolean
---@field wrap_cards? boolean
---@field show_thinking? boolean
---@field images? Neoagent.UIImageConfigInput|false
---@field provider_shell? Neoagent.ProviderShellUIConfigInput
---@field completion? boolean
---@field border? Applet.WindowBorder
---@field mappings? table<string, Neoagent.UIMapping>

---@alias Neoagent.DefaultProfile string|(fun(selection: Neoagent.ModelSelection?): string?)

---@class Neoagent.AgentSettings<C = unknown>
---@field name? string
---@field shell_timeout number|false
---@field sandbox Neoagent.SandboxSettings<C>
---@field workspace_trust {path: string}|false
---@field default_thinking_level Neoagent.ThinkingLevel
---@field default_model? Neoagent.ModelSelection
---@field persistence Neoagent.PersistenceConfig
---@field agent_instructions {global_files: string[], project_filenames: string[]}|false
---@field skills {global_dirs: string[], project_dirs: string[]}|false
---@field retry Neoagent.RetryConfig
---@field compaction Neoagent.CompactionConfig|false
---@field ui Neoagent.UIConfig
---@field tools? Neoagent.Tool<C>[]
---@field web_search? Neoagent.WebSearchOptions|false
---@field decorate_tool? fun(execute: Neoagent.ToolExecutor<C>): Neoagent.ToolExecutor<C>
---@field system_prompt? string|fun(context: Neoagent.ConfiguredPromptContext): string
---@field _view? fun(opts: Neoagent.ViewOptions): Neoagent.View

---@class Neoagent.Config<C = unknown>: Neoagent.AgentSettings<C>, Neoagent.ModelResolutionConfig, Neoagent.ProviderRuntimeConfig
---@field default_registry boolean
---@field default_profile Neoagent.DefaultProfile
---@field profile? string
---@field providers table<string, Neoagent.ProviderDefinition>
---@field auth Neoagent.AuthConfig
---@field _apis table<string, Neoagent.ApiFactory>
---@field recording Neoagent.RecordingConfig

---@class Neoagent.ConfigInput<C = unknown>
---@field name? string
---@field default_registry? boolean
---@field default_profile? Neoagent.DefaultProfile
---@field profile? string
---@field shell_timeout? number|false
---@field sandbox? {enabled?: boolean, profile?: Neoagent.SandboxProfileSetting<Neoagent.SandboxContext<C>>, parent_tools?: Neoagent.Tool<C>[]}
---@field workspace_trust? {path?: string}|false
---@field default_thinking_level? Neoagent.ThinkingLevel
---@field default_model? Neoagent.ModelSelection
---@field providers? table<string, Neoagent.ProviderOptions|false>
---@field auth? {path?: string, methods?: table<string, Neoagent.AuthMethodInput<Neoagent.Credential>|Neoagent.AuthMethod<Neoagent.Credential>>}
---@field _apis? table<string, Neoagent.ApiFactory>
---@field persistence? Neoagent.PersistenceConfigInput
---@field recording? Neoagent.RecordingConfigInput
---@field agent_instructions? {global_files?: string[], project_filenames?: string[]}|false
---@field skills? {global_dirs?: string[], project_dirs?: string[]}|false
---@field retry? Neoagent.RetryConfigInput
---@field compaction? Neoagent.CompactionConfigInput|false
---@field ui? Neoagent.UIConfigInput
---@field tools? Neoagent.Tool<C>[]
---@field web_search? Neoagent.WebSearchOptions|false
---@field decorate_tool? fun(execute: Neoagent.ToolExecutor<C>): Neoagent.ToolExecutor<C>
---@field system_prompt? string|fun(context: Neoagent.ConfiguredPromptContext): string
---@field _view? fun(opts: Neoagent.ViewOptions): Neoagent.View

local M = {}

local renderer_styles = { codex = true, pi = true }

---@param selection? Neoagent.ModelSelection
---@return string
local function default_profile(selection)
  if
    selection
    and (selection.provider == "openai" or selection.provider == "openai-codex" or selection.provider == "deepseek")
  then
    return "codex"
  end
  return "pi"
end

local defaults = {
  default_registry = true,
  default_profile = default_profile,
  shell_timeout = false,
  web_search = false,
  sandbox = {},
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
      ["alibaba-token-plan"] = alibaba_token_plan_auth.new(),
      ["alibaba-token-plan-dashboard"] = alibaba_dashboard_auth.new(),
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
          return {
            headers = {
              Authorization = "Bearer " .. credential.key,
              ["x-api-key"] = credential.key,
            },
          }
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
    retention = "rolling",
    directory = vim.fn.stdpath("state") .. "/neoagent",
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
    strategy = "prefix",
    auto = true,
    reserve_tokens = 16384,
    keep_recent_tokens = 20000,
  },
  ui = {
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
  profile = true,
  default_profile = true,
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
  web_search = true,
  system_prompt = true,
  decorate_tool = true,
  _apis = true,
  _view = true,
}

---@class Neoagent.ConfigSnapshot<C>
---@field config Neoagent.Config<C>
---@field overrides Neoagent.ConfigInput<C>

---@type Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>?
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
  auth_scopes = true,
  base_url = true,
  catalog = true,
  diagnostics = true,
  file_uploads = true,
  prompt_caching = true,
  custom_tools = true,
  models = true,
  request_opts = true,
  service = true,
  service_opts = true,
}

local catalog_fields = {
  account_scoped = true,
  additions = true,
  discover = true,
  seed = true,
  source_id = true,
  source_options = true,
  source_revision = true,
  ttl_ms = true,
  transform_model = true,
}

---@param provider Neoagent.ProviderDefinition
---@return table<string, Neoagent.ModelConfigInput|false>[]
local function model_configuration_maps(provider)
  return {
    provider.models or {},
    provider.catalog and provider.catalog.additions or {},
  }
end

---@param provider Neoagent.ProviderDefinition
---@param name string
---@return boolean
local function provider_uses_api(provider, name)
  if provider.api == name then
    return true
  end
  for _, models in ipairs(model_configuration_maps(provider)) do
    for _, model in pairs(models) do
      if type(model) == "table" and model.api == name then
        return true
      end
    end
  end
  return false
end

---@param value? number
---@param name string
local function validate_dimension(value, name)
  if value == nil then
    return
  end
  if type(value) ~= "number" or value <= 0 or (value > 1 and value % 1 ~= 0) then
    error(name .. " must be a fraction in (0, 1] or an integer greater than one")
  end
end

---@param value string[]
---@param name string
local function string_list(value, name)
  assert(util.is_list(value), name .. " must be a list")
  for _, item in ipairs(value) do
    assert(type(item) == "string" and item ~= "", name .. " must contain non-empty strings")
  end
end

---@param ui Neoagent.UIConfig
local function validate_ui(ui)
  if ui.renderer ~= nil then
    require("neoagent.ui.renderer").assert(ui.renderer, "ui.renderer")
  elseif ui.style ~= nil then
    assert(renderer_styles[ui.style], "ui.style must be pi or codex")
  end
  local positions = { auto = true, left = true, right = true, top = true, bottom = true, center = true }
  assert(positions[ui.position], "invalid ui.position")
  validate_dimension(ui.width, "ui.width")
  validate_dimension(ui.height, "ui.height")
  assert(
    type(ui.margin) == "number" and ui.margin >= 0 and ui.margin % 1 == 0,
    "ui.margin must be a non-negative integer"
  )
  assert(
    type(ui.input_height) == "number" and ui.input_height >= 1 and ui.input_height % 1 == 0,
    "ui.input_height must be a positive integer"
  )
  assert(type(ui.scroll_on_submit) == "boolean", "ui.scroll_on_submit must be boolean")
  assert(type(ui.scroll_on_transcript_leave) == "boolean", "ui.scroll_on_transcript_leave must be boolean")
  assert(type(ui.scroll_on_reopen) == "boolean", "ui.scroll_on_reopen must be boolean")
  assert(type(ui.wrap_cards) == "boolean", "ui.wrap_cards must be boolean")
  assert(type(ui.show_thinking) == "boolean", "ui.show_thinking must be boolean")
  assert(
    ui.images == false or type(ui.images) == "table" and not util.is_list(ui.images),
    "ui.images must be false or a table"
  )
  if ui.images then
    local images = ui.images
    for key in pairs(images) do
      assert(key == "backend" or key == "display", "unsupported ui.images setting: " .. tostring(key))
    end
    assert(images.backend == "kitty", "ui.images.backend must be kitty")
    assert(images.display == "always" or images.display == "expanded", "ui.images.display must be always or expanded")
  end
  assert(
    type(ui.provider_shell) == "table" and not util.is_list(ui.provider_shell),
    "ui.provider_shell must be a table"
  )
  assert(
    ({ left = true, right = true, top = true, bottom = true, center = true })[ui.provider_shell.position],
    "ui.provider_shell.position must be left, right, top, bottom, or center"
  )
  validate_dimension(ui.provider_shell.width, "ui.provider_shell.width")
  validate_dimension(ui.provider_shell.height, "ui.provider_shell.height")
  assert(type(ui.completion) == "boolean", "ui.completion must be boolean")
  for action, mapping in pairs(ui.mappings) do
    assert(type(action) == "string", "UI mapping names must be strings")
    if type(mapping) == "table" then
      string_list(mapping, "ui.mappings." .. action)
      assert(#mapping > 0, "ui.mappings." .. action .. " must not be empty")
    else
      assert(
        mapping == false or type(mapping) == "string" and mapping ~= "",
        "UI mappings must be non-empty strings, non-empty lists, or false"
      )
    end
  end
end

---@generic C
---@param opts Neoagent.Config<C>
local function validate(opts)
  assert(opts.name == nil or (type(opts.name) == "string" and opts.name ~= ""), "name must be a non-empty string")
  assert(type(opts.default_registry) == "boolean", "default_registry must be boolean")
  assert(
    type(opts.default_profile) == "function" or type(opts.default_profile) == "string" and opts.default_profile ~= "",
    "default_profile must be a Profile ID or selector"
  )
  assert(
    opts.profile == nil or type(opts.profile) == "string" and opts.profile ~= "",
    "profile must identify a Profile"
  )
  assert(
    opts.shell_timeout == false
      or type(opts.shell_timeout) == "number"
        and opts.shell_timeout > 0
        and opts.shell_timeout <= MAX_SHELL_TIMEOUT_SECONDS,
    "shell_timeout must be false or a positive number no greater than " .. MAX_SHELL_TIMEOUT_SECONDS .. " seconds"
  )
  require("neoagent.sandbox.settings").validate(opts.sandbox)
  assert(
    opts.workspace_trust == false or (type(opts.workspace_trust) == "table" and not util.is_list(opts.workspace_trust)),
    "workspace_trust must be false or a table"
  )
  if opts.workspace_trust then
    for key in pairs(opts.workspace_trust) do
      assert(key == "path", "unsupported workspace_trust setting: " .. tostring(key))
    end
    assert(
      type(opts.workspace_trust.path) == "string" and opts.workspace_trust.path ~= "",
      "workspace_trust.path is required"
    )
  end
  assert(
    require("neoagent.thinking").is_level(opts.default_thinking_level),
    "default_thinking_level must be off, minimal, low, medium, high, xhigh, max, or ultra"
  )
  if opts.default_model ~= nil then
    assert(type(opts.default_model) == "table", "default_model must be a table")
    assert(
      model_config.safe_provider_id(opts.default_model.provider),
      "default_model.provider must be safe text without path separators"
    )
    assert(model_config.safe_id(opts.default_model.model), "default_model.model must be safe non-empty text")
  end
  assert(type(opts.providers) == "table", "providers must be a table")
  assert(type(opts.retry) == "table", "retry must be a table")
  assert(type(opts.retry.enabled) == "boolean", "retry.enabled must be boolean")
  assert(
    type(opts.retry.max_retries) == "number" and opts.retry.max_retries >= 0 and opts.retry.max_retries % 1 == 0,
    "retry.max_retries must be a non-negative integer"
  )
  assert(
    type(opts.retry.base_delay_ms) == "number" and opts.retry.base_delay_ms > 0 and opts.retry.base_delay_ms % 1 == 0,
    "retry.base_delay_ms must be a positive integer"
  )
  if opts.compaction ~= false then
    assert(type(opts.compaction) == "table", "compaction must be false or a table")
    assert(
      opts.compaction.strategy == "summary" or opts.compaction.strategy == "prefix",
      'compaction.strategy must be "summary" or "prefix"'
    )
    assert(type(opts.compaction.auto) == "boolean", "compaction.auto must be boolean")
    for _, key in ipairs({ "reserve_tokens", "keep_recent_tokens" }) do
      local value = opts.compaction[key]
      assert(
        type(value) == "number" and value > 0 and value % 1 == 0,
        "compaction." .. key .. " must be a positive integer"
      )
    end
    for key in pairs(opts.compaction) do
      assert(
        key == "strategy" or key == "auto" or key == "reserve_tokens" or key == "keep_recent_tokens",
        "unsupported compaction setting: " .. tostring(key)
      )
    end
  end
  for id, provider in pairs(opts.providers) do
    assert(
      model_config.safe_provider_id(id) and type(provider) == "table",
      "providers must use safe text keys without path separators"
    )
    for name in pairs(provider) do
      assert(provider_fields[name], "unsupported provider setting: " .. tostring(name))
    end
    assert(type(provider.api) == "string" and provider.api ~= "", "provider " .. id .. " requires api")
    assert(type(provider.models) == "table", "provider " .. id .. " requires models")
    for _, field in ipairs({ "file_uploads", "prompt_caching" }) do
      assert(
        provider[field] == nil or type(provider[field]) == "boolean",
        "provider " .. id .. " " .. field .. " must be boolean"
      )
    end
    assert(
      provider.service == nil or type(provider.service) == "function",
      "provider " .. id .. " service must be a function"
    )
    assert(
      provider.service_opts == nil or type(provider.service_opts) == "table" and not util.is_list(provider.service_opts),
      "provider " .. id .. " service_opts must be a table"
    )
    assert(
      type(provider.catalog) == "table" and (next(provider.catalog) == nil or not util.is_list(provider.catalog)),
      "provider " .. id .. " catalog must be an object"
    )
    for name in pairs(provider.catalog) do
      assert(catalog_fields[name], "unsupported provider catalog setting: " .. tostring(name))
    end
    local ttl_ms = provider.catalog.ttl_ms
    assert(
      ttl_ms == nil or type(ttl_ms) == "number" and ttl_ms > 0 and ttl_ms % 1 == 0 and ttl_ms < math.huge,
      "provider " .. id .. " catalog.ttl_ms must be a positive integer"
    )
    assert(
      provider.catalog.discover == nil or type(provider.catalog.discover) == "function",
      "provider " .. id .. " catalog.discover must be a function"
    )
    assert(
      provider.catalog.source_options == nil or type(provider.catalog.source_options) == "function",
      "provider " .. id .. " catalog.source_options must be a function"
    )
    assert(
      not (provider.catalog.discover and next(provider.service_opts or {}) ~= nil)
        or type(provider.catalog.source_options) == "function",
      "provider " .. id .. " discovery with service_opts requires catalog.source_options"
    )
    local source_id = provider.catalog.source_id
    local source_revision = provider.catalog.source_revision
    assert(
      source_id == nil
        or type(source_id) == "string"
          and source_id ~= ""
          and #source_id <= 256
          and util.is_valid_utf8(source_id)
          and not source_id:find("[%z\1-\31\127]"),
      "provider " .. id .. " catalog.source_id must be safe text"
    )
    assert(
      source_revision == nil
        or type(source_revision) == "number"
          and source_revision >= 1
          and source_revision % 1 == 0
          and source_revision < math.huge,
      "provider " .. id .. " catalog.source_revision must be a positive integer"
    )
    assert(
      (source_id == nil) == (source_revision == nil),
      "provider " .. id .. " catalog source_id and source_revision must be supplied together"
    )
    assert(
      provider.catalog.discover == nil or source_id ~= nil,
      "provider " .. id .. " discovery requires catalog source_id and source_revision"
    )
    assert(
      provider.catalog.account_scoped == nil or type(provider.catalog.account_scoped) == "boolean",
      "provider " .. id .. " catalog.account_scoped must be boolean"
    )
    assert(
      provider.catalog.account_scoped ~= true or provider.auth ~= nil,
      "provider " .. id .. " account-scoped catalog requires auth"
    )
    assert(
      provider.catalog.transform_model == nil or type(provider.catalog.transform_model) == "function",
      "provider " .. id .. " catalog.transform_model must be a function"
    )
    if provider.catalog.seed ~= nil then
      local seed, seed_err = model_config.normalize_discoveries(id, provider.catalog.seed)
      assert(seed, seed_err and seed_err.message or "provider catalog seed is invalid")
    end
    assert(
      provider.catalog.additions == nil
        or type(provider.catalog.additions) == "table"
          and (next(provider.catalog.additions) == nil or not util.is_list(provider.catalog.additions)),
      "provider " .. id .. " catalog.additions must be a keyed table"
    )
    for model_id, model in pairs(provider.catalog.additions or {}) do
      assert(
        model_config.safe_id(model_id)
          and (model == false or type(model) == "table" and (next(model) == nil or not util.is_list(model))),
        "provider " .. id .. " catalog.additions must contain keyed tables or false"
      )
      if model ~= false then
        local validated, model_err = model_config.validate(id, model_id, model)
        assert(validated, model_err and model_err.message or "catalog model addition is invalid")
      end
    end
    local uses_built_in_api = built_in_apis[provider.api] == true
    for _, models in ipairs(model_configuration_maps(provider)) do
      for _, model in pairs(models) do
        if type(model) == "table" and built_in_apis[model.api] then
          uses_built_in_api = true
          break
        end
      end
      if uses_built_in_api then
        break
      end
    end
    if uses_built_in_api then
      assert(type(provider.base_url) == "string" and provider.base_url ~= "", "provider " .. id .. " requires base_url")
    end
    if provider.auth ~= nil then
      assert(type(provider.auth) == "string" and provider.auth ~= "", "provider auth must be a method name")
    end
    assert(
      provider.auth_scopes == nil or type(provider.auth_scopes) == "table" and not util.is_list(provider.auth_scopes),
      "provider auth_scopes must be an object"
    )
    for scope, method in pairs(provider.auth_scopes or {}) do
      assert(
        type(scope) == "string" and scope ~= "" and #scope <= 128 and scope:match("^[%w_.-]+$") and scope ~= "inference",
        "provider auth scope must be safe text other than inference"
      )
      assert(type(method) == "string" and method ~= "", "provider auth scope must name an authentication method")
    end
    assert(
      provider.auth_optional == nil or type(provider.auth_optional) == "boolean",
      "provider auth_optional must be boolean"
    )
    assert(provider.auth_optional ~= true or provider.auth ~= nil, "provider auth_optional requires auth")
    if provider.api_key ~= nil then
      assert(
        type(provider.api_key) == "string" or type(provider.api_key) == "function",
        "api_key must be a string or function"
      )
    end
    if provider.request_opts ~= nil then
      assert(
        type(provider.request_opts) == "table" or type(provider.request_opts) == "function",
        "request_opts must be a table or function"
      )
    end
    assert(
      provider.custom_tools == nil or type(provider.custom_tools) == "boolean",
      "provider custom_tools must be boolean"
    )
    if
      provider_uses_api(provider, "openai-codex-responses")
      and provider.diagnostics ~= nil
      and provider.diagnostics ~= false
    then
      assert(type(provider.diagnostics) == "table", "provider diagnostics must be false or a table")
      assert(
        type(provider.diagnostics.path) == "string" and provider.diagnostics.path ~= "",
        "provider diagnostics.path is required"
      )
    end
    for model_id, model in pairs(provider.models) do
      assert(
        model_config.safe_id(model_id) and (model == false or type(model) == "table"),
        "models must contain keyed tables or false"
      )
      if model ~= false then
        local validated, model_err = model_config.validate(id, model_id, model)
        assert(validated, model_err and model_err.message or "model configuration is invalid")
      end
    end
  end
  assert(type(opts._apis) == "table", "_apis must be a table")
  for name, factory in pairs(opts._apis) do
    assert(type(name) == "string" and type(factory) == "function", "_apis must contain functions")
  end
  assert(type(opts.auth) == "table", "auth must be a table")
  assert(type(opts.auth.path) == "string" and opts.auth.path ~= "", "auth.path is required")
  assert(type(opts.auth.methods) == "table", "auth.methods must be a table")
  for id, method in pairs(opts.auth.methods) do
    assert(type(id) == "string" and type(method) == "table", "auth methods must be keyed tables")
    assert(type(method.name) == "string" and method.name ~= "", "auth method name is required")
    assert(
      method.type == nil or method.type == "api_key" or method.type == "oauth",
      "auth method type must be api_key or oauth"
    )
    assert(
      type(method.login) == "function" and type(method.request_opts) == "function",
      "auth methods require login and request_opts"
    )
    assert(
      method.public_metadata == nil or type(method.public_metadata) == "function",
      "auth method public_metadata must be a function"
    )
    assert(
      method.cache_identity == nil or type(method.cache_identity) == "function",
      "auth method cache_identity must be a function"
    )
    assert(
      method.validate_credential == nil or type(method.validate_credential) == "function",
      "auth method validate_credential must be a function"
    )
    assert(
      method.login_with_ambient == nil or type(method.login_with_ambient) == "boolean",
      "auth method login_with_ambient must be a boolean"
    )
    for _, field in ipairs({ "login_label", "logout_label" }) do
      local value = method[field]
      assert(
        value == nil or model_config.safe_id(value) and #value <= 128,
        "auth method " .. field .. " must be safe text of at most 128 bytes"
      )
    end
    assert(
      method._with_transport == nil or type(method._with_transport) == "function",
      "auth method _with_transport must be a function"
    )
    if method.type == "api_key" then
      assert(
        method.refresh == nil or type(method.refresh) == "function",
        "API key auth method refresh must be a function"
      )
    else
      assert(type(method.refresh) == "function", "OAuth auth methods require refresh")
    end
  end
  for id, provider in pairs(opts.providers) do
    for _, entry in ipairs(provider_auth.entries(provider)) do
      if entry.method ~= nil then
        assert(
          opts.auth.methods[entry.method] ~= nil,
          "provider " .. id .. " uses unknown auth method " .. entry.method
        )
      end
    end
  end
  assert(type(opts.persistence) == "table", "persistence must be a table")
  assert(type(opts.persistence.enabled) == "boolean", "persistence.enabled must be boolean")
  assert(type(opts.persistence.workspace_settings) == "boolean", "persistence.workspace_settings must be boolean")
  assert(
    type(opts.persistence.directory) == "string" and opts.persistence.directory ~= "",
    "persistence.directory is required"
  )
  assert(type(opts.recording) == "table" and not util.is_list(opts.recording), "recording must be a table")
  for key in pairs(opts.recording) do
    assert(
      key == "enabled" or key == "format" or key == "retention" or key == "directory",
      "unsupported recording setting: " .. tostring(key)
    )
  end
  assert(type(opts.recording.enabled) == "boolean", "recording.enabled must be boolean")
  assert(
    opts.recording.format == "auto" or opts.recording.format == "yaml" or opts.recording.format == "json",
    "recording.format must be auto, yaml, or json"
  )
  assert(
    opts.recording.retention == "rolling" or opts.recording.retention == "all",
    "recording.retention must be rolling or all"
  )
  assert(
    type(opts.recording.directory) == "string" and opts.recording.directory ~= "",
    "recording.directory is required"
  )
  assert(
    opts.agent_instructions == false or type(opts.agent_instructions) == "table",
    "agent_instructions must be a table or false"
  )
  if opts.agent_instructions then
    string_list(opts.agent_instructions.global_files, "agent_instructions.global_files")
    string_list(opts.agent_instructions.project_filenames, "agent_instructions.project_filenames")
  end
  assert(opts.skills == false or type(opts.skills) == "table", "skills must be a table or false")
  if opts.skills then
    string_list(opts.skills.global_dirs, "skills.global_dirs")
    string_list(opts.skills.project_dirs, "skills.project_dirs")
  end
  validate_ui(opts.ui)
  if opts.web_search then
    require("neoagent.web_search").validate_options(opts.web_search)
  end
  agent_loop.validate_toolset(opts.tools or {})
  assert(opts.decorate_tool == nil or type(opts.decorate_tool) == "function", "decorate_tool must be a function")
  if opts.system_prompt ~= nil then
    assert(
      type(opts.system_prompt) == "string" or type(opts.system_prompt) == "function",
      "system_prompt must be a string or function"
    )
  end
  if opts._view ~= nil then
    assert(type(opts._view) == "function", "_view must be a function")
  end
end

-- These settings construct shared owners and cannot change with an Agent
-- recipe or a draft. Profile defaults and draft patches contain Agent settings.
local composition_fields = {
  providers = true,
  auth = true,
  recording = true,
  _apis = true,
  default_registry = true,
  default_profile = true,
  profile = true,
}

-- Normalize public UI input into copied settings and one borrowed dependency.
-- Accepted compositions and presentation owners retain these separately.
---@generic T: Neoagent.UIConfigInput
---@param value T
---@return T, Neoagent.Renderer<unknown>?
function M.ui_settings(value)
  local renderer = value.renderer
  local settings = util.shallow_copy(value)
  settings.renderer = nil
  return util.copy(settings), renderer
end

-- Public configuration input may still contain ui.renderer. Keep its identity
-- at this boundary; data-only accepted settings use ordinary value copies.
---@generic T: table
---@param value T
---@return T
function M.copy(value)
  local fields = util.shallow_copy(value)
  fields.ui = nil
  local copy = util.copy(fields)
  if type(value.ui) == "table" then
    local settings, renderer = M.ui_settings(value.ui)
    settings.renderer = renderer
    copy.ui = settings
  else
    copy.ui = value.ui
  end
  return copy
end

---@generic T: Neoagent.UIConfigInput
---@param base T
---@param overrides? Neoagent.UIConfigInput
---@return T
local function merge_ui(base, overrides)
  local before, renderer = M.ui_settings(base)
  local patch, replacement = M.ui_settings(overrides or {})
  local selected = util.deep_merge(before, patch)
  if replacement then
    selected.renderer = replacement
  elseif not (overrides and overrides.style) then
    selected.renderer = renderer
  end
  return selected --[[@as T]]
end

---@param base table
---@param overrides? table
---@return table
local function merge_values(base, overrides)
  local before, patch = util.shallow_copy(base), util.shallow_copy(overrides or {})
  before.ui, patch.ui = nil, nil
  local selected = util.deep_merge(before, patch)
  if base.ui or overrides and overrides.ui then
    selected.ui = merge_ui(base.ui or {}, overrides and overrides.ui)
  end
  return selected
end

---@generic C
---@param options? Neoagent.ConfigInput<C>|Neoagent.Config<C>
---@return Neoagent.ConfigInput<C>
function M.agent_options(options)
  if options == nil then
    return {}
  end
  local result = {}
  for key, value in pairs(options) do
    if not composition_fields[key] then
      result[key] = value
    end
  end
  return M.copy(result)
end

---@generic C
---@param configured Neoagent.Config<C>
---@return Neoagent.AgentSettings<C>
function M.agent_settings(configured)
  return M.copy({
    name = configured.name,
    shell_timeout = configured.shell_timeout,
    sandbox = configured.sandbox,
    workspace_trust = configured.workspace_trust,
    default_thinking_level = configured.default_thinking_level,
    default_model = configured.default_model,
    persistence = configured.persistence,
    agent_instructions = configured.agent_instructions,
    skills = configured.skills,
    retry = configured.retry,
    compaction = configured.compaction,
    ui = configured.ui,
    tools = configured.tools,
    web_search = configured.web_search,
    decorate_tool = configured.decorate_tool,
    system_prompt = configured.system_prompt,
    _view = configured._view,
  })
end

---@param options table
function M.validate_agent_options(options)
  assert(
    type(options) == "table" and (next(options) == nil or not util.is_list(options)),
    "Agent options must be an object"
  )
  for key in pairs(options) do
    assert(
      not composition_fields[key],
      key .. " belongs to top-level composition, not Profile defaults or draft options"
    )
    assert(input_fields[key], "unsupported setting: " .. tostring(key))
  end
end

---@generic C
---@param base Neoagent.ConfigInput<C>
---@param patch Neoagent.ConfigInput<C>
---@return Neoagent.ConfigInput<C>
function M.merge_agent_options(base, patch)
  M.validate_agent_options(patch)
  return merge_values(base, patch) --[[@as Neoagent.ConfigInput<C>]]
end

---@param base Neoagent.UIConfig
---@param overrides? Neoagent.UIConfigInput
---@return Neoagent.UIConfig
function M.extend_ui(base, overrides)
  local selected = merge_ui(base, overrides)
  validate_ui(selected)
  return selected
end

---@generic C
---@param base table
---@param opts? Neoagent.ConfigInput<C>
---@return Neoagent.Config<C>
local function merge(base, opts)
  opts = opts or {}
  assert(type(opts) == "table" and (next(opts) == nil or not util.is_list(opts)), "configuration must be an object")
  for key in pairs(opts) do
    assert(input_fields[key], "unsupported setting: " .. tostring(key))
  end
  local configured = merge_values(base, opts)
  return configured --[[@as Neoagent.Config<C>]]
end

---@generic C
---@param base Neoagent.Config<C>
---@param opts? Neoagent.ConfigInput<C>
---@return Neoagent.Config<C>
function M.extend(base, opts)
  local configured = merge(base, opts)
  assert(
    not opts or opts.default_registry == nil or opts.default_registry == base.default_registry,
    "default_registry cannot change after configuration resolution"
  )
  if opts and opts.providers then
    configured.providers = require("neoagent.registry").extend(base.providers, opts.providers) --[[@as table<string, Neoagent.ProviderDefinition>]]
  end
  validate(configured)
  return configured
end

---@generic C
---@param opts? Neoagent.ConfigInput<C>
---@return Neoagent.Config<C>
function M.resolve(opts)
  local configured = merge(defaults, opts)
  configured.providers = require("neoagent.registry").compose(configured.providers, configured.default_registry) --[[@as table<string, Neoagent.ProviderDefinition>]]
  validate(configured)
  return configured
end

-- Profile defaults are applied later. Retain the caller's precedence with the
-- resolved shared configuration so every construction path has the same input.
---@generic C
---@param opts? Neoagent.ConfigInput<C>
---@return Neoagent.ConfigSnapshot<C>
function M.snapshot(opts)
  if opts == nil then
    opts = {}
  end
  local overrides = M.copy(opts)
  return { config = M.resolve(overrides), overrides = overrides }
end

---@param opts? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
---@return Neoagent.Config<Neoagent.AgentToolEnvironment>
function M.setup(opts)
  current = M.snapshot(opts)
  return M.copy(current.config)
end

---@return Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
function M.get_snapshot()
  if not current then
    M.setup({})
  end
  local snapshot = assert(current)
  return { config = M.copy(snapshot.config), overrides = M.copy(snapshot.overrides) }
end

---@return Neoagent.Config<Neoagent.AgentToolEnvironment>
function M.get()
  return M.get_snapshot().config
end

function M._reset()
  current = nil
end

---@param snapshot Neoagent.ConfigSnapshot<Neoagent.AgentToolEnvironment>
function M._set(snapshot)
  validate(snapshot.config)
  current = { config = M.copy(snapshot.config), overrides = M.copy(snapshot.overrides) }
end

return M
