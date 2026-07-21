local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}

local function escape_xml(value)
  return value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    :gsub('"', "&quot;"):gsub("'", "&apos;")
end

local function scalar(value)
  value = util.trim(value)
  if value:sub(1, 1) == '"' and value:sub(-1) == '"' then
    local ok, decoded = pcall(vim.json.decode, value)
    if ok and type(decoded) == "string" then return decoded end
  elseif value:sub(1, 1) == "'" and value:sub(-1) == "'" then
    return value:sub(2, -2):gsub("''", "'")
  end
  return value
end

local function frontmatter(content)
  content = content:gsub("\r\n", "\n")
  local header = content:match("^%-%-%-\n(.-)\n%-%-%-\n")
  if not header then return nil, "missing YAML frontmatter" end
  local lines = vim.split(header, "\n", { plain = true })
  local values = {}
  local index = 1
  while index <= #lines do
    local key, value = lines[index]:match("^([%w_-]+):%s*(.*)$")
    if key then
      if value == "|" or value == ">" then
        local block = {}
        index = index + 1
        while index <= #lines and (lines[index]:match("^%s+") or lines[index] == "") do
          block[#block + 1] = lines[index]:gsub("^%s+", "")
          index = index + 1
        end
        values[key] = value == ">" and util.trim(table.concat(block, " "):gsub("%s+", " "))
          or table.concat(block, "\n"):gsub("\n+$", "")
      else
        values[key] = scalar(value)
        index = index + 1
      end
    else
      index = index + 1
    end
  end
  return values
end

local function load_skill(path, source)
  local content, err = fs.read(path)
  if not content then return nil, "failed to read skill: " .. tostring(err) end
  local values, parse_err = frontmatter(content)
  if not values then return nil, parse_err end
  local name, description = values.name, values.description
  if type(name) ~= "string" or name == "" then return nil, "skill name is required" end
  local valid_name = #name <= 64 and (name:match("^[a-z0-9]$")
    or name:match("^[a-z0-9][a-z0-9-]*[a-z0-9]$")) and not name:find("--", 1, true)
  if not valid_name then
    return nil, "skill name must use 1-64 lowercase letters, numbers, or single hyphens"
  end
  if type(description) ~= "string" or util.trim(description) == "" then
    return nil, "skill description is required"
  end
  if #description > 1024 then return nil, "skill description exceeds 1024 characters" end
  local canonical = fs.canonical(path)
  return {
    name = name,
    description = util.trim(description),
    path = canonical,
    directory = vim.fs.dirname(canonical),
    source = source,
  }
end

local function scan(root, source, add, diagnostics, visited)
  root = fs.normalize(vim.fn.expand(root))
  local stat = vim.uv.fs_stat(root)
  if not stat then return end
  if stat.type ~= "directory" then
    diagnostics[#diagnostics + 1] = { path = root, message = "skill path is not a directory" }
    return
  end
  local canonical = fs.canonical(root)
  if visited[canonical] then return end
  visited[canonical] = true

  local skill_path = fs.join(canonical, "SKILL.md")
  if vim.uv.fs_stat(skill_path) then
    local skill, err = load_skill(skill_path, source)
    if skill then add(skill) else diagnostics[#diagnostics + 1] = { path = skill_path, message = err } end
    return
  end

  local handle, scan_err = vim.uv.fs_scandir(canonical)
  if not handle then
    diagnostics[#diagnostics + 1] = { path = canonical, message = "failed to scan skills: " .. tostring(scan_err) }
    return
  end
  local children = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if name:sub(1, 1) ~= "." and name ~= "node_modules" then
      local path = fs.join(canonical, name)
      local child_stat = kind == "link" and vim.uv.fs_stat(path) or nil
      if kind == "directory" or child_stat and child_stat.type == "directory" then
        children[#children + 1] = path
      end
    end
  end
  table.sort(children)
  for _, child in ipairs(children) do scan(child, source, add, diagnostics, visited) end
end

function M.discover(opts)
  opts = opts or {}
  assert(type(opts.cwd) == "string" and opts.cwd ~= "", "cwd is required")
  local by_name, diagnostics, visited, paths = {}, {}, {}, {}
  local function add(skill)
    if paths[skill.path] then return end
    paths[skill.path] = true
    by_name[skill.name] = skill
  end
  for _, directory in ipairs(opts.global_dirs or {}) do
    scan(directory, "global", add, diagnostics, visited)
  end
  for _, ancestor in ipairs(fs.ancestors(opts.cwd)) do
    for _, directory in ipairs(opts.project_dirs or {}) do
      scan(fs.join(ancestor, directory), "project", add, diagnostics, visited)
    end
  end
  local skills = vim.tbl_values(by_name)
  table.sort(skills, function(a, b) return a.name < b.name end)
  return { skills = skills, diagnostics = diagnostics }
end

function M.format(skills)
  if #(skills or {}) == 0 then return "" end
  local lines = {
    "The following skills provide specialized instructions for specific tasks.",
    "Use read_file to load a skill's SKILL.md when the task matches its description.",
    "Resolve relative paths in a skill against the directory containing its SKILL.md.",
    "",
    "<available_skills>",
  }
  for _, skill in ipairs(skills) do
    lines[#lines + 1] = "  <skill>"
    lines[#lines + 1] = "    <name>" .. escape_xml(skill.name) .. "</name>"
    lines[#lines + 1] = "    <description>" .. escape_xml(skill.description) .. "</description>"
    lines[#lines + 1] = "    <location>" .. escape_xml(skill.path) .. "</location>"
    lines[#lines + 1] = "  </skill>"
  end
  lines[#lines + 1] = "</available_skills>"
  return table.concat(lines, "\n")
end

return M
