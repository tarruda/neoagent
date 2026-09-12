local assert = require("luassert")
local Applet = require("applet")
local layout = Applet.layout
local ui = Applet.Pane.nodes

---@class Applet.TestObservationState
---@field text? string

local sequence = 0

---@param key string
---@param mode? "managed"|"editable"
---@param text? string
---@return Applet.Pane<Applet.TestObservationState>
local function component(key, mode, text)
  sequence = sequence + 1
  local value = Applet.Pane.new({
    key = key,
    buffer_mode = mode or "managed",
    ---@param state Applet.TestObservationState
    render = function(state)
      return ui.text({ key = "content", text = state.text or "" })
    end,
  })
  value:set_state({ text = text or "" })
  return value
end

---@class Applet.TestObservationMountOptions
---@field lifecycle? Applet.MountLifecycle
---@field owns_pane? boolean
---@field border? Applet.WindowBorder
---@field mode? "normal"|"insert"|"preserve"

---@param key string
---@param value Applet.Pane
---@param opts? Applet.TestObservationMountOptions
---@return Applet.MountNode
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

---@param first Applet.Pane
---@param second? Applet.Pane
---@return Applet.LayoutTree
local function tree(first, second)
  ---@type Applet.LayoutNode
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

---@generic T
---@param ok T
---@param err? Applet.Error
---@return T
local function succeeds(ok, err)
  assert(ok, err and err.message or tostring(err))
  return ok
end

---@param predicate fun(): boolean
local function wait_for(predicate)
  assert(vim.wait(1500, predicate, 5), "timed out waiting for Applet observation")
end

describe("Applet observation", function()
  ---@type Applet.Applet[]
  local applets = {}
  ---@type Applet.Pane[]
  local panes = {}
  ---@type integer[]
  local foreign_windows = {}
  ---@type integer[]
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

  ---@param key string
  ---@param mode? "managed"|"editable"
  ---@param text? string
  ---@return Applet.Pane<Applet.TestObservationState>
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

  it("publishes one ordered callback batch before applying callback mutations", function()
    local first, second = new_pane("first", "managed", "first"),
      new_pane("second", "editable")
    ---@type string[], (fun(): boolean)?
    local events, expired_default = {}, nil
    ---@type Applet.Applet<unknown>
    local value
    ---@param event Applet.ExternalEvent
    ---@param default fun(): boolean
    local function observe(event, default)
      events[#events + 1] = event.kind
      assert.are.equal(event.revision, assert(value):observed().revision)
      assert.are.equal(event.request_generation,
        assert(value):observed().request_generation)
      local native = event.native()
      native.events[1] = "changed"
      assert.are_not.equal("changed", event.native().events[1])
      assert.is_true(default())
      assert.is_false(default())
      expired_default = default
      if event.kind == "pane_close" then
        local opaque = setmetatable({ marker = "opaque" }, {})
        local close_options = { restore_origin = false, opaque = opaque }
        close_options.self = close_options
        assert(value):update(tree(first, second))
        assert.is_true(assert(value).domain:flush())
        assert.is_true(assert(value).domain.dirty[assert(value)])
        assert.is_true(assert(value):flush())
        assert.is_true(assert(value):close(close_options))
        local deferred = assert(assert(value).deferred_close)
        assert.are_not.equal(close_options, deferred)
        assert.are.equal(deferred, deferred.self)
        assert.are.equal(opaque, deferred.opaque)
      end
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

    vim.api.nvim_win_close((assert(assert(value:pane("first")):native().window)), true)
    wait_for(function() return not value:is_open() end)
    assert.are.same({ "pane_close", "resize" }, events)
    assert.is_false(assert(expired_default)())
    assert.are.equal(batches + 1, value:_stats().observation_batches)
  end)

  it("finishes destruction requested from an observation callback", function()
    local first = new_pane("first", "managed", "destroy from callback")
    local second = new_pane("second", "editable", "")
    ---@type Applet.Applet<unknown>
    local value
    value = applet({
      name = "destroy-during-observation",
      host = Applet.host.tab({ label = "Destroy observation" }),
      on_pane_close = function() assert(value):destroy() end,
    })
    value:update(tree(first, second))
    succeeds(value:open())

    vim.api.nvim_win_close((assert(assert(value:pane("first")):native().window)), true)
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
    local native = assert(value:pane("first")):native()
    vim.api.nvim_win_call((assert(native.window)), function()
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
    vim.api.nvim_win_set_buf((assert(native.window)), replacement)
    local replacement_wrap = vim.api.nvim_get_option_value(
      "wrap", { win = native.window })
    wait_for(function() return detached == 1 end)
    assert.is_true(vim.api.nvim_win_is_valid((assert(native.window))))
    assert.are.equal(replacement, vim.api.nvim_win_get_buf((assert(native.window))))
    assert.are.equal(replacement_wrap,
      vim.api.nvim_get_option_value("wrap", { win = native.window }))

    value:destroy()
    assert.is_true(vim.api.nvim_win_is_valid((assert(native.window))))
    assert.are.equal(replacement, vim.api.nvim_win_get_buf((assert(native.window))))
  end)

  it("observes retained buffer lifetime while closed and remounts explicitly", function()
    for _, case in ipairs({
      { command = "bunload!", reason = "buffer_unloaded" },
      { command = "bdelete!", reason = "buffer_deleted" },
      { command = "bwipeout!", reason = "buffer_wiped" },
    }) do
      local content = new_pane("first", "managed", case.reason)
      ---@type string?
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
      local old_buffer = assert(value:pane("first")):native().buffer
      if case.reason == "buffer_deleted" then
        vim.api.nvim_set_option_value("buflisted", true, { buf = old_buffer })
      end
      succeeds(value:close())
      vim.cmd(case.command .. " " .. old_buffer)
      wait_for(function() return observed ~= nil end)
      assert.are.equal(case.reason, observed)
      assert.is_nil(assert(value:pane("first")):native().buffer)

      value:remount("first")
      succeeds(value:open())
      local replacement = assert(value:pane("first")):native().buffer
      assert.are_not.equal(old_buffer, replacement)
      assert.is_true(vim.api.nvim_buf_is_loaded((assert(replacement))))
      if vim.api.nvim_buf_is_valid((assert(old_buffer))) then
        foreign_buffers[#foreign_buffers + 1] = old_buffer
      end
      value:destroy()
    end
  end)

  it("discovers direct floating-window moves at an explicit refresh boundary", function()
    local content = new_pane("first", "managed", "move")
    ---@type Applet.Rectangle?
    local observed
    local value = applet({
      name = "explicit-position-observation",
      host = Applet.host.floating({ width = 40, height = 10 }),
      on_resize = function(event)
        observed = assert(event.after.panes).first.geometry
      end,
    })
    local requested = tree(content)
    value:update(requested)
    succeeds(value:open())
    local window = assert(value:pane("first")):native().window
    local config = vim.api.nvim_win_get_config((assert(window)))
    config.row = assert(config.row) + 2
    vim.api.nvim_win_set_config((assert(window)), config)
    assert.is_nil(observed)

    value:invalidate({ host = true })
    succeeds(value:flush())
    assert.are.equal(config.row, assert(observed).row)
    assert.are.equal(config.col, assert(observed).col)

    value:update(requested)
    succeeds(value:flush())
    assert.are_not.equal(config.row,
      vim.api.nvim_win_get_config((assert(window))).row)
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

  it("adopts the addition and removal of a foreign split without replacing its Pane", function()
    local content = new_pane("first", "managed", "retained")
    local value = applet({
      name = "foreign-split-removal",
      host = Applet.host.tab({ label = "Foreign split" }),
    })
    local requested = tree(content)
    value:update(requested)
    succeeds(value:open())
    local native = content:native()
    vim.cmd("vsplit")
    local foreign = vim.api.nvim_get_current_win()
    foreign_windows[#foreign_windows + 1] = foreign
    wait_for(function() return value:observed().foreign_windows == 1 end)
    local added_revision = value:observed().revision

    vim.api.nvim_win_close(foreign, true)
    wait_for(function() return value:observed().foreign_windows == 0 end)
    assert.is_true(value:observed().revision > added_revision)
    assert.is_true(value:is_open())
    assert.are.equal(native.window, content:native().window)
    assert.are.equal(native.buffer, content:native().buffer)
    content:set_state({ text = "updated" })
    value:update(requested)
    succeeds(value:flush())
    assert.are.same({ "updated" }, vim.api.nvim_buf_get_lines((assert(native.buffer)), 0, -1, false))
    assert.are.same({ assert(native.window) }, vim.api.nvim_tabpage_list_wins(0))
  end)

  it("reports a failed resize callback and continues observing later changes", function()
    local content = new_pane("first", "managed", "retained")
    ---@type Applet.Error[]
    local errors = {}
    local fail = true
    local resized = 0
    local value = applet({
      name = "resize-callback-failure",
      host = Applet.host.floating({ width = 40, height = 10 }),
      on_error = function(err) errors[#errors + 1] = err end,
      on_resize = function(_, default)
        resized = resized + 1
        if fail then error("resize observer failed") end
        default()
      end,
    })
    value:update(tree(content))
    succeeds(value:open())
    local window = assert(content:native().window)
    local config = vim.api.nvim_win_get_config(window)
    config.row = assert(config.row) + 1
    vim.api.nvim_win_set_config(window, config)
    value:invalidate({ host = true })
    succeeds(value:flush())
    assert.are.equal(1, #errors)
    assert.are.equal("action", assert(errors[1]).phase)
    assert.matches("resize observer failed", assert(errors[1]).message)
    local failed_calls = resized

    fail = false
    config = vim.api.nvim_win_get_config(window)
    config.row = assert(config.row) + 1
    vim.api.nvim_win_set_config(window, config)
    value:invalidate({ host = true })
    succeeds(value:flush())
    assert.is_true(resized > failed_calls)
    assert.are.equal(1, #errors)
    assert.is_true(value:is_open())
    assert.are.equal(config.row, assert(value:observed().panes.first.geometry).row)
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
    local window = assert(value:pane("first")):native().window
    local config = vim.api.nvim_win_get_config((assert(window)))
    config.row = assert(config.row) + 2
    vim.api.nvim_win_set_config((assert(window)), config)
    value:invalidate({ host = true })
    succeeds(value:flush())
    wait_for(function()
      return value.records.first.adopted_float_config ~= nil
    end)

    value:update(requested)
    succeeds(value:flush())
    assert.are.equal(config.row, vim.api.nvim_win_get_config((assert(window))).row)
  end)

  it("reopens after a callback closes the current epoch", function()
    local first = new_pane("first", "managed", "first")
    local second = new_pane("second", "editable", "draft")
    ---@type Applet.Applet<unknown>
    local value
    value = applet({
      name = "callback-reopen",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_pane_close = function()
        assert(value):close({ restore_origin = false })
        assert(value):open()
        assert(value):focus("second")
      end,
    })
    value:update(tree(first, second))
    succeeds(value:open())
    vim.api.nvim_win_close((assert(assert(value:pane("first")):native().window)), true)
    wait_for(function()
      return value:is_open() and assert(value:pane("first")):is_mounted()
    end)
    assert.are.equal("second", value:focused_pane())
  end)

  it("uses the editor fallback when no native window can serve as a floating container", function()
    local origin, original = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local special = vim.api.nvim_create_buf(false, true)
    foreign_buffers[#foreign_buffers + 1] = special
    vim.bo[special].buftype = "nofile"
    vim.api.nvim_win_set_buf(origin, special)
    local first = new_pane("first", "managed", "content")
    local value = applet({ name = "unavailable-container",
      host = Applet.host.floating({ container = "largest_window", width = 60, height = 20 }) })
    value:update(tree(first))
    local opened, err = value:open()
    assert.is_nil(opened)
    assert.matches("container is unavailable", assert(err).message)
    assert.is_false(first:is_mounted())
    value:set_host(Applet.host.floating({ container = "auto", width = 60, height = 20 }))
    succeeds(value:open())
    assert.is_true(first:is_mounted())
    assert.are.equal("content", first:text())
    assert.is_true(value:close())
    vim.api.nvim_win_set_buf(origin, original)
  end)

  for _, event in ipairs({ "WinEnter", "TabEnter" }) do
    it("rejects focus when " .. event .. " replaces the target Pane buffer", function()
      local first, second = new_pane("first"), new_pane("second", "editable", "retained draft")
      local value = applet({ name = "focus-buffer-replacement",
        host = Applet.host.floating({ width = 60, height = 20 }) })
      value:update(tree(first, second))
      succeeds(value:open())
      assert(second:replace_text("retained draft"))
      local window = assert(first:native().window)
      local foreign = vim.api.nvim_create_buf(false, true)
      foreign_buffers[#foreign_buffers + 1] = foreign
      vim.api.nvim_buf_set_lines(foreign, 0, -1, false, { "external content" })
      local tab = vim.api.nvim_win_get_tabpage(window)
      if event == "TabEnter" then vim.cmd("tabnew") end
      local replaced = false
      local callback = vim.api.nvim_create_autocmd(event, {
        once = true,
        callback = function()
          local entered = event == "TabEnter" and vim.api.nvim_get_current_tabpage() == tab
            or event == "WinEnter" and vim.api.nvim_get_current_win() == window
          if entered and not replaced then
            replaced = true
            vim.api.nvim_win_set_buf(window, foreign)
          end
        end,
      })
      local focused = value:focus("first")
      pcall(vim.api.nvim_del_autocmd, callback)
      assert.is_true(replaced)
      assert.is_false(focused)
      wait_for(function() return not first:is_mounted() end)
      assert.are.same({ "external content" }, vim.api.nvim_buf_get_lines(foreign, 0, -1, false))
      assert.are.equal("retained draft", second:text())
    end)
  end

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
    local main_window = assert(value:pane("main")):native().window
    local dialog_window = assert(value:pane("dialog")):native().window
    assert.are.equal(dialog_window, vim.api.nvim_get_current_win())
    vim.api.nvim_set_current_win((assert(main_window)))
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
    assert(assert(requested.root.child.children)[1]).child.lifecycle = "transient"
    value:update(requested)
    succeeds(value:open())
    local buffer = assert(value:pane("first")):native().buffer
    vim.cmd("bunload! " .. buffer)
    wait_for(function() return reason == "buffer_unloaded" end)
    assert.is_false(vim.api.nvim_buf_is_valid((assert(buffer))))
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
    local native = assert(value:pane("first")):native()
    assert(second:replace_text("second"))
    vim.api.nvim_win_close((assert(native.window)), true)
    wait_for(function() return reasons[1] == "window_closed" end)
    vim.cmd("bunload! " .. native.buffer)
    wait_for(function() return reasons[2] == "buffer_unloaded" end)
    assert.are.equal("", first:text())
    assert.is_false(first:focus())
    assert.is_false(first:scroll({ target = "end" }))
    assert.are.equal("second", second:text())
  end)

  it("adopts replacement of every projected tab Pane", function()
    local content = new_pane("first", "managed", "owned")
    local sibling = new_pane("second", "editable", "sibling")
    local reasons = 0
    local value = applet({
      name = "last-tab-pane-replaced",
      host = Applet.host.tab({ label = "Replaced" }),
      on_pane_buffer_change = function(event, default)
        assert.are.equal("buffer_replaced", event.reason)
        reasons = reasons + 1
        default()
      end,
    })
    value:update(tree(content, sibling))
    succeeds(value:open())
    for _, key in ipairs({ "first", "second" }) do
      local window = assert(assert(value:pane(key)):native().window)
      local replacement = vim.api.nvim_create_buf(false, true)
      foreign_buffers[#foreign_buffers + 1] = replacement
      vim.api.nvim_win_set_buf(window, replacement)
    end
    wait_for(function() return reasons == 2 end)
    assert.is_true(value:is_open())
    assert.is_false(content:is_mounted())
    assert.is_false(sibling:is_mounted())
    local driver = assert(value.driver)
    ---@cast driver Applet.TabDriver
    assert.is_nil(driver.structure)
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
    vim.api.nvim_win_close((assert(assert(value:pane("first")):native().window)), true)
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
