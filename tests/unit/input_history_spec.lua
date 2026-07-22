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
    assert.has_error(function() history:write({ false }) end)
    assert.has_error(function()
      history_module.new({ directory = directory, root = root, limit = 0 })
    end)
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

    vim.fn.delete(history.path)
    vim.fn.mkdir(history.path, "p")
    value, err = history:load()
    assert.is_nil(value)
    assert.matches("read", err.message)
  end)
end)
