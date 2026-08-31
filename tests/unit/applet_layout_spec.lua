local Applet = require("applet")
local compiler = require("applet.layout.compile")
local compile = compiler.compile
local host = require("applet.host")
local ui = Applet.layout

local function error_matches(pattern, callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  assert.matches(pattern, tostring(err))
end

local sequence = 0
local function pane_value(key, mode)
  sequence = sequence + 1
  return Applet.Pane.new({
    key = key,
    buffer_mode = mode or "managed",
  })
end

local function pane(key, value, opts)
  opts = opts or {}
  assert.are.equal(key, value:key())
  return ui.mount(value, {
    lifecycle = opts.lifecycle,
    required = opts.required,
    buffer = { name = key, filetype = opts.filetype },
    window = { border = opts.border or "single" },
    focus = { mode = opts.mode },
    bindings = opts.bindings,
  })
end

local function tree(transcript, input, layers)
  return {
    root = ui.frame({
      key = "frame",
      child = ui.split({
        key = "main",
        axis = "vertical",
        children = {
          { key = "body", grow = 1, min = 3, child = transcript },
          {
            key = "composer",
            basis = { content = 3 },
            grow = 0,
            child = input,
          },
        },
      }),
      layers = layers,
    }),
    focus = { initial = "input" },
  }
end

describe("Applet layout compilation", function()
  local panes = {}

  after_each(function()
    for _, value in ipairs(panes) do value:destroy() end
    panes = {}
  end)

  local function new_pane(key, mode)
    local value = pane_value(key, mode)
    panes[#panes + 1] = value
    return value
  end

  it("constructs validated immutable Host descriptors", function()
    local floating_options = { side = "left", width = 0.5, margin = 2 }
    local floating = host.floating(floating_options)
    floating_options.side = "right"
    assert.are.same({
      kind = "floating",
      container = "editor",
      side = "left",
      width = 0.5,
      height = 0.9,
      margin = 2,
      base_zindex = 40,
    }, floating)
    assert.are.same({
      kind = "tab", position = "first", label = "Example",
    }, host.tab({ position = "first", label = "Example" }))

    error_matches("not a recognized field", function()
      host.floating({ registry = true })
    end)
    error_matches("integral cell count", function()
      host.floating({ width = 2.5 })
    end)
    error_matches("before, after", function()
      host.tab({ position = "middle" })
    end)
    error_matches("floating or tab", function()
      host.validate({ kind = "external" })
    end)
  end)

  it("resolves every floating side and container fallback without handles", function()
    local editor = { row = 2, col = 3, width = 100, height = 40 }
    local expected = {
      left = { row = 3, col = 4 },
      right = { row = 3, col = 72 },
      top = { row = 3, col = 4 },
      bottom = { row = 31, col = 4 },
      center = { row = 17, col = 38 },
    }
    for side, position in pairs(expected) do
      local environment = compiler.environment({
        host = host.floating({
          side = side, width = 30, height = 10, margin = 1,
        }),
        editor = editor,
      })
      assert.are.equal(position.row, environment.bounds.row)
      assert.are.equal(position.col, environment.bounds.col)
      assert.is_false(environment.capabilities.native_splits)
      assert.is_true(environment.capabilities.overlays)
    end

    local container = {
      available = true, row = 5, col = 10, width = 50, height = 20,
    }
    local largest = compiler.environment({
      host = host.floating({
        container = "largest_window", side = "center",
        width = 20, height = 8, margin = 0,
      }),
      editor = editor,
      container = container,
    })
    assert.are.same({ row = 11, col = 25, width = 20, height = 8 },
      largest.bounds)
    local fallback = compiler.environment({
      host = host.floating({
        container = "auto", side = "left", width = 20, height = 8,
      }),
      editor = editor,
      container = { available = false },
    })
    assert.are.equal(editor.row + 1, fallback.bounds.row)
    error_matches("container is unavailable", function()
      compiler.environment({
        host = host.floating({ container = "largest_window" }),
        editor = editor,
        container = { available = false },
      })
    end)
    error_matches("margin leaves no available cells", function()
      compiler.environment({
        host = host.floating({ margin = 3 }),
        editor = { width = 5, height = 5 },
      })
    end)
  end)

  it("projects one topology through floating and tab Hosts", function()
    local transcript = new_pane("transcript")
    local input = new_pane("input", "editable")
    local value = tree(
      pane("transcript", transcript, { required = true }),
      pane("input", input, { required = true, mode = "insert" }))
    local editor = { row = 0, col = 0, width = 100, height = 40 }
    local floating = compile({
      tree = value,
      host = host.floating({ side = "center", width = 0.8, height = 0.75 }),
      editor = editor,
    })
    local tab = compile({ tree = value, host = host.tab(), editor = editor })

    assert.are.equal("split", floating.topology.type)
    assert.are.equal("split", tab.topology.type)
    assert.are.equal("vertical", floating.topology.axis)
    assert.are.same({ "transcript", "input" }, floating.pane_order)
    assert.are.same({ "transcript", "input" }, tab.pane_order)
    assert.are.equal(80, floating.bounds.width)
    assert.are.equal(30, floating.bounds.height)
    assert.are.equal(100, tab.bounds.width)
    assert.are.equal(40, tab.bounds.height)
    assert.are.equal("floating", floating.panes.transcript.projection.kind)
    assert.are.equal("split", tab.panes.transcript.projection.kind)
    assert.are.equal(5, floating.topology.children[2].size)
    assert.are.equal(3, tab.topology.children[2].size)
    assert.are.equal(3, floating.panes.input.content.height)
    assert.are.equal(3, tab.panes.input.content.height)
    assert.are.equal("insert", tab.panes.input.focus.mode)
    assert.are.equal("input", tab.focus.initial)
  end)

  it("allocates nested fixed, fractional, growing, shrinking, and bounded splits", function()
    local left, center, right = new_pane("left"), new_pane("center"), new_pane("right")
    local value = {
      root = ui.frame({
        key = "frame",
        child = ui.split({
          key = "columns",
          axis = "horizontal",
          children = {
            { key = "left-slot", basis = 0.25, grow = 0,
              child = pane("left", left, { border = "none" }) },
            { key = "center-slot", basis = 10, grow = 1, min = 5, max = 20,
              child = pane("center", center, { border = "none" }) },
            { key = "right-slot", basis = 30, grow = 1, shrink = 2, min = 8,
              child = pane("right", right, { border = "none" }) },
          },
        }),
      }),
    }
    local frame = compile({
      tree = value,
      host = host.tab(),
      editor = { width = 60, height = 20 },
    })
    assert.are.same({ 15, 13, 32 }, frame.splits.columns.sizes)
    assert.are.equal(0, frame.panes.left.outer.col)
    assert.are.equal(15, frame.panes.center.outer.col)
    assert.are.equal(28, frame.panes.right.outer.col)

    error_matches("minimum constraints do not fit", function()
      compile({
        tree = value,
        host = host.tab(),
        editor = { width = 12, height = 20 },
      })
    end)
  end)

  it("honors valid split overrides and deterministic maximum allocation", function()
    local first, second = new_pane("first"), new_pane("second")
    local value = {
      root = ui.frame({
        key = "frame",
        child = ui.split({
          key = "maximums",
          axis = "horizontal",
          children = {
            { key = "first", basis = 2, grow = 0, max = 6,
              child = pane("first", first, { border = "none" }) },
            { key = "second", basis = 2, grow = 0, max = 6,
              child = pane("second", second, { border = "none" }) },
          },
        }),
      }),
    }
    local base = compile({ tree = value, host = host.tab(),
      editor = { width = 10, height = 5 } })
    assert.are.same({ 4, 6 }, base.splits.maximums.sizes)
    local signature = base.splits.maximums.signature
    local overridden = compile({
      tree = value,
      host = host.tab(),
      editor = { width = 10, height = 5 },
      overrides = { maximums = { signature = signature, sizes = { 6, 4 } } },
    })
    assert.are.same({ 6, 4 }, overridden.splits.maximums.sizes)
    local ignored = compile({
      tree = value,
      host = host.tab(),
      editor = { width = 10, height = 5 },
      overrides = { maximums = { signature = signature, sizes = { 9, 1 } } },
    })
    assert.are.same({ 4, 6 }, ignored.splits.maximums.sizes)
    error_matches("maximum constraints leave unallocated cells", function()
      compile({ tree = value, host = host.tab(),
        editor = { width = 13, height = 5 } })
    end)
  end)

  it("compiles Pane-relative content-sized Layers and modal boundaries", function()
    local transcript, input = new_pane("transcript"), new_pane("input", "editable")
    local details, dialog = new_pane("details"), new_pane("dialog", "editable")
    local value = tree(
      pane("transcript", transcript),
      pane("input", input, { mode = "insert" }),
      {
        ui.layer({
          key = "details-layer",
          container = "transcript",
          width = 0.5,
          height = { content = true, min = 2, max = 10 },
          zindex = 70,
          enter = true,
          child = pane("details", details),
        }),
        ui.layer({
          key = "dialog-layer",
          container = "applet",
          width = 30,
          height = { content = true, min = 3, max = 12 },
          zindex = 80,
          modal = true,
          enter = false,
          child = pane("dialog", dialog, { mode = "insert" }),
        }),
      })
    value.focus.intent = { key = "dialog", revision = "open-dialog" }
    local frame = compile({
      tree = value,
      host = host.tab(),
      editor = { width = 100, height = 40 },
      measurements = {
        details = { screen_lines = 7 },
        dialog = { screen_lines = 5 },
      },
    })
    assert.are.equal(2, #frame.layers)
    assert.are.equal(7, frame.layers[1].rect.height)
    assert.are.equal(5, frame.layers[2].rect.height)
    assert.are.equal("floating", frame.panes.details.projection.kind)
    assert.are.equal("floating", frame.panes.dialog.projection.kind)
    assert.are.same({ "dialog" }, frame.modal_boundary)
    assert.are.equal("dialog", frame.focus.layer_entry)
    assert.are.same({ key = "dialog", revision = "open-dialog" },
      frame.focus.intent)
  end)

  it("measures content through scoped split subtrees", function()
    local main, first, second = new_pane("main"), new_pane("first"), new_pane("second")
    local value = {
      root = ui.frame({
        key = "frame",
        child = pane("main", main, { border = "none" }),
        layers = {
          ui.layer({
            key = "compound-layer",
            container = "editor",
            width = { content = true, min = 2, max = 60 },
            height = { content = true, max = 10 },
            child = ui.scope({
              key = "compound-scope",
              child = ui.split({
                key = "compound-split",
                axis = "horizontal",
                children = {
                  { key = "first", grow = 1,
                    child = pane("first", first, { border = "none" }) },
                  { key = "second", grow = 1,
                    child = pane("second", second, { border = "none" }) },
                },
              }),
            }),
          }),
        },
      }),
    }
    local frame = compile({
      tree = value,
      host = host.tab(),
      editor = { width = 80, height = 24 },
      measurements = {
        first = { screen_width = 18, screen_lines = 3 },
        second = { screen_width = 26, screen_lines = 5 },
      },
    })
    assert.are.equal(44, frame.layers[1].rect.width)
    assert.are.equal(5, frame.layers[1].rect.height)
    assert.are.same({ "first", "second" }, frame.layers[1].panes)
  end)

  it("sums vertical split measurements for content-sized Layers", function()
    local main, input = new_pane("document"), new_pane("input", "editable")
    local prompt, results = new_pane("prompt", "editable"), new_pane("results")
    local value = tree(pane("document", main), pane("input", input), {
      ui.layer({
        key = "picker-layer",
        container = "editor",
        width = 40,
        height = { content = true, max = 20 },
        child = ui.split({
          key = "picker-split",
          axis = "vertical",
          children = {
            { key = "prompt", basis = { content = true },
              child = pane("prompt", prompt, { border = "none" }) },
            { key = "results", basis = { content = true },
              child = pane("results", results, { border = "none" }) },
          },
        }),
      }),
    })
    local frame = compile({
      tree = value,
      host = host.floating({ width = 60, height = 20 }),
      editor = { width = 80, height = 24 },
      measurements = {
        prompt = { screen_lines = 1 },
        results = { screen_lines = 4 },
      },
    })
    assert.are.equal(5, frame.layers[1].rect.height)
    assert.are.same({ 1, 4 }, frame.splits["picker-split"].sizes)
  end)

  it("anchors Layers in every direction and orders equal z-index declarations", function()
    local main = new_pane("main")
    local names = {
      "top_left", "top", "top_right", "left", "center", "right",
      "bottom_left", "bottom", "bottom_right",
    }
    local expected = {
      top_left = { 10, 25 }, top = { 10, 45 }, top_right = { 10, 65 },
      left = { 18, 25 }, center = { 18, 45 }, right = { 18, 65 },
      bottom_left = { 26, 25 }, bottom = { 26, 45 },
      bottom_right = { 26, 65 },
    }
    local layers = {}
    for _, anchor in ipairs(names) do
      layers[#layers + 1] = ui.layer({
        key = anchor .. "-layer",
        container = "applet",
        anchor = anchor,
        width = 10,
        height = 4,
        zindex = 70,
        child = pane(anchor, new_pane(anchor), { border = "none" }),
      })
    end
    local value = {
      root = ui.frame({
        key = "frame",
        child = pane("main", main, { border = "none" }),
        layers = layers,
      }),
    }
    local frame = compile({
      tree = value,
      host = host.floating({ width = 50, height = 20, margin = 0 }),
      editor = { width = 100, height = 40 },
    })
    for index, anchor in ipairs(names) do
      local layer = frame.layers[index]
      assert.are.equal(anchor .. "-layer", layer.key)
      assert.are.same({
        row = expected[anchor][1], col = expected[anchor][2],
        width = 10, height = 4,
      }, layer.rect)
      assert.are.equal(70, layer.zindex)
    end
  end)

  it("uses measured width and portable chrome for content-sized Layers", function()
    local main, measured = new_pane("main"), new_pane("measured")
    local value = {
      root = ui.frame({
        key = "frame",
        child = pane("main", main, { border = "none" }),
        layers = {
          ui.layer({
            key = "measured-layer",
            container = "editor",
            anchor = "top_right",
            width = { content = true, min = 3, max = 20 },
            height = 4,
            child = pane("measured", measured, { border = "none" }),
          }),
        },
      }),
    }
    local frame = compile({
      tree = value,
      host = host.tab(),
      editor = { width = 80, height = 24 },
      measurements = { measured = {
        screen_width = 9,
        chrome = { top = 1, right = 0, bottom = 1, left = 0 },
      } },
    })
    assert.are.equal(9, frame.layers[1].rect.width)
    assert.are.equal(71, frame.layers[1].rect.col)
    assert.are.same({ top = 1, right = 0, bottom = 1, left = 0 },
      frame.panes.measured.chrome)
  end)

  it("projects root, layout, and Pane bindings in precedence order", function()
    local transcript = new_pane("transcript")
    local close = Applet.Pane.nodes.action
    local value = {
      root = ui.frame({
        key = "frame",
        child = ui.scope({
          key = "nested",
          bindings = {
            { mode = "n", lhs = "q", action = close("custom.nested") },
          },
          child = pane("transcript", transcript, {
            bindings = {
              { mode = "n", lhs = "q", action = close("custom.pane") },
            },
          }),
        }),
      }),
      bindings = {
        { mode = "n", lhs = "q", action = close("applet.close") },
      },
    }
    local frame = compile({
      tree = value,
      host = host.tab(),
      editor = { width = 40, height = 10 },
      handlers = { ["custom.nested"] = true, ["custom.pane"] = true },
    })
    local scopes = frame.panes.transcript.scopes
    assert.are.equal("root", scopes[1].kind)
    assert.are.equal("nested", scopes[2].key)
    assert.are.equal("pane", scopes[3].kind)
    assert.are.equal("custom.pane", scopes[3].bindings[1].action.action)
  end)

  it("rejects malformed, cyclic, conflicting, and impossible Trees", function()
    local first, second = new_pane("one"), new_pane("two")
    error_matches("duplicates", function()
      compile({
        tree = tree(pane("one", first), pane("one", first)),
        host = host.tab(),
        editor = { width = 40, height = 10 },
      })
    end)
    local same_first, same_second = new_pane("same"), new_pane("same")
    error_matches("duplicates", function()
      compile({
        tree = tree(pane("same", same_first), pane("same", same_second)),
        host = host.tab(),
        editor = { width = 40, height = 10 },
      })
    end)
    local cyclic = ui.scope({ key = "cycle", bindings = {} })
    cyclic.child = cyclic
    error_matches("cycle", function()
      compile({
        tree = { root = ui.frame({ key = "frame", child = cyclic }) },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
    error_matches("unknown", function()
      compile({
        tree = {
          root = ui.frame({ key = "frame", child = pane("one", first) }),
          bindings = {
            { lhs = "x", action = Applet.Pane.nodes.action("missing.action") },
          },
        },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
    error_matches("must be mount, scope, or split", function()
      compile({
        tree = { root = ui.frame({
          key = "frame",
          child = { type = "unknown", key = "unknown" },
        }) },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
    error_matches("must be mount, scope, or split", function()
      compile({
        tree = { root = ui.frame({
          key = "frame",
          child = pane("one", first),
          layers = {
            ui.layer({
              key = "invalid-content-layer",
              height = { content = true },
              child = { type = "unknown", key = "unknown-content" },
            }),
          },
        }) },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
    error_matches("requires an editable Pane", function()
      compile({
        tree = { root = ui.frame({
          key = "frame",
          child = pane("one", first, { mode = "insert" }),
        }) },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
    local invalid = ui.mount(first, { registry = true })
    error_matches("not a recognized field", function()
      compile({
        tree = { root = ui.frame({ key = "frame", child = invalid }) },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)

    error_matches("dense list", function()
      compile({
        tree = { root = ui.frame({
          key = "frame",
          child = ui.split({
            key = "sparse",
            axis = "vertical",
            children = {
              [1] = { key = "one", child = pane("one", first) },
              [3] = { key = "two", child = pane("two", second) },
            },
          }),
        }) },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
    error_matches("recognized border", function()
      compile({
        tree = { root = ui.frame({
          key = "frame",
          child = pane("one", first, { border = "invented" }),
        }) },
        host = host.floating(), editor = { width = 40, height = 10 },
      })
    end)
    error_matches("requires a transient Pane", function()
      compile({
        tree = { root = ui.frame({ key = "frame", child = ui.mount(first, {
          lifecycle = "retained",
          buffer = { sensitive = true },
        }) }) },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
    error_matches("swapfile", function()
      compile({
        tree = { root = ui.frame({ key = "frame", child = ui.mount(first, {
          lifecycle = "transient",
          buffer = { sensitive = true, options = { swapfile = true } },
        }) }) },
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
    error_matches("active modal boundary", function()
      local modal = new_pane("modal")
      local value = tree(pane("one", first), pane("two", second), {
        ui.layer({
          key = "modal-layer",
          modal = true,
          child = pane("modal", modal),
        }),
      })
      value.focus.initial = "one"
      value.focus.intent = { key = "one" }
      compile({
        tree = value,
        host = host.tab(), editor = { width = 40, height = 10 },
      })
    end)
  end)
end)
