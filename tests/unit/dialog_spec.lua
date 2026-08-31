local async = require("neoagent.async")

local function dialog(actions)
  return {
    placement = "transcript",
    title = "Choose a test action",
    body = "This body is supplied by the caller.",
    actions = actions or {
      { id = "proceed", label = "proceed", key = "y" },
      { id = "skip", label = "skip", key = "n" },
    },
  }
end

local function wait(...)
  local runs = { ... }
  assert(vim.wait(1000, function()
    for _, run in ipairs(runs) do
      if not run:is_done() then return false end
    end
    return true
  end, 5))
end

describe("neoagent dialog source", function()
  it("publishes arbitrary dialogs in FIFO order and returns chosen actions",
    function()
      local source = require("neoagent.dialog").new()
      local snapshots = {}
      local detach = source:subscribe(function(snapshot)
        snapshots[#snapshots + 1] = snapshot
      end)
      local first = source:show(dialog())
      local first_id = source:snapshot().active.id
      local second = source:show(dialog())
      assert.are.equal(first_id, source:snapshot().active.id)
      assert.are.equal(1, source:snapshot().queue_count)

      local missing, missing_err = source:choose("missing", "proceed")
      assert.is_nil(missing)
      assert.matches("is not active", missing_err.message)
      local invalid, err = source:choose(first_id, "missing")
      assert.is_nil(invalid)
      assert.are.equal("dialog", err.kind)
      assert.is_true(source:choose(first_id, "proceed"))
      local second_id = source:snapshot().active.id
      assert.are_not.equal(first_id, second_id)
      assert.is_true(source:choose(second_id, "skip"))
      wait(first, second)
      assert.are.same({ ok = true, action = "proceed" },
        first:result())
      assert.are.same({ ok = true, action = "skip" },
        second:result())
      assert.is_nil(source:snapshot().active)
      assert.is_true(#snapshots >= 5)
      detach()
    end)

  it("returns editable input and cancels a dismissed active dialog", function()
    local source = require("neoagent.dialog").new()
    local detach = source:subscribe(function() end)
    local editable = dialog({
      { id = "save", label = "save", key = "<C-s>" },
      { id = "cancel", label = "cancel", key = "<Esc>" },
    })
    editable.placement = "float"
    editable.input = {
      label = "Command prefix",
      value = "git status",
      multiline = false,
    }
    local run = source:show(editable)
    local id = source:snapshot().active.id
    assert(source:choose(id, "save", "git diff"))
    wait(run)
    assert.are.same({
      ok = true,
      action = "save",
      input = "git diff",
    }, run:result())

    run = source:show(dialog())
    id = source:snapshot().active.id
    local missing, missing_err = source:cancel("missing")
    assert.is_nil(missing)
    assert.matches("is not active", missing_err.message)
    assert(source:cancel(id, "surface closed"))
    wait(run)
    assert.is_false(run:result().ok)
    assert.are.equal("surface closed", run:result().error.message)
    detach()
  end)

  it("removes cancelled queued dialogs and applies generic bulk actions",
    function()
      local source = require("neoagent.dialog").new()
      local detach = source:subscribe(function() end)
      local first = source:show(dialog())
      local second = source:show(dialog())
      local third = source:show(dialog())
      second:cancel()
      wait(second)
      assert.are.equal(1, source:snapshot().queue_count)
      first:cancel()
      wait(first)
      assert.are.equal(0, source:snapshot().queue_count)
      assert(source:choose(source:snapshot().active.id, "skip"))
      wait(third)

      first = source:show(dialog())
      second = source:show(dialog())
      assert.are.equal(2,
        source:choose_pending("skip", "caller selected all"))
      wait(first, second)
      assert.are.equal("skip", first:result().action)
      assert.are.equal("caller selected all", second:result().reason)

      first = source:show(dialog())
      second = source:show(dialog({
        { id = "close", label = "close", key = "q" },
      }))
      local count, err = source:choose_pending("skip")
      assert.is_nil(count)
      assert.matches("does not provide action", err.message)
      assert.are.equal(1, source:snapshot().queue_count)
      source:cancel_pending("test teardown")
      wait(first, second)

      local editable = dialog()
      editable.placement = "float"
      editable.input = {
        label = "Input",
        value = "",
        multiline = true,
      }
      first = source:show(editable)
      local editable_count, editable_err = source:choose_pending("proceed")
      assert.is_nil(editable_count)
      assert.matches("individual input", editable_err.message)
      source:cancel_pending("test teardown", {
        presenter_unavailable = true,
      })
      wait(first)
      assert.is_true(first:result().presenter_unavailable)
      assert.are.equal(0, source:choose_pending("proceed"))
      detach()
    end)

  it("fails closed without a presenter and validates dialog data", function()
    local unavailable = require("neoagent.dialog").new():show(dialog())
    assert.are.same({
      ok = false,
      error = {
        kind = "dialog",
        message = "Dialog is unavailable because no presenter is attached",
      },
    }, unavailable:result())

    local source = require("neoagent.dialog").new()
    local invalid = {
      function(value) value.placement = "sidebar" end,
      function(value) value.agent = "" end,
      function(value) value.agent = {} end,
      function(value) value.title = "" end,
      function(value) value.body = "bad\0body" end,
      function(value) value.default_action = "" end,
      function(value) value.default_action = "missing" end,
      function(value) value.actions = {} end,
      function(value) value.actions[1].id = "" end,
      function(value) value.actions[1].label = "" end,
      function(value) value.actions[1].key = "" end,
      function(value) value.actions[2].id = "proceed" end,
      function(value) value.actions[2].key = "y" end,
      function(value)
        value.input = {
          label = "Input",
          value = "",
          multiline = false,
        }
      end,
    }
    for _, mutate in ipairs(invalid) do
      local value = dialog()
      mutate(value)
      assert.has_error(function() source:show(value) end)
    end

    local editable = dialog()
    editable.placement = "float"
    editable.input = {
      label = "Input",
      value = "",
      multiline = false,
    }
    local detach = source:subscribe(function() end)
    local run = source:show(editable)
    assert.has_error(function()
      source:choose(source:snapshot().active.id, "proceed", "a\nb")
    end, "dialog response input must be one line")
    source:cancel_pending("test teardown")
    wait(run)
    detach()
  end)

  it("isolates subscriber failures and reports presenter loss", function()
    local notifications = {}
    local source = require("neoagent.dialog").new({ report = function(message, level)
      notifications[#notifications + 1] = { message, level }
    end })
    local broken = source:subscribe(function(snapshot)
      if snapshot.active then error("subscriber exploded") end
    end)
    local working = source:subscribe(function() end)
    local pending = source:show(dialog())
    assert.are.equal(1, #notifications)
    assert.matches("subscriber exploded", notifications[1][1])
    assert.are.equal(vim.log.levels.ERROR, notifications[1][2])
    assert(source:choose(source:snapshot().active.id, "skip"))
    wait(pending)
    broken()
    working()

    local rejected = require("neoagent.dialog").new()
    assert.has_error(function()
      rejected:subscribe(function() error("cannot present") end)
    end, "cannot present")
    assert.is_false(rejected:show(dialog()):result().ok)

    source = require("neoagent.dialog").new()
    local detach = source:subscribe(function() end)
    pending = source:show(dialog())
    detach()
    wait(pending)
    assert.is_false(pending:result().ok)
    assert.is_true(pending:result().presenter_unavailable)
  end)

  it("injects a lifetime-scoped optional ctx.dialog capability", function()
    local source = require("neoagent.dialog").new()
    local detach = source:subscribe(function() end)
    local retained
    local execute = require("neoagent.dialog").wrap(source,
      function(_, _, ctx)
        retained = ctx.dialog
        return ctx.dialog:show(dialog()):await()
      end)
    local run = async.run(function()
      return execute({ name = "custom" }, {}, {
        context = { agent = "Review" },
      })
    end)
    assert(vim.wait(1000, function()
      return source:snapshot().active ~= nil
    end, 5))
    assert.are.equal("Review", source:snapshot().active.agent)
    assert(source:choose(source:snapshot().active.id, "proceed"))
    wait(run)
    assert.are.equal("proceed", run:result().action)
    local ok, err = pcall(retained.show, retained, dialog())
    assert.is_false(ok)
    assert.are.equal("Dialog capability has expired", err.message)

    local retained_bulk
    local bulk = require("neoagent.dialog").wrap(source,
      function(_, _, ctx)
        retained_bulk = ctx.dialog
        local first = ctx.dialog:show(dialog())
        local second = ctx.dialog:show(dialog())
        assert.are.equal(2,
          ctx.dialog:choose_pending("skip", "selected by tool"))
        return {
          action = first:await().action,
          reason = second:await().reason,
        }
      end)
    local bulk_run = async.run(function() return bulk({}, {}, {}) end)
    wait(bulk_run)
    assert.are.equal("skip", bulk_run:result().action)
    assert.are.equal("selected by tool", bulk_run:result().reason)
    ok, err = pcall(
      retained_bulk.choose_pending, retained_bulk, "skip")
    assert.is_false(ok)
    assert.are.equal("Dialog capability has expired", err.message)

    local default = require("neoagent.dialog").wrap(source)
    assert.are.equal("direct", default({
      execute = function(_, ctx)
        assert.is_table(ctx.dialog)
        return "direct"
      end,
    }, {}, {}))
    detach()

    local observed
    local direct = function(_, _, ctx)
      observed = ctx.dialog
      return "headless"
    end
    assert.are.equal("headless", direct({}, {}, {}))
    assert.is_nil(observed)
  end)
end)
