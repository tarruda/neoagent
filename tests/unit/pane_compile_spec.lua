local Applet = require("applet")
local compile = require("applet.pane.compile").compile
local layout_changes = require("applet.pane.reconcile").changes
local ui = Applet.Pane.nodes
local widgets = Applet.Pane.widgets

local function error_matches(pattern, callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  assert.matches(pattern, tostring(err))
end

describe("Pane content Trees and compilation", function()
  it("exposes plain content constructors", function()
    assert.is_nil(package.loaded["neoagent"])
    local options = { key = "message", text = "hello" }
    local node = ui.text(options)
    assert.are.equal("text", node.type)
    assert.are.equal("hello", node.text)
    assert.is_nil(options.type)
    local action = ui.action("choose", { id = 3 })
    assert.are.same({ action = "choose", payload = { id = 3 } }, action)
    assert.are.same({ root = node, view = { scroll = "preserve" } },
      ui.tree(node, { view = { scroll = "preserve" } }))

    error_matches("options must be a table", function() ui.text("bad") end)
    error_matches("name must be", function() ui.action("") end)
    error_matches("must be a node", function() ui.tree(false) end)
  end)

  it("compares immutable values exactly", function()
    local util = require("applet.util")
    assert.is_true(util.equal({ a = 1, [2] = true }, { [2] = true, a = 1 }))
    assert.is_false(util.equal({ a = 1 }, { a = 2 }))
    assert.is_false(util.equal({ a = 1 }, { a = 1, b = 2 }))
    local left, right = {}, {}
    left.self, right.self = left, right
    assert.is_true(util.equal(left, right))
    right.changed = true
    assert.is_false(util.equal(left, right))
    assert.is_false(util.equal(setmetatable({}, {}), setmetatable({}, {})))
    assert.are.equal(2, util.byte_col("á界z", 2))
    assert.are.equal(5, util.byte_col("á界z", 3))
    assert.are.equal(0, util.byte_col("text", 0))
    assert.are.equal(3, util.byte_col("text", 3))
    local decomposed = "e" .. vim.fn.nr2char(0x0301) .. "界"
    assert.are.equal(3, util.byte_col(decomposed, 1))
    assert.are.equal(3, util.byte_col(decomposed, 2))
    assert.are.equal(6, util.byte_col(decomposed, 3))
    assert.are.same({ a = 1 }, util.copy({ a = 1 }))
    assert.are.equal(3, #util.characters("á界😀", "characters"))
    assert.is_true(util.nonempty_string("x"))
    assert.is_false(util.nonempty_string(""))
    error_matches("valid UTF%-8", function() util.characters("\255", "bad") end)
  end)

  it("compiles Layouts without cryptographic content digests", function()
    local original = vim.fn.sha256
    vim.fn.sha256 = function()
      error("Applet compilation must not call sha256", 0)
    end
    local ok, layout = pcall(compile, {
      tree = ui.region({
        key = "content",
        revision = 1,
        child = ui.text({
          key = "content:text",
          text = string.rep("payload ", 1024),
          wrap = "none",
        }),
      }),
      width = 80,
      cache = {},
    })
    vim.fn.sha256 = original

    assert.is_true(ok, tostring(layout))
    assert.are.equal(1, #layout.regions)
  end)

  it("defines and resolves explicit semantic themes", function()
    local Theme = Applet.Theme
    local theme = Theme.new({
      generation = 4,
      groups = { strong = "AppletTestStrong" },
      highlights = { AppletTestStrong = { bold = true } },
    })
    theme:define()
    assert.are.equal("AppletTestStrong", theme:group("strong"))
    assert.are.equal("LiteralGroup", theme:group("LiteralGroup"))
    assert.is_nil(theme:group(nil))
    assert.are.equal(4, theme.generation)
    assert.is_true(vim.api.nvim_get_hl(0, { name = "AppletTestStrong" }).bold)
    error_matches("theme: must be", function() Theme.new(false) end)
    error_matches("groups: must be", function() Theme.new({ groups = false }) end)
    error_matches("highlights: must be", function() Theme.new({ highlights = false }) end)
    error_matches("style: must be", function() theme:group("") end)
  end)

  it("provides display-cell text operations and bounded theme derivation", function()
    local text = Applet.Pane.text
    assert.are.equal(4, text.width("a界b"))
    assert.are.equal("界", text.slice("a界b", 1, 3))
    assert.are.equal("a界b", text.truncate("a界b", 4))
    assert.are.equal("…def", text.truncate("abcdef", 4, { side = "left" }))
    assert.are.equal("ab…f", text.truncate("abcdef", 4, { side = "middle" }))
    assert.are.equal("..", text.truncate("abcdef", 2, { marker = "..." }))
    assert.are.same({ "one", "", "three" }, text.lines("one\n\nthree"))
    error_matches("non%-negative integral", function()
      text.truncate("value", 1.5)
    end)
    error_matches("right, left, or middle", function()
      text.truncate("value", 3, { side = "outside" })
    end)

    local previous_terminal = vim.g.terminal_color_1
    vim.g.terminal_color_1 = "#010203"
    vim.api.nvim_set_hl(0, "AppletPaletteBase", { fg = 0x123456 })
    local theme = Applet.Theme.new({
      name = "palette-test",
      groups = { base = "AppletPaletteBase" },
      max_derived_highlights = 1,
      highlights = function(palette)
        return {
          AppletPaletteNamed = {
            fg = "red",
            bg = palette:blend("#000000", "#ffffff", 0.5),
          },
        }
      end,
    })
    local palette = theme:colors()
    assert.are.equal(0x010203, palette:terminal(1))
    assert.are.equal(0x000000, palette:terminal(16))
    assert.are.equal(0xffffff, palette:terminal(231))
    assert.are.equal(0x080808, palette:terminal(232))
    assert.are.same({ red = 0x12, green = 0x34, blue = 0x56 },
      palette:rgb("#123456"))
    assert.are.equal(196, palette:cterm("#ff0000"))
    assert.is_nil(palette:cterm("not-a-color"))
    theme:define()
    local named = vim.api.nvim_get_hl(0, { name = "AppletPaletteNamed" })
    assert.are.equal(0xff0000, named.fg)
    assert.are.equal(0x7f7f7f, named.bg)
    local derived = theme:derive("first", { base = "base", italic = true })
    assert.are.equal(derived,
      theme:derive("first", { base = "base", italic = false }))
    assert.are.equal("AppletPaletteBase",
      theme:derive("overflow", { base = "base" }))
    assert.is_nil(theme:derive("overflow-without-base", {}))

    local independent_one = Applet.Theme.new()
    local independent_two = Applet.Theme.new()
    local first_group = independent_one:derive("first", {
      base = "Normal",
      bold = true,
    })
    local second_group = independent_two:derive("second", {
      base = "Normal",
      italic = true,
    })
    assert.are_not.equal(first_group, second_group)
    assert.is_true(vim.api.nvim_get_hl(0, { name = first_group }).bold)
    assert.is_true(vim.api.nvim_get_hl(0, { name = second_group }).italic)
    vim.g.terminal_color_1 = previous_terminal
  end)

  it("orders shared interaction participants by phase and stable registration", function()
    local Domain = require("applet.interaction_domain")
    local domain = Domain.new()
    local order = {}
    local function participant(name)
      return {
        _flush_requested = function() order[#order + 1] = name end,
      }
    end
    local late = participant("late")
    local first = participant("first")
    local frame = participant("frame")
    domain:add(late, { phase = 3 })
    domain:add(first)
    domain:add(frame, { phase = "frame" })
    assert.are.same({
      participants = 3,
      active_participants = 0,
      key_observer_active = false,
      waiting_for_safe = false,
    }, domain:_stats())
    assert.is_true(domain:activate(first))
    assert.is_false(domain:activate(first))
    assert.is_true(domain:_stats().key_observer_active)
    assert.is_true(domain:deactivate(first))
    assert.is_false(domain:deactivate(first))
    assert.is_false(domain:_stats().key_observer_active)
    domain:add(late, { phase = "content" })
    domain:request(late)
    domain:request(first)
    domain:request(frame)
    assert.is_true(domain:flush())
    assert.are.same({ "frame", "late", "first" }, order)

    order = {}
    assert.is_true(domain:remove(late))
    domain:add(late)
    domain:request(late)
    domain:request(first)
    domain:request(frame)
    assert.is_true(domain:flush())
    assert.are.same({ "frame", "first", "late" }, order)
    domain:destroy()
  end)

  it("releases disconnected interaction participants", function()
    local Domain = require("applet.interaction_domain")
    local domain = Domain.new()
    local retained = setmetatable({}, { __mode = "v" })

    for index = 1, 300 do
      local participant = { _flush_requested = function() end }
      retained[index] = participant
      domain:add(participant)
      domain:remove(participant)
    end
    collectgarbage("collect")
    collectgarbage("collect")

    assert.is_nil(next(retained))
    domain:destroy()
  end)

  it("allows surface callbacks to disconnect later participants", function()
    local Domain = require("applet.interaction_domain")
    local domain = Domain.new()
    local changed = {}
    local later = {
      _flush_requested = function() end,
      surface_changed = function() changed[#changed + 1] = "later" end,
    }
    local first = {
      _flush_requested = function() end,
      surface_changed = function()
        changed[#changed + 1] = "first"
        domain:remove(later)
      end,
    }
    local last = {
      _flush_requested = function() end,
      surface_changed = function() changed[#changed + 1] = "last" end,
    }
    domain:add(first)
    domain:add(later)
    domain:add(last)

    assert.is_true(domain:surfaces_changed())
    assert.are.same({ "first", "last" }, changed)
    domain:destroy()
  end)

  it("compiles Applet navigation bindings through nested modal scopes", function()
    local layout = compile({
      tree = ui.scope({
        key = "outer-modal",
        modal = true,
        bindings = {
          {
            lhs = "l",
            action = ui.action("applet.focus.move", {
              direction = "right",
              wrap = true,
            }),
          },
        },
        child = ui.scope({
          key = "inner-modal",
          modal = true,
          child = ui.text({ key = "modal-text", text = "modal" }),
        }),
      }),
      width = 20,
    })
    assert.is_true(layout.scopes["outer-modal"].modal)
    assert.are.equal("outer-modal", layout.scopes["inner-modal"].parent)
    assert.are.equal("applet.focus.move",
      layout.scopes["outer-modal"].bindings[1].action.action)
  end)

  it("accepts modal ancestry through an intermediate scope", function()
    local layout = compile({
      tree = ui.scope({
        key = "outer-modal",
        modal = true,
        child = ui.scope({
          key = "intermediate",
          child = ui.scope({
            key = "inner-modal",
            modal = true,
            child = ui.text({ key = "modal-text", text = "modal" }),
          }),
        }),
      }),
      width = 20,
    })
    assert.are.equal("intermediate", layout.scopes["inner-modal"].parent)
    assert.are.equal("outer-modal", layout.scopes.intermediate.parent)
  end)

  it("compiles rich document regions into one physical Layout", function()
    local theme = Applet.Theme.new({
      generation = 2,
      groups = {
        strong = "Bold",
        muted = "Comment",
        selected = "Visual",
        panel = "NormalFloat",
      },
    })
    local first = ui.region({
      key = "message:1",
      revision = 7,
      child = ui.panel({
        key = "message:1:panel",
        padding = { left = 1, right = 1, top = 1, bottom = 1 },
        background = "panel",
        child = ui.source({
          key = "message:1:source",
          path = "hello.lua",
          language = "lua",
          child = ui.target({
            key = "message:1:target",
            group = "cards",
            role = "document",
            action = ui.action("details", { id = 1 }),
            focus_style = "selected",
            focus = {
              active = {
                {
                  row = 0,
                  col = 1,
                  chunks = { { text = "open", style = "muted" } },
                  position = "overlay",
                },
              },
              inactive = {
                {
                  row = "end",
                  chunks = { { text = "idle", group = "String" } },
                  win_col = 4,
                  priority = 210,
                },
              },
            },
            child = ui.text({
              key = "message:1:text",
              runs = {
                { text = "local", style = "strong" },
                { text = "\tvalue\nnext", group = "String" },
              },
              tabstop = 8,
              wrap = "character",
            }),
          }),
        }),
      }),
    })
    local second = ui.region({
      key = "message:2",
      child = ui.scope({
        key = "message:2:scope",
        bindings = {
          {
            lhs = "<CR>",
            action = ui.action("applet.target.activate"),
            desc = "Open",
          },
        },
        child = ui.target({
          key = "message:2:target",
          group = "cards",
          child = ui.row({
            key = "message:2:row",
            gap = 2,
            children = {
              {
                min_width = 4,
                grow = 1,
                node = ui.text({ key = "left", text = "left", wrap = "none" }),
              },
              {
                min_width = 3,
                grow = 2,
                node = ui.text({ key = "right", text = "right", wrap = "none" }),
              },
            },
          }),
        }),
      }),
    })
    local tree = {
      root = ui.scope({
        key = "root:scope",
        bindings = {
          { mode = "n", lhs = "q", action = ui.action("close") },
        },
        child = ui.column({
          key = "regions",
          gap = 1,
          children = { first, second },
        }),
      }),
      chrome = {
        title = { { text = " Applet ", style = "strong" } },
        title_pos = "center",
        footer = { { text = " q close ", group = "Comment" } },
        footer_pos = "right",
        options = { wrap = false },
      },
      view = {
        scroll = "follow_end",
        initial_target = "message:1:target",
        target_intent = {
          key = "show-messages",
          select = "message:1:target",
          reveal = "message:2:target",
        },
      },
    }
    local layout = compile({
      tree = tree,
      width = 20,
      height = 5,
      extent = "document",
      theme = theme,
    })
    assert.are.equal("document", layout.extent)
    assert.are.equal(20, layout.width)
    assert.are.equal(5, layout.height)
    assert.are.same({
      key = "show-messages",
      select = "message:1:target",
      reveal = "message:2:target",
    }, layout.view.target_intent)
    assert.is_true(#layout.lines > 5)
    assert.are.equal(2, #layout.regions)
    assert.are.equal("message:1", layout.regions[1].key)
    assert.are.equal(7, layout.regions[1].revision)
    assert.are.equal(layout.regions[1].last + 1, layout.regions[2].first)
    assert.are.equal("Visual", layout.targets["message:1:target"].focus_style)
    assert.are.equal("document", layout.targets["message:1:target"].role)
    local target = layout.targets["message:1:target"]
    assert.are.same({ "open", "Comment" }, target.focus.active[1].chunks[1])
    assert.are.equal(target.rectangles[1].row, target.focus.active[1].row)
    assert.are.equal(target.rectangles[1].col + 1, target.focus.active[1].col)
    local last_rectangle = target.rectangles[#target.rectangles]
    assert.are.equal(last_rectangle.row + last_rectangle.height,
      target.focus.inactive[1].row)
    assert.are.equal(target.rectangles[1].col + 4,
      target.focus.inactive[1].win_col)
    assert.are.equal(210, target.focus.inactive[1].priority)
    assert.are.equal("message:2:scope", layout.scopes["message:2:scope"].key)
    assert.are.equal("root:scope", layout.scopes["message:2:scope"].parent)
    assert.are.equal(2, #layout.binding_pairs)
    assert.are.same({ " Applet ", "Bold" }, layout.chrome.title[1])
    assert.are.equal("center", layout.chrome.title_pos)
    assert.are.same({ " q close ", "Comment" }, layout.chrome.footer[1])
    assert.are.equal("right", layout.chrome.footer_pos)
    assert.are.equal("follow_end", layout.view.scroll)
    assert.are.equal(1, #layout.source_ranges)
    assert.are.equal("hello.lua", layout.source_ranges[1].path)
    assert.is_true(#layout.decorations > 2)
  end)

  it("compiles explicitly wide rows for native horizontal scrolling", function()
    local layout = compile({
      tree = ui.row({
        key = "track",
        width = 12,
        children = {
          {
            min_width = 6,
            grow = 0,
            node = ui.text({ key = "left", text = "left", wrap = "none" }),
          },
          {
            min_width = 6,
            grow = 0,
            node = ui.target({
              key = "right",
              child = ui.text({ key = "right:text", text = "right" }),
            }),
          },
        },
      }),
      width = 6,
    })
    assert.are.equal(12, vim.fn.strdisplaywidth(layout.lines[1]))
    assert.are.same({ row = 0, col = 6 }, layout.targets.right.point)
    error_matches("must cover the available width", function()
      compile({
        tree = ui.row({
          key = "short",
          width = 5,
          children = { ui.text({ key = "text", text = "short" }) },
        }),
        width = 6,
      })
    end)
  end)

  it("composes clipped container layers by stable z-order", function()
    local layout = compile({
      tree = ui.container({
        key = "stage",
        width = 10,
        height = 4,
        child = ui.text({
          key = "base",
          text = table.concat({
            "aaaaaaaaaa",
            "bbbbbbbbbb",
            "cccccccccc",
            "dddddddddd",
          }, "\n"),
          wrap = "none",
        }),
        layers = {
          ui.container({
            key = "lower:container",
            position = { mode = "absolute", row = 1, col = 2, zindex = 10 },
            width = 5,
            height = 1,
            child = ui.target({
              key = "lower",
              child = ui.text({ key = "lower:text", text = "LLLLL" }),
            }),
          }),
          ui.container({
            key = "upper:container",
            position = { mode = "absolute", row = 1, col = 4, zindex = 10 },
            width = 3,
            height = 1,
            child = ui.target({
              key = "upper",
              child = ui.text({ key = "upper:text", text = "UUU" }),
            }),
          }),
          ui.container({
            key = "clipped:container",
            position = { mode = "absolute", row = 2, col = -1, zindex = 30 },
            width = 3,
            height = 1,
            child = ui.text({ key = "clipped", text = "XYZ" }),
          }),
        },
      }),
      width = 10,
    })

    assert.are.same({
      "aaaaaaaaaa",
      "bbLLUUUbbb",
      "YZcccccccc",
      "dddddddddd",
    }, layout.lines)
    assert.are.same({ "lower", "upper" }, layout.target_order)
    assert.are.same({ "upper", "lower" }, layout.hit_order)
    assert.are.same({
      { row = 1, col = 2, width = 2, height = 1 },
    }, layout.targets.lower.rectangles)
    assert.are.same({
      { row = 1, col = 4, width = 3, height = 1 },
    }, layout.targets.upper.rectangles)
  end)

  it("renders the container box model inside its Applet bounds", function()
    local layout = compile({
      tree = ui.container({
        key = "frame",
        width = 8,
        height = 4,
        padding = 1,
        background = "Surface",
        border = {
          kind = "rounded",
          group = "FrameBorder",
          title = " frame ",
          title_pos = "center",
        },
        shadow = {
          row = 1,
          col = 2,
          character = "░",
          group = "FrameShadow",
        },
        child = ui.text({ key = "label", text = "AB", wrap = "none" }),
      }),
      width = 12,
    })

    assert.are.same({
      "╭ frame ─╮  ",
      "│        │░░",
      "│ AB     │░░",
      "│        │░░",
      "│        │░░",
      "╰────────╯░░",
      "  ░░░░░░░░░░",
    }, layout.lines)
    local groups = {}
    for _, decoration in ipairs(layout.decorations) do
      groups[decoration.group] = true
    end
    assert.is_true(groups.Surface)
    assert.is_true(groups.FrameBorder)
    assert.is_true(groups.FrameShadow)
  end)

  it("projects framed container metadata through its inferred box", function()
    local layout = compile({
      tree = ui.container({
        key = "frame",
        border = {
          kind = "double",
          group = "FrameBorder",
          title = "T",
          title_pos = "right",
          title_group = "FrameTitle",
        },
        child = ui.text({
          key = "base",
          text = "base\nline",
          wrap = "none",
          background = "BaseBackground",
        }),
        layers = {
          ui.container({
            key = "layer",
            position = { mode = "absolute", row = 0, col = 0 },
            width = 4,
            height = 1,
            child = ui.scope({
              key = "layer:scope",
              bindings = { {
                lhs = "x",
                action = ui.action("choose"),
              } },
              child = ui.source({
                key = "layer:source",
                language = "lua",
                child = ui.text({
                  key = "layer:text",
                  text = "TOP!",
                  wrap = "none",
                }),
              }),
            }),
          }),
        },
      }),
      width = 10,
    })

    assert.are.same({
      "╔═══════T╗",
      "║TOP!    ║",
      "║line    ║",
      "╚════════╝",
    }, layout.lines)
    assert.are.same({
      { row = 1, col = 1, width = 4, height = 1 },
    }, layout.scopes["layer:scope"].rectangles)
    assert.are.same({
      { row = 1, col = 1, width = 4, height = 1 },
    }, layout.source_ranges[1].rectangles)
    local groups = {}
    for _, decoration in ipairs(layout.decorations) do
      groups[decoration.group] = true
    end
    assert.is_true(groups.FrameBorder)
    assert.is_true(groups.FrameTitle)
    assert.is_true(groups.BaseBackground)
  end)

  it("clips nested containers and partially covered wide glyphs", function()
    local layout = compile({
      tree = ui.container({
        key = "outer",
        width = 7,
        height = 3,
        child = ui.container({
          key = "inner",
          width = 7,
          height = 3,
          child = ui.target({
            key = "base:target",
            child = ui.text({
              key = "base:text",
              text = "界x\nsecond\nthird",
              wrap = "none",
            }),
          }),
          layers = {
            ui.container({
              key = "cover",
              position = { mode = "absolute", row = 0, col = 1, zindex = 2 },
              width = 1,
              height = 1,
              child = ui.target({
                key = "cover:target",
                child = ui.text({ key = "cover:text", text = "Z" }),
              }),
            }),
          },
        }),
        layers = {
          ui.container({
            key = "nested",
            position = { mode = "absolute", row = 2, col = 5, zindex = 1 },
            width = 4,
            height = 2,
            background = "Overlay",
          }),
        },
      }),
      width = 7,
    })

    assert.are.same({ " Zx    ", "second ", "third  " }, layout.lines)
    assert.are.same({
      { row = 0, col = 2, width = 1, height = 1 },
      { row = 1, col = 0, width = 6, height = 1 },
      { row = 2, col = 0, width = 5, height = 1 },
    }, layout.targets["base:target"].rectangles)
    assert.are.same({
      { row = 0, col = 1, width = 1, height = 1 },
    }, layout.targets["cover:target"].rectangles)
    assert.are.same({ "cover:target", "base:target" }, layout.hit_order)
  end)

  it("preserves composed characters inside containers", function()
    local decomposed = "e" .. vim.fn.nr2char(0x0301)
    local layout = compile({
      tree = ui.container({
        key = "unicode",
        width = 6,
        height = 1,
        child = ui.text({
          key = "unicode:text",
          runs = { { text = decomposed .. "界x", group = "String" } },
          wrap = "none",
        }),
      }),
      width = 6,
    })

    assert.are.same({ decomposed .. "界x  " }, layout.lines)
    assert.are.equal("String", layout.decorations[1].group)
    assert.are.equal(0, layout.decorations[1].col)
    assert.are.equal(#decomposed + #"界x", layout.decorations[1].end_col)
  end)

  it("clips sparse canvas spans without splitting wide glyphs", function()
    local canvas = require("applet.pane.canvas")
    local wide = canvas.compose({
      width = 2,
      height = 2,
      layers = { {
        id = "wide",
        row = 0,
        col = 0,
        zindex = 0,
        order = 0,
        lines = { "界", "界" },
        coverage = {
          [0] = { { first = 1, last = 2 } },
          [1] = { { first = 0, last = 2 } },
        },
        clip = { row = 0, col = 0, width = 2, height = 2 },
      } },
    })
    assert.are.same({ "  ", "界" }, wide.lines)
    assert.are.same({ { first = 1, last = 2 } }, wide.coverage[0])
    assert.are.same({ { first = 0, last = 2 } }, wide.coverage[1])
    assert.are.same({
      { row = 0, col = 1, width = 1, height = 1 },
      { row = 1, col = 0, width = 2, height = 1 },
    }, wide.visible.wide)
    assert.are.equal(" ", canvas.slice({ "界" }, 0, 1, 2))
    assert.are.equal("界", canvas.slice({ "界" }, 0, 0, 2))
    assert.are.equal("bc", canvas.slice({ "abcd" }, 0, 1, 3))
    error_matches("ordered display%-cell range", function()
      canvas.slice({ "界" }, 0, -1, 1)
    end)

    local clipped = canvas.compose({
      width = 4,
      height = 1,
      layers = { {
        id = "clipped",
        row = 0,
        col = 0,
        zindex = 0,
        order = 0,
        lines = { "abcd" },
        coverage = { [0] = { { first = 0, last = 4 } } },
        clip = { row = 0, col = 1, width = 2, height = 1 },
      } },
    })
    assert.are.same({ " bc " }, clipped.lines)
    assert.are.same({ { first = 1, last = 3 } }, clipped.coverage[0])
    assert.are.equal(5, canvas.byte_col(clipped.cell_map, 0, 5))
  end)

  it("projects source and image metadata through visible container cells", function()
    local source = {
      kind = "png_bytes",
      id = "layered-image",
      data = "png",
      revision = 1,
    }
    local identity = require("applet.image.source").identity(source)
    local layout = compile({
      tree = ui.container({
        key = "stage",
        width = 8,
        height = 4,
        child = ui.source({
          key = "source",
          language = "lua",
          child = ui.image({
            key = "image",
            source = source,
            alt = "layered",
            width = 8,
            height = 4,
            fit = "fill",
            align = "left",
          }),
        }),
        layers = {
          ui.container({
            key = "occluder",
            position = { mode = "absolute", row = 1, col = 3, zindex = 5 },
            width = 3,
            height = 2,
            background = "Overlay",
          }),
        },
      }),
      width = 8,
      images = {
        status = "available",
        generation = 1,
        cell_width = 1,
        cell_height = 1,
        resources = {
          [identity] = { id = identity, width = 8, height = 4 },
        },
      },
    })

    assert.are.same({
      { row = 0, col = 0, width = 8, height = 1 },
      { row = 1, col = 0, width = 3, height = 2 },
      { row = 1, col = 6, width = 2, height = 2 },
      { row = 3, col = 0, width = 8, height = 1 },
    }, layout.images.image.visible)
    assert.are.same(layout.images.image.visible,
      layout.source_ranges[1].rectangles)
    assert.are.same({ first = 0, last = 4 }, {
      first = layout.source_ranges[1].first,
      last = layout.source_ranges[1].last,
    })
  end)

  it("keeps placement-only composition independent of hidden layer size", function()
    local document = table.concat(
      vim.fn["repeat"]({ string.rep("d", 120) }, 80), "\n")
    local cache = {}
    local stats = {
      region_compilations = 0,
      region_reuses = 0,
      layer_compilations = 0,
      layer_reuses = 0,
      composed_cells = 0,
    }
    local function scene(row, text)
      return ui.container({
        key = "stage",
        width = 20,
        height = 8,
        layers = {
          ui.container({
            key = "document",
            position = {
              mode = "absolute",
              row = -row,
              col = 0,
              zindex = 0,
            },
            width = 120,
            height = 80,
            child = ui.text({
              key = "document:text",
              text = text,
              wrap = "none",
            }),
          }),
          ui.container({
            key = "overlay",
            position = {
              mode = "absolute",
              row = 2 + row,
              col = 4,
              zindex = 10,
            },
            width = 6,
            height = 2,
            background = "NormalFloat",
            child = ui.text({ key = "overlay:text", text = "detail" }),
          }),
        },
      })
    end
    local function render(row, text)
      return compile({
        tree = scene(row, text),
        width = 20,
        height = 8,
        cache = cache,
        stats = stats,
      })
    end

    local first = render(0, document)
    assert.are.equal("dddddddddddddddddddd", first.lines[1])
    assert.are.equal(2, stats.layer_compilations)
    local initial_cells = stats.composed_cells

    local moved = render(1, document)
    assert.are.equal("dddddetaildddddddddd", moved.lines[4])
    assert.are.equal(2, stats.layer_compilations)
    assert.are.equal(2, stats.layer_reuses)
    assert.are.equal(20 * 8, stats.composed_cells - initial_cells)

    local before_content_change = stats.composed_cells
    local changed = render(2, "changed\n" .. document)
    assert.are.equal("dddddetaildddddddddd", changed.lines[5])
    assert.are.equal(3, stats.layer_compilations)
    assert.are.equal(3, stats.layer_reuses)
    assert.is_true(stats.composed_cells - before_content_change > 20 * 8)
  end)

  it("projects disjoint retained targets across placement changes", function()
    local compiler = require("applet.pane.compile")
    local initial = compile({
      tree = ui.container({
        key = "stage",
        width = 10,
        height = 1,
        child = ui.target({
          key = "left",
          child = ui.text({ key = "left:text", text = "left" }),
        }),
        layers = {
          ui.container({
            key = "right:container",
            position = { mode = "absolute", row = 0, col = 6, zindex = 1 },
            width = 4,
            height = 1,
            child = ui.target({
              key = "right",
              child = ui.text({ key = "right:text", text = "right" }),
            }),
          }),
        },
      }),
      width = 10,
      height = 1,
      retain_scene = true,
    })
    assert.are.same({
      { row = 0, col = 0, width = 4, height = 1 },
    }, initial.targets.left.rectangles)
    assert.are.same({
      { row = 0, col = 6, width = 4, height = 1 },
    }, initial.targets.right.rectangles)

    local moved_scene = require("applet.pane.scene").reposition(
      initial.scene, "right:container", { col = 2 })
    local moved = compiler.project_scene({
      layout = initial,
      scene = moved_scene,
    })
    assert.are.same({
      { row = 0, col = 0, width = 2, height = 1 },
    }, moved.targets.left.rectangles)
    assert.are.same({
      { row = 0, col = 2, width = 4, height = 1 },
    }, moved.targets.right.rectangles)
    assert.are.same({ "right", "left" }, moved.hit_order)

    local overlapping_scene = vim.deepcopy(initial.scene)
    for _, layer in ipairs(overlapping_scene.layers) do
      local target = layer.fragment.targets.left
      if target then
        target.rectangles = {
          { row = 0, col = 0, width = 3, height = 1 },
          { row = 0, col = 2, width = 2, height = 1 },
        }
      end
    end
    local canonical = compiler.project_scene({
      layout = initial,
      scene = overlapping_scene,
    })
    assert.are.same({
      { row = 0, col = 0, width = 4, height = 1 },
    }, canonical.targets.left.rectangles)
  end)

  it("reuses nested positioned fragments and their image claims", function()
    local source = {
      kind = "png_bytes",
      id = "nested-cache",
      data = "png",
      revision = 1,
    }
    local identity = require("applet.image.source").identity(source)
    local images = {
      status = "available",
      generation = 1,
      cell_width = 1,
      cell_height = 1,
      resources = {
        [identity] = { id = identity, width = 2, height = 1 },
      },
    }
    local cache = {}
    local stats = {
      region_compilations = 0,
      region_reuses = 0,
      layer_compilations = 0,
      layer_reuses = 0,
      composed_cells = 0,
    }
    local function tree(marker)
      return ui.container({
        key = "stage",
        width = 10,
        height = 4,
        layers = {
          ui.container({
            key = "outer",
            position = { mode = "absolute", row = 0, col = 0, zindex = 0 },
            width = 10,
            height = 4,
            child = ui.text({ key = "outer:text", text = marker }),
            layers = {
              ui.container({
                key = "middle",
                position = {
                  mode = "absolute", row = 1, col = 1, zindex = 1,
                },
                width = 4,
                height = 2,
                child = ui.image({
                  key = "nested:image",
                  source = source,
                  alt = "nested cache",
                  width = 2,
                  height = 1,
                  fit = "fill",
                }),
                layers = {
                  ui.container({
                    key = "inner",
                    position = {
                      mode = "absolute", row = 1, col = 2, zindex = 1,
                    },
                    width = 1,
                    height = 1,
                    background = "Visual",
                  }),
                },
              }),
            },
          }),
        },
      })
    end
    local function render(marker)
      return compile({
        tree = tree(marker),
        width = 10,
        height = 4,
        images = images,
        cache = cache,
        stats = stats,
      })
    end

    local first = render("one")
    assert.is_table(first.images["nested:image"])
    assert.are.equal(3, stats.layer_compilations)
    local second = render("two")
    assert.is_table(second.images["nested:image"])
    assert.are.equal(4, stats.layer_compilations)
    assert.are.equal(1, stats.layer_reuses)
    local third = render("two")
    assert.is_table(third.images["nested:image"])
    assert.are.equal(4, stats.layer_compilations)
    assert.are.equal(2, stats.layer_reuses)
  end)

  it("wraps, clips, ellipsizes, expands tabs, and preserves UTF-8 highlights", function()
    local layered = compile({
      tree = ui.text({
        key = "layered",
        runs = { {
          text = "thinking",
          groups = {
            "NeoagentThinking",
            { group = "NeoagentMarkdownItalic", priority = 110 },
          },
        } },
        wrap = "native",
      }),
      width = 5,
    })
    assert.are.same({
      { row = 0, col = 0, end_col = 8, group = "NeoagentThinking" },
      { row = 0, col = 0, end_col = 8,
        group = "NeoagentMarkdownItalic", priority = 110 },
    }, layered.decorations)

    local native = compile({
      tree = ui.text({
        key = "native",
        text = "one two three\nfour five",
        wrap = "native",
      }),
      width = 5,
    })
    assert.are.same({ "one two three", "four five" }, native.lines)

    local word = compile({
      tree = ui.text({
        key = "word",
        runs = { { text = "one two three", style = "String" } },
        wrap = "word",
        max_lines = 2,
        overflow = "ellipsis",
      }),
      width = 5,
    })
    assert.are.equal(2, #word.lines)
    assert.matches("…$", word.lines[2])
    assert.are.equal("String", word.decorations[1].group)

    local background = compile({
      tree = ui.text({
        key = "background",
        text = "short",
        background = "NormalFloat",
      }),
      width = 20,
    })
    assert.are.same({ "short" }, background.lines)
    assert.are.equal("NormalFloat", background.decorations[1].group)
    assert.is_true(background.decorations[1].whole_line)

    local continuation = compile({
      tree = ui.text({
        key = "continuation",
        text = "one two three",
        wrap = "native",
        background = "NormalFloat",
      }),
      width = 5,
    })
    assert.are.equal(5, continuation.decorations[1].col)
    assert.are.equal("NormalFloat", continuation.decorations[1].group)
    assert.is_true(continuation.decorations[1].continuation)
    assert.is_true(continuation.decorations[1].whole_line)

    local character = compile({
      tree = ui.text({
        key = "character",
        runs = { { text = "á界z" } },
        wrap = "character",
      }),
      width = 2,
    })
    assert.are.same({ "á", "界", "z" }, character.lines)

    local clipped = compile({
      tree = ui.text({
        key = "clipped",
        runs = { { text = "a\tb" } },
        tabstop = 4,
        wrap = "none",
        overflow = "ellipsis",
      }),
      width = 4,
    })
    assert.are.equal("a  …", clipped.lines[1])
  end)

  it("selects responsive variants with advisory document height", function()
    local function responsive()
      return ui.responsive({
        key = "responsive",
        variants = {
          {
            min_width = 10,
            min_height = 4,
            max_height = 8,
            node = ui.text({ key = "wide", text = "wide" }),
          },
          {
            max_width = 9,
            node = ui.text({ key = "narrow", text = "narrow" }),
          },
          { node = ui.text({ key = "fallback", text = "fallback" }) },
        },
      })
    end
    assert.are.equal("wide", compile({
      tree = responsive(), width = 12, height = 5,
    }).lines[1])
    assert.are.equal("narrow", compile({
      tree = responsive(), width = 8,
    }).lines[1])
    assert.are.equal("fallback", compile({
      tree = responsive(), width = 12,
    }).lines[1])
  end)

  it("compiles virtual chrome and enforces viewport presentation bounds", function()
    local root = ui.column({
      key = "root",
      children = {
        ui.text({ key = "body", text = "body" }),
        ui.virtual({
          key = "status",
          placement = "above-end",
          lines = {
            { { text = "queued", style = "Comment" } },
            { { text = "working", group = "String" } },
          },
        }),
      },
    })
    local layout = compile({ tree = root, width = 20, height = 3, extent = "viewport" })
    assert.are.equal(1, #layout.lines)
    assert.are.equal(1, #layout.virtuals)
    assert.are.same({ "queued", "Comment" }, layout.virtuals[1].lines[1][1])
    error_matches("exceeds its height", function()
      compile({ tree = root, width = 20, height = 2, extent = "viewport" })
    end)
    error_matches("required for viewport", function()
      compile({ tree = root, width = 20, extent = "viewport" })
    end)
  end)

  it("clips or collapses viewport overflow explicitly", function()
    local function content(overrides)
      return ui.column(vim.tbl_extend("force", {
        key = "bounded",
        children = {
          ui.text({ key = "one", text = "one" }),
          ui.text({ key = "two", text = "two" }),
          ui.text({ key = "three", text = "three" }),
          ui.text({ key = "four", text = "four" }),
        },
      }, overrides or {}))
    end
    local prefix = compile({
      tree = content({
        overflow = "clip",
        overflow_marker = ui.text({ key = "more", text = "more" }),
      }),
      width = 10,
      height = 3,
      extent = "viewport",
    })
    assert.are.same({ "one", "two", "more" }, prefix.lines)
    assert.are.equal("bounded:clipped", prefix.regions[1].key)

    local suffix = compile({
      tree = content({ overflow = "clip", clip_from = "start" }),
      width = 10,
      height = 3,
      extent = "viewport",
    })
    assert.are.same({ "…", "three", "four" }, suffix.lines)

    local collapsed = compile({
      tree = content({
        overflow = "collapse",
        collapse = ui.text({ key = "summary", text = "four rows" }),
      }),
      width = 10,
      height = 1,
      extent = "viewport",
    })
    assert.are.same({ "four rows" }, collapsed.lines)
    assert.are.equal("bounded:collapsed", collapsed.regions[1].key)

    error_matches("must be error", function()
      compile({
        tree = content({ overflow = "unknown" }),
        width = 10, height = 1, extent = "viewport",
      })
    end)
    error_matches("required for collapse", function()
      compile({
        tree = content({ overflow = "collapse" }),
        width = 10, height = 1, extent = "viewport",
      })
    end)
    error_matches("must be start", function()
      compile({
        tree = content({ overflow = "clip", clip_from = "middle" }),
        width = 10, height = 2, extent = "viewport",
      })
    end)
  end)

  it("clips viewport metadata with the physical rows it describes", function()
    local image_source = { kind = "png_bytes", id = "test", data = "png", revision = 1 }
    local identity = require("applet.image.source").identity(image_source)
    local root = ui.scope({
      key = "bounded:scope",
      overflow = "clip",
      clip_from = "start",
      bindings = { { lhs = "x", action = ui.action("choose") } },
      child = ui.column({
        key = "bounded",
        children = {
          ui.target({
            key = "text:target",
            focus = {
              active = { {
                row = 2,
                chunks = { { text = "active", group = "String" } },
                position = "eol",
              } },
              inactive = { {
                row = 2,
                chunks = { { text = "inactive", group = "Comment" } },
                position = "eol",
              } },
            },
            child = ui.source({
              key = "text:source",
              language = "lua",
              child = ui.text({
                key = "text",
                runs = { { text = "one\ntwo\nthree", style = "String" } },
              }),
            }),
          }),
          ui.image({
            key = "picture",
            source = image_source,
            alt = "picture",
            width = 3,
            height = 2,
          }),
        },
      }),
    })
    local layout = compile({
      tree = root,
      width = 8,
      height = 4,
      extent = "viewport",
      images = {
        status = "available",
        generation = 2,
        resources = {
          [identity] = { id = identity, content_id = 4, width = 2, height = 2 },
        },
      },
    })
    assert.are.equal(4, #layout.lines)
    local styled = vim.tbl_filter(function(decoration)
      return decoration.group == "String"
    end, layout.decorations)
    assert.are.equal(1, #styled)
    assert.are.equal(1, styled[1].row)
    assert.are.equal(1, #layout.targets["text:target"].rectangles)
    assert.are.equal(1, layout.targets["text:target"].rectangles[1].row)
    assert.are.equal(1, layout.targets["text:target"].focus.active[1].row)
    assert.are.equal(1, layout.targets["text:target"].focus.inactive[1].row)
    assert.is_true(layout.scopes["bounded:scope"].root)
    assert.are.equal(1, #layout.source_ranges)
    assert.are.same({ first = 1, last = 2 }, {
      first = layout.source_ranges[1].first,
      last = layout.source_ranges[1].last,
    })
    assert.are.equal(2, layout.images.picture.row)
    assert.are.equal(2, layout.images.picture.height)

    local retained_point = compile({
      tree = ui.target({
        key = "retained:target",
        child = ui.text({ key = "retained:text", text = "one\ntwo\nthree" }),
        overflow = "clip",
      }),
      width = 8,
      height = 2,
      extent = "viewport",
    })
    assert.are.same({ row = 0, col = 0 },
      retained_point.targets["retained:target"].point)
  end)

  it("reuses explicit revised region fragments under equal constraints", function()
    local cache = {}
    local stats = { region_compilations = 0, region_reuses = 0 }
    local function revised(text, revision)
      return ui.region({
        key = "stable",
        revision = revision,
        child = ui.text({ key = "stable:text", text = text }),
      })
    end
    assert.are.same({ "first" }, compile({
      tree = revised("first", 1),
      width = 20,
      cache = cache,
      stats = stats,
    }).lines)
    assert.are.same({ "first" }, compile({
      tree = revised("caller-promised-unchanged", 1),
      width = 20,
      cache = cache,
      stats = stats,
    }).lines)
    assert.are.equal(1, stats.region_compilations)
    assert.are.equal(1, stats.region_reuses)
    assert.are.same({ "second" }, compile({
      tree = revised("second", 2),
      width = 20,
      cache = cache,
      stats = stats,
    }).lines)
    assert.are.equal(2, stats.region_compilations)
    local empty = compile({
      tree = ui.column({ key = "regions", gap = 2, children = {
        ui.region({
          key = "empty",
          revision = 1,
          child = ui.column({ key = "empty:content", children = {} }),
        }),
        ui.region({
          key = "replacement",
          revision = 1,
          child = ui.text({ key = "replacement:text", text = "replacement" }),
        }),
      } }),
      width = 20,
      cache = cache,
      stats = stats,
    })
    assert.are.same({ "replacement" }, empty.lines)
    assert.are.same({ first = 0, last = 0 }, {
      first = empty.regions[1].first,
      last = empty.regions[1].last,
    })
    compile({
      tree = ui.region({
        key = "replacement",
        revision = 1,
        child = ui.text({ key = "replacement:text", text = "replacement" }),
      }),
      width = 20,
      cache = cache,
      stats = stats,
    })
    assert.is_nil(cache.regions.stable)
  end)

  it("retains immutable content for reused region fragments", function()
    local marker = "__cached_transcript_payload__"
    local cache = {}
    local function tree()
      return ui.region({
        key = "stable",
        revision = 1,
        child = ui.text({ key = "stable:text", text = marker, wrap = "none" }),
      })
    end
    local first = compile({ tree = tree(), width = 80, cache = cache })
    local second = compile({ tree = tree(), width = 80, cache = cache })

    assert.are.same({ marker }, second.lines)
    assert.is_true(rawequal(first.regions[1].lines, second.regions[1].lines))
  end)

  it("compares complete Layout semantics exactly", function()
    local cache = {}
    local function tree(opts)
      return {
        root = ui.scope({
          key = "root",
          bindings = { {
            lhs = opts.lhs or "x",
            action = ui.action("choose"),
          } },
          child = ui.region({
            key = "body",
            revision = opts.revision or 1,
            child = ui.text({ key = "body:text", text = opts.text or "body" }),
          }),
        }),
        chrome = { footer = { { text = opts.footer or "footer" } } },
      }
    end
    local base = compile({ tree = tree({}), width = 20, cache = cache })
    local stable = compile({ tree = tree({}), width = 20, cache = cache })
    assert.is_false(layout_changes(base, stable).any)

    local binding = compile({
      tree = tree({ lhs = "y" }), width = 20, cache = cache,
    })
    assert.is_false(layout_changes(base, binding).content)
    assert.is_true(layout_changes(base, binding).interaction)
    assert.is_true(layout_changes(base, binding).any)

    local chrome = compile({
      tree = tree({ footer = "changed" }), width = 20, cache = cache,
    })
    assert.is_false(layout_changes(base, chrome).content)
    assert.is_true(layout_changes(base, chrome).chrome)
    assert.is_true(layout_changes(base, chrome).any)

    local content = compile({
      tree = tree({ revision = 2, text = "changed" }),
      width = 20,
      cache = cache,
    })
    assert.is_true(layout_changes(base, content).content)
    assert.is_true(layout_changes(base, content).any)
  end)

  it("invalidates only cached regions that reference changed images", function()
    local image_source = { kind = "png_bytes", id = "test", data = "png", revision = 1 }
    local identity = require("applet.image.source").identity(image_source)
    local cache = {}
    local stats = { region_compilations = 0, region_reuses = 0 }
    local function tree()
      return ui.column({ key = "regions", children = {
        ui.region({ key = "text", revision = 1, child = ui.text({
          key = "text:value", text = "stable",
        }) }),
        ui.region({ key = "image", revision = 1, child = ui.image({
          key = "image:value",
          source = image_source,
          alt = "image",
          width = 2,
          height = 1,
        }) }),
      } })
    end
    compile({ tree = tree(), width = 10, cache = cache, stats = stats })
    compile({
      tree = tree(),
      width = 10,
      cache = cache,
      stats = stats,
      images = {
        status = "available",
        generation = 2,
        resources = {
          [identity] = { id = identity, content_id = 7, width = 1, height = 1 },
        },
      },
    })
    assert.are.equal(3, stats.region_compilations)
    assert.are.equal(1, stats.region_reuses)
    error_matches("images.presented", function()
      compile({ tree = tree(), width = 10, images = { presented = false } })
    end)
  end)

  it("tracks presented image dependencies by their stable slot", function()
    local image_source = {
      kind = "png_bytes", id = "shared", data = "png", revision = 2,
    }
    local cache = {}
    local stats = { region_compilations = 0, region_reuses = 0 }
    local function tree()
      return ui.column({ key = "regions", children = {
        ui.region({ key = "left", revision = 1, child = ui.image({
          key = "left:image",
          source = image_source,
          alt = "left image",
          width = 2,
          height = 1,
        }) }),
        ui.region({ key = "right", revision = 1, child = ui.image({
          key = "right:image",
          source = image_source,
          alt = "right image",
          width = 2,
          height = 1,
        }) }),
      } })
    end
    local function presented(right_identity)
      local left = { id = "left:1", width = 1, height = 1 }
      local right = { id = right_identity, width = 1, height = 1 }
      return {
        status = "available",
        generation = 1,
        resources = {
          [left.id] = left,
          [right.id] = right,
        },
        presented = {
          ["left:image"] = "left:1",
          ["right:image"] = right_identity,
        },
      }
    end
    compile({
      tree = tree(), width = 10, cache = cache, stats = stats,
      images = presented("right:1"),
    })
    compile({
      tree = tree(), width = 10, cache = cache, stats = stats,
      images = presented("right:2"),
    })
    assert.are.equal(3, stats.region_compilations)
    assert.are.equal(1, stats.region_reuses)
  end)

  it("uses a presented slot while its desired image revision prepares", function()
    local first_source = {
      kind = "png_bytes", id = "preview", data = "first", revision = 1,
    }
    local desired_source = {
      kind = "png_bytes", id = "preview", data = "second", revision = 2,
    }
    local source_module = require("applet.image.source")
    local first_id = source_module.identity(first_source)
    local desired_id = source_module.identity(desired_source)
    local first = { id = first_id, width = 8, height = 4 }
    local desired = { id = desired_id, width = 4, height = 8 }
    local node = ui.image({
      key = "preview:image",
      source = desired_source,
      alt = "preview",
      width = "native",
      height = "auto",
    })
    local function images(resources, status, key)
      return {
        status = status or "available",
        generation = 2,
        cell_width = 1,
        cell_height = 1,
        resources = resources,
        presented = {
          [key or "preview:image"] = first_id,
        },
      }
    end

    local pending = compile({
      tree = node,
      width = 20,
      images = images({ [first_id] = first }),
    })
    assert.are.equal(first_id, pending.images["preview:image"].source_identity)
    assert.are.equal(8, pending.images["preview:image"].width)
    assert.are.equal(4, pending.images["preview:image"].height)

    local prepared = compile({
      tree = node,
      width = 20,
      images = images({ [first_id] = first, [desired_id] = desired }),
    })
    assert.are.equal(desired_id,
      prepared.images["preview:image"].source_identity)
    assert.are.equal(4, prepared.images["preview:image"].width)
    assert.are.equal(8, prepared.images["preview:image"].height)

    local unavailable = compile({
      tree = node,
      width = 20,
      images = images({ [first_id] = first }, "unavailable"),
    })
    assert.is_nil(unavailable.images["preview:image"])
    local another_slot = compile({
      tree = node,
      width = 20,
      images = images({ [first_id] = first }, "available", "other:image"),
    })
    assert.is_nil(another_slot.images["preview:image"])
  end)

  it("uses fixed image rectangles and fallbacks", function()
    local source = {
      kind = "png_bytes",
      id = "pixel",
      data = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1",
      revision = 1,
    }
    local fallback = ui.text({
      key = "fallback",
      text = "not available",
      wrap = "word",
    })
    local node = ui.image({
      key = "image",
      source = source,
      alt = "test image",
      width = 8,
      height = 6,
      fit = "cover",
      align = "right",
      fallback = fallback,
    })
    local unavailable = compile({ tree = node, width = 10 })
    assert.are.equal(3, #unavailable.lines)
    assert.are.equal(10, vim.fn.strdisplaywidth(unavailable.lines[1]))
    assert.matches("^  not", unavailable.lines[1])
    assert.is_nil(unavailable.images.image)
    local identity = require("applet.image.source").identity(source)
    local resource = { id = identity, content_id = 3 }
    local available = compile({
      tree = node,
      width = 10,
      images = {
        status = "available",
        generation = 4,
        resources = { [identity] = resource },
      },
    })
    assert.are.equal(identity, available.images.image.source_identity)
    assert.are.equal(2, available.images.image.col)
    assert.are.equal("cover", available.images.image.fit)
    assert.are.equal(4, available.image_generation)

    local automatic = compile({
      tree = ui.image({
        key = "automatic",
        source = source,
        alt = "automatic fallback",
        width = "fill",
        height = 1,
      }),
      width = 30,
    })
    assert.matches("Image unavailable", automatic.lines[1])
    assert.are.equal(30, vim.fn.strdisplaywidth(automatic.lines[1]))

    local clipped = compile({
      tree = ui.image({
        key = "clipped",
        source = source,
        alt = "clipped fallback",
        width = 10,
        height = 2,
        fallback = ui.column({
          key = "fallback:column",
          children = {
            ui.target({
              key = "fallback:target",
              child = ui.source({
                key = "fallback:source",
                language = "lua",
                child = ui.text({
                  key = "fallback:text",
                  runs = { { text = "one\ntwo\nthree", style = "String" } },
                }),
              }),
            }),
            ui.target({
              key = "removed:target",
              child = ui.text({ key = "removed:text", text = "removed" }),
            }),
          },
        }),
      }),
      width = 10,
    })
    assert.are.equal(2, #clipped.lines)
    assert.are.equal(2, #clipped.targets["fallback:target"].rectangles)
    assert.is_nil(clipped.targets["removed:target"])
    assert.are.equal(2, clipped.source_ranges[1].last)

    local clipped_point = compile({
      tree = ui.image({
        key = "point",
        source = source,
        alt = "clipped target point",
        width = 10,
        height = 1,
        fallback = ui.target({
          key = "point:target",
          child = ui.text({ key = "point:text", text = "\nvisible" }),
        }),
      }),
      width = 10,
    })
    assert.are.same({ row = 0, col = 0 },
      clipped_point.targets["point:target"].point)
  end)

  it("resolves semantic image sizes inside Applet", function()
    local source = {
      kind = "png_bytes",
      id = "semantic-size",
      data = "png",
      revision = 1,
    }
    local identity = require("applet.image.source").identity(source)
    local function available(width, height)
      return {
        status = "available",
        generation = 1,
        cell_width = 10,
        cell_height = 20,
        resources = {
          [identity] = { id = identity, width = width, height = height },
        },
      }
    end
    local thumbnail = ui.image({
      key = "thumbnail",
      source = source,
      alt = "thumbnail",
      width = "fill",
      height = "auto",
      max_height = 12,
      align = "left",
    })
    local landscape = compile({
      tree = thumbnail,
      width = 40,
      images = available(160, 80),
    })
    assert.are.equal(40, landscape.images.thumbnail.width)
    assert.are.equal(10, landscape.images.thumbnail.height)
    assert.are.equal(0, landscape.images.thumbnail.col)

    local portrait = compile({
      tree = thumbnail,
      width = 40,
      images = available(40, 160),
    })
    assert.are.equal(6, portrait.images.thumbnail.width)
    assert.are.equal(12, portrait.images.thumbnail.height)
    assert.are.equal(0, portrait.images.thumbnail.col)

    local native = compile({
      tree = ui.image({
        key = "native",
        source = source,
        alt = "native",
        width = "native",
        height = "auto",
        align = "center",
      }),
      width = 40,
      images = available(40, 160),
    })
    assert.are.equal(4, native.images.native.width)
    assert.are.equal(8, native.images.native.height)
    assert.are.equal(18, native.images.native.col)
  end)

  it("builds menus, dialogs, and cards from primitive nodes", function()
    local menu, entry = widgets.menu({
      key = "menu",
      title = "Choose",
      initial = "three",
      wrap_navigation = true,
      items = {
        {
          key = "one",
          label = "One",
          detail = "First",
          action = ui.action("choose", { id = 1 }),
          quick_keys = { "1" },
        },
        { key = "two", label = { { text = "Two" } }, disabled = true },
        { key = "three", label = "Three", action = ui.action("choose", { id = 3 }) },
      },
      keys = { previous = "k", next = "j", activate = "<CR>" },
    })
    local layout = compile({ tree = menu, width = 30 })
    assert.are.equal(3, #layout.target_order)
    assert.is_true(layout.targets["menu:item:two"].disabled)
    assert.are.equal(4, #layout.binding_pairs)
    local next_binding = vim.tbl_filter(function(value)
      return value.lhs == "j"
    end, layout.scopes["menu:scope"].bindings)[1]
    assert.are.equal("first", next_binding.action.payload.entry)
    assert.are.equal("selected",
      layout.targets["menu:item:one"].focus_style)
    assert.is_nil(layout.targets["menu:item:two"].focus_style)
    assert.are.same({
      select = "menu:item:three",
      reveal = "menu:item:three",
    }, entry)
    assert.are.same({
      key = "open-menu",
      select = "menu:item:three",
      reveal = "menu:item:three",
    }, widgets.menu_intent(entry, "open-menu"))
    assert.is_nil(widgets.menu_intent(nil, "unused"))

    local natural = compile({
      tree = widgets.menu({
        key = "natural",
        items = {
          { key = "a", label = "A", action = ui.action("choose") },
        },
      }),
      width = 10,
    })
    assert.are.equal(0, #natural.binding_pairs)

    local horizontal = compile({
      tree = widgets.menu({
        key = "horizontal",
        orientation = "horizontal",
        item_min_width = 3,
        items = {
          { key = "a", label = "A", action = ui.action("choose") },
          { key = "b", label = "B", action = ui.action("choose") },
        },
      }),
      width = 12,
    })
    assert.are.equal(1, #horizontal.lines)

    local dialog_node, dialog_entry = widgets.dialog({
      key = "dialog",
      title = "Question",
      body = "Continue?",
      background = "NormalFloat",
      initial_action = "no",
      actions = {
        {
          key = "yes",
          label = "Yes",
          action = ui.action("answer", { yes = true }),
          quick_keys = { "y" },
        },
        { key = "no", label = "No", action = ui.action("answer", { yes = false }) },
      },
    })
    local dialog = compile({
      tree = dialog_node,
      width = 40,
    })
    assert.are.same({
      select = "dialog:actions:item:no",
      reveal = "dialog:actions:item:no",
    }, dialog_entry)
    assert.is_true(dialog.scopes["dialog:modal"].modal)
    assert.are.equal(4, #dialog.binding_pairs)
    assert.are.equal(4, #dialog.scopes["dialog:modal"].bindings)
    assert.are.equal(0, #dialog.scopes["dialog:actions:scope"].bindings)
    assert.is_true(dialog.targets["dialog:actions:item:yes"].point.row
      < dialog.targets["dialog:actions:item:no"].point.row)

    local explicit_activate = compile({
      tree = widgets.dialog({
        key = "explicit-activate",
        actions = { {
          key = "continue",
          label = "Continue",
          action = ui.action("answer"),
          quick_keys = { "<CR>" },
        } },
      }),
      width = 20,
    })
    assert.are.equal(3, #explicit_activate.binding_pairs)
    local enter = vim.tbl_filter(function(binding)
      return binding.lhs == "<CR>"
    end, explicit_activate.scopes["explicit-activate:modal"].bindings)
    assert.are.equal(1, #enter)
    assert.are.equal("explicit-activate:actions:item:continue",
      enter[1].action.payload.target)

    local card = compile({
      tree = widgets.card({
        key = "card",
        source = { language = "lua" },
        details_action = ui.action("details"),
        background = "NormalFloat",
        child = ui.text({ key = "card:text", text = "print('ok')" }),
      }),
      width = 30,
    })
    assert.are.equal("details", card.targets.card.action.action)
    assert.are.equal("lua", card.source_ranges[1].language)
  end)

  it("rejects malformed Trees before producing a Layout", function()
    local cases = {
      { "layout.width", function() compile({ tree = ui.text({ key = "x", text = "x" }), width = 0 }) end },
      { "layout.extent", function() compile({ tree = ui.text({ key = "x", text = "x" }), width = 2, extent = "page" }) end },
      { "tree: must be", function() compile({ width = 2 }) end },
      { "type: is unknown", function() compile({ tree = { type = "wat", key = "x" }, width = 2 }) end },
      { "key: must be", function() compile({ tree = { type = "text", text = "x" }, width = 2 }) end },
      { "runs: must be", function() compile({ tree = ui.text({ key = "x", runs = {} }), width = 2 }) end },
      { "wrap: must be", function() compile({ tree = ui.text({ key = "x", text = "x", wrap = "bad" }), width = 2 }) end },
      { "overflow: must be", function() compile({ tree = ui.text({ key = "x", text = "x", overflow = "bad" }), width = 2 }) end },
      { "tab without", function() compile({ tree = ui.text({ key = "x", text = "\t" }), width = 2 }) end },
      { "carriage", function() compile({ tree = ui.text({ key = "x", text = "\r" }), width = 2 }) end },
      { "style or group", function() compile({ tree = ui.text({ key = "x", runs = { { text = "x", style = "A", group = "B" } } }), width = 2 }) end },
      { "groups or one", function() compile({ tree = ui.text({ key = "x", runs = { { text = "x", style = "A", groups = { "B" } } } }), width = 2 }) end },
      { "non%-empty list", function() compile({ tree = ui.text({ key = "x", runs = { { text = "x", groups = {} } } }), width = 2 }) end },
      { "integer >= 0", function() compile({ tree = ui.text({ key = "x", runs = { { text = "x", groups = { { group = "A", priority = -1 } } } } }), width = 2 }) end },
      { "cannot appear in rows", function() compile({ tree = ui.row({ key = "x", children = { ui.region({ key = "r", child = ui.text({ key = "t", text = "x" }) }) } }), width = 2 }) end },
      { "minimum row widths", function() compile({ tree = ui.row({ key = "x", children = { { node = ui.text({ key = "t", text = "x" }), min_width = 3 } } }), width = 2 }) end },
      { "padding leaves", function() compile({ tree = ui.panel({ key = "x", padding = 1, child = ui.text({ key = "t", text = "x" }) }), width = 2 }) end },
      { "only valid in a parent", function() compile({
        tree = ui.container({
          key = "x",
          position = { mode = "absolute", row = 0, col = 0 },
          width = 2,
          height = 1,
        }),
        width = 2,
      }) end },
      { "layers: must be a list", function() compile({
        tree = ui.container({ key = "x", width = 2, height = 1, layers = { bad = true } }),
        width = 2,
      }) end },
      { "must be a container", function() compile({
        tree = ui.container({
          key = "x",
          width = 2,
          height = 1,
          layers = { ui.text({ key = "layer", text = "x" }) },
        }),
        width = 2,
      }) end },
      { "position: must be absolute", function() compile({
        tree = ui.container({
          key = "x",
          width = 2,
          height = 1,
          layers = { ui.container({ key = "layer", width = 1, height = 1 }) },
        }),
        width = 2,
      }) end },
      { "width: exceeds available", function() compile({
        tree = ui.container({ key = "x", width = 2, height = 1, border = "single" }),
        width = 2,
      }) end },
      { "height: is required", function() compile({
        tree = ui.container({ key = "x", width = 2 }),
        width = 2,
      }) end },
      { "kind: must be single", function() compile({
        tree = ui.container({ key = "x", width = 2, height = 1, border = "ornate" }),
        width = 4,
      }) end },
      { "shadow: must specify", function() compile({
        tree = ui.container({ key = "x", width = 2, height = 1, shadow = {} }),
        width = 4,
      }) end },
      { "cannot contain virtual lines", function() compile({
        tree = ui.container({
          key = "x",
          width = 2,
          height = 1,
          child = ui.virtual({ key = "virtual", lines = {} }),
        }),
        width = 2,
      }) end },
      { "no responsive", function() compile({ tree = ui.responsive({ key = "x", variants = { { min_width = 10, node = ui.text({ key = "t", text = "x" }) } } }), width = 2 }) end },
      { "region is only", function() compile({ tree = ui.column({ key = "x", children = { ui.column({ key = "nested", children = { ui.region({ key = "r", child = ui.text({ key = "t", text = "x" }) }) } }) } }), width = 4 }) end },
      { "cannot mix", function() compile({ tree = ui.column({ key = "x", children = { ui.region({ key = "r", child = ui.text({ key = "t", text = "x" }) }), ui.text({ key = "plain", text = "x" }) } }), width = 4 }) end },
      { "must be unique", function() compile({ tree = ui.column({ key = "x", children = { ui.region({ key = "r", child = ui.text({ key = "a", text = "x" }) }), ui.region({ key = "r", child = ui.text({ key = "b", text = "x" }) }) } }), width = 4 }) end },
      { "duplicate target", function() compile({ tree = ui.column({ key = "x", children = { ui.target({ key = "same", child = ui.text({ key = "a", text = "a" }) }), ui.target({ key = "same", child = ui.text({ key = "b", text = "b" }) }) } }), width = 4 }) end },
      { "focus: must be", function() compile({ tree = ui.target({ key = "x", focus = false, child = ui.text({ key = "t", text = "x" }) }), width = 4 }) end },
      { "following boundary", function() compile({ tree = ui.target({ key = "x", focus = { active = { { row = 2, chunks = { { text = "x" } } } } }, child = ui.text({ key = "t", text = "x" }) }), width = 4 }) end },
      { "chunks: must be", function() compile({ tree = ui.target({ key = "x", focus = { active = { { row = 0, chunks = {} } } }, child = ui.text({ key = "t", text = "x" }) }), width = 4 }) end },
      { "position: is unknown", function() compile({ tree = ui.target({ key = "x", focus = { active = { { row = 0, chunks = { { text = "x" } }, position = "middle" } } }, child = ui.text({ key = "t", text = "x" }) }), width = 4 }) end },
      { "cannot combine", function() compile({ tree = ui.target({ key = "x", focus = { active = { { row = 0, chunks = { { text = "x" } }, position = "eol", win_col = 1 } } }, child = ui.text({ key = "t", text = "x" }) }), width = 4 }) end },
      { "duplicates an image", function()
        local source = { kind = "png_bytes", id = "test", data = "same", revision = 1 }
        compile({ tree = ui.column({ key = "x", children = {
          ui.image({ key = "same", source = source, alt = "one", width = 1, height = 1 }),
          ui.image({ key = "same", source = source, alt = "two", width = 1, height = 1 }),
        } }), width = 4 })
      end },
      { "duplicate image key", function()
        local image_source = { kind = "png_bytes", id = "test", data = "same", revision = 1 }
        compile({ tree = ui.column({ key = "regions", children = {
          ui.region({ key = "one", child = ui.image({
            key = "same", source = image_source, alt = "one", width = 1, height = 1,
          }) }),
          ui.region({ key = "two", child = ui.image({
            key = "same", source = image_source, alt = "two", width = 1, height = 1,
          }) }),
        } }), width = 4 })
      end },
      { "duplicate image key", function()
        local cache = {}
        local image_source = { kind = "png_bytes", id = "test", data = "same", revision = 1 }
        local function region(key)
          return ui.region({ key = key, revision = 1, child = ui.image({
            key = "same", source = image_source, alt = key, width = 1, height = 1,
          }) })
        end
        compile({ tree = region("cached"), width = 4, cache = cache })
        compile({ tree = ui.column({ key = "regions", children = {
          region("cached"), region("other"),
        } }), width = 4, cache = cache })
      end },
      { "duplicates a binding", function() compile({ tree = ui.scope({ key = "x", bindings = { { lhs = "x", action = ui.action("x") }, { lhs = "x", action = ui.action("x") } }, child = ui.text({ key = "t", text = "x" }) }), width = 4 }) end },
      { "more than one modal", function() compile({ tree = ui.column({ key = "x", children = { ui.scope({ key = "a", modal = true, child = ui.text({ key = "ta", text = "a" }) }), ui.scope({ key = "b", modal = true, child = ui.text({ key = "tb", text = "b" }) }) } }), width = 4 }) end },
      { "sibling scopes", function() compile({ tree = ui.column({ key = "x", children = {
        ui.scope({ key = "a", bindings = { { lhs = "x", action = ui.action("x") } }, child = ui.virtual({ key = "va", lines = {} }) }),
        ui.scope({ key = "b", bindings = { { lhs = "x", action = ui.action("x") } }, child = ui.virtual({ key = "vb", lines = {} }) }),
      } }), width = 4 }) end },
      { "plain data", function() compile({ tree = ui.target({ key = "x", action = ui.action("x", { callback = function() end }), child = ui.text({ key = "t", text = "x" }) }), width = 4 }) end },
      { "plain data", function() compile({ tree = {
        root = ui.text({ key = "x", text = "x", ignored = function() end }),
      }, width = 4 }) end },
      { "plain data", function()
        local node = ui.text({ key = "x", text = "x" })
        setmetatable(node, {})
        compile({ tree = node, width = 4 })
      end },
      { "known built%-in", function() compile({
        tree = ui.scope({ key = "x", bindings = {
          { lhs = "x", action = ui.action("applet.unknown") },
        }, child = ui.text({ key = "t", text = "x" }) }), width = 4,
      }) end },
      { "previous or next", function() compile({
        tree = ui.scope({ key = "x", bindings = {
          { lhs = "x", action = ui.action("applet.target.move", { direction = "down" }) },
        }, child = ui.text({ key = "t", text = "x" }) }), width = 4,
      }) end },
      { "payload.group", function() compile({
        tree = ui.scope({ key = "x", bindings = {
          { lhs = "x", action = ui.action("applet.target.move", {
            direction = "next", group = "",
          }) },
        }, child = ui.text({ key = "t", text = "x" }) }), width = 4,
      }) end },
      { "payload.wrap", function() compile({
        tree = ui.scope({ key = "x", bindings = {
          { lhs = "x", action = ui.action("applet.target.move", {
            direction = "next", wrap = "yes",
          }) },
        }, child = ui.text({ key = "t", text = "x" }) }), width = 4,
      }) end },
      { "payload.entry", function() compile({
        tree = ui.scope({ key = "x", bindings = {
          { lhs = "x", action = ui.action("applet.target.move", {
            direction = "next", entry = "nearest",
          }) },
        }, child = ui.text({ key = "t", text = "x" }) }), width = 4,
      }) end },
      { "payload.target", function() compile({
        tree = ui.scope({ key = "x", bindings = {
          { lhs = "x", action = ui.action("applet.target.activate", { target = "" }) },
        }, child = ui.text({ key = "t", text = "x" }) }), width = 4,
      }) end },
      { "payload.target", function() compile({
        tree = ui.scope({ key = "x", bindings = {
          { lhs = "x", action = ui.action("applet.target.reveal") },
        }, child = ui.text({ key = "t", text = "x" }) }), width = 4,
      }) end },
      { "revision", function() compile({
        tree = ui.region({
          key = "image-region",
          revision = 1,
          child = ui.image({
            key = "image",
            source = { kind = "png_bytes", id = "test", data = "png" },
            alt = "invalid",
            width = 1,
            height = 1,
          }),
        }),
        width = 4,
        cache = {},
      }) end },
      { "chrome.title_pos", function() compile({
        tree = {
          root = ui.text({ key = "x", text = "x" }),
          chrome = { title_pos = "middle" },
        },
        width = 4,
      }) end },
      { "chrome.footer_pos", function() compile({
        tree = {
          root = ui.text({ key = "x", text = "x" }),
          chrome = { footer_pos = false },
        },
        width = 4,
      }) end },
      { "view.scroll", function() compile({
        tree = { root = ui.text({ key = "x", text = "x" }), view = { scroll = "jump" } },
        width = 4,
      }) end },
      { "view.initial_target", function() compile({
        tree = { root = ui.text({ key = "x", text = "x" }), view = { initial_target = "" } },
        width = 4,
      }) end },
      { "target_intent.key", function() compile({
        tree = { root = ui.text({ key = "x", text = "x" }), view = {
          target_intent = {},
        } }, width = 4,
      }) end },
      { "target_intent.select", function() compile({
        tree = { root = ui.text({ key = "x", text = "x" }), view = {
          target_intent = { key = "intent", select = "" },
        } }, width = 4,
      }) end },
      { "target_intent.reveal", function() compile({
        tree = { root = ui.target({
          key = "x", child = ui.text({ key = "text", text = "x" }),
        }), view = { target_intent = {
          key = "intent", select = "x", reveal = true,
        } } }, width = 4,
      }) end },
      { "target_intent.target", function() compile({
        tree = { root = ui.text({ key = "x", text = "x" }), view = {
          target_intent = { key = "intent", select = "x", target = "x" },
        } }, width = 4,
      }) end },
      { "fallback: must not", function()
        local image = ui.image({ key = "x", source = {
          kind = "png_bytes", id = "test", data = "x", revision = 1,
        }, alt = "x", width = 1, height = 1 })
        image.fallback = ui.image({ key = "nested", source = {
          kind = "png_bytes", id = "test", data = "y", revision = 1,
        }, alt = "nested", width = 1, height = 1 })
        compile({ tree = image, width = 2 })
      end },
    }
    for _, case in ipairs(cases) do error_matches(case[1], case[2]) end

    local disjoint = compile({
      tree = ui.row({ key = "disjoint", children = {
        ui.scope({ key = "left", bindings = {
          { lhs = "x", action = ui.action("left") },
        }, child = ui.text({ key = "left:text", text = "L" }) }),
        ui.scope({ key = "right", bindings = {
          { lhs = "x", action = ui.action("right") },
        }, child = ui.text({ key = "right:text", text = "R" }) }),
      } }),
      width = 4,
    })
    assert.are.equal(1, #disjoint.binding_pairs)
  end)

  it("validates widget inputs directly", function()
    error_matches("options must", function() widgets.menu(false) end)
    error_matches("menu.key", function() widgets.menu({}) end)
    error_matches("orientation", function()
      widgets.menu({ key = "x", items = {}, orientation = "diagonal" })
    end)
    error_matches("menu.text_wrap", function()
      widgets.menu({ key = "x", items = {}, text_wrap = "window" })
    end)
    error_matches("menu.initial", function()
      widgets.menu({ key = "x", items = {}, initial = false })
    end)
    error_matches("menu.initial", function()
      widgets.menu({ key = "x", items = {}, initial = "missing" })
    end)
    error_matches("menu.initial", function()
      widgets.menu({
        key = "x",
        initial = "disabled",
        items = { { key = "disabled", label = "Disabled", disabled = true } },
      })
    end)
    error_matches("must be unique", function()
      widgets.menu({
        key = "x",
        items = {
          { key = "a", label = "A", action = ui.action("x") },
          { key = "a", label = "A", action = ui.action("x") },
        },
      })
    end)
    error_matches("action: is required", function()
      widgets.menu({ key = "x", items = { { key = "a", label = "A" } } })
    end)
    error_matches("menu entry", function()
      widgets.menu_intent(false, "intent")
    end)
    error_matches("menu entry.select", function()
      widgets.menu_intent({}, "intent")
    end)
    error_matches("menu entry.reveal", function()
      widgets.menu_intent({ select = "target" }, "intent")
    end)
    error_matches("menu intent key", function()
      widgets.menu_intent({ select = "target", reveal = "target" }, "")
    end)
    error_matches("dialog.key", function() widgets.dialog({}) end)
    error_matches("card.child", function() widgets.card({ key = "x" }) end)
  end)
end)
