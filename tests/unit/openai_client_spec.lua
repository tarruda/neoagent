local assert = require("luassert")
local client = require("neoagent.providers.openai.client")
local fake_transport = require("tests.helpers.fake_transport")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return (assert(run:result()))
end

local auth = require("tests.helpers.api_key_auth")

describe("OpenAI management client", function()
  it("loads the accessible model catalog with the inference key", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      object = "list",
      data = {
        { id = "gpt-5.4", object = "model", owned_by = "openai" },
        { id = "text-embedding-4", object = "model", owned_by = "openai" },
      },
    }) } }
    local value = client.new({
      base_url = "https://example.test/v1/",
      transport = transport,
    })
    local result = wait(value:models({
      resolve_auth = auth({ Authorization = "Bearer inference-key" }),
    }))

    assert(result.ok)
    assert.are.same({ "gpt-5.4", "text-embedding-4" }, result.models)
    assert.are.equal("https://example.test/v1/models",
      assert(transport.fetch_requests[1]).url)
    assert.are.equal("Bearer inference-key",
      rawget(assert(assert(transport.fetch_requests[1]).headers), "Authorization"))
  end)

  it("aggregates 30-day organization completion usage and costs", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        object = "page", has_more = false, next_page = vim.NIL,
        data = {
          { object = "bucket", start_time = 100, end_time = 200, results = { {
            object = "organization.usage.completions.result",
            input_tokens = 1000, input_cached_tokens = 400,
            output_tokens = 500, num_model_requests = 5,
          } } },
          { object = "bucket", start_time = 200, end_time = 300, results = { {
            object = "organization.usage.completions.result",
            input_tokens = 2000, output_tokens = 750,
            num_model_requests = 7,
          } } },
        },
      }) },
      { body = vim.json.encode({
        object = "page", has_more = false, next_page = vim.NIL,
        data = { {
          object = "bucket", start_time = 100, end_time = 200, results = {
            { object = "organization.costs.result",
              amount = { value = 1.25, currency = "usd" } },
            { object = "organization.costs.result",
              amount = { value = 0.75, currency = "usd" } },
          },
        } },
      }) },
    }
    local now = 1787270400
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
      now = function() return now end,
    })
    local result = wait(value:organization({
      resolve_auth = auth({ Authorization = "Bearer admin-key" }),
    }))

    assert(result.ok)
    assert.are.same({
      requests = 12,
      input_tokens = 3000,
      cached_input_tokens = 400,
      output_tokens = 1250,
    }, result.usage)
    assert.are.same({ { currency = "usd", value = 2 } }, result.costs)
    assert.are.equal(now - 30 * 86400, result.start_time)
    assert.are.equal(now, result.end_time)
    assert.matches("/organization/usage/completions%?", assert(transport.fetch_requests[1]).url)
    assert.matches("bucket_width=1d", assert(transport.fetch_requests[1]).url)
    assert.matches("limit=31", assert(transport.fetch_requests[1]).url)
    assert.matches("/organization/costs%?", assert(transport.fetch_requests[2]).url)
    for _, request in ipairs(transport.fetch_requests) do
      assert.are.equal("Bearer admin-key", rawget(assert(request.headers), "Authorization"))
    end
  end)

  it("uses the provider API key and rejects incomplete reports safely", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ object = "page", has_more = true, data = {} }) },
      { body = vim.json.encode({ object = "page", has_more = false, data = {} }) },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
      ambient_api_key = function() return "api-secret" end,
      now = function() return 10000000 end,
    })
    local result = wait(value:organization({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("incomplete usage", assert(result.error).message)
    assert.is_nil((vim.inspect(result.error):find("api-secret", 1, true)))

    value = client.new({
      base_url = "https://example.test/v1",
      transport = fake_transport.new(),
      ambient_api_key = function() return nil end,
    })
    result = wait(value:organization({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("OPENAI_API_KEY", assert(result.error).message)
  end)

  it("redacts HTTP responses and validates schemas and options", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 403, body = "private billing response" },
      { body = vim.json.encode({ data = { { id = "bad\nmodel" } } }) },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
      ambient_api_key = function() return "inference-secret" end,
    })
    local forbidden = wait(value:organization({ resolve_auth = auth(nil) }))
    assert.is_false(forbidden.ok)
    assert.are.equal(403, rawget(assert(forbidden.error), "status"))
    assert.is_nil((vim.inspect(forbidden.error):find("private billing response", 1, true)))

    local invalid = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(invalid.ok)
    assert.matches("invalid model catalog", assert(invalid.error).message)

    local missing_options = {}
    assert.has_error(function() client.new(missing_options --[[@as Neoagent.OpenAIClientOptions]]) end)
    assert.has_error(function()
      client.new({ base_url = "x", max_response_bytes = 10 })
    end)
  end)

  it("rejects malformed organization pages, buckets, entries, and costs", function()
    local valid_usage = {
      has_more = false,
      data = { { results = { {
        input_tokens = 1, output_tokens = 1, num_model_requests = 1,
      } } } },
    }
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = "models" }) },
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
        data = { { results = { { amount = {
          value = -1, currency = "usd",
        } } } } } }) },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    })

    local result = wait(value:models({
      resolve_auth = auth({ Authorization = "Bearer key" }),
    }))
    assert.is_false(result.ok)
    assert.matches("invalid model catalog", assert(result.error).message)
    for _ = 1, 3 do
      local result = wait(value:organization({
        resolve_auth = auth({ Authorization = "Bearer key" }),
      }))
      assert.is_false(result.ok)
      assert.matches("invalid usage data", assert(result.error).message)
    end
    for _ = 1, 2 do
      local result = wait(value:organization({
        resolve_auth = auth({ Authorization = "Bearer key" }),
      }))
      assert.is_false(result.ok)
      assert.matches("invalid cost data", assert(result.error).message)
    end
  end)

  it("reports incomplete and failed cost requests after valid usage", function()
    local valid_usage = {
      has_more = false,
      data = { { results = { {
        input_tokens = 1,
        output_tokens = 1,
        num_model_requests = 1,
      } } } },
    }
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode(valid_usage) },
      { body = vim.json.encode({ has_more = true, data = {} }) },
      { body = vim.json.encode(valid_usage) },
      { status = 503, body = "private cost response" },
    }
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    })
    local request = {
      resolve_auth = auth({ Authorization = "Bearer admin-key" }),
    }

    local incomplete = wait(value:organization(request))
    assert.is_false(incomplete.ok)
    assert.matches("incomplete cost data", assert(incomplete.error).message)

    local unavailable = wait(value:organization(request))
    assert.is_false(unavailable.ok)
    assert.are.equal(503, rawget(assert(unavailable.error), "status"))
    assert.is_nil((vim.inspect(unavailable.error):find("private cost response", 1, true)))
  end)

  it("reports invalid keys and reads OPENAI_API_KEY by default", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 401, body = "private" },
      { body = vim.json.encode({ data = { { id = "gpt-environment" } } }) },
    }
    local previous = vim.env.OPENAI_API_KEY
    vim.env.OPENAI_API_KEY = "environment-key"
    local value = client.new({
      base_url = "https://example.test/v1",
      transport = transport,
    })
    local result = wait(value:models({ resolve_auth = auth(nil) }))
    assert.is_false(result.ok)
    assert.matches("requires a valid API key", assert(result.error).message)
    result = wait(value:models({ resolve_auth = auth(nil) }))
    vim.env.OPENAI_API_KEY = previous
    assert(result.ok)
    assert.are.equal("Bearer environment-key",
      rawget(assert(assert(transport.fetch_requests[2]).headers), "Authorization"))
  end)
end)
