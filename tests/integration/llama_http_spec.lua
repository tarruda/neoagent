local llama = require("neoagent.providers.llama")
local llama_catalog = require("neoagent.providers.llama.catalog")
local llama_client = require("neoagent.providers.llama.client")
local llama_server = require("tests.helpers.llama_server")
local model_catalog = require("neoagent.model_catalog")
local models = require("neoagent.models")
local registry = require("neoagent.registry")

local function wait(run, timeout)
  assert(vim.wait(timeout or 5000, function() return run:is_done() end))
  return run:result()
end

local function ids(entries)
  return vim.tbl_map(function(entry) return entry.id end, entries)
end

local function block(snapshot, block_type, label)
  for _, candidate in ipairs(snapshot.blocks or {}) do
    if candidate.type == block_type
        and (label == nil or candidate.label == label) then
      return candidate
    end
  end
end

describe("llama.cpp router HTTP integration", function()
  local servers = {}
  local runtimes = {}

  after_each(function()
    for _, runtime in ipairs(runtimes) do
      runtime.service:destroy()
      runtime.catalog:destroy()
    end
    for _, server in ipairs(servers) do server:stop() end
    servers = {}
    runtimes = {}
  end)

  local function start()
    local server = llama_server.start()
    servers[#servers + 1] = server
    return server
  end

  local function client(server)
    return llama_client.new({
      server_url = server.url,
      api_key = "router-key",
      wait_timeout_ms = 3000,
      download_timeout_ms = 3000,
      poll_interval_ms = 10,
    })
  end

  local function runtime(server)
    local definition = {
      api = "openai-completions",
      base_url = server.url .. "/v1",
      auth_optional = true,
      request_opts = registry.defaults()["llama.cpp"].request_opts,
      catalog = {
        ttl_ms = 5 * 60 * 1000,
        source_options = require("neoagent.model_catalog.source").no_options,
        discover = llama_catalog.discover,
        transform_model = llama_catalog.transform,
      },
      models = {},
      service_opts = {
        wait_timeout_ms = 3000,
        download_timeout_ms = 3000,
        poll_interval_ms = 10,
      },
    }
    local catalog = model_catalog.new({
      provider_id = "llama.cpp",
      provider = definition,
      definition = definition.catalog,
      models = definition.models,
    })
    local value = {
      id = "llama.cpp",
      definition = definition,
      catalog = catalog,
      service = llama.new(definition, {
        catalog = catalog,
        provider_id = "llama.cpp",
      }),
    }
    runtimes[#runtimes + 1] = value
    return value
  end

  it("discovers, loads, watches, and unloads router models through curl", function()
    local server = start()
    local value = client(server)

    local initial = wait(value:list())
    assert.is_true(initial.ok)
    assert.are.same({ "fake/loaded", "fake/unloaded", "fake/failing" },
      ids(initial.value))
    assert.are.equal("loaded", initial.value[1].status.value)
    assert.are.same({ "text", "image" },
      initial.value[1].architecture.input_modalities)
    assert.are.equal("unloaded", initial.value[2].status.value)

    local progress = {}
    local loaded = wait(value:load_and_wait("fake/unloaded", function(update)
      progress[#progress + 1] = update
    end))
    assert.is_true(loaded.ok)
    assert.are.equal("loaded", loaded.value.status.value)
    assert(vim.wait(1000, function()
      return vim.tbl_contains(vim.tbl_map(function(update)
        return update.message
      end, progress), "Loading text model")
    end))

    local unloaded = wait(value:unload_and_wait("fake/unloaded"))
    assert.is_true(unloaded.ok)
    local final = wait(value:list())
    assert.are.equal("unloaded", final.value[2].status.value)

    assert(vim.wait(1000, function()
      return server:count_requests("POST", "/models/load") == 1
        and server:count_requests("POST", "/models/unload") == 1
    end))
    local load_request = server:find_request("POST", "/models/load")
    assert.are.equal("Bearer router-key", load_request.headers.authorization)
    assert.are.same({ model = "fake/unloaded" }, load_request.body)
  end)

  it("preserves router HTTP errors and failed child process status", function()
    local server = start()
    local value = client(server)

    local missing = wait(value:load("fake/missing"))
    assert.is_false(missing.ok)
    assert.are.equal("model is not found", missing.error.message)
    assert.are.equal(404, missing.error.status)

    local failed = wait(value:load_and_wait("fake/failing", function() end))
    assert.is_false(failed.ok)
    assert.are.equal("provider", failed.error.kind)
    assert.are.equal("Model exited with code 42", failed.error.message)
  end)

  it("cancels loading through the real HTTP and SSE transports", function()
    local server = start()
    local value = client(server)
    local run
    run = value:load_and_wait("fake/unloaded", function(update)
      if update.ratio then run:cancel() end
    end)

    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert(vim.wait(1000, function()
      return server:count_requests("POST", "/models/unload") == 1
    end))
  end)

  it("downloads a model through SSE and reloads the resulting catalog", function()
    local server = start()
    local value = client(server)
    local progress = {}
    local selected = runtime(server)
    local service = selected.service
    assert.is_true(wait(selected.catalog:refresh({ force = true })).ok)
    local dashboard_progress, dashboard_updates = nil, 0
    local unsubscribe = service:subscribe(function(snapshot)
      dashboard_updates = dashboard_updates + 1
      for _, candidate in ipairs(snapshot.blocks or {}) do
        if candidate.type == "progress"
            and candidate.label == "Downloading fake/downloaded:Q4_K_M"
            and candidate.value == 0.5 then
          dashboard_progress = candidate
        end
      end
    end)
    assert(vim.wait(1000, function()
      return server:count_requests("GET", "/models/sse") == 1
    end))

    local run = value:download_and_wait(
      "fake/downloaded:Q4_K_M", function(update)
        progress[#progress + 1] = update
      end)
    assert(vim.wait(1000, function()
      for _, update in ipairs(progress) do
        if update.detail == "512 B / 1.00 KiB" and update.ratio == 0.5 then
          return true
        end
      end
      return false
    end))
    local downloading = wait(value:list())
    local active = vim.tbl_filter(function(entry)
      return entry.id == "fake/downloaded:Q4_K_M"
    end, downloading.value)[1]
    assert.are.equal("downloading", active.status.value)
    assert.is_nil(active.status.progress)

    local result = wait(run)
    assert.is_true(result.ok)
    assert.is_true(vim.tbl_contains(ids(result.value), "fake/downloaded:Q4_K_M"))
    assert.are.equal("Download complete", progress[#progress].message)
    assert.are.equal(1, progress[#progress].ratio)
    assert.is_not_nil(dashboard_progress)
    assert.are.equal("512 B / 1.00 KiB", dashboard_progress.detail)
    assert(vim.wait(1000, function()
      return block(service:state(), "progress",
        "Downloading fake/downloaded:Q4_K_M") == nil
    end))
    assert.are.equal("success",
      block(service:state(), "field", "Endpoint").level)
    assert.is_nil(block(service:state(), "activity"))
    assert(vim.wait(1000, function()
      return server:count_requests("POST", "/models") == 1
        and server:count_requests("GET", "/models?reload=1") == 1
    end))

    local updates_before_failure = dashboard_updates
    assert.is_true(wait(value:download("fake/failing-download")).ok)
    assert(vim.wait(1000, function()
      return dashboard_updates > updates_before_failure
    end))
    assert.is_nil(block(service:state(), "activity"))
    unsubscribe()
  end)

  it("refreshes the dynamic catalog and streams inference through the router", function()
    local server = start()
    local selected = runtime(server)
    local service = selected.service

    local refreshed = wait(selected.catalog:refresh({ force = true }))
    assert.is_true(refreshed.ok)
    local discovered = vim.tbl_keys(selected.catalog:snapshot().models)
    table.sort(discovered)
    assert.are.same({ "fake/failing", "fake/loaded", "fake/unloaded" },
      discovered)

    local configured = {
      _apis = {},
      providers = {
        ["llama.cpp"] = {
          api = "openai-completions",
          base_url = server.url .. "/v1",
          auth_optional = true,
          request_opts = selected.definition.request_opts,
          models = {},
        },
      },
    }
    local model = models.resolve("llama.cpp", "fake/loaded",
      configured, nil, { ["llama.cpp"] = selected })
    assert.are.same({ "text", "image" }, model.input)
    local png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC"
      .. "AAAAC0lEQVR42mP8/x8AAusB9Wl5ZAAAAABJRU5ErkJggg=="
    local inference_stats = {}
    local streamed = wait(model:stream({
      messages = { { role = "user", content = {
        { type = "text", text = "What is in this image?" },
        { type = "image", mimeType = "image/png", data = png },
      } } },
      on_event = function(event)
        if event.type == "inference_stats" then
          inference_stats[#inference_stats + 1] = event
        end
      end,
    }))
    assert.is_true(streamed.ok)
    assert.are.equal("image accepted", streamed.text)
    assert.are.same({
      type = "thinking",
      thinking = "checking the image",
      thinkingSignature = "reasoning_content",
    }, streamed.message.content[1])
    assert.are.same({ type = "text", text = "image accepted" },
      streamed.message.content[2])
    assert.are.equal(7, streamed.message.usage.totalTokens)
    assert(vim.wait(1000, function()
      return server:count_requests("POST", "/v1/chat/completions") == 1
    end))
    local request = server:find_request("POST", "/v1/chat/completions")
    assert.are.equal("fake/loaded", request.body.model)
    assert.is_true(request.body.stream)
    assert.is_true(request.body.timings_per_token)
    assert.is_true(request.body.return_progress)
    assert.are.same({ include_usage = true }, request.body.stream_options)
    assert.are.same({
      type = "inference_stats",
      generation_tokens_per_second = 50,
    }, inference_stats[#inference_stats])
    assert.are.same({
      type = "image_url",
      image_url = { url = "data:image/png;base64," .. png },
    }, request.body.messages[1].content[2])
  end)

  it("pushes implicitly loaded model progress from router SSE", function()
    local server = start()
    local selected = runtime(server)
    local service = selected.service
    assert.is_true(wait(selected.catalog:refresh({ force = true })).ok)

    local visible_progress, failed_progress
    local unsubscribe = service:subscribe(function(snapshot)
      for _, block in ipairs(snapshot.blocks or {}) do
        if block.type == "progress" and block.value == 0.25 then
          if block.label == "Loading fake/failing" then
            failed_progress = vim.deepcopy(block)
          else
            visible_progress = vim.deepcopy(block)
          end
        end
      end
    end)
    assert(vim.wait(1000, function()
      return server:count_requests("GET", "/models/sse") == 1
    end))

    local configured = {
      _apis = {},
      providers = {
        ["llama.cpp"] = {
          api = "openai-completions",
          base_url = server.url .. "/v1",
          auth_optional = true,
          models = {},
        },
      },
    }
    local model = models.resolve("llama.cpp", "fake/unloaded",
      configured, nil, { ["llama.cpp"] = selected })
    local result = wait(model:stream({
      messages = { { role = "user", content = "hello" } },
    }))
    assert.is_true(result.ok)
    assert.are.equal("fake reply", result.text)
    assert(vim.wait(1000, function() return visible_progress ~= nil end))
    assert.are.equal("Loading fake/unloaded", visible_progress.label)
    assert.are.equal(0.25, visible_progress.value)
    local settled = vim.wait(1000, function()
      return block(service:state(), "progress", "Loading fake/unloaded") == nil
        and block(service:state(), "field", "Last response") ~= nil
    end)
    assert(settled, vim.inspect(service:state()))
    assert.are.equal("3 in · 4 out",
      block(service:state(), "field", "Last response").value)
    assert.are.equal("success",
      block(service:state(), "field", "Endpoint").level)
    assert.is_nil(block(service:state(), "activity"))
    assert.are.equal(0,
      server:count_requests("POST", "/models/load"))

    assert.is_true(wait(client(server):unload_and_wait("fake/unloaded")).ok)
    local failed = wait(client(server):load_and_wait("fake/failing", function() end))
    assert.is_false(failed.ok)
    assert(vim.wait(1000, function()
      return failed_progress ~= nil
        and block(service:state(), "progress", "Loading fake/failing") == nil
    end))
    assert.is_nil(block(service:state(), "activity"))

    unsubscribe()
  end)
end)
