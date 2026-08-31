local Applet = require("applet")
local protocol = require("neoagent.ui.renderer")

local simple_renderer = {
  name = "simple",
  theme = Applet.Theme.new(),

  render_block = function(_, block)
    return Applet.Pane.nodes.text({
      key = "simple:block",
      text = block.text or block.summary or block.name or block.kind,
      wrap = "word",
    })
  end,

  render_details = function(self, block)
    return self:render_block(block)
  end,
}

local function lines(node)
  return assert(Applet.Pane.compile({
    tree = node,
    width = 40,
    theme = simple_renderer.theme,
  })).lines
end

describe("a minimal custom Renderer", function()
  it("returns native Pane content nodes for blocks and details", function()
    assert.are.equal(simple_renderer, protocol.validate(simple_renderer))
    assert.are.same({ "hello" }, lines(assert(protocol.render_block(
      simple_renderer, { kind = "assistant", text = "hello" }))))
    assert.are.same({ "first", "second" }, lines(assert(protocol.render_details(
      simple_renderer, { kind = "thinking", text = "first\nsecond" }))))
  end)
end)
