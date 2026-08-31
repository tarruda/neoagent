local auth = require("neoagent.providers.llama.auth")
local fake_transport = require("tests.helpers.fake_transport")

describe("neoagent llama.cpp auth", function()
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

  local function patch_client(transport)
    local client = require("neoagent.providers.llama.client")
    local original_new = client.new
    local seen = {}
    client.new = function(opts)
      opts.transport = transport
      seen[#seen + 1] = {
        server_url = opts.server_url,
        api_key = opts.api_key,
      }
      return original_new(opts)
    end
    return seen, function() client.new = original_new end
  end

  it("logs in without an API key when the server accepts anonymous access", function()
    local original_url = vim.env.LLAMA_BASE_URL
    vim.env.LLAMA_BASE_URL = nil
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({ data = {} }) } }
    local seen, restore = patch_client(transport)
    local method = auth.new()
    local prompts = {
      { type = "text", value = "" },
    }
    local result = wait(method.login({
      prompt = function(prompt, done)
        local next = table.remove(prompts, 1)
        assert(next, "unexpected prompt: " .. tostring(prompt.type))
        assert.are.equal(next.type, prompt.type)
        done.resolve(next.value)
        return function() end
      end,
    }))
    restore()
    vim.env.LLAMA_BASE_URL = original_url

    assert.is_true(result.ok)
    assert.are.equal("api_key", result.credential.type)
    assert.are.equal("anonymous", result.credential.key)
    assert.are.equal("1", result.credential.env.LLAMA_ANONYMOUS)
    assert.are.equal("http://127.0.0.1:8080", result.credential.env.LLAMA_BASE_URL)
    assert.are.equal("http://127.0.0.1:8080", seen[1].server_url)
    assert.is_nil(seen[1].api_key)
    assert.are.equal(1, #seen)
  end)

  it("requests a key when the server rejects anonymous access", function()
    local original_url = vim.env.LLAMA_BASE_URL
    vim.env.LLAMA_BASE_URL = nil
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 401, body = vim.json.encode({ error = { message = "unauthorized" } }) },
      { body = vim.json.encode({ data = {} }) },
    }
    local seen, restore = patch_client(transport)
    local method = auth.new()
    local prompts = {
      { type = "text", value = "http://127.0.0.1:8080" },
      { type = "secret", value = "key" },
    }
    local result = wait(method.login({
      prompt = function(prompt, done)
        local next = table.remove(prompts, 1)
        assert(next, "unexpected prompt: " .. tostring(prompt.type))
        assert.are.equal(next.type, prompt.type)
        done.resolve(next.value)
        return function() end
      end,
    }))
    restore()
    vim.env.LLAMA_BASE_URL = original_url

    assert.is_true(result.ok)
    assert.are.equal("key", result.credential.key)
    assert.is_nil(seen[1].api_key)
    assert.are.equal("key", seen[2].api_key)
    assert.are.equal(2, #seen)
  end)

  it("propagates server failures and empty key entries", function()
    local original_url = vim.env.LLAMA_BASE_URL
    vim.env.LLAMA_BASE_URL = nil
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = { { id = 1 } } }) },
    }
    local seen, restore = patch_client(transport)
    local method = auth.new()
    local result = wait(method.login({
      prompt = function(prompt, done)
        done.resolve("http://127.0.0.1:8080")
        return function() end
      end,
    }))
    restore()
    assert.is_false(result.ok)
    assert.matches("router mode", result.error.message)

    transport = fake_transport.new()
    transport.fetches = {
      { status = 401, body = vim.json.encode({ error = { message = "unauthorized" } }) },
    }
    seen, restore = patch_client(transport)
    result = wait(method.login({
      prompt = function(prompt, done)
        if prompt.type == "secret" then
          done.resolve("")
        else
          done.resolve("http://127.0.0.1:8080")
        end
        return function() end
      end,
    }))
    restore()
    vim.env.LLAMA_BASE_URL = original_url
    assert.is_false(result.ok)
    assert.matches("API key is required", result.error.message)

    local llama_client = require("neoagent.providers.llama.client")
    local original_new = llama_client.new
    llama_client.new = function()
      return {
        list = function()
          return require("neoagent.async").run(function()
            return { ok = false }
          end)
        end,
      }
    end
    local ok, fallback = pcall(function()
      return wait(method.login({
        prompt = function(_, done)
          done.resolve("http://127.0.0.1:8080")
          return function() end
        end,
      }))
    end)
    llama_client.new = original_new
    assert(ok, fallback)
    assert.is_false(fallback.ok)
    assert.matches("server check failed", fallback.error.message)
  end)

  it("derives request options and public metadata", function()
    local method = auth.new()
    local request_opts = method.request_opts({
      type = "api_key",
      key = "key",
      env = { LLAMA_BASE_URL = "http://127.0.0.1:8080" },
    })
    assert.are.equal("http://127.0.0.1:8080/v1/chat/completions", request_opts.url)
    assert.are.equal("Bearer key", request_opts.headers.Authorization)
    local anonymous = method.request_opts({
      type = "api_key",
      key = "anonymous",
      env = {
        LLAMA_BASE_URL = "http://127.0.0.1:8080",
        LLAMA_ANONYMOUS = "1",
      },
    })
    assert.are.equal("http://127.0.0.1:8080/v1/chat/completions", anonymous.url)
    assert.is_nil(anonymous.headers)
    assert.are.same({ server_url = "http://127.0.0.1:8080" },
      method.public_metadata({
        type = "api_key",
        key = "key",
        env = { LLAMA_BASE_URL = "http://127.0.0.1:8080" },
      }))
    assert.is_nil(method.public_metadata({ type = "api_key", key = "key" }))
  end)
end)
