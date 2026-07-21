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
      .. "and context explicitly.",
    "- `Session.new()` is an in-memory, tool-free message owner unless a store is injected.",
    "- Bundled Workspace settings persist a shared UI dock plus name-scoped model and "
      .. "thinking preferences per cwd. Sessions remain shared across Controllers.",
    "- `neoagent.new(opts)` creates an independent Controller with its own configuration, "
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
    "    -- Confirm, log, sandbox, lint, or typecheck here when appropriate.",
    "    return tool.execute(arguments, ctx)",
    "end",
    "local controller = neoagent.new(custom_opts)",
    "```",
    "",
    "Passing `tools` selects exactly those tools. The bundled coding preset contains read, "
      .. "write, edit, shell, and this documentation "
      .. "tool. The read-only preset remains read, grep, and find.",
    "",
    "## Custom View",
    "",
    "Set `view = function(opts) return my_view end`. The factory receives `config`, "
      .. "`window`, `on_submit`, `on_stop`, `on_cycle_thinking`, `on_cycle_agent`, and "
      .. "`on_position_change`. A passive View implements `open`, `close`, `is_open`, "
      .. "`destroy`, `get_input`, `set_input`, `set_messages`, `set_context`, `apply`, and "
      .. "`finish`. Controllers publish snapshots and updates for custom Window adapters.",
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
