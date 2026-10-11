local common = require("neoagent.tools.common")
local M = {}

-- Neovim's shell options are argument lists, not shell programs. Double
-- quotes group words; backslashes escape quotes/backslashes only inside them.
---@param value string
---@return string[]
local function words(value)
  ---@type string[], string[]
  local argv, word = {}, {}
  local quoted, started, index = false, false, 1
  local function finish()
    if started then
      argv[#argv + 1] = table.concat(word)
      word, started = {}, false
    end
  end
  while index <= #value do
    local char = value:sub(index, index)
    if char == '"' then
      quoted, started = not quoted, true
    elseif char == "\\" and quoted and value:sub(index + 1, index + 1):match('["\\]') then
      index = index + 1
      word[#word + 1], started = value:sub(index, index), true
    elseif not quoted and (char == " " or char == "\t") then
      finish()
    else
      word[#word + 1], started = char, true
    end
    index = index + 1
  end
  assert(not quoted, "Unclosed quote in shell option")
  finish()
  return argv
end

-- An explicit mode overrides the corresponding configured flags. Preserve
-- other shell options and their operands (which may themselves look like
-- flags). The synchronous shell Tool passes nil to keep its exact options.
---@param argv string[]
---@param name string
---@param login boolean
---@param powershell boolean
---@return string[]
local function mode(argv, name, login, powershell)
  local result = { assert(argv[1]) }
  if powershell and not login then
    result[#result + 1] = "-NoProfile"
  elseif not powershell and login then
    result[#result + 1] = "-l"
  end
  local operand, ended = false, false
  for index = 2, #argv do
    local argument = assert(argv[index])
    ---@type string?
    local value = argument
    if operand or ended then
      operand = false
    elseif powershell then
      local option = argument:lower():match("^[-/](.+)$")
      if option and #option >= 3 and ("noprofile"):sub(1, #option) == option then
        value = nil
      elseif option then
        ended = ("command"):sub(1, #option) == option
          or ("file"):sub(1, #option) == option
          or option == "ec"
          or #option >= 2 and ("encodedcommand"):sub(1, #option) == option
      end
    else
      if argument == "--" then
        ended = true
      elseif argument == "--login" then
        value = nil
      elseif argument:match("^[-+][a-zA-Z]+$") then
        value = argument:gsub("l", "")
        if #value == 1 then
          value = nil
        end
      end
      operand = argument == "-o"
        or argument == "+o"
        or name == "bash" and (argument == "-O" or argument == "+O" or argument == "--rcfile" or argument == "--init-file")
        or name == "fish" and (argument == "-C" or argument == "--init-command")
    end
    if value ~= nil then
      result[#result + 1] = value
    end
  end
  return result
end

---@param command string
---@param shell? string Explicit executable; otherwise preserve 'shell' and 'shellcmdflag'.
---@param login? boolean Override POSIX login mode or PowerShell profile loading; nil preserves configured flags.
---@return string[]
function M.argv(command, shell, login)
  local argv = shell and { (common.path(shell, "shell"):gsub('^"(.*)"$', "%1")) } or words(vim.o.shell)
  local executable = common.path(assert(argv[1], "shell must name an executable"), "shell")
  local name = executable:gsub("\\", "/"):match("([^/]+)$") or ""
  name = name:lower():gsub("%.exe$", "")
  if name == "powershell" or name == "pwsh" then
    vim.list_extend(argv, shell and { "-Command" } or words(vim.o.shellcmdflag))
    if login ~= nil then
      argv = mode(argv, name, login, true)
    end
  elseif name == "cmd" then
    vim.list_extend(argv, shell and { "/d", "/s", "/c" } or words(vim.o.shellcmdflag))
  else
    local posix = name == "sh" or name == "bash" or name == "zsh" or name == "dash" or name == "ksh" or name == "fish"
    assert(not shell or posix, "Unsupported explicit shell; configure 'shell' and 'shellcmdflag' for other shells")
    vim.list_extend(argv, shell and { "-c" } or words(vim.o.shellcmdflag))
    if posix and login ~= nil then
      argv = mode(argv, name, login, false)
    end
  end
  argv[#argv + 1] = command
  return argv
end

return M
