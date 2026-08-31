local Applet = require("applet")
local layout = Applet.layout
local ui = Applet.Pane.nodes

local sequence = 0
local function component(key, mode, text, handlers)
  sequence = sequence + 1
  local value = Applet.Pane.new({
    key = key,
    buffer_mode = mode or "managed",
    handlers = handlers,
    render = function(state)
      return {
        root = ui.scope({
          key = "content:scope",
          bindings = state.bindings or {},
          child = ui.text({ key = "content", text = state.text or "" }),
        }),
        edit = state.edit,
        chrome = state.chrome,
      }
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
    required = opts.required ~= false,
    buffer = {
      name = key,
      uri = opts.uri,
      filetype = opts.filetype or "applet-test",
      sensitive = opts.sensitive,
      options = opts.buffer_options,
    },
    window = {
      border = opts.border or "single",
      options = { wrap = true, linebreak = true },
    },
    focus = { mode = opts.mode, cursor = opts.cursor },
    bindings = opts.bindings,
  })
end

local function tree(transcript, input, layers)
  return {
    root = layout.frame({
      key = "frame",
      child = layout.split({
        key = "main",
        axis = "vertical",
        children = {
          { key = "body", grow = 1, min = 3,
            child = pane("transcript", transcript) },
          { key = "composer", basis = { content = 2 }, grow = 0,
            child = pane("input", input, { mode = "insert" }) },
        },
      }),
      layers = layers,
    }),
    bindings = {
      {
        mode = "n",
        lhs = "q",
        action = ui.action("applet.close"),
      },
    },
    focus = { initial = "input" },
  }
end

local function lines(buffer)
  return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

describe("Applet Hosts", function()
  local applets = {}
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

  local function new_pane(key, mode, text, handlers)
    local value = component(key, mode, text, handlers)
    panes[#panes + 1] = value
    return value
  end

  local function applet(opts)
    local value = Applet.new(opts)
    applets[#applets + 1] = value
    return value
  end

  it("opens coordinated floats, focuses editable Panes, and retains buffers", function()
    local transcript = new_pane("transcript", "managed", "hello")
    local input = new_pane("input", "editable", "")
    local origin = vim.api.nvim_get_current_win()
    local value = applet({
      name = "floating-test",
      host = Applet.host.floating({
        side = "center", width = 0.8, height = 0.8,
      }),
    })
    value:update(tree(transcript, input))
    local opened, open_error = value:open()
    assert(opened, open_error and open_error.message)

    local transcript_pane = assert(value:pane("transcript"))
    local input_pane = assert(value:pane("input"))
    assert.is_true(value:is_open())
    assert.is_true(value:is_visible())
    assert.is_true(transcript_pane:is_mounted())
    assert.is_true(input_pane:is_mounted())
    assert.are.same({ "hello" }, lines(transcript_pane:native().buffer))
    assert.are.equal("input", value:focused_pane())
    assert.is_true(input_pane:is_focused())
    assert.are.equal("insert", input_pane:mode())
    assert.are.equal("floating", transcript_pane:geometry().host)
    assert.are.equal("", vim.api.nvim_win_get_config(origin).relative)

    input_pane:replace_text("draft", { line = 1, column = 5 }, 1)
    assert.are.equal("draft", input_pane:text())
    local input_buffer = input_pane:native().buffer
    value:close()
    assert.is_false(value:is_open())
    assert.is_true(vim.api.nvim_buf_is_valid(input_buffer))
    assert.are.equal("draft", input_pane:text())
    assert.is_true(input_pane:replace_text(
      "closed draft", { line = 1, column = 6 }, 2))
    assert.is_false(input_pane:replace_text(
      "ignored", { line = 1, column = 0 }, 2))
    assert.are.equal("closed draft", input_pane:text())
    assert.are.equal(origin, vim.api.nvim_get_current_win())

    assert(value:open())
    assert.are.equal(input_buffer, input_pane:native().buffer)
    assert.are.equal("closed draft", input_pane:text())
    local observed = value:observed()
    assert.is_true(observed.host.open)
    assert.is_true(observed.panes.input.mounted)
    assert.is_nil(observed.panes.input.window)
  end)

  it("keeps a mounted Pane's live viewport when focus changes", function()
    local content = {}
    for index = 1, 80 do content[index] = "transcript line " .. index end
    local transcript = new_pane("transcript", "managed", table.concat(content, "\n"))
    local input = new_pane("input", "editable", "")
    local value = applet({
      name = "floating-live-viewport",
      host = Applet.host.floating({
        side = "center", width = 0.8, height = 0.8,
      }),
    })
    value:update(tree(transcript, input))
    assert(value:open())

    local transcript_window = assert(value:pane("transcript")):native().window
    assert(value:focus("transcript"))
    vim.api.nvim_win_call(transcript_window, function()
      vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, leftcol = 0 })
    end)
    assert(value:focus("input"))
    vim.api.nvim_win_call(transcript_window, function()
      vim.fn.winrestview({ lnum = 40, col = 0, topline = 30, leftcol = 0 })
    end)
    local before = vim.api.nvim_win_call(
      transcript_window, function() return vim.fn.winsaveview() end)
    assert.are.equal(30, before.topline)

    assert(value:focus("transcript"))
    local after = vim.api.nvim_win_call(
      transcript_window, function() return vim.fn.winsaveview() end)
    assert.are.equal(before.lnum, after.lnum)
    assert.are.equal(before.topline, after.topline)
  end)

  it("routes Applet actions through the Applet mapping owner", function()
    local invoked, reported = 0, nil
    local transcript = new_pane("transcript", "managed", "mapped")
    local input = new_pane("input", "editable", "")
    local details = new_pane("details", "managed", "details")
    local value = applet({
      name = "mapping-test",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_error = function(err) reported = err end,
      handlers = {
        ["test.invoke"] = function(event)
          invoked = invoked + 1
          assert.are.equal("transcript", event.pane:key())
        end,
        ["test.fail"] = function() error("action failed") end,
      },
    })
    local value_tree = tree(transcript, input)
    for _, binding in ipairs({
      { mode = "n", lhs = "x", action = ui.action("test.invoke") },
      { mode = "n", lhs = "e", action = ui.action("test.fail") },
      { mode = "n", lhs = "f", action = ui.action(
        "applet.focus", { pane = "input" }) },
      { mode = "n", lhs = "j", action = ui.action(
        "applet.focus.move", { direction = "down" }) },
      { mode = "n", lhs = "k", action = ui.action(
        "applet.focus.move", { direction = "up" }) },
      { mode = "n", lhs = "l", action = ui.action(
        "applet.focus.move", { direction = "right" }) },
      { mode = "n", lhs = "w", action = ui.action(
        "applet.focus.move", { direction = "right", wrap = true }) },
      { mode = "n", lhs = "r", action = ui.action(
        "applet.focus.restore") },
    }) do
      value_tree.bindings[#value_tree.bindings + 1] = binding
    end
    value:update(value_tree)
    assert(value:open())
    assert(value:focus("transcript"))
    local input_dispatch = require("applet.pane.input").dispatch
    assert.is_true(input_dispatch(transcript, "n", "x"))
    assert.are.equal(1, invoked)
    assert.is_false(input_dispatch(transcript, "n", "r"))
    assert.is_false(input_dispatch(transcript, "n", "e"))
    assert.matches("action failed", reported.message)
    assert.is_true(input_dispatch(transcript, "n", "f"))
    assert.are.equal("input", value:focused_pane())
    assert.is_true(input_dispatch(input, "n", "k"))
    assert.are.equal("transcript", value:focused_pane())
    assert.is_true(input_dispatch(transcript, "n", "j"))
    assert.are.equal("input", value:focused_pane())
    assert.is_false(input_dispatch(input, "n", "l"))
    assert.is_true(input_dispatch(input, "n", "w"))
    assert.are.equal("transcript", value:focused_pane())

    value_tree.root.layers = {
      layout.layer({
        key = "details-layer",
        width = 30,
        height = 8,
        enter = true,
        restore_focus = true,
        child = pane("details", details),
      }),
    }
    value:update(value_tree)
    assert(value:flush())
    assert.are.equal("details", value:focused_pane())
    assert.is_true(input_dispatch(details, "n", "r"))
    assert.are.equal("transcript", value:focused_pane())

    local mappings = vim.api.nvim_buf_get_keymap(
      value:pane("transcript"):native().buffer, "n")
    local owned = 0
    for _, mapping in ipairs(mappings) do
      if mapping.lhs == "x" then owned = owned + 1 end
    end
    assert.are.equal(1, owned)
    assert.is_true(input_dispatch(transcript, "n", "q"))
    assert.is_false(value:is_open())
  end)

  it("realizes the main topology as native tab splits and Layers as floats", function()
    local transcript = new_pane("transcript", "managed", "tab transcript")
    local input = new_pane("input", "editable", "")
    local details = new_pane("details", "managed", "details")
    local value = applet({
      name = "tab-test",
      host = Applet.host.tab({ label = "Applet test" }),
    })
    value:update(tree(transcript, input, {
      layout.layer({
        key = "details-layer",
        container = "applet",
        width = 40,
        height = { content = true, min = 2, max = 8 },
        zindex = 70,
        enter = true,
        child = pane("details", details, { required = false }),
      }),
    }))
    assert(value:open())
    local transcript_native = value:pane("transcript"):native()
    local input_native = value:pane("input"):native()
    local details_native = value:pane("details"):native()
    assert.are.equal("", vim.api.nvim_win_get_config(transcript_native.window).relative)
    assert.are.equal("", vim.api.nvim_win_get_config(input_native.window).relative)
    assert.are_not.equal("", vim.api.nvim_win_get_config(details_native.window).relative)
    assert.are.equal(vim.api.nvim_win_get_tabpage(transcript_native.window),
      vim.api.nvim_win_get_tabpage(input_native.window))
    assert.are.equal("details", value:focused_pane())
    assert.are.equal(1, vim.api.nvim_tabpage_get_var(
      vim.api.nvim_win_get_tabpage(input_native.window),
      "applet_label") == "Applet test" and 1 or 0)
    assert.are.equal("col", vim.fn.winlayout()[1])
  end)

  it("adopts external Pane closure once and remounts only explicitly", function()
    local transcript = new_pane("transcript", "managed", "close me")
    local input = new_pane("input", "editable", "")
    local closed = 0
    local value = applet({
      name = "external-close-test",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_pane_close = function(event, default)
        closed = closed + 1
        assert.are.equal("transcript", event.pane:key())
        default()
      end,
    })
    value:update(tree(transcript, input))
    assert(value:open())
    local pane_value = value:pane("transcript")
    vim.api.nvim_win_close(pane_value:native().window, true)
    local waited = vim.wait(1000, function() return closed == 1 end)
    assert(waited)
    assert.is_false(pane_value:is_mounted())
    value:flush()
    assert.is_false(pane_value:is_mounted())
    value:remount("transcript")
    assert(value:flush())
    assert.is_true(pane_value:is_mounted())
    assert.are.equal(1, closed)
  end)

  it("lets a custom detach callback reproject the requested Pane", function()
    local transcript = new_pane("transcript", "managed", "replace me")
    local input = new_pane("input", "editable", "")
    local detached = 0
    local value = applet({
      name = "custom-detach-test",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_pane_close = function(event)
        detached = detached + 1
        assert.are.equal("transcript", event.pane:key())
      end,
    })
    local requested = tree(transcript, input)
    value:update(requested)
    assert(value:open())
    local transcript_pane = value:pane("transcript")
    local original_buffer = transcript_pane:native().buffer
    vim.api.nvim_win_close(transcript_pane:native().window, true)
    assert(vim.wait(1000, function() return detached == 1 end))
    assert.is_false(transcript_pane:is_mounted())

    value:update(requested)
    assert(value:flush())
    assert.is_true(transcript_pane:is_mounted())
    assert.are.equal(original_buffer, transcript_pane:native().buffer)
    assert.are.equal(1, detached)
  end)

  it("adopts externally changed Pane options", function()
    local transcript = new_pane("transcript", "managed", "options")
    local input = new_pane("input", "editable", "")
    local value = applet({
      name = "custom-option-test",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    local requested = tree(transcript, input)
    requested.root.child.children[1].child.buffer.options = { buflisted = true }
    value:update(requested)
    assert(value:open())
    local pane_value = value:pane("transcript")
    local window = pane_value:native().window
    vim.api.nvim_win_call(window, function()
      vim.cmd("setlocal nowrap")
      vim.api.nvim_exec_autocmds("OptionSet", { pattern = "wrap" })
    end)
    assert(vim.wait(1000, function()
      return not vim.api.nvim_get_option_value("wrap", { win = window })
    end))

    local buffer = pane_value:native().buffer
    vim.api.nvim_set_option_value("buflisted", false, { buf = buffer })
    vim.api.nvim_exec_autocmds("OptionSet", { pattern = "buflisted" })
    assert(vim.wait(1000, function()
      return not vim.api.nvim_get_option_value("buflisted", { buf = buffer })
    end))

    transcript:set_state({ text = "options changed" })
    value:update(requested)
    assert(value:flush())
    assert.is_false(vim.api.nvim_get_option_value("wrap", { win = window }))
    assert.is_false(vim.api.nvim_get_option_value("buflisted", { buf = buffer }))
  end)

  it("rebuilds an explicitly remounted main Pane in a tab Host", function()
    local transcript = new_pane("transcript", "managed", "tab remount")
    local input = new_pane("input", "editable", "")
    local value = applet({
      name = "tab-remount-test",
      host = Applet.host.tab({ label = "Remount" }),
    })
    value:update(tree(transcript, input))
    assert(value:open())
    local transcript_pane = value:pane("transcript")
    local transcript_buffer = transcript_pane:native().buffer
    vim.api.nvim_win_close(transcript_pane:native().window, true)
    assert(vim.wait(1000, function() return not transcript_pane:is_mounted() end))

    assert(value:remount("transcript"))
    assert(value:flush())
    assert.is_true(transcript_pane:is_mounted())
    assert.are.equal(transcript_buffer, transcript_pane:native().buffer)
    assert.are.equal("", vim.api.nvim_win_get_config(
      transcript_pane:native().window).relative)
  end)

  it("retains external modes only for Panes with preserve policy", function()
    local preserved = new_pane("preserved", "editable", "")
    local fixed = new_pane("fixed", "editable", "")
    local value = applet({
      name = "mode-policy-test",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    local function modes(preserved_mode)
      return {
        root = layout.frame({
          key = "frame",
          child = layout.split({
            key = "modes",
            axis = "horizontal",
            children = {
              { key = "preserved", grow = 1,
                child = pane("preserved", preserved,
                  { mode = preserved_mode }) },
              { key = "fixed", grow = 1,
                child = pane("fixed", fixed, { mode = "normal" }) },
            },
          }),
        }),
        focus = { initial = "preserved" },
      }
    end
    value:update(modes("insert"))
    assert(value:open())
    assert.are.equal("insert", value:pane("preserved"):mode())

    -- Changing to preserve keeps the mode already owned by the Pane. Moving
    -- focus away, observing a Neovim mode change, and moving back must restore
    -- the retained mode.
    value:update(modes("preserve"))
    assert(value:flush())
    local original_get_mode = vim.api.nvim_get_mode
    local original_cmd = vim.cmd
    local commands = {}
    vim.api.nvim_get_mode = function() return { mode = "i" } end
    vim.cmd = function(command) commands[#commands + 1] = command end
    local called, focused = pcall(value.focus, value, "fixed")
    vim.api.nvim_get_mode = original_get_mode
    vim.cmd = original_cmd
    assert(called, focused)
    assert.is_true(focused)
    assert.is_true(vim.tbl_contains(commands, "stopinsert"))
    value:_event("mode_change", "preserved", { mode = "normal" },
      { mode = "insert" }, { mode = "insert" }, "mode_changed")
    assert.are.equal("insert", value:pane("preserved"):mode())
    assert(value:focus("preserved"))
    assert.are.equal("insert", value:pane("preserved"):mode())

    -- A fixed policy is authoritative even if Neovim reports a different
    -- external mode. Its default handler must leave the Pane policy intact.
    assert(value:focus("fixed"))
    value:_event("mode_change", "fixed", { mode = "normal" },
      { mode = "insert" }, { mode = "insert" }, "mode_changed")
    assert(value:focus("preserved"))
    assert.are.equal("normal", value:pane("fixed"):mode())
    assert(value:focus("fixed"))
    assert.are.equal("normal", value:pane("fixed"):mode())
  end)

  it("owns dynamic chrome across Host changes", function()
    local transcript = new_pane("transcript", "managed", "chrome")
    local input = new_pane("input", "editable", "")
    local value = applet({
      name = "dynamic-chrome-test",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    local requested = tree(transcript, input)
    value:update(requested)
    assert(value:open())
    local window = value:pane("transcript"):native().window
    local original_cursorline = vim.api.nvim_get_option_value(
      "cursorline", { win = window })
    transcript:set_state({
      text = "chrome",
      chrome = {
        title = { { text = " Dynamic " } },
        footer = { { text = " Footer " } },
        options = { cursorline = not original_cursorline },
      },
    })
    assert(transcript:flush())
    local config = vim.api.nvim_win_get_config(window)
    assert.are.equal(" Dynamic ", config.title[1][1])
    assert.are.equal(" Footer ", config.footer[1][1])
    assert.are.equal(not original_cursorline,
      vim.api.nvim_get_option_value("cursorline", { win = window }))
    assert.are.same({}, value.records.transcript.adopted_window_options or {})

    transcript:set_state({ text = "plain" })
    assert(transcript:flush())
    config = vim.api.nvim_win_get_config(window)
    assert.is_true(config.title == nil or config.title == "")
    assert.is_true(config.footer == nil or config.footer == "")
    assert.are.equal(original_cursorline,
      vim.api.nvim_get_option_value("cursorline", { win = window }))

    value:set_host(Applet.host.tab({ label = "Chrome" }))
    value:close()
    assert(value:open())
    assert.are.equal("tab", value:host().kind)
    assert.are.equal("", vim.api.nvim_win_get_config(
      value:pane("transcript"):native().window).relative)
  end)

  it("supports semantic cursor, scrolling, completion, and effect boundaries", function()
    local first = new_pane("first", "editable", "")
    local second = new_pane("second", "editable", "")
    local value = applet({
      name = "pane-capabilities-test",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    local requested = {
      root = layout.frame({
        key = "frame",
        child = layout.split({
          key = "editors",
          axis = "horizontal",
          children = {
            { key = "first", grow = 1,
              child = pane("first", first,
                { mode = "normal", cursor = "start" }) },
            { key = "second", grow = 1,
              child = pane("second", second,
                { mode = "normal", cursor = "end" }) },
          },
        }),
      }),
      focus = { initial = "second" },
    }
    value:update(requested)
    assert(value:open())
    local first_pane, second_pane = value:pane("first"), value:pane("second")
    first_pane:replace_text("one\ntwo\nthree")
    second_pane:replace_text("alpha\nomega")
    assert(value:focus("first"))
    assert.are.same({ line = 1, column = 0 }, first_pane:cursor())
    assert.is_true(first_pane:at_start())
    first_pane:move_cursor("end")
    assert.is_true(first_pane:at_end())
    first_pane:move_cursor("up", 2)
    assert.are.equal(1, first_pane:cursor().line)
    first_pane:move_cursor("down", 1)
    assert.are.equal(2, first_pane:cursor().line)
    first_pane:move_cursor("start")
    assert(first_pane:scroll({ target = "start", align = "top" }))
    assert(first_pane:scroll({ align = "center" }))
    assert.has_error(function() first_pane:move_cursor("sideways") end,
      "cursor direction must be up, down, previous, next, start, or end")
    assert(value:focus("second"))
    assert.are.same({ line = 2, column = 4 }, second_pane:cursor())
    assert.is_true(second_pane:at_end())

    local previous_open = vim.ui.open
    vim.ui.open = nil
    assert.has_error(function() value:open_uri("https://example.test") end,
      "URI opening is unavailable")
    vim.ui.open = previous_open

    local previous_notify = vim.notify
    local notification
    vim.notify = function(message, level)
      notification = { message = message, level = level }
      return "notified"
    end
    local notified = value:notify("ready", vim.log.levels.INFO)
    vim.notify = previous_notify
    assert.are.equal("notified", notified)
    assert.are.same({ message = "ready", level = vim.log.levels.INFO },
      notification)
  end)

  it("retains scrolling applied to an unfocused Pane", function()
    local document = {}
    for index = 1, 30 do document[index] = "line " .. index end
    local transcript = new_pane(
      "transcript", "managed", table.concat(document, "\n"))
    local input = new_pane("input", "editable", "")
    local value = applet({
      name = "retained-scroll-test",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    value:update(tree(transcript, input))
    assert(value:open())

    local transcript_pane = value:pane("transcript")
    local window = transcript_pane:native().window
    assert(transcript_pane:scroll({ target = "end", align = "bottom" }))
    local scrolled_top = vim.api.nvim_win_call(
      window, function() return vim.fn.line("w0") end)
    assert.is_true(scrolled_top > 1)
    assert(value:focus("transcript"))

    assert.are.same({ line = 30, column = 0 }, transcript_pane:cursor())
    local restored_top = vim.api.nvim_win_call(
      window, function() return vim.fn.line("w0") end)
    assert.are.equal(scrolled_top, restored_top)
  end)

  it("wipes sensitive transient buffers even when another window displays them", function()
    local secret = new_pane("secret", "editable", "")
    local origin = vim.api.nvim_get_current_win()
    local value = applet({
      name = "sensitive-pane-test",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    value:update({
      root = layout.frame({
        key = "frame",
        child = pane("secret", secret, {
          lifecycle = "transient",
          owns_pane = true,
          sensitive = true,
          mode = "normal",
        }),
      }),
      focus = { initial = "secret" },
    })
    assert(value:open())
    local secret_pane = value:pane("secret")
    secret_pane:replace_text("private value")
    local buffer = secret_pane:native().buffer
    vim.api.nvim_set_option_value("modifiable", false, { buf = buffer })
    vim.api.nvim_set_current_win(origin)
    vim.cmd("belowright split")
    local foreign = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(foreign, buffer)
    assert.are.equal("private value", table.concat(lines(buffer), "\n"))

    value:close({ restore_origin = false })
    assert.is_false(vim.api.nvim_buf_is_valid(buffer))
    assert.are_not.equal(buffer, vim.api.nvim_win_get_buf(foreign))
    assert.is_true(secret.destroyed)
  end)

  for _, host_kind in ipairs({ "floating", "tab" }) do
    it("bounds public resources across " .. host_kind .. " Host lifecycles", function()
      local content = new_pane("content", "managed", "bounded")
      local value = applet({
        name = "public-lifecycle-" .. host_kind,
        host = host_kind == "floating"
            and Applet.host.floating({ width = 40, height = 10 })
          or Applet.host.tab({ label = "Public lifecycle" }),
      })
      value:update({
        root = layout.frame({ key = "frame", child = pane("content", content) }),
        focus = { initial = "content" },
      })

      assert.is_false(value:is_destroyed())
      assert.is_nil(value:_stats().observer_scope)
      assert(value:open())
      local live = value:_stats()
      assert.are.equal("live", live.observer_scope)
      assert.are.equal(1, live.observer_activations)
      assert.are.equal(1, live.interaction.active_participants)
      assert.is_true(live.interaction.key_observer_active)
      assert.is_true(content:is_connected())

      assert(value:close())
      local retained = value:_stats()
      assert.are.equal("retained", retained.observer_scope)
      assert.are.equal(2, retained.observer_activations)
      assert.are.equal(1, retained.observer_releases)
      assert.are.equal(0, retained.interaction.active_participants)
      assert.is_false(retained.interaction.key_observer_active)
      assert.is_false(content:is_connected())
      local callbacks = retained.observer_callbacks
      local scans = retained.observer_record_scans
      vim.api.nvim_exec_autocmds("VimResized", {})
      vim.api.nvim_exec_autocmds("WinEnter", {})
      local foreign = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_exec_autocmds("BufUnload", { buffer = foreign })
      vim.api.nvim_buf_delete(foreign, { force = true })
      assert.are.equal(callbacks, value:_stats().observer_callbacks)
      assert.are.equal(scans, value:_stats().observer_record_scans)

      assert(value:open())
      assert.are.equal("live", value:_stats().observer_scope)
      value:destroy()
      assert.is_true(value:is_destroyed())
      assert.is_false(content:is_destroyed())
      assert.is_false(content:is_connected())
    end)

    it("publishes " .. host_kind .. " Hosts after staged content commits", function()
      local origin_tab = vim.api.nvim_get_current_tabpage()
      local during_render = {}
      local value
      local staged = Applet.Pane.new({
        key = "staged",
        render = function()
          during_render[#during_render + 1] = {
            visible = value:is_visible(),
            tab = vim.api.nvim_get_current_tabpage(),
          }
          return ui.text({ key = "content", text = "staged" })
        end,
      })
      panes[#panes + 1] = staged
      staged:set_state({})
      value = applet({
        name = "staged-publication-" .. host_kind,
        host = host_kind == "floating"
            and Applet.host.floating({ width = 40, height = 10 })
          or Applet.host.tab({ label = "Staged" }),
      })
      value:update({
        root = layout.frame({ key = "frame", child = pane("staged", staged) }),
        focus = { initial = "staged" },
      })

      assert(value:open())
      assert.is_true(#during_render > 0)
      assert.is_false(during_render[1].visible)
      assert.are.equal(origin_tab, during_render[1].tab)
      assert.is_true(value:is_visible())
      assert.is_true(value:pane("staged"):is_visible())
    end)

    it("rolls back failed " .. host_kind .. " Host opens", function()
      local origin_tab = vim.api.nvim_get_current_tabpage()
      local origin_window = vim.api.nvim_get_current_win()
      local tabs_before = #vim.api.nvim_list_tabpages()
      local windows_before = #vim.api.nvim_list_wins()
      local broken = Applet.Pane.new({
        key = "broken",
        render = function() error("injected Pane failure") end,
      })
      panes[#panes + 1] = broken
      broken:set_state({})
      local value = applet({
        name = "failed-open-" .. host_kind,
        host = host_kind == "floating"
            and Applet.host.floating({ width = 40, height = 10 })
          or Applet.host.tab({ label = "Failed" }),
      })
      value:update({
        root = layout.frame({ key = "frame", child = pane("broken", broken) }),
      })

      local opened, err = value:open()
      assert.is_nil(opened)
      assert.are.equal("commit", err.phase)
      assert.matches("injected Pane failure", err.message)
      assert.is_false(value:is_open())
      assert.is_false(value:is_visible())
      local stats = value:_stats()
      assert.is_nil(stats.observer_scope)
      assert.are.equal(1, stats.observer_activations)
      assert.are.equal(1, stats.observer_releases)
      assert.are.equal(0, stats.interaction.active_participants)
      assert.is_false(stats.interaction.key_observer_active)
      assert.is_nil(broken.surface)
      assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
      assert.are.equal(windows_before, #vim.api.nvim_list_wins())
      assert.are.equal(origin_tab, vim.api.nvim_get_current_tabpage())
      assert.are.equal(origin_window, vim.api.nvim_get_current_win())
    end)

    it("keeps the committed " .. host_kind .. " frame after an update failure", function()
      local transcript = new_pane("transcript", "managed", "stable")
      local input = new_pane("input", "editable", "draft")
      local broken = Applet.Pane.new({
        key = "broken",
        render = function() error("injected update failure") end,
      })
      panes[#panes + 1] = broken
      broken:set_state({})
      local value = applet({
        name = "failed-update-" .. host_kind,
        host = host_kind == "floating"
            and Applet.host.floating({ width = 60, height = 20 })
          or Applet.host.tab({ label = "Rollback" }),
      })
      local initial = tree(transcript, input)
      value:update(initial)
      assert(value:open())
      value:pane("input"):replace_text("draft", { line = 1, column = 5 }, 1)
      local transcript_native = value:pane("transcript"):native()
      local input_native = value:pane("input"):native()
      local tabs_before = #vim.api.nvim_list_tabpages()

      local failed = tree(transcript, input)
      failed.root.child.children[#failed.root.child.children + 1] = {
        key = "broken-slot",
        basis = 3,
        grow = 0,
        child = pane("broken", broken),
      }
      value:update(failed)
      local committed, err = value:flush()
      assert.is_nil(committed)
      assert.are.equal("commit", err.phase)
      assert.matches("injected update failure", err.message)
      assert.is_true(value:is_open())
      assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
      assert.are.equal(transcript_native.buffer,
        value:pane("transcript"):native().buffer)
      assert.are.equal(input_native.buffer, value:pane("input"):native().buffer)
      assert.are.equal(transcript_native.window,
        value:pane("transcript"):native().window)
      assert.are.equal(input_native.window, value:pane("input"):native().window)
      assert.are.same({ "stable" }, lines(transcript_native.buffer))
      assert.are.same({ "draft" }, lines(input_native.buffer))
      assert.is_nil(broken.surface)
    end)

    it("retains committed Pane content after a " .. host_kind .. " render failure", function()
      local reported
      local transcript = Applet.Pane.new({
        key = "transcript",
        render = function(state)
          if state.fail then error("injected retained failure") end
          return ui.text({ key = "content", text = state.text })
        end,
      })
      panes[#panes + 1] = transcript
      transcript:set_state({ text = "committed", fail = false })
      local input = new_pane("input", "editable", "")
      local value = applet({
        name = "retained-failure-" .. host_kind,
        host = host_kind == "floating"
            and Applet.host.floating({ width = 60, height = 20 })
          or Applet.host.tab({ label = "Retained failure" }),
        on_error = function(err) reported = err end,
      })
      local requested = tree(transcript, input)
      value:update(requested)
      assert(value:open())
      local native = value:pane("transcript"):native()

      transcript:set_state({ text = "uncommitted", fail = true })
      value:update(requested)
      local committed, err = value:flush()
      assert.is_true(committed)
      assert.is_nil(err)
      assert.matches("injected retained failure", reported.message)
      assert.is_true(value:is_open())
      assert.are.equal(native.window, value:pane("transcript"):native().window)
      assert.are.equal(native.buffer, value:pane("transcript"):native().buffer)
      assert.are.same({ "committed" }, lines(native.buffer))
      assert.is_not_nil(transcript.surface)
    end)

    it("restores a replaced " .. host_kind .. " Pane after candidate failure", function()
      local committed_pane = new_pane("transcript", "managed", "original Pane")
      local input = new_pane("input", "editable", "")
      local replacement = Applet.Pane.new({
        key = "transcript",
        render = function() error("injected replacement failure") end,
      })
      panes[#panes + 1] = replacement
      replacement:set_state({})
      local value = applet({
        name = "failed-replacement-" .. host_kind,
        host = host_kind == "floating"
            and Applet.host.floating({ width = 60, height = 20 })
          or Applet.host.tab({ label = "Replacement" }),
      })
      value:update(tree(committed_pane, input))
      assert(value:open())
      local native = value:pane("transcript"):native()

      value:update(tree(replacement, input))
      local committed, err = value:flush()
      assert.is_nil(committed)
      assert.matches("injected replacement failure", err.message)
      assert.is_true(value:is_open())
      assert.are.same(native, value:pane("transcript"):native())
      assert.are.same({ "original Pane" }, lines(native.buffer))
      assert.is_not_nil(committed_pane.surface)
      assert.is_nil(replacement.surface)
    end)

    it("retains the closed " .. host_kind .. " composition after reopen failure", function()
      local committed_pane = new_pane("transcript", "managed", "retained composition")
      local input = new_pane("input", "editable", "draft")
      local broken = Applet.Pane.new({
        key = "transcript",
        render = function() error("injected reopen failure") end,
      })
      panes[#panes + 1] = broken
      broken:set_state({})
      local value = applet({
        name = "failed-reopen-" .. host_kind,
        host = host_kind == "floating"
            and Applet.host.floating({ width = 60, height = 20 })
          or Applet.host.tab({ label = "Reopen rollback" }),
      })
      local initial = tree(committed_pane, input)
      initial.root.child.children[1].child.owns_pane = true
      value:update(initial)
      assert(value:open())
      local native = value:pane("transcript"):native()
      value:close()

      value:update(tree(broken, input))
      local opened, err = value:open()
      assert.is_nil(opened)
      assert.matches("injected reopen failure", err.message)
      assert.is_false(committed_pane.destroyed)
      assert.is_true(vim.api.nvim_buf_is_valid(native.buffer))

      value:update(initial)
      assert(value:open())
      assert.are.equal(native.buffer, value:pane("transcript"):native().buffer)
      assert.are.same({ "retained composition" }, lines(native.buffer))
    end)

    it("publishes a replacement " .. host_kind .. " Applet on the retained Pane", function()
      local original = new_pane("transcript", "managed", "original content")
      local replacement = new_pane("transcript", "managed", "replacement content")
      local input = new_pane("input", "editable", "")
      local value = applet({
        name = "successful-replacement-" .. host_kind,
        host = host_kind == "floating"
            and Applet.host.floating({ width = 60, height = 20 })
          or Applet.host.tab({ label = "Applet replacement" }),
      })
      local initial = tree(original, input)
      initial.root.child.children[1].child.owns_pane = true
      value:update(initial)
      assert(value:open())
      local native = value:pane("transcript"):native()

      value:update(tree(replacement, input))
      assert(value:flush())
      assert.are.same(native, value:pane("transcript"):native())
      assert.are.same({ "replacement content" }, lines(native.buffer))
      assert.is_true(original.destroyed)
      assert.is_not_nil(replacement.surface)
    end)
  end
end)
