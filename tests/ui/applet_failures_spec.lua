local Applet = require("applet")
local layout = Applet.layout
local ui = Applet.Pane.nodes
local Base = require("applet.host.base")
local FloatingDriver = require("applet.host.float")

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
    buffer = {
      name = key,
      uri = opts.uri,
      filetype = "applet-failure",
    },
    window = {
      border = opts.border or "single",
      options = { wrap = true },
    },
    focus = { mode = opts.mode },
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

local function measured_tree(main, detail, height)
  return frame(pane("main", main), {
    focus = "main",
    layers = {
      layout.layer({
        key = "measured-layer",
        width = 24,
        height = height,
        child = pane("detail", detail),
      }),
    },
  })
end

local function measurement(size)
  return {
    content_lines = size,
    screen_lines = size,
    chrome = { top = 0, right = 0, bottom = 0, left = 0 },
  }
end

local function succeeds(ok, err)
  assert(ok, err and err.message or tostring(err))
  return ok
end

local function with_patch(target, key, replacement, callback)
  local original = target[key]
  target[key] = replacement
  local ok, first, second = pcall(callback)
  target[key] = original
  assert(ok, first)
  return first, second
end

describe("Applet failure boundaries", function()
  local applets = {}
  local panes = {}

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
    applets, panes = {}, {}
    vim.cmd("silent! tabonly")
    vim.cmd("silent! only")
    vim.cmd("stopinsert")
  end)

  it("suppresses an optional failed Pane and rejects it when required", function()
    local errors = {}
    local broken = new_pane("content", {
      mode = "editable", fail = "optional Pane failed",
    })
    local value = applet({
      name = "optional-failure",
      host = Applet.host.floating({ width = 40, height = 10 }),
      on_error = function(err) errors[#errors + 1] = err end,
    })
    value:update(frame(pane("content", broken, { required = false }), {
      focus = "content",
    }))
    succeeds(value:open())
    local content = value:pane("content")
    assert.is_false(content:is_mounted())
    assert.are.same({ line = 1, column = 0 }, content:cursor())
    assert.is_true(content:set_cursor({ line = 1, column = 3 }))
    assert.are.same({ line = 1, column = 3 }, content:cursor())
    assert.are.equal("commit", errors[#errors].phase)

    succeeds(value:close())
    value:update(frame(pane("content", broken), { focus = "content" }))
    local opened, err = value:open()
    assert.is_nil(opened)
    assert.are.equal("commit", err.phase)
    assert.matches("required Pane could not be mounted", err.message)
  end)

  it("detaches an optional failed Layer from a tab Host", function()
    local main = new_pane("main", { text = "main" })
    local broken = new_pane("optional", { fail = "optional Layer failed" })
    local value = applet({
      name = "optional-tab-layer",
      host = Applet.host.tab({ label = "Optional Layer" }),
    })
    value:update(frame(pane("main", main), {
      focus = "main",
      layers = {
        layout.layer({
          key = "optional-layer",
          width = 24,
          height = 6,
          child = pane("optional", broken, { required = false }),
        }),
      },
    }))
    succeeds(value:open())
    assert.is_true(value:pane("main"):is_mounted())
    assert.is_false(value:pane("optional"):is_mounted())
  end)

  it("releases a transient Layer removed from a committed frame", function()
    local main = new_pane("main", { text = "main" })
    local transient = new_pane("transient", { text = "transient" })
    local value = applet({
      name = "removed-transient-layer",
      host = Applet.host.floating({ width = 50, height = 15 }),
    })
    value:update(frame(pane("main", main), {
      focus = "main",
      layers = {
        layout.layer({
          key = "transient-layer",
          width = 24,
          height = 6,
          child = pane("transient", transient, {
            lifecycle = "transient",
            owns_pane = true,
          }),
        }),
      },
    }))
    succeeds(value:open())
    local buffer = value:pane("transient"):native().buffer
    value:update(frame(pane("main", main), { focus = "main" }))
    succeeds(value:flush())
    assert.is_true(transient.destroyed)
    assert.is_false(vim.api.nvim_buf_is_valid(buffer))
    assert.is_nil(value:pane("transient"))
  end)

  it("destroys an owned Pane after replacing its buffer identity", function()
    local original = new_pane("content", { text = "original" })
    local replacement = new_pane("content", { text = "replacement" })
    local value = applet({
      name = "owned-buffer-replacement",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    value:update(frame(pane("content", original, {
      uri = "applet://failure/original",
      owns_pane = true,
    })))
    succeeds(value:open())
    local old_buffer = value:pane("content"):native().buffer

    value:update(frame(pane("content", replacement, {
      uri = "applet://failure/replacement",
    })))
    succeeds(value:flush())
    assert.is_true(original.destroyed)
    assert.is_false(vim.api.nvim_buf_is_valid(old_buffer))
    assert.are.same({ "replacement" }, vim.api.nvim_buf_get_lines(
      value:pane("content"):native().buffer, 0, -1, false))
  end)

  it("releases a partial observer installation before retrying open", function()
    local content = new_pane("content", { text = "stable" })
    local value = applet({
      name = "observer-installation-failure",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    value:update(frame(pane("content", content), { focus = "content" }))

    local opened, err = with_patch(vim.api, "nvim_create_autocmd", function()
      error("observer installation failed")
    end, function()
      return value:open()
    end)
    assert.is_nil(opened)
    assert.are.equal("host", err.phase)
    assert.matches("observer installation failed", err.message)
    assert.is_false(value:is_open())
    assert.is_nil(value.augroup)
    assert.is_nil(value:_stats().observer_scope)
    assert.is_false(value:_stats().interaction.key_observer_active)

    succeeds(value:open())
    assert.are.equal("live", value:_stats().observer_scope)
  end)

  it("rolls back Host transaction startup and publication failures", function()
    local content = new_pane("content", { text = "stable" })
    local value = applet({
      name = "update-failures",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    local requested = frame(pane("content", content), { focus = "content" })
    value:update(requested)
    succeeds(value:open())
    local native = value:pane("content"):native()

    local begin = value.driver.begin
    value.driver.begin = function() error("transaction startup failed") end
    value:update(requested)
    local committed, err = value:flush()
    value.driver.begin = begin
    assert.is_nil(committed)
    assert.matches("transaction startup failed", err.message)
    assert.are.same(native, value:pane("content"):native())

    local publish = value.driver.publish
    value.driver.publish = function() error("transaction publication failed") end
    value:update(requested)
    committed, err = value:flush()
    value.driver.publish = publish
    assert.is_nil(committed)
    assert.matches("transaction publication failed", err.message)
    assert.are.same(native, value:pane("content"):native())
    assert.is_true(value:is_open())
  end)

  it("closes cleanly when Host rollback itself fails", function()
    local content = new_pane("content", { text = "stable" })
    local value = applet({
      name = "rollback-failure",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    local requested = frame(pane("content", content))
    value:update(requested)
    succeeds(value:open())
    local driver = value.driver
    local begin, rollback = driver.begin, driver.rollback
    driver.begin = function() error("startup failed") end
    driver.rollback = function() error("rollback failed") end
    value:update(requested)
    local committed, err = value:flush()
    driver.begin, driver.rollback = begin, rollback
    assert.is_nil(committed)
    assert.matches("rollback failed", err.message)
    assert.is_false(value:is_open())
  end)

  it("bounds repeated and divergent content measurement feedback", function()
    local main = new_pane("main", { text = "main" })
    local detail = new_pane("detail", { text = "detail" })

    local repeated = applet({
      name = "repeated-measurement",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    repeated:update(measured_tree(main, detail,
      { content = true, min = 4, max = 4 }))
    local calls = 0
    local opened, repeated_error = with_patch(Base, "measure", function()
      calls = calls + 1
      return measurement(calls)
    end, function()
      return repeated:open()
    end)
    assert.is_nil(opened)
    assert.are.equal("measure", repeated_error.phase)
    assert.matches("did not settle", repeated_error.message)

    local divergent_main = new_pane("main", { text = "main" })
    local divergent_detail = new_pane("detail", { text = "detail" })
    local divergent = applet({
      name = "divergent-measurement",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    divergent:update(measured_tree(divergent_main, divergent_detail,
      { content = true, min = 2, max = 15 }))
    calls = 0
    local divergent_error
    opened, divergent_error = with_patch(Base, "measure", function()
      calls = calls + 1
      return measurement(calls)
    end, function()
      return divergent:open()
    end)
    assert.is_nil(opened)
    assert.are.equal("measure", divergent_error.phase)
    assert.matches("exceeded two recompilations", divergent_error.message)
  end)

  it("accepts content measurement that settles on its final bounded pass", function()
    local main = new_pane("main", { text = "main" })
    local detail = new_pane("detail", { text = "detail" })
    local value = applet({
      name = "settled-measurement",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    value:update(measured_tree(main, detail,
      { content = true, min = 2, max = 15 }))
    local calls = 0
    local opened, err = with_patch(Base, "measure", function()
      calls = calls + 1
      return measurement(math.min(calls, 2))
    end, function()
      return value:open()
    end)
    succeeds(opened, err)
    assert.are.equal(3, calls)
  end)

  it("rolls back an update whose content measurement cannot settle", function()
    local main = new_pane("main", { text = "main" })
    local detail = new_pane("detail", { text = "detail" })
    local value = applet({
      name = "update-measurement",
      host = Applet.host.floating({ width = 60, height = 20 }),
    })
    local requested = measured_tree(main, detail,
      { content = true, min = 4, max = 4 })
    value:update(requested)
    succeeds(value:open())
    local native = value:pane("main"):native()
    value:update(requested)
    local calls = 0
    local committed, err = with_patch(Base, "measure", function()
      calls = calls + 1
      return measurement(20 + calls)
    end, function()
      return value:flush()
    end)
    assert.is_nil(committed)
    assert.are.equal("measure", err.phase)
    assert.are.same(native, value:pane("main"):native())
    assert.is_true(value:is_open())
  end)

  it("rejects repeated same-generation Surface measurement commits", function()
    local errors = {}
    local main = new_pane("main", { text = "main" })
    local detail = new_pane("detail", { text = "detail" })
    local value = applet({
      name = "surface-measurement-limit",
      host = Applet.host.floating({ width = 60, height = 20 }),
      on_error = function(err) errors[#errors + 1] = err end,
    })
    value:update(measured_tree(main, detail,
      { content = true, min = 2, max = 15 }))
    succeeds(value:open())
    local record = value.records.detail
    local settled = value.measurements.detail
    local calls = 0
    with_patch(Base, "measure", function()
      calls = calls + 1
      if calls == 1 then return settled end
      return measurement(30 + calls)
    end, function()
      record.surface.on_commit({ generation = 77 })
      record.surface.on_commit({ generation = 77 })
      record.surface.on_commit({ generation = 77 })
      record.surface.on_commit({ generation = 77 })
    end)
    assert.are.equal("measure", errors[#errors].phase)
    assert.matches("exceeded two recompilations", errors[#errors].message)
  end)

  it("contains floating Host publication and rollback failures during open", function()
    local function attempt(name, rollback_failure)
      local content = new_pane("content", { text = name })
      local value = applet({
        name = name,
        host = Applet.host.floating({ width = 40, height = 10 }),
      })
      value:update(frame(pane("content", content)))
      local new_driver = FloatingDriver.new
      return with_patch(FloatingDriver, "new", function(...)
        local driver = new_driver(...)
        driver.publish = function() error("open publication failed") end
        if rollback_failure then
          local destroy = driver.destroy
          driver.destroy = function(self, records)
            destroy(self, records)
            error("open release failed")
          end
        end
        return driver
      end, function()
        return value:open()
      end)
    end

    local opened, err = attempt("open-publication", false)
    assert.is_nil(opened)
    assert.matches("open publication failed", err.message)
    opened, err = attempt("open-rollback", true)
    assert.is_nil(opened)
    assert.matches("open rollback failed", err.message)
    assert.matches("open release failed", err.message)
  end)

  it("reports preparation failure and focuses an already open Applet", function()
    local empty = applet({
      name = "empty-open",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    local opened, err = empty:open()
    assert.is_nil(opened)
    assert.are.equal("render", err.phase)
    assert.is_false(empty:is_open())

    local content = new_pane("content", { text = "ready" })
    local value = applet({
      name = "repeated-open",
      host = Applet.host.floating({ width = 40, height = 10 }),
    })
    value:update(frame(pane("content", content), { focus = "content" }))
    succeeds(value:open())
    vim.api.nvim_set_current_win(empty.origin.window)
    succeeds(value:open())
    assert.is_true(value:pane("content"):is_focused())
  end)

  it("contains focus callback failures from requested and native focus", function()
    local errors = {}
    local first = new_pane("first", { text = "first" })
    local second = new_pane("second", { text = "second" })
    local value = applet({
      name = "focus-callback-failure",
      host = Applet.host.floating({ width = 50, height = 15 }),
      on_focus = function() error("focus callback failed") end,
      on_error = function(err) errors[#errors + 1] = err end,
    })
    value:update(frame(layout.split({
      key = "main",
      axis = "horizontal",
      children = {
        { key = "first", grow = 1, child = pane("first", first) },
        { key = "second", grow = 1, child = pane("second", second) },
      },
    }), { focus = "second" }))
    succeeds(value:open())
    assert.are.equal("action", errors[#errors].phase)
    vim.api.nvim_set_current_win(value:pane("first"):native().window)
    assert(vim.wait(1000, function() return #errors >= 2 end))
    assert.are.equal("action", errors[#errors].phase)
    assert.matches("focus callback failed", errors[#errors].message)
  end)
end)
