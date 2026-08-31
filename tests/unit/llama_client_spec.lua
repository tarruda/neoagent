local async = require("neoagent.async")
local client = require("neoagent.providers.llama.client")
local fake_transport = require("tests.helpers.fake_transport")

describe("neoagent llama.cpp client", function()
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

  it("normalizes server URLs and formats bytes", function()
    assert.are.equal("http://127.0.0.1:8080",
      client.normalize_server_url("http://127.0.0.1:8080/v1"))
    assert.are.equal("http://127.0.0.1:8080/v1",
      client.inference_url("http://127.0.0.1:8080/v1/"))
    assert.has_error(function() client.normalize_server_url("ftp://host") end)
    assert.are.equal("4.20 GiB", client.format_bytes(4511000000))
    assert.are.equal("512 B", client.format_bytes(512))
  end)

  it("lists and validates router models", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = {
        { id = "qwen3", status = { value = "loaded" } },
      } }) },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local result = wait(value:list({ reload = true }))
    assert.are.equal("qwen3", result.value[1].id)
    assert.matches("/models%?reload=1", transport.fetch_requests[1].url)
  end)

  it("reports invalid catalogs and router-mode failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ data = { { id = 1 } } }) },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local result = wait(value:list())
    assert.is_false(result.ok)
    assert.matches("router mode", result.error.message)
  end)

  it("reports HTTP errors with provider payload messages", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 429, body = vim.json.encode({ error = { message = "usage limit" } }) },
      { status = 500, body = "plain" },
      { status = 403, body = "{}" },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local first = wait(value:list())
    assert.is_false(first.ok)
    assert.matches("usage limit", first.error.message)
    assert.are.equal(429, first.error.status)
    local second = wait(value:list())
    assert.is_false(second.ok)
    assert.matches("HTTP 500", second.error.message)
    assert.are.equal(500, second.error.status)
    local third = wait(value:list())
    assert.is_false(third.ok)
    assert.matches("HTTP 403", third.error.message)
    assert.are.equal(403, third.error.status)
  end)

  it("rejects catalogs without a data list", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = "{}" } }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local result = wait(value:list())
    assert.is_false(result.ok)
    assert.matches("invalid model catalog", result.error.message)
  end)

  it("posts load, unload, and download commands", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = "{}" },
      { body = "{}" },
      { body = "{}" },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    wait(value:load("qwen3"))
    wait(value:unload("qwen3"))
    wait(value:download("owner/repo:Q4_K_M"))
    assert.are.equal("POST", transport.fetch_requests[1].method)
    assert.are.equal("POST", transport.fetch_requests[2].method)
    assert.are.equal("POST", transport.fetch_requests[3].method)
    assert.matches("qwen3", transport.fetch_requests[1].body)
  end)

  it("unloads and waits until the model disappears", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = "{}" },
      { body = vim.json.encode({ data = { { id = "qwen3", status = { value = "loaded" } } } }) },
      { body = vim.json.encode({ data = { { id = "qwen3", status = { value = "unloaded" } } } }) },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    assert.is_true(wait(value:unload_and_wait("qwen3")).value)
  end)

  it("bounds router waits and reports timeout instead of false success", function()
    local loaded = vim.json.encode({ data = {
      { id = "qwen3", status = { value = "loaded" } },
    } })
    local transport = fake_transport.new()
    transport.fetch = function(opts)
      transport.fetch_requests[#transport.fetch_requests + 1] = opts.request
      return async.run(function()
        if opts.request.url:match("/models/unload$") then
          return { ok = true, status = 200, body = "{}" }
        end
        return { ok = true, status = 200, body = loaded }
      end)
    end
    local value = client.new({
      server_url = "http://127.0.0.1:8080",
      transport = transport,
      wait_timeout_ms = 20,
      poll_interval_ms = 1,
    })
    local result = wait(value:unload_and_wait("qwen3"))
    assert.is_false(result.ok)
    assert.matches("Timed out waiting to unload qwen3", result.error.message)

    local existing = vim.json.encode({ data = {} })
    transport = fake_transport.new()
    transport.fetch = function(opts)
      transport.fetch_requests[#transport.fetch_requests + 1] = opts.request
      return async.run(function()
        if opts.request.method == "POST" then
          return { ok = true, status = 200, body = "{}" }
        end
        return { ok = true, status = 200, body = existing }
      end)
    end
    value = client.new({
      server_url = "http://127.0.0.1:8080",
      transport = transport,
      wait_timeout_ms = 20,
      poll_interval_ms = 1,
    })
    result = wait(value:download_and_wait("owner/repo", function() end))
    assert.is_false(result.ok)
    assert.matches("Timed out waiting to download owner/repo", result.error.message)
  end)

  it("parses model-status SSE progress", function()
    local transport = fake_transport.new()
    transport.responses = {
      {
        chunks = {
          "data: " .. vim.json.encode({
            model = "qwen3",
            event = "model_status",
            data = { status = "loading", progress = { current = "tensors", value = 0.5, stages = { "load", "tensors" } } },
          }) .. "\n\n",
        },
      },
    }
    local events = {}
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    wait(value:watch(function(event) events[#events + 1] = event end))
    assert.are.equal("model_status", events[1].event)
  end)

  it("loads and waits using SSE progress and failure branches", function()
    local transport = fake_transport.new()
    transport.responses = {
      {
        chunks = {
          "data: " .. vim.json.encode({
            model = "qwen3",
            event = "status_change",
            data = { status = "loading", progress = { current = "tensors", value = 0.5, stages = { "load", "tensors" } } },
          }) .. "\n\n",
        },
      },
    }
    transport.fetches = {
      { body = "{}" },
      { body = vim.json.encode({ data = { { id = "qwen3", status = { value = "loading" } } } }) },
      { body = vim.json.encode({ data = { { id = "qwen3", status = { value = "loaded" } } } }) },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local progress = {}
    local result = wait(value:load_and_wait("qwen3", function(update)
      progress[#progress + 1] = update
    end))
    assert.are.equal("loaded", result.value.status.value)
    assert.is_true(#progress >= 2)
    assert.are.equal("Model loaded", progress[#progress].message)
    assert.are.equal(1, progress[#progress].ratio)

    transport = fake_transport.new()
    transport.fetches = {
      { body = "{}" },
      { body = vim.json.encode({ data = { { id = "qwen3", status = { value = "failed", failed = true, exit_code = 7 } } } }) },
    }
    value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    result = wait(value:load_and_wait("qwen3", function() end))
    assert.is_false(result.ok)
    assert.matches("code 7", result.error.message)

    transport = fake_transport.new()
    transport.fetches = {
      { body = "{}" },
      { body = vim.json.encode({ data = { {
        id = "qwen3",
        status = { value = "failed", failed = true },
      } } }) },
    }
    value = client.new({
      server_url = "http://127.0.0.1:8080",
      transport = transport,
    })
    result = wait(value:load_and_wait("qwen3", function() end))
    assert.is_false(result.ok)
    assert.matches("Model failed to load", result.error.message)
  end)

  it("loads and waits through SSE loaded and error events", function()
    local transport = fake_transport.new()
    transport.responses = {
      {
        chunks = {
          "data: " .. vim.json.encode({
            model = "qwen3",
            event = "status_change",
            data = { status = "loaded" },
          }) .. "\n\n",
        },
      },
    }
    transport.fetches = {
      { body = "{}" },
      { body = vim.json.encode({ data = {} }) },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local result = wait(value:load_and_wait("qwen3", function() end))
    assert.are.equal("loaded", result.value.status.value)

    transport = fake_transport.new()
    transport.responses = {
      {
        chunks = {
          "data: " .. vim.json.encode({
            model = "qwen3",
            event = "status_change",
            data = { status = "unloaded", exit_code = 13 },
          }) .. "\n\n",
        },
      },
    }
    transport.fetches = {
      { body = "{}" },
      { body = vim.json.encode({ data = { { id = "qwen3", status = { value = "failed", failed = true } } } }) },
    }
    value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    result = wait(value:load_and_wait("qwen3", function() end))
    assert.is_false(result.ok)
    assert.matches("code 13", result.error.message)
  end)

  it("cancels load polling while it sleeps", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = "{}" },
      { body = vim.json.encode({ data = { { id = "qwen3", status = { value = "loading" } } } }) },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local run = value:load_and_wait("qwen3", function() end)
    vim.wait(50)
    run:cancel()
    assert(vim.wait(3000, function() return run:is_done() end))
    assert.are.equal("cancelled", run:result().error.kind)
    assert(vim.wait(1000, function()
      for _, request in ipairs(transport.fetch_requests) do
        if request.url:match("/models/unload$") then return true end
      end
      return false
    end))
  end)

  local function pending_request_transport(fulfill)
    local pending = { requests = 0, cancelled = 0 }
    local transport = {
      fetch = function(opts)
        return async.run(function()
          if fulfill.fetch then fulfill.fetch(opts.request, pending) end
          return { ok = true, status = 200, body = "{}" }
        end)
      end,
      request = function(opts)
        pending.requests = pending.requests + 1
        return async.run(function(run)
          async.await(function(done)
            pending.done = done
            return function() pending.cancelled = pending.cancelled + 1 end
          end)
        end)
      end,
    }
    return transport, pending
  end

  it("cancels the SSE watcher when load and download commands fail", function()
    local transport, pending = pending_request_transport()
    local fetches = {
      { status = 400, body = vim.json.encode({ error = { message = "already running" } }) },
    }
    transport.fetch = function(opts)
      local response = table.remove(fetches, 1) or { body = "{}" }
      return async.run(function()
        return { ok = true, status = response.status or 200, body = response.body }
      end)
    end
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local load = wait(value:load_and_wait("qwen3", function() end))
    assert.is_false(load.ok)
    assert.matches("already running", load.error.message)
    assert.are.equal(1, pending.requests)
    assert(vim.wait(1000, function() return pending.cancelled == 1 end))

    transport = pending_request_transport()
    transport.fetch = function()
      return async.run(function()
        return {
          ok = true,
          status = 400,
          body = vim.json.encode({ error = { message = "already exists" } }),
        }
      end)
    end
    value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local download = wait(value:download_and_wait("owner/repo", function() end))
    assert.is_false(download.ok)
    assert.matches("already exists", download.error.message)
    assert(vim.wait(1000, function() return pending.cancelled == 1 end))
  end)

  it("cancels the SSE watcher when load and download runs are cancelled", function()
    local transport, pending = pending_request_transport()
    local fetches = {
      { body = "{}" },
      { body = vim.json.encode({ data = { { id = "qwen3", status = { value = "loading" } } } }) },
    }
    transport.fetch = function(opts)
      if opts.request.url:match("/models/unload$") then
        pending.cancel_unloads = (pending.cancel_unloads or 0) + 1
      end
      local response = table.remove(fetches, 1) or { body = "{}" }
      return async.run(function()
        return { ok = true, status = response.status or 200, body = response.body }
      end)
    end
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local run = value:load_and_wait("qwen3", function() end)
    vim.wait(50)
    run:cancel()
    assert(vim.wait(3000, function() return run:is_done() end))
    assert.are.equal("cancelled", run:result().error.kind)
    assert(vim.wait(1000, function() return pending.cancelled == 1 end))
    assert(vim.wait(1000, function() return pending.cancel_unloads == 1 end))

    transport, pending = pending_request_transport()
    fetches = {
      { body = vim.json.encode({ data = {} }) },
      { body = "{}" },
      { body = vim.json.encode({ data = { { id = "owner/repo", status = { value = "downloading" } } } }) },
    }
    transport.fetch = function(opts)
      if opts.request.url:match("/models/unload$") then
        pending.cancel_unloads = (pending.cancel_unloads or 0) + 1
      end
      local response = table.remove(fetches, 1) or { body = "{}" }
      return async.run(function()
        return { ok = true, status = response.status or 200, body = response.body }
      end)
    end
    value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    run = value:download_and_wait("owner/repo", function() end)
    vim.wait(50)
    run:cancel()
    assert(vim.wait(3000, function() return run:is_done() end))
    assert.are.equal("cancelled", run:result().error.kind)
    assert(vim.wait(1000, function() return pending.cancelled == 1 end))
    assert(vim.wait(1000, function() return pending.cancel_unloads == 1 end))
  end)

  it("downloads and waits using SSE finish and failure events", function()
    local transport = fake_transport.new()
    local catalog = { data = { { id = "owner/repo:Q4_K_M", status = { value = "downloading", progress = { file = { done = 1, total = 2 } } } } } }
    transport.responses = {
      {
        chunks = {
          "data: " .. vim.json.encode({
            model = "owner/repo:Q4_K_M",
            event = "download_progress",
            data = { progress = { file = { done = 1, total = 2 } } },
          }) .. "\n\n",
          "data: " .. vim.json.encode({
            model = "owner/repo:Q4_K_M",
            event = "download_finished",
            data = {},
          }) .. "\n\n",
        },
      },
    }
    transport.fetches = {
      { body = vim.json.encode({ data = {} }) },
      { body = "{}" },
      { body = vim.json.encode(catalog) },
      { body = vim.json.encode({ data = { { id = "owner/repo:Q4_K_M", status = { value = "downloading" } } } }) },
      { body = vim.json.encode({ data = { { id = "owner/repo:Q4_K_M", status = { value = "loaded" } } } }) },
      { body = vim.json.encode({ data = { { id = "owner/repo:Q4_K_M", status = { value = "loaded" } } } }) },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local progress = {}
    local result = wait(value:download_and_wait("owner/repo:Q4_K_M", function(update)
      progress[#progress + 1] = update
    end))
    assert(result.ok, vim.inspect(result.error))
    assert.are.equal(1, #result.value)
    assert.is_true(#progress >= 2)
    assert.are.equal("Download complete", progress[#progress].message)
    assert.are.equal(1, progress[#progress].ratio)

    transport = fake_transport.new()
    transport.responses = {
      {
        chunks = {
          "data: " .. vim.json.encode({
            model = "owner/repo:Q4_K_M",
            event = "download_failed",
            data = { error = { message = "download failed" } },
          }) .. "\n\n",
        },
      },
    }
    transport.fetches = {
      { body = vim.json.encode({ data = {} }) },
      { body = "{}" },
      { body = vim.json.encode(catalog) },
    }
    value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    result = wait(value:download_and_wait("owner/repo:Q4_K_M", function() end))
    assert.is_false(result.ok)
    assert.matches("download failed", result.error.message)
  end)

  it("keeps waiting for a pre-existing model download until its status changes", function()
    local transport = fake_transport.new()
    local existing = { data = { { id = "owner/repo", status = { value = "unloaded" } } } }
    transport.fetches = {
      { body = vim.json.encode(existing) },
      { body = "{}" },
      { body = vim.json.encode(existing) },
      { body = vim.json.encode(existing) },
      { body = vim.json.encode({ data = { { id = "owner/repo", status = { value = "loaded" } } } }) },
      { body = vim.json.encode({ data = { { id = "owner/repo", status = { value = "loaded" } } } }) },
    }
    local value = client.new({ server_url = "http://127.0.0.1:8080", transport = transport })
    local result = wait(value:download_and_wait("owner/repo", function() end))
    assert(result.ok, vim.inspect(result.error))
    assert.are.equal("loaded", result.value[1].status.value)
    assert.are.equal(6, #transport.fetch_requests)
  end)
end)
