local assert = require("luassert")
local Presenter = require("neoagent.presenter")

---@param overrides? Partial<Neoagent.PresenterHost>
---@return Neoagent.PresenterHost
local function host(overrides)
  ---@type Neoagent.PresenterHost
  local value = {
    select = function(request, done) done.resolve(assert(request.items[1]).id) end,
    input = function(request, done) done.resolve(request.default or "") end,
    notice = function(_, done) done.resolve(true) end,
    notify = function() end,
    open_uri = function() end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

describe("neoagent semantic Presenter", function()
  ---@type Neoagent.Presenter[]
  local presenters = {}
  local original_select

  before_each(function() original_select = vim.ui.select end)

  after_each(function()
    vim.ui.select = original_select
    for _, presenter in ipairs(presenters) do presenter:destroy() end
    presenters = {}
  end)

  ---@param opts? {host?: Neoagent.PresenterHost}
  ---@return Neoagent.Presenter
  local function presenter(opts)
    local value = Presenter.new(opts)
    presenters[#presenters + 1] = value
    return value
  end

  it("uses the Applet host translation when no View is attached", function()
    local selected, retired = nil, false
    local value = presenter({
      host = host({
        select = function(request, done)
          selected = request.items[2].fallback
          done.resolve(request.items[2].id)
          return function() retired = true end
        end,
      }),
    })
    local run = value:select({ items = { "alpha", "beta" } })
    assert.is_true(run:is_done())
    assert.is_true(assert(run:result()).ok)
    assert.are.equal("beta", assert(run:result()).value)
    assert.are.equal("beta", selected)
    assert.is_true(retired)
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
    assert.is_false(assert(run:result()).value)
  end)

  it("publishes FIFO semantic requests and resolves private values", function()
    ---@type Neoagent.PresentationSnapshot[]
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
    local active = assert(snapshot.active)
    assert(active.kind == "select")
    local item = assert(active.items[1])
    assert.are.equal(1, snapshot.queue_count)
    assert.is_nil(item.value)
    assert.is_nil(item.fallback)
    assert.is_nil((value:resolve(active.id, "b")))
    assert(value:resolve(active.id, "a"))
    assert(vim.wait(1000, function() return first:is_done() end))
    assert.are.same({ answer = 1 }, assert(first:result()).value)
    snapshot = value:snapshot()
    active = assert(snapshot.active)
    assert(active.kind == "input")
    assert.are.equal("draft", active.default)
    assert(value:resolve(active.id, ""))
    assert(vim.wait(1000, function() return second:is_done() end))
    assert.are.equal("", assert(second:result()).value)
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
    local id = assert(value:snapshot().active).id
    assert.is_true(update({
      { id = "one", label = "One updated", value = "new" },
      { id = "two", label = "Two", value = "second" },
    }))
    local active = assert(value:snapshot().active)
    assert(active.kind == "select")
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
    assert.are.equal("new", assert(run:result()).value)
    active = assert(value:snapshot().active)
    assert(active.kind == "select")
    assert.are.equal("Queued updated", assert(active.items[1]).label)
    assert(value:resolve(active.id, "queued"))
    assert(vim.wait(1000, function() return queued:is_done() end))
    assert.are.equal("new queued", assert(queued:result()).value)
    assert.is_false(update({}))
    value:destroy()
    assert.is_false(update({ { id = "one", label = "Destroyed" } }))
    detach()
  end)

  it("rejects active fallback updates and stale failures", function()
    local value = presenter({
      host = host({
        select = function() return function() end end,
      }),
    })
    local run, update = value:select({ items = { "one" } })
    local active = assert(value:snapshot().active)

    assert.is_false(update({ "two" }))
    assert.is_false(value:reject("stale", "late failure"))
    assert.is_true(value:cancel(active.id))
    assert(vim.wait(1000, function() return run:is_done() end))
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
    assert.are.equal("one", assert(run:result()).value)
  end)

  it("retires each fallback exactly once when an Applet takes over", function()
    for _, kind in ipairs({ "select", "input", "notice" }) do
      local cancelled = 0
      ---@type Applet.PresentationCallbacks<unknown>?
      local fallback_done
      local value = presenter({
        host = host({
          [kind] = function(_, done)
            fallback_done = done
            return function() cancelled = cancelled + 1 end
          end,
        }),
      })
      local run
      if kind == "select" then
        run = value:select({ items = { "one" } })
      elseif kind == "input" then
        run = value:input({ allow_empty = true })
      else
        run = value:notice({ body = "notice" })
      end
      assert.is_false(run:is_done())
      ---@type Neoagent.PresentationSnapshot?
      local presented
      local detach = value:attach({
        present = function(snapshot) presented = snapshot end,
      })
      assert.are.equal(1, cancelled)
      local active = assert(assert(presented).active)
      local response = active.kind == "select" and assert(active.items[1]).id
        or kind == "input" and "answer" or nil
      assert(value:resolve(active.id, response))
      assert(vim.wait(1000, function() return run:is_done() end))
      fallback_done.resolve(response)
      assert.are.equal(1, cancelled)
      detach()
    end
  end)

  it("publishes closeable notices", function()
    local value = presenter({ host = host() })
    local detach = value:attach({ present = function() end })
    local run = value:notice({ prompt = "Device login", body = "Code 1234" })
    local active = assert(value:snapshot().active)
    assert.are.equal("notice", active.kind)
    assert.are.equal("Device login", active.prompt)
    assert.are.equal("Code 1234", active.body)
    assert(value:resolve(active.id))
    assert(vim.wait(1000, function() return run:is_done() end))
    assert.is_true(assert(run:result()).value)
    detach()
  end)

  it("returns booleans from confirmation and validates responses", function()
    local value = presenter({ host = host() })
    local detach = value:attach({ present = function() end })
    local rejected = value:confirm({ prompt = "Continue?" })
    local active = assert(value:snapshot().active)
    assert(value:resolve(active.id, "no"))
    assert(vim.wait(1000, function() return rejected:is_done() end))
    assert.is_false(assert(rejected:result()).value)

    local input = value:input({ prompt = "One line" })
    active = assert(value:snapshot().active)
    assert.is_nil((value:resolve(active.id, "two\nlines")))
    assert.is_nil((value:resolve(active.id, "")))
    assert(value:cancel(active.id, "dismissed"))
    assert(vim.wait(1000, function() return input:is_done() end))
    assert.is_false(assert(input:result()).ok)
    assert.are.equal("cancelled", assert(assert(input:result()).error).kind)
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
    assert.is_false(assert(active:result()).ok)
    assert.matches("surface closed", assert(assert(active:result()).error).message)
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
    assert.matches("is not active", assert(stale_error).message)
    selection:cancel()
    assert(vim.wait(1000, function() return selection:is_done() end))
    assert.are.equal(1, cancelled)

    local failed = value:input({ prompt = "Broken" })
    assert(vim.wait(1000, function() return failed:is_done() end))
    assert.is_false(assert(failed:result()).ok)
    assert.matches("input host failed", assert(assert(failed:result()).error).message)

    local pending = value:select({ items = { "two" } })
    value:destroy()
    assert(vim.wait(1000, function() return pending:is_done() end))
    assert.are.equal(2, cancelled)
    assert.matches("Presenter was destroyed", assert(assert(pending:result()).error).message)

    local surface = presenter({ host = host() })
    local attached, attach_error = pcall(function()
      surface:attach({
        present = function() error("surface failed") end,
      })
    end)
    assert.is_false(attached)
    assert.matches("surface failed", tostring(attach_error))
    assert.is_nil(surface.attachment)
  end)
end)
