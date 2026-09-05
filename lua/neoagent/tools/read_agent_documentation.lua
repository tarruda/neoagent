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
    "Choose the smallest composition that owns the task:",
    "",
    "- A Model implements `model:stream(opts)` and returns a cancellable Run.",
    "- `neoagent.agent_loop.run(opts)` runs an explicit Model and toolset.",
    "- `Session.new()` owns messages; a store adds persistence.",
    "- `neoagent.new(opts[, runtime])` creates an independent Agent.",
    "- `neoagent.setup(opts)` creates the interactive Profile composition.",
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
    "The constructor input is an ordinary options table. Pass a Session, "
      .. "Workspace, or shared provider runtimes in the second argument.",
    "",
    "## Tools and execution",
    "",
    "A Tool is a `{ name, description, input_schema, execute }` table. "
      .. "Bundled presets come from `require(\"neoagent.tools\")`.",
    "`execute_tool(tool, arguments, ctx)` is the policy boundary for "
      .. "approval, logging, sandboxing, and other decorators.",
    "",
    "## Runtime policies and UI",
    "",
    "Workspace trust, sandboxing, resources, persistence, and UI are optional "
      .. "layers composed around an Agent.",
    "An Agent Applet presents one Agent; the top-level Neoagent Applet owns "
      .. "Profile drafts, Agent selection, and the Provider Shell.",
    "",
    "## References",
    "",
    "- Plugin root: " .. root,
    "- Configuration, commands, and Lua APIs: " .. root .. "/doc/neoagent.txt",
    "- UI package: " .. root .. "/doc/applet.txt",
    "- Ownership and data flow: " .. root .. "/architecture.md",
    "- Contributor guide: " .. root .. "/AGENTS.md",
    "- Active Neovim configuration: " .. init_path(),
  }, "\n")
end

local DESCRIPTION = table.concat({
  "Read Neoagent's configuration and composition API map.",
  "Use this only when the user asks about Neoagent, its configuration, or",
  "its Lua APIs. Do not call it for ordinary project work.",
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
