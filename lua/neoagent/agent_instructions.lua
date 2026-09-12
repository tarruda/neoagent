local fs = require("neoagent.fs")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.ResourceDiagnostic
---@field path string
---@field message string

---@class Neoagent.InstructionFile
---@field path string
---@field content string

---@class Neoagent.InstructionOptions
---@field global_files? string[]
---@field project_filenames? string[]

---@class Neoagent.InstructionDiscoveryOptions: Neoagent.InstructionOptions
---@field cwd string

---@param value string
---@return string
local function escape_xml(value)
  return (value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

---@param opts Neoagent.InstructionDiscoveryOptions
---@return {files: Neoagent.InstructionFile[], diagnostics: Neoagent.ResourceDiagnostic[]}
function M.discover(opts)
  opts = opts or {}
  assert(type(opts.cwd) == "string" and opts.cwd ~= "", "cwd is required")
  ---@type Neoagent.InstructionFile[], Neoagent.ResourceDiagnostic[], table<string, boolean>
  local files, diagnostics, seen = {}, {}, {}

  ---@param path string
  local function add(path)
    local expanded = vim.fn.expand(path)
    ---@cast expanded string
    path = fs.normalize(expanded)
    local stat = vim.uv.fs_stat(path)
    if not stat then
      return
    end
    if stat.type ~= "file" then
      diagnostics[#diagnostics + 1] = { path = path, message = "AGENTS.md path is not a file" }
      return
    end
    local canonical = fs.canonical(path)
    if seen[canonical] then
      return
    end
    local content, err = fs.read(path)
    if not content then
      diagnostics[#diagnostics + 1] = { path = path, message = "failed to read AGENTS.md: " .. tostring(err) }
      return
    end
    seen[canonical] = true
    files[#files + 1] = { path = canonical, content = content }
  end

  for _, path in ipairs(opts.global_files or {}) do
    add(path)
  end
  for _, directory in ipairs(fs.ancestors(opts.cwd)) do
    for _, filename in ipairs(opts.project_filenames or {}) do
      add(fs.join(directory, filename))
    end
  end
  return { files = files, diagnostics = diagnostics }
end

---@param files? Neoagent.InstructionFile[]
---@return string
function M.format(files)
  files = files or {}
  if #files == 0 then
    return ""
  end
  local lines = {
    "<project_context>",
    "Contextual instructions, ordered from broadest to most specific:",
    "",
  }
  for _, file in ipairs(files) do
    lines[#lines + 1] = '<project_instructions path="' .. escape_xml(file.path) .. '">'
    lines[#lines + 1] = util.trim(file.content)
    lines[#lines + 1] = "</project_instructions>"
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "</project_context>"
  return table.concat(lines, "\n")
end

return M
