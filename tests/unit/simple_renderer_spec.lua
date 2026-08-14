local protocol = require("neoagent.ui.renderer")

local function content(text)
  return {
    lines = vim.split(tostring(text or ""), "\n", { plain = true }),
  }
end

local simple_renderer = {
  name = "simple",

  render_block = function(_, block)
    return content(block.text or block.summary or block.name or block.kind)
  end,

  render_details = function(self, block)
    return self:render_block(block)
  end,

  render_dialog = function(_, snapshot)
    return {
      content = content(snapshot.active.body),
      title = " " .. snapshot.active.title .. " ",
    }
  end,
}

describe("a minimal custom Renderer", function()
  it("presents blocks, details, and dialogs as plain text", function()
    assert.are.equal(simple_renderer, protocol.validate(simple_renderer))
    local block = assert(protocol.render_block(simple_renderer, {
      kind = "assistant", text = "hello",
    }))
    assert.are.same({ "hello" }, block.lines)

    local details = assert(protocol.render_details(simple_renderer, {
      kind = "thinking", text = "first\nsecond",
    }))
    assert.are.same({ "first", "second" }, details.lines)

    local dialog = assert(protocol.render_dialog(simple_renderer, {
      active = { title = "Confirm", body = "Continue?" },
      queue_count = 0,
    }))
    assert.are.same({ "Continue?" }, dialog.content.lines)
    assert.are.equal(" Confirm ", dialog.title)
  end)
end)
