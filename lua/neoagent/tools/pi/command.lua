-- Model-facing contracts adapted from Pi 3390bd9363 (MIT).
local commands = require("neoagent.tools.command")
local M = {}

---@return string
local function default_shell()
  local candidates = jit.os == "Windows" and { "pwsh", "powershell" } or { "bash", "sh" }
  for _, candidate in ipairs(candidates) do
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  -- Keep configuration usable when a dependency is missing. Health and
  -- request preparation report the selected executable before any spawn.
  return assert(candidates[#candidates])
end

---@param options? Neoagent.ToolPresetOptions
---@return Neoagent.Tool<unknown>
function M.new(options)
  options = options or {}
  local shell = options.shell ~= nil and require("neoagent.tools.common").path(options.shell, "shell")
    or default_shell()
  local argv = commands.shell_argv(shell, false)
  local executable = assert(argv[1])
  local name = commands.name(executable)
  local powershell = name == "pwsh" or name == "powershell"
  local label = powershell and "PowerShell" or name
  local prefix
  if powershell then
    argv = { executable, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command" }
    prefix = "try { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8 } catch {}\n"
  end
  local tool = require("neoagent.tools.shell").new({
    argv = argv,
    command_prefix = prefix,
    default_timeout = options.shell_timeout,
  })
  tool.name = powershell and "powershell" or name == "bash" and "bash" or "shell"
  tool.capabilities = { read_files = true }
  tool.description = "Execute a "
    .. label
    .. " command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds."
  tool.prompt_snippet = "Execute " .. label .. " commands"
  return tool
end

return M
