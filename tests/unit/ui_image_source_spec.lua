local assert = require("luassert")
local async = require("neoagent.async")
local files = require("neoagent.files")
local images = require("neoagent.ui.image_source")
local attachments = require("tests.helpers.attachments")
local util = require("neoagent.util")

describe("View attachment readers", function()
  ---@param reader Applet.ImageResourceReader
  ---@param source Applet.PngResource
  ---@param maximum integer
  ---@return string?, string?
  local function read(reader, source, maximum)
    local completed, data, failure = false, nil, nil
    local cancel = reader(source, maximum, function(value, err)
      completed, data, failure = true, value, err
    end)
    if not vim.wait(1000, function() return completed end) then
      cancel()
      error("Image reader did not complete")
    end
    cancel()
    return data, failure
  end

  it("creates plain descriptors without reading and shares content independently of occurrence", function()
    assert.is_nil((images.new()))
    local incomplete = attachments.new().files
    rawset(incomplete, "open", false)
    assert.has_error(function() images.new(incomplete) end)
    local fixture = attachments.new()
    local image = fixture.image("synthetic PNG bytes", "image/png", { id = "first", revision = 1 })
    local source = util.copy(fixture.files)
    local opens, open = 0, source.open
    source.open = function(...)
      opens = opens + 1
      return open(...)
    end
    local factory, reader = images.new(source)
    local first = assert(factory)(image)
    image.id, image.revision = "second", 2
    assert.are.same(first, assert(factory)(image))
    assert.are.equal(0, opens)
    assert.are.equal("png_resource", first.kind)
    assert.are.equal("synthetic PNG bytes", read(assert(reader), first --[[@as Applet.PngResource]], 1024))
    assert.are.equal(1, opens)
    local other_factory, other_reader = images.new(attachments.new().files)
    assert.are_not.same(first, assert(other_factory)(image))
    local bytes, err = read(assert(other_reader), first --[[@as Applet.PngResource]], 1024)
    assert.is_nil(bytes)
    assert.matches("different file store", assert(err))
  end)

  it("reports missing, malformed, oversized and inconsistent attachment references", function()
    local fixture = attachments.new()
    local image = fixture.image("image")
    local factory, reader = images.new(fixture.files)
    local source = assert(factory)(image) --[[@as Applet.PngResource]]
    ---@param id? string
    ---@param revision? integer
    ---@return Applet.PngResource
    local function reference(id, revision)
      return { kind = "png_resource", id = id or source.id,
        revision = revision or source.revision }
    end
    ---@type {source: Applet.PngResource, maximum: integer, error: string}[]
    local variants = {
      { source = source, maximum = 4, error = "byte limit" },
      { source = reference(nil, 6), maximum = 100, error = "size does not match" },
      { source = reference(nil, 0), maximum = 100, error = "byte count" },
      { source = reference(fixture.files.identity .. ":invalid"), maximum = 100, error = "file ID" },
      { source = reference(fixture.files.identity .. ":" .. string.rep("0", 64)), maximum = 100, error = "missing" },
    }
    for _, case in ipairs(variants) do
      local bytes, err = read(assert(reader), case.source, case.maximum)
      assert.is_nil(bytes)
      assert.matches(case.error, assert(err))
    end
    local corrupt = util.copy(fixture.files)
    corrupt.open = function(_, maximum)
      return files.reader({ file_id = image.file_id, bytes = image.bytes }, maximum, function() return "other" end, function() return true end)
    end
    local _, corrupt_reader = images.new(corrupt)
    local bytes, err = read(assert(corrupt_reader), source, 100)
    assert.is_nil(bytes)
    assert.matches("does not match its file ID", assert(err))
  end)

  it("cancels an in-flight read once and suppresses its late completion", function()
    local fixture = attachments.new()
    local image = fixture.image("image")
    local source = util.copy(fixture.files)
    local closes, delivered = 0, 0
    ---@type Neoagent.AwaitCallbacks<string>?
    local pending
    source.open = function(_, maximum)
      return files.reader({ file_id = image.file_id, bytes = image.bytes }, maximum, function()
        return async.await(function(done) pending = done end)
      end, function() closes = closes + 1; return true end)
    end
    local factory, reader = images.new(source)
    local cancel = assert(reader)(assert(factory)(image) --[[@as Applet.PngResource]], 100,
      function() delivered = delivered + 1 end)
    assert(vim.wait(1000, function() return pending ~= nil end))
    cancel()
    cancel()
    assert.are.equal(1, closes)
    assert(pending).resolve("image")
    local drained = false
    vim.schedule(function() drained = true end)
    assert(vim.wait(1000, function() return drained end))
    assert.are.equal(0, delivered)
    assert.are.equal(1, closes)
  end)
end)
