local fs = require("neoagent.fs")

local M = {}

---@class Neoagent.LuaJitProfiler
---@field start fun(mode: string, callback: fun(thread: thread, samples: integer, vmstate: string))
---@field stop fun()
---@field dumpstack fun(thread: thread, format: string, depth: integer): string

---@class Neoagent.LuaProfile
---@field profiler Neoagent.LuaJitProfiler
---@field path string
---@field group integer
---@field started_at string
---@field started_ns number
---@field samples integer
---@field states table<string, integer>
---@field stacks table<string, integer>
---@field report? string

---@type Neoagent.LuaProfile?
local current
local sequence = 0
local interval_ms = 2
local stack_depth = 10
local state_names = {
  N = "Compiled Lua",
  I = "Interpreted Lua",
  C = "C code",
  G = "Garbage collector",
  J = "JIT compiler",
}

---@param lines string[]
---@param counts table<string, integer>
---@param total integer
local function append_counts(lines, counts, total)
  local keys = vim.tbl_keys(counts)
  table.sort(keys, function(a, b)
    if counts[a] == counts[b] then
      return a < b
    end
    return counts[a] > counts[b]
  end)
  for _, key in ipairs(keys) do
    lines[#lines + 1] = string.format("%6.2f%% %8d  %s", counts[key] * 100 / total, counts[key], key:gsub("\n", " < "))
  end
end

---@param capture Neoagent.LuaProfile
---@return string
local function render(capture)
  ---@type {major: integer, minor: integer, patch: integer}
  local version = vim.fn.api_info().version
  local lines = {
    "Neoagent LuaJIT profile",
    "Started: " .. capture.started_at,
    string.format("Neovim: %d.%d.%d", version.major, version.minor, version.patch),
    "LuaJIT: " .. jit.version,
    "Scope: all Lua in this Neovim process",
    string.format("Capture duration: %.3f seconds (wall clock)", (vim.uv.hrtime() - capture.started_ns) / 1e9),
    string.format("Sampling interval: %d ms (requested; actual precision depends on the platform)", interval_ms),
    "Samples: " .. capture.samples,
    "Percentages describe samples, not elapsed time or exact call durations.",
    "",
  }
  if capture.samples == 0 then
    lines[#lines + 1] = "No samples collected."
  else
    lines[#lines + 1] = "VM states"
    append_counts(lines, capture.states, capture.samples)
    local functions = {}
    for stack, count in pairs(capture.stacks) do
      local leaf = assert(stack:match("^[^\n]+"))
      functions[leaf] = (functions[leaf] or 0) + count
    end
    lines[#lines + 1] = "\nFunctions (top frame; all VM states)"
    append_counts(lines, functions, capture.samples)
    lines[#lines + 1] = "\nCall stacks (leaf < caller; up to " .. stack_depth .. " frames)"
    append_counts(lines, capture.stacks, capture.samples)
  end
  return table.concat(lines, "\n") .. "\n"
end

---@return string? path Reserved report path.
---@return string? error
function M.start()
  if current then
    return nil, "A LuaJIT profile is already active or awaiting save; run :NeoagentProfile stop first"
  end
  local available, loaded = pcall(require, "jit.profile")
  if
    not available
    or type(loaded) ~= "table"
    or type(loaded.start) ~= "function"
    or type(loaded.stop) ~= "function"
    or type(loaded.dumpstack) ~= "function"
  then
    return nil, "LuaJIT sampling profiler is unavailable: " .. tostring(loaded)
  end
  ---@type Neoagent.LuaJitProfiler
  local profiler = loaded
  local directory = vim.fn.stdpath("state") .. "/neoagent/profiling"
  local ready, directory_err = fs.ensure_private_directory(directory, 448)
  if not ready then
    return nil, "Cannot create profiling directory: " .. tostring(directory_err)
  end
  sequence = sequence + 1
  local timestamp = os.date("!%Y%m%dT%H%M%SZ")
  local path = fs.join(directory, string.format("%s-%d-%d.txt", timestamp, vim.uv.os_getpid(), sequence))
  local reserved, reserve_err = fs.write_all(path, "", "wx", 384)
  if not reserved then
    return nil, "Cannot create LuaJIT profile: " .. tostring(reserve_err)
  end
  local capture = {
    profiler = profiler,
    path = path,
    group = vim.api.nvim_create_augroup("NeoagentProfiler", { clear = true }),
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    started_ns = vim.uv.hrtime(),
    samples = 0,
    states = {},
    stacks = {},
  }
  current = capture
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = capture.group,
    once = true,
    callback = function()
      local _, err = M.stop()
      if err then
        vim.notify("neoagent: " .. err, vim.log.levels.ERROR)
      end
    end,
  })
  local started, start_err = pcall(profiler.start, "fi" .. interval_ms, function(thread, samples, vmstate)
    -- The callback only aggregates stacks: no editor calls or file I/O.
    local stack = profiler.dumpstack(thread, "pFZ\n", stack_depth)
    if stack == "" then
      stack = "(unavailable)"
    end
    local state = state_names[vmstate] or vmstate
    capture.samples = capture.samples + samples
    capture.states[state] = (capture.states[state] or 0) + samples
    capture.stacks[stack] = (capture.stacks[stack] or 0) + samples
  end)
  if not started then
    current = nil
    vim.api.nvim_del_augroup_by_id(capture.group)
    vim.uv.fs_unlink(path)
    return nil, "Cannot start LuaJIT profiler: " .. tostring(start_err)
  end
  return path
end

---@return string? path Saved report path.
---@return string? error
function M.stop()
  local capture = current
  if not capture then
    return nil, "No LuaJIT profile is active"
  end
  if not capture.report then
    local stopped, stop_err = pcall(capture.profiler.stop)
    if not stopped then
      return nil, "Cannot stop LuaJIT profiler: " .. tostring(stop_err)
    end
    capture.report = render(capture)
  end
  local written, write_err = fs.write_all(capture.path, capture.report, "w", 384)
  if not written then
    return nil,
      "Cannot save LuaJIT profile to " .. capture.path .. "; retry :NeoagentProfile stop: " .. tostring(write_err)
  end
  current = nil
  vim.api.nvim_del_augroup_by_id(capture.group)
  return capture.path
end

return M
