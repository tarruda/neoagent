local assert = require("luassert")
local Applet = require("applet")
local compile = require("applet.pane.compile")
local ui = Applet.Pane.nodes

describe("Applet document compilation", function()
  ---@return Applet.PaneCompileCache, Applet.PaneCompileStats, Applet.Theme
  local function setup()
    return {}, { region_reuses = 0, region_compilations = 0 }, Applet.Theme.new()
  end

  ---@param key string
  ---@param revision? integer
  ---@return Applet.Tree
  local function document(key, revision)
    return {
      cache_key = key,
      root = ui.column({
        key = "document",
        children = { ui.region({
          key = key .. ":body",
          revision = revision or 1,
          child = ui.text({ key = key .. ":text", text = key .. " revision " .. (revision or 1) }),
        }) },
      }),
    }
  end

  it("reuses revised content after visiting another document", function()
    local cache, stats, theme = setup()
    local first = document("first")
    local options = { tree = first, width = 40, cache = cache, stats = stats, theme = theme }
    assert.are.same({ "first revision 1" }, compile.compile(options).lines)
    options.tree = document("second")
    assert.are.same({ "second revision 1" }, compile.compile(options).lines)
    options.tree = first
    assert.are.same({ "first revision 1" }, compile.compile(options).lines)
    assert.are.equal(2, stats.region_compilations, "returning to a revised document recompiled its content")
    assert.are.equal(1, stats.region_reuses)
  end)

  it("bounds retained compilation to the active document and two recently visited documents", function()
    local cache, stats, theme = setup()
    for _, key in ipairs({ "a", "b", "c", "a", "d", "e", "b" }) do
      local layout = compile.compile({ tree = document(key), width = 40, cache = cache, stats = stats, theme = theme })
      assert.are.same({ key .. " revision 1" }, layout.lines)
    end
    assert.are.equal(6, stats.region_compilations)
    assert.are.equal(1, stats.region_reuses)
  end)

  it("checks current constraints and revisions before reusing an inactive document", function()
    local cache, stats, theme = setup()
    for _, operation in ipairs({
      { key = "a", width = 40, revision = 1 },
      { key = "b", width = 40, revision = 1 },
      { key = "a", width = 30, revision = 1 },
      { key = "b", width = 30, revision = 1 },
      { key = "a", width = 30, revision = 2 },
      { key = "a", width = 30, revision = 2 },
    }) do
      local layout = compile.compile({
        tree = document(operation.key, operation.revision), width = operation.width,
        cache = cache, stats = stats, theme = theme,
      })
      assert.are.same({ operation.key .. " revision " .. operation.revision }, layout.lines)
    end
    assert.are.equal(5, stats.region_compilations)
    assert.are.equal(1, stats.region_reuses)
  end)

  it("separates document namespaces and clears retention when returning to unkeyed content", function()
    local cache, stats, theme = setup()
    for _, key in ipairs({ "a", "b", "a" }) do
      local tree = document(key)
      local children = tree.root.children
      assert(children)
      local region = children[1]
      assert(region)
      region.key = "shared"
      local layout = compile.compile({ tree = tree, width = 40, cache = cache, stats = stats, theme = theme })
      assert.are.same({ key .. " revision 1" }, layout.lines)
    end
    assert.are.equal(2, stats.region_compilations)
    local tree = document("unkeyed")
    tree.cache_key = nil
    assert.are.same({ "unkeyed revision 1" },
      compile.compile({ tree = tree, width = 40, cache = cache, stats = stats, theme = theme }).lines)
    assert.are.same({ "a revision 1" },
      compile.compile({ tree = document("a"), width = 40, cache = cache, stats = stats, theme = theme }).lines)
    assert.are.equal(4, stats.region_compilations)
  end)

  it("requires a nonempty string to identify a cached document", function()
    for _, invalid in ipairs({ "", false, 1 }) do
      local tree = document("invalid")
      tree.cache_key = invalid --[[@as string]]
      local ok, err = pcall(compile.compile, { tree = tree, width = 40 })
      assert.is_false(ok)
      assert.matches("tree.cache_key", tostring(err), 1, true)
    end
  end)
end)
