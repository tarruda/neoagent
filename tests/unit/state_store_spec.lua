local state_store = require("neoagent.state_store")

describe("neoagent state store", function()
  local directories = {}

  after_each(function()
    for _, path in ipairs(directories) do vim.fn.delete(path, "rf") end
    directories = {}
  end)

  local function store()
    local path = vim.fn.tempname()
    directories[#directories + 1] = path
    return state_store.new({ directory = path })
  end

  it("persists, reads, and deletes JSON objects", function()
    local value = store()
    local entry = { models = { { id = "one" } }, checked_at = 12 }
    assert(value:write("llama.cpp", entry))
    assert.are.same(entry, value:read("llama.cpp"))
    assert(value:write("llama.cpp", { models = {} }))
    assert.are.same({ models = {} }, value:read("llama.cpp"))
    assert(value:delete("llama.cpp"))
    assert.is_nil(value:read("llama.cpp"))
    assert(value:delete("llama.cpp"))
  end)

  it("recovers from missing and malformed documents", function()
    local value = store()
    assert.is_nil(value:read("missing"))
    local path = value:path("broken")
    require("neoagent.fs").write_all(path, "{broken", "w", 384)
    local result, err = value:read("broken")
    assert.is_nil(result)
    assert.are.equal("state_store", err.kind)
    assert.matches("invalid JSON", err.message)
  end)

  it("rejects invalid ids and entries", function()
    local value = store()
    assert.has_error(function() value:read("../escape") end)
    local result, err = value:write("entry", { "list" })
    assert.is_nil(result)
    assert.are.equal("state_store", err.kind)
    result, err = value:write("entry", { bad = function() end })
    assert.is_nil(result)
    assert.are.equal("state_store", err.kind)
    result, err = value:write("entry", { text = "\255" })
    assert.is_nil(result)
    assert.matches("entry must contain", err.message)
  end)

  it("reports atomic write and cleanup failures", function()
    local value = store()
    local original_rename = vim.uv.fs_rename
    local original_unlink = vim.uv.fs_unlink
    vim.uv.fs_rename = function() return nil, "rename failed", "EIO" end
    vim.uv.fs_unlink = function() return true end
    local result, err = value:write("entry", { models = {} })
    vim.uv.fs_rename = original_rename
    vim.uv.fs_unlink = original_unlink
    assert.is_nil(result)
    assert.is_not_nil(err)

    value:write("entry", { models = {} })
    vim.fn.mkdir(value:path("directory"), "p")
    result, err = value:delete("directory")
    assert.is_nil(result)
    assert.is_not_nil(err)
  end)

  it("tolerates unusable state directories and reports failures through operations", function()
    local path = vim.fn.tempname()
    require("neoagent.fs").write_all(path, "file", "w", 384)
    directories[#directories + 1] = path
    local value = state_store.new({ directory = path })
    local entry, read_err = value:read("entry")
    assert.is_nil(entry)
    assert.are.equal("state_store", read_err.kind)
    local result, err = value:write("entry", { models = {} })
    assert.is_nil(result)
    assert.is_not_nil(err)

    local original_chmod = vim.uv.fs_chmod
    vim.uv.fs_chmod = function() return nil, "chmod failed" end
    local directory = vim.fn.tempname()
    vim.fn.delete(directory)
    local tolerated = state_store.new({ directory = directory })
    vim.uv.fs_chmod = original_chmod
    assert.is_not_nil(tolerated)
    result, err = tolerated:write("entry", { models = {} })
    assert.is_nil(result)
    assert.matches("private state directory", err.message)
    assert.is_nil(vim.uv.fs_stat(tolerated:path("entry")))
    vim.fn.delete(directory, "rf")
  end)
end)
