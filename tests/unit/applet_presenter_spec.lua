local presenter = require("applet.presenter")

local function result()
  local value = {}
  return value, {
    resolve = function(item) value.resolved = item end,
    reject = function(err) value.rejected = err end,
  }
end

describe("Applet host Presenter", function()
  local original_select
  local original_input
  local original_open
  local original_notify
  local original_inputsecret
  local original_schedule

  before_each(function()
    original_select = vim.ui.select
    original_input = vim.ui.input
    original_open = vim.ui.open
    original_notify = vim.notify
    original_inputsecret = vim.fn.inputsecret
    original_schedule = vim.schedule
  end)

  after_each(function()
    vim.ui.select = original_select
    vim.ui.input = original_input
    vim.ui.open = original_open
    vim.notify = original_notify
    vim.fn.inputsecret = original_inputsecret
    vim.schedule = original_schedule
  end)

  it("selects semantic items through fallback values and contains cancellation", function()
    local callback, options, physical
    vim.ui.select = function(items, opts, done)
      physical, options, callback = items, opts, done
    end
    local selected, done = result()
    local fallback = { name = "host value" }
    local cancel = presenter.select({
      prompt = "Choose",
      items = {
        { id = "first", label = "First", detail = "detail",
          fallback = fallback },
        { id = "second", label = "Second" },
      },
    }, done)
    assert.are.equal(fallback, physical[1])
    assert.are.equal("Second", physical[2].label)
    assert.are.equal("First · detail", options.format_item(fallback))
    assert.are.equal("Choose", options.prompt)
    callback(fallback)
    assert.are.equal("first", selected.resolved)
    callback(physical[2])
    assert.is_nil(selected.rejected)
    cancel()

    local cancelled, cancelled_done = result()
    presenter.select({ prompt = "Choose", items = {} }, cancelled_done)
    callback(nil)
    assert.are.equal("cancelled", cancelled.rejected.kind)
    assert.are.equal("Selection cancelled", cancelled.rejected.message)
  end)

  it("contains select startup errors and ignores callbacks after cancellation", function()
    local failed, failed_done = result()
    vim.ui.select = function() error("select unavailable") end
    presenter.select({ prompt = "Choose", items = {} }, failed_done)
    assert.matches("select unavailable", tostring(failed.rejected))

    local callback
    vim.ui.select = function(_, _, done) callback = done end
    local cancelled, done = result()
    local cancel = presenter.select({
      prompt = "Choose", items = { { id = "one", label = "One" } },
    }, done)
    cancel()
    callback({ id = "one", label = "One" })
    assert.is_nil(cancelled.resolved)
    assert.is_nil(cancelled.rejected)
  end)

  it("accepts ordinary input and rejects absent or disallowed empty values", function()
    local callback, options
    vim.ui.input = function(opts, done) options, callback = opts, done end
    local accepted, accepted_done = result()
    presenter.input({ prompt = "Name", default = "draft" }, accepted_done)
    assert.are.same({ prompt = "Name ", default = "draft" }, options)
    callback("value")
    assert.are.equal("value", accepted.resolved)

    local empty, empty_done = result()
    presenter.input({ prompt = "Name", allow_empty = false }, empty_done)
    callback("")
    assert.are.equal("cancelled", empty.rejected.kind)

    local allowed, allowed_done = result()
    presenter.input({ prompt = "Name", allow_empty = true }, allowed_done)
    callback("")
    assert.are.equal("", allowed.resolved)

    local absent, absent_done = result()
    presenter.input({ prompt = "Name" }, absent_done)
    callback(nil)
    assert.are.equal("cancelled", absent.rejected.kind)

    local failed, failed_done = result()
    vim.ui.input = function() error("input unavailable") end
    presenter.input({ prompt = "Name" }, failed_done)
    assert.matches("input unavailable", tostring(failed.rejected))
  end)

  it("keeps notices visible until their host choice closes them", function()
    local callback, options, items
    vim.ui.select = function(values, opts, done)
      items, options, callback = values, opts, done
    end
    local closed, closed_done = result()
    presenter.notice({
      prompt = "Device login · <C-c> close",
      body = "Open https://device.example\nCode ABCD-EFGH",
    }, closed_done)
    assert.are.equal("Device login · <C-c> close\n"
      .. "Open https://device.example\nCode ABCD-EFGH", options.prompt)
    assert.are.equal("Close", options.format_item(items[1]))
    callback(items[1])
    assert.is_true(closed.resolved)

    local cancelled, cancelled_done = result()
    presenter.notice({ prompt = "Notice", body = "Body" }, cancelled_done)
    callback(nil)
    assert.are.equal("cancelled", cancelled.rejected.kind)
    assert.are.equal("Notice closed", cancelled.rejected.message)
  end)

  it("schedules secret input and keeps cancellation private", function()
    local scheduled
    vim.schedule = function(callback) scheduled = callback end
    vim.fn.inputsecret = function(prompt)
      assert.are.equal("Secret ", prompt)
      return "token"
    end
    local accepted, accepted_done = result()
    presenter.input({ prompt = "Secret", secret = true }, accepted_done)
    scheduled()
    assert.are.equal("token", accepted.resolved)

    vim.fn.inputsecret = function() return "" end
    local empty, empty_done = result()
    presenter.input({ prompt = "Secret", secret = true }, empty_done)
    scheduled()
    assert.are.equal("cancelled", empty.rejected.kind)

    local allowed, allowed_done = result()
    presenter.input({ prompt = "Secret", secret = true, allow_empty = true },
      allowed_done)
    scheduled()
    assert.are.equal("", allowed.resolved)

    vim.fn.inputsecret = function() error("secret unavailable") end
    local failed, failed_done = result()
    presenter.input({ prompt = "Secret", secret = true }, failed_done)
    scheduled()
    assert.matches("secret unavailable", tostring(failed.rejected))

    vim.fn.inputsecret = function() return "hidden" end
    local cancelled, cancelled_done = result()
    local cancel = presenter.input({ prompt = "Secret", secret = true },
      cancelled_done)
    cancel()
    scheduled()
    assert.is_nil(cancelled.resolved)
    assert.is_nil(cancelled.rejected)
  end)

  it("confirms yes, no, and cancellation through semantic choices", function()
    local callback, options, items
    vim.ui.select = function(values, opts, done)
      items, options, callback = values, opts, done
    end
    local yes, yes_done = result()
    presenter.confirm({
      prompt = "Continue?", accept_label = "Proceed", reject_label = "Stop",
    }, yes_done)
    assert.are.equal("Continue?", options.prompt)
    assert.are.equal("Proceed", options.format_item(items[1]))
    callback(items[1])
    assert.is_true(yes.resolved)

    local no, no_done = result()
    presenter.confirm({
      prompt = "Continue?", accept_label = "Proceed", reject_label = "Stop",
    }, no_done)
    callback(items[2])
    assert.is_false(no.resolved)

    local cancelled, cancelled_done = result()
    presenter.confirm({
      prompt = "Continue?", accept_label = "Proceed", reject_label = "Stop",
    }, cancelled_done)
    callback(nil)
    assert.are.equal("cancelled", cancelled.rejected.kind)

    local failed, failed_done = result()
    vim.ui.select = function() error("confirm unavailable") end
    presenter.confirm({
      prompt = "Continue?", accept_label = "Proceed", reject_label = "Stop",
    }, failed_done)
    assert.matches("confirm unavailable", tostring(failed.rejected))
  end)

  it("translates notifications and URI opening through Neovim", function()
    local effects = {}
    vim.notify = function(message, level)
      effects[#effects + 1] = { "notify", message, level }
      return "notified"
    end
    vim.ui.open = function(uri)
      effects[#effects + 1] = { "open", uri }
      return "opened"
    end
    assert.are.equal("notified", presenter.notify("ready", 2))
    assert.are.equal("opened", presenter.open_uri("https://example.test"))
    assert.are.same({
      { "notify", "ready", 2 },
      { "open", "https://example.test" },
    }, effects)

    vim.ui.open = nil
    assert.has_error(function() presenter.open_uri("https://example.test") end,
      "URI opening is unavailable")
  end)
end)
