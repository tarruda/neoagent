local fs = require("neoagent.fs")

describe("neoagent health", function()
  local original_health
  local original_path
  local original_tmux
  local original_term
  local roots = {}
  local messages

  local function contains(values, pattern)
    for _, value in ipairs(values) do
      if value:match(pattern) then return true end
    end
    return false
  end

  before_each(function()
    original_health = vim.health
    original_path = vim.env.PATH
    original_tmux = vim.env.TMUX
    original_term = vim.env.TERM
    messages = { ok = {}, error = {}, warn = {}, start = {} }
    vim.health = {}
    for kind in pairs(messages) do
      vim.health[kind] = function(value) messages[kind][#messages[kind] + 1] = value end
    end
    require("neoagent.config")._reset()
  end)

  after_each(function()
    vim.health = original_health
    vim.env.PATH = original_path
    vim.env.TMUX = original_tmux
    vim.env.TERM = original_term
    require("neoagent.config")._reset()
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots = {}
  end)

  it("reports dependency versions and a valid configuration", function()
    require("neoagent.config").setup({ persistence = { enabled = false } })
    require("neoagent.health").check()
    assert.are.same({ "neoagent" }, messages.start)
    assert.is_true(contains(messages.ok, "curl .- satisfies"))
    assert.is_true(contains(messages.ok, "^configuration is valid$"))
  end)

  it("reports Applet-owned image diagnostics", function()
    local ImageSystem = require("applet").ImageSystem
    local diagnostics = ImageSystem.diagnostics
    ImageSystem.diagnostics = function(options)
      assert.are.same({ backend = "kitty" }, options)
      return {
        { level = "ok", message = "applet image backend ready" },
        { level = "warn", message = "applet image warning" },
      }
    end
    local ok, err = pcall(function()
      require("neoagent.config").setup({ persistence = { enabled = false } })
      require("neoagent.health").check()
      assert.is_true(contains(messages.ok, "applet image backend ready"))
      assert.is_true(contains(messages.warn, "applet image warning"))
    end)
    ImageSystem.diagnostics = diagnostics
    assert(ok, err)
  end)

  it("reports an unsupported Neovim and explicitly disabled images", function()
    local original_has = vim.fn.has
    vim.fn.has = function(feature)
      if feature == "nvim-0.10" then return 0 end
      return original_has(feature)
    end
    local ok, err = pcall(function()
      require("neoagent.config").setup({
        persistence = { enabled = false },
        ui = { images = false },
      })
      require("neoagent.health").check()
      assert.is_true(contains(messages.error, "Neovim 0.10 or newer"))
      assert.is_true(contains(messages.ok, "terminal image display is disabled"))
    end)
    vim.fn.has = original_has
    assert(ok, err)
  end)

  it("reports an old curl, missing tools, and an invalid resolved model", function()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    vim.fn.mkdir(root, "p")
    local curl = root .. "/curl"
    assert(fs.write_all(curl, "#!/bin/sh\nprintf 'curl 7.75.0 fake\\n'\n", "w"))
    assert(vim.uv.fs_chmod(curl, 493))
    vim.env.PATH = root
    require("neoagent.config").setup({
      default_model = { provider = "missing", model = "missing" },
      persistence = { enabled = false },
    })
    require("neoagent.health").check()
    assert.is_true(contains(messages.error, "too old"))
    assert.is_true(contains(messages.error, "rg is required"))
    assert.is_true(contains(messages.error, "configuration error"))
  end)

  it("accepts the exact minimum curl version and rejects unknown output", function()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    vim.fn.mkdir(root, "p")
    local curl = root .. "/curl"
    assert(fs.write_all(curl, "#!/bin/sh\nprintf 'curl 7.76.0 exact\\n'\n", "w"))
    assert(vim.uv.fs_chmod(curl, 493))
    vim.env.PATH = root
    require("neoagent.config").setup({ persistence = { enabled = false } })
    require("neoagent.health").check()
    assert.is_true(contains(messages.ok, "curl 7.76.0 satisfies"))

    messages.error = {}
    assert(fs.write_all(curl, "#!/bin/sh\nprintf 'unknown version\\n'\n", "w"))
    require("neoagent.health").check()
    assert.is_true(contains(messages.error, "could not determine"))
  end)

  it("reports tmux image passthrough requirements", function()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    vim.fn.mkdir(root, "p")
    local tmux = root .. "/tmux"
    assert(fs.write_all(tmux, "#!/bin/sh\nprintf 'all\\n'\n", "w"))
    assert(vim.uv.fs_chmod(tmux, 493))
    vim.env.PATH = root
    vim.env.TMUX = "/tmp/tmux"
    vim.env.TERM = "tmux-256color"
    require("neoagent.config").setup({ persistence = { enabled = false } })
    require("neoagent.health").check()
    assert.is_true(contains(messages.ok,
      "tmux passes terminal graphics through every pane"))
    messages.warn = {}
    assert(fs.write_all(tmux, "#!/bin/sh\nprintf 'on\\n'\n", "w"))
    require("neoagent.health").check()
    assert.is_true(contains(messages.warn, "allow%-passthrough all"))
  end)

  it("accepts a default model from a provider catalog seed", function()
    require("neoagent.config").setup({
      default_registry = false,
      default_model = { provider = "dynamic", model = "discovered" },
      persistence = { enabled = false },
      providers = {
        dynamic = {
          api = "fake",
          models = {},
          catalog = {
            seed = { { id = "discovered", context_window = 4096 } },
          },
        },
      },
      _apis = {
        fake = function(resolved)
          return {
            api = resolved.api,
            provider = resolved.provider_id,
            id = resolved.model_id,
            input = resolved.model.input or { "text" },
            context_window = resolved.model.context_window,
            stream = function() end,
          }
        end,
      },
    })
    require("neoagent.health").check()
    assert.is_true(contains(messages.ok, "^configuration is valid$"))
  end)

  it("reports a dynamic default that awaits its first catalog", function()
    require("neoagent.config").setup({
      default_registry = false,
      default_model = { provider = "dynamic", model = "pending" },
      persistence = { enabled = false },
      providers = {
        dynamic = {
          api = "fake",
          models = {},
          catalog = {
            source_id = "dynamic-test-models",
            source_revision = 1,
            discover = function() error("must not run") end,
          },
        },
      },
      _apis = {
        fake = function()
          return { stream = function() end }
        end,
      },
    })
    require("neoagent.health").check()
    assert.is_true(contains(messages.warn,
      "default model dynamic/pending awaits the dynamic provider catalog"))
    assert.is_true(contains(messages.ok, "^configuration is valid$"))
  end)

  it("warns when a usable catalog cannot derive cache identity", function()
    require("neoagent.config").setup({
      default_registry = false,
      providers = {
        dynamic = {
          api = "fake",
          auth = "custom",
          api_key = "ambient-secret",
          models = {},
          catalog = {
            source_id = "dynamic-test-models",
            source_revision = 1,
            account_scoped = true,
            seed = { { id = "seed" } },
            discover = function() error("must not run") end,
          },
        },
      },
      auth = { methods = { custom = {
        name = "Custom",
        type = "api_key",
        login = function() end,
        request_opts = function() return {} end,
      } } },
    })

    require("neoagent.health").check()

    assert.is_true(contains(messages.warn,
      "dynamic model catalog cache is unavailable"))
    assert.is_true(contains(messages.ok, "^configuration is valid$"))
  end)

  it("contains Profile resource construction failures as health diagnostics", function()
    require("neoagent.config").setup({
      default_registry = false,
      persistence = { enabled = false },
      providers = {
        broken = {
          api = "fake",
          models = {},
          service = function() error("service construction exploded") end,
        },
      },
      _apis = {
        fake = function() return { stream = function() end } end,
      },
    })

    local ok, err = pcall(require("neoagent.health").check)

    assert(ok, err)
    assert.is_true(contains(messages.error,
      "Failed to construct provider service for broken"))
  end)
end)
