local Session = require("neoagent.session")
local storage = require("neoagent.storage")

local function tempdir()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return path
end

describe("neoagent.storage", function()
  local dirs = {}

  after_each(function()
    for _, path in ipairs(dirs) do
      vim.fn.delete(path, "rf")
    end
    dirs = {}
  end)

  it("creates no file until the first message", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local store = storage.new({ directory = directory, cwd = directory })
    local path = store:metadata().path
    assert.is_nil(vim.uv.fs_stat(path))
    local session = assert(Session.new({ store = store }))
    assert.is_nil(vim.uv.fs_stat(path))
    assert(session:append({ role = "user", content = "hello", timestamp = 1 }))
    assert.is_not_nil(vim.uv.fs_stat(path))
  end)

  it("writes and resumes a linear pi v3 JSONL session", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local cwd = vim.uv.fs_realpath(directory)
    local store = storage.new({ directory = directory, cwd = cwd })
    assert(store:append({ role = "user", content = "one", timestamp = 1 }))
    assert(store:append({ role = "assistant", content = { { type = "text", text = "two" } }, timestamp = 2 }))
    local data = assert(require("neoagent.fs").read(store:metadata().path))
    local lines = vim.split(data, "\n", { plain = true, trimempty = true })
    local header = vim.json.decode(lines[1])
    local first = vim.json.decode(lines[2])
    local second = vim.json.decode(lines[3])
    assert.are.equal("session", header.type)
    assert.are.equal(3, header.version)
    assert.are.equal(cwd, header.cwd)
    assert.are.equal(vim.NIL, first.parentId)
    assert.are.equal(first.id, second.parentId)

    local reopened = assert(storage.open(store:metadata().path))
    assert.are.equal(2, #reopened:load())
    assert.are.equal(store:metadata().id, reopened:metadata().id)
    assert.are.same({ store:metadata().path }, storage.list(directory, cwd))
  end)

  it("rejects incomplete and branching input without rewriting it", function()
    local directory = tempdir()
    dirs[#dirs + 1] = directory
    local path = directory .. "/bad.jsonl"
    vim.fn.writefile({ "{}" }, path, "b")
    local _, incomplete = storage.open(path)
    assert.matches("incomplete", incomplete.detail)

    local header = vim.json.encode({ type = "session", version = 3, id = "s", timestamp = "t", cwd = directory })
    local first = vim.json.encode({
      type = "message", id = "one", parentId = vim.NIL, timestamp = "t",
      message = { role = "user", content = "one" },
    })
    local branch = vim.json.encode({
      type = "message", id = "two", parentId = vim.NIL, timestamp = "t",
      message = { role = "user", content = "two" },
    })
    vim.fn.writefile({ header, first, branch }, path)
    local _, err = storage.open(path)
    assert.matches("parent", err.detail)
  end)
end)
