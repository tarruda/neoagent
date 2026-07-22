local fs = require("neoagent.fs")
local provider_log = require("neoagent.provider_log")

local bit = bit or bit32

describe("neoagent provider diagnostics", function()
  local paths = {}
  local notify = vim.notify

  after_each(function()
    vim.notify = notify
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  it("writes bounded private JSONL without request content", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    local path = directory .. "/nested/codex.log"
    local log = provider_log.callback(path)
    log({
      type = "request_failed",
      timestamp = 123,
      provider = "openai-codex",
      model = "gpt-test",
      status = 500,
      message = string.rep("m", 2100),
      request_id = "req-safe",
      detail = "private response body",
      headers = { Authorization = "Bearer secret" },
      token = "secret",
    })

    local raw = assert(fs.read(path))
    local event = vim.json.decode(raw)
    assert.are.equal("request_failed", event.type)
    assert.are.equal(2000, #event.message)
    assert.are.equal("req-safe", event.request_id)
    assert.is_nil(event.detail)
    assert.is_nil(event.headers)
    assert.is_nil(event.token)
    assert.are.equal(384, bit.band(assert(vim.uv.fs_stat(path)).mode, 511))
    assert.are.equal(448, bit.band(assert(vim.uv.fs_stat(vim.fs.dirname(path))).mode, 511))
    assert.matches("neoagent/codex%.log$", provider_log.codex_path())
  end)

  it("reports a diagnostic sink failure once without throwing", function()
    local path = vim.fn.tempname()
    paths[#paths + 1] = path
    assert(fs.write_all(path, "file", "w"))
    local messages = {}
    vim.notify = function(message) messages[#messages + 1] = message end
    local log = provider_log.callback(path .. "/codex.log")

    log({ type = "request_failed" })
    log({ type = "request_failed" })
    assert(vim.wait(1000, function() return #messages == 1 end))
    assert.matches("diagnostic log failed", messages[1])
  end)

  it("rotates a full diagnostic log before appending", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert(fs.mkdirp(directory))
    assert(vim.uv.fs_chmod(directory, 493))
    local path = directory .. "/codex.log"
    assert(fs.write_all(path, string.rep("x", 1024 * 1024), "w"))
    assert(provider_log.append(path, { type = "request_failed", message = "new" }))

    assert.are.equal(1024 * 1024, assert(vim.uv.fs_stat(path .. ".1")).size)
    assert.are.equal(384, bit.band(assert(vim.uv.fs_stat(path .. ".1")).mode, 511))
    assert.are.equal(493, bit.band(assert(vim.uv.fs_stat(directory)).mode, 511))
    local raw = assert(fs.read(path))
    assert.are.equal("new", vim.json.decode(raw).message)
  end)
end)
