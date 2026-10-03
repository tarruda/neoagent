local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local fs = require("neoagent.fs")

describe("read_file with native ImageMagick", function()
  if vim.fn.executable("magick") ~= 1 then
    pending("requires ImageMagick")
    return
  end
  ---@type string
  local directory
  before_each(function()
    directory = vim.fn.tempname()
    assert(fs.mkdirp(directory))
  end)
  after_each(function()
    vim.fn.delete(directory, "rf")
  end)

  local function read(path)
    local attachments = require("tests.helpers.attachments").new()
    return helper.complete(function()
      return require("neoagent.tools.read_file").new().execute({ path = path }, {
        context = {
          workspace = require("neoagent.workspace").new({ root = directory, cwd = directory }),
          files = attachments.files,
        },
      })
    end, 10000)
  end

  it("accepts successful partial consumption of an animated image", function()
    local path = directory .. "/animated.gif"
    local created = vim
      .system(
        {
          "magick",
          "-seed",
          "1",
          "-size",
          "128x128",
          "xc:",
          "+noise",
          "Random",
          "-colors",
          "256",
          "-duplicate",
          "127",
          path,
        },
        { timeout = 5000 }
      )
      :wait()
    assert.are.equal(0, created.code, created.stderr or "")
    assert.is_true(assert(vim.uv.fs_stat(path)).size > 1024 * 1024)
    local result = read(path)
    assert.is_nil(result.error, vim.inspect(result))
    assert.are.equal("image", result.content[2].type)
    assert.are.equal("image/png", result.content[2].mime_type)
  end)

  it("still rejects an invalid image when its decoder closes input early", function()
    local path = directory .. "/broken.gif"
    assert(fs.write_all(path, "GIF89a" .. ("\0"):rep(2 * 1024 * 1024)))
    local result = read(path)
    assert.is_false(result.ok)
    assert.matches("could not inspect image dimensions", assert(result.error).message, 1, true)
  end)
end)
