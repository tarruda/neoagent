local Applet = require("applet")
local layout = Applet.layout
local ui = Applet.Pane.nodes

local sequence = 0

local function component(key, opts)
  opts = opts or {}
  sequence = sequence + 1
  local value = Applet.Pane.new({
    key = key,
    buffer_mode = opts.mode or "managed",
    render = function(state)
      if state.fail then error(state.fail) end
      return ui.text({ key = "content", text = state.text or "" })
    end,
  })
  value:set_state({ text = opts.text or "", fail = opts.fail })
  return value
end

local function pane(key, value, opts)
  opts = opts or {}
  assert.are.equal(key, value:key())
  return layout.mount(value, {
    lifecycle = opts.lifecycle or "retained",
    owns_pane = opts.owns_pane,
    required = opts.required ~= false,
    mount_revision = opts.mount_revision,
    buffer = {
      name = opts.name or key,
      uri = opts.uri,
      filetype = opts.filetype or "applet-boundary",
      sensitive = opts.sensitive,
      options = opts.buffer_options,
    },
    window = {
      border = opts.border or "single",
      options = opts.window_options or { wrap = true },
      host_options = opts.host_options,
    },
    focus = {
      mode = opts.focus_mode,
      cursor = opts.cursor,
    },
  })
end

local function frame(child, opts)
  opts = opts or {}
  return {
    root = layout.frame({
      key = "frame",
      child = child,
      layers = opts.layers,
    }),
    focus = { initial = opts.focus },
  }
end

local function split(axis, children, key)
  return layout.split({ key = key or "split", axis = axis, children = children })
end

local function host(kind, opts)
  if kind == "tab" then return Applet.host.tab(opts or { label = "Boundary" }) end
  return Applet.host.floating(opts or { width = 60, height = 20 })
end

local function succeeds(ok, err)
  assert(ok, err and err.message or tostring(err))
  return ok
end

describe("Applet ownership boundaries", function()
  local applets = {}
  local panes = {}
  local foreign_buffers = {}

  local function new_pane(key, opts)
    local value = component(key, opts)
    panes[#panes + 1] = value
    return value
  end

  local function applet(opts)
    local value = Applet.new(opts)
    applets[#applets + 1] = value
    return value
  end

  before_each(function()
    vim.o.columns = 100
    vim.o.lines = 35
    vim.cmd("stopinsert")
  end)

  after_each(function()
    for _, value in ipairs(applets) do value:destroy() end
    for _, value in ipairs(panes) do
      if not value.destroyed then value:destroy() end
    end
    for _, buffer in ipairs(foreign_buffers) do
      if vim.api.nvim_buf_is_valid(buffer) then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
    end
    applets, panes, foreign_buffers = {}, {}, {}
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
    vim.cmd("stopinsert")
  end)

  for _, kind in ipairs({ "floating", "tab" }) do
    it("replaces a " .. kind .. " Pane buffer identity atomically", function()
      local content = new_pane("content", { text = "retained content" })
      local value = applet({
        name = "buffer-identity-" .. kind,
        host = host(kind),
      })
      local function requested(uri, options)
        return frame(pane("content", content, {
          uri = uri,
          buffer_options = options,
          host_options = {
            floating = { list = true },
            tab = { list = true },
          },
        }), { focus = "content" })
      end
      value:update(requested("applet://boundary/one", { buflisted = true }))
      succeeds(value:open())
      local original = value:pane("content"):native()
      assert.is_true(vim.api.nvim_get_option_value("buflisted", {
        buf = original.buffer,
      }))
      assert.is_true(vim.api.nvim_get_option_value("list", {
        win = original.window,
      }))

      value:update(requested("applet://boundary/two"))
      succeeds(value:flush())
      local replacement = value:pane("content"):native()
      assert.are_not.equal(original.buffer, replacement.buffer)
      assert.is_false(vim.api.nvim_buf_is_valid(original.buffer))
      assert.are.equal(replacement.buffer, content.surface.buffer)
      assert.are.same({ "retained content" },
        vim.api.nvim_buf_get_lines(replacement.buffer, 0, -1, false))
    end)
  end

  it("retires a sensitive transient buffer before an ordinary generation", function()
    local secret = new_pane("presentation", { mode = "editable" })
    local ordinary = new_pane("presentation", { mode = "editable" })
    local value = applet({
      name = "sensitive-generation",
      host = host("floating"),
    })
    local function requested(component, revision, sensitive)
      return frame(pane("presentation", component, {
        lifecycle = "transient",
        owns_pane = true,
        mount_revision = revision,
        sensitive = sensitive,
        focus_mode = "insert",
        buffer_options = {
          buftype = "nofile",
          swapfile = false,
          undofile = false,
        },
      }), { focus = "presentation" })
    end

    value:update(requested(secret, "secret", true))
    succeeds(value:open())
    assert(secret:replace_text("s3cr3t"))
    local secret_buffer = assert(secret:native().buffer)
    local host_window = assert(secret:native().window)
    vim.cmd("belowright split")
    local foreign_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(foreign_window, secret_buffer)
    vim.api.nvim_set_current_win(host_window)

    value:update(requested(ordinary, "ordinary", false))
    succeeds(value:flush())
    local ordinary_buffer = assert(ordinary:native().buffer)
    assert.are_not.equal(secret_buffer, ordinary_buffer)
    assert.is_false(vim.api.nvim_buf_is_valid(secret_buffer))
    assert.are_not.equal(secret_buffer,
      vim.api.nvim_win_get_buf(foreign_window))

    assert(ordinary:replace_text("ordinary prompt"))
    vim.api.nvim_buf_call(ordinary_buffer, function()
      vim.cmd("silent! undo")
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(
      ordinary_buffer, 0, -1, false), "\n")
    assert.is_nil(text:find("s3cr3t", 1, true))
  end)

  it("restores a removed buffer option on a retained Pane", function()
    local content = new_pane("content", { text = "options" })
    local value = applet({
      name = "buffer-option-removal",
      host = host("floating"),
    })
    local function requested(options)
      return frame(pane("content", content, {
        buffer_options = options,
      }), { focus = "content" })
    end
    value:update(requested({ buflisted = true }))
    succeeds(value:open())
    local native = value:pane("content"):native()
    assert.is_true(vim.api.nvim_get_option_value("buflisted", { buf = native.buffer }))
    value:update(requested())
    succeeds(value:flush())
    assert.is_false(vim.api.nvim_get_option_value("buflisted", { buf = native.buffer }))
  end)

  it("cleans a buffer whose explicit URI collides with another Applet", function()
    local first_content = new_pane("content", { text = "first" })
    local second_content = new_pane("content", { text = "second" })
    local uri = "applet://boundary/shared"
    local first = applet({ name = "uri-owner", host = host("floating") })
    first:update(frame(pane("content", first_content, { uri = uri })))
    succeeds(first:open())
    local buffers = #vim.api.nvim_list_bufs()

    local second = applet({ name = "uri-collision", host = host("floating") })
    second:update(frame(pane("content", second_content, { uri = uri })))
    local opened, err = second:open()
    assert.is_nil(opened)
    assert.matches("failed to name Pane buffer", err.message)
    assert.are.equal(buffers, #vim.api.nvim_list_bufs())
    assert.is_true(first:pane("content"):is_mounted())
  end)

  it("projects scoped horizontal topology and moves one Pane through a Layer", function()
    local stable = new_pane("stable", { text = "stable" })
    local movable = new_pane("movable", { text = "movable" })
    local value = applet({
      name = "portable-pane-projection",
      host = host("tab"),
    })
    local function main_with_movable()
      return layout.scope({
        key = "outer-scope",
        child = split("horizontal", {
          { key = "stable", grow = 1,
            child = layout.scope({ key = "stable-scope",
              child = pane("stable", stable) }) },
          { key = "movable", grow = 1,
            child = layout.scope({ key = "movable-scope",
              child = pane("movable", movable) }) },
        }, "horizontal-main"),
      })
    end
    value:update(frame(main_with_movable(), { focus = "movable" }))
    succeeds(value:open())
    assert.are.equal("", vim.api.nvim_win_get_config(
      value:pane("movable"):native().window).relative)

    value:update(frame(pane("stable", stable), {
      focus = "movable",
      layers = {
        layout.layer({
          key = "movable-layer",
          width = 24,
          height = 6,
          enter = true,
          child = pane("movable", movable),
        }),
      },
    }))
    succeeds(value:flush())
    assert.are_not.equal("", vim.api.nvim_win_get_config(
      value:pane("movable"):native().window).relative)

    value:update(frame(main_with_movable(), { focus = "movable" }))
    succeeds(value:flush())
    assert.are.equal("", vim.api.nvim_win_get_config(
      value:pane("movable"):native().window).relative)
  end)

  it("builds nested split topology from each descendant Pane", function()
    local first = new_pane("first", { text = "first" })
    local second = new_pane("second", { text = "second" })
    local third = new_pane("third", { text = "third" })
    local value = applet({
      name = "nested-tab-topology",
      host = host("tab"),
    })
    value:update(frame(split("horizontal", {
      { key = "first", grow = 1, child = pane("first", first) },
      { key = "nested", grow = 1, child = split("vertical", {
        { key = "second", grow = 1, child = pane("second", second) },
        { key = "third", grow = 1, child = pane("third", third) },
      }, "nested-vertical") },
    }, "outer-horizontal"), { focus = "first" }))
    succeeds(value:open())
    local layout = vim.fn.winlayout()
    assert.are.equal("row", layout[1])
    assert.are.equal("col", layout[2][2][1])
    assert.is_true(value:pane("first"):is_mounted())
    assert.is_true(value:pane("second"):is_mounted())
    assert.is_true(value:pane("third"):is_mounted())
  end)

  it("orders directional focus by primary and secondary distance", function()
    local first = new_pane("first", { text = "first" })
    local second = new_pane("second", { text = "second" })
    local third = new_pane("third", { text = "third" })
    local value = applet({
      name = "directional-focus-distance",
      host = host("floating"),
    })
    local function requested(child)
      local result = frame(child, { focus = "first" })
      result.bindings = {
        {
          mode = "n",
          lhs = "m",
          action = ui.action("applet.focus.move", {
            direction = "right",
          }),
        },
      }
      return result
    end
    value:update(requested(split("horizontal", {
      { key = "first", grow = 1, child = pane("first", first) },
      { key = "second", grow = 1, child = pane("second", second) },
      { key = "third", grow = 1, child = pane("third", third) },
    }, "distance-row")))
    succeeds(value:open())
    local dispatch = require("applet.pane.input").dispatch
    assert.is_true(dispatch(first, "n", "m"))
    assert.are.equal("second", value:focused_pane())

    value:update(requested(split("horizontal", {
      { key = "first", grow = 1, child = pane("first", first) },
      { key = "right", grow = 1, child = split("vertical", {
        { key = "second", grow = 1, child = pane("second", second) },
        { key = "third", grow = 1, child = pane("third", third) },
      }, "distance-column") },
    }, "distance-grid")))
    succeeds(value:flush())
    succeeds(value:focus("first"))
    assert.is_true(dispatch(first, "n", "m"))
    assert.is_true(value:focused_pane() == "second"
      or value:focused_pane() == "third")
  end)

  it("leaves one editor tab when its Host is the final tab", function()
    local content = new_pane("content", { text = "last tab" })
    local origin = vim.api.nvim_get_current_tabpage()
    local value = applet({
      name = "final-tab-release",
      host = host("tab"),
    })
    value:update(frame(pane("content", content), { focus = "content" }))
    succeeds(value:open())
    local host_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(origin)
    vim.cmd("tabclose!")
    assert.are.equal(host_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(1, #vim.api.nvim_list_tabpages())

    succeeds(value:close({ restore_origin = false }))
    assert.are.equal(1, #vim.api.nvim_list_tabpages())
    assert.is_false(vim.api.nvim_tabpage_is_valid(host_tab))
  end)

  it("places tab Hosts at each declared position", function()
    for _, position in ipairs({ "first", "last", "before" }) do
      local content = new_pane("content", { text = position })
      vim.cmd("tabnew")
      local origin = vim.api.nvim_get_current_tabpage()
      local value = applet({
        name = "tab-position-" .. position,
        host = host("tab", { label = position, position = position }),
      })
      value:update(frame(pane("content", content)))
      succeeds(value:open())
      local tab = vim.api.nvim_win_get_tabpage(value:pane("content"):native().window)
      if position == "first" then
        assert.are.equal(1, vim.api.nvim_tabpage_get_number(tab))
      elseif position == "last" then
        assert.are.equal(#vim.api.nvim_list_tabpages(),
          vim.api.nvim_tabpage_get_number(tab))
      else
        assert.is_true(vim.api.nvim_tabpage_get_number(tab)
          < vim.api.nvim_tabpage_get_number(origin))
      end
      value:destroy()
    end
  end)

  it("publishes an inactive shadow tab without stealing focus", function()
    local first = new_pane("first", { text = "first" })
    local second = new_pane("second", { text = "second" })
    local third = new_pane("third", { text = "third" })
    local origin = vim.api.nvim_get_current_tabpage()
    local value = applet({ name = "inactive-shadow", host = host("tab") })
    local function requested(include_third)
      local children = {
        { key = "first", grow = 1, child = pane("first", first) },
        { key = "second", grow = 1, child = pane("second", second) },
      }
      if include_third then
        children[#children + 1] = {
          key = "third", grow = 1, child = pane("third", third),
        }
      end
      return frame(split("vertical", children, "main"))
    end
    value:update(requested(false))
    succeeds(value:open())
    vim.api.nvim_set_current_tabpage(origin)
    value:update(requested(true))
    succeeds(value:flush())
    assert.are.equal(origin, vim.api.nvim_get_current_tabpage())
    assert.is_true(value:pane("third"):is_mounted())
  end)

  it("rolls back a tab topology build failure", function()
    local first = new_pane("first", { text = "first" })
    local second = new_pane("second", { text = "second" })
    local third = new_pane("third", { text = "third" })
    local value = applet({ name = "tab-build-rollback", host = host("tab") })
    local function requested(include_third)
      local children = {
        { key = "first", grow = 1, child = pane("first", first) },
        { key = "second", grow = 1, child = pane("second", second) },
      }
      if include_third then
        children[#children + 1] = {
          key = "third", grow = 1, child = pane("third", third),
        }
      end
      return frame(split("vertical", children, "main"))
    end
    value:update(requested(false))
    succeeds(value:open())
    local first_native, second_native = value:pane("first"):native(),
      value:pane("second"):native()
    local original_open = vim.api.nvim_open_win
    vim.api.nvim_open_win = function(buffer, enter, config)
      if config and config.split then error("injected split creation failure") end
      return original_open(buffer, enter, config)
    end
    value:update(requested(true))
    local call_ok, committed, err = pcall(value.flush, value)
    vim.api.nvim_open_win = original_open
    assert.is_true(call_ok)
    assert.is_nil(committed)
    assert.matches("injected split creation failure", err.message)
    assert.are.same(first_native, value:pane("first"):native())
    assert.are.same(second_native, value:pane("second"):native())
  end)

  it("rolls back added and reconfigured tab Layers after content failure", function()
    local main = new_pane("main", { text = "main" })
    local existing = new_pane("existing", { text = "existing" })
    local broken = new_pane("broken", { fail = "injected Layer failure" })
    local value = applet({ name = "tab-layer-rollback", host = host("tab") })
    local function layer(key, content, width)
      return layout.layer({
        key = key .. "-layer",
        width = width,
        height = 5,
        child = pane(key, content),
      })
    end
    value:update(frame(pane("main", main), {
      layers = { layer("existing", existing, 20) },
    }))
    succeeds(value:open())
    local existing_native = value:pane("existing"):native()
    local original_config = vim.api.nvim_win_get_config(existing_native.window)
    local windows = #vim.api.nvim_list_wins()

    value:update(frame(pane("main", main), {
      layers = {
        layer("existing", existing, 30),
        layer("broken", broken, 15),
      },
    }))
    local committed, err = value:flush()
    assert.is_nil(committed)
    assert.matches("injected Layer failure", err.message)
    assert.are.equal(windows, #vim.api.nvim_list_wins())
    assert.are.same(original_config,
      vim.api.nvim_win_get_config(existing_native.window))
    assert.are.same(existing_native, value:pane("existing"):native())
  end)

  it("adds and removes a tab Layer without rebuilding main topology", function()
    local main = new_pane("main", { text = "main" })
    local overlay = new_pane("overlay", { text = "overlay" })
    local value = applet({ name = "tab-layer-reconcile", host = host("tab") })
    value:update(frame(pane("main", main)))
    succeeds(value:open())
    local main_native = value:pane("main"):native()
    local requested = frame(pane("main", main), {
      layers = {
        layout.layer({
          key = "overlay-layer",
          width = 20,
          height = 5,
          child = pane("overlay", overlay),
        }),
      },
    })
    value:update(requested)
    succeeds(value:flush())
    assert.are_not.equal("", vim.api.nvim_win_get_config(
      value:pane("overlay"):native().window).relative)
    value:update(frame(pane("main", main)))
    succeeds(value:flush())
    assert.are.same(main_native, value:pane("main"):native())
    assert.is_false(value:pane("overlay"):is_mounted())
  end)

  it("releases an unobserved floating window after its buffer changes", function()
    local content = new_pane("content", { text = "owned" })
    local value = applet({ name = "unobserved-buffer-change", host = host("floating") })
    local requested = frame(pane("content", content))
    value:update(requested)
    succeeds(value:open())
    local native = value:pane("content"):native()
    local replacement = vim.api.nvim_create_buf(false, true)
    foreign_buffers[#foreign_buffers + 1] = replacement
    vim.api.nvim_win_call(native.window, function()
      vim.cmd("noautocmd buffer " .. replacement)
    end)
    value:update(requested)
    succeeds(value:flush())
    assert.is_true(vim.api.nvim_win_is_valid(native.window))
    assert.are.equal(replacement, vim.api.nvim_win_get_buf(native.window))
    assert.are_not.equal(native.window, value:pane("content"):native().window)
  end)

  for _, kind in ipairs({ "floating", "tab" }) do
    it("focuses an inactive " .. kind .. " Host tab", function()
      local content = new_pane("content", { text = "focus" })
      local value = applet({ name = "inactive-focus-" .. kind, host = host(kind) })
      value:update(frame(pane("content", content), { focus = "content" }))
      succeeds(value:open())
      local host_tab = vim.api.nvim_win_get_tabpage(value:pane("content"):native().window)
      vim.cmd("tabnew")
      assert.are_not.equal(host_tab, vim.api.nvim_get_current_tabpage())
      assert.is_true(value:pane("content"):focus())
      assert.are.equal(host_tab, vim.api.nvim_get_current_tabpage())
    end)
  end

  it("supports native tab-call and tab-close primitives when available", function()
    local original_call = vim.api.nvim_tabpage_call
    local original_close = vim.api.nvim_tabpage_close
    local calls, closes = 0, 0
    vim.api.nvim_tabpage_call = function(tab, callback)
      calls = calls + 1
      local current = vim.api.nvim_get_current_tabpage()
      if current ~= tab then vim.api.nvim_set_current_tabpage(tab) end
      local results = { pcall(callback) }
      if vim.api.nvim_tabpage_is_valid(current)
          and vim.api.nvim_get_current_tabpage() ~= current then
        vim.api.nvim_set_current_tabpage(current)
      end
      if not results[1] then error(results[2], 0) end
      return unpack(results, 2)
    end
    vim.api.nvim_tabpage_close = function(tab, force)
      closes = closes + 1
      local number = vim.api.nvim_tabpage_get_number(tab)
      vim.cmd((force and "tabclose! " or "tabclose ") .. number)
    end
    local content = new_pane("content", { text = "boundary" })
    local value = applet({ name = "native-tab-primitives", host = host("tab") })
    value:update(frame(pane("content", content)))
    local call_ok, err = pcall(function()
      succeeds(value:open())
      succeeds(value:close())
    end)
    vim.api.nvim_tabpage_call = original_call
    vim.api.nvim_tabpage_close = original_close
    assert(call_ok, err)
    assert.is_true(calls > 0)
    assert.is_true(closes > 0)
  end)

  it("keeps an owned Pane alive when it moves to another Pane", function()
    local moved = new_pane("moved", { text = "moved" })
    local replacement = new_pane("first", { text = "replacement" })
    local value = applet({ name = "applet-move", host = host("floating") })
    value:update(frame(pane("moved", moved, { owns_pane = true })))
    succeeds(value:open())
    value:update(frame(split("horizontal", {
      { key = "first", grow = 1, child = pane("first", replacement) },
      { key = "second", grow = 1,
        child = pane("moved", moved, { owns_pane = true }) },
    }, "moved-main")))
    succeeds(value:flush())
    assert.is_false(moved.destroyed)
    assert.are.equal(moved.surface.buffer, value:pane("moved"):native().buffer)
  end)

  it("validates direct Trees against resolver Hosts and invalidates closed state", function()
    local content = new_pane("content", { text = "state" })
    local value = applet({
      name = "direct-tree-resolver",
      host = host("floating"),
      render = function() return frame(pane("content", content)) end,
    })
    value:update(frame(pane("content", content)))
    value:set_host(function() return host("floating") end)
    local committed, err = value:flush()
    assert.is_nil(committed)
    assert.matches("resolver requires state%-driven rendering", err.message)
    value:set_host(host("tab"))
    local generation = value:invalidate({ reset_sizes = true })
    assert.are.equal(generation + 1, value:invalidate({}))
    succeeds(value:flush())
    assert.are.equal("tab", value:host().kind)
  end)

  it("restores an Insert-mode origin request", function()
    local base = require("applet.host.base")
    local window = vim.api.nvim_get_current_win()
    assert.is_true(base.restore_origin({
      tab = vim.api.nvim_get_current_tabpage(),
      window = window,
      mode = "i",
      cursor = vim.api.nvim_win_get_cursor(window),
      view = vim.fn.winsaveview(),
    }))
    vim.cmd("stopinsert")
  end)
end)
