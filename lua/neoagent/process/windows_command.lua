---@class Neoagent.WindowsCommand
---@field prepare_cmd fun(argv: string[]): string[]?
---@field line fun(argv: string[]): string
local M = {}

---@param program string
---@return boolean
local function is_cmd(program)
  local basename = program:gsub("/", "\\"):match("([^\\]+)$")
  return basename ~= nil and (basename:lower() == "cmd.exe" or basename:lower() == "cmd")
end

---@param argv string[]
---@return string[]?
function M.prepare_cmd(argv)
  if not is_cmd(assert(argv[1])) then
    return nil
  end
  for index = 2, #argv do
    local option = assert(argv[index]):lower()
    if option == "/c" or option == "/k" then
      if index ~= #argv - 1 then
        return nil
      end
      local prepared = {}
      for part, argument in ipairs(argv) do
        prepared[part] = argument
      end
      prepared[1] = assert(prepared[1]):gsub("/", "\\")
      prepared[#prepared] = '"' .. assert(prepared[#prepared]) .. '"'
      return prepared
    end
  end
end

---@param value string
---@return string
local function quote(value)
  if value == "" then
    return '""'
  end
  if not value:find('[%s"]') then
    return value
  end
  local result, backslashes = { '"' }, 0
  for index = 1, #value do
    local character = value:sub(index, index)
    if character == "\\" then
      backslashes = backslashes + 1
    elseif character == '"' then
      result[#result + 1] = string.rep("\\", backslashes * 2 + 1)
      result[#result + 1] = '"'
      backslashes = 0
    else
      if backslashes > 0 then
        result[#result + 1] = string.rep("\\", backslashes)
        backslashes = 0
      end
      result[#result + 1] = character
    end
  end
  if backslashes > 0 then
    result[#result + 1] = string.rep("\\", backslashes * 2)
  end
  result[#result + 1] = '"'
  return table.concat(result)
end

---@param argv string[]
---@return string
function M.line(argv)
  local prepared = M.prepare_cmd(argv)
  local values = {}
  for index, value in ipairs(prepared or argv) do
    if index == 1 and is_cmd(value) then
      value = value:gsub("/", "\\")
    end
    values[index] = prepared and index == #argv and value or quote(value)
  end
  return table.concat(values, " ")
end

return M
