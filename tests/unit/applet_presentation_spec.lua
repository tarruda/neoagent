local presentation = require("applet.presentation")

local function picker(opts)
  opts = opts or {}
  return presentation.new({
    request = {
      id = "picker",
      kind = "select",
      prompt = "Choose",
      items = opts.items or {
        { id = "alpha", label = "Alpha" },
        { id = "beta", label = "Beta" },
      },
    },
    on_choose = function() end,
    on_cancel = function() end,
    on_results = opts.on_results,
  })
end

describe("Applet dynamic presentations", function()
  local values

  after_each(function()
    for _, value in ipairs(values or {}) do value:destroy() end
    values = {}
  end)

  it("replaces picker items while preserving valid selection identity", function()
    local snapshots = {}
    local value = picker({
      on_results = function(snapshot) snapshots[#snapshots + 1] = snapshot end,
    })
    values = { value }

    assert.are.same({ query = "", count = 2, selected = "alpha" }, snapshots[1])
    assert.are.equal(2, value:set_items({
      { id = "alpha", label = "Alpha revised" },
      { id = "beta", label = "Beta revised" },
    }))
    assert.are.same({ query = "", count = 2, selected = "alpha" }, snapshots[2])
    assert.are.equal("alpha", value.selected)

    assert.are.equal(1, value:set_items({
      { id = "gamma", label = "Gamma" },
    }))
    assert.are.same({ query = "", count = 1, selected = "gamma" }, snapshots[3])
    assert.are.equal("gamma", value.selected)

    assert.are.equal(1, value:set_items({
      { id = "disabled", label = "Disabled", disabled = true },
    }))
    assert.are.same({ query = "", count = 1, selected = nil }, snapshots[4])
    assert.is_false(value:is_destroyed())
    value:destroy()
    assert.is_true(value:is_destroyed())
  end)

  it("validates replacement items at the presentation boundary", function()
    local value = picker()
    local input = presentation.new({
      request = { id = "input", kind = "input", prompt = "Input" },
      on_choose = function() end,
      on_cancel = function() end,
    })
    values = { value, input }

    assert.has_error(function() input:set_items({}) end,
      "presentation items: require a selection presentation")
    assert.has_error(function() value:set_items(false) end,
      "presentation items: must be a list")
    assert.has_error(function() value:set_items({ named = true }) end,
      "presentation items: must be a list")
    assert.has_error(function() value:set_items({ false }) end,
      "presentation item 1: must be a table")
    assert.has_error(function() value:set_items({ { label = "Missing" } }) end,
      "presentation item 1: requires an id")
    assert.has_error(function() value:set_items({ { id = "missing" } }) end,
      "presentation item 1: requires a label")
    assert.has_error(function()
      value:set_items({ { id = "detail", label = "Detail", detail = true } })
    end, "presentation item 1.detail: must be a string")
    assert.has_error(function()
      value:set_items({ { id = "disabled", label = "Disabled", disabled = 1 } })
    end, "presentation item 1.disabled: must be a boolean")
    assert.has_error(function()
      value:set_items({
        { id = "same", label = "First" },
        { id = "same", label = "Second" },
      })
    end, "presentation item 2: id must be unique")
  end)
end)
