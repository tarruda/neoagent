local assert = require("luassert")
local fs = require("neoagent.fs")
local limits = require("neoagent.tools.limits")

describe("bundled Tool input boundaries", function()
  ---@type string
  local root
  local encode
  local maximum_values

  before_each(function()
    root = assert(fs.create_temp_directory("neoagent-inputs-"))
    encode = vim.mpack.encode
    maximum_values = limits.MAX_INPUT_VALUES
  end)

  after_each(function()
    vim.mpack.encode = encode
    limits.MAX_INPUT_VALUES = maximum_values
    vim.fn.delete(root, "rf")
  end)

  local function context()
    return {
      context = { workspace = { root = root, cwd = root } },
      on_update = function() end,
    } --[[@as Neoagent.ToolContext<unknown>]]
  end

  it("writes locally without serializing the request", function()
    vim.mpack.encode = function() error("local effects entered the wire encoder") end
    local result = require("neoagent.tools.write_file").new().execute({
      path = "local.txt", content = "local content",
    }, context())
    assert.is_nil(result.isError)
    assert.are.equal("local content", fs.read(root .. "/local.txt"))
  end)

  it("bounds request structure before editing even when text is small", function()
    local path = root .. "/edit.txt"
    assert(fs.write_all(path, "one two"))
    limits.MAX_INPUT_VALUES = 12
    local accepted, failure = pcall(require("neoagent.tools.edit_file").new().execute, {
      path = "edit.txt", edits = {
        { oldText = "one", newText = "ONE" },
        { oldText = "two", newText = "TWO" },
      },
    }, context())
    assert.is_false(accepted)
    assert.matches("aggregate request limit", tostring(failure), 1, true)
    assert.are.equal("one two", fs.read(path))
  end)
end)
