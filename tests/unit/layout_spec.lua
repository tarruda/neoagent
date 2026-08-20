local layout = require("neoagent.ui.layout")

describe("neoagent UI layout provider regions", function()
  local base = {
    columns = 120,
    lines = 40,
    position = "center",
    margin = 0,
    input_height = 7,
    border = "rounded",
  }

  it("splits a right provider column inside the transcript row", function()
    local configs, err = layout.layout(vim.tbl_extend("force", base, {
      provider = true,
      provider_position = "right",
      provider_width = 0.4,
    }))
    assert(configs, err)
    assert.is_true(configs.transcript.width < configs.input.width)
    assert.are.equal(configs.transcript.row, configs.provider.row)
    assert.are.equal(configs.transcript.height, configs.provider.height)
    assert.are.equal(configs.transcript.col + configs.transcript.width + 1,
      configs.provider.col)
    assert.are.equal(configs.transcript.row + configs.transcript.height + 2,
      configs.input.row)
  end)

  it("splits a bottom provider region above the input", function()
    local configs, err = layout.layout(vim.tbl_extend("force", base, {
      provider = true,
      provider_position = "bottom",
      provider_height = 0.4,
    }))
    assert(configs, err)
    assert.are.equal(configs.transcript.width, configs.provider.width)
    assert.are.equal(configs.transcript.col, configs.provider.col)
    assert.are.equal(configs.transcript.row + configs.transcript.height + 2,
      configs.provider.row)
    assert.are.equal(configs.provider.row + configs.provider.height + 2,
      configs.input.row)
  end)

  it("splits a top provider region above the transcript", function()
    local configs = assert(layout.layout(vim.tbl_extend("force", base, {
      provider = true,
      provider_position = "top",
      provider_height = 0.35,
    })))
    assert.are.equal(configs.provider.width, configs.transcript.width)
    assert.are.equal(configs.transcript.width, configs.input.width)
    assert.are.equal(configs.provider.col, configs.transcript.col)
    assert.are.equal(configs.provider.row + configs.provider.height + 2,
      configs.transcript.row)
    local ordinary = assert(layout.layout(base))
    assert.are.equal(ordinary.input.row, configs.input.row)
  end)

  it("rejects provider regions that no longer fit", function()
    local narrow = vim.tbl_extend("force", base, { columns = 14 })
    assert.is_nil(layout.layout(vim.tbl_extend("force", narrow, {
      provider = true,
      provider_position = "right",
      provider_width = 0.4,
    })))
    local tiny = vim.tbl_extend("force", base, { lines = 10 })
    assert.is_nil(layout.layout(vim.tbl_extend("force", tiny, {
      provider = true,
      provider_position = "bottom",
      provider_height = 1,
    })))
  end)

  it("keeps ordinary layouts unchanged when the console is closed", function()
    local configs, err = layout.layout(base)
    assert(configs, err)
    assert.is_nil(configs.provider)
    assert.are.equal(112, configs.transcript.width)
  end)
end)
