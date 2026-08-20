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
    "# Neoagent API map",
    "",
    "Neoagent is composed from plain Lua values. Use the layer that matches the task:",
    "",
    "- Models implement `model:stream(opts)` and return cancellable Runs.",
    "- `neoagent.agent.run(opts)` runs an explicit Model and toolset.",
    "- `Session.new()` owns in-memory messages; persistence is injected.",
    "- `neoagent.new(opts[, runtime])` creates an independent Controller.",
    "- `neoagent.new_window(opts)` attaches named Controllers to one passive View.",
    "- `neoagent.setup(opts)` creates the built-in Neo and Chat Controllers.",
    "",
    "## Independent Controller",
    "",
    "```lua",
    "local neoagent = require(\"neoagent\")",
    "local opts = neoagent.default():config()",
    "opts.name = \"Review\"",
    "opts.tools = require(\"neoagent.tools\").read_only()",
    "opts.system_prompt = \"Review this workspace.\"",
    "",
    "local review = neoagent.new(opts)",
    "local window = neoagent.new_window({",
    "  controllers = { neoagent.default(), review },",
    "})",
    "neoagent.set_default_window(window)",
    "```",
    "",
    "Controller names are unique within a Window. Each Controller owns its Session, "
      .. "model selection, toolset, draft, and active Run. A Window keeps inactive "
      .. "Controller Runs alive.",
    "",
    "## Tools and execution",
    "",
    "A tool is a `{ name, description, input_schema, execute }` table. Passing "
      .. "`tools` selects the exact list. Bundled presets are available from "
      .. "`require(\"neoagent.tools\")`.",
    "",
    "`execute_tool(tool, arguments, ctx)` is the policy boundary for approvals, "
      .. "logging, sandboxing, and post-edit checks. Bundled tools route effects "
      .. "through optional `ctx.fs` and `ctx.process` capabilities.",
    "",
    "Tools may define `on_messages(messages, ctx)` to derive Session state and "
      .. "`render(opts)` to return semantic presentation data. "
      .. "`controller:set_toolset(toolset)` replaces tools and their executor "
      .. "between Runs.",
    "",
    "## Runtime policies and UI",
    "",
    "Workspace trust and sandboxing are explicit higher-level compositions. "
      .. "The built-in Neo Controller uses both; custom Controllers receive them "
      .. "through runtime injection and executor decoration.",
    "",
    "A custom View is a passive consumer of Controller snapshots and updates. "
      .. "The Window owns Controller selection and drafts. An explicit Renderer "
      .. "turns copied semantic blocks into declarative content.",
    "",
    "Use `:help neoagent` for configuration, commands, method lists, and extension "
      .. "contracts. Read the relevant source before changing an integration.",
    "",
    "## Paths",
    "",
    "- Plugin root: " .. root,
    "- README: " .. root .. "/README.md",
    "- Vim help: " .. root .. "/doc/neoagent.txt",
    "- Architecture: " .. root .. "/architecture.md",
    "- Contributor guide: " .. root .. "/AGENTS.md",
    "- Agent loop: " .. root .. "/lua/neoagent/agent.lua",
    "- Controller: " .. root .. "/lua/neoagent/controller.lua",
    "- Window: " .. root .. "/lua/neoagent/window.lua",
    "- Configuration: " .. root .. "/lua/neoagent/config.lua",
    "- Tools: " .. root .. "/lua/neoagent/tools",
    "- View: " .. root .. "/lua/neoagent/ui.lua",
    "- Active Neovim configuration: " .. init_path(),
    "- Neovim configuration directory: " .. vim.fn.stdpath("config"),
  }, "\n")
end

local function new()
  return {
    name = "read_agent_documentation",
    description = "Read Neoagent's configuration and extension API map. Use this only when "
      .. "the user asks about Neoagent itself, configuring or extending "
      .. "Neoagent, its Lua APIs, tools, Controllers, Views, models, sessions, "
      .. "or UI. Do not call it for ordinary project work.",
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
