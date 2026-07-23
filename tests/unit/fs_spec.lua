local fs = require("neoagent.fs")

describe("neoagent.fs", function()
  local original

  before_each(function()
    original = {
      stat = vim.uv.fs_stat,
      open = vim.uv.fs_open,
      read = vim.uv.fs_read,
      write = vim.uv.fs_write,
      close = vim.uv.fs_close,
      mkdir = vim.fn.mkdir,
    }
  end)

  after_each(function()
    vim.uv.fs_stat = original.stat
    vim.uv.fs_open = original.open
    vim.uv.fs_read = original.read
    vim.uv.fs_write = original.write
    vim.uv.fs_close = original.close
    vim.fn.mkdir = original.mkdir
  end)

  it("reports open and read failures and closes opened files", function()
    vim.uv.fs_stat = function() return { type = "file", size = 4 } end
    vim.uv.fs_open = function() return nil, "open denied" end
    local data, err = fs.read("file")
    assert.is_nil(data)
    assert.are.equal("open denied", err)

    local closed = false
    vim.uv.fs_open = function() return 7 end
    vim.uv.fs_read = function() return nil, "read failed" end
    vim.uv.fs_close = function(fd) closed = fd == 7 return true end
    data, err = fs.read("file")
    assert.is_nil(data)
    assert.are.equal("read failed", err)
    assert.is_true(closed)
  end)

  it("reports directory creation failures", function()
    assert.is_true(fs.mkdirp(""))
    vim.fn.mkdir = function() error("mkdir failed") end
    local ok, err = fs.mkdirp("directory")
    assert.is_nil(ok)
    assert.matches("mkdir failed", tostring(err))

    vim.fn.mkdir = function() return 0 end
    vim.uv.fs_stat = function() return nil end
    ok, err = fs.mkdirp("directory")
    assert.is_nil(ok)
    assert.are.equal("failed to create directory", err)
  end)

  it("reports write open, write, and close failures", function()
    vim.uv.fs_open = function() return nil, "open failed" end
    local ok, err = fs.write_all("file", "data")
    assert.is_nil(ok)
    assert.are.equal("open failed", err)

    local closes = 0
    vim.uv.fs_open = function() return 8 end
    vim.uv.fs_write = function() return nil, "write failed" end
    vim.uv.fs_close = function() closes = closes + 1 return true end
    ok, err = fs.write_all("file", "data")
    assert.is_nil(ok)
    assert.are.equal("write failed", err)
    assert.are.equal(1, closes)

    vim.uv.fs_write = function(_, data) return #data end
    vim.uv.fs_close = function() return nil, "close failed" end
    ok, err = fs.write_all("file", "data")
    assert.is_nil(ok)
    assert.are.equal("close failed", err)
  end)
end)
