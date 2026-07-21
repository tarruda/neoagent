local settings_module = require("neoagent.workspace_settings")

describe("neoagent workspace settings", function()
  local paths = {}

  after_each(function()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  it("recursively merges and atomically persists cwd-scoped overrides", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local settings = settings_module.new({ directory = directory, root = root })
    local metadata = settings:metadata()
    assert.are.equal(vim.uv.fs_realpath(root), metadata.root)
    assert.are.equal(directory .. "/" .. vim.fn.sha256(metadata.root), metadata.directory)
    assert.are.equal(metadata.directory .. "/settings.json", metadata.settings_path)
    assert.are.equal(metadata.directory .. "/sessions", metadata.sessions_directory)

    local merged, overrides = assert(settings:merge({ nested = { first = true }, value = "base" }))
    assert.are.same({}, overrides)
    assert.are.same({ nested = { first = true }, value = "base" }, merged)
    assert.is_nil(vim.uv.fs_stat(directory))

    assert(settings:write({ nested = { second = true }, value = "local" }))
    local updated = assert(settings:update({ nested = { third = true } }))
    assert.are.same({ nested = { second = true, third = true }, value = "local" }, updated)
    assert.are.same(updated, assert(settings:load()))
    local bit = require("bit")
    assert.are.equal(448, bit.band(vim.uv.fs_stat(metadata.directory).mode, 511))
    assert.are.equal(384, bit.band(vim.uv.fs_stat(metadata.settings_path).mode, 511))
  end)

  it("reports malformed and non-object settings", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local settings = settings_module.new({ directory = directory, root = root })
    vim.fn.mkdir(settings.directory, "p")
    vim.fn.writefile({ "[]" }, settings.settings_path)
    local value, err = settings:load()
    assert.is_nil(value)
    assert.are.equal("settings", err.kind)
    assert.matches("object", err.detail)
    vim.fn.writefile({ "{" }, settings.settings_path)
    value, err = settings:merge({})
    assert.is_nil(value)
    assert.matches("Invalid", err.message)
    value, err = settings:write({ callback = function() end })
    assert.is_nil(value)
    assert.matches("encode", err.message)

    local original_rename = vim.uv.fs_rename
    vim.uv.fs_rename = function() return nil, "denied" end
    local called, written, write_err = pcall(settings.write, settings, { valid = true })
    vim.uv.fs_rename = original_rename
    assert(called)
    assert.is_nil(written)
    assert.matches("replace", write_err.message)

    vim.fn.delete(settings.settings_path)
    vim.fn.mkdir(settings.settings_path, "p")
    value, err = settings:load()
    assert.is_nil(value)
    assert.matches("read", err.message)
  end)
end)
