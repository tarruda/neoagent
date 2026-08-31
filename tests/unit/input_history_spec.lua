local history_module = require("neoagent.input_history")

describe("neoagent input history", function()
  local paths = {}

  after_each(function()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  it("persists bounded multiline JSONL history per workspace", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local history = history_module.new({ directory = directory, root = root, limit = 3 })
    assert.are.same({}, assert(history:load()))
    assert.are.same({}, assert(history:add("  ")))
    assert.is_nil(vim.uv.fs_stat(directory))

    assert(history:add("one\nline"))
    assert(history:add("one\nline"))
    assert(history:add("two"))
    assert(history:add("three"))
    assert(history:add("four"))
    assert.are.same({ "four", "three", "two" }, assert(history:load()))
    assert.are.equal('"two"\n"three"\n"four"\n',
      assert(require("neoagent.fs").read(history.path)))

    local bit = require("bit")
    assert.are.equal(448, bit.band(vim.uv.fs_stat(history.directory).mode, 511))
    assert.are.equal(384, bit.band(vim.uv.fs_stat(history.path).mode, 511))
    assert.are.same({ "direct" }, assert(history:write({ "direct" })))
    assert.are.same({ "direct" }, assert(history:load()))
    assert.has_error(function() history:write({ false }) end)
    assert.has_error(function()
      history_module.new({ directory = directory, root = root, limit = 0 })
    end)
  end)

  it("merges additions serialized with a concurrent writer", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local history = history_module.new({ directory = directory, root = root })
    assert(history:add("first"))
    local lock_path = history.path .. ".lock"
    assert(require("neoagent.fs").write_all(lock_path, "held", "wx", 384))

    local concurrent_done, concurrent_err
    vim.defer_fn(function()
      local written, write_err = require("neoagent.fs").write_all(
        history.path, '"first"\n"concurrent"\n')
      local removed, remove_err = vim.uv.fs_unlink(lock_path)
      concurrent_err = write_err or remove_err
      concurrent_done = written and removed
    end, 20)

    local updated = assert(history:add("local"))
    assert(vim.wait(1000, function() return concurrent_done or concurrent_err ~= nil end, 5))
    assert.is_nil(concurrent_err)
    assert.are.same({ "local", "concurrent", "first" }, updated)
    assert.are.same(updated, assert(history:load()))
  end)

  it("reports malformed files and atomic replacement failures", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local history = history_module.new({ directory = directory, root = root })
    vim.fn.mkdir(history.directory, "p")
    vim.fn.writefile({ "not-json" }, history.path)
    local value, err = history:load()
    assert.is_nil(value)
    assert.are.equal("history", err.kind)
    assert.matches("line 1", err.detail)

    vim.fn.writefile({ '"valid"' }, history.path)
    local original_rename = vim.uv.fs_rename
    vim.uv.fs_rename = function() return nil, "denied" end
    value, err = history:add("new")
    vim.uv.fs_rename = original_rename
    assert.is_nil(value)
    assert.matches("replace", err.message)

    local original_random = vim.uv.random
    vim.uv.random = function(size, ...)
      if size == 8 then return nil, "entropy unavailable" end
      return original_random(size, ...)
    end
    value, err = history:add("without random bytes")
    vim.uv.random = original_random
    assert.is_nil(value)
    assert.matches("temporary file", err.message)
    assert.are.equal("entropy unavailable", err.detail)

    vim.fn.delete(history.path)
    vim.fn.mkdir(history.path, "p")
    value, err = history:load()
    assert.is_nil(value)
    assert.matches("read", err.message)

    vim.fn.delete(history.path, "rf")
    local original_open = vim.uv.fs_open
    vim.uv.fs_open = function(candidate, ...)
      if candidate == history.path .. ".lock" then return nil, "EACCES: denied" end
      return original_open(candidate, ...)
    end
    value, err = history:write({ "blocked" })
    vim.uv.fs_open = original_open
    assert.is_nil(value)
    assert.matches("acquire input history lock", err.message)
  end)
end)
