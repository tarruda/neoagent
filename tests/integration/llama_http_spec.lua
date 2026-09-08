local assert = require("luassert")
local llama = require("neoagent.providers.llama")
local llama_catalog = require("neoagent.providers.llama.catalog")
local llama_client = require("neoagent.providers.llama.client")
local http_replay = require("tests.helpers.http_replay")
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

local function find_request(scenario, method, path)
  for _, value in ipairs(scenario.requests) do
    if (value.method or "POST") == method and value.url == scenario.url .. path then
      local request = vim.deepcopy(value)
      request.headers = {}
      for key, item in pairs(value.headers or {}) do request.headers[key:lower()] = item end
      if value.body then request.body = vim.json.decode(value.body) end
      return request
    end
  end
end

local function count_requests(scenario, method, path)
  local count = 0
  for _, value in ipairs(scenario.requests) do
    if (value.method or "POST") == method and value.url == scenario.url .. path then count = count + 1 end
  end
  return count
end

describe("llama.cpp router HTTP integration", function()
  local scenarios = {}
  local runtimes = {}

  after_each(function()
    for _, runtime in ipairs(runtimes) do
      runtime.service:destroy()
      runtime.catalog:destroy()
    end
    for _, scenario in ipairs(scenarios) do http_replay.finish(scenario) end
    scenarios = {}
    runtimes = {}
  end)

  local function start(exchanges)
    local scenario = http_replay.open(exchanges)
    scenarios[#scenarios + 1] = scenario
    return scenario
  end

  local function client(scenario)
    return llama_client.new({
      server_url = scenario.url,
      transport = scenario,
      api_key = "router-key",
      wait_timeout_ms = 3000,
      download_timeout_ms = 3000,
      poll_interval_ms = 10,
    })
  end

  local function runtime(scenario)
    local definition = {
      api = "openai-completions",
      base_url = scenario.url .. "/v1",
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
      transport = scenario,
      provider = definition,
      definition = definition.catalog,
      models = definition.models,
    })
    local value = {
      id = "llama.cpp",
      transport = scenario,
      definition = definition,
      catalog = catalog,
      service = llama.new(definition, {
        catalog = catalog,
        provider_id = "llama.cpp",
        transport = scenario,
      }),
    }
    runtimes[#runtimes + 1] = value
    return value
  end

  it("discovers, loads, watches, and unloads router models through recorded HTTP", function()
    local scenario = start({
      { id = "1", path = "tests/recordings/llama/scenario-1-1.yaml", headers_subset = true },
      {
        id = "2",
        path = "tests/recordings/llama/scenario-1-2.yaml",
        open = true,
        gates = { ["1"] = { "3:request" }, ["2"] = { "4:complete" }, ["3"] = { "8:request" } },
        headers_subset = true,
      },
      { id = "3", path = "tests/recordings/llama/scenario-1-3.yaml", headers_subset = true },
      { id = "4", path = "tests/recordings/llama/scenario-1-4.yaml", headers_subset = true },
      {
        id = "8",
        path = "tests/recordings/llama/scenario-1-8.yaml",
        finish_after = { "2:chunk:3" },
        headers_subset = true,
      },
      { id = "9", path = "tests/recordings/llama/scenario-1-9.yaml", headers_subset = true },
      { id = "10", path = "tests/recordings/llama/scenario-1-10.yaml", headers_subset = true },
      { id = "12", path = "tests/recordings/llama/scenario-1-12.yaml", headers_subset = true },
      { id = "13", path = "tests/recordings/llama/scenario-1-13.yaml", headers_subset = true },
    })
    local value = client(scenario)

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
      return count_requests(scenario, "POST", "/models/load") == 1
        and count_requests(scenario, "POST", "/models/unload") == 1
    end))
    local load_request = find_request(scenario, "POST", "/models/load")
    assert.are.equal("Bearer router-key", load_request.headers.authorization)
    assert.are.same({ model = "fake/unloaded" }, load_request.body)
  end)

  it("preserves router HTTP errors and failed child process status", function()
    local scenario = start({
      { id = "14", path = "tests/recordings/llama/scenario-2-14.yaml", headers_subset = true },
      {
        id = "15",
        path = "tests/recordings/llama/scenario-2-15.yaml",
        open = true,
        gates = { ["1"] = { "16:request" }, ["2"] = { "17:complete" }, ["3"] = { "21:request" } },
        headers_subset = true,
      },
      { id = "16", path = "tests/recordings/llama/scenario-2-16.yaml", headers_subset = true },
      { id = "17", path = "tests/recordings/llama/scenario-2-17.yaml", headers_subset = true },
      {
        id = "21",
        path = "tests/recordings/llama/scenario-2-21.yaml",
        finish_after = { "15:chunk:3" },
        headers_subset = true,
      },
    })
    local value = client(scenario)

    local missing = wait(value:load("fake/missing"))
    assert.is_false(missing.ok)
    assert.are.equal("model is not found", missing.error.message)
    assert.are.equal(404, missing.error.status)

    local failed = wait(value:load_and_wait("fake/failing", function() end))
    assert.is_false(failed.ok)
    assert.are.equal("provider", failed.error.kind)
    assert.are.equal("Model exited with code 42", failed.error.message)
  end)

  it("cancels loading through replayed HTTP and SSE", function()
    local scenario = start({
      {
        id = "22",
        path = "tests/recordings/llama/scenario-3-22.yaml",
        open = true,
        gates = { ["1"] = { "23:request" }, ["2"] = { "26:request" } },
        headers_subset = true,
      },
      { id = "23", path = "tests/recordings/llama/scenario-3-23.yaml", headers_subset = true },
      { id = "24", path = "tests/recordings/llama/scenario-3-24.yaml", headers_subset = true },
      { id = "26", path = "tests/recordings/llama/scenario-3-26.yaml", open = true, headers_subset = true },
      { id = "cleanup", path = "tests/recordings/llama/scenario-3-cleanup.yaml", headers_subset = true },
    })
    local value = client(scenario)
    local run
    run = value:load_and_wait("fake/unloaded", function(update)
      if update.ratio then run:cancel() end
    end)

    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert(vim.wait(1000, function()
      return count_requests(scenario, "POST", "/models/unload") == 1
    end))
  end)

  it("downloads a model through SSE and reloads the resulting catalog", function()
    local scenario = start({
      { id = "28", path = "tests/recordings/llama/scenario-4-28.yaml", headers_subset = true },
      {
        id = "29",
        path = "tests/recordings/llama/scenario-4-29.yaml",
        open = true,
        gates = {
          ["1"] = { "32:request" },
          ["2"] = { "33:request" },
          ["3"] = { "inspected-download" },
          ["4"] = { "51:request" },
        },
        headers_subset = true,
      },
      {
        id = "30",
        path = "tests/recordings/llama/scenario-4-30.yaml",
        open = true,
        gates = { ["1"] = { "32:request" }, ["2"] = { "33:request" }, ["3"] = { "inspected-download" } },
        headers_subset = true,
      },
      { id = "31", path = "tests/recordings/llama/scenario-4-31.yaml", headers_subset = true },
      { id = "32", path = "tests/recordings/llama/scenario-4-32.yaml", headers_subset = true },
      {
        id = "33",
        path = "tests/recordings/llama/scenario-4-33.yaml",
        finish_after = { "35:request" },
        headers_subset = true,
      },
      { id = "35", path = "tests/recordings/llama/scenario-4-35.yaml", headers_subset = true },
      {
        id = "49",
        path = "tests/recordings/llama/scenario-4-49.yaml",
        finish_after = { "30:chunk:3" },
        headers_subset = true,
      },
      { id = "50", path = "tests/recordings/llama/scenario-4-50.yaml", headers_subset = true },
      { id = "51", path = "tests/recordings/llama/scenario-4-51.yaml", headers_subset = true },
    })
    local value = client(scenario)
    local progress = {}
    local selected = runtime(scenario)
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
      return count_requests(scenario, "GET", "/models/sse") == 1
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
    scenario.release("inspected-download")

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
      return count_requests(scenario, "POST", "/models") == 1
        and count_requests(scenario, "GET", "/models?reload=1") == 2
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
    local scenario = start({
      { id = "52", path = "tests/recordings/llama/scenario-5-52.yaml", headers_subset = true },
      { id = "53", path = "tests/recordings/llama/scenario-5-53.yaml", headers_subset = true },
    })
    local selected = runtime(scenario)
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
          base_url = scenario.url .. "/v1",
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
      return count_requests(scenario, "POST", "/v1/chat/completions") == 1
    end))
    local request = find_request(scenario, "POST", "/v1/chat/completions")
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
    local scenario = start({
      { id = "54", path = "tests/recordings/llama/scenario-6-54.yaml", headers_subset = true },
      {
        id = "55",
        path = "tests/recordings/llama/scenario-6-55.yaml",
        open = true,
        gates = {
          ["1"] = { "56:request" },
          ["2"] = { "56:request" },
          ["3"] = { "56:request" },
          ["4"] = { "57:request" },
          ["5"] = { "62:request" },
          ["6"] = { "63:complete" },
          ["7"] = { "67:request" },
        },
        headers_subset = true,
      },
      {
        id = "56",
        path = "tests/recordings/llama/scenario-6-56.yaml",
        finish_after = { "55:chunk:3" },
        headers_subset = true,
      },
      { id = "57", path = "tests/recordings/llama/scenario-6-57.yaml", headers_subset = true },
      { id = "58", path = "tests/recordings/llama/scenario-6-58.yaml", headers_subset = true },
      { id = "60", path = "tests/recordings/llama/scenario-6-60.yaml", headers_subset = true },
      {
        id = "61",
        path = "tests/recordings/llama/scenario-6-61.yaml",
        open = true,
        gates = { ["1"] = { "62:request" }, ["2"] = { "63:complete" }, ["3"] = { "67:request" } },
        headers_subset = true,
      },
      { id = "62", path = "tests/recordings/llama/scenario-6-62.yaml", headers_subset = true },
      { id = "63", path = "tests/recordings/llama/scenario-6-63.yaml", headers_subset = true },
      {
        id = "67",
        path = "tests/recordings/llama/scenario-6-67.yaml",
        finish_after = { "55:chunk:7", "61:chunk:3" },
        headers_subset = true,
      },
    })
    local selected = runtime(scenario)
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
      return count_requests(scenario, "GET", "/models/sse") == 1
    end))

    local configured = {
      _apis = {},
      providers = {
        ["llama.cpp"] = {
          api = "openai-completions",
          base_url = scenario.url .. "/v1",
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
      count_requests(scenario, "POST", "/models/load"))

    assert.is_true(wait(client(scenario):unload_and_wait("fake/unloaded")).ok)
    local failed = wait(client(scenario):load_and_wait("fake/failing", function() end))
    assert.is_false(failed.ok)
    assert(vim.wait(1000, function()
      return failed_progress ~= nil
        and block(service:state(), "progress", "Loading fake/failing") == nil
    end))
    assert.is_nil(block(service:state(), "activity"))

    unsubscribe()
  end)
end)
