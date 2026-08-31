local Applet = require("applet")
local layout = Applet.layout
local ui = Applet.Pane.nodes

local sequence = 0

local function component(key, mode, text)
  sequence = sequence + 1
  local value = Applet.Pane.new({
    key = key,
    buffer_mode = mode or "managed",
    render = function(state)
      return ui.text({ key = "content", text = state.text or "" })
    end,
  })
  value:set_state({ text = text or "" })
  return value
end

local function pane(key, value, opts)
  opts = opts or {}
  assert.are.equal(key, value:key())
  return layout.mount(value, {
    lifecycle = opts.lifecycle or "retained",
    owns_pane = opts.owns_pane,
    required = true,
    buffer = {
      name = key,
      filetype = "applet-observation",
      options = { swapfile = false, undofile = false },
    },
    window = {
      border = opts.border or "single",
      options = { wrap = true, linebreak = true },
    },
    focus = { mode = opts.mode },
  })
end

local function tree(first, second)
  local child = pane("first", first, { mode = "normal" })
  if second then
    child = layout.split({
      key = "main",
      axis = "vertical",
      children = {
        { key = "first", grow = 1, min = 3,
          child = child },
        { key = "second", basis = { content = 3 }, grow = 0,
          child = pane("second", second, { mode = "insert" }) },
      },
    })
  end
  return {
    root = layout.frame({ key = "frame", child = child }),
    focus = { initial = second and "second" or "first" },
  }
end

local function succeeds(ok, err)
  assert(ok, err and err.message or tostring(err))
  return ok
end

local function wait_for(predicate)
  assert(vim.wait(1500, predicate, 5), "timed out waiting for Applet observation")
end

describe("Applet observation", function()
  local applets = {}
  local panes = {}
  local foreign_windows = {}
  local foreign_buffers = {}

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
    for _, window in ipairs(foreign_windows) do
      if vim.api.nvim_win_is_valid(window) then
        pcall(vim.api.nvim_win_close, window, true)
      end
    end
    for _, buffer in ipairs(foreign_buffers) do
      if vim.api.nvim_buf_is_valid(buffer) then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
    end
    applets, panes = {}, {}
    foreign_windows, foreign_buffers = {}, {}
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
    vim.cmd("stopinsert")
  end)

  local function new_pane(key, mode, text)
    local value = component(key, mode, text)
    panes[#panes + 1] = value
    return value
  end

  local function applet(opts)
    local value = Applet.new(opts)
    applets[#applets + 1] = value
    return value
  end

  it("publishes one ordered callback batch before applying callback mutations", function()
    local first, second = new_pane("first", "managed", "first"),
      new_pane("second", "editable")
    local events, expired_default = {}, nil
    local value
    local function observe(event, default)
      events[#events + 1] = event.kind
      assert.are.equal(event.revision, value:observed().revision)
      assert.are.equal(event.request_generation,
        value:observed().request_generation)
      local native = event.native()
      native.events[1] = "changed"
      assert.are_not.equal("changed", event.native().events[1])
      assert.is_true(default())
      assert.is_false(default())
      expired_default = default
      if event.kind == "pane_close" then value:close() end
    end
    value = applet({
      name = "ordered-observation",
      host = Applet.host.tab({ label = "Observed" }),
      on_pane_close = observe,
      on_resize = observe,
    })
    value:update(tree(first, second))
    succeeds(value:open())
    local batches = value:_stats().observation_batches

    vim.api.nvim_win_close(value:pane("first"):native().window, true)
    wait_for(function() return not value:is_open() end)
    assert.are.same({ "pane_close", "resize" }, events)
    assert.is_false(expired_default())
    assert.are.equal(batches + 1, value:_stats().observation_batches)
  end)

  it("finishes destruction requested from an observation callback", function()
    local first = new_pane("first", "managed", "destroy from callback")
    local second = new_pane("second", "editable", "")
    local value
    value = applet({
      name = "destroy-during-observation",
      host = Applet.host.tab({ label = "Destroy observation" }),
      on_pane_close = function() value:destroy() end,
    })
    value:update(tree(first, second))
    succeeds(value:open())

    vim.api.nvim_win_close(value:pane("first"):native().window, true)
    wait_for(function() return value:is_destroyed() end)
    assert.is_false(value:is_open())
  end)

  it("observes external Host closure and suppresses owned closes", function()
    local first, second = new_pane("first", "managed", "first"),
      new_pane("second", "editable")
    local value = applet({
      name = "host-close-observation",
      host = Applet.host.tab({ label = "Close observation" }),
    })
    value:update(tree(first, second))
    succeeds(value:open())

    vim.cmd("tabclose!")
    wait_for(function() return not value:is_open() end)
    assert.is_false(value:observed().host.open)

    succeeds(value:open())
    succeeds(value:close())
    vim.wait(30, function() return false end, 5)
  end)

  it("adopts external options and leaves a replacement buffer and window untouched", function()
    local first, second = new_pane("first", "managed", "first"),
      new_pane("second", "editable")
    local detached = 0
    local value = applet({
      name = "option-and-buffer-observation",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_pane_buffer_change = function(event, default)
        detached = detached + 1
        assert.are.equal("buffer_replaced", event.reason)
        default()
      end,
    })
    local requested = tree(first, second)
    value:update(requested)
    succeeds(value:open())
    local native = value:pane("first"):native()
    vim.api.nvim_win_call(native.window, function()
      vim.cmd("setlocal nowrap")
      vim.api.nvim_exec_autocmds("OptionSet", { pattern = "wrap" })
    end)
    wait_for(function()
      return value:observed().panes.first.window_options.wrap == false
    end)

    first:set_state({ text = "updated" })
    value:update(requested)
    succeeds(value:flush())
    assert.is_false(vim.api.nvim_get_option_value("wrap", { win = native.window }))

    local replacement = vim.api.nvim_create_buf(false, true)
    foreign_buffers[#foreign_buffers + 1] = replacement
    foreign_windows[#foreign_windows + 1] = native.window
    vim.api.nvim_win_set_buf(native.window, replacement)
    local replacement_wrap = vim.api.nvim_get_option_value(
      "wrap", { win = native.window })
    wait_for(function() return detached == 1 end)
    assert.is_true(vim.api.nvim_win_is_valid(native.window))
    assert.are.equal(replacement, vim.api.nvim_win_get_buf(native.window))
    assert.are.equal(replacement_wrap,
      vim.api.nvim_get_option_value("wrap", { win = native.window }))

    value:destroy()
    assert.is_true(vim.api.nvim_win_is_valid(native.window))
    assert.are.equal(replacement, vim.api.nvim_win_get_buf(native.window))
  end)

  it("observes retained buffer lifetime while closed and remounts explicitly", function()
    for _, case in ipairs({
      { command = "bunload!", reason = "buffer_unloaded" },
      { command = "bdelete!", reason = "buffer_deleted" },
      { command = "bwipeout!", reason = "buffer_wiped" },
    }) do
      local content = new_pane("first", "managed", case.reason)
      local observed
      local value = applet({
        name = "closed-" .. case.reason,
        host = Applet.host.floating({ width = 40, height = 10 }),
        on_pane_buffer_change = function(event, default)
          observed = event.reason
          default()
        end,
      })
      value:update(tree(content))
      succeeds(value:open())
      local old_buffer = value:pane("first"):native().buffer
      if case.reason == "buffer_deleted" then
        vim.api.nvim_set_option_value("buflisted", true, { buf = old_buffer })
      end
      succeeds(value:close())
      vim.cmd(case.command .. " " .. old_buffer)
      wait_for(function() return observed ~= nil end)
      assert.are.equal(case.reason, observed)
      assert.is_nil(value:pane("first"):native().buffer)

      value:remount("first")
      succeeds(value:open())
      local replacement = value:pane("first"):native().buffer
      assert.are_not.equal(old_buffer, replacement)
      assert.is_true(vim.api.nvim_buf_is_loaded(replacement))
      if vim.api.nvim_buf_is_valid(old_buffer) then
        foreign_buffers[#foreign_buffers + 1] = old_buffer
      end
      value:destroy()
    end
  end)

  it("discovers direct floating-window moves at an explicit refresh boundary", function()
    local content = new_pane("first", "managed", "move")
    local observed
    local value = applet({
      name = "explicit-position-observation",
      host = Applet.host.floating({ width = 40, height = 10 }),
      on_resize = function(event)
        observed = event.after.panes.first.geometry
      end,
    })
    local requested = tree(content)
    value:update(requested)
    succeeds(value:open())
    local window = value:pane("first"):native().window
    local config = vim.api.nvim_win_get_config(window)
    config.row = config.row + 2
    vim.api.nvim_win_set_config(window, config)
    assert.is_nil(observed)

    value:invalidate({ host = true })
    succeeds(value:flush())
    assert.are.equal(config.row, observed.row)
    assert.are.equal(config.col, observed.col)

    value:update(requested)
    succeeds(value:flush())
    assert.are_not.equal(config.row,
      vim.api.nvim_win_get_config(window).row)
  end)

  it("observes an explicit resize event in the active Host tab", function()
    local content = new_pane("first", "managed", "resize")
    local value = applet({
      name = "resize-event-observation",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    value:update(tree(content))
    succeeds(value:open())
    local refreshes = value:_stats().host_snapshot_refreshes
    vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
    wait_for(function()
      return value:_stats().host_snapshot_refreshes > refreshes
    end)
  end)

  it("adopts floating Pane geometry through the resize default", function()
    local content = new_pane("first", "managed", "adopt resize")
    local value = applet({
      name = "adopted-floating-geometry",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    local requested = tree(content)
    value:update(requested)
    succeeds(value:open())
    local window = value:pane("first"):native().window
    local config = vim.api.nvim_win_get_config(window)
    config.row = config.row + 2
    vim.api.nvim_win_set_config(window, config)
    value:invalidate({ host = true })
    succeeds(value:flush())
    wait_for(function()
      return value.records.first.adopted_float_config ~= nil
    end)

    value:update(requested)
    succeeds(value:flush())
    assert.are.equal(config.row, vim.api.nvim_win_get_config(window).row)
  end)

  it("reopens after a callback closes the current epoch", function()
    local first = new_pane("first", "managed", "first")
    local second = new_pane("second", "editable", "draft")
    local value
    value = applet({
      name = "callback-reopen",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_pane_close = function()
        value:close({ restore_origin = false })
        value:open()
        value:focus("second")
      end,
    })
    value:update(tree(first, second))
    succeeds(value:open())
    vim.api.nvim_win_close(value:pane("first"):native().window, true)
    wait_for(function()
      return value:is_open() and value:pane("first"):is_mounted()
    end)
    assert.are.equal("second", value:focused_pane())
  end)

  it("redirects native focus into the active modal boundary", function()
    local main = new_pane("main", "managed", "main")
    local dialog = new_pane("dialog", "managed", "dialog")
    local value = applet({
      name = "modal-native-focus",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    value:update({
      root = layout.frame({
        key = "frame",
        child = pane("main", main),
        layers = {
          layout.layer({
            key = "dialog-layer",
            width = 24,
            height = 6,
            modal = true,
            enter = true,
            child = pane("dialog", dialog),
          }),
        },
      }),
      focus = { initial = "main" },
    })
    succeeds(value:open())
    local main_window = value:pane("main"):native().window
    local dialog_window = value:pane("dialog"):native().window
    assert.are.equal(dialog_window, vim.api.nvim_get_current_win())
    vim.api.nvim_set_current_win(main_window)
    wait_for(function() return vim.api.nvim_get_current_win() == dialog_window end)
    assert.are.equal("dialog", value:focused_pane())
  end)

  it("cleans a transient Pane when its loaded buffer is externally released", function()
    local transient = new_pane("first", "managed", "transient")
    local stable = new_pane("second", "editable", "stable")
    local reason
    local value = applet({
      name = "transient-buffer-loss",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_pane_buffer_change = function(event, default)
        reason = event.reason
        default()
      end,
    })
    local requested = tree(transient, stable)
    requested.root.child.children[1].child.lifecycle = "transient"
    value:update(requested)
    succeeds(value:open())
    local buffer = value:pane("first"):native().buffer
    vim.cmd("bunload! " .. buffer)
    wait_for(function() return reason == "buffer_unloaded" end)
    assert.is_false(vim.api.nvim_buf_is_valid(buffer))
    assert.is_true(value:is_open())
  end)

  it("observes a retained buffer loss after its Pane is detached", function()
    local first = new_pane("first", "managed", "first")
    local second = new_pane("second", "editable", "second")
    local reasons = {}
    local value = applet({
      name = "detached-buffer-loss",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_pane_close = function(event, default)
        reasons[#reasons + 1] = event.reason
        default()
      end,
      on_pane_buffer_change = function(event, default)
        reasons[#reasons + 1] = event.reason
        default()
      end,
    })
    value:update(tree(first, second))
    succeeds(value:open())
    local native = value:pane("first"):native()
    vim.api.nvim_win_close(native.window, true)
    wait_for(function() return reasons[1] == "window_closed" end)
    vim.cmd("bunload! " .. native.buffer)
    wait_for(function() return reasons[2] == "buffer_unloaded" end)
  end)

  it("closes a single-window Host and releases its transient owner", function()
    local content = new_pane("first", "managed", "transient host")
    local value = applet({
      name = "last-host-window",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    local requested = tree(content)
    requested.root.child.lifecycle = "transient"
    requested.root.child.owns_pane = true
    value:update(requested)
    succeeds(value:open())
    vim.api.nvim_win_close(value:pane("first"):native().window, true)
    wait_for(function() return not value:is_open() end)
    assert.is_false(value:is_open())
    assert.is_true(content.destroyed)
  end)

  it("ignores window activity outside an inactive tab Host", function()
    local content = new_pane("first", "managed", "isolated")
    local origin_tab = vim.api.nvim_get_current_tabpage()
    local value = applet({
      name = "unrelated-window-observation",
      host = Applet.host.tab({ label = "Isolated" }),
    })
    value:update(tree(content))
    succeeds(value:open())
    vim.api.nvim_set_current_tabpage(origin_tab)
    wait_for(function() return value:observed().host.visible == false end)
    local refreshes = value:_stats().host_snapshot_refreshes

    vim.cmd("vsplit")
    local drained = false
    vim.schedule(function() drained = true end)
    wait_for(function() return drained end)
    assert.are.equal(refreshes, value:_stats().host_snapshot_refreshes)
  end)

  it("applies Pane modes across direct and temporary-Normal focus", function()
    local executable = vim.env.NEOAGENT_NVIM or "nvim"
    for _, host_kind in ipairs({ "floating", "tab" }) do
      local result = vim.system({
        executable, "--headless", "--noplugin", "-u", "tests/minimal_init.lua",
        "-c", "luafile tests/helpers/applet_direct_focus.lua",
      }, {
        text = true,
        env = { APPLET_HOST = host_kind },
      }):wait(5000)
      local output = (result.stderr or "") .. (result.stdout or "")
      assert.are.equal(0, result.code,
        host_kind .. " Applet focus failed: " .. output)
    end
  end)
end)
