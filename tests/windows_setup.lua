-- Run on a fresh, elevated Windows CI host before admitting any sandbox work.
-- Native setup must resume each interrupted allocation with the same identities.
local nvim = assert(vim.env.NEOAGENT_NVIM)
local directory = assert(vim.env.NEOAGENT_WINDOWS_SANDBOX_STATE)
local record = vim.fs.joinpath(assert(vim.env.RUNNER_TEMP), "neoagent-setup-effects.jsonl")
local fixture = assert(vim.uv.fs_realpath("tests/fixtures/sandbox_windows_setup_failure.lua"))
vim.opt.runtimepath:prepend(assert(vim.uv.cwd()))
local ok, err = pcall(function()
  for _, phase in ipairs({ "launcher", "rights", "group", "firewall", "complete" }) do
    local result = vim.system({ nvim, "--headless", "-u", "NONE", "-i", "NONE", "-n",
      "-l", fixture, "--", "--setup" }, { text = true, env = {
        NEOAGENT_SETUP_TEST_PHASE = phase, NEOAGENT_SETUP_TEST_RECORD = record,
      } }):wait(60000)
    assert(result.code == (phase == "complete" and 0 or 137),
      "setup did not reach " .. phase .. ": " .. (result.stderr or ""))
    if phase ~= "complete" then
      local status = require("neoagent.sandbox.windows").check({ fs = require("neoagent.fs"), nvim = nvim })
      assert(not status.ok and status.stage == "setup-incomplete",
        "interrupted provisioning allowed admission: " .. vim.inspect(status))
    end
  end
  ---@type table<string, table<string, boolean>>
  local allocations = { launcher = {}, group = {}, filter = {} }
  for _, line in ipairs(vim.fn.readfile(record)) do
    local event = vim.json.decode(line)
    local identities = allocations[event.kind]
    if identities then identities[event.identity] = true end
  end
  for kind, identities in pairs(allocations) do
    assert(vim.tbl_count(identities) == (kind == "filter" and 4 or 1),
      "interrupted setup lost " .. kind .. " ownership: " .. vim.inspect(vim.tbl_keys(identities)))
  end
  local journal = assert(io.open(vim.fs.joinpath(directory, "state.json"), "rb"))
  local state = vim.json.decode((journal:read("*a")))
  journal:close()
  assert(assert(allocations.launcher)[state.launcher.name], "setup journal lost the allocated launcher")
  assert(assert(allocations.group)[state.offline_group.name], "setup journal lost the allocated group")
end)
vim.uv.fs_unlink(record)
if not ok then error(err, 0) end
io.stdout:write("Windows setup recovered every interrupted persistent allocation\n")
