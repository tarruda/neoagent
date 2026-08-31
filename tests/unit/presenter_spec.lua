local Presenter = require("neoagent.presenter")

local function host(overrides)
  local value = {
    select = function(request, done) done.resolve(request.items[1].id) end,
    input = function(request, done) done.resolve(request.default) end,
    notice = function(_, done) done.resolve(true) end,
    notify = function() end,
    open_uri = function() end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

describe("neoagent semantic Presenter", function()
  local presenters = {}
  local original_select

  before_each(function() original_select = vim.ui.select end)

  after_each(function()
    vim.ui.select = original_select
    for _, presenter in ipairs(presenters) do presenter:destroy() end
    presenters = {}
  end)

  local function presenter(opts)
    local value = Presenter.new(opts)
    presenters[#presenters + 1] = value
    return value
  end

  it("uses the Applet host translation when no View is attached", function()
    local selected
    local value = presenter({
      host = host({
        select = function(request, done)
          selected = request.items[2].fallback
          done.resolve(request.items[2].id)
        end,
      }),
    })
    local run = value:select({ items = { "alpha", "beta" } })
    assert.is_true(run:is_done())
    assert.is_true(run:result().ok)
    assert.are.equal("beta", run:result().value)
    assert.are.equal("beta", selected)
  end)

  it("preserves false selection values and host fallbacks", function()
    local fallback
    local value = presenter({
      host = host({
        select = function(request, done)
          fallback = request.items[1].fallback
          done.resolve(request.items[1].id)
        end,
      }),
    })
    local run = value:select({
      items = { { id = "disabled-value", label = "False", value = false,
        fallback = false } },
    })
    assert.is_true(run:is_done())
    assert.is_false(fallback)
    assert.is_false(run:result().value)
  end)

  it("publishes FIFO semantic requests and resolves private values", function()
    local publications = {}
    local value = presenter({ host = host() })
    local detach = value:attach({
      present = function(snapshot) publications[#publications + 1] = snapshot end,
    })
    local first = value:select({
      prompt = "Choose",
      items = {
        { id = "a", label = "Alpha", value = { answer = 1 } },
        { id = "b", label = "Beta", disabled = true },
      },
    })
    local second = value:input({
      prompt = "Name", default = "draft", allow_empty = true,
    })
    local snapshot = value:snapshot()
    assert.are.equal("select", snapshot.active.kind)
    assert.are.equal(1, snapshot.queue_count)
    assert.is_nil(snapshot.active.items[1].value)
    assert.is_nil(snapshot.active.items[1].fallback)
    assert.is_nil(value:resolve(snapshot.active.id, "b"))
    assert(value:resolve(snapshot.active.id, "a"))
    assert(vim.wait(1000, function() return first:is_done() end))
    assert.are.same({ answer = 1 }, first:result().value)
    snapshot = value:snapshot()
    assert.are.equal("input", snapshot.active.kind)
    assert.are.equal("draft", snapshot.active.default)
    assert(value:resolve(snapshot.active.id, ""))
    assert(vim.wait(1000, function() return second:is_done() end))
    assert.are.equal("", second:result().value)
    assert.is_nil(value:snapshot().active)
    assert.is_true(#publications >= 4)
    detach()
  end)

  it("updates a live selection while retaining its presentation identity", function()
    local value = presenter({ host = host() })
    local detach = value:attach({ present = function() end })
    local run, update = value:select({
      prompt = "Live models",
      items = { { id = "one", label = "One", value = "old" } },
    })
    local id = value:snapshot().active.id
    assert.is_true(update({
      { id = "one", label = "One updated", value = "new" },
      { id = "two", label = "Two", value = "second" },
    }))
    local active = value:snapshot().active
    assert.are.equal(id, active.id)
    assert.are.same({ "One updated", "Two" },
      vim.tbl_map(function(item) return item.label end, active.items))

    local queued, update_queued = value:select({
      prompt = "Queued models",
      items = {
        { id = "queued", label = "Queued", value = "old queued" },
      },
    })
    assert.is_true(update_queued({
      { id = "queued", label = "Queued updated", value = "new queued" },
    }))
    assert(value:resolve(id, "one"))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.equal("new", run:result().value)
    active = value:snapshot().active
    assert.are.equal("Queued updated", active.items[1].label)
    assert(value:resolve(active.id, "queued"))
    assert(vim.wait(1000, function() return queued:is_done() end))
    assert.are.equal("new queued", queued:result().value)
    assert.is_false(update({}))
    value:destroy()
    assert.is_false(update({ { id = "one", label = "Destroyed" } }))
    detach()
  end)

  it("returns an attached request to its host when the surface detaches", function()
    local hosted
    local value = presenter({
      host = host({
        select = function(request, done)
          hosted = request.prompt
          done.resolve(request.items[1].id)
        end,
      }),
    })
    local detach = value:attach({ present = function() end })
    local run = value:select({
      prompt = "Resume on host", items = { "one" },
    })
    assert.is_false(run:is_done())

    detach()

    assert(vim.wait(1000, function() return run:is_done() end))
    assert.are.equal("Resume on host", hosted)
    assert.are.equal("one", run:result().value)
  end)

  it("publishes closeable notices", function()
    local value = presenter({ host = host() })
    local detach = value:attach({ present = function() end })
    local run = value:notice({ prompt = "Device login", body = "Code 1234" })
    local active = value:snapshot().active
    assert.are.equal("notice", active.kind)
    assert.are.equal("Device login", active.prompt)
    assert.are.equal("Code 1234", active.body)
    assert(value:resolve(active.id))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(run:result().value)
    detach()
  end)

  it("returns booleans from confirmation and validates responses", function()
    local value = presenter({ host = host() })
    local detach = value:attach({ present = function() end })
    local rejected = value:confirm({ prompt = "Continue?" })
    local active = value:snapshot().active
    assert(value:resolve(active.id, "no"))
    assert(vim.wait(1000, function() return rejected:is_done() end))
    assert.is_false(rejected:result().value)

    local input = value:input({ prompt = "One line" })
    active = value:snapshot().active
    assert.is_nil(value:resolve(active.id, "two\nlines"))
    assert.is_nil(value:resolve(active.id, ""))
    assert(value:cancel(active.id, "dismissed"))
    assert(vim.wait(1000, function() return input:is_done() end))
    assert.is_false(input:result().ok)
    assert.are.equal("cancelled", input:result().error.kind)
    detach()
  end)

  it("removes cancelled queued requests and rejects a detached surface", function()
    local value = presenter({ host = host() })
    local detach = value:attach({ present = function() end })
    local active = value:select({ items = { "one" } })
    local queued = value:input({ prompt = "queued", allow_empty = true })
    queued:cancel()
    assert(vim.wait(1000, function() return queued:is_done() end))
    assert.are.equal(0, value:snapshot().queue_count)
    detach("surface closed")
    assert(vim.wait(1000, function() return active:is_done() end))
    assert.is_false(active:result().ok)
    assert.matches("surface closed", active:result().error.message)
  end)

  it("routes effects through the attached Applet boundary", function()
    local effects = {}
    local value = presenter({
      host = host({
        notify = function(message) effects[#effects + 1] = "host:" .. message end,
        open_uri = function(uri) effects[#effects + 1] = "host:" .. uri end,
      }),
    })
    value:notify("outside")
    value:open_uri("https://outside.example")
    local detach = value:attach({
      present = function() end,
      notify = function(message) effects[#effects + 1] = "view:" .. message end,
      open_uri = function(uri) effects[#effects + 1] = "view:" .. uri end,
    })
    value:notify({ message = "inside", level = 3 })
    value:open_uri({ uri = "https://inside.example" })
    assert.are.same({
      "host:outside",
      "host:https://outside.example",
      "view:inside",
      "view:https://inside.example",
    }, effects)
    detach()
  end)

  it("contains host startup, cancellation, destruction, and surface failures", function()
    local cancelled = 0
    local value = presenter({
      host = host({
        select = function()
          return function() cancelled = cancelled + 1 end
        end,
        input = function()
          error("input host failed")
        end,
      }),
    })

    local selection = value:select({ items = { "one" } })
    assert.is_false(selection:is_done())
    local resolved, stale_error = value:resolve("stale", "1")
    assert.is_nil(resolved)
    assert.matches("is not active", stale_error.message)
    selection:cancel()
    assert(vim.wait(1000, function() return selection:is_done() end))
    assert.are.equal(1, cancelled)

    local failed = value:input({ prompt = "Broken" })
    assert(vim.wait(1000, function() return failed:is_done() end))
    assert.is_false(failed:result().ok)
    assert.matches("input host failed", failed:result().error.message)

    local pending = value:select({ items = { "two" } })
    value:destroy()
    assert(vim.wait(1000, function() return pending:is_done() end))
    assert.are.equal(2, cancelled)
    assert.matches("Presenter was destroyed", pending:result().error.message)

    local surface = presenter({ host = host() })
    local attached, attach_error = pcall(function()
      surface:attach({
        present = function() error("surface failed") end,
      })
    end)
    assert.is_false(attached)
    assert.matches("surface failed", attach_error)
    assert.is_nil(surface.attachment)
  end)
end)
