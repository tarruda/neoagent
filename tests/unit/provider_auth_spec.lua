local assert = require("luassert")
local auth = require("neoagent.auth")
local async = require("neoagent.async")
local fake_model = require("tests.helpers.fake_model")
local config = require("neoagent.config")

describe("neoagent provider auth metadata", function()
  ---@generic T, E
  ---@param run Neoagent.Run<T, E>
  ---@return Neoagent.RunResult<T>
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return (assert(run:result()))
  end

  ---@param credential Neoagent.Credential
  ---@return Neoagent.AuthStorage
  local function store(credential)
    return {
      read = function() return credential end,
      write = function() return true end,
    }
  end

  ---@param public_metadata? fun(credential: Neoagent.Credential): table<string, string>?
  ---@return Neoagent.AuthMethod<Neoagent.Credential> & Neoagent.AuthMethodInput<Neoagent.Credential>
  local function method(public_metadata)
    return {
      type = "api_key",
      name = "Test",
      login = function()
        return async.run(function()
          return { ok = true, credential = { type = "api_key", key = "key" } }
        end)
      end,
      request_opts = function(credential)
        assert(credential.type == "api_key")
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
        assert(credential.type == "api_key")
        return { server_url = assert(credential.env).LLAMA_BASE_URL }
      end) },
      store = store({
        type = "api_key",
        key = "key",
        env = { LLAMA_BASE_URL = "http://127.0.0.1:8080" },
      }),
    })
    local result = wait(manager:resolve("test"))
    assert(result.ok and result.configured)
    assert.are.same({ server_url = "http://127.0.0.1:8080" }, result.metadata)
    assert.is_nil(assert(result.metadata).key)
  end)

  it("accepts absent public_metadata", function()
    local manager = auth.new({
      methods = { test = method(nil) },
      store = store({ type = "api_key", key = "key" }),
    })
    local result = wait(manager:resolve("test"))
    assert(result.ok and result.configured)
    assert.is_nil(result.metadata)
  end)

  it("preserves timeout introspection through Model wrapping", function()
    local manager = auth.new({
      methods = { test = method(nil) },
      store = store({ type = "api_key", key = "key" }),
    })
    local model = fake_model.new()
    model.timeout_ms = 45000
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
        methods = { test = method(public_metadata --[[@as fun(credential: Neoagent.Credential): table<string, string>?]]) },
        store = store({ type = "api_key", key = "key" }),
      })
      local result = wait(manager:resolve("test"))
      assert.is_false(result.ok)
      assert.are.equal("auth", assert(result.error).kind)
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
    assert.has_error(function()
      config.setup({
        default_registry = false,
        providers = {},
        auth = {
          path = "/tmp/auth.json",
          methods = { invalid = method("not a function" --[[@as fun(credential: Neoagent.Credential): table<string, string>?]]) },
        },
      })
    end)
    assert.has_error(function()
      local invalid = method(nil)
      rawset(invalid, "cache_identity", "not a function")
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

  it("rejects non-string authentication method queries", function()
    local provider_auth = require("neoagent.provider_auth")
    assert.is_false(provider_auth.uses({ auth = "primary" }, {}))
    assert.is_true(provider_auth.uses({
      auth = "primary", auth_scopes = { dashboard = "secondary" },
    }, "secondary"))
  end)
end)
