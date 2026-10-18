local assert = require("luassert")
local fake_model = require("tests.helpers.fake_model")
local util = require("neoagent.util")

describe("draft composition publication", function()
  ---@type Neoagent.NeoagentApplet?
  local owner
  ---@type string[]
  local paths = {}

  after_each(function()
    if owner then
      owner:destroy()
    end
    owner = nil
    for _, path in ipairs(paths) do
      vim.fn.delete(path, "rf")
    end
    paths = {}
  end)

  ---@param extra? Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
  ---@return Neoagent.NeoagentApplet, Neoagent.TestModel
  local function setup(extra)
    local model = fake_model.new({
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
      { result = fake_model.assistant({ { type = "text", text = "checkpoint" } }) },
    })
    ---@type Neoagent.ConfigInput<Neoagent.AgentToolEnvironment>
    local options = {
      default_registry = false,
      workspace_trust = false,
      sandbox = { enabled = false },
      persistence = { enabled = false },
      recording = { enabled = false },
      agent_instructions = false,
      skills = false,
      tools = {},
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      _apis = {
        ["fake-api"] = function(resolved)
          model.api, model.provider, model.id = resolved.api, resolved.provider_id, resolved.model_id
          return model
        end,
      },
      ui = { images = false, position = "center" },
    }
    if extra then
      options = require("neoagent.config").merge_agent_options(options, extra)
    end
    owner = require("neoagent").setup(options)
    return owner, model
  end

  ---@return string
  local function directory()
    local path = vim.fn.tempname()
    paths[#paths + 1] = path
    return path
  end

  ---@param draft Neoagent.AgentApplet
  ---@return Neoagent.Agent
  local function submit(draft)
    local run = draft:send("remember this")
    assert(run)
    assert(type(run) == "table")
    assert(vim.wait(2000, function()
      return run:is_done()
    end))
    assert.is_true(assert(run:result()).ok)
    return (assert(draft:agent()))
  end

  ---@param applet Neoagent.NeoagentApplet
  ---@return Neoagent.AgentApplet, Neoagent.View
  local function open(applet)
    assert(applet:open())
    local draft = applet:foreground_applet()
    assert(draft)
    local view = applet:view()
    assert(view)
    return draft, view
  end

  it("applies accepted UI settings to the open input and transcript", function()
    local applet = setup({ ui = { completion = true, show_thinking = true, mappings = { submit = "<C-s>" } } })
    local draft, view = open(applet)
    view:set_input("keep this draft")
    assert(applet:update_draft_options({
      ui = {
        completion = false,
        show_thinking = false,
        mappings = { submit = "<F6>" },
      },
    }, draft))
    local keys = {}
    for _, binding in ipairs(view.input:mapping_bindings()) do
      keys[binding.lhs] = true
    end
    assert.is_true(keys["<F6>"])
    assert.is_nil(keys["<C-s>"])
    assert.is_false(view.input.state.completion)
    assert.is_false(view.transcript.config.show_thinking)
    assert.are.equal("keep this draft", view:get_input())
  end)

  it("retains direct draft position and style edits through recomposition", function()
    local applet = setup()
    local draft, view = open(applet)
    assert(draft:set_position("left"))
    assert(draft:set_transcript_style("codex"))
    assert(applet:update_draft_options({ system_prompt = "ordinary edit" }, draft))
    assert.are.equal("left", draft.position)
    assert.are.equal("left", view.position)
    assert.are.equal("codex", draft.transcript_style)
    assert.are.equal(require("neoagent.ui.renderers").get("codex"), view.renderer)
    assert.are.same({ position = "left", style = "codex" }, assert(applet:get_draft_options(draft)).ui)
  end)

  it("updates the View-owned image system with the draft configuration", function()
    local applet = setup()
    local draft, view = open(applet)
    assert.is_nil(view.image_system)
    assert(applet:update_draft_options({ ui = { images = { backend = "kitty", display = "always" } } }, draft))
    local images = assert(view.image_system, "accepted image configuration must create an image system")
    assert.are.equal(images, view.transcript.image_system)
    assert.are.equal(images, view.transcript.pane.image_system)
    assert(applet:update_draft_options({ ui = { images = false } }, draft))
    assert.is_true(images.destroyed)
    assert.is_nil(view.image_system)
    assert.is_nil(view.transcript.image_system)
    assert.is_nil(view.transcript.pane.image_system)
  end)

  it("restores the whole View when draft publication fails", function()
    local applet = setup({ ui = { completion = true, mappings = { submit = "<C-s>" } } })
    local draft, view = open(applet)
    local previous_context = util.copy(view.context)
    local previous_renderer = view.renderer
    ---@type fun(self: Neoagent.View, context?: Neoagent.AgentContext)
    local set_context = view.set_context
    local reject = true
    function view:set_context(context)
      set_context(self, context)
      if reject then
        reject = false
        error("publication rejected", 0)
      end
    end
    local updated, err = applet:update_draft_options({
      ui = {
        completion = false,
        mappings = { submit = "<F6>" },
        style = "codex",
        position = "right",
        images = { backend = "kitty", display = "always" },
      },
    }, draft)
    function view:set_context(context)
      set_context(self, context)
    end
    assert.is_nil(updated)
    assert.matches("publication rejected", assert(err).message)
    assert.are.equal(previous_renderer, view.renderer)
    assert.are.same(previous_context, view.context)
    assert.are.equal("center", view.position)
    assert.is_true(view.input.state.completion)
    assert.are.equal("<C-s>", assert(view.input.config.mappings).submit)
    assert.is_nil(view.image_system)
    assert.is_nil(view.transcript.pane.image_system)
    assert.is_nil(assert(applet:get_draft_options(draft)).ui)
  end)

  it("recreates the accepted View when restoration also fails", function()
    local applet = setup({ ui = { completion = true, show_thinking = true } })
    local draft, view = open(applet)
    view:set_input("keep this unsent input")
    assert(applet:select_model())
    local picker = assert(draft:presenter():snapshot().active).id
    ---@type fun(self: Neoagent.InputPane, configured?: Neoagent.UIConfigInput)
    local set_config = view.input.set_config
    ---@type fun(self: Neoagent.View, context?: Neoagent.AgentContext)
    local set_context = view.set_context
    local calls = 0
    function view.input:set_config(configured)
      calls = calls + 1
      if calls == 2 then
        error("restoration rejected", 0)
      end
      return set_config(self, configured)
    end
    function view:set_context(context)
      set_context(self, context)
      error("publication rejected", 0)
    end
    local updated, err = applet:update_draft_options({
      ui = { completion = false, show_thinking = false },
    }, draft)
    function view.input:set_config(configured)
      set_config(self, configured)
    end
    function view:set_context(context)
      set_context(self, context)
    end
    assert.is_nil(updated)
    assert.matches("publication rejected", assert(err).message)
    assert.is_true(view.destroyed)
    local replacement = applet:view()
    assert(replacement)
    assert.are_not.equal(view, replacement)
    assert.is_true(replacement:is_open())
    assert.is_true(replacement.input.state.completion)
    assert.is_true(replacement.transcript.config.show_thinking)
    assert.are.equal("keep this unsent input", replacement:get_input())
    assert.are.equal(picker, assert(draft:presenter():snapshot().active).id)
    assert.is_nil(assert(applet:get_draft_options(draft)).ui)
  end)

  for _, failure in ipairs({ "construction", "opening", "disposal" }) do
    it("retains accepted input after View recovery fails during " .. failure, function()
      local builds = 0
      ---@type Neoagent.View?
      local rejected
      local applet = setup({ _view = function(options)
        builds = builds + 1
        if builds == 2 and failure == "construction" then
          error("reconstruction rejected", 0)
        end
        local created = require("neoagent.ui").new(options)
        if builds == 2 then
          rejected = created
          created.open = function()
            return nil, util.error("ui", "reconstruction rejected")
          end
          if failure == "disposal" then
            ---@type fun(self: Neoagent.View)
            local destroy = created.destroy
            function created:destroy()
              destroy(self)
              error("disposal rejected", 0)
            end
          end
        end
        return created
      end })
      local draft, view = open(applet)
      view:set_input("survive unavailable presentation")
      ---@type fun(self: Neoagent.InputPane, configured?: Neoagent.UIConfigInput)
      local set_config = view.input.set_config
      ---@type fun(self: Neoagent.View, context?: Neoagent.AgentContext)
      local set_context = view.set_context
      local calls = 0
      function view.input:set_config(configured)
        calls = calls + 1
        if calls == 2 then
          error("restoration rejected", 0)
        end
        return set_config(self, configured)
      end
      view.set_context = function()
        error("publication rejected", 0)
      end
      local updated, err = applet:update_draft_options({ ui = { completion = false } }, draft)
      function view.input:set_config(configured)
        set_config(self, configured)
      end
      function view:set_context(context)
        set_context(self, context)
      end
      assert.is_nil(updated)
      assert.matches("publication rejected", assert(err).message)
      assert.matches("reconstruction rejected", vim.inspect(err))
      assert.is_true(view.destroyed)
      if rejected then
        assert.is_true(rejected.destroyed)
      end
      if failure == "disposal" then
        assert.matches("disposal rejected", vim.inspect(err))
      end
      assert.is_nil(applet:view())
      assert.are.equal("survive unavailable presentation", draft:get_input())
      assert.is_nil(assert(applet:get_draft_options(draft)).ui)
      assert(applet:open())
      assert.are.equal(3, builds)
      assert.are.equal("survive unavailable presentation", assert(applet:view()):get_input())
    end)
  end

  it("persists an explicitly pinned automatic draft under its Profile", function()
    local path = directory()
    local applet = setup({ persistence = { enabled = true, workspace_settings = true, directory = path } })
    local automatic = applet:draft()
    assert(automatic)
    local pinned = applet:draft("neo")
    assert(pinned)
    assert.are.equal(automatic, pinned)
    submit(pinned)
    local settings = require("neoagent.workspace_settings").new({ directory = path, root = vim.fn.getcwd() })
    local stored = assert(settings:load())
    assert.are.same({ provider = "fake", model = "test" }, assert(stored.agents.neo).default_model)
    assert.is_nil(stored.default_model)
  end)

  it("creates the Session from the draft's accepted persistence settings", function()
    local path = directory()
    local applet = setup({ persistence = { enabled = true, workspace_settings = true, directory = path } })
    local draft = applet:draft("neo")
    assert(draft)
    assert(applet:update_draft_options({ persistence = { enabled = false } }, draft))
    local agent = submit(draft)
    assert.is_false(agent:config().persistence.enabled)
    local metadata = agent:get_session():metadata()
    assert(metadata)
    assert.is_false(metadata.persisted)
    assert.is_nil(metadata.path)
    local history = require("neoagent.input_history").new({ directory = path, root = vim.fn.getcwd() })
    assert.are.same({}, history:load())
  end)

  it("enables Session and input persistence in the selected draft directory", function()
    local applet = setup()
    local draft = applet:draft("neo")
    assert(draft)
    local path = directory()
    assert(applet:update_draft_options({ persistence = { enabled = true, directory = path } }, draft))
    local agent = submit(draft)
    local metadata = agent:get_session():metadata()
    assert(metadata)
    assert.is_true(metadata.persisted)
    assert.are.equal(1, vim.fn.filereadable((assert(metadata.path))))
    local history = require("neoagent.input_history").new({ directory = path, root = vim.fn.getcwd() })
    assert.are.same({ "remember this" }, history:load())
  end)

end)
