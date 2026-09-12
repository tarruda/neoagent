local assert = require("luassert")
local presentation = require("applet.presentation")

---@param opts? {items?: Applet.PresentationItem[], on_results?: (fun(snapshot: Applet.PickerResults))}
---@return Applet.Presentation
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
  ---@type Applet.Presentation[]
  local values = {}

  after_each(function()
    for _, value in ipairs(values or {}) do value:destroy() end
    values = {}
  end)

  it("replaces picker items while preserving valid selection identity", function()
    ---@type Applet.PickerResults[]
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
    local dispatch = require("applet.pane.input").dispatch_action
    local action = require("applet").Pane.nodes.action
    assert(dispatch(value.pane, action("presentation.move", { direction = 1 }), nil, 1, "n", 0, 0))
    assert.are.equal("beta", value.selected)
    assert(dispatch(value.pane, action("presentation.move", { direction = 1 }), nil, 1, "n", 0, 0))
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
    assert.is_false(dispatch(value.pane, action("presentation.move", { direction = 1 }), nil, 1, "n", 0, 0))
    assert.is_false(value:is_destroyed())
    value:destroy()
    assert.is_true(value:is_destroyed())
  end)

  it("settles a presentation once when cancellation is dispatched repeatedly", function()
    local cancelled, selected = 0, 0
    local value = presentation.new({
      request = { id = "cancel-once", kind = "select", prompt = "Choose",
        items = { { id = "alpha", label = "Alpha" } } },
      on_choose = function() selected = selected + 1 end,
      on_cancel = function() cancelled = cancelled + 1 end,
    })
    values = { value }
    local dispatch = require("applet.pane.input").dispatch_action
    local action = require("applet").Pane.nodes.action
    assert.is_true(dispatch(value.pane, action("presentation.cancel"), nil, 1, "n", 0, 0))
    assert.is_false(dispatch(value.pane, action("presentation.cancel"), nil, 1, "n", 0, 0))
    assert.is_false(dispatch(value.pane, action("presentation.choose"), nil, 1, "n", 0, 0))
    assert.are.equal(1, cancelled)
    assert.are.equal(0, selected)
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
    local invalid = {
      { value = false, message = "presentation items: must be a list" },
      { value = { named = true }, message = "presentation items: must be a list" },
      { value = { false }, message = "presentation item 1: must be a table" },
      { value = { { label = "Missing" } }, message = "presentation item 1: requires an id" },
      { value = { { id = "missing" } }, message = "presentation item 1: requires a label" },
      { value = { { id = "detail", label = "Detail", detail = true } },
        message = "presentation item 1.detail: must be a string" },
      { value = { { id = "disabled", label = "Disabled", disabled = 1 } },
        message = "presentation item 1.disabled: must be a boolean" },
    }
    for _, case in ipairs(invalid) do
      assert.has_error(function()
        value:set_items(case.value --[[@as Applet.PresentationItem[] ]])
      end, case.message)
    end
    assert.has_error(function()
      value:set_items({
        { id = "same", label = "First" },
        { id = "same", label = "Second" },
      })
    end, "presentation item 2: id must be unique")
  end)
end)
