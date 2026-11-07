local assert = require("luassert")
local Applet = require("applet")
local compiler = require("applet.pane.compile")
local util = require("applet.util")
local ui = Applet.Pane.nodes

describe("Pane text fragment reuse", function()
  local validate_text = util.validate_text
  local ambiwidth = vim.o.ambiwidth
  after_each(function()
    util.validate_text = validate_text
    vim.o.ambiwidth = ambiwidth
  end)

  ---@param header string
  ---@param revision integer
  ---@param body string
  ---@return Applet.RegionNode
  local function document(header, revision, body)
    return ui.region({
      key = "tool",
      revision = revision,
      child = ui.target({
        key = "tool:target",
        child = ui.column({
          key = "tool:content",
          children = {
            ui.text({ key = "tool:header", text = header, wrap = "native", background = "NormalFloat" }),
            ui.source({
              key = "tool:source",
              language = "lua",
              child = ui.text({ key = "tool:body", text = body, wrap = "native", background = "NormalFloat" }),
            }),
          },
        }),
      }),
    })
  end

  it("reuses unchanged body text while an animated header changes", function()
    local cache = {}
    local body = ("stable body\n"):rep(100)
    local first = compiler.compile({ tree = document("Working 1", 1, body), width = 40, cache = cache })
    local validations = 0
    util.validate_text = function(value, path)
      if value == body then
        validations = validations + 1
      end
      return validate_text(value, path)
    end
    local second = compiler.compile({
      tree = document("Working 2", 2, body),
      width = 40,
      cache = cache,
      previous = first,
    })
    assert.are.equal(0, validations, "an animation recompiled unchanged body text")
    assert.are.equal("Working 1", first.lines[1])
    assert.are.equal("Working 2", second.lines[1])
    assert.are.same(first.coverage, second.coverage)
    assert.are.equal(1, #second.target_order)
    assert.are.equal(1, #second.source_ranges)
    assert.are.equal("tool:target", second.target_order[1])
    assert.are.equal(1, assert(assert(second.targets["tool:target"]).rectangles[2]).row)
  end)

  it("invalidates text reuse when native display widths change", function()
    local cache = {}
    local function content(revision)
      return ui.region({
        key = "ambiguous",
        revision = revision,
        child = ui.text({ key = "ambiguous:text", text = "·", wrap = "native" }),
      })
    end
    vim.o.ambiwidth = "single"
    local first = compiler.compile({ tree = content(1), width = 30, cache = cache })
    vim.o.ambiwidth = "double"
    local second = compiler.compile({ tree = content(2), width = 30, cache = cache, previous = first })
    assert.are.equal(1, assert(assert(first.coverage[0])[1]).last)
    assert.are.equal(2, assert(assert(second.coverage[0])[1]).last)
  end)

  it("invalidates text reuse for changed content, width, and theme", function()
    local cache = {}
    local theme = Applet.Theme.new({ generation = 1 })
    local first = compiler.compile({ tree = document("One", 1, "body"), width = 40, cache = cache, theme = theme })
    local second = compiler.compile({
      tree = document("Two", 2, "changed body"),
      width = 40,
      cache = cache,
      previous = first,
      theme = theme,
    })
    assert.are.equal("body", first.lines[2])
    assert.are.equal("changed body", second.lines[2])
    local validations = 0
    util.validate_text = function(value, path)
      if value == "changed body" then
        validations = validations + 1
      end
      return validate_text(value, path)
    end
    compiler.compile({
      tree = document("Three", 3, "changed body"),
      width = 30,
      cache = cache,
      previous = second,
      theme = theme,
    })
    assert.are.equal(1, validations)
    compiler.compile({
      tree = document("Four", 4, "changed body"),
      width = 30,
      cache = cache,
      theme = Applet.Theme.new({ generation = 2 }),
    })
    assert.are.equal(2, validations)
    assert.has_error(function()
      compiler.compile({ tree = document("Bad", 5, "\255"), width = 30, cache = cache })
    end)
  end)

  it("resolves retained text styles with a replacement Theme at the same generation", function()
    local cache = {}
    local function content(revision)
      return ui.region({
        key = "styled",
        revision = revision,
        child = ui.text({ key = "styled:text", runs = { { text = "body", style = "body" } } }),
      })
    end
    local first_theme = Applet.Theme.new({ groups = { body = "ErrorMsg" } })
    local next_theme = Applet.Theme.new({ groups = { body = "WarningMsg" } })
    local first = compiler.compile({ tree = content(1), width = 30, cache = cache, theme = first_theme })
    local before = vim.deepcopy(first)
    local second = compiler.compile({
      tree = content(2),
      width = 30,
      cache = cache,
      previous = first,
      theme = next_theme,
    })
    local expected = compiler.compile({ tree = content(2), width = 30, theme = next_theme })
    assert.are.equal("WarningMsg", assert(second.decorations[1]).group)
    assert.are.same(expected.decorations, second.decorations)
    assert.are.same(before, first)
    local restored = compiler.compile({
      tree = content(3),
      width = 30,
      cache = cache,
      previous = second,
      theme = first_theme,
    })
    assert.are.same(first.decorations, restored.decorations)
  end)

  it("keeps borrowed text coverage immutable when composing row and background coverage", function()
    local cache = {}
    local function content(revision, background)
      return ui.region({
        key = "region",
        revision = revision,
        child = ui.panel({
          key = "panel",
          background = background,
          child = ui.row({
            key = "row",
            children = {
              ui.text({ key = "left", text = "left", wrap = "none" }),
              ui.text({ key = "right", text = "right", wrap = "none" }),
            },
          }),
        }),
      })
    end
    local first = compiler.compile({ tree = content(1, nil), width = 30, cache = cache })
    local before = vim.deepcopy(first)
    local second = compiler.compile({ tree = content(2, "NormalFloat"), width = 30, cache = cache, previous = first })
    assert.are.same(before, first)
    assert.is_true(#second.decorations > #first.decorations)
    assert.matches("left%s+right", assert(second.lines[1]))
  end)

  it("inserts background coverage before retained sparse text without changing its cached row", function()
    local cache = {}
    local function content(revision, background)
      return ui.region({
        key = "wide",
        revision = revision,
        child = ui.panel({
          key = "wide:panel",
          background = background,
          child = ui.row({
            key = "wide:row",
            width = 60,
            children = {
              ui.column({ key = "wide:empty", children = {} }),
              ui.text({ key = "wide:text", text = "far", wrap = "none" }),
            },
          }),
        }),
      })
    end
    local first = compiler.compile({ tree = content(1, nil), width = 20, cache = cache })
    local before = vim.deepcopy(first)
    local second = compiler.compile({
      tree = content(2, "NormalFloat"),
      width = 20,
      cache = cache,
      previous = first,
    })
    assert.are.same({ { first = 30, last = 33 } }, first.coverage[0])
    assert.are.same({ { first = 0, last = 20 }, { first = 30, last = 33 } }, second.coverage[0])
    assert.are.same(first.lines, second.lines)
    assert.are.same(before, first)
  end)

  it("keeps coverage rows disjoint while cached document Regions move", function()
    local cache = {}
    local function content(text, revision)
      return ui.column({
        key = "document",
        gap = 1,
        children = {
          ui.region({
            key = "stable",
            revision = 1,
            child = ui.text({ key = "stable:text", text = "stable" }),
          }),
          ui.region({
            key = "tail",
            revision = revision,
            child = ui.text({ key = "tail:text", text = text }),
          }),
        },
      })
    end
    local first = compiler.compile({ tree = content("old", 1), width = 20, cache = cache })
    local before = vim.deepcopy(first)
    local second = compiler.compile({
      tree = content("new\nline", 2),
      width = 20,
      cache = cache,
      previous = first,
    })
    local expected = compiler.compile({ tree = content("new\nline", 2), width = 20 })
    assert.are.same({ "stable", "", "new", "line" }, second.lines)
    assert.are.same(expected.coverage, second.coverage)
    assert.is_true(rawequal(first.coverage[0], second.coverage[0]))
    assert.are.same(before, first)
    local recomposed = compiler.compile({ tree = content("new\nline", 2), width = 20, cache = cache })
    assert.are.same(expected.coverage, recomposed.coverage)
    assert.are.same(before, first)
  end)

  it("preserves cached fallback text when a revised Image shrinks and grows", function()
    local cache = {}
    ---@param revision integer
    ---@param height integer
    local function content(revision, height)
      return ui.region({
        key = "image-region",
        revision = revision,
        child = ui.image({
          key = "image",
          source = { kind = "png_resource", id = "synthetic", revision = 1 },
          alt = "synthetic",
          width = 20,
          height = height,
          fallback = ui.text({
            key = "fallback",
            runs = { { text = "first\nsecond\nthird", group = "Normal" } },
            wrap = "none",
          }),
        }),
      })
    end
    local previous
    for revision, height in ipairs({ 1, 3, 1, 3 }) do
      local tree = content(revision, height)
      local before = previous and vim.deepcopy(previous)
      local layout = compiler.compile({ tree = tree, width = 20, cache = cache, previous = previous })
      local expected = compiler.compile({ tree = tree, width = 20 })
      assert.are.same(expected.lines, layout.lines)
      assert.are.same(expected.coverage, layout.coverage)
      assert.are.same(expected.decorations, layout.decorations)
      assert.are.same(before, previous)
      previous = layout
    end
  end)

  it("does not retain Image reservation rows when the image becomes unavailable", function()
    local source = { kind = "png_resource", id = "synthetic", revision = 1 }
    local identity = require("applet.image.source").identity(source)
    local tree = ui.region({
      key = "image-region",
      revision = 1,
      child = ui.image({
        key = "image",
        source = source,
        alt = "synthetic",
        width = 20,
        height = 4,
        fallback = ui.text({ key = "fallback", text = "first\nsecond\nthird", wrap = "none" }),
      }),
    })
    local cache = {}
    local first = compiler.compile({
      tree = tree,
      width = 20,
      cache = cache,
      images = {
        status = "available",
        generation = 1,
        resources = { [identity] = { id = identity, width = 20, height = 4 } },
      },
    })
    assert.are.equal(4, #first.lines)
    local before = vim.deepcopy(first)
    local second = compiler.compile({ tree = tree, width = 20, cache = cache, previous = first })
    local expected = compiler.compile({ tree = tree, width = 20 })
    assert.are.same(expected.lines, second.lines)
    assert.are.equal(3, #second.lines)
    assert.are.same(before, first)
  end)
end)
