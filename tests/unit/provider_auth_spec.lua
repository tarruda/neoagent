local auth = require("neoagent.auth")
local config = require("neoagent.config")

describe("neoagent provider auth metadata", function()
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

  local function store(credential)
    return {
      read = function() return credential end,
      write = function() return true end,
    }
  end

  local function method(public_metadata)
    return {
      type = "api_key",
      name = "Test",
      login = function() return {
        ok = true,
        credential = { type = "api_key", key = "key" },
      } end,
      request_opts = function(credential)
        return { headers = { Authorization = "Bearer " .. credential.key } }
      end,
      public_metadata = public_metadata,
    }
  end

  before_each(function() config._reset() end)
  after_each(function() config._reset() end)

  it("exposes validated public metadata from resolved credentials", function()
    local manager = auth.new({
      methods = { test = method(function(credential)
        return { server_url = credential.env.LLAMA_BASE_URL }
      end) },
      store = store({
        type = "api_key",
        key = "key",
        env = { LLAMA_BASE_URL = "http://127.0.0.1:8080" },
      }),
    })
    local result = wait(manager:resolve("test"))
    assert.is_true(result.ok)
    assert.are.same({ server_url = "http://127.0.0.1:8080" }, result.metadata)
    assert.is_nil(result.metadata.key)
  end)

  it("accepts absent public_metadata", function()
    local manager = auth.new({
      methods = { test = method(nil) },
      store = store({ type = "api_key", key = "key" }),
    })
    local result = wait(manager:resolve("test"))
    assert.is_true(result.ok)
    assert.is_nil(result.metadata)
  end)

  it("preserves timeout introspection through Model wrapping", function()
    local manager = auth.new({
      methods = { test = method(nil) },
      store = store({ type = "api_key", key = "key" }),
    })
    local model = {
      api = "fake",
      provider = "fake",
      id = "test",
      input = { "text" },
      timeout_ms = 45000,
      stream = function() end,
    }
    local wrapped = manager:wrap(model, "test")
    assert.are.equal(45000, wrapped.timeout_ms)
  end)

  it("rejects unsafe or malformed public metadata", function()
    local cases = {
      function() return {} end,
      function() return { key = "x" } end,
      function() return { [""] = "x" } end,
      function() return { server_token = "x" } end,
      function() return { authorization = "x" } end,
      function() return { secret = "x" } end,
      function() return { server_url = 1 } end,
      function() return { server_url = "" } end,
      function() return { server_url = string.rep("x", 513) } end,
      function() return { server_url = "bad\0value" } end,
      function() return { server_url = "\255" } end,
      function() error("metadata boom") end,
    }
    for _, public_metadata in ipairs(cases) do
      local manager = auth.new({
        methods = { test = method(public_metadata) },
        store = store({ type = "api_key", key = "key" }),
      })
      local result = wait(manager:resolve("test"))
      assert.is_false(result.ok)
      assert.are.equal("auth", result.error.kind)
    end
  end)

  it("validates metadata callbacks in configured auth methods", function()
    config.setup({
      default_registry = false,
      providers = {},
      auth = {
        path = "/tmp/auth.json",
        methods = {
          valid = method(function() return { server_url = "http://localhost" } end),
        },
      },
    })
    assert.is_true(true)
    assert.has_error(function()
      config.setup({
        default_registry = false,
        providers = {},
        auth = {
          path = "/tmp/auth.json",
          methods = { invalid = method("not a function") },
        },
      })
    end)
    assert.has_error(function()
      local invalid = method(nil)
      invalid.cache_identity = "not a function"
      config.setup({
        default_registry = false,
        providers = {},
        auth = {
          path = "/tmp/auth.json",
          methods = { invalid = invalid },
        },
      })
    end)
  end)
end)
