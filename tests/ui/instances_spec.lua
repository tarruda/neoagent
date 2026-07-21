local fake_model = require("tests.helpers.fake_model")

describe("neoagent controller instances", function()
  local neoagent
  local controllers

  before_each(function()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
    controllers = {}
  end)

  after_each(function()
    for _, controller in ipairs(controllers) do controller:destroy() end
  end)

  local function view_factory(views)
    return function(opts)
      local view = {
        config = opts.config,
        controller = opts.controller,
        messages = {},
        context = {},
        events = {},
        opened = false,
        destroyed = false,
      }
      function view:open() self.opened = true return true end
      function view:close() self.opened = false end
      function view:is_open() return self.opened end
      function view:destroy() self:close() self.destroyed = true end
      function view:set_messages(messages) self.messages = messages end
      function view:set_input(input) self.input = input end
      function view:set_context(context) self.context = context end
      function view:apply(event) self.events[#self.events + 1] = event end
      function view:finish(result) self.result = result end
      views[#views + 1] = view
      return view
    end
  end

  local function options(name, model, views)
    local result = {
      name = name,
      default_registry = false,
      persistence = { enabled = false },
      default_model = { provider = "fake", model = name },
      providers = { fake = { api = "fake", models = { [name] = {} } } },
      apis = { fake = function() return model end },
      tools = {},
      agents = false,
      skills = false,
    }
    if views then result.view = view_factory(views) end
    return result
  end

  it("runs independently configured sessions and passive views", function()
    local alpha_model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "alpha reply" } }),
    } })
    local beta_model = fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "beta reply" } }),
    } })
    local views = {}
    local alpha = neoagent.new(options("alpha", alpha_model, views))
    local beta = neoagent.new(options("beta", beta_model, views))
    controllers = { alpha, beta }

    assert(alpha:open())
    assert(beta:open())
    assert.are.equal(2, #views)
    assert.are_not.equal(views[1], views[2])
    assert.are.equal("alpha", views[1].config.title)
    assert.are.equal("beta", views[2].config.title)
    assert.are.equal(alpha, views[1].controller)
    assert.are.equal(beta, views[2].controller)

    local alpha_run = assert(alpha:send("for alpha"))
    local beta_run = assert(beta:send("for beta"))
    assert(vim.wait(1000, function() return alpha_run:is_done() and beta_run:is_done() end))
    assert.are.equal("for alpha", alpha:get_session():messages()[1].content)
    assert.are.equal("alpha reply", alpha:get_session():messages()[2].content[1].text)
    assert.are.equal("for beta", beta:get_session():messages()[1].content)
    assert.are.equal("beta reply", beta:get_session():messages()[2].content[1].text)
    assert.are.equal(alpha_model, alpha:get_model())
    assert.are.equal(beta_model, beta:get_model())
    assert.is_true(views[1].result.ok)
    assert.is_true(views[2].result.ok)

    alpha:close()
    assert.is_false(views[1]:is_open())
    assert.is_true(views[2]:is_open())
    alpha:destroy()
    assert.is_true(views[1].destroyed)
    assert.is_false(views[2].destroyed)
  end)

  it("keeps multiple bundled floating views independent", function()
    local alpha = neoagent.new(options("alpha", fake_model.new({})))
    local beta = neoagent.new(options("beta", fake_model.new({})))
    controllers = { alpha, beta }
    assert(alpha:open())
    assert(beta:open())

    local alpha_view = alpha:_state().view
    local beta_view = beta:_state().view
    assert.are_not.equal(alpha_view.transcript_buf, beta_view.transcript_buf)
    assert.are_not.equal(alpha_view.input_buf, beta_view.input_buf)
    assert.is_true(alpha_view:is_open())
    assert.is_true(beta_view:is_open())
    assert.matches("^alpha ·", alpha_view:_title())
    assert.matches("^beta ·", beta_view:_title())

    alpha:close()
    assert.is_false(alpha_view:is_open())
    assert.is_true(beta_view:is_open())
  end)

  it("replaces the command-facing default without consuming the old instance", function()
    local old_views, new_views = {}, {}
    local old = neoagent.setup(options("old", fake_model.new({}), old_views))
    local replacement = neoagent.new(options("new", fake_model.new({}), new_views))
    controllers = { old, replacement }

    assert.are.equal(old, neoagent.default())
    assert.are.equal(old, neoagent.set_default(replacement))
    assert.are.equal(replacement, neoagent.default())
    assert.are.equal("new", require("neoagent.config").get().name)
    assert(neoagent.open())
    assert.is_true(new_views[1]:is_open())
    assert(old:open())
    assert.is_true(old_views[1]:is_open())
    neoagent.close()
    assert.is_false(new_views[1]:is_open())
    assert.is_true(old_views[1]:is_open())
    assert.has_error(function() neoagent.set_default({}) end)

    local latest_views = {}
    local latest = neoagent.setup(options("latest", fake_model.new({}), latest_views))
    controllers[#controllers + 1] = latest
    assert.are.equal(latest, neoagent.default())
    assert.is_true(new_views[1].destroyed)
    assert.is_false(old_views[1].destroyed)
  end)
end)
