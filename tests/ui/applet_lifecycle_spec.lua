local assert = require("luassert")
local Applet = require("applet")
local layout = Applet.layout
local ui = Applet.Pane.nodes

local sequence = 0

---@generic T
---@param ok T
---@param err? Applet.Error
---@return T
local function succeeds(ok, err)
  assert(ok, err and err.message or tostring(err))
  return ok
end

---@param key string
---@param mode? "managed"|"editable"
---@param text? string
---@return Applet.Pane<{text: string}>
local function component(key, mode, text)
  sequence = sequence + 1
  local value = Applet.Pane.new({
    key = key,
    buffer_mode = mode or "managed",
    ---@param state {text: string}
    render = function(state)
      return ui.text({ key = "content", text = state.text or "" })
    end,
  })
  value:set_state({ text = text or "" })
  return value
end

---@class Applet.LifecycleTestMountOptions
---@field lifecycle? Applet.MountLifecycle
---@field required? boolean
---@field sensitive? boolean
---@field border? Applet.WindowBorder
---@field mode? "normal"|"insert"|"preserve"

---@param key string
---@param value Applet.Pane
---@param opts? Applet.LifecycleTestMountOptions
---@return Applet.MountNode
local function pane(key, value, opts)
  opts = opts or {}
  assert.are.equal(key, value:key())
  return layout.mount(value, {
    lifecycle = opts.lifecycle or "retained",
    required = opts.required ~= false,
    buffer = {
      name = key,
      sensitive = opts.sensitive,
      filetype = "applet-lifecycle",
    },
    window = {
      border = opts.border or "none",
      options = { wrap = true },
    },
    focus = { mode = opts.mode },
  })
end

---@class Applet.LifecycleTestTreeOptions
---@field second_height? integer
---@field third? Applet.Pane
---@field revision? integer
---@field layers? Applet.LayoutLayerNode[]
---@field intent? {key: string, revision?: string|number}

---@param first Applet.Pane
---@param second Applet.Pane
---@param opts? Applet.LifecycleTestTreeOptions
---@return Applet.LayoutTree
local function tree(first, second, opts)
  opts = opts or {}
  ---@type Applet.LayoutSplitChild[]
  local children = {
    { key = "first", grow = 1, min = 2, child = pane("first", first) },
    { key = "second", basis = opts.second_height or 3, grow = 0,
      child = pane("second", second, { mode = "insert" }) },
  }
  if opts.third then
    children[#children + 1] = {
      key = "third", basis = 3, grow = 0,
      child = pane("third", opts.third),
    }
  end
  return {
    root = layout.frame({
      key = "frame",
      child = layout.split({
        key = "main",
        axis = "vertical",
        revision = opts.revision,
        children = children,
      }),
      layers = opts.layers,
    }),
    focus = { initial = "second", intent = opts.intent },
  }
end

describe("Applet lifecycle", function()
  ---@type Applet.Applet[]
  local applets = {}
  ---@type Applet.Pane[]
  local panes = {}

  before_each(function()
    vim.o.columns = 100
    vim.o.lines = 35
    vim.cmd("stopinsert")
  end)

  after_each(function()
    for _, applet in ipairs(applets) do applet:destroy() end
    for _, pane_value in ipairs(panes) do
      if not pane_value.destroyed then pane_value:destroy() end
    end
    applets, panes = {}, {}
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
    vim.cmd("stopinsert")
  end)

  ---@param key string
  ---@param mode? "managed"|"editable"
  ---@param text? string
  ---@return Applet.Pane<{text: string}>
  local function new_pane(key, mode, text)
    local value = component(key, mode, text)
    panes[#panes + 1] = value
    return value
  end

  ---@generic S
  ---@param opts Applet.AppletOptions<S>
  ---@return Applet.Applet<S>
  local function applet(opts)
    local value = Applet.new(opts)
    applets[#applets + 1] = value
    return value
  end

  it("finishes closing when a native window-close callback closes it again", function()
    local first, second = new_pane("first"), new_pane("second", "editable")
    local value = applet({ name = "reentrant-close", host = Applet.host.floating({ width = 60, height = 20 }) })
    value:update(tree(first, second))
    succeeds(value:open())
    local window = assert(assert(value:pane("first")):native().window)
    local calls = 0
    local callback = vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(window), once = true,
      callback = function()
        calls = calls + 1
        assert.is_true(value:close())
      end,
    })
    assert.is_true(value:close())
    pcall(vim.api.nvim_del_autocmd, callback)
    assert.are.equal(1, calls)
    assert.is_false(value:is_open())
    assert.is_false(vim.api.nvim_win_is_valid(window))
    assert.is_true(value:close())
  end)

  it("borrows immutable state and Tree submissions by identity", function()
    local first = new_pane("first", "managed", "first")
    local second = new_pane("second", "editable", "draft")
    local submitted = { marker = {} }
    local rendered
    local value = applet({
      name = "borrowed-submissions",
      host = function(state)
        assert.are.equal(submitted, state)
        return Applet.host.floating({ width = 60, height = 20 })
      end,
      render = function(state)
        rendered = state
        return tree(first, second)
      end,
    })

    value:set_state(submitted)
    assert.are.equal(submitted, value.pending_state)
    succeeds(value:open())
    assert.are.equal(submitted, rendered)

    local direct = tree(first, second, { revision = 2 })
    value:update(direct)
    assert.are.equal(direct, value.pending_tree)
  end)

  it("queues Host-kind changes until the next open epoch", function()
    local first = new_pane("first", "managed", "first")
    local second = new_pane("second", "editable", "draft")
    local effects = {}
    local value = applet({
      name = "host-epoch",
      host = Applet.host.floating({ width = 60, height = 20 }),
      notify = function(message, level)
        effects[#effects + 1] = { "notify", message, level }
      end,
      open_uri = function(uri) effects[#effects + 1] = { "uri", uri } end,
    })
    assert.are.equal(1, value:update(tree(first, second)))
    succeeds(value:flush())
    assert.is_false(value:is_open())
    succeeds(value:open())
    assert.are.equal("floating", value:host().kind)

    value:set_host(Applet.host.tab({ label = "Next epoch" }))
    succeeds(value:flush())
    assert.are.equal("floating", value:host().kind)
    value:notify("ready", 2)
    value:open_uri("https://example.test")
    assert.are.same({
      { "notify", "ready", 2 },
      { "uri", "https://example.test" },
    }, effects)

    succeeds(value:toggle())
    assert.is_false(value:is_open())
    succeeds(value:toggle())
    assert.are.equal("tab", value:host().kind)
    assert.are.equal("Next epoch", value:host().label)

    local observed = value:observed()
    rawset(assert(observed.host), "kind", "changed")
    assert.are.equal("tab", value:observed().host.kind)
    local stats = value:_stats()
    stats.renders = -1
    assert.are_not.equal(-1, value:_stats().renders)
  end)

  it("publishes size changes in place and topology changes through a shadow tab", function()
    local first = new_pane("first")
    local second = new_pane("second", "editable")
    local third = new_pane("third")
    local value = applet({
      name = "tab-transactions",
      host = Applet.host.tab({ label = "Transactions" }),
    })
    value:update(tree(first, second))
    succeeds(value:open())
    local first_pane = assert(value:pane("first"))
    local second_pane = assert(value:pane("second"))
    local first_native, second_native = assert(first_pane):native(), assert(second_pane):native()
    local original_tab = vim.api.nvim_win_get_tabpage((assert(first_native.window)))
    local tabs = #vim.api.nvim_list_tabpages()

    value:update(tree(first, second, { second_height = 6 }))
    succeeds(value:flush())
    assert.are.same(first_native, assert(first_pane):native())
    assert.are.same(second_native, assert(second_pane):native())

    value:update(tree(first, second, { second_height = 6, third = third }))
    succeeds(value:flush())
    assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
    assert.is_false(vim.api.nvim_tabpage_is_valid(original_tab))
    assert.are.equal(first_native.buffer, assert(first_pane):native().buffer)
    assert.are.equal(second_native.buffer, assert(second_pane):native().buffer)
    assert.is_true(assert(value:pane("third")):is_mounted())
    assert.are.equal(first_pane, value:pane("first"))
  end)

  it("updates an inactive tab without stealing focus", function()
    local first = new_pane("first", "managed", "before")
    local second = new_pane("second", "editable", "draft")
    local origin_tab = vim.api.nvim_get_current_tabpage()
    local value = applet({
      name = "inactive-tab",
      host = Applet.host.tab({ label = "Background" }),
    })
    local requested = tree(first, second)
    value:update(requested)
    succeeds(value:open())
    local buffer = assert(value:pane("first")):native().buffer
    vim.api.nvim_set_current_tabpage(origin_tab)
    assert.is_false(value:is_visible())

    first:set_state({ text = "after" })
    value:update(requested)
    succeeds(value:flush())
    assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage())
    assert.are.same({ "after" },
      vim.api.nvim_buf_get_lines((assert(buffer)), 0, -1, false))
    assert.is_false(value:is_visible())
  end)

  it("preserves foreign tab windows and relinquishes shared buffers", function()
    local first = new_pane("first")
    local second = new_pane("second", "editable")
    local third = new_pane("third")
    local value = applet({
      name = "foreign-window",
      host = Applet.host.tab({ label = "Foreign window" }),
    })
    local requested = tree(first, second)
    value:update(requested)
    succeeds(value:open())
    local owned = assert(value:pane("first")):native()
    vim.api.nvim_set_current_win((assert(owned.window)))
    vim.cmd("vsplit")
    local foreign = vim.api.nvim_get_current_win()
    assert.are.equal(owned.buffer, vim.api.nvim_win_get_buf(foreign))
    assert(vim.wait(1000, function()
      return value:observed().foreign_windows == 1
    end))

    first:set_state({ text = "shared update" })
    value:update(requested)
    succeeds(value:flush())
    assert.is_true(vim.api.nvim_win_is_valid(foreign))

    value:update(tree(first, second, { third = third }))
    local committed, err = value:flush()
    assert.is_nil(committed)
    assert.matches("foreign windows", assert(err).message)
    assert.is_true(vim.api.nvim_win_is_valid(foreign))
    assert.are.equal(owned.buffer, vim.api.nvim_win_get_buf(foreign))

    value:close()
    assert.is_true(vim.api.nvim_win_is_valid(foreign))
    value:destroy()
    assert.is_true(vim.api.nvim_win_is_valid(foreign))
    assert.is_true(vim.api.nvim_buf_is_valid((assert(owned.buffer))))
    assert.are.same({ "shared update" },
      vim.api.nvim_buf_get_lines((assert(owned.buffer)), 0, -1, false))
  end)

  it("restores focus through nested Layers and releases a detached modal boundary", function()
    local first = new_pane("first")
    local second = new_pane("second", "editable")
    local details, dialog = new_pane("details"), new_pane("dialog")
    local value = applet({
      name = "nested-layers",
      host = Applet.host.floating({ width = 70, height = 24 }),
    })
    value:update(tree(first, second))
    succeeds(value:open())
    assert.are.equal("second", value:focused_pane())

    local detail_layer = layout.layer({
      key = "details-layer", width = 30, height = 8, enter = true,
      restore_focus = true, child = pane("details", details),
    })
    local dialog_layer = layout.layer({
      key = "dialog-layer", width = 24, height = 6, zindex = 90,
      modal = true, enter = true, restore_focus = true,
      child = pane("dialog", dialog),
    })
    value:update(tree(first, second, { layers = { detail_layer, dialog_layer } }))
    succeeds(value:flush())
    assert.are.equal("dialog", value:focused_pane())
    assert.is_false(value:focus("second"))

    value:update(tree(first, second, { layers = { detail_layer } }))
    succeeds(value:flush())
    assert.are.equal("details", value:focused_pane())
    value:update(tree(first, second))
    succeeds(value:flush())
    assert.are.equal("second", value:focused_pane())

    value:update(tree(first, second, { layers = { dialog_layer } }))
    succeeds(value:flush())
    vim.api.nvim_win_close(assert(assert(value:pane("dialog")):native().window), true)
    assert(vim.wait(1000, function()
      return not assert(value:pane("dialog")):is_mounted()
    end))
    assert.is_true(value:focus("second"))
  end)

  it("applies each focus intent revision once", function()
    local first = new_pane("first", "managed", "first")
    local second = new_pane("second", "editable", "second")
    local value = applet({
      name = "focus-intent-revisions",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    value:update(tree(first, second))
    succeeds(value:open())
    assert.are.equal("second", value:focused_pane())

    value:update(tree(first, second, {
      intent = { key = "first", revision = 1 },
    }))
    succeeds(value:flush())
    assert.are.equal("first", value:focused_pane())
    succeeds(value:focus("second"))

    value:update(tree(first, second, {
      intent = { key = "first", revision = 1 },
    }))
    succeeds(value:flush())
    assert.are.equal("second", value:focused_pane())

    value:update(tree(first, second, {
      intent = { key = "first", revision = 2 },
    }))
    succeeds(value:flush())
    assert.are.equal("first", value:focused_pane())

    value:update(tree(first, second))
    succeeds(value:flush())
    succeeds(value:focus("second"))
    value:update(tree(first, second, {
      intent = { key = "first", revision = 2 },
    }))
    succeeds(value:flush())
    assert.are.equal("first", value:focused_pane())

    for revision = 3, 302 do
      value:update(tree(first, second, {
        intent = { key = revision % 2 == 0 and "first" or "second",
          revision = revision },
      }))
      succeeds(value:flush())
    end
    assert.are.equal("first\0" .. "302", value.applied_focus_intent)
    assert.is_nil(rawget(value, "applied_focus_intents"))
  end)

  it("keeps Pane editing semantic while mounted and retained", function()
    local first = new_pane("first", "managed", "read only")
    local second = new_pane("second", "editable", "one\ntwo\nthree")
    local value = applet({
      name = "pane-editing",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    value:update(tree(first, second))
    succeeds(value:open())
    local editable = assert(value:pane("second"))
    assert.is_true(assert(editable):replace_text("one\ntwo\nthree", nil, 1))
    assert.are.equal("one\ntwo\nthree", assert(editable):text())
    assert.is_true(assert(editable):set_cursor({ line = 1, column = 0 }))
    assert.is_true(assert(editable):at_start())
    assert.is_true(assert(editable):move_cursor("end"))
    assert.is_true(assert(editable):at_end())
    assert.is_true(assert(editable):move_cursor("up", 2))
    assert.are.same({ line = 1, column = 3 }, assert(editable):cursor())
    assert.is_true(assert(editable):move_cursor("down"))
    assert.is_true(assert(editable):move_cursor("start"))
    assert.is_true(assert(editable):replace_text("changed", { line = 1, column = 7 }, 4))
    assert.is_false(assert(editable):replace_text("ignored", nil, 4))
    assert.are.equal("changed", assert(editable):text())
    assert.are.equal("read only", assert(value:pane("first")):text())

    local geometry = assert(editable):geometry()
    assert.are.equal("floating", geometry.host)
    assert.is_nil(rawget(geometry, "buffer"))
    assert.is_nil(rawget(geometry, "window"))
    value:close()
    assert.is_false(assert(editable):is_mounted())
    assert.is_false(assert(editable):scroll({ target = "end" }))
    assert.are.equal("changed", assert(editable):text())
    assert.is_false(editable:complete())
    assert.is_false(editable:completion_move("next"))
    assert.is_false(editable:completion_accept())
    local buffer = assert(editable:native().buffer)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
    assert(editable:replace_text("retained edit", { line = 1, column = 2 }, 5))
    assert.are.equal("retained edit", editable:text())
    assert.is_false(vim.api.nvim_get_option_value("modifiable", { buf = buffer }))
    assert.are.same({ line = 1, column = 2 }, editable:cursor())
    assert(editable:replace_text("retained edit without a cursor"))
    assert.are.same({ line = 1, column = 2 }, editable:cursor())
    succeeds(value:open())
    assert.are.equal("retained edit without a cursor", editable:text())
  end)

  it("reports bounded render, Host, and compilation failures", function()
    local first, second = new_pane("first"), new_pane("second", "editable")
    local errors = {}
    local value = applet({
      name = "failure-phases",
      host = function(state)
        if state.host_error then error("host resolver failed") end
        if state.invalid_host then return { kind = "unknown" } --[[@as Applet.HostInput]] end
        return Applet.host.floating({ width = 60, height = 20 })
      end,
      render = function(state)
        if state.render_error then error("render failed") end
        if state.large_error then error({ message = string.rep("x", 600) }) end
        if state.semantic_error then
          error({ kind = "render", message = "semantic render failed" })
        end
        if state.nil_tree then return nil --[[@as Applet.LayoutTree]] end
        if state.invalid_tree then return { root = {} } --[[@as Applet.LayoutTree]] end
        return tree(first, second)
      end,
      on_error = function(err) errors[#errors + 1] = err end,
    })
    value:set_state({})
    succeeds(value:open())
    local native = assert(value:pane("first")):native()

    for _, case in ipairs({
      { state = { host_error = true }, phase = "host", text = "resolver failed" },
      { state = { invalid_host = true }, phase = "host", text = "Host.kind" },
      { state = { render_error = true }, phase = "render", text = "render failed" },
      { state = { semantic_error = true }, phase = "render",
        text = "semantic render failed" },
      { state = { nil_tree = true }, phase = "render", text = "returned nil" },
      { state = { invalid_tree = true }, phase = "compile", text = "root" },
    }) do
      value:set_state(case.state)
      local committed, err = value:flush()
      assert.is_nil(committed)
      assert.are.equal(case.phase, assert(err).phase)
      assert.matches(case.text, assert(err).message)
      assert.are.same(native, assert(value:pane("first")):native())
    end
    value:set_state({ large_error = true })
    local committed, err = value:flush()
    assert.is_nil(committed)
    assert.are.equal(string.rep("x", 509) .. "...", assert(err).message)
    assert.are.same(native, assert(value:pane("first")):native())
    assert.are.equal(7, #errors)
  end)

  it("contains stale actions and owns recursive observation payloads", function()
    local first = new_pane("first", "managed", "first")
    local value = applet({
      name = "stale-surface-action",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    value:update({
      root = layout.frame({ key = "frame", child = pane("first", first) }),
      focus = {},
    })
    succeeds(value:open())
    value.focused = nil
    assert.is_false(value:_focus_move({ direction = "right" }))
    assert.is_true(value:focus("first"))
    local invalid_move = { direction = "diagonal" }
    ---@cast invalid_move Applet.FocusMove
    assert.is_false(value:_focus_move(invalid_move))

    local interaction = assert(assert(first.surface).interaction)
    local event = {
      action = "missing.action",
      pane = first,
      count = 1,
      mode = "n",
      row = 0,
      col = 0,
    }
    assert.is_false(interaction.dispatch(event --[[@as Applet.ActionEvent<Applet.Pane>]]))

    local native = { event = "explicit" }
    native.self = native
    value:_schedule_observe("Explicit", native)
    local copied = assert(assert(value.observation_native)[1])
    ---@cast copied table<string, unknown>
    assert.are_not.equal(native, copied)
    assert.are.equal(copied, rawget(copied, "self"))

    assert.is_true(value:close({ restore_origin = false }))
    assert.is_false(interaction.dispatch(event --[[@as Applet.ActionEvent<Applet.Pane>]]))
    value:_sync_observed()
    value:destroy()
    value:_schedule_observe("Explicit", { event = "late" })
    value:_sync_observed()
  end)

  it("validates construction and rejects mutations after destruction", function()
    local floating = Applet.host.floating()
    for _, opts in ipairs({
      {},
      { name = "name" },
      { name = "name", host = false },
      { name = "name", host = floating, handlers = false },
      { name = "name", host = floating, render = false },
      { name = "name", host = floating, notify = false },
      { name = "name", host = floating, on_focus = false },
      { name = "name", host = floating,
        handlers = { ["applet.reserved"] = function() end } },
    }) do
      assert.has_error(function() Applet.new(opts --[[@as Applet.AppletOptions<unknown>]]) end)
    end
    assert.has_error(function()
      Applet.new({ name = "resolver", host = function() return nil --[[@as Applet.HostInput]] end })
    end)

    local value = applet({ name = "destroyed", host = floating })
    value:destroy()
    value:destroy()
    local invalid_tree = {}
    assert.has_error(function()
      value:update(invalid_tree --[[@as Applet.LayoutTree]])
    end, "Applet is destroyed")
    assert.has_error(function() value:open() end, "Applet is destroyed")
    assert.has_error(function() value:notify("message") end,
      "Applet is destroyed")
  end)
end)
