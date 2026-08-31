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

  it("reports semantic ranges and safe subdivisions for rendered documents", function()
    local result = markdown.render(table.concat({
      "first",
      "second",
      "",
      "```lua",
      "one",
      "two",
      "```",
      "",
      "| A |",
      "| --- |",
      "| b |",
    }, "\n"), { width = 40 })

    assert.are.same({
      { kind = "paragraph", first = 0, last = 2, splittable = true },
      { kind = "blank", first = 2, last = 3, splittable = true },
      { kind = "fence", first = 3, last = 7, splittable = true },
      { kind = "blank", first = 7, last = 8, splittable = true },
      { kind = "table", first = 8, last = 13, splittable = false },
    }, result.markdown_blocks)
  end)

  it("slices and tails documents with surface-local ranges", function()
    local document = markdown.new():update("first\n**second**\n\n", {
      width = 40,
    })

    assert.are.same({
      lines = { "second" },
      highlights = {
        {
          row = 0,
          col = 0,
          end_col = 6,
          group = "NeoagentMarkdownBold",
        },
      },
      markdown_blocks = {
        { kind = "paragraph", first = 0, last = 1, splittable = true },
      },
    }, document:slice(2, 2))

    local tail, omitted = document:tail(1)
    assert.are.same(document:slice(2, 2), tail)
    assert.are.equal(1, omitted)
    assert.are.equal(2, document:finish())
  end)

  it("retains completed regions while an incomplete tail grows", function()
    local document = markdown.new()
    local source = { "```lua" }
    for index = 1, 130 do
      source[#source + 1] = "value " .. index
    end
    document:update(table.concat(source, "\n"), { width = 40 })
    local first = document:regions(64)
    assert.are.equal(3, #first)
    assert.is_true(rawequal(first, document:regions(64)))
    local stable_first, stable_second, changing_tail =
      first[1], first[2], first[3]

    source[#source + 1] = "value 131"
    document:update(table.concat(source, "\n"), { width = 40 })
    local second = document:regions(64)

    assert.is_true(rawequal(stable_first, second[1]))
    assert.is_true(rawequal(stable_second, second[2]))
    assert.is_false(rawequal(changing_tail, second[3]))
    assert.are.same(markdown.render(table.concat(source, "\n"), {
      width = 40,
    }).lines, document:snapshot().lines)
  end)

  it("transfers retained content between equivalent stream submissions", function()
    local document = markdown.new()
    local source = { "```lua" }
    for index = 1, 70 do
      source[#source + 1] = "value " .. index
    end
    local text = table.concat(source, "\n")
    document:update(text, { width = 40 }, "initial-stream")
    local initial = document:regions(32)

    document:update(text, { width = 40 }, "replacement-stream")
    document:update(text .. "\nvalue 71", { width = 40 },
      "replacement-stream")
    local appended = document:regions(32)

    assert.is_true(rawequal(initial[1], appended[1]))
    assert.are.same(markdown.render(text .. "\nvalue 71", {
      width = 40,
    }).lines, document:snapshot().lines)
  end)

  it("packs retained regions around atomic and adjacent Markdown blocks", function()
    local document = markdown.new()
    document:update(table.concat({
      "plain one",
      "plain two",
      "| Value |",
      "| --- |",
      "| table row |",
      "tail one",
      "tail two",
      "```",
      "```",
    }, "\n"), { width = 40 })

    local regions = document:regions(3)
    assert.are.same({ 2, 5, 2, 2 }, vim.tbl_map(function(region)
      return region.last - region.first + 1
    end, regions))
    assert.are.same(document:snapshot().lines,
      vim.iter(regions):fold({}, function(lines, region)
        return vim.list_extend(lines, vim.tbl_map(function(row)
          return row.text
        end, region.rows))
      end))

    local exact = markdown.new():update("first\nsecond", { width = 40 })
    local exact_regions = exact:regions(2)
    assert.are.equal(1, #exact_regions)
    assert.are.same({ "first", "second" }, vim.tbl_map(function(row)
      return row.text
    end, exact_regions[1].rows))
  end)

  it("matches clean parses across streamed Markdown transitions", function()
    local chunks = {
      "plain text with a trailing ",
      "*",
      "italic* and **bo",
      "ld**\n| Name | Value |\n",
      "| --- | --- |\n| one | tw",
      "o |\n\n```lua\nlocal value = ",
      "1\n~",
      "~~\nafter [li",
      "nk](https://example.test)",
    }
    local document = markdown.new()
    local source = ""
    for _, chunk in ipairs(chunks) do
      source = source .. chunk
      document:update(source, { width = 50 }, "stream")
      local clean = markdown.render(source, { width = 50 })
      local incremental = document:snapshot()
      assert.are.same(clean.lines, incremental.lines)
      assert.are.same(clean.highlights, incremental.highlights)
      assert.are.equal(select(2, source:gsub("%S+", "")),
        document:word_count())
    end
  end)

  it("matches a clean parse at every byte boundary", function()
    local source = table.concat({
      "# Heading",
      "plain \\*literal* **bold** *italic* ~~strike~~ `code`",
      "> quote [link](https://example.test)",
      "- [x] task",
      "| Name | Value |",
      "| --- | --- |",
      "| one | two |",
      "```lua",
      "local value = 1",
      "```",
      "after",
    }, "\n")
    local document = markdown.new()
    for finish = 1, #source do
      local partial = source:sub(1, finish)
      document:update(partial, { width = 48 }, "byte-stream")
      local clean = markdown.render(partial, { width = 48 })
      local incremental = document:snapshot()
      assert.are.same(clean.lines, incremental.lines)
      assert.are.same(clean.highlights, incremental.highlights)
    end
  end)

  it("rebuilds retained documents for replacements and option changes", function()
    local document = markdown.new()
    document:update("| Name | Value |\n| --- | --- |\n| one | two |", {
      width = 50,
    }, "first-stream")
    for index, case in ipairs({
      {
        text = "replacement\n> quoted **text**",
        opts = { width = 50 },
      },
      {
        text = "+ marker\n---",
        opts = { width = 50, preserve_markers = true },
      },
      {
        text = "| Name | Value |\n| --- | --- |\n| wider | contents |",
        opts = { width = 8 },
      },
    }) do
      document:update(case.text, case.opts, "replacement-" .. index)
      local clean = markdown.render(case.text, case.opts)
      local incremental = document:snapshot()
      assert.are.same(clean.lines, incremental.lines)
      assert.are.same(clean.highlights, incremental.highlights)
    end
  end)
end)
