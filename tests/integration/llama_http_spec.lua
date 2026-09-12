local assert = require("luassert")
local llama = require("neoagent.providers.llama")
local llama_catalog = require("neoagent.providers.llama.catalog")
local llama_client = require("neoagent.providers.llama.client")
local http_replay = require("tests.helpers.http_replay")
local model_catalog = require("neoagent.model_catalog")
local models = require("neoagent.models")
local registry = require("neoagent.registry")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@param timeout? integer
---@return Neoagent.RunResult<T>
local function wait(run, timeout)
  assert(vim.wait(timeout or 5000, function() return run:is_done() end))
  return (assert(run:result()))
end

---@param entries Neoagent.LlamaModelInfo[]
---@return string[]
local function ids(entries)
  return vim.tbl_map(function(entry) return entry.id end, entries)
end

local block = require("tests.helpers.provider_state").block

---@param scenario Neoagent.TestHttpReplay
---@param method string
---@param path string
---@return { headers: table<string, string>, body?: Neoagent.JsonValue }?
local function find_request(scenario, method, path)
  for _, value in ipairs(scenario.requests) do
    if (value.method or "POST") == method and value.url == scenario.url .. path then
      ---@type { headers: table<string, string>, body?: Neoagent.JsonValue }
      local request = { headers = {} }
      request.headers = {}
      for key, item in pairs(value.headers or {}) do request.headers[key:lower()] = item end
      if value.body then request.body = vim.json.decode(value.body) end
      return request
    end
  end
end

---@param scenario Neoagent.TestHttpReplay
---@param method string
---@param path string
---@return integer
local function count_requests(scenario, method, path)
  local count = 0
  for _, value in ipairs(scenario.requests) do
    if (value.method or "POST") == method and value.url == scenario.url .. path then count = count + 1 end
  end
  return count
end

describe("llama.cpp router HTTP integration", function()
  ---@type Neoagent.TestHttpReplay[]
  local scenarios = {}
  ---@type Neoagent.ProviderRuntime[]
  local runtimes = {}

  after_each(function()
    for _, runtime in ipairs(runtimes) do
      assert(runtime.service.destroy)(runtime.service)
      runtime.catalog:destroy()
    end
    for _, scenario in ipairs(scenarios) do http_replay.finish(scenario) end
    scenarios = {}
    runtimes = {}
  end)

  ---@param exchanges (string|Neoagent.ReplayEntryOptions)[]
  ---@return Neoagent.TestHttpReplay
  local function start(exchanges)
    local scenario = http_replay.open(exchanges)
    scenarios[#scenarios + 1] = scenario
    return scenario
  end

  ---@param scenario Neoagent.TestHttpReplay
  ---@return Neoagent.LlamaClient
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

  ---@param scenario Neoagent.TestHttpReplay
  ---@return Neoagent.ProviderRuntime
  local function runtime(scenario)
    ---@type Neoagent.ProviderDefinition
    local definition = {
      api = "openai-completions",
      base_url = scenario.url .. "/v1",
      auth_optional = true,
      request_opts = assert(registry.defaults()["llama.cpp"]).request_opts,
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
      auth_services = {},
      credentials = require("neoagent.provider_credentials").new({
        provider_id = "llama.cpp", provider = definition,
      }),
      transport = scenario,
      definition = definition,
      catalog = catalog,
      service = llama.new({
        api = definition.api, base_url = definition.base_url,
        auth_optional = definition.auth_optional,
        service_opts = definition.service_opts,
      }, {
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
    assert(initial.ok)
    assert.are.same({ "fake/loaded", "fake/unloaded", "fake/failing" },
      ids(initial.value))
    assert.are.equal("loaded", assert(initial.value[1]).status.value)
    assert.are.same({ "text", "image" },
      assert(assert(initial.value[1]).architecture).input_modalities)
    assert.are.equal("unloaded", assert(initial.value[2]).status.value)

    ---@type Neoagent.LlamaProgress[]
    local progress = {}
    local loaded = wait(value:load_and_wait("fake/unloaded", function(update)
      progress[#progress + 1] = update
    end))
    assert(loaded.ok)
    assert.are.equal("loaded", loaded.value.status.value)
    assert(vim.wait(1000, function()
      return vim.tbl_contains(vim.tbl_map(function(update)
        return update.message
      end, progress), "Loading text model")
    end))

    local unloaded = wait(value:unload_and_wait("fake/unloaded"))
    assert(unloaded.ok)
    local final = wait(value:list())
    assert(final.ok)
    assert.are.equal("unloaded", assert(assert(final.value)[2]).status.value)

    assert(vim.wait(1000, function()
      return count_requests(scenario, "POST", "/models/load") == 1
        and count_requests(scenario, "POST", "/models/unload") == 1
    end))
    local load_request = find_request(scenario, "POST", "/models/load")
    assert.are.equal("Bearer router-key", rawget(assert(load_request).headers, "authorization"))
    assert.are.same({ model = "fake/unloaded" }, assert(load_request).body)
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
    assert.are.equal("model is not found", assert(missing.error).message)
    assert.are.equal(404, rawget(assert(missing.error), "status"))

    local failed = wait(value:load_and_wait("fake/failing", function() end))
    assert.is_false(failed.ok)
    assert.are.equal("provider", assert(failed.error).kind)
    assert.are.equal("Model exited with code 42", assert(failed.error).message)
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
    ---@type Neoagent.Run<Neoagent.LlamaLoadSuccess|Neoagent.AsyncFailure, nil>?
    local run
    run = value:load_and_wait("fake/unloaded", function(update)
      if update.ratio then assert(run):cancel() end
    end)

    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
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
    ---@type Neoagent.LlamaProgress[]
    local progress = {}
    local selected = runtime(scenario)
    local service = selected.service
    assert.is_true(wait(selected.catalog:refresh({ force = true })).ok)
    ---@type Neoagent.ProviderProgressBlock?
    local dashboard_progress
    local dashboard_updates = 0
    local unsubscribe = assert(service.subscribe)(service, function(snapshot)
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
    assert(downloading.ok)
    local active = vim.tbl_filter(function(entry)
      return entry.id == "fake/downloaded:Q4_K_M"
    end, downloading.value)[1]
    assert.are.equal("downloading", assert(active).status.value)
    assert.is_nil(assert(active).status.progress)
    scenario.release("inspected-download")

    local result = wait(run)
    assert(result.ok)
    assert.is_true(vim.tbl_contains(ids(result.value), "fake/downloaded:Q4_K_M"))
    assert.are.equal("Download complete", assert(progress[#progress]).message)
    assert.are.equal(1, assert(progress[#progress]).ratio)
    assert.is_not_nil(dashboard_progress)
    assert.are.equal("512 B / 1.00 KiB", assert(dashboard_progress).detail)
    assert(vim.wait(1000, function()
      return block(service:state(), "progress",
        "Downloading fake/downloaded:Q4_K_M") == nil
    end))
    assert.are.equal("success",
      assert(block(service:state(), "field", "Endpoint")).level)
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

  for _, string_timings in ipairs({ false, true }) do
    it("refreshes the catalog and streams image inference with " .. (string_timings and "string" or "numeric") .. " timings", function()
      local exchange = require("neoagent.http_replay").read("tests/recordings/llama/scenario-5-53.yaml")
      if string_timings then
        -- Preserve captured SSE semantics while exercising numeric metadata
        -- encoded as strings by an OpenAI-compatible endpoint.
        exchange.body = exchange.body:gsub('"timings":(%b{})', function(encoded)
          local timings = vim.json.decode(encoded)
          for key, value in pairs(timings) do timings[key] = tostring(value) end
          return '"timings":' .. vim.json.encode(timings)
        end)
        exchange.chunks = {{ data = exchange.body, bytes = #exchange.body, at_us = 1000 }}
      end
      local scenario = start({
        { id = "52", path = "tests/recordings/llama/scenario-5-52.yaml", headers_subset = true },
        { id = "53", exchange = exchange, headers_subset = true },
      })
      local selected = runtime(scenario)
      local service = selected.service

      local refreshed = wait(selected.catalog:refresh({ force = true }))
      assert(refreshed.ok)
      local discovered = vim.tbl_keys(selected.catalog:snapshot().models)
      table.sort(discovered)
      assert.are.same({ "fake/failing", "fake/loaded", "fake/unloaded" },
        discovered)

      local configured = {
        auth = { path = "unused-credentials.json", methods = {} },
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
      local attachments = require("tests.helpers.attachments").new()
      local inference_stats = {}
      local streamed = wait(model:stream({
        files = attachments.files,
        messages = { { role = "user", content = {
          { type = "text", text = "What is in this image?" },
          attachments.image(vim.base64.decode(png)),
        } } },
        on_event = function(event)
          if event.type == "inference_stats" then
            inference_stats[#inference_stats + 1] = event
          end
        end,
      }))
      assert(streamed.ok)
      assert.are.equal("image accepted", streamed.text)
      assert.are.same({
        type = "thinking",
        thinking = "checking the image",
        thinkingSignature = "reasoning_content",
      }, streamed.message.content[1])
      assert.are.same({ type = "text", text = "image accepted" },
        streamed.message.content[2])
      assert.are.equal(7, assert(streamed.message.usage).totalTokens)
      assert(vim.wait(1000, function()
        return count_requests(scenario, "POST", "/v1/chat/completions") == 1
      end))
      local request = find_request(scenario, "POST", "/v1/chat/completions")
      assert.are.equal("fake/loaded", assert(assert(request).body).model)
      assert.is_true(assert(assert(request).body).stream)
      assert.is_true(assert(assert(request).body).timings_per_token)
      assert.is_true(assert(assert(request).body).return_progress)
      assert.are.same({ include_usage = true }, assert(assert(request).body).stream_options)
      assert.are.same({
        type = "inference_stats",
        generation_tokens_per_second = 50,
      }, inference_stats[#inference_stats])
      assert.are.same({
        type = "image_url",
        image_url = { url = "data:image/png;base64," .. png },
      }, assert(assert(assert(assert(assert(request).body).messages)[1]).content)[2])
    end)
  end

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

    ---@type Neoagent.ProviderProgressBlock?
    local visible_progress
    ---@type Neoagent.ProviderProgressBlock?
    local failed_progress
    local unsubscribe = assert(service.subscribe)(service, function(snapshot)
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
      auth = { path = "unused-credentials.json", methods = {} },
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
    assert(result.ok)
    assert.are.equal("fake reply", result.text)
    assert(vim.wait(1000, function() return visible_progress ~= nil end))
    assert.are.equal("Loading fake/unloaded", assert(visible_progress).label)
    assert.are.equal(0.25, assert(visible_progress).value)
    local settled = vim.wait(1000, function()
      return block(service:state(), "progress", "Loading fake/unloaded") == nil
        and block(service:state(), "field", "Last response") ~= nil
    end)
    assert(settled, vim.inspect(service:state()))
    assert.are.equal("3 in · 4 out",
      assert(block(service:state(), "field", "Last response")).value)
    assert.are.equal("success",
      assert(block(service:state(), "field", "Endpoint")).level)
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
