local file_lock = require("neoagent.file_lock")
local fs = require("neoagent.fs")

describe("neoagent Windows file locks", function()
  local paths = {}

  after_each(function()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  it("owns a stable Unicode lock path through a native handle", function()
    local directory = vim.fn.tempname() .. "-néo"
    paths[#paths + 1] = directory
    assert(fs.mkdirp(directory))
    local path = fs.join(directory, "resource.lock")

    local lease = assert(file_lock.new({ path = path }):acquire())
    local held = assert(vim.uv.fs_lstat(path))
    local first_token = assert(fs.read(path))
    assert(lease:release())

    local released = assert(vim.uv.fs_lstat(path))
    assert.are.equal(held.dev, released.dev)
    assert.are.equal(held.ino, released.ino)
    assert.are.equal(first_token, assert(fs.read(path)))

    lease = assert(file_lock.new({ path = path }):acquire())
    assert.is_not.equal(first_token, assert(fs.read(path)))
    assert(lease:release())
  end)
end)
