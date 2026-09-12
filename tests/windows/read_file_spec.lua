local assert = require("luassert")
local fs = require("neoagent.fs")
local fake = require("tests.helpers.fake_model")
local attachments = require("tests.helpers.attachments")

describe("neoagent Windows image filenames", function()
  if jit.os ~= "Windows" then
    pending("requires Windows")
    return
  end

  ---@type string?
  local directory
  ---@type Neoagent.ChatRun?
  local run
  after_each(function()
    if run and not run:is_done() then
      run:cancel()
      assert(vim.wait(1000, function() return assert(run):is_done() end))
    end
    if directory then vim.fn.delete(directory, "rf") end
  end)

  it("commits an image read from a native long Unicode filename", function()
    directory = vim.fn.tempname()
    assert(fs.mkdirp(directory))
    local filename = string.rep("界", 200) .. ".png"
    local png = vim.base64.decode("iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAAAIklEQVR4nGP4z8BAEiJR+X9SlY9aMGrBqAWjFoxaMCAWAABQpv4QX+h4RQAAAABJRU5ErkJggg==")
    local path = fs.join(directory, filename)
    assert(fs.write_all(path, png))
    local source = attachments.new()
    local session = assert(require("neoagent.session").new({ files = source.files }))
    local model = fake.new({
      { result = fake.assistant({ { type = "toolCall", id = "read-1", name = "read_file",
        arguments = { path = filename } } }, "toolUse") },
      { result = fake.assistant({ { type = "text", text = "Finished." } }) },
    })
    run = require("neoagent.chat").run(session, "Inspect the image.", {
      model = model, tools = { require("neoagent.tools.read_file").new() },
      context = { files = session:files(), workspace = require("neoagent.workspace").new({
        root = directory, cwd = directory,
      }) },
    })
    assert(vim.wait(5000, function() return assert(run):is_done() end))
    assert.is_true(assert(run:result()).ok)
    local result = assert(session:messages()[3])
    assert(result.role == "toolResult")
    assert.is_false(result.isError, vim.inspect(result.content))
    local image = assert(result.content[2])
    assert(image.type == "image")
    assert.is_nil(image.filename)
    assert(vim.uv.fs_unlink(path))
    assert.are.equal(image.bytes, #source.read(image))
    assert.are.same(result, assert(model.requests[2]).messages[3])
  end)
end)
