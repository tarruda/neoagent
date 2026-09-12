local assert = require("luassert")
local fs = require("neoagent.fs")
local provider_log = require("neoagent.provider_log")

local bit = require("bit")

describe("neoagent provider diagnostics", function()
  ---@type string[]
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
    ---@type string[]
    local messages = {}
    local log = provider_log.callback(path .. "/codex.log", {
      report = function(message) messages[#messages + 1] = message end,
    })

    log({ type = "request_failed" })
    log({ type = "request_failed" })
    assert(vim.wait(1000, function() return #messages == 1 end))
    assert.matches("diagnostic log failed", (assert(messages[1])))
  end)

  it("reports diagnostic lock failures", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert(fs.mkdirp(directory))
    local path = directory .. "/codex.log"
    local original_open = vim.uv.fs_open
    ---@param candidate string
    ---@param flags uv.fs_open.flags
    ---@param mode integer
    vim.uv.fs_open = function(candidate, flags, mode)
      if candidate == path .. ".lock" then return nil, "EACCES: denied" end
      return original_open(candidate, flags, mode)
    end
    local ok, err = provider_log.append(path, { type = "request_failed" })
    vim.uv.fs_open = original_open
    assert.is_nil(ok)
    assert.matches("EACCES", (assert(err)))
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

  it("reports serialization, rotation, and append failures", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert(fs.mkdirp(directory))
    local path = directory .. "/codex.log"

    local encoded, encode_err = provider_log.append(path, { status = math.huge })
    assert.is_nil(encoded)
    assert.is_not_nil(encode_err)

    assert(fs.write_all(path, string.rep("x", 1024 * 1024), "w"))
    local rename = vim.uv.fs_rename
    vim.uv.fs_rename = function() return nil, "rotation denied" end
    local rotated, rotate_err = provider_log.append(path, { type = "failure" })
    vim.uv.fs_rename = rename
    assert.is_nil(rotated)
    assert.matches("rotation denied", tostring(rotate_err))

    assert(vim.uv.fs_unlink(path))
    local write_all = fs.write_all
    fs.write_all = function(candidate, ...)
      if candidate == path then return nil, "append denied" end
      return write_all(candidate, ...)
    end
    local written, write_err = provider_log.append(path, { type = "failure" })
    fs.write_all = write_all
    assert.is_nil(written)
    assert.matches("append denied", tostring(write_err))
  end)

  it("serializes appends with a concurrent writer", function()
    local directory = vim.fn.tempname()
    paths[#paths + 1] = directory
    assert(fs.mkdirp(directory))
    local path = directory .. "/codex.log"
    assert(fs.write_all(path, vim.json.encode({ type = "existing" }) .. "\n", "w"))
    local holder = assert(require("neoagent.file_lock").new({
      path = path .. ".lock",
    }):acquire())

    local concurrent_done = false
    vim.defer_fn(function()
      assert(fs.write_all(path,
        vim.json.encode({ type = "concurrent" }) .. "\n", "a", 384))
      assert(holder:release())
      concurrent_done = true
    end, 20)

    assert(provider_log.append(path, { type = "local" }))
    assert(vim.wait(1000, function() return concurrent_done end))
    local events = vim.tbl_map(vim.json.decode,
      vim.split(assert(fs.read(path)), "\n", { plain = true, trimempty = true }))
    assert.are.same({ "existing", "concurrent", "local" },
      vim.tbl_map(function(event) return event.type end, events))
  end)
end)
