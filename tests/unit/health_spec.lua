local fs = require("neoagent.fs")

describe("neoagent health", function()
  local original_health
  local original_path
  local roots = {}
  local messages

  local function contains(values, pattern)
    for _, value in ipairs(values) do
      if value:match(pattern) then return true end
    end
    return false
  end

  before_each(function()
    original_health = vim.health
    original_path = vim.env.PATH
    messages = { ok = {}, error = {}, warn = {}, start = {} }
    vim.health = {}
    for kind in pairs(messages) do
      vim.health[kind] = function(value) messages[kind][#messages[kind] + 1] = value end
    end
    require("neoagent.config")._reset()
  end)

  after_each(function()
    vim.health = original_health
    vim.env.PATH = original_path
    require("neoagent.config")._reset()
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots = {}
  end)

  it("reports dependency versions and a valid configuration", function()
    require("neoagent.config").setup({ persistence = { enabled = false } })
    require("neoagent.health").check()
    assert.are.same({ "neoagent" }, messages.start)
    assert.is_true(contains(messages.ok, "curl .- satisfies"))
    assert.is_true(contains(messages.ok, "^configuration is valid$"))
  end)

  it("reports an old curl, missing tools, and an invalid resolved model", function()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    vim.fn.mkdir(root, "p")
    local curl = root .. "/curl"
    assert(fs.write_all(curl, "#!/bin/sh\nprintf 'curl 7.75.0 fake\\n'\n", "w"))
    assert(vim.uv.fs_chmod(curl, 493))
    vim.env.PATH = root
    require("neoagent.config").setup({
      default_model = { provider = "missing", model = "missing" },
      persistence = { enabled = false },
    })
    require("neoagent.health").check()
    assert.is_true(contains(messages.error, "too old"))
    assert.is_true(contains(messages.error, "rg is required"))
    assert.is_true(contains(messages.warn, "magick"))
    assert.is_true(contains(messages.error, "configuration error"))
  end)

  it("accepts the exact minimum curl version and rejects unknown output", function()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    vim.fn.mkdir(root, "p")
    local curl = root .. "/curl"
    assert(fs.write_all(curl, "#!/bin/sh\nprintf 'curl 7.76.0 exact\\n'\n", "w"))
    assert(vim.uv.fs_chmod(curl, 493))
    vim.env.PATH = root
    require("neoagent.config").setup({ persistence = { enabled = false } })
    require("neoagent.health").check()
    assert.is_true(contains(messages.ok, "curl 7.76.0 satisfies"))

    messages.error = {}
    assert(fs.write_all(curl, "#!/bin/sh\nprintf 'unknown version\\n'\n", "w"))
    require("neoagent.health").check()
    assert.is_true(contains(messages.error, "could not determine"))
  end)
end)
