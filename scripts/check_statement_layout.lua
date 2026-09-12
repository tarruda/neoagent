-- Keep block statements on separate lines so LuaCov can distinguish a
-- condition or closure from the statements inside its body.
local paths = {}
for _, root in ipairs({ "lua/applet", "lua/neoagent", "plugin" }) do
  vim.list_extend(paths, vim.fn.globpath(root, "**/*.lua", false, true))
end
table.sort(paths)

local failures = 0
for _, path in ipairs(paths) do
  local lines = vim.fn.readfile(path)
  local source = table.concat(lines, "\n")
  local parser = vim.treesitter.get_string_parser(source, "lua")
  local tree = assert(parser:parse()[1])
  assert(not tree:root():has_error(), "Invalid Lua syntax: " .. path)

  -- Remove only parsed comments. A string containing Lua syntax remains part
  -- of its owning statement, and a long comment can precede code on its line.
  ---@param node TSNode
  local function remove_comments(node)
    if node:type() == "comment" then
      local first_row, first_column, last_row, last_column = node:range()
      for row = first_row, last_row do
        local line = assert(lines[row + 1])
        local first = row == first_row and first_column or 0
        local last = row == last_row and last_column or #line
        lines[row + 1] = line:sub(1, first) .. string.rep(" ", last - first) .. line:sub(last + 1)
      end
      return
    end
    for child in node:iter_children() do
      remove_comments(child)
    end
  end
  remove_comments(tree:root())

  ---@param row integer
  ---@param detail string
  local function report(row, detail)
    io.stderr:write(("%s:%d: %s\n"):format(path, row + 1, detail))
    failures = failures + 1
  end

  ---@param node TSNode
  local function visit(node)
    local kind = node:type()
    if kind == "elseif_statement" then
      local row, column = node:start()
      if assert(lines[row + 1]):sub(1, column):find("%S") then
        report(row, "elseif condition shares its line with preceding code")
      end
    end
    if kind == "block" or kind == "chunk" then
      for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
          local first_row, first_column, last_row, last_column = child:range()
          if assert(lines[first_row + 1]):sub(1, first_column):find("%S") then
            report(first_row, "statement shares its line with preceding code")
          end
          if assert(lines[last_row + 1]):sub(last_column + 1):find("[^%s;]") then
            report(last_row, "statement shares its line with following code")
          end
        end
      end
    end
    for child in node:iter_children() do
      visit(child)
    end
  end
  visit(tree:root())
end

print(("Statement layout: %d Lua files checked; %d failures"):format(#paths, failures))
if failures > 0 then
  vim.cmd("cquit")
end
