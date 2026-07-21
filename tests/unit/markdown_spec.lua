local markdown = require("neoagent.markdown")

local function groups(result)
  local found = {}
  for _, span in ipairs(result.highlights) do found[span.group] = true end
  return found
end

describe("neoagent markdown", function()
  it("renders common block and inline Markdown", function()
    local result = markdown.render(table.concat({
      "# Heading",
      "",
      "Text with **bold**, *italic*, ~~gone~~, `code`, and [docs](https://example.test).",
      "> quoted *text*",
      "- [x] done",
      "3) ordered",
      "---",
    }, "\n"), { width = 40 })
    assert.are.same({
      "Heading",
      "",
      "Text with bold, italic, gone, code, and docs (https://example.test).",
      "│ quoted text",
      "- [x] done",
      "3) ordered",
      string.rep("─", 40),
    }, result.lines)
    local found = groups(result)
    for _, group in ipairs({
      "NeoagentMarkdownHeading", "NeoagentMarkdownBold", "NeoagentMarkdownItalic",
      "NeoagentMarkdownStrike", "NeoagentMarkdownCode", "NeoagentMarkdownLink",
      "NeoagentMarkdownLinkUrl", "NeoagentMarkdownQuote", "NeoagentMarkdownQuoteBorder",
      "NeoagentMarkdownListBullet", "NeoagentMarkdownHr", "NeoagentMarkdownUnderline",
    }) do assert.is_true(found[group], group) end
  end)

  it("renders fenced code without flickering on a partial closing fence", function()
    local complete = markdown.render("```lua\nlocal x = 1\n```\nafter")
    assert.are.same({ "```lua", "  local x = 1", "```", "after" }, complete.lines)
    local partial = markdown.render("~~~\none\n~~")
    assert.are.same({ "```", "  one", "```" }, partial.lines)
    local found = groups(complete)
    assert.is_true(found.NeoagentMarkdownCodeBorder)
    assert.is_true(found.NeoagentMarkdownCodeBlock)
  end)

  it("renders fitting tables and falls back safely in narrow windows", function()
    local source = "| Name | Value |\n| --- | --- |\n| **one** | two |"
    local wide = markdown.render(source, { width = 40 })
    assert.matches("^┌", wide.lines[1])
    assert.matches("one", table.concat(wide.lines, "\n"))
    assert.is_true(groups(wide).NeoagentMarkdownTableBorder)
    local narrow = markdown.render(source, { width = 5 })
    assert.are.equal("| Name | Value |", narrow.lines[1])
  end)

  it("keeps incomplete markup readable and handles escapes, images, and marker options", function()
    local result = markdown.render("\\*literal* and **open and `tick\n![alt](image.png)\ninvalid ~~ spaced ~~ strike\n+ plus", {
      preserve_markers = true,
    })
    assert.are.equal("*literal* and **open and `tick", result.lines[1])
    assert.are.equal("[image: alt] (image.png)", result.lines[2])
    assert.are.equal("invalid ~~ spaced ~~ strike", result.lines[3])
    assert.are.equal("+ plus", result.lines[4])
    assert.are.same({}, markdown.render(" \n ").lines)
    assert.are.equal("a_b_c", markdown.render("a_b_c").lines[1])
  end)
end)
