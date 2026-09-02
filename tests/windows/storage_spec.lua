local fs = require("neoagent.fs")
local storage = require("neoagent.storage")

describe("neoagent Windows Session persistence", function()
  local paths = {}

  after_each(function()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  it("appends and recovers through verified regular handles", function()
    local directory = vim.fn.tempname() .. "-néo-session"
    paths[#paths + 1] = directory
    assert(fs.mkdirp(directory))
    local store = storage.new({ directory = directory, cwd = directory })
    assert(store:append({ role = "user", content = "first" }))
    assert(store:append({
      role = "assistant",
      content = { { type = "text", text = "second" } },
    }))
    local path = store:metadata().path
    local complete = assert(fs.read(path))

    local reopened = assert(storage.open(path))
    assert.are.same(store:entries(), reopened:entries())
    assert(fs.write_all(path, '{"type":"message"', "a", 384))
    reopened = assert(storage.open(path))
    assert.are.equal(complete, assert(fs.read(path)))
    assert.are.same(store:entries(), reopened:entries())
  end)
end)
