local assert = require("luassert")
local input = require("applet.pane.input")
local TargetIndex = require("applet.pane.target_index")

---@param targets table<string, Applet.InputTarget>
---@param order string[]
---@return Applet.InputLayout
local function layout(targets, order)
  return { targets = targets, target_order = order, hit_order = order, scopes = {}, binding_pairs = {} }
end

describe("Pane target index", function()
  it("matches hit precedence and nearest-menu behavior across overlapping rectangles", function()
    local seed = 73
    ---@param maximum integer
    ---@return integer
    local function random(maximum)
      seed = seed * 48271 % 2147483647
      return math.floor(seed % maximum)
    end
    ---@type table<string, Applet.InputTarget>
    local targets = {}
    local order = {}
    for index = 1, 80 do
      local key = "target-" .. index
      local rectangles = {}
      for _ = 1, random(4) + 1 do
        rectangles[#rectangles + 1] = {
          row = random(200) - 20,
          col = random(30) - 5,
          height = random(30),
          width = random(25),
        }
      end
      targets[key] = {
        key = key,
        rectangles = rectangles,
        disabled = index % 7 == 0,
        role = index % 5 == 0 and "menuitem" or nil,
      }
      table.insert(order, 1, key)
    end
    local value = layout(targets, order)
    local index = TargetIndex.new()
    index:refresh(value)
    index:refresh(value)
    for _ = 1, 500 do
      local row, col = random(250) - 30, random(60) - 10
      assert.are.equal(input.target_at(value, row, col), index:at(row, col))
    end
  end)

  it("updates changed targets and ordering while removing obsolete entries", function()
    local first = { key = "first", rectangles = { { row = 0, col = 0, width = 3, height = 1 } } }
    local second = { key = "second", rectangles = { { row = 0, col = 0, width = 3, height = 1 } } }
    local index = TargetIndex.new()
    index:refresh(layout({ first = first, second = second }, { "first", "second", "first" }))
    assert.are.equal(first, index:at(0, 0))
    index:refresh(layout({ first = first, second = second }, { "second", "first" }))
    assert.are.equal(second, index:at(0, 0))
    local moved = { key = "second", rectangles = { { row = 200, col = 0, width = 3, height = 1 } } }
    index:refresh(layout({ second = moved }, { "missing", "second" }))
    assert.is_nil(index:at(0, 0))
    assert.are.equal(moved, index:at(200, 0))
    index:refresh(layout({}, {}))
    assert.is_nil(index:at(200, 0))
  end)

  it("bounds indexing for tall rectangles and keeps menu-distance ties in hit order", function()
    local large = { key = "large", rectangles = { { row = -1, col = 0, width = 2, height = 100000000 } } }
    local first = { key = "first", role = "menuitem", rectangles = { { row = 3, col = 4, width = 1, height = 1 } } }
    local second = { key = "second", role = "menuitem", rectangles = { { row = 3, col = 8, width = 1, height = 1 } } }
    local index = TargetIndex.new()
    index:refresh(layout({ large = large, first = first, second = second }, { "large", "second", "first" }))
    assert.are.equal(large, index:at(9999999, 0))
    assert.are.equal(second, index:at(3, 6))
    assert.are.equal(first, index:at(3, 3))
    index:refresh(layout({ first = first }, { "first" }))
    assert.is_nil(index:at(9999999, 0))
    assert.are.equal(first, index:at(3, 4))
  end)
end)
