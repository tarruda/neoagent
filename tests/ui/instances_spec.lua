local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")

describe("neoagent controller windows", function()
  local neoagent
  local controllers
  local windows
  local paths

  before_each(function()
    package.loaded["neoagent"] = nil
    neoagent = require("neoagent")
    controllers, windows, paths = {}, {}, {}
  end)

  after_each(function()
    for _, window in ipairs(windows) do window:destroy() end
    for _, controller in ipairs(controllers) do controller:destroy() end
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
  end)

  local function options(name, model, extra)
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
      ui = { position = "center" },
    }
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
  end

  local function delayed_model(name, pending)
    local model = { api = "fake", provider = "fake", id = name }
    function model:stream(opts)
      return async.run(function(run)
        run:emit({ type = "text_delta", text = name .. " partial" })
        local text = async.await(function(done)
          pending[name] = {
            resolve = function(value)
              run:emit({ type = "text_delta", text = " reply" })
              done.resolve(value)
            end,
          }
          return function() end
        end)
        return fake_model.assistant({ { type = "text", text = text } })
      end, { on_event = opts.on_event, on_done = opts.on_done, error_kind = "model" })
    end
    return model
  end

  local function transcript(view)
    return table.concat(vim.api.nvim_buf_get_lines(view.transcript_buf, 0, -1, false), "\n")
  end

  it("constructs the command-facing Controller and Window lazily", function()
    local controller = neoagent.default()
    local window = neoagent.default_window()
    controllers = window:controllers()
    windows = { window }
    assert.are.equal(controller, window:active())
    assert.are.equal(2, #controllers)
    assert.are.equal("Neo", controllers[1]:config().name)
    assert.are.equal("Chat", controllers[2]:config().name)
    assert.is_nil(controllers[1]:get_session())
    assert.is_nil(controllers[2]:get_session())
  end)

  it("requires unique Controller names in a Window", function()
    local unnamed_options = options("unnamed", fake_model.new({}))
    unnamed_options.name = nil
    local unnamed = neoagent.new(unnamed_options)
    local first = neoagent.new(options("same", fake_model.new({})))
    local second = neoagent.new(options("same", fake_model.new({})))
    controllers = { unnamed, first, second }

    assert.has_error(function() neoagent.new_window({ controllers = { unnamed } }) end)
    assert.has_error(function() neoagent.new_window({ controllers = { first, second } }) end)
  end)

  it("reports Controller preparation failures before opening its View", function()
    local controller = neoagent.new(options("missing", fake_model.new({}), {
      default_model = { provider = "absent", model = "missing" },
    }))
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    local opened, err = window:open()
    assert.is_nil(opened)
    assert.are.equal("controller", err.kind)
    assert.is_false(window:is_open())
    assert.is_nil(controller:get_session())
    window:destroy()
    opened, err = window:open()
    assert.is_nil(opened)
    assert.are.equal("Window is destroyed", err.message)
  end)

  it("uses one View and restores each Controller draft", function()
    local alpha = neoagent.new(options("alpha", fake_model.new({})))
    local beta = neoagent.new(options("beta", fake_model.new({})))
    controllers = { alpha, beta }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }

    assert(window:open())
    local view = window:_state().view
    local transcript_buffer, input_buffer = view.transcript_buf, view.input_buf
    view:set_input("alpha draft")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<M-n>", true, false, true), "x", false)
    assert(vim.wait(1000, function() return window:active() == beta end))
    assert.are.equal("", view:get_input())
    assert.matches("^beta ·", view:_title())
    view:set_input("beta draft")
    assert.are.equal(alpha, window:cycle())
    assert.are.equal("alpha draft", view:get_input())
    assert.are.equal(transcript_buffer, view.transcript_buf)
    assert.are.equal(input_buffer, view.input_buf)
    assert.are.equal(beta, window:select(beta))
    assert.are.equal("beta draft", view:get_input())
    view:close()
    assert(window:open())
    assert.are.equal("beta draft", view:get_input())
    assert.has_error(function() window:select({}) end)
  end)

  it("drives a custom passive View through Controller updates", function()
    local created
    local function view_factory(opts)
      local view = {
        input = "", messages = {}, context = {}, events = {}, opened = false,
        window = opts.window, on_submit = opts.on_submit,
      }
      function view:open() self.opened = true return true end
      function view:close() self.opened = false end
      function view:is_open() return self.opened end
      function view:destroy() self:close() self.destroyed = true end
      function view:get_input() return self.input end
      function view:set_input(value) self.input = value end
      function view:set_messages(value) self.messages = value end
      function view:set_context(value) self.context = value end
      function view:apply(value) self.events[#self.events + 1] = value end
      function view:finish(value) self.result = value end
      created = view
      return view
    end
    local model = fake_model.new({ {
      events = { { type = "text_delta", text = "custom" } },
      result = fake_model.assistant({ { type = "text", text = "custom" } }),
    } })
    local controller = neoagent.new(options("custom", model, { view = view_factory }))
    controllers = { controller }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    assert.are.equal(window, created.window)
    created:set_input("question")
    local run = assert(created.on_submit(created:get_input()))
    assert(vim.wait(1000, function() return run:is_done() and created.result end))
    assert.are.equal("", created:get_input())
    assert.are.equal("question", created.messages[1].content)
    assert.are.equal("text_delta", created.events[1].type)
    assert.is_true(created.result.ok)
  end)

  it("keeps independent runs alive while their shared Window switches", function()
    local pending = {}
    local alpha = neoagent.new(options("alpha", delayed_model("alpha", pending)))
    local beta = neoagent.new(options("beta", delayed_model("beta", pending)))
    controllers = { alpha, beta }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    local view = window:_state().view

    view:set_input("for alpha")
    local alpha_run = assert(view.on_submit(view:get_input()))
    assert.are.equal(beta, window:cycle())
    view:set_input("for beta")
    local beta_run = assert(view.on_submit(view:get_input()))
    assert.is_true(alpha:is_running())
    assert.is_true(beta:is_running())
    assert(vim.wait(1000, function() return pending.alpha and pending.beta end))
    assert.are.equal(alpha, window:cycle())
    assert(vim.wait(1000, function()
      return transcript(view):find("alpha partial", 1, true) ~= nil
    end))
    assert.are.equal(beta, window:cycle())
    pending.alpha.resolve("alpha reply")
    assert(vim.wait(1000, function() return alpha_run:is_done() end))
    assert.is_nil(transcript(view):find("alpha reply", 1, true))
    pending.beta.resolve("beta reply")
    assert(vim.wait(1000, function() return beta_run:is_done() end))
    assert(vim.wait(1000, function()
      return transcript(view):find("beta partial reply", 1, true) ~= nil
    end))

    assert.are.equal(alpha, window:cycle())
    assert(vim.wait(1000, function() return transcript(view):find("alpha reply", 1, true) ~= nil end))
    assert.are.equal("for alpha", alpha:get_session():messages()[1].content)
    assert.are.equal("for beta", beta:get_session():messages()[1].content)
  end)

  it("persists one lazily-created Session for each Controller", function()
    local directory = vim.fn.tempname()
    paths = { directory }
    local extra = { persistence = { enabled = true, directory = directory } }
    local alpha = neoagent.new(options("alpha", fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "a" } }),
    } }), extra))
    local beta = neoagent.new(options("beta", fake_model.new({ {
      result = fake_model.assistant({ { type = "text", text = "b" } }),
    } }), extra))
    controllers = { alpha, beta }
    local window = neoagent.new_window({ controllers = controllers })
    windows = { window }
    assert(window:open())
    assert.is_nil(alpha:get_session())
    assert.is_nil(beta:get_session())
    assert.is_nil(vim.uv.fs_stat(directory))

    local alpha_run = assert(alpha:send("alpha"))
    window:cycle()
    assert.is_nil(beta:get_session())
    local beta_run = assert(beta:send("beta"))
    assert(vim.wait(1000, function() return alpha_run:is_done() and beta_run:is_done() end))
    assert.are.equal(2, #require("neoagent.storage").list(directory, vim.fn.getcwd()))
    local alpha_path = alpha:get_session():metadata().path
    assert(beta:resume(alpha_path))
    assert.are.equal("alpha", beta:get_session():messages()[1].content)
  end)

  it("routes the command-facing default through a replaceable Window", function()
    local old = neoagent.setup(options("old", fake_model.new({})))
    local old_window = neoagent.default_window()
    local replacement = neoagent.new(options("new", fake_model.new({})))
    controllers = old_window:controllers()
    controllers[#controllers + 1] = replacement
    local window = neoagent.new_window({ controllers = { old, replacement } })
    windows = { window }

    assert.are.equal(old, neoagent.default())
    local previous_window = neoagent.set_default_window(window)
    windows[#windows + 1] = previous_window
    assert.are.equal(old, neoagent.default())
    assert.are.equal(replacement, neoagent.select_agent(2))
    assert.are.equal(replacement, neoagent.default())
    assert(neoagent.open())
    assert.is_true(window:is_open())
    assert.are.equal(replacement, neoagent.set_default(old))
    windows[#windows + 1] = neoagent.default_window()
    assert.are.equal(old, neoagent.default())
    assert.has_error(function() neoagent.set_default({}) end)
    assert.has_error(function() neoagent.set_default_window({}) end)
  end)
end)
