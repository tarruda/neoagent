local Applet = require("applet")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function neoagent_sources()
  return vim.fn.glob(root .. "/lua/neoagent/**/*.lua", false, true)
end

describe("Applet consumer boundary", function()
  it("keeps headless Agent construction outside rendering modules", function()
    local auth = {
      resolve = function() end,
      login = function() end,
      logout = function() end,
    }
    local agent = require("neoagent").new({
      workspace_trust = false,
      default_registry = false,
      persistence = { enabled = false },
      tools = {},
      agent_instructions = false,
      skills = false,
    }, { auth = auth, runtimes = {} })
    local rendering_modules = {
      "neoagent.applet",
      "neoagent.agent_applet",
      "neoagent.ui.renderers",
      "applet.applet",
      "applet.pane",
      "applet.layout",
      "applet.image",
    }
    local loaded = {}
    for _, name in ipairs(rendering_modules) do
      loaded[name] = package.loaded[name] ~= nil
    end
    agent:destroy()
    for _, name in ipairs(rendering_modules) do
      assert.is_false(loaded[name],
        name .. " loaded during headless construction")
    end
  end)

  it("publishes concrete Applet values from one module", function()
    assert.are.equal("function", type(Applet.new))
    assert.are.equal("function", type(Applet.Pane.new))
    assert.are.equal("function", type(Applet.ImageSystem.png_info))
  end)

  it("keeps Neoagent on the documented Applet surface", function()
    local forbidden = {
      "[%a_][%w_]*%.surface%f[^%w_]",
      "[%a_][%w_]*%.buffer_mode%f[^%w_]",
      "[%a_][%w_]*%.namespace%f[^%w_]",
      "[%a_][%w_]*%.focus_namespace%f[^%w_]",
      "[%a_][%w_]*%.committed_generation%f[^%w_]",
      "%.pane%.layout",
      "%.pane%.generation",
      "%.applet%.domain",
      "%.applet%.destroyed",
    }
    for _, path in ipairs(neoagent_sources()) do
      local source = table.concat(vim.fn.readfile(path), "\n")
      assert.is_nil(source:match("require%s*%(%s*['\"]applet%."), path)
      for _, pattern in ipairs(forbidden) do
        assert.is_nil(source:match(pattern), path .. " reads " .. pattern)
      end
    end
  end)
end)
