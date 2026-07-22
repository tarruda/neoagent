local util = require("neoagent.util")
local api_key = require("neoagent.auth.api_key")

local M = {}

local defaults = {
  default_registry = true,
  default_thinking_level = "medium",
  providers = {},
  apis = {},
  auth = {
    path = vim.fn.stdpath("state") .. "/neoagent/auth.json",
    methods = {
      openai = api_key.new({ name = "OpenAI API key" }),
      deepseek = api_key.new({ name = "DeepSeek API key" }),
      zai = api_key.new({ name = "Z.AI API key" }),
      ["openai-codex"] = require("neoagent.auth.openai_codex").new(),
    },
  },
  persistence = {
    enabled = true,
    workspace_settings = true,
    directory = vim.fn.stdpath("state") .. "/neoagent/workspaces",
  },
  agents = {
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
  compaction = {
    auto = true,
    reserve_tokens = 16384,
    keep_recent_tokens = 20000,
  },
  ui = {
    position = "auto",
    margin = 1,
    input_height = 7,
    scroll_on_submit = true,
    scroll_on_transcript_leave = true,
    scroll_on_reopen = true,
    completion = {
      sources = { "files" },
    },
    border = "rounded",
    mappings = {
      submit = "<CR>",
      complete = "<Tab>",
      interrupt = "<C-c>",
      toggle_focus = { "<C-w>w", "<C-w><C-w>" },
      close_input = "<Esc><Esc>",
      close_empty = "<C-d>",
      expand_tools = "<C-o>",
      cycle_thinking = "<S-Tab>",
      cycle_agent = "<A-n>",
      select_model = "<A-m>",
      resume_session = "<A-r>",
      history_previous = { "<Up>", "<C-k>" },
      history_next = { "<Down>", "<C-j>" },
      select_history = "<C-r>",
      dequeue_steering = "<A-Up>",
      dock_left = "<C-w>H",
      dock_bottom = "<C-w>J",
      dock_top = "<C-w>K",
      dock_right = "<C-w>L",
      dock_center = "<C-w>=",
      close = "q",
    },
  },
  view = nil,
}

local current

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
  assert(require("neoagent.thinking").is_level(opts.default_thinking_level),
    "default_thinking_level must be off, minimal, low, medium, high, xhigh, or max")
  if opts.default_model ~= nil then
    assert(type(opts.default_model) == "table", "default_model must be a table")
    assert(type(opts.default_model.provider) == "string", "default_model.provider is required")
    assert(type(opts.default_model.model) == "string", "default_model.model is required")
  end
  assert(type(opts.providers) == "table", "providers must be a table")
  if opts.compaction ~= false then
    assert(type(opts.compaction) == "table", "compaction must be false or a table")
    assert(type(opts.compaction.auto) == "boolean", "compaction.auto must be boolean")
    for _, key in ipairs({ "reserve_tokens", "keep_recent_tokens" }) do
      local value = opts.compaction[key]
      assert(type(value) == "number" and value > 0 and value % 1 == 0,
        "compaction." .. key .. " must be a positive integer")
    end
    assert(opts.compaction.run == nil or type(opts.compaction.run) == "function",
      "compaction.run must be a function")
  end
  for id, provider in pairs(opts.providers) do
    assert(type(id) == "string" and type(provider) == "table", "providers must be keyed tables")
    assert(type(provider.api) == "string" and provider.api ~= "", "provider " .. id .. " requires api")
    assert(type(provider.models) == "table", "provider " .. id .. " requires models")
    if provider.api == "openai-completions" or provider.api == "openai-responses"
        or provider.api == "openai-codex-responses" or provider.api == "anthropic-messages" then
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
    if provider.api == "openai-codex-responses" and provider.diagnostics ~= nil
        and provider.diagnostics ~= false then
      assert(type(provider.diagnostics) == "table", "provider diagnostics must be false or a table")
      assert(type(provider.diagnostics.path) == "string" and provider.diagnostics.path ~= "",
        "provider diagnostics.path is required")
    end
    for model_id, model in pairs(provider.models) do
      assert(type(model_id) == "string" and type(model) == "table", "models must be keyed tables")
      if model.context_window ~= nil then
        assert(type(model.context_window) == "number" and model.context_window > 0
          and model.context_window % 1 == 0, "model context_window must be a positive integer")
      end
      if model.thinking ~= nil and model.thinking ~= false then
        assert(type(model.thinking) == "table", "model thinking must be a table or false")
        assert(model.reasoning ~= true, "model thinking and static reasoning are mutually exclusive")
        for level, value in pairs(model.thinking) do
          assert(require("neoagent.thinking").is_level(level), "unknown thinking level: " .. tostring(level))
          assert(value == false or type(value) == "table" or type(value) == "function",
            "thinking levels must contain request_opts tables, functions, or false")
        end
      end
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
        if model.reasoning_context ~= nil then
          assert(type(model.reasoning_context) == "string" and model.reasoning_context ~= "",
            "model reasoning_context must be a non-empty string")
        end
        if provider.api == "openai-codex-responses" and model.text_verbosity ~= nil then
          assert(type(model.text_verbosity) == "string" and model.text_verbosity ~= "",
            "model text_verbosity must be a non-empty string")
        end
        if provider.api == "openai-codex-responses" and model.responses_lite ~= nil then
          assert(type(model.responses_lite) == "boolean", "model responses_lite must be boolean")
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
    assert(method.type == nil or method.type == "api_key" or method.type == "oauth",
      "auth method type must be api_key or oauth")
    assert(type(method.login) == "function" and type(method.request_opts) == "function",
      "auth methods require login and request_opts")
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
  local function string_list(value, name)
    assert(util.is_list(value), name .. " must be a list")
    for _, item in ipairs(value) do
      assert(type(item) == "string" and item ~= "", name .. " must contain non-empty strings")
    end
  end
  assert(opts.agents == false or type(opts.agents) == "table", "agents must be a table or false")
  if opts.agents then
    string_list(opts.agents.global_files, "agents.global_files")
    string_list(opts.agents.project_filenames, "agents.project_filenames")
  end
  assert(opts.skills == false or type(opts.skills) == "table", "skills must be a table or false")
  if opts.skills then
    string_list(opts.skills.global_dirs, "skills.global_dirs")
    string_list(opts.skills.project_dirs, "skills.project_dirs")
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
  assert(opts.ui.completion == false or type(opts.ui.completion) == "table",
    "ui.completion must be false or a table")
  if opts.ui.completion then
    string_list(opts.ui.completion.sources, "ui.completion.sources")
    for _, source in ipairs(opts.ui.completion.sources) do
      assert(source == "files", "unsupported ui.completion source: " .. source)
    end
  end
  for action, mapping in pairs(opts.ui.mappings) do
    assert(type(action) == "string", "UI mapping names must be strings")
    if type(mapping) == "table" then
      string_list(mapping, "ui.mappings." .. action)
    else
      assert(type(mapping) == "string" or mapping == false,
        "UI mappings must be strings, lists of strings, or false")
    end
  end
  if opts.tools ~= nil then assert(type(opts.tools) == "table", "tools must be an array") end
  if opts.system_prompt ~= nil then assert(type(opts.system_prompt) == "string" or type(opts.system_prompt) == "function", "system_prompt must be a string or function") end
  if opts.execute_tool ~= nil then assert(type(opts.execute_tool) == "function", "execute_tool must be a function") end
  if opts.interaction ~= nil then assert(type(opts.interaction) == "function", "interaction must be a function") end
  if opts.view ~= nil then assert(type(opts.view) == "function", "view must be a function") end
end

function M.resolve(opts)
  opts = opts or {}
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
