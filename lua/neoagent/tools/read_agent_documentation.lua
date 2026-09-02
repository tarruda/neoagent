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
    "- `neoagent.agent_loop.run(opts)` runs an explicit Model, toolset, and "
      .. "message commit command.",
    "- `Session.new()` owns in-memory messages; persistence is injected.",
    "- `neoagent.profile_sessions` binds registered Profiles to Session headers.",
    "- `neoagent.new(opts[, runtime])` creates an independent Agent.",
    "- `neoagent.setup(opts)` creates Neo and Chat Profiles with zero Agents.",
    "",
    "## Independent Agent",
    "",
    "```lua",
    "local neoagent = require(\"neoagent\")",
    "local session = require(\"neoagent.session\").new()",
    "",
    "local review = neoagent.new({",
    "  name = \"Review\",",
    "  tools = require(\"neoagent.tools\").read_only(),",
    "  system_prompt = \"Review this workspace.\",",
    "}, {",
    "  session = session,",
    "  workspace = vim.fn.getcwd(),",
    "})",
    "```",
    "",
    "Each Agent has opaque identity and owns one immutable Session binding, model selection, "
      .. "toolset, Presenter, dialogs, and outer activity Run. Durable submission "
      .. "acceptance is published separately from Run creation. Direct Agents may "
      .. "remain headless.",
    "Agent completion publications contain bounded scalar metadata and exclude "
      .. "Session, Store, Model, Run, Presenter, and UI owner graphs.",
    "`agent:config()` and `neoagent.config.get()` return resolved inspection snapshots; "
      .. "constructor input is an ordinary options table.",
    "",
    "Registered-Profile Sessions record `metadata.neoagent.profileId`. The "
      .. "top-level Applet owns new, resume, fork, copy, live Session "
      .. "claims, and foreground selection. Branching stays inside the Agent's Session. "
      .. "`:NeoagentCycle` opens the switcher and `:NeoagentCopySession` creates "
      .. "an independent Profile-selected copy.",
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
    "Bundled writes atomically replace regular files in their target directory, "
      .. "preserve existing modes, reject symbolic links, and create new files "
      .. "with mode 0644 subject to process policy.",
    "",
    "Tools may define `on_messages(messages, ctx)` to derive Session state and "
      .. "`render(opts)` to return semantic presentation data. "
      .. "`agent:set_toolset(toolset)` replaces tools and their executor "
      .. "between Runs.",
    "Toolsets are validated during configuration, health checks, replacement, "
      .. "and turn preparation. Model and request preparation complete before "
      .. "the Session accepts a user message.",
    "Tool-result images use base64 data and a required `image/*` MIME type. "
      .. "Transient image updates also carry stable `id` and `revision` values.",
    "",
    "## Runtime policies and UI",
    "",
    "Workspace trust and sandboxing are explicit higher-level compositions. "
      .. "The built-in Neo Agent uses both; custom Agents receive them "
      .. "through runtime injection and executor decoration.",
    "",
    "One Agent Applet owns its View and its draft, dialogs, focus, "
      .. "scrolling, and provider visibility. The top-level Neoagent Applet "
      .. "owns Profile drafts, Agent selection, and the switcher. An explicit "
      .. "Renderer turns copied semantic blocks into declarative content.",
    "",
    "Use `:help neoagent` for configuration, commands, method lists, and composition "
      .. "contracts. Read the relevant source before changing an integration.",
    "",
    "## Paths",
    "",
    "- Plugin root: " .. root,
    "- README: " .. root .. "/README.md",
    "- Vim help: " .. root .. "/doc/neoagent.txt",
    "- Architecture: " .. root .. "/architecture.md",
    "- Contributor guide: " .. root .. "/AGENTS.md",
    "- Agent Loop: " .. root .. "/lua/neoagent/agent_loop.lua",
    "- Agent: " .. root .. "/lua/neoagent/agent.lua",
    "- Neoagent Applet: " .. root .. "/lua/neoagent/applet.lua",
    "- Agent Applet: " .. root .. "/lua/neoagent/agent_applet.lua",
    "- Profiles: " .. root .. "/lua/neoagent/profiles.lua",
    "- Profile Sessions: " .. root .. "/lua/neoagent/profile_sessions.lua",
    "- Configuration: " .. root .. "/lua/neoagent/config.lua",
    "- Tools: " .. root .. "/lua/neoagent/tools",
    "- View: " .. root .. "/lua/neoagent/ui.lua",
    "- Active Neovim configuration: " .. init_path(),
    "- Neovim configuration directory: " .. vim.fn.stdpath("config"),
  }, "\n")
end

local DESCRIPTION = table.concat({
  "Read Neoagent's configuration and composition API map.",
  "Use this only when the user asks about Neoagent itself, configuring or",
  "extending Neoagent, its Lua APIs, tools, Agents, Views, models, sessions,",
  "or UI. Do not call it for ordinary project work.",
}, " ")

local function new()
  return {
    name = "read_agent_documentation",
    description = DESCRIPTION,
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
