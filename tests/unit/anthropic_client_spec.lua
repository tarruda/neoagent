local async = require("neoagent.async")
local client = require("neoagent.providers.anthropic.client")
local fake_transport = require("tests.helpers.fake_transport")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

local function auth(headers)
  return function()
    return async.run(function()
      return {
        ok = true,
        configured = headers ~= nil,
        request_opts = headers and { headers = headers } or nil,
      }
    end)
  end
end

describe("Anthropic management client", function()
  it("loads the paginated-capacity model catalog", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        data = { {
          id = "claude-opus-5",
          type = "model",
          display_name = "Claude Opus 5",
          max_input_tokens = 1000000,
          max_tokens = 128000,
          capabilities = {
            image_input = { supported = true },
            thinking = { supported = true, types = {
              adaptive = { supported = true },
              enabled = { supported = true },
            } },
            effort = {
              supported = true,
              low = { supported = true },
              medium = { supported = true },
              high = { supported = true },
              xhigh = { supported = true },
              max = { supported = false },
            },
          },
        } },
        has_more = true,
        first_id = "claude-opus-5",
        last_id = "claude-opus-5",
      }) },
      { body = vim.json.encode({
        data = { {
          id = "claude-sonnet-5",
          type = "model",
          capabilities = { thinking = { supported = false } },
        } },
        has_more = false,
        first_id = "claude-sonnet-5",
        last_id = "claude-sonnet-5",
      }) },
    }
    local value = client.new({
      base_url = "https://example.test/v1/",
      transport = transport,
      ambient_api_key = function() return nil end,
    })
    local result = wait(value:models({
      resolve_auth = auth({ ["x-api-key"] = "api-key" }),
    }))

    assert.is_true(result.ok)
    assert.are.same({
      {
        id = "claude-opus-5",
        name = "Claude Opus 5",
        input = { "text", "image" },
        context_window = 1000000,
        max_output_tokens = 128000,
        thinking_type = "adaptive",
        reasoning_levels = { "low", "medium", "high", "xhigh" },
      },
      { id = "claude-sonnet-5", thinking_type = false },
    }, result.models)
    assert.are.equal("https://example.test/v1/models?limit=1000",
      transport.fetch_requests[1].url)
    assert.are.equal(
      "https://example.test/v1/models?limit=1000&after_id=claude-opus-5",
      transport.fetch_requests[2].url)
    assert.are.equal("2023-06-01",
      transport.fetch_requests[1].headers["anthropic-version"])
    assert.are.equal("2023-06-01",
      transport.fetch_requests[2].headers["anthropic-version"])
  end)

  it("rejects repeated cursors and duplicate models across pages", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        data = { { id = "claude-one" } },
        has_more = true,
        last_id = "claude-one",
      }) },
      { body = vim.json.encode({
        data = { { id = "claude-two" } },
        has_more = true,
        last_id = "claude-one",
      }) },
      { body = vim.json.encode({
        data = { { id = "claude-one" } },
        has_more = true,
        last_id = "claude-one",
      }) },
      { body = vim.json.encode({
        data = { { id = "claude-one" } },
        has_more = false,
      }) },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    })
    local request = { resolve_auth = auth({ ["x-api-key"] = "key" }) }

    local result = wait(value:models(request))
    assert.is_false(result.ok)
    assert.matches("incomplete model catalog", result.error.message)

    result = wait(value:models(request))
    assert.is_false(result.ok)
    assert.matches("invalid model catalog", result.error.message)
  end)

  it("rejects malformed capability metadata and bounded pagination", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = {}, first_id = "missing" }) },
      { body = vim.json.encode({
        data = { { id = "bad-image", capabilities = {
          image_input = { supported = "yes" },
        } } },
        has_more = false,
      }) },
      { body = vim.json.encode({
        data = { { id = "bad-thinking", capabilities = {
          thinking = { supported = true, types = {} },
        } } },
        has_more = false,
      }) },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    })
    local request = { resolve_auth = auth({ ["x-api-key"] = "key" }) }
    for _ = 1, 3 do
      local result = wait(value:models(request))
      assert.is_false(result.ok)
      assert.matches("invalid model catalog", result.error.message)
    end

    transport = fake_transport.new()
    transport.fetches = {}
    for index = 1, 32 do
      transport.fetches[index] = { body = vim.json.encode({
        data = { { id = "model-" .. index } },
        has_more = true,
        last_id = "model-" .. index,
      }) }
    end
    value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    })
    local result = wait(value:models(request))
    assert.is_false(result.ok)
    assert.matches("incomplete model catalog", result.error.message)
    assert.are.equal(32, #transport.fetch_requests)
  end)

  it("aggregates organization token usage and costs in dollars", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ has_more = false, data = { {
        starting_at = "2026-07-01T00:00:00Z",
        ending_at = "2026-07-02T00:00:00Z",
        results = { {
          uncached_input_tokens = 100,
          cache_read_input_tokens = 200,
          cache_creation = {
            ephemeral_5m_input_tokens = 50,
            ephemeral_1h_input_tokens = 25,
          },
          output_tokens = 300,
        } },
      } } }) },
      { body = vim.json.encode({ has_more = false, data = { {
        starting_at = "2026-07-01T00:00:00Z",
        ending_at = "2026-07-02T00:00:00Z",
        results = {
          { amount = "123.45", currency = "USD" },
          { amount = "76.55", currency = "USD" },
        },
      } } }) },
    }
    local now = 1787270400
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
      now = function() return now end,
    })
    local result = wait(value:organization({
      resolve_auth = auth({ ["x-api-key"] = "admin-key" }),
    }))

    assert.is_true(result.ok)
    assert.are.same({
      uncached_input_tokens = 100,
      cache_read_input_tokens = 200,
      cache_creation_input_tokens = 75,
      output_tokens = 300,
    }, result.usage)
    assert.are.same({ { currency = "USD", value = 2 } }, result.costs)
    assert.matches("/organizations/usage_report/messages%?",
      transport.fetch_requests[1].url)
    assert.matches("bucket_width=1d", transport.fetch_requests[1].url)
    assert.matches("/organizations/cost_report%?",
      transport.fetch_requests[2].url)
  end)

  it("rejects incomplete reports, invalid catalogs, and missing keys safely", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ has_more = true, data = {} }) },
      { body = vim.json.encode({ data = { { id = "bad\nmodel" } }, has_more = false }) },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
      ambient_api_key = function() return "api-secret" end,
    })
    local result = wait(value:organization({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("incomplete usage", result.error.message)
    assert.is_nil(vim.inspect(result.error):find("api-secret", 1, true))

    result = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("invalid model catalog", result.error.message)

    value = client.new({
      base_url = "https://example.test/v1",
      transport = fake_transport.new(),
      ambient_api_key = function() return nil end,
    })
    result = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("ANTHROPIC_API_KEY", result.error.message)
  end)

  it("rejects malformed report pages, buckets, entries, and costs", function()
    local valid_usage = {
      has_more = false,
      data = { { results = { {
        uncached_input_tokens = 1,
        cache_read_input_tokens = 1,
        cache_creation = {
          ephemeral_5m_input_tokens = 1,
          ephemeral_1h_input_tokens = 1,
        },
        output_tokens = 1,
      } } } },
    }
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = {}, has_more = true }) },
      { body = vim.json.encode({ has_more = false, data = "usage" }) },
      { body = vim.json.encode({ has_more = false,
        data = { { results = "usage" } } }) },
      { body = vim.json.encode({ has_more = false,
        data = { { results = { {} } } } }) },
      { body = vim.json.encode(valid_usage) },
      { body = vim.json.encode({ has_more = false,
        data = { { results = "costs" } } }) },
      { body = vim.json.encode(valid_usage) },
      { body = vim.json.encode({ has_more = false,
        data = { { results = { {
          amount = "-1", currency = "USD",
        } } } } }) },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    })
    local request = { resolve_auth = auth({ ["x-api-key"] = "key" }) }

    local result = wait(value:models(request))
    assert.is_false(result.ok)
    assert.matches("incomplete model catalog", result.error.message)
    for _ = 1, 3 do
      result = wait(value:organization(request))
      assert.is_false(result.ok)
      assert.matches("invalid usage data", result.error.message)
    end
    for _ = 1, 2 do
      result = wait(value:organization(request))
      assert.is_false(result.ok)
      assert.matches("invalid cost data", result.error.message)
    end
  end)

  it("reports invalid keys and reads ANTHROPIC_API_KEY by default", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 401, body = "private" },
      { body = vim.json.encode({
        data = { { id = "claude-environment" } }, has_more = false,
      }) },
    }
    local previous = vim.env.ANTHROPIC_API_KEY
    vim.env.ANTHROPIC_API_KEY = "environment-key"
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    })
    local result = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("requires a valid API key", result.error.message)
    result = wait(value:models({ resolve_auth = auth(nil) }))
    vim.env.ANTHROPIC_API_KEY = previous
    assert.is_true(result.ok)
    assert.are.equal("environment-key",
      transport.fetch_requests[2].headers["x-api-key"])
  end)
end)
