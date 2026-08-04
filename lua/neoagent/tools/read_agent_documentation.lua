local function plugin_root()
  local source = debug.getinfo(1, "S").source
  local path = source:sub(1, 1) == "@" and source:sub(2) or source
  path = vim.fn.fnamemodify(path, ":p")
  for _ = 1, 4 do path = vim.fs.dirname(path) end
  return path
end

local function init_path()
  local path = vim.env.MYVIMRC
  if type(path) == "string" and path ~= "" then
    return vim.fn.fnamemodify(path, ":p")
  end
  return vim.fn.stdpath("config") .. "/init.lua"
end

local function documentation()
  local root = plugin_root()
  return table.concat({
    "# Neoagent configuration and extensibility",
    "",
    "Neoagent is composed from ordinary Lua values. Models, tools, executors, "
      .. "Sessions, Controllers, and Views can be used or replaced independently. "
      .. "Personal integrations are ordinary Lua modules loaded explicitly by "
      .. "Neovim configuration.",
    "",
    "## Choose the smallest useful layer",
    "",
    "- A Model exposes `model:stream(opts)` and can be used directly.",
    "- `neoagent.agent.run(opts)` receives its Model, messages, exact tools, executor, "
      .. "context, and optional steering callback explicitly.",
    "- `Session.new()` is an in-memory, tool-free message owner unless a store is injected.",
    "- Bundled Workspace settings persist a shared UI dock plus name-scoped model and "
      .. "thinking preferences per cwd. Sessions remain shared across Controllers.",
    "- Bundled Windows persist accepted input in a workspace JSONL history shared by "
      .. "their Controllers.",
    "- `neoagent.new(opts[, runtime])` creates an independent Controller with its own configuration, "
      .. "model selection, Session, Workspace, and Run.",
    "- `neoagent.new_window(opts)` attaches uniquely named Controllers to one passive View. "
      .. "Selection restores per-Controller messages and input drafts while Runs remain "
      .. "concurrent.",
    "- `neoagent.setup(opts)` creates the built-in Neo and Chat Controllers in one Window. "
      .. "Neo uses the configured coding composition; Chat has an empty system prompt and "
      .. "tool list with resource discovery disabled. Commands target the active Controller "
      .. "in the default Window.",
    "- `neoagent.set_default_window(window)` installs an assembled command-facing Window.",
    "",
    "A Controller created by `neoagent.new()` receives a complete configuration. Copy "
      .. "`neoagent.default():config()` first when it should derive from the default Controller.",
    "",
    "## Independent Controller example",
    "",
    "```lua",
    "local neoagent = require(\"neoagent\")",
    "local opts = neoagent.default():config() -- independent copy",
    "opts.name = \"Review\"",
    "opts.tools = require(\"neoagent.tools\").read_only()",
    "opts.persistence = { enabled = false }",
    "opts.system_prompt = \"Review this workspace without editing it.\"",
    "local reviewer = neoagent.new(opts)",
    "local window = neoagent.new_window({",
    "  controllers = { neoagent.default(), reviewer },",
    "  ui = { position = \"left\" },",
    "})",
    "neoagent.set_default_window(window)",
    "```",
    "",
    "## Custom tool and execution policy",
    "",
    "A tool is a plain table. `execute_tool` is the boundary for approvals, logging, "
      .. "sandbox delegation, or post-edit checks.",
    "",
    "```lua",
    "local neoagent = require(\"neoagent\")",
    "local inspect_buffer = {",
    "  name = \"inspect_buffer\",",
    "  description = \"Inspect editor state supplied by this integration.\",",
    "  input_schema = { type = \"object\", properties = {}, additionalProperties = false },",
    "  execute = function(arguments, ctx)",
    "    return { content = { { type = \"text\", text = vim.inspect(ctx.context) } } }",
    "  end,",
    "}",
    "",
    "local custom_opts = neoagent.default():config()",
    "custom_opts.tools = { inspect_buffer }",
    "custom_opts.execute_tool = function(tool, arguments, ctx)",
    "    -- Confirm, log, delegate effects, lint, or typecheck here.",
    "    return tool.execute(arguments, ctx)",
    "end",
    "local controller = neoagent.new(custom_opts)",
    "```",
    "",
    "Passing `tools` selects exactly those tools. The bundled coding preset contains read, "
      .. "write, edit, shell, and this documentation "
      .. "tool. The read-only preset remains read, grep, and find.",
    "Tools may define `on_messages(messages, { session_id = ... })` to derive "
      .. "per-Session state from complete active-conversation copies. The opaque ID "
      .. "also appears at `ctx.context.session_id` during execution.",
    "`controller:get_toolset()` returns the active tools and executor. "
      .. "`controller:set_toolset(toolset)` atomically replaces that pair between Runs "
      .. "while `controller:config()` retains construction defaults.",
    "Bundled tools resolve model-directed effects through optional `ctx.fs` and "
      .. "`ctx.process` capabilities. Direct Lua calls use host implementations.",
    "The built-in Neo composition accepts `sandbox = { enabled = true }` as its "
      .. "initial editor state. `:NeoagentToggleSandbox` switches Neo between "
      .. "its configured host toolset and the composed sandbox toolset without "
      .. "changing configuration; `:NeoagentSandboxInfo` reports runtime status. "
      .. "A successful native requirements check replaces those capabilities "
      .. "with per-call sandbox implementations. Activation failure preserves "
      .. "the configured executor, and runtime failures are fail-closed. Profiles "
      .. "can override canonical read, write, and deny paths, network access, "
      .. "environment construction, and shared host temporary access.",
    "Executors can create `require(\"neoagent.dialog\").new()`, inject its "
      .. "lifetime-scoped `ctx.dialog` capability with "
      .. "`neoagent.dialog.wrap`, and pass the source as the `dialogs` option "
      .. "to `neoagent.new_window()`. Callers define transcript or floating "
      .. "placement, action IDs, labels, keys, optional Controller ownership, "
      .. "and optional editable input. Controller-scoped dialogs remain pending "
      .. "and hidden while another Controller is active. "
      .. "The source fails when no presenter is attached.",
    "",
    "## Custom workspace trust",
    "",
    "Workspace trust is an explicit Controller runtime policy. Compose its View "
      .. "separately so the Controller configuration remains reusable.",
    "",
    "```lua",
    "local neoagent = require(\"neoagent\")",
    "local dialogs = require(\"neoagent.dialog\").new()",
    "local opts = neoagent.default():config()",
    "opts.name = \"Review\"",
    "local trust_view, policy =",
    "  require(\"neoagent.workspace_trust\").compose(opts, { dialogs = dialogs })",
    "local controller = neoagent.new(opts, { workspace_trust = policy })",
    "local window = neoagent.new_window({",
    "  controllers = { controller },",
    "  dialogs = dialogs,",
    "  view = trust_view,",
    "})",
    "policy:attach_window(window, controller)",
    "```",
    "",
    "The composition reads `opts.workspace_trust.path`. Pass an explicit `path` "
      .. "to override it and pass sandbox composition status as `sandbox_status` "
      .. "when the protected toolset is sandboxed.",
    "",
    "## Custom View",
    "",
    "Set `view = function(opts) return my_view end`. The factory receives `config`, "
      .. "`window`, `on_submit`, `on_stop`, `on_dequeue_steering`, "
      .. "`on_input_history`, `on_select_history`, `on_cycle_thinking`, "
      .. "`on_cycle_agent`, `on_select_model`, `on_resume_session`, `resolve_tool`, "
      .. "`on_dialog_action`, and `on_dialog_dismiss`. `resolve_tool(name)` "
      .. "exposes optional active-tool rendering callbacks. A passive "
      .. "View implements `open`, `close`, `is_open`, "
      .. "`destroy`, `get_input`, `set_input`, `set_messages`, `set_context`, `apply`, and "
      .. "`finish`; Views used with a dialog source also implement "
      .. "`set_dialog`. Controllers publish snapshots and updates for custom "
      .. "Window adapters.",
    "",
    "## Installed paths",
    "",
    "- Plugin root: " .. root,
    "- Main documentation: " .. root .. "/README.md",
    "- Vim help: " .. root .. "/doc/neoagent.txt",
    "- Contributor guide: " .. root .. "/AGENTS.md",
    "- Core agent loop: " .. root .. "/lua/neoagent/agent.lua",
    "- Controller: " .. root .. "/lua/neoagent/controller.lua",
    "- Window: " .. root .. "/lua/neoagent/window.lua",
    "- Configuration: " .. root .. "/lua/neoagent/config.lua",
    "- Bundled tools: " .. root .. "/lua/neoagent/tools",
    "- Bundled View: " .. root .. "/lua/neoagent/ui.lua",
    "- Active Neovim configuration: " .. init_path(),
    "- Neovim configuration directory: " .. vim.fn.stdpath("config"),
    "",
    "Read the relevant documentation and source completely before changing Neoagent or "
      .. "the user's configuration. Preserve unrelated configuration and prefer a separate "
      .. "Lua module for personal integrations.",
  }, "\n")
end

local function new()
  return {
    name = "read_agent_documentation",
    description = "Read Neoagent's configuration and extensibility guide. Use this only when "
      .. "the user asks about Neoagent itself, configuring or extending Neoagent, its Lua APIs, "
      .. "tools, Controllers, Views, models, sessions, or UI. Do not call it for ordinary project work.",
    input_schema = {
      type = "object",
      properties = {},
      additionalProperties = false,
    },
    execute = function()
      return { content = { { type = "text", text = documentation() } } }
    end,
  }
end

local M = new()
M.new = new
return M
