local Applet = require("applet")
local Domain = Applet.InteractionDomain
local ui = Applet.Pane.nodes
local widgets = Applet.Pane.widgets

local function tree(message, revision)
  return {
    root = ui.column({
      key = "root",
      gap = 1,
      children = {
        ui.region({
          key = "message",
          revision = revision,
          child = ui.target({
            key = "message:target",
            group = "messages",
            action = ui.action("open", { message = message }),
            focus_style = "Visual",
            child = ui.text({ key = "message:text", text = message }),
          }),
        }),
        ui.region({
          key = "footer",
          child = ui.text({ key = "footer:text", text = "footer" }),
        }),
      },
    }),
    chrome = {
      title = { { text = " Applet " } },
      options = { cursorline = true },
    },
    view = { scroll = "preserve", initial_target = "message:target" },
  }
end

local function surface(name, floating)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, name)
  local window
  if floating then
    window = vim.api.nvim_open_win(buffer, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 40,
      height = 8,
      style = "minimal",
      border = "single",
    })
  else
    window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(window, buffer)
  end
  return {
    buffer = buffer,
    window = function() return window end,
    owns_buffer = true,
    buffer_options = { buftype = "nofile", filetype = "applet-test" },
    window_options = { wrap = false },
  }, function() return window end
end

local function lines(buffer)
  return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local function image_backend(overrides)
  local value = {
    name = "test",
    available = true,
    cell_dimensions = function() return { width = 1, height = 1 } end,
    replace = function() end,
    clear = function() end,
    release = function() end,
    redraw = function() return false end,
    destroy = function() end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function mapping(buffer, mode, lhs)
  for _, value in ipairs(vim.api.nvim_buf_get_keymap(buffer, mode)) do
    if value.lhs == lhs then return value end
  end
end

describe("Pane buffer surfaces", function()
  local panes = {}
  local floating_windows = {}

  after_each(function()
    for _, value in ipairs(floating_windows) do
      if vim.api.nvim_win_is_valid(value.window) then
        vim.api.nvim_win_close(value.window, true)
      end
      if vim.api.nvim_buf_is_valid(value.buffer) then
        vim.api.nvim_buf_delete(value.buffer, { force = true })
      end
    end
    floating_windows = {}
    for _, pane in ipairs(panes) do pane:destroy() end
    panes = {}
    vim.cmd("silent! only")
    vim.cmd("stopinsert")
  end)

  local function pane(opts)
    local value = Applet.Pane.new(opts)
    panes[#panes + 1] = value
    return value
  end

  it("connects a managed document and preserves native buffer behavior", function()
    local chosen
    local value = pane({
      key = "managed",
      render = function(state) return tree(state.message, state.revision) end,
      handlers = {
        open = function(event) chosen = event end,
      },
    })
    local host, window = surface("applet-managed", true)
    assert.is_false(value:is_destroyed())
    assert.is_false(value:is_editable())
    assert.is_false(value:is_connected())
    assert.is_true(value:is_settled())
    value:_connect(host)
    assert.is_true(value:is_connected())
    assert.is_true(vim.bo[host.buffer].modifiable == false)
    assert.is_true(vim.bo[host.buffer].readonly)
    value:set_state({ message = "first\nsecond", revision = 1 })
    assert.is_false(value:is_settled())
    assert.is_true(value:flush())
    assert.is_true(value:is_settled())
    local targets = value:targets({ group = "messages" })
    assert.are.equal(1, #targets)
    assert.are.equal(1, #value:targets())
    assert.are.equal("message:target", targets[1].key)
    targets[1].disabled = true
    assert.is_false(value:targets({ group = "messages" })[1].disabled)
    assert.are.same({}, value:targets({ group = "missing" }))
    assert.has_error(function() value:targets(false) end,
      "Pane.targets: options must be a table")
    assert.has_error(function() value:targets({ group = false }) end,
      "Pane.targets.group: must be a string")
    assert.are.same({ "first", "second", "", "footer" }, lines(host.buffer))
    assert.are.equal("applet-test", vim.bo[host.buffer].filetype)
    assert.is_false(vim.wo[window()].wrap)
    assert.is_true(vim.wo[window()].cursorline)
    assert.are.same({ " Applet " },
      vim.tbl_map(function(chunk) return chunk[1] end,
        vim.api.nvim_win_get_config(window()).title))
    assert.is_nil(mapping(host.buffer, "n", "j"))
    assert.is_nil(mapping(host.buffer, "n", "k"))

    vim.api.nvim_win_set_cursor(window(), { 1, 0 })
    vim.api.nvim_win_call(window(), function() vim.cmd("normal! j") end)
    assert.are.equal(2, vim.api.nvim_win_get_cursor(window())[1])
    value:_draw_focus()
    local marks = vim.api.nvim_buf_get_extmarks(
      host.buffer, value.focus_namespace, 0, -1, { details = true })
    assert.are.equal(2, #marks)
    assert.are.equal("Visual", marks[1][4].hl_group)

    vim.api.nvim_win_call(window(), function() vim.cmd("normal! v") end)
    value:_draw_focus()
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(
      host.buffer, value.focus_namespace, 0, -1, {}))
    vim.api.nvim_win_call(window(), function() vim.cmd("normal! " .. vim.keycode("<Esc>")) end)

    local action = value.layout.targets["message:target"].action
    assert.is_true(require("applet.pane.input").dispatch_action(
      value, action, value.layout.targets["message:target"], 1, "n", 1, 0))
    assert.are.equal("open", chosen.action)
    assert.are.equal("first\nsecond", chosen.payload.message)
    assert.are.equal(value.committed_generation, chosen.generation)
    vim.api.nvim_win_set_cursor(window(), {
      vim.api.nvim_buf_line_count(host.buffer), 0,
    })
    value:update(vim.tbl_deep_extend("force", tree("first\nsecond", 1), {
      view = {
        scroll = "follow_end",
        target_intent = {
          key = "select-message",
          select = "message:target",
        },
      },
    }))
    local initial_ok, initial_error = value:flush()
    assert(initial_ok, vim.inspect(initial_error))
    assert.are.equal(1, vim.api.nvim_win_get_cursor(window())[1])

    value:update(tree("first\nsecond", 1))
    assert(value:flush())
    vim.api.nvim_win_set_cursor(window(), { 4, 0 })
    value:update(vim.tbl_deep_extend("force", tree("first\nsecond", 1), {
      view = {
        target_intent = {
          key = "select-message",
          select = "message:target",
        },
      },
    }))
    assert(value:flush())
    assert.are.equal(1, vim.api.nvim_win_get_cursor(window())[1])
    for revision = 1, 300 do
      value:update(vim.tbl_deep_extend("force", tree("first\nsecond", 1), {
        view = {
          target_intent = {
            key = "select-message-" .. revision,
            select = "message:target",
          },
        },
      }))
      assert(value:flush())
    end
    assert.are.equal("select-message-300", value.applied_target_intent)
    assert.is_nil(value.applied_intents)

    local config = vim.api.nvim_win_get_config(window())
    config.width = config.width + 1
    vim.api.nvim_win_set_config(window(), config)
    vim.api.nvim_exec_autocmds("WinResized", {})
    assert(vim.wait(1000, function()
      return value.last_width == vim.api.nvim_win_get_width(window())
    end))
    value:flush()
    local original_get_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "i" } end
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = host.buffer })
    vim.api.nvim_get_mode = original_get_mode

    vim.api.nvim_win_call(window(), function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("normal! Vjy")
    end)
    assert.are.same({ "first", "second" }, vim.fn.getreg('"', 1, true))

    local started = vim.api.nvim_win_call(window(), function()
      local ok, err = pcall(vim.cmd, "startinsert")
      return { ok = ok, error = err }
    end)
    if not started.ok then
      assert.matches("modifiable", tostring(started.error))
    end
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = host.buffer })
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i"
    end))
  end)

  it("coalesces automatic submissions at an optional frame cadence", function()
    assert.has_error(function()
      Applet.Pane.new({ key = "invalid-cadence", frame_interval_ms = 0 })
    end, "Pane.frame_interval_ms: must be a positive integer")

    local renders = 0
    local value = pane({
      key = "cadence",
      frame_interval_ms = 40,
      render = function(state)
        renders = renders + 1
        return tree(state.message, state.revision)
      end,
      handlers = { open = function() end },
    })
    local host = surface("applet-cadence", true)
    value:_connect(host)
    value:set_state({ message = "initial", revision = 1 })
    assert(vim.wait(1000, function() return value:is_settled() end))

    local before = renders
    for revision = 2, 8 do
      value:set_state({ message = "frame " .. revision, revision = revision })
    end
    assert.is_false(value:is_settled())
    assert(vim.wait(1000, function()
      return value:is_settled() and lines(host.buffer)[1] == "frame 8"
    end))
    assert.are.equal(before + 1, renders)

    assert.has_error(function()
      value:set_state({}, { unknown = true })
    end, "Pane.set_state.unknown: is not recognized")
    assert.has_error(function()
      value:set_state({}, "eager")
    end, "Pane.set_state: options must be a table")
    assert.has_error(function()
      value:set_state({}, { eager = "yes" })
    end, "Pane.set_state.eager: must be a boolean")
    value:set_state({ message = "eager", revision = 9 }, { eager = true })
    assert(vim.wait(1000, function()
      return value:is_settled() and lines(host.buffer)[1] == "eager"
    end))
    value:set_state({ message = "reconnected", revision = 10 })
    value:_disconnect()
    assert.is_false(value:is_connected())
    value:_connect(host)
    assert(vim.wait(1000, function()
      return value:is_settled() and lines(host.buffer)[1] == "reconnected"
    end))
  end)

  it("uses one Pane value for direct content and runtime access", function()
    local origin = vim.api.nvim_get_current_win()
    local value = pane({ key = "direct-runtime", buffer_mode = "editable" })
    local host, window = surface("applet-direct-runtime", true)
    value:_connect(host)
    assert.is_true(value:is_editable())
    assert.is_true(value:is_connected())
    value:update(ui.text({ key = "direct-text", text = "one\ntwo" }))
    assert(value:flush())
    assert(value:replace_text("one\ntwo"))

    assert.is_true(value:is_mounted())
    assert.is_true(value:is_visible())
    assert.is_true(value:is_focused())
    assert.are.equal("normal", value:mode())
    assert.are.same({ buffer = host.buffer, window = window() }, value:native())

    vim.api.nvim_set_current_win(origin)
    assert.is_false(value:is_focused())
    assert.is_true(value:focus())
    assert.are.equal(window(), vim.api.nvim_get_current_win())

    value:set_cursor({ line = 2, column = 1 })
    assert.are.same({ line = 2, column = 1 }, value:cursor())

    assert.are.same({
      host = "direct",
      row = 1,
      col = 1,
      content_width = 40,
      content_height = 8,
      outer_width = 40,
      outer_height = 8,
      screen_row = 1,
      screen_col = 1,
      screen_width = 40,
      screen_height = 8,
      zindex = vim.api.nvim_win_get_config(window()).zindex,
    }, value:geometry())
    assert.is_true(value:move_cursor("start"))
    assert.are.same({ line = 1, column = 0 }, value:cursor())
    assert.is_true(value:move_cursor("end"))
    assert.are.same({ line = 2, column = 2 }, value:cursor())
    assert.is_true(value:scroll({ target = "start", align = "top" }))
    assert.are.same({ line = 1, column = 0 }, value:cursor())

    local original_feedkeys = vim.api.nvim_feedkeys
    local fed = {}
    vim.api.nvim_feedkeys = function(keys, mode, escape)
      fed[#fed + 1] = { keys, mode, escape }
    end
    assert.is_boolean(value:completion_visible())
    assert.is_true(value:complete())
    assert.is_true(value:completion_move("next"))
    assert.is_true(value:completion_move("previous"))
    assert.is_true(value:completion_accept())
    vim.api.nvim_feedkeys = original_feedkeys
    assert.are.same({
      { vim.keycode("<C-x><C-f>"), "in", false },
      { vim.keycode("<C-n>"), "in", false },
      { vim.keycode("<C-p>"), "in", false },
      { vim.keycode("<C-y>"), "in", false },
    }, fed)

    local get_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "i" } end
    local mode = value:mode()
    vim.api.nvim_get_mode = get_mode
    assert.are.equal("insert", mode)

    value:_disconnect()
    assert.is_false(value:is_connected())
    value:destroy()
    assert.is_true(value:is_destroyed())
    assert.has_error(function() value:cursor() end, "Pane is unavailable")
  end)

  it("draws target-specific active and inactive focus decorations", function()
    local value = pane({ key = "focus-decorations" })
    local host, window = surface("applet-focus-decorations", true)
    value:_connect(host)
    value:update(ui.column({
      key = "focus-root",
      gap = 1,
      children = {
        ui.target({
          key = "focus-target",
          focus = {
            active = {
              {
                row = 0,
                chunks = { { text = "[open]", group = "String" } },
                win_col = 8,
              },
            },
            inactive = {
              {
                row = 0,
                chunks = { { text = "[idle]", group = "Comment" } },
                position = "eol",
              },
            },
          },
          child = ui.text({ key = "focus-text", text = "message" }),
        }),
        ui.text({ key = "focus-footer", text = "footer" }),
      },
    }))
    assert(value:flush())

    local function virtual_text()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
          host.buffer, value.focus_namespace, 0, -1, { details = true })) do
        if mark[4].virt_text then
          result[#result + 1] = {
            text = mark[4].virt_text[1][1],
            group = mark[4].virt_text[1][2],
            position = mark[4].virt_text_pos,
            win_col = mark[4].virt_text_win_col,
          }
        end
      end
      return result
    end

    vim.api.nvim_win_set_cursor(window(), { 1, 0 })
    value:_draw_focus()
    assert.are.same({ {
      text = "[open]", group = "String", position = "win_col", win_col = 8,
    } }, virtual_text())

    vim.api.nvim_win_set_cursor(window(), { 3, 0 })
    value:_draw_focus()
    assert.are.same({ {
      text = "[idle]", group = "Comment", position = "eol",
    } }, virtual_text())

    vim.api.nvim_win_call(window(), function() vim.cmd("normal! v") end)
    value:_draw_focus()
    assert.are.same({}, virtual_text())
  end)

  it("does not redraw stable focus decorations for chrome-only updates", function()
    local value = pane({ key = "stable-focus" })
    local host = surface("applet-stable-focus", true)
    value:_connect(host)
    local root = ui.target({
      key = "stable-focus:target",
      focus = {
        active = { {
          row = 0,
          chunks = { { text = "[active]", group = "String" } },
          position = "eol",
        } },
      },
      child = ui.text({ key = "stable-focus:text", text = "message" }),
    })
    local function document(title)
      return {
        root = root,
        chrome = { title = { { text = title } } },
      }
    end
    value:update(document("first"))
    assert(value:flush())
    local before = value:_stats()

    local original_clear = vim.api.nvim_buf_clear_namespace
    local focus_clears = 0
    vim.api.nvim_buf_clear_namespace = function(buffer, namespace, first, last)
      if buffer == host.buffer and namespace == value.focus_namespace then
        focus_clears = focus_clears + 1
      end
      return original_clear(buffer, namespace, first, last)
    end
    local ok, err = pcall(function()
      value:update(document("second"))
      assert(value:flush())
    end)
    vim.api.nvim_buf_clear_namespace = original_clear

    assert(ok, err)
    assert.are.equal(0, focus_clears)
    local after = value:_stats()
    assert.are.equal(before.region_compilations, after.region_compilations)
    assert.are.equal(before.region_reuses, after.region_reuses)
  end)

  it("reconnects an idempotent buffer when its host window changes", function()
    local value = pane({ key = "reconnect-window" })
    local host = surface("applet-reconnect-window", true)
    local original_bufhidden = vim.api.nvim_get_option_value(
      "bufhidden", { buf = host.buffer })
    host.buffer_options.bufhidden = "hide"
    value:_connect(host)
    assert.are.equal("hide", vim.api.nvim_get_option_value(
      "bufhidden", { buf = host.buffer }))
    value:update(ui.text({ key = "message", text = "first" }))
    assert(value:flush())

    local second = vim.api.nvim_open_win(host.buffer, true, {
      relative = "editor",
      row = 2,
      col = 2,
      width = 40,
      height = 8,
      style = "minimal",
    })
    assert(value:flush())
    assert.is_nil(value.domain.dirty[value])
    host.window = function() return second end
    value:_connect(host)
    value:update(ui.text({ key = "message", text = "first" }))
    assert.is_true(value.domain.dirty[value])
    assert(value:flush())
    assert.are.equal(second, value.surface.window())
    assert.are.same({ "first" }, lines(host.buffer))

    local replacement = vim.tbl_extend("force", {}, host)
    replacement.buffer_options = {
      buftype = "nofile",
      filetype = "applet-test",
    }
    value:_connect(replacement)
    assert.are.equal(original_bufhidden, vim.api.nvim_get_option_value(
      "bufhidden", { buf = host.buffer }))
  end)

  it("replaces ambient interaction scopes through one Applet dispatcher", function()
    local errors = {}
    local value = pane({
      key = "ambient-interaction",
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host = surface("applet-ambient-interaction", true)
    local function interaction(revision, dispatch, pass)
      return {
        revision = revision,
        scopes = { {
          key = "applet",
          bindings = { {
            mode = "n",
            lhs = "x",
            action = ui.action("ambient.action"),
          } },
        } },
        has_action = function(name) return name == "ambient.action" end,
        dispatch = dispatch,
        pass = pass,
      }
    end
    host.interaction = interaction(1, function(event) event:pass() end,
      function() error("native pass failed") end)
    value:_connect(host)
    value:update(ui.text({ key = "text", text = "ambient" }))
    assert(value:flush())
    local input = require("applet.pane.input")
    assert.is_false(input.dispatch(value, "n", "x"))
    assert.matches("native pass failed", errors[#errors].message)

    value:set_surface_interaction(interaction(2,
      function(event) event:pass() end))
    assert(value:flush())
    assert.is_false(input.dispatch(value, "n", "x"))

    value:set_surface_interaction(interaction(3, function() return false end))
    assert(value:flush())
    assert.is_false(input.dispatch(value, "n", "x"))

    value:set_surface_interaction(interaction(4, function() end))
    assert(value:flush())
    assert.is_true(input.dispatch(value, "n", "x"))
    assert.is_false(input.dispatch_action(value,
      ui.action("absent.action"), nil, 1, "n", 0, 0))
  end)

  it("coalesces state and reconciles stable regions incrementally", function()
    local renders = 0
    local value = pane({
      key = "regions",
      handlers = { open = function() end },
      render = function(state)
        renders = renders + 1
        return tree(state.message, state.revision)
      end,
    })
    local host = surface("applet-regions")
    value:_connect(host)
    value:set_state({ message = "discarded", revision = 1 })
    value:set_state({ message = "current", revision = 2 })
    local coalesced_ok, coalesced_error = value:flush()
    assert(coalesced_ok, vim.inspect(coalesced_error))
    assert.are.equal(1, renders)
    assert.are.same({ "current", "", "footer" }, lines(host.buffer))
    local first_tick = vim.api.nvim_buf_get_changedtick(host.buffer)
    local initial_stats = value:_stats()
    assert.are.equal(2, initial_stats.requested_generations)
    assert.are.equal(1, initial_stats.renders)
    assert.are.equal(1, initial_stats.commits)
    value:set_state({ message = "current", revision = 2 })
    value:flush()
    assert.are.equal(first_tick, vim.api.nvim_buf_get_changedtick(host.buffer))
    assert.are.equal("rebuild", value.reconcile_state.content_result)
    assert.are.equal(initial_stats.commits, value:_stats().commits)
    assert.is_true(value:_stats().region_reuses > initial_stats.region_reuses)

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    value:set_state({ message = "one\ntwo", revision = 3 })
    value:flush()
    assert.are.equal("regions", value.reconcile_state.content_result)
    assert.are.same({ "one", "two", "", "footer" }, lines(host.buffer))
    assert.are.equal(4, vim.api.nvim_win_get_cursor(0)[1])

    local content_tick = vim.api.nvim_buf_get_changedtick(host.buffer)
    local extmarks = value:_stats().extmark_writes
    local title_tree = tree("one\ntwo", 3)
    title_tree.chrome.title = { { text = " New title " } }
    value:update(title_tree)
    value:flush()
    assert.are.equal(content_tick, vim.api.nvim_buf_get_changedtick(host.buffer))
    assert.are.equal(extmarks, value:_stats().extmark_writes)

    value:update({
      root = ui.column({
        key = "reordered",
        gap = 1,
        children = {
          ui.region({
            key = "new",
            child = ui.text({ key = "new:text", text = "new" }),
          }),
          ui.region({
            key = "message",
            child = ui.text({ key = "message:text", text = "one\ntwo" }),
          }),
        },
      }),
    })
    value:flush()
    assert.are.equal("island", value.reconcile_state.content_result)
    assert.are.same({ "new", "", "one", "two" }, lines(host.buffer))

    local function regions(middle)
      return {
        root = ui.column({
          key = "three-regions",
          children = {
            ui.region({ key = "a", child = ui.text({ key = "a:text", text = "a" }) }),
            ui.region({ key = middle, child = ui.text({ key = middle .. ":text", text = middle }) }),
            ui.region({ key = "c", child = ui.text({ key = "c:text", text = "c" }) }),
          },
        }),
      }
    end
    value:update(regions("b"))
    value:flush()
    value:update(regions("replacement"))
    value:flush()
    assert.are.equal("island", value.reconcile_state.content_result)
    assert.are.same({ "a", "replacement", "c" }, lines(host.buffer))

    local function target_after(prefix)
      return {
        root = ui.column({ key = "target-regions", children = {
          ui.region({
            key = "prefix",
            child = ui.text({ key = "prefix:text", text = prefix }),
          }),
          ui.region({
            key = "choice",
            child = ui.target({
              key = "stable-choice",
              action = ui.action("open"),
              child = ui.text({ key = "choice:text", text = "choose" }),
            }),
          }),
        } }),
      }
    end
    value:update(target_after("before"))
    value:flush()
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    value:update(target_after("before\nand after"))
    value:flush()
    assert.are.same({ 3, 2 }, vim.api.nvim_win_get_cursor(0))

    vim.bo[host.buffer].modifiable = true
    vim.bo[host.buffer].readonly = false
    vim.api.nvim_buf_set_lines(host.buffer, 0, -1, false, { "external" })
    vim.bo[host.buffer].modifiable = false
    vim.bo[host.buffer].readonly = true
    assert.is_true(value.reconcile_state.unknown)
    value:update(ui.text({ key = "rebuilt", text = "rebuilt" }))
    value:flush()
    assert.are.equal("rebuild", value.reconcile_state.content_result)
    assert.are.same({ "rebuilt" }, lines(host.buffer))

    vim.bo[host.buffer].modifiable = true
    vim.bo[host.buffer].readonly = false
    vim.api.nvim_buf_set_lines(host.buffer, 0, -1, false, { "external again" })
    vim.bo[host.buffer].modifiable = false
    vim.bo[host.buffer].readonly = true
    value:update(ui.text({ key = "rebuilt", text = "rebuilt" }))
    value:flush()
    assert.are.equal("rebuild", value.reconcile_state.content_result)
    assert.are.same({ "rebuilt" }, lines(host.buffer))
  end)

  it("reconciles a changed prefix region while appending a sibling", function()
    local value = pane({ key = "growing-prefix" })
    local host = surface("applet-growing-prefix")
    value:_connect(host)
    value:update({
      root = ui.column({ key = "before", children = {
        ui.region({
          key = "prefix",
          child = ui.text({ key = "prefix:text", text = "old" }),
        }),
      } }),
    })
    assert(value:flush())
    value:update({
      root = ui.column({ key = "after", children = {
        ui.region({
          key = "prefix",
          child = ui.text({ key = "prefix:text", text = "new\nseparator" }),
        }),
        ui.region({
          key = "sibling",
          child = ui.text({ key = "sibling:text", text = "sibling" }),
        }),
      } }),
    })
    assert(value:flush())
    assert.are.same({ "new", "separator", "sibling" }, lines(host.buffer))
  end)

  it("does not reread a known managed buffer before an incremental splice", function()
    local value = pane({ key = "known-buffer" })
    local host = surface("applet-known-buffer")
    value:_connect(host)
    local function document(first, revision)
      return {
        root = ui.column({ key = "known-regions", children = {
          ui.region({
            key = "first", revision = revision,
            child = ui.text({ key = "first:text", text = first }),
          }),
          ui.region({
            key = "stable", revision = 1,
            child = ui.text({ key = "stable:text", text = "stable" }),
          }),
        } }),
      }
    end
    value:update(document("before", 1))
    assert(value:flush())

    local original_get_lines = vim.api.nvim_buf_get_lines
    local original_get_mark = vim.api.nvim_buf_get_extmark_by_id
    local complete_reads = 0
    local region_mark_reads = 0
    vim.api.nvim_buf_get_lines = function(buffer, first, last, strict)
      if buffer == host.buffer and first == 0 and last == -1 then
        complete_reads = complete_reads + 1
      end
      return original_get_lines(buffer, first, last, strict)
    end
    vim.api.nvim_buf_get_extmark_by_id = function(
        buffer, namespace, id, options)
      if buffer == host.buffer and namespace == value.region_namespace then
        region_mark_reads = region_mark_reads + 1
      end
      return original_get_mark(buffer, namespace, id, options)
    end
    local ok, err = pcall(function()
      value:update(document("after", 2))
      assert(value:flush())
    end)
    vim.api.nvim_buf_get_lines = original_get_lines
    vim.api.nvim_buf_get_extmark_by_id = original_get_mark

    assert(ok, err)
    assert.are.equal(0, complete_reads)
    assert.are.equal(0, region_mark_reads)
    assert.are.same({ "after", "stable" }, lines(host.buffer))
  end)

  it("appends an implicit document without rewriting its retained prefix", function()
    local value = pane({ key = "implicit-tail-splice" })
    local host = surface("applet-implicit-tail-splice")
    value:_connect(host)
    local entries = {}
    for index = 1, 100 do entries[index] = "line " .. index end
    local function document()
      local children = {}
      for index, entry in ipairs(entries) do
        children[index] = ui.text({
          key = "implicit-tail:" .. index,
          runs = { { text = entry, style = "String" } },
          wrap = "native",
        })
      end
      return ui.column({ key = "implicit-tail:document", children = children })
    end
    local function decoration_ids()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
          host.buffer, value.namespace, 0, -1, {})) do
        result[mark[2]] = mark[1]
      end
      return result
    end

    value:update(document())
    assert(value:flush())
    local initial = decoration_ids()
    assert.are.equal(100, vim.tbl_count(initial))
    local writes = value:_stats().extmark_writes

    local original = vim.api.nvim_buf_set_lines
    local calls = {}
    vim.api.nvim_buf_set_lines = function(buffer, first, last, strict, replacement)
      if buffer == host.buffer then
        calls[#calls + 1] = {
          first = first,
          last = last,
          replacement = vim.deepcopy(replacement),
        }
      end
      return original(buffer, first, last, strict, replacement)
    end
    entries[#entries + 1] = "line 101"
    local ok, err = pcall(function()
      value:update(document())
      assert(value:flush())
    end)
    vim.api.nvim_buf_set_lines = original

    assert(ok, err)
    assert.are.same({ {
      first = 100, last = 100, replacement = { "line 101" },
    } }, calls)
    local appended = decoration_ids()
    for row = 0, 99 do assert.are.equal(initial[row], appended[row]) end
    assert.is_true(value:_stats().extmark_writes - writes <= 2)
  end)

  it("reconciles empty implicit and explicit documents", function()
    local value = pane({ key = "empty-document-transitions" })
    local host = surface("applet-empty-document-transitions")
    value:_connect(host)
    local function implicit(text)
      return ui.column({
        key = "empty:implicit",
        children = text and {
          ui.text({ key = "empty:implicit:text", text = text }),
        } or {},
      })
    end
    local function explicit(text)
      return ui.column({
        key = "empty:explicit",
        children = {
          ui.region({
            key = "empty:first",
            child = ui.column({ key = "empty:first:body", children = {} }),
          }),
          ui.region({
            key = "empty:last",
            child = text
                and ui.text({ key = "empty:last:text", text = text })
              or ui.column({ key = "empty:last:body", children = {} }),
          }),
        },
      })
    end

    for _, document in ipairs({ implicit, explicit }) do
      value:update(document())
      assert(value:flush())
      assert.are.same({ "" }, lines(host.buffer))
      value:update(document("value"))
      assert(value:flush())
      assert.are.same({ "value" }, lines(host.buffer))
      value:update(document())
      assert(value:flush())
      assert.are.same({ "" }, lines(host.buffer))
    end
  end)

  it("preserves a free cursor position inside a replaced region", function()
    local value = pane({ key = "region-cursor" })
    local host, window = surface("applet-region-cursor", true)
    value:_connect(host)
    local function document(last)
      local lines = {}
      for index = 1, last do lines[index] = "line " .. index end
      return ui.region({
        key = "document",
        revision = last,
        child = ui.text({
          key = "document:text",
          text = table.concat(lines, "\n"),
        }),
      })
    end
    value:update(document(8))
    assert(value:flush())
    vim.api.nvim_win_set_cursor(window(), { 6, 2 })
    value:update(document(9))
    assert(value:flush())
    assert.are.same({ 6, 2 }, vim.api.nvim_win_get_cursor(window()))
  end)

  it("preserves the viewport topline inside a replaced region", function()
    local value = pane({ key = "region-topline" })
    local host, window = surface("applet-region-topline", true)
    value:_connect(host)
    local function document(prefix, revision)
      local content = {}
      for index = 1, 20 do
        content[index] = prefix .. " " .. index
      end
      return ui.region({
        key = "document",
        revision = revision,
        child = ui.text({
          key = "document:text",
          text = table.concat(content, "\n"),
        }),
      })
    end
    value:update(document("old", 1))
    assert(value:flush())
    vim.api.nvim_win_call(window(), function()
      vim.fn.winrestview({ lnum = 10, col = 0, topline = 5, leftcol = 0 })
    end)
    value:update(document("new", 2))
    assert(value:flush())
    local restored = vim.api.nvim_win_call(
      window(), function() return vim.fn.winsaveview() end)
    assert.are.equal(10, restored.lnum)
    assert.are.equal(5, restored.topline)
  end)

  it("changes Theme in place while preserving the viewport", function()
    local first = Applet.Theme.new({ groups = { accent = "String" } })
    local second = Applet.Theme.new({ groups = { accent = "Comment" } })
    local value = pane({ key = "dynamic-theme", theme = first })
    local host, window = surface("applet-dynamic-theme", true)
    value:_connect(host)
    local content = {}
    for index = 1, 20 do content[index] = ("line %02d"):format(index) end
    value:update(ui.region({
      key = "document",
      child = ui.text({
        key = "document:text",
        runs = { { text = table.concat(content, "\n"), style = "accent" } },
      }),
    }))
    assert(value:flush())
    vim.api.nvim_win_call(window(), function()
      vim.fn.winrestview({ lnum = 10, col = 0, topline = 5, leftcol = 0 })
    end)

    assert.are.equal(second, value:set_theme(second))
    assert(value:flush())
    local restored = vim.api.nvim_win_call(
      window(), function() return vim.fn.winsaveview() end)
    assert.are.equal(10, restored.lnum)
    assert.are.equal(5, restored.topline)
    local marks = vim.api.nvim_buf_get_extmarks(
      host.buffer, value.namespace, 0, -1, { details = true })
    assert.are.equal("Comment", marks[1][4].hl_group)
  end)

  it("retains decorations and region anchors for unchanged regions", function()
    local value = pane({ key = "stable-decorations" })
    local host = surface("applet-stable-decorations")
    value:_connect(host)
    local function content(first)
      return ui.column({ key = "regions", children = {
        ui.region({ key = "first", child = ui.text({
          key = "first:text", runs = { { text = first, style = "String" } },
        }) }),
        ui.region({ key = "second", child = ui.text({
          key = "second:text", runs = { { text = "second", style = "Comment" } },
        }) }),
      } })
    end
    value:update(content("first"))
    value:flush()
    local marks = vim.api.nvim_buf_get_extmarks(
      host.buffer, value.namespace, 0, -1, { details = true })
    local first_id, second_id
    for _, mark in ipairs(marks) do
      if mark[2] == 0 then first_id = mark[1] end
      if mark[2] == 1 then second_id = mark[1] end
    end
    assert.is_number(first_id)
    assert.is_number(second_id)
    local writes = value:_stats().extmark_writes
    value:update(content("first\ncontinued"))
    value:flush()
    local second = vim.api.nvim_buf_get_extmark_by_id(
      host.buffer, value.namespace, second_id, { details = true })
    local first = vim.api.nvim_buf_get_extmark_by_id(
      host.buffer, value.namespace, first_id, { details = true })
    assert.are.same({ 0, 0 }, { first[1], first[2] })
    assert.are.same({ 2, 0 }, { second[1], second[2] })
    assert.are.equal(2, second[3].end_row)
    assert.are.equal(6, second[3].end_col)
    assert.are.equal(2, value:_stats().extmark_writes - writes)
  end)

  it("keeps stable decoration ranges valid when their region content changes", function()
    local value = pane({ key = "changed-decoration-region" })
    local host = surface("applet-changed-decoration-region")
    value:_connect(host)
    local function content(trailer, revision)
      return ui.region({
        key = "changing",
        revision = revision,
        child = ui.text({
          key = "changing:text",
          runs = {
            { text = "marked", style = "String" },
            { text = "\n" .. trailer },
          },
        }),
      })
    end
    value:update(content("pending", 1))
    assert(value:flush())
    value:update(content("complete\nmore", 2))
    assert(value:flush())

    local marks = vim.api.nvim_buf_get_extmarks(
      host.buffer, value.namespace, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.are.same({ 0, 0 }, { marks[1][2], marks[1][3] })
    assert.are.equal(0, marks[1][4].end_row)
    assert.are.equal(6, marks[1][4].end_col)
  end)

  it("keeps randomized incremental reconciliation equivalent to a clean render", function()
    local incremental = pane({
      key = "incremental-model",
      handlers = { open = function() end },
    })
    local incremental_host = surface("applet-incremental-model")
    incremental_host.window = function() return nil end
    incremental:_connect(incremental_host)
    local entries, next_key, seed = {}, 1, 1234567
    local function random(limit)
      seed = (seed * 1103515245 + 12345) % 2147483648
      return (seed % limit) + 1
    end
    local function model_tree()
      local regions = {}
      for _, entry in ipairs(entries) do
        regions[#regions + 1] = ui.region({
          key = entry.key,
          revision = entry.revision,
          child = ui.target({
            key = entry.key .. ":target",
            action = ui.action("open", { key = entry.key }),
            child = ui.source({
              key = entry.key .. ":source",
              language = "lua",
              child = ui.text({
                key = entry.key .. ":text",
                runs = { { text = entry.text, style = entry.style } },
              }),
            }),
          }),
        })
      end
      return {
        root = ui.column({ key = "model", children = regions }),
        chrome = { options = { wrap = false } },
      }
    end
    for step = 1, 50 do
      local operation = random(4)
      if #entries == 0 or operation == 1 then
        entries[#entries + 1] = {
          key = "entry:" .. next_key,
          revision = 1,
          text = "value " .. next_key,
          style = next_key % 2 == 0 and "String" or "Comment",
        }
        next_key = next_key + 1
      elseif operation == 2 then
        local entry = entries[random(#entries)]
        entry.revision = entry.revision + 1
        entry.text = entry.text .. "\nstep " .. step
      elseif operation == 3 and #entries > 1 then
        table.remove(entries, random(#entries))
      elseif #entries > 1 then
        local left, right = random(#entries), random(#entries)
        entries[left], entries[right] = entries[right], entries[left]
      end
      incremental:update(model_tree())
      local ok, err = incremental:flush()
      assert(ok, vim.inspect(err))
    end

    local clean = pane({
      key = "clean-model",
      handlers = { open = function() end },
    })
    local clean_host = surface("applet-clean-model")
    clean_host.window = function() return nil end
    clean:_connect(clean_host)
    clean:update(model_tree())
    local ok, err = clean:flush()
    assert(ok, vim.inspect(err))
    assert.are.same(lines(clean_host.buffer), lines(incremental_host.buffer))
    for _, field in ipairs({
      "decorations", "targets", "target_order", "scopes", "source_ranges",
      "binding_pairs", "chrome",
    }) do
      assert.are.same(clean.layout[field], incremental.layout[field])
    end

    local function persistent_marks(value, buffer)
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
          buffer, value.namespace, 0, -1, { details = true })) do
        result[#result + 1] = {
          row = mark[2],
          col = mark[3],
          end_row = mark[4].end_row,
          end_col = mark[4].end_col,
          group = mark[4].hl_group,
        }
      end
      return result
    end
    assert.are.same(persistent_marks(clean, clean_host.buffer),
      persistent_marks(incremental, incremental_host.buffer))
  end)

  it("retains source syntax outside changes and redetects affected paths", function()
    local value = pane({ key = "retained-source-syntax" })
    local host = surface("applet-retained-source-syntax")
    value:_connect(host)
    local function content(source_text, source_revision, tail, tail_revision)
      return {
        root = ui.column({ key = "source-regions", children = {
          ui.region({
            key = "source", revision = source_revision,
            child = ui.source({
              key = "source:lua", path = "example.lua",
              child = ui.text({ key = "source:text", text = source_text }),
            }),
          }),
          ui.region({
            key = "tail", revision = tail_revision,
            child = ui.text({ key = "tail:text", text = tail }),
          }),
        } }),
      }
    end
    value:update(content("local value = 1", 1, "before", 1))
    assert(value:flush())

    local filetype_match = vim.filetype.match
    local matches = 0
    vim.filetype.match = function(options)
      matches = matches + 1
      return filetype_match(options)
    end
    local ok, err = pcall(function()
      value:update(content("local value = 1", 1, "after", 2))
      assert(value:flush())
      assert.are.equal(0, matches)
      value:update(content("local value = 2", 2, "after", 2))
      assert(value:flush())
    end)
    vim.filetype.match = filetype_match

    assert(ok, err)
    assert.are.equal(1, matches)
    assert.are.equal(1, vim.b[host.buffer].applet_source_regions)
  end)

  it("routes only declared menu mappings and keeps the cursor as selection", function()
    local choices = {}
    local value = pane({
      key = "menu",
      handlers = {
        choose = function(event) choices[#choices + 1] = event.payload.id end,
      },
    })
    local host, window = surface("applet-menu")
    value:_connect(host)
    local menu, entry = widgets.menu({
      key = "options",
      items = {
        { key = "one", label = "One", action = ui.action("choose", { id = 1 }) },
        { key = "two", label = "Two", disabled = true },
        {
          key = "three",
          label = "Three",
          detail = "third detail",
          action = ui.action("choose", { id = 3 }),
          quick_keys = { "3" },
        },
      },
      keys = {
        previous = "<Up>",
        next = "<Down>",
        activate = "<CR>",
      },
    })
    value:update({
      root = menu,
      view = { target_intent = widgets.menu_intent(entry, "open-options") },
    })
    value:flush()
    assert.is_nil(mapping(host.buffer, "n", "j"))
    assert.is_truthy(mapping(host.buffer, "n", "<Down>"))
    assert.is_truthy(mapping(host.buffer, "n", "<CR>"))
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(window()))
    vim.api.nvim_win_set_cursor(window(), { 1, 0 })

    assert.is_true(require("applet.pane.input").dispatch(value, "n", "<Down>"))
    assert.are.equal(3, vim.api.nvim_win_get_cursor(window())[1])
    assert.are.equal("options:item:three",
      require("applet.pane.input").focus_target(value).key)
    vim.api.nvim_win_set_cursor(window(), { 4, 0 })
    assert.are.equal("options:item:three",
      require("applet.pane.input").focus_target(value).key)
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "<CR>"))
    assert.are.same({ 3 }, choices)
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "<Up>"))
    assert.are.equal(1, vim.api.nvim_win_get_cursor(window())[1])
    vim.api.nvim_win_set_cursor(window(), { 4, 0 })
    assert.is_true(value:focus_target_intent())
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(window()))
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "3"))
    assert.are.same({ 3, 3 }, choices)
    vim.api.nvim_win_set_cursor(window(), { 2, 0 })
    assert.is_true(require("applet.pane.input").move(value, {
      group = "options",
      direction = "next",
    }, 1))
    assert.are.equal(3, vim.api.nvim_win_get_cursor(window())[1])
    vim.api.nvim_win_set_cursor(window(), { 2, 0 })
    assert.is_true(require("applet.pane.input").move(value, {
      group = "options",
      direction = "previous",
    }, 1))
    assert.are.equal(1, vim.api.nvim_win_get_cursor(window())[1])
    assert.is_true(require("applet.pane.input").dispatch_action(
      value,
      ui.action("applet.target.reveal", { target = "options:item:three" }),
      nil, 1, "n", 0, 0))
    assert.are.equal(3, vim.api.nvim_win_get_cursor(window())[1])
    assert.is_true(require("applet.pane.input").contains({
      { row = 2, col = 0, width = 3, height = 1 },
    }, 2, 1))

    value:update(widgets.menu({
      key = "natural",
      items = {
        { key = "one", label = "One", action = ui.action("choose", { id = 1 }) },
        { key = "two", label = "Two", action = ui.action("choose", { id = 2 }) },
        { key = "three", label = "Three", action = ui.action("choose", { id = 3 }) },
      },
    }))
    value:flush()
    assert.is_false(value:focus_target_intent())
    assert.is_nil(mapping(host.buffer, "n", "<Down>"))
    vim.api.nvim_win_set_cursor(window(), { 1, 0 })
    vim.api.nvim_win_call(window(), function() vim.cmd("normal! j") end)
    assert.are.equal(2, vim.api.nvim_win_get_cursor(window())[1])
    assert.are.equal("natural:item:two", require("applet.pane.input").focus_target(value).key)

    value:update(ui.target({
      key = "padded",
      group = "cards",
      child = ui.text({ key = "padded:text", text = "\ncontent" }),
    }))
    value:flush()
    assert.is_true(require("applet.pane.input").reveal(value, "padded"))
    assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(window()))
    value.layout.targets.padded.point = nil
    assert.is_true(require("applet.pane.input").reveal(value, "padded"))
    assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(window()))
  end)

  it("anchors grouped movement to a containing parent target", function()
    local value = pane({
      key = "nested-target-movement",
      handlers = { choose = function() end },
    })
    local host, window = surface("applet-nested-target-movement")
    value:_connect(host)
    local function card(key)
      return ui.target({
        key = key,
        group = "cards",
        child = ui.target({
          key = key .. ":action",
          action = ui.action("choose"),
          child = ui.text({ key = key .. ":text", text = key }),
        }),
      })
    end
    value:update(ui.column({
      key = "cards",
      children = { card("first"), card("second") },
    }))
    assert(value:flush())
    vim.api.nvim_win_set_cursor(window(), { 1, 0 })
    assert.are.equal("first:action",
      require("applet.pane.input").focus_target(value).key)
    assert.is_true(require("applet.pane.input").move(value, {
      group = "cards",
      direction = "next",
    }, 1))
    assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(window()))
  end)

  it("dispatches overlapping container interactions to the top layer", function()
    local chosen
    local value = pane({
      key = "layered-interaction",
      handlers = {
        choose = function(event) chosen = event.payload.value end,
      },
    })
    local host, window = surface("applet-layered-interaction", true)
    value:_connect(host)
    value:update(ui.scope({
      key = "scope",
      bindings = { {
        lhs = "<CR>",
        action = ui.action("applet.target.activate"),
      } },
      child = ui.container({
        key = "stage",
        width = 10,
        height = 2,
        child = ui.target({
          key = "lower",
          action = ui.action("choose", { value = "lower" }),
          child = ui.text({ key = "lower:text", text = "lower text" }),
        }),
        layers = {
          ui.container({
            key = "upper:container",
            position = { mode = "absolute", row = 0, col = 2, zindex = 4 },
            width = 5,
            height = 1,
            child = ui.target({
              key = "upper",
              action = ui.action("choose", { value = "upper" }),
              child = ui.text({ key = "upper:text", text = "UPPER" }),
            }),
          }),
        },
      }),
    }))
    assert.is_true(value:flush())
    assert.are.same({ "lower", "upper" }, value.layout.target_order)
    assert.are.same({ "upper", "lower" }, value.layout.hit_order)
    vim.api.nvim_win_set_cursor(window(), { 1, 3 })
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "<CR>"))
    assert.are.equal("upper", chosen)
  end)

  it("moves retained container layers without rebuilding their surface", function()
    local chosen
    local value = pane({
      key = "retained-layer-movement",
      handlers = {
        choose = function(event) chosen = event.payload.value end,
      },
    })
    local host, window = surface("applet-retained-layer-movement", true)
    value:_connect(host)
    value:update(ui.scope({
      key = "scope",
      bindings = { {
        lhs = "<CR>",
        action = ui.action("applet.target.activate"),
      } },
      child = ui.container({
        key = "stage",
        width = 12,
        height = 3,
        child = ui.target({
          key = "lower",
          action = ui.action("choose", { value = "lower" }),
          child = ui.text({ key = "lower:text", text = "lower surface" }),
        }),
        layers = {
          ui.container({
            key = "upper:container",
            position = { mode = "absolute", row = 0, col = 1, zindex = 4 },
            width = 5,
            height = 1,
            child = ui.target({
              key = "upper",
              action = ui.action("choose", { value = "upper" }),
              child = ui.text({ key = "upper:text", text = "UPPER" }),
            }),
          }),
        },
      }),
    }))
    assert.is_true(value:flush())
    local before = value:_stats()
    local changedtick = vim.api.nvim_buf_get_changedtick(host.buffer)

    assert.is_true(value:set_position("upper:container", {
      mode = "absolute",
      row = 2,
      col = 6,
      zindex = 8,
    }))
    assert.is_true(value:flush())
    assert.are.equal(changedtick,
      vim.api.nvim_buf_get_changedtick(host.buffer))
    local after = value:_stats()
    assert.are.equal(before.renders, after.renders)
    assert.are.equal(before.region_compilations, after.region_compilations)
    assert.are.equal(before.layer_compilations, after.layer_compilations)
    assert.are.equal(before.composed_cells, after.composed_cells)
    assert.are.equal(before.line_splices, after.line_splices)
    assert.are.equal(before.extmark_writes, after.extmark_writes)
    assert.are.equal(before.position_updates + 1, after.position_updates)

    vim.api.nvim_win_set_cursor(window(), { 3, 7 })
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "<CR>"))
    assert.are.equal("upper", chosen)
    vim.api.nvim_win_set_cursor(window(), { 1, 2 })
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "<CR>"))
    assert.are.equal("lower", chosen)

    vim.api.nvim_win_set_width(window(), 41)
    value:surface_changed()
    assert.is_true(value:flush())
    vim.api.nvim_win_set_cursor(window(), { 3, 7 })
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "<CR>"))
    assert.are.equal("upper", chosen)
  end)

  it("repaints retained images after placement changes", function()
    local placed = {}
    local selected = image_backend({
      replace = function(_, _, placements)
        for _, image in ipairs(placements) do
          placed[#placed + 1] = vim.deepcopy(image)
        end
      end,
    })
    local images = Applet.ImageSystem._new({ _backend = selected })
    images.status = "available"
    local source_value = {
      kind = "png_bytes",
      id = "retained-position",
      data = "png",
      revision = 1,
    }
    local identity = require("applet.image.source").identity(source_value)
    images.resources[identity] = {
      id = identity,
      data = "png",
      bytes = 3,
      width = 4,
      height = 2,
    }
    local value = pane({
      key = "retained-image-position",
      image_system = images,
    })
    local host = surface("applet-retained-image-position", true)
    value:_connect(host)
    value:update(ui.container({
      key = "stage",
      width = 10,
      height = 4,
      layers = {
        ui.container({
          key = "image:container",
          position = { mode = "absolute", row = 0, col = 0, zindex = 1 },
          width = 4,
          height = 2,
          child = ui.image({
            key = "image",
            source = source_value,
            alt = "retained position",
            width = 4,
            height = 2,
            fit = "fill",
            align = "left",
          }),
        }),
      },
    }))
    assert.is_true(value:flush())
    assert.are.equal(1, #placed)
    local before = value:_stats()
    local first_row, first_col = placed[1].screen_row, placed[1].screen_col

    assert.is_true(value:set_position("image:container", { row = 1, col = 3 }))
    assert.is_true(value:flush())
    local after = value:_stats()
    assert.are.equal(2, #placed)
    assert.are.equal(first_row + 1, placed[2].screen_row)
    assert.are.equal(first_col + 3, placed[2].screen_col)
    assert.are.equal(1, value.layout.images.image.row)
    assert.are.equal(3, value.layout.images.image.col)
    assert.are.equal(before.renders, after.renders)
    assert.are.equal(before.position_updates + 1, after.position_updates)
    images:destroy()
  end)

  it("applies a prepared image generation during retained scene movement", function()
    local Source = require("applet.image.source")
    local resources, callbacks, presented, generation = {}, {}, {}, 0
    local image_system = {
      subscribe = function(_, callback)
        callbacks[callback] = true
        return function() callbacks[callback] = nil end
      end,
      request = function(_, value)
        return resources[Source.identity(value)]
      end,
      snapshot = function()
        return {
          status = "available",
          generation = generation,
          cell_width = 1,
          cell_height = 1,
          resources = resources,
          presented = presented,
        }
      end,
      set_references = function() end,
      present = function(_, _, presentation)
        presented = vim.deepcopy(presentation.slots)
        return true
      end,
      clear = function() end,
    }
    local function source_value(revision)
      return {
        kind = "png_bytes",
        id = "moving-preview",
        data = "frame-" .. revision,
        revision = revision,
      }
    end
    local function identity(revision)
      return Source.identity(source_value(revision))
    end
    local function prepare(revision)
      local id = identity(revision)
      resources[id] = { id = id, width = 4, height = 2 }
      generation = generation + 1
      for callback in pairs(callbacks) do callback() end
    end
    local function content(revision)
      return ui.container({
        key = "stage",
        width = 10,
        height = 4,
        layers = {
          ui.container({
            key = "moving",
            position = { mode = "absolute", row = 0, col = 0 },
            width = 4,
            height = 2,
            child = ui.image({
              key = "preview",
              source = source_value(revision),
              alt = "moving preview",
              width = 4,
              height = 2,
            }),
          }),
        },
      })
    end

    local value = pane({
      key = "retained-image-generation",
      image_system = image_system,
    })
    local host = surface("applet-retained-image-generation", true)
    value:_connect(host)
    prepare(1)
    value:update(content(1))
    assert.is_true(value:flush())
    assert.are.equal(identity(1), value.layout.images.preview.source_identity)

    value:update(content(2))
    assert.is_true(value:flush())
    assert.are.equal(identity(1), value.layout.images.preview.source_identity)
    assert.is_true(value:set_position("moving", { row = 1, col = 3 }))
    prepare(2)
    assert.is_true(value:flush())
    assert.are.equal(identity(2), value.layout.images.preview.source_identity)
  end)

  it("draws clipped retained Unicode layers with their highlights", function()
    local providers = {}
    local set_provider = vim.api.nvim_set_decoration_provider
    vim.api.nvim_set_decoration_provider = function(namespace, callbacks)
      providers[namespace] = callbacks
      return set_provider(namespace, callbacks)
    end

    local value = pane({ key = "retained-layer-drawing" })
    local host, window = surface("applet-retained-layer-drawing", true)
    local rendered, render_error = pcall(function()
      value:_connect(host)
      value:update(ui.container({
        key = "stage",
        width = 10,
        height = 3,
        background = "NormalFloat",
        child = ui.text({
          key = "base",
          background = "Visual",
          runs = { {
            text = "A界B",
            groups = { { group = "String", priority = 120 } },
          } },
        }),
        layers = {
          ui.container({
            key = "overlay",
            position = { mode = "absolute", row = 0, col = 1, zindex = 0 },
            width = 4,
            height = 1,
            child = ui.text({
              key = "overlay:text",
              background = "Statement",
              runs = { {
                text = "XY",
                groups = { { group = "ErrorMsg", priority = 120 } },
              } },
            }),
          }),
        },
      }))
      assert.is_true(value:flush())
    end)
    vim.api.nvim_set_decoration_provider = set_provider
    assert(rendered, render_error)

    local callbacks = assert(providers[value.scene_namespace])
    assert.is_true(callbacks.on_win(nil, window(), host.buffer))
    assert.is_false(callbacks.on_win(nil, window() + 1000, host.buffer))
    assert.is_false(callbacks.on_win(nil, window(), host.buffer + 1000))

    local marks = {}
    local set_extmark = vim.api.nvim_buf_set_extmark
    vim.api.nvim_buf_set_extmark = function(buffer, namespace, row, col, opts)
      if namespace == value.scene_namespace and opts.ephemeral then
        marks[#marks + 1] = {
          buffer = buffer,
          row = row,
          col = col,
          options = vim.deepcopy(opts),
        }
        return #marks
      end
      return set_extmark(buffer, namespace, row, col, opts)
    end
    local drawn, draw_error = pcall(function()
      callbacks.on_line(nil, nil, host.buffer + 1000, 0)
      callbacks.on_line(nil, nil, host.buffer, -1)
      callbacks.on_line(nil, nil, host.buffer, 3)
      callbacks.on_line(nil, nil, host.buffer, 0)
      callbacks.on_line(nil, nil, host.buffer, 0)
      callbacks.on_line(nil, nil, host.buffer, 1)
      callbacks.on_line(nil, nil, host.buffer, 2)
    end)
    vim.api.nvim_buf_set_extmark = set_extmark
    assert(drawn, draw_error)

    assert.are.equal(8, #marks)
    local function mark(priority, occurrence)
      local found = 0
      for _, candidate in ipairs(marks) do
        if candidate.options.priority == priority then
          found = found + 1
          if found == (occurrence or 1) then return candidate end
        end
      end
    end
    local base = assert(mark(1002))
    assert.are.equal(0, base.options.virt_text_win_col)
    assert.are.same({
      { "A界B", "String" },
      { "      ", "Visual" },
    }, base.options.virt_text)
    local overlay = assert(mark(1003))
    assert.are.equal(1, overlay.options.virt_text_win_col)
    assert.are.same({
      { "XY", "ErrorMsg" },
      { "  ", "Statement" },
    }, overlay.options.virt_text)
    assert.are.same(base.options.virt_text, mark(1002, 2).options.virt_text)

    local changedtick = vim.api.nvim_buf_get_changedtick(host.buffer)
    local before = value:_stats()
    assert.is_true(value:set_position("overlay", { col = 3 }))
    assert.is_true(value:flush())
    local after = value:_stats()
    assert.are.equal(changedtick,
      vim.api.nvim_buf_get_changedtick(host.buffer))
    assert.are.equal(before.renders, after.renders)
    assert.are.equal(before.position_updates + 1, after.position_updates)

    value:destroy()
    assert.is_false(callbacks.on_win(nil, window(), host.buffer))
    callbacks.on_line(nil, nil, host.buffer, 0)
  end)

  it("reconciles replacement retained scenes and restores their provider", function()
    local value = pane({ key = "retained-scene-replacement" })
    local host = surface("applet-retained-scene-replacement", true)
    local function content(key, text)
      return ui.container({
        key = key,
        width = 8,
        height = 2,
        child = ui.text({ key = key .. ":text", text = text }),
        layers = {
          ui.container({
            key = "movable",
            position = { mode = "absolute", row = 1, col = 1, zindex = 1 },
            width = 2,
            height = 1,
            child = ui.text({ key = key .. ":layer", text = "xx" }),
          }),
        },
      })
    end
    value:_connect(host)
    value:update(content("first", "one"))
    assert.is_true(value:flush())
    local changedtick = vim.api.nvim_buf_get_changedtick(host.buffer)
    local first_provider = value.reconcile_state.scene_provider

    value:update(content("second", "two"))
    assert.is_true(value:flush())
    assert.are.equal("unchanged", value.reconcile_state.content_result)
    assert.are.equal(changedtick,
      vim.api.nvim_buf_get_changedtick(host.buffer))

    require("applet.pane.scene").clear(first_provider)
    value.reconcile_state.scene_provider = nil
    assert.is_true(value:set_position("movable", { col = 4 }))
    assert.is_true(value:flush())
    assert.is_table(value.reconcile_state.scene_provider)
    assert.are_not.equal(first_provider, value.reconcile_state.scene_provider)
  end)

  it("routes dialog quick keys throughout the modal surface", function()
    local chosen
    local value = pane({
      key = "dialog-quick-keys",
      handlers = {
        choose = function(event) chosen = event.payload.id end,
      },
    })
    local host, window = surface("applet-dialog-quick-keys", true)
    value:_connect(host)
    value:update(widgets.dialog({
      key = "confirm",
      title = "Confirm action",
      body = "Choose an answer.",
      actions = {
        {
          key = "yes",
          label = "Yes",
          action = ui.action("choose", { id = "yes" }),
          quick_keys = { "y" },
        },
        {
          key = "no",
          label = "No",
          action = ui.action("choose", { id = "no" }),
          quick_keys = { "n" },
        },
      },
    }))
    value:flush()

    vim.api.nvim_win_set_cursor(window(), { 2, 0 })
    assert.is_nil(require("applet.pane.input").focus_target(value))
    local quick_key = mapping(host.buffer, "n", "y")
    assert.is_function(quick_key.callback)
    quick_key.callback()
    assert.are.equal("yes", chosen)
  end)

  it("keeps editable lines under Neovim and dispatches declared text changes", function()
    local changes = {}
    local value = pane({
      key = "editable",
      buffer_mode = "editable",
      handlers = {
        changed = function(event) changes[#changes + 1] = event.pane:text() end,
        submit = function(event) changes[#changes + 1] = "submit:" .. event.pane:text() end,
      },
    })
    local host, window = surface("applet-editable")
    value:_connect(host)
    assert.is_true(value:replace_text("draft", nil, 0))
    value:update({
      root = ui.scope({
        key = "input:scope",
        bindings = {
          {
            mode = "i",
            lhs = "<C-s>",
            action = ui.action("submit"),
          },
        },
        child = ui.virtual({
          key = "prompt",
          placement = "below-end",
          lines = { { { text = "Ask", style = "Comment" } } },
        }),
      }),
      edit = { on_change = ui.action("changed") },
    })
    value:flush()
    assert.is_true(vim.bo[host.buffer].modifiable)
    assert.is_false(vim.bo[host.buffer].readonly)
    assert.is_true(value:replace_text("one\ntwo", { 2, 1 }, 1))
    assert.is_false(value:replace_text("ignored", nil, 1))
    assert.are.equal("one\ntwo", value:text())
    assert.are.same({ 2, 1 }, vim.api.nvim_win_get_cursor(window()))
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = host.buffer })
    assert.are.same({}, changes)
    vim.api.nvim_buf_set_text(host.buffer, 1, 3, 1, 3, { "!" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = host.buffer })
    assert.are.same({ "one\ntwo!" }, changes)
    assert.is_truthy(mapping(host.buffer, "i", "<C-S>"))
    assert.is_true(require("applet.pane.input").dispatch(value, "i", "<C-s>"))
    assert.are.same({ "one\ntwo!", "submit:one\ntwo!" }, changes)
    local virtuals = vim.api.nvim_buf_get_extmarks(
      host.buffer, value.virtual_namespace, 0, -1, { details = true })
    assert.are.equal("Ask", virtuals[1][4].virt_lines[1][1][1])
  end)

  it("retains the committed Layout on errors and restores connection state", function()
    local silent = pane({ key = "silent-errors" })
    local _, silent_error = silent:_report("direct", "silent failure")
    assert.are.equal("direct", silent_error.phase)
    assert.is_false(silent:_flush_requested())
    local errors = {}
    local value = pane({
      key = "errors",
      render = function(state)
        if state.throw then error("render exploded") end
        if state.semantic_error then
          error({ kind = "render", message = "semantic Applet failure" })
        end
        if state.invalid then return ui.text({ key = "", text = "bad" }) end
        local node = ui.text({ key = "ok", text = state.text })
        if state.source then
          node = ui.source({
            key = "source", language = "lua", child = node,
          })
        end
        return node
      end,
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host = surface("applet-errors")
    local original_modifiable = vim.bo[host.buffer].modifiable
    value:_connect(host)
    value:set_state({ text = "good" })
    value:flush()
    local committed = value.layout
    value:set_state({ throw = true })
    value:flush()
    assert.are.equal(committed, value.layout)
    assert.are.equal("render", errors[#errors].phase)
    assert.matches("render exploded", errors[#errors].message)
    value:set_state({ semantic_error = true })
    value:flush()
    assert.are.equal(committed, value.layout)
    assert.are.equal("semantic Applet failure", errors[#errors].message)
    value:set_state({ invalid = true })
    value:flush()
    assert.are.equal(committed, value.layout)
    assert.are.equal("compile", errors[#errors].phase)
    assert.are.same({ "good" }, lines(host.buffer))
    local _, direct_error = value:_report("test", "direct failure")
    assert.are.equal("test", direct_error.phase)

    local source_adapter = require("applet.pane.source")
    local original_apply = source_adapter.apply
    source_adapter.apply = function() error("commit exploded") end
    value:set_state({ text = "commit", source = true })
    value:flush()
    source_adapter.apply = original_apply
    assert.are.equal("commit", errors[#errors].phase)
    assert.is_true(value.reconcile_state.unknown)

    value:_disconnect()
    assert.is_false(value:flush())
    assert.are.equal(original_modifiable, vim.bo[host.buffer].modifiable)
    assert.is_nil(value.surface)
    value:_connect(host)
    value:set_state({ text = "again" })
    value:flush()
    assert.are.same({ "again" }, lines(host.buffer))
    local buffer = host.buffer
    value:destroy()
    assert.is_false(vim.api.nvim_buf_is_valid(buffer))
  end)

  it("coordinates safe commits through an explicit shared domain", function()
    local natural = Domain.new()
    assert.is_true(natural:is_safe())
    local original_get_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "no" } end
    assert.is_false(natural:is_safe())
    vim.api.nvim_get_mode = original_get_mode
    natural:destroy()

    local critical = true
    local domain = Domain.new({ critical = function() return critical end })
    domain.is_safe = function() return not critical end
    domain:_track_key('"', "i")
    assert.is_false(domain.register_pending)
    domain:_track_key('"', "n")
    assert.is_true(domain.register_pending)
    domain.register_pending = false
    local one = pane({ key = "domain-one" })
    local two = pane({ key = "domain-two" })
    local first = surface("applet-domain-one")
    local second_buffer = vim.api.nvim_create_buf(false, true)
    local second = {
      buffer = second_buffer,
      window = function() return nil end,
      owns_buffer = true,
      domain = domain,
    }
    first.domain = domain
    one:_connect(first)
    two:_connect(second)
    one:update(ui.text({ key = "one", text = "one" }))
    two:update(ui.text({ key = "two", text = "two" }))
    assert.is_false(domain:flush())
    assert.is_nil(one.layout)
    assert.is_nil(two.layout)
    critical = false
    assert.is_true(domain:flush())
    assert.are.same({ "one" }, lines(first.buffer))
    assert.are.same({ "two" }, lines(second.buffer))
    domain.register_pending = true
    domain:_wait_for_safe()
    assert.is_truthy(domain.safe_autocmd)
    vim.api.nvim_exec_autocmds("SafeState", {})
    assert.is_false(domain.register_pending)
    domain:request(one)
    assert(vim.wait(1000, function() return not domain.scheduled end))
    domain:remove(one)
    local ok = pcall(domain.request, domain, one)
    assert.is_false(ok)
    domain:add(one)
    domain:destroy()
    domain:destroy()
    assert.is_false(domain:flush())
    local add_ok = pcall(domain.add, domain, one)
    assert.is_false(add_ok)
  end)

  it("applies source annotations through Applet-owned syntax regions", function()
    local adapter = require("applet.pane.source")
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "local value = 1",
      "return value",
      "plain text",
    })
    local ranges = {
      { key = "lua", first = 0, last = 2, language = "lua" },
      { key = "path", first = 2, last = 3, path = "example.lua" },
      { key = "invalid", first = -1, last = 99, language = "lua" },
    }
    assert.is_true(adapter.apply(buffer, ranges,
      vim.api.nvim_buf_get_lines(buffer, 0, -1, false)))
    assert.are.equal(2, vim.b[buffer].applet_source_regions)
    assert.is_true(#vim.b[buffer].applet_source_filetypes >= 1)
    assert.is_true(adapter.apply(buffer, ranges,
      vim.api.nvim_buf_get_lines(buffer, 0, -1, false)))
    adapter.clear(buffer)
    assert.are.equal(0, vim.b[buffer].applet_source_regions)
    assert.is_false(adapter.apply(buffer, {
      { first = 0, last = 1, path = "" },
    }, { "plain" }))
    assert.is_false(adapter.apply(buffer, { {
      first = 0,
      last = 1,
      language = "lua",
      rectangles = { invalid = true },
    } }, { "plain" }))
    assert.is_false(adapter.apply(buffer, { {
      first = 0,
      last = 1,
      language = "lua",
      rectangles = { { row = 0, col = 0, width = 0, height = 1 } },
    } }, { "plain" }))

    local layered = { "xx local value yy" }
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, layered)
    assert.is_true(adapter.apply(buffer, { {
      key = "layered",
      first = 0,
      last = 1,
      language = "lua",
      linewise = false,
      rectangles = { { row = 0, col = 3, width = 11, height = 1 } },
    } }, layered))
    assert.are.equal(1, vim.b[buffer].applet_source_regions)
    local inside, outside
    vim.api.nvim_buf_call(buffer, function()
      vim.cmd("syntax sync fromstart")
      local function names(column)
        return vim.tbl_map(function(id)
          return vim.fn.synIDattr(id, "name")
        end, vim.fn.synstack(1, column))
      end
      inside, outside = names(4), names(1)
    end)
    assert.is_true(vim.tbl_contains(inside, "luaStatement"))
    assert.is_false(vim.tbl_contains(outside, "luaStatement"))
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  it("prepares and presents optional images through an ImageSystem", function()
    local function uint32(value)
      return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256)
    end
    local png = "\137PNG\r\n\26\n\0\0\0\rIHDR"
      .. uint32(2) .. uint32(2)
    local batches, redraws = {}, 0
    local selected = image_backend({
      replace = function(_, owner, placements)
        batches[#batches + 1] = {
          owner = owner,
          placements = vim.deepcopy(placements),
        }
      end,
      redraw = function()
        redraws = redraws + 1
        return true
      end,
    })
    local images = Applet.ImageSystem._new({ _backend = selected })
    local errors = {}
    local value = pane({
      key = "images",
      image_system = images,
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host = surface("applet-images", true)
    value:_connect(host)
    value:update(ui.image({
      key = "image",
      source = {
        kind = "png_bytes",
        id = "test",
        data = png,
        revision = 1,
      },
      alt = "tiny",
      width = 4,
      height = 2,
    }))
    value:flush()
    assert(vim.wait(1000, function() return images.status == "available" end))
    value:flush()
    assert(vim.wait(1000, function()
      return next(images:snapshot().resources) ~= nil
    end))
    assert.is_true(value:flush())
    assert.are.equal(0, #errors, vim.inspect(errors))
    local layout_image = assert(value.layout.images.image)
    local first = assert(batches[#batches].placements[1])
    assert.are.equal(png, first.resource.data)
    local image_line = vim.api.nvim_buf_get_lines(
      host.buffer, layout_image.row, layout_image.row + 1, false)[1]
    local position = vim.fn.screenpos(host.window(), layout_image.row + 1,
      require("applet.util").byte_col(image_line, layout_image.col) + 1)
    assert.are.equal(position.row, first.screen_row)
    assert.are.equal(position.col, first.screen_col)
    assert.are.equal(layout_image.source_identity,
      images:snapshot(value).presented.image)

    vim.api.nvim__redraw({
      win = host.window(),
      range = { layout_image.row, layout_image.row + layout_image.height },
      valid = false,
      flush = true,
    })
    assert(vim.wait(1000, function() return redraws > 0 end))

    local overlap_buffer = vim.api.nvim_create_buf(false, true)
    local overlap_window = vim.api.nvim_open_win(overlap_buffer, true, {
      relative = "editor",
      row = position.row - 1,
      col = position.col - 1,
      width = layout_image.width,
      height = 1,
      style = "minimal",
      border = { "", "", "", "", "", "", "", "" },
      zindex = 100,
    })
    value.force_images = true
    assert.is_true(value:flush())
    local clipped = assert(batches[#batches].placements[1])
    assert.are.same({
      row = 1,
      col = 0,
      width = layout_image.width,
      height = 1,
    }, clipped.viewport)

    vim.api.nvim_win_set_config(overlap_window, { hide = true })
    value.force_images = true
    assert.is_true(value:flush())
    assert.are.same({
      row = 0,
      col = 0,
      width = layout_image.width,
      height = layout_image.height,
    }, batches[#batches].placements[1].viewport)
    vim.api.nvim_win_close(overlap_window, true)
    vim.api.nvim_buf_delete(overlap_buffer, { force = true })

    local original_pumvisible, original_pum_getpos =
      vim.fn.pumvisible, vim.fn.pum_getpos
    vim.fn.pumvisible = function() return 1 end
    vim.fn.pum_getpos = function()
      return {
        col = first.screen_col - 1,
        row = first.screen_row - 1,
        width = first.width,
        height = first.height,
      }
    end
    value.force_images = true
    assert.is_true(value:flush())
    assert.are.equal(0, #batches[#batches].placements)
    vim.fn.pumvisible, vim.fn.pum_getpos =
      original_pumvisible, original_pum_getpos

    value:_disconnect()
    assert.are.equal(0, #batches[#batches].placements)
    images:destroy()
    assert.are.equal(0, #errors)
  end)

  it("clips floating image placements to the editor screen", function()
    local placed = {}
    local selected = image_backend({
      replace = function(_, _, placements)
        placed = vim.deepcopy(placements)
      end,
    })
    local images = Applet.ImageSystem._new({ _backend = selected })
    images.status = "available"
    local source_value = {
      kind = "png_bytes", id = "screen-clip", data = "png", revision = 1,
    }
    local identity = require("applet.image.source").identity(source_value)
    images.resources[identity] = {
      id = identity,
      data = "png",
      bytes = 3,
      width = 60,
      height = 20,
    }
    local value = pane({
      key = "screen-clipped-image",
      image_system = images,
    })
    local host, window = surface("applet-screen-clipped-image", true)
    vim.api.nvim_win_set_config(window(), {
      relative = "editor",
      row = 2,
      col = -3,
      fixed = true,
    })
    value:_connect(host)
    value:update(ui.image({
      key = "image",
      source = source_value,
      alt = "clipped",
      width = 8,
      height = 2,
      fit = "fill",
      align = "left",
    }))
    assert.is_true(value:flush())
    assert.are.equal(1, #placed)
    assert.are.equal(1,
      placed[1].screen_col + placed[1].viewport.col)
    assert.is_true(placed[1].viewport.col > 0)
    assert.are.equal(8 - placed[1].viewport.col, placed[1].viewport.width)

    placed = {}
    vim.api.nvim_win_set_config(window(), {
      relative = "editor",
      row = 2,
      col = -20,
    })
    value:surface_changed()
    assert.is_true(value:flush())
    assert.are.same({}, placed)
    assert.are.same({}, placed)
    images:destroy()
  end)

  it("places only image cells exposed by Applet container layers", function()
    local placed = {}
    local selected = image_backend({
      replace = function(_, _, placements)
        placed = vim.tbl_map(function(image)
          return vim.deepcopy(image.viewport)
        end, placements)
      end,
      redraw = function() return true end,
    })
    local images = Applet.ImageSystem._new({ _backend = selected })
    images.status = "available"
    local source_value = {
      kind = "png_bytes",
      id = "container-clipped",
      data = "png",
      revision = 1,
    }
    local identity = require("applet.image.source").identity(source_value)
    images.resources[identity] = {
      id = identity,
      data = "png",
      bytes = 3,
      width = 8,
      height = 4,
    }
    local value = pane({
      key = "container-clipped-image",
      image_system = images,
    })
    local host = surface("applet-container-clipped-image", false)
    value:_connect(host)
    value:update(ui.container({
      key = "stage",
      width = 8,
      height = 4,
      child = ui.image({
        key = "image",
        source = source_value,
        alt = "container clipped",
        width = 8,
        height = 4,
        fit = "fill",
        align = "left",
      }),
      layers = {
        ui.container({
          key = "occluder",
          position = { mode = "absolute", row = 1, col = 3, zindex = 1 },
          width = 3,
          height = 2,
          background = "NormalFloat",
        }),
      },
    }))
    assert.is_true(value:flush())
    assert.are.same({
      { row = 0, col = 0, width = 8, height = 1 },
      { row = 1, col = 0, width = 3, height = 2 },
      { row = 1, col = 6, width = 2, height = 2 },
      { row = 3, col = 0, width = 8, height = 1 },
    }, placed)

    local layout_image = value.reconcile_state.layout.images.image
    layout_image.visible = {
      { row = 0, col = 0, width = 8, height = 3 },
      { row = 2, col = 0, width = 8, height = 2 },
    }
    local reconcile = require("applet.pane.reconcile")
    reconcile.refresh_images({
      surface = host,
      state = value.reconcile_state,
      image_system = images,
      image_owner = value,
    })
    assert.are.same({ { first = 0, last = 4 } },
      value.reconcile_state.image_redraw_provider.ranges)
    images:destroy()
  end)

  it("keeps image fragments canonical when overlapping floats reopen", function()
    local placed, active, redraws = {}, {}, 0
    local selected = image_backend({
      replace = function(_, _, placements)
        placed = vim.tbl_map(function(image)
          return vim.deepcopy(image.viewport)
        end, placements)
        active = vim.deepcopy(placed)
      end,
      redraw = function()
        redraws = redraws + 1
        return true
      end,
    })
    local images = Applet.ImageSystem._new({ _backend = selected })
    images.status = "available"
    local source_value = {
      kind = "png_bytes", id = "canonical-fragments",
      data = "png", revision = 1,
    }
    local identity = require("applet.image.source").identity(source_value)
    images.resources[identity] = {
      id = identity,
      data = "png",
      bytes = 3,
      width = 24,
      height = 8,
    }
    local value = pane({
      key = "canonical-image-fragments",
      image_system = images,
    })
    local host, window = surface("applet-canonical-image-fragments", true)
    value:_connect(host)
    value:update(ui.image({
      key = "image",
      source = source_value,
      alt = "canonical fragments",
      width = 24,
      height = 8,
      fit = "fill",
      align = "left",
    }))
    assert.is_true(value:flush())
    local image = value.layout.images.image
    local line = vim.api.nvim_buf_get_lines(
      host.buffer, image.row, image.row + 1, false)[1]
    local position = vim.fn.screenpos(window(), image.row + 1,
      require("applet.util").byte_col(line, image.col) + 1)

    local function blocker(_, row, col, width, height, zindex)
      local buffer = vim.api.nvim_create_buf(false, true)
      local window_id = vim.api.nvim_open_win(buffer, false, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        zindex = zindex,
      })
      local result = { buffer = buffer, window = window_id }
      function result:destroy()
        if vim.api.nvim_win_is_valid(self.window) then
          vim.api.nvim_win_close(self.window, true)
        end
        if vim.api.nvim_buf_is_valid(self.buffer) then
          vim.api.nvim_buf_delete(self.buffer, { force = true })
        end
      end
      floating_windows[#floating_windows + 1] = result
      return result
    end
    local first_config = {
      row = position.row,
      col = position.col + 3,
      width = 12,
      height = 4,
      zindex = 70,
    }
    local first = blocker("applet-canonical-first",
      first_config.row, first_config.col,
      first_config.width, first_config.height, first_config.zindex)
    blocker("applet-canonical-second",
      position.row + 3, position.col + 9, 12, 4, 90)

    placed = {}
    value.force_images = true
    assert.is_true(value:flush())
    local before = vim.deepcopy(placed)
    assert.is_true(#before > 1)

    first:destroy()
    blocker("applet-canonical-first-reopened",
      first_config.row, first_config.col,
      first_config.width, first_config.height, first_config.zindex)
    placed = {}
    value.force_images = true
    assert.is_true(value:flush())
    assert.are.same({}, placed)
    assert.is_true(redraws > 0)
    assert.are.same(before, active)
    images:destroy()
  end)

  it("places the visible horizontal slice of an image", function()
    local reconcile = require("applet.pane.reconcile")
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "0123456789          abcdefghij",
    })
    local window = vim.api.nvim_open_win(buffer, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 10,
      height = 1,
      style = "minimal",
    })
    vim.wo[window].wrap = false
    vim.api.nvim_win_call(window, function()
      vim.api.nvim_win_set_cursor(window, { 1, 10 })
      vim.fn.winrestview({ topline = 1, leftcol = 10, lnum = 1, col = 10 })
    end)
    local state = {
      layout = {
        images = {
          image = {
            row = 0,
            col = 10,
            width = 10,
            height = 1,
            source_identity = "horizontal",
          },
        },
      },
    }
    local placed, signature = {}, nil
    local image_system = {
      snapshot = function()
        return { generation = 0, presented = {} }
      end,
      present = function(_, _, presentation)
        local next_signature = vim.inspect(presentation.placements)
        if next_signature == signature then return false end
        signature = next_signature
        placed = vim.deepcopy(presentation.placements)
        return true
      end,
    }
    local function refresh()
      return reconcile.refresh_images({
        surface = {
          buffer = buffer,
          window = function() return window end,
        },
        state = state,
        image_system = image_system,
        image_owner = state,
      })
    end
    local function scroll(leftcol)
      vim.api.nvim_win_call(window, function()
        local col = math.min(20, math.max(10, leftcol))
        vim.api.nvim_win_set_cursor(window, { 1, col })
        vim.fn.winrestview({
          topline = 1,
          leftcol = leftcol,
          lnum = 1,
          col = col,
        })
      end)
    end
    assert.are.equal(1, refresh())
    assert.are.same({ row = 0, col = 0, width = 10, height = 1 },
      placed[1].viewport)

    scroll(15)
    assert.are.equal(1, refresh())
    assert.are.same({ row = 0, col = 5, width = 5, height = 1 },
      placed[1].viewport)

    scroll(20)
    assert.are.equal(1, refresh())
    assert.are.same({}, placed)

    scroll(10)
    assert.are.equal(1, refresh())
    assert.are.same({ row = 0, col = 0, width = 10, height = 1 },
      placed[1].viewport)
    vim.api.nvim_win_close(window, true)
    assert.are.equal(1, refresh())
    assert.are.same({}, placed)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  it("submits fragmented images as one complete presentation", function()
    local reconcile = require("applet.pane.reconcile")
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "    ", "    ",
    })
    local window = vim.api.nvim_open_win(buffer, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 4,
      height = 2,
      style = "minimal",
    })
    local state = {
      layout = {
        images = {
          image = {
            row = 0,
            col = 0,
            width = 4,
            height = 2,
            cell_width = 1,
            cell_height = 1,
            fit = "fill",
            source_identity = "fragmented",
            visible = {
              { row = 0, col = 0, width = 4, height = 1 },
              { row = 1, col = 0, width = 2, height = 1 },
            },
          },
        },
      },
    }
    local presentations = {}
    local owner = {}
    local changes = reconcile.refresh_images({
      surface = {
        buffer = buffer,
        window = function() return window end,
      },
      state = state,
      image_system = {
        snapshot = function()
          return { generation = 0, presented = {} }
        end,
        present = function(_, received_owner, presentation)
          assert.are.equal(owner, received_owner)
          presentations[#presentations + 1] = vim.deepcopy(presentation)
          return true
        end,
      },
      image_owner = owner,
    })
    assert.are.equal(1, changes)
    assert.are.equal(1, #presentations)
    assert.are.same({ image = "fragmented" }, presentations[1].slots)
    assert.are.equal(2, #presentations[1].placements)
    for _, placement in ipairs(presentations[1].placements) do
      assert.are.equal("image", placement.key)
      assert.is_nil(placement.resource)
    end

    vim.api.nvim_win_close(window, true)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  it("resolves a complete image batch before mutating the backend", function()
    local reconcile = require("applet.pane.reconcile")
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      "    ", "    ", "    ",
    })
    local window = vim.api.nvim_open_win(buffer, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 4,
      height = 3,
      style = "minimal",
    })
    local images = {}
    for _, key in ipairs({ "first", "second", "third" }) do
      images[key] = {
        row = 0,
        col = 0,
        width = 2,
        height = 1,
        cell_width = 1,
        cell_height = 1,
        fit = "fill",
        source_identity = key,
      }
    end
    local iteration = {}
    for key in pairs(images) do iteration[#iteration + 1] = key end
    images[assert(iteration[#iteration])].row = 1

    local presentations = 0
    local screenpos = vim.fn.screenpos
    vim.fn.screenpos = function(target, row, col)
      if row == 2 then error("image resolution failed") end
      return screenpos(target, row, col)
    end
    local refreshed, refresh_error = pcall(reconcile.refresh_images, {
      surface = {
        buffer = buffer,
        window = function() return window end,
      },
      state = {
        layout = { images = images },
      },
      image_system = {
        present = function()
          presentations = presentations + 1
          return true
        end,
      },
      image_owner = {},
    })
    vim.fn.screenpos = screenpos
    vim.api.nvim_win_close(window, true)
    vim.api.nvim_buf_delete(buffer, { force = true })

    assert.is_false(refreshed)
    assert.matches("image resolution failed", tostring(refresh_error))
    assert.are.equal(0, presentations)
  end)

  it("rejects image fragments whose screen rows are discontinuous", function()
    local reconcile = require("applet.pane.reconcile")
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false,
      { "xx", "xx", "xx" })
    local window = vim.api.nvim_open_win(buffer, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 4,
      height = 3,
      style = "minimal",
    })
    local placements = 0
    local state = {
      layout = {
        images = {
          image = {
            row = 0,
            col = 0,
            width = 2,
            height = 3,
            source_identity = "discontinuous",
          },
        },
      },
    }
    local presentations = 0
    local image_system = {
      snapshot = function()
        return { generation = 0, presented = {} }
      end,
      present = function(_, _, presentation)
        presentations = presentations + 1
        placements = #presentation.placements
        return true
      end,
    }
    local screenpos = vim.fn.screenpos
    vim.fn.screenpos = function(_, row)
      return { row = row == 1 and 10 or row + 10, col = 5 }
    end
    local refreshed, refresh_error = pcall(reconcile.refresh_images, {
      surface = {
        buffer = buffer,
        window = function() return window end,
      },
      state = state,
      image_system = image_system,
      image_owner = state,
      image_namespace = vim.api.nvim_create_namespace(
        "applet-discontinuous-image"),
    })
    vim.fn.screenpos = screenpos
    vim.api.nvim_win_close(window, true)
    vim.api.nvim_buf_delete(buffer, { force = true })
    assert(refreshed, refresh_error)
    assert.are.equal(1, presentations)
    assert.are.equal(0, placements)
  end)

  it("contains image request failures and reports each rejected source once", function()
    local mode = "throw"
    local references = {}
    local image_system = {
      subscribe = function() return function() end end,
      snapshot = function()
        return {
          status = "unavailable",
          generation = 0,
          resources = {},
          presented = {},
        }
      end,
      set_references = function(_, _, value)
        references = vim.deepcopy(value)
      end,
      present = function() return false end,
      clear = function() end,
      request = function()
        if mode == "throw" then error("request exploded") end
        return nil, "image rejected"
      end,
    }
    local errors = {}
    local value = pane({
      key = "image-errors",
      image_system = image_system,
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host = surface("applet-image-errors", true)
    value:_connect(host)
    local image = ui.image({
      key = "image",
      source = { kind = "png_bytes", id = "test", data = "bad", revision = 1 },
      alt = "bad",
      width = 2,
      height = 1,
    })
    value:_prepare_images(image)
    mode = "reject"
    value:_prepare_images(image)
    value:_prepare_images(image)
    assert.are.equal(2, #errors)
    assert.are.equal("image", errors[1].phase)
    assert.matches("request exploded", errors[1].message)
    assert.matches("image rejected", errors[2].message)

    local replacement = vim.deepcopy(image)
    replacement.source.revision = 2
    value:_prepare_images(replacement)
    assert.are.equal(3, #errors)
    assert.are.equal(1, vim.tbl_count(value.image_errors))
    assert.is_truthy(value.image_errors[
      require("applet.image.source").identity(replacement.source)])

    value:update(image)
    assert.is_true(value:flush())
    assert.is_truthy(next(references))
    value:update({ type = "unknown", key = "invalid" })
    assert.is_nil(value:flush())
    assert.is_nil(next(references))
  end)

  it("presents scrolling images immediately despite a content cadence", function()
    local source_value = {
      kind = "png_bytes", id = "scroll-image", data = "png", revision = 1,
    }
    local identity = require("applet.image.source").identity(source_value)
    local resource = {
      id = identity, data = "png", bytes = 3, width = 4, height = 12,
    }
    local placed, presented = {}, {}
    local presentation_signature
    local image_system = {
      subscribe = function() return function() end end,
      snapshot = function()
        return {
          status = "available",
          generation = 1,
          resources = {
            [identity] = {
              id = identity, width = resource.width, height = resource.height,
            },
          },
          presented = presented,
        }
      end,
      request = function() return resource end,
      set_references = function() end,
      present = function(_, _, presentation)
        local signature = vim.inspect(presentation)
        if signature == presentation_signature then return false end
        presentation_signature = signature
        presented = vim.deepcopy(presentation.slots)
        for _, image in ipairs(presentation.placements) do
          placed[#placed + 1] = vim.deepcopy(image)
        end
        return true
      end,
      clear = function() end,
    }
    local value = pane({
      key = "scroll-image",
      frame_interval_ms = 10000,
      image_system = image_system,
    })
    local host, window = surface("applet-scroll-image", true)
    value:_connect(host)
    local function content()
      return ui.image({
        key = "image",
        source = source_value,
        alt = "scrolling image",
        width = 4,
        height = 12,
        fit = "fill",
        align = "left",
      })
    end
    value:update(content())
    assert.is_true(value:flush())
    assert.are.equal(1, #placed)
    assert.are.same({ row = 0, col = 0, width = 4, height = 8 },
      placed[1].viewport)

    value:update(content())
    assert.is_false(value:is_settled())
    vim.api.nvim_win_call(window(), function()
      vim.api.nvim_win_set_cursor(0, { 12, 0 })
      vim.cmd("normal! zb")
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", {})
    assert.is_true(value.domain:flush())
    assert.is_true(value:is_settled())
    assert.are.equal(2, #placed)
    assert.are.same({ row = 4, col = 0, width = 4, height = 8 },
      placed[2].viewport)
  end)

  it("replaces changed images and retains stable presentations", function()
    local resources, presented = {}, {}
    local placements, requests, presentations = 0, 0, 0
    local active, signature = {}, nil
    local image_generation = 0
    local image_system = {
      subscribe = function() return function() end end,
      request = function(_, value)
        requests = requests + 1
        local id = require("applet.image.source").identity(value)
        image_generation = value.revision
        resources[id] = {
          id = id,
          content_id = value.revision,
          width = 1,
          height = 1,
        }
        return resources[id]
      end,
      snapshot = function()
        return {
          status = "available",
          generation = image_generation,
          resources = resources,
          presented = presented,
        }
      end,
      set_references = function() end,
      present = function(_, _, presentation)
        presentations = presentations + 1
        local next_signature = vim.inspect(presentation)
        if next_signature == signature then return false end
        signature = next_signature
        placements = placements + 1
        active = vim.deepcopy(presentation.placements)
        presented = vim.deepcopy(presentation.slots)
        return true
      end,
      clear = function() end,
    }
    local errors = {}
    local value = pane({
      key = "image-diffs",
      image_system = image_system,
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host, image_window = surface("applet-image-diffs", true)
    value:_connect(host)
    local function content(text, revision)
      return ui.column({ key = "content", children = {
        ui.text({ key = "text", text = text }),
        ui.image({
          key = "image",
          source = { kind = "png_bytes", id = "test", data = "png", revision = revision },
          alt = "image",
          width = 2,
          height = 1,
        }),
      } })
    end
    value:update(content("one", 1))
    value:flush()
    assert.is_truthy(value.layout.images.image)
    assert.are.equal(1, value.layout.image_generation)
    assert.are.equal(1, placements)
    value:update(content("one", 2))
    value:flush()
    assert.are.equal(2, value.layout.image_generation)
    assert.are.equal(2, placements)
    local stable_requests = requests
    local stable_presentations = presentations
    value:update(content("two", 2))
    value:flush()
    assert.are.equal(0, #errors, vim.inspect(errors))
    assert.are.equal(2, placements)
    assert.are.same({
      requests = stable_requests,
      presentations = stable_presentations,
    }, {
      requests = requests,
      presentations = presentations,
    })

    vim.api.nvim_win_set_height(image_window(), 1)
    value:flush()
    assert.are.same({}, active)
    vim.api.nvim_win_set_height(image_window(), 8)
    value:flush()
    assert.are.equal(4, placements)
    value:update(ui.text({ key = "text-only", text = "done" }))
    value:flush()
    assert.are.same({}, active)
  end)

  it("keeps the presented image while a desired revision prepares", function()
    local source_module = require("applet.image.source")
    local resources, callbacks, presented = {}, {}, {}
    local references, batches = {}, {}
    local presentation_signature
    local generation = 1
    local rejected = {}
    local image_system = {
      subscribe = function(_, callback)
        callbacks[callback] = true
        return function() callbacks[callback] = nil end
      end,
      request = function(_, source)
        local identity = source_module.identity(source)
        if rejected[identity] then return nil, "candidate rejected" end
        return resources[identity]
      end,
      snapshot = function()
        return {
          status = "available",
          generation = generation,
          cell_width = 1,
          cell_height = 1,
          resources = resources,
          presented = presented,
        }
      end,
      set_references = function(_, _, value)
        references = vim.deepcopy(value)
      end,
      present = function(_, _, presentation)
        local signature = vim.inspect(presentation)
        if signature == presentation_signature then return false end
        presentation_signature = signature
        batches[#batches + 1] = vim.deepcopy(presentation)
        presented = vim.deepcopy(presentation.slots)
        return true
      end,
      clear = function()
        presented = {}
        return true
      end,
    }
    local errors = {}
    local value = pane({
      key = "staged-image",
      image_system = image_system,
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host = surface("applet-staged-image", true)
    value:_connect(host)
    local function source(revision)
      return {
        kind = "png_bytes",
        id = "preview",
        data = "frame-" .. revision,
        revision = revision,
      }
    end
    local function identity(revision)
      return source_module.identity(source(revision))
    end
    local function content(text, revision)
      return ui.column({ key = "content", children = {
        ui.text({ key = "status", text = text }),
        ui.image({
          key = "preview:image",
          source = source(revision),
          alt = "preview",
          width = 4,
          height = 2,
        }),
      } })
    end
    local function prepare(revision)
      local id = identity(revision)
      resources[id] = { id = id, width = 4, height = 2 }
      generation = generation + 1
      for callback in pairs(callbacks) do callback() end
    end

    prepare(1)
    value:update(content("one", 1))
    assert(value:flush())
    assert.are.equal(identity(1),
      value.layout.images["preview:image"].source_identity)
    assert.are.equal(1, #batches)

    value:update(content("two", 2))
    assert(value:flush())
    assert.are.equal("two", lines(host.buffer)[1])
    assert.are.equal(identity(1),
      value.layout.images["preview:image"].source_identity)
    assert.are.equal(1, #batches)
    assert.is_nil(references[identity(1)])
    assert.is_true(references[identity(2)])

    value:update(content("three", 3))
    assert(value:flush())
    assert.are.equal(identity(1),
      value.layout.images["preview:image"].source_identity)
    assert.is_nil(references[identity(2)])
    assert.is_true(references[identity(3)])

    prepare(3)
    assert(value:flush())
    assert.are.equal(identity(3),
      value.layout.images["preview:image"].source_identity)
    assert.are.equal(2, #batches)
    assert.are.equal(identity(3),
      presented["preview:image"])

    rejected[identity(4)] = true
    value:update(content("four", 4))
    assert(value:flush())
    assert.are.equal("four", lines(host.buffer)[1])
    assert.are.equal(identity(3),
      value.layout.images["preview:image"].source_identity)
    assert.are.equal(1, #errors)
    assert.matches("candidate rejected", errors[1].message)

    value:update(ui.text({ key = "done", text = "done" }))
    assert(value:flush())
    assert.is_nil(value.layout.images["preview:image"])
    assert.are.equal(0, #batches[#batches].placements)
    assert.is_nil(next(references))
  end)

  it("honors nested and modal scope precedence", function()
    local actions = {}
    local value = pane({
      key = "scope-precedence",
      theme = { groups = {} },
      handlers = {
        root = function() actions[#actions + 1] = "root" end,
        inner = function() actions[#actions + 1] = "inner" end,
      },
    })
    local host = surface("applet-scope-precedence")
    value:_connect(host)
    value:update(ui.scope({
      key = "root",
      modal = true,
      bindings = { { lhs = "x", action = ui.action("root") } },
      child = ui.scope({
        key = "inner",
        bindings = { { lhs = "x", action = ui.action("inner") } },
        child = ui.text({ key = "text", text = "inside" }),
      }),
    }))
    value:flush()
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "x"))
    assert.are.same({ "root" }, actions)
    value:update(ui.scope({
      key = "outer",
      bindings = { { lhs = "o", action = ui.action("root") } },
      child = ui.scope({
        key = "inner-two",
        bindings = { { lhs = "o", action = ui.action("inner") } },
        child = ui.text({ key = "text-two", text = "inside" }),
      }),
    }))
    value:flush()
    assert.is_true(require("applet.pane.input").dispatch(value, "n", "o"))
    assert.are.same({ "root", "inner" }, actions)
    local installed = mapping(host.buffer, "n", "o")
    assert.is_function(installed.callback)
    installed.callback()
    assert.are.same({ "root", "inner", "inner" }, actions)
  end)

  it("ignores interaction when a Surface window displays another buffer", function()
    local invoked = false
    local value = pane({
      key = "surface-buffer-boundary",
      handlers = {
        invoke = function() invoked = true end,
      },
    })
    local host, window = surface("surface-buffer-boundary")
    value:_connect(host)
    value:update(ui.scope({
      key = "scope",
      bindings = { { lhs = "x", action = ui.action("invoke") } },
      child = ui.target({
        key = "target",
        child = ui.text({ key = "text", text = "content" }),
      }),
    }))
    value:flush()
    local replacement = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(window(), replacement)
    local input = require("applet.pane.input")
    assert.is_false(input.dispatch(value, "n", "x"))
    assert.is_false(input.apply_target_intent(value, { select = "target" }))
    assert.is_false(invoked)
    vim.api.nvim_win_set_buf(window(), host.buffer)
    vim.api.nvim_buf_delete(replacement, { force = true })
  end)

  it("rejects unknown actions and contains handler failures", function()
    local errors = {}
    local value = pane({
      key = "action-errors",
      handlers = {
        explode = function() error("handler exploded") end,
      },
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host = surface("applet-action-errors")
    value:_connect(host)
    value:update(ui.scope({
      key = "scope",
      bindings = {
        { lhs = "x", action = ui.action("explode") },
      },
      child = ui.text({ key = "text", text = "text" }),
    }))
    value:flush()
    assert.is_false(require("applet.pane.input").dispatch(value, "n", "x"))
    assert.are.equal("handler", errors[#errors].phase)
    assert.matches("handler exploded", errors[#errors].message)
    local committed = value.layout
    value:update(ui.scope({
      key = "unknown",
      bindings = {
        { lhs = "u", action = ui.action("missing") },
      },
      child = ui.text({ key = "unknown:text", text = "unknown" }),
    }))
    value:flush()
    assert.are.equal(committed, value.layout)
    assert.are.equal("compile", errors[#errors].phase)
    assert.matches("unknown action", errors[#errors].message)
  end)

  it("contains mapping installation failures as commit failures", function()
    local errors = {}
    local value = pane({
      key = "mapping-errors",
      handlers = { action = function() end },
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host = surface("applet-mapping-errors")
    value:_connect(host)
    local original = vim.keymap.set
    vim.keymap.set = function() error("mapping exploded") end
    value:update(ui.scope({
      key = "scope",
      bindings = { { lhs = "x", action = ui.action("action") } },
      child = ui.text({ key = "text", text = "text" }),
    }))
    value:flush()
    vim.keymap.set = original
    assert.are.equal("commit", errors[#errors].phase)
    assert.matches("mapping exploded", errors[#errors].message)
    assert.is_true(value.reconcile_state.unknown)
    assert.is_nil(mapping(host.buffer, "n", "x"))
    value:update(ui.text({ key = "recovered", text = "recovered" }))
    value:flush()
    assert.are.same({ "recovered" }, lines(host.buffer))
  end)

  it("retains the current image and releases a failed commit candidate", function()
    local source_module = require("applet.image.source")
    local function source_value(revision)
      return {
        kind = "png_bytes",
        id = "mapping-image",
        data = "frame-" .. revision,
        revision = revision,
      }
    end
    local first_id = source_module.identity(source_value(1))
    local second_id = source_module.identity(source_value(2))
    local resources = {
      [first_id] = {
        id = first_id,
        data = "frame-1",
        bytes = 7,
        width = 2,
        height = 1,
      },
      [second_id] = {
        id = second_id,
        data = "frame-2",
        bytes = 7,
        width = 2,
        height = 1,
      },
    }
    local images = Applet.ImageSystem._new({
      _backend = image_backend(),
    })
    images.status = "available"
    images.resources = resources
    images.cache_bytes = 14
    local errors = {}
    local value = pane({
      key = "mapping-image-leases",
      image_system = images,
      handlers = { action = function() end },
      on_error = function(err) errors[#errors + 1] = err end,
    })
    local host = surface("applet-mapping-image-leases", true)
    value:_connect(host)
    local function image(revision)
      return ui.image({
        key = "mapping:image",
        source = source_value(revision),
        alt = "mapping image",
        width = 2,
        height = 1,
      })
    end
    value:update(image(1))
    assert(value:flush())

    local keymap_set = vim.keymap.set
    vim.keymap.set = function() error("mapping exploded") end
    value:update(ui.scope({
      key = "mapping:scope",
      bindings = { { lhs = "x", action = ui.action("action") } },
      child = image(2),
    }))
    local flushed, flush_error = pcall(value.flush, value)
    vim.keymap.set = keymap_set

    assert(flushed, flush_error)
    assert.are.equal("commit", errors[#errors].phase)
    assert.are.equal(first_id,
      images:snapshot(value).presented["mapping:image"])
    assert.is_truthy(images.resources[first_id])
    assert.is_nil(images.resources[second_id])
    images:destroy()
  end)

  it("owns and restores floating chrome as complete state", function()
    local value = pane({ key = "chrome" })
    local host, window = surface("applet-chrome", true)
    local original_wrap = vim.wo[window()].wrap
    local original_cursorline = vim.wo[window()].cursorline
    value:_connect(host)
    value:update({
      root = ui.text({ key = "text", text = "text" }),
      chrome = {
        title = { { text = " Managed " } },
        title_pos = "center",
        footer = { { text = " Footer " } },
        footer_pos = "right",
        options = { cursorline = not original_cursorline },
      },
    })
    value:flush()
    assert.are.equal(" Managed ", vim.api.nvim_win_get_config(window()).title[1][1])
    assert.are.equal("center", vim.api.nvim_win_get_config(window()).title_pos)
    assert.are.equal("right", vim.api.nvim_win_get_config(window()).footer_pos)
    assert.are.equal(not original_cursorline, vim.wo[window()].cursorline)
    assert.is_false(vim.wo[window()].wrap)
    value:update(ui.text({ key = "text", text = "text" }))
    value:flush()
    local config = vim.api.nvim_win_get_config(window())
    assert.is_true(config.title == nil or config.title == "")
    assert.is_true(config.footer == nil or config.footer == "")
    assert.are.equal(original_cursorline, vim.wo[window()].cursorline)
    local replacement = vim.api.nvim_open_win(host.buffer, true, {
      relative = "editor",
      row = 4,
      col = 4,
      width = 30,
      height = 4,
      style = "minimal",
    })
    host.window = function() return replacement end
    value:_connect(host)
    value:update(ui.text({ key = "text", text = "text" }))
    value:flush()
    assert.is_false(vim.wo[replacement].wrap)
    vim.api.nvim_win_close(replacement, true)
    value:_disconnect()
    assert.is_nil(value.reconcile_state.chrome)
    host.window = window
    value:_connect(host)
    value:update(ui.text({ key = "text", text = "text" }))
    value:flush()
    value:_disconnect()
    assert.are.equal(original_wrap, vim.wo[window()].wrap)
    assert.are.equal(original_cursorline, vim.wo[window()].cursorline)
  end)

  it("restores original float footers and replaces Surface chrome adapters", function()
    local value = pane({ key = "replace-chrome-adapter" })
    local host, window = surface("applet-replace-chrome-adapter", true)
    local config = vim.api.nvim_win_get_config(window())
    config.footer = { { " Original ", "Comment" } }
    config.footer_pos = "left"
    vim.api.nvim_win_set_config(window(), config)
    value:_connect(host)
    value:update({
      root = ui.text({ key = "text", text = "chrome" }),
      chrome = { footer = { { text = " Managed " } }, footer_pos = "right" },
    })
    assert(value:flush())
    value:_disconnect()
    config = vim.api.nvim_win_get_config(window())
    assert.are.equal(" Original ", config.footer[1][1])
    assert.are.equal("left", config.footer_pos)

    local restored = { first = 0, second = 0 }
    local function adapter(name)
      return {
        apply = function() end,
        measure = function() return {} end,
        restore = function() restored[name] = restored[name] + 1 end,
      }
    end
    host.chrome = adapter("first")
    value:_connect(host)
    value:update(ui.text({ key = "adapter-text", text = "adapter" }))
    assert(value:flush())
    local replacement = vim.tbl_extend("force", {}, host)
    replacement.chrome = adapter("second")
    value:_connect(replacement)
    value:surface_changed({ chrome = true })
    assert(value:flush())
    assert.are.equal(1, restored.first)
    value:_disconnect()
    assert.are.equal(1, restored.second)
  end)

  it("restores mappings that existed before connection", function()
    local host = surface("applet-mapping-restore")
    vim.keymap.set("n", "z", "<Cmd>let g:applet_original = 1<CR>", {
      buffer = host.buffer,
      desc = "Original mapping",
    })
    vim.keymap.set("n", "y", "<Cmd>let g:applet_original_y = 1<CR>", {
      buffer = host.buffer,
      desc = "Original Y mapping",
    })
    local value = pane({
      key = "mapping-restore",
      handlers = { action = function() end },
    })
    value:_connect(host)
    value:update(ui.scope({
      key = "scope",
      bindings = {
        { lhs = "z", action = ui.action("action") },
        { lhs = "y", action = ui.action("action") },
      },
      child = ui.text({ key = "text", text = "text" }),
    }))
    value:flush()
    assert.are.equal(value.mapping_description,
      mapping(host.buffer, "n", "z").desc)
    vim.keymap.set("n", "y", "<Cmd>let g:applet_user_y = 1<CR>", {
      buffer = host.buffer,
      desc = "User Y mapping",
    })
    value:_disconnect()
    assert.are.equal("Original mapping", mapping(host.buffer, "n", "z").desc)
    assert.are.equal("User Y mapping", mapping(host.buffer, "n", "y").desc)
    vim.keymap.del("n", "z", { buffer = host.buffer })
    vim.keymap.del("n", "y", { buffer = host.buffer })
  end)

  it("disconnects when its connected buffer is wiped", function()
    local value = pane({ key = "wiped" })
    local host = surface("applet-wiped")
    host.owns_buffer = false
    value:_connect(host)
    value:update(ui.text({ key = "text", text = "text" }))
    value:flush()
    vim.api.nvim_buf_delete(host.buffer, { force = true })
    assert.is_nil(value.surface)
  end)

  it("disconnects safely when its buffer is unloaded", function()
    local value = pane({
      key = "unloaded",
      handlers = { action = function() end },
    })
    local host = surface("applet-unloaded")
    value:_connect(host)
    value:update(ui.scope({
      key = "scope",
      bindings = { { lhs = "x", action = ui.action("action") } },
      child = ui.text({ key = "text", text = "text" }),
    }))
    value:flush()
    vim.cmd("bunload! " .. host.buffer)
    assert(vim.wait(1000, function() return value.surface == nil end))
    assert.is_true(vim.api.nvim_buf_is_valid(host.buffer))
    assert.is_false(vim.api.nvim_buf_is_loaded(host.buffer))
    value:destroy()
    assert.is_false(vim.api.nvim_buf_is_valid(host.buffer))
  end)
end)
