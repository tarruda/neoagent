local fs = require("neoagent.fs")

describe("neoagent provider storage layout", function()
  local directories = {}
  local resources = {}
  local original_state_home

  local function state_root()
    local directory = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(directory, "p"))
    directory = assert(vim.uv.fs_realpath(directory))
    directories[#directories + 1] = directory
    vim.env.XDG_STATE_HOME = directory
    return fs.join(directory, "nvim", "neoagent")
  end

  local function assert_provider_state(root)
    local path = fs.join(root, "provider", "state")
    assert.are.equal(448, require("bit").band(
      assert(vim.uv.fs_stat(path)).mode, 511))
    assert.is_nil(vim.uv.fs_stat(fs.join(root, "model-catalog")))
  end

  before_each(function()
    original_state_home = vim.env.XDG_STATE_HOME
  end)

  after_each(function()
    for index = #resources, 1, -1 do resources[index]:destroy() end
    for _, directory in ipairs(directories) do vim.fn.delete(directory, "rf") end
    vim.env.XDG_STATE_HOME = original_state_home
    directories, resources = {}, {}
  end)

  it("places bundled and direct Agent state under provider/state", function()
    local bundled_root = state_root()
    local configured = require("neoagent.config").resolve({
      default_registry = false,
      providers = {},
      workspace_trust = false,
      agent_instructions = false,
      skills = false,
    })
    local _, _, bundled = require("neoagent.profiles").bundled(
      configured, { startup = false })
    resources[#resources + 1] = bundled
    assert_provider_state(bundled_root)

    local direct_root = state_root()
    local agent = require("neoagent.agent").new({
      name = "Provider storage layout",
      default_registry = false,
      providers = {},
      persistence = { enabled = false },
      tools = {},
    })
    resources[#resources + 1] = agent
    assert_provider_state(direct_root)
  end)
end)
