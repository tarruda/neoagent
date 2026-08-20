local llama = require("neoagent.providers.llama")
local llama_client = require("neoagent.providers.llama.client")
local llama_server = require("tests.helpers.llama_server")
local models = require("neoagent.models")

local function wait(run, timeout)
  assert(vim.wait(timeout or 5000, function() return run:is_done() end))
  return run:result()
end

local function ids(entries)
  return vim.tbl_map(function(entry) return entry.id end, entries)
end

describe("llama.cpp router HTTP integration", function()
  local servers = {}

  after_each(function()
    for _, server in ipairs(servers) do server:stop() end
    servers = {}
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
    local service = llama.new({
      api = "openai-completions",
      base_url = server.url .. "/v1",
      auth_optional = true,
      models = {},
    }, {
      explicit = true,
      startup = false,
    })
    assert.is_true(wait(service:refresh_catalog({ allow_network = true })).ok)
    local dashboard_progress
    local unsubscribe = service:subscribe(function(snapshot)
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
      for _, candidate in ipairs(service:state().blocks) do
        if candidate.type == "activity" then
          for _, entry in ipairs(candidate.entries) do
            if entry.message == "Downloaded fake/downloaded:Q4_K_M" then
              return true
            end
          end
        end
      end
      return false
    end))
    assert(vim.wait(1000, function()
      return server:count_requests("POST", "/models") == 1
        and server:count_requests("GET", "/models?reload=1") == 1
    end))

    assert.is_true(wait(value:download("fake/failing-download")).ok)
    assert(vim.wait(1000, function()
      for _, candidate in ipairs(service:state().blocks) do
        if candidate.type == "activity" then
          for _, entry in ipairs(candidate.entries) do
            if entry.message == "Download failed for fake/failing-download" then
              return true
            end
          end
        end
      end
      return false
    end))
    unsubscribe()
    service:destroy()
  end)

  it("refreshes the dynamic catalog and streams inference through the router", function()
    local server = start()
    local service = llama.new({
      api = "openai-completions",
      base_url = server.url .. "/v1",
      auth_optional = true,
      models = {},
      service_opts = {
        wait_timeout_ms = 3000,
        download_timeout_ms = 3000,
        poll_interval_ms = 10,
      },
    }, {
      explicit = true,
      startup = false,
    })

    local refreshed = wait(service:refresh_catalog({ allow_network = true }))
    assert.is_true(refreshed.ok)
    assert.are.same({ "fake/loaded", "fake/failing", "fake/unloaded" },
      ids(service:get_models()))

    local configured = {
      apis = {},
      providers = {
        ["llama.cpp"] = {
          api = "openai-completions",
          base_url = server.url .. "/v1",
          auth_optional = true,
          models = {},
        },
      },
    }
    local model = models.resolve("llama.cpp", "fake/loaded",
      configured, nil, { ["llama.cpp"] = service })
    assert.are.same({ "text", "image" }, model.input)
    local png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC"
      .. "AAAAC0lEQVR42mP8/x8AAusB9Wl5ZAAAAABJRU5ErkJggg=="
    local streamed = wait(model:stream({
      messages = { { role = "user", content = {
        { type = "text", text = "What is in this image?" },
        { type = "image", mimeType = "image/png", data = png },
      } } },
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
    assert.are.same({ include_usage = true }, request.body.stream_options)
    assert.are.same({
      type = "image_url",
      image_url = { url = "data:image/png;base64," .. png },
    }, request.body.messages[1].content[2])

    service:destroy()
  end)

  it("pushes implicitly loaded model progress from router SSE", function()
    local server = start()
    local service = llama.new({
      api = "openai-completions",
      base_url = server.url .. "/v1",
      auth_optional = true,
      models = {},
      service_opts = {
        wait_timeout_ms = 3000,
        download_timeout_ms = 3000,
        poll_interval_ms = 10,
      },
    }, {
      explicit = true,
      startup = false,
    })
    assert.is_true(wait(service:refresh_catalog({ allow_network = true })).ok)

    local visible_progress
    local unsubscribe = service:subscribe(function(snapshot)
      for _, block in ipairs(snapshot.blocks or {}) do
        if block.type == "progress" and block.value == 0.25 then
          local presentation = require("neoagent.ui.provider_presentation").render({
            name = "llama.cpp",
            state = snapshot,
            operations = {},
          }, { width = 48 })
          visible_progress = table.concat(presentation.content.lines, "\n")
        end
      end
    end)
    assert(vim.wait(1000, function()
      return server:count_requests("GET", "/models/sse") == 1
    end))

    local configured = {
      apis = {},
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
      configured, nil, { ["llama.cpp"] = service })
    local result = wait(model:stream({
      messages = { { role = "user", content = "hello" } },
    }))
    assert.is_true(result.ok)
    assert.are.equal("fake reply", result.text)
    assert(vim.wait(1000, function() return visible_progress ~= nil end))
    assert.matches("Loading fake/unloaded", visible_progress)
    assert.matches("25%%", visible_progress)
    local final = table.concat(vim.tbl_map(function(block)
      if block.type ~= "activity" then return "" end
      return table.concat(vim.tbl_map(function(entry) return entry.message end,
        block.entries), "\n")
    end, service:state().blocks), "\n")
    assert.matches("Loaded fake/unloaded", final)
    assert.matches("Completed response · fake/unloaded", final)
    assert.are.equal(0,
      server:count_requests("POST", "/models/load"))

    assert.is_true(wait(client(server):unload_and_wait("fake/unloaded")).ok)
    local failed = wait(client(server):load_and_wait("fake/failing", function() end))
    assert.is_false(failed.ok)
    assert(vim.wait(1000, function()
      local messages = {}
      for _, candidate in ipairs(service:state().blocks) do
        if candidate.type == "activity" then
          for _, entry in ipairs(candidate.entries) do
            messages[entry.message] = true
          end
        end
      end
      return messages["Unloaded fake/unloaded"]
        and messages["Model failed: fake/failing"]
    end))

    unsubscribe()
    service:destroy()
  end)
end)
