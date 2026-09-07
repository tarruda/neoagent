local async = require("neoagent.async")
local llama = require("neoagent.providers.llama")
local llama_catalog = require("neoagent.providers.llama.catalog")
local model_catalog = require("neoagent.model_catalog")
local models_module = require("neoagent.models")
local provider_service = require("neoagent.provider_service")
local fake_transport = require("tests.helpers.fake_transport")
local util = require("neoagent.util")

describe("neoagent llama.cpp Provider Service", function()
  local catalogs = setmetatable({}, { __mode = "k" })

  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

  local function catalog(models)
    return vim.json.encode({ data = models })
  end

  local function model(id, status, extra)
    return vim.tbl_extend("force", {
      id = id,
      status = { value = status },
      meta = { n_ctx = 32000, size = 7 * 1024 * 1024 * 1024 },
    }, extra or {})
  end

  local function service(transport, store, models, auth, ttl_ms, report,
      overrides)
    local provider = {
      api = "openai-completions",
      base_url = "http://127.0.0.1:8080/v1",
      auth_optional = true,
      catalog = { additions = models or {} },
      models = overrides or {},
    }
    local catalog_value = model_catalog.new({
      provider_id = "llama.cpp",
      provider = provider,
      definition = {
        source_id = "llama-cpp-test-models",
        source_revision = 1,
        ttl_ms = type(ttl_ms) == "number" and ttl_ms or 5 * 60 * 1000,
        additions = provider.catalog.additions,
        discover = llama_catalog.discover,
        transform_model = llama_catalog.transform,
      },
      models = provider.models,
      store = store,
      transport = transport,
      authentication = auth,
      report = report,
    })
    local value = llama.new(provider, {
      catalog = catalog_value,
      transport = transport,
      auth = auth,
      report = report,
    })
    catalogs[value] = catalog_value
    return value
  end

  local function catalog_for(value)
    return assert(catalogs[value], "test service has no model catalog")
  end

  local function catalog_models(value)
    local result = vim.tbl_values(catalog_for(value):snapshot().models)
    table.sort(result, function(left, right) return left.id < right.id end)
    return result
  end

  local function catalog_refresh(value, opts)
    opts = opts or {}
    return catalog_for(value):refresh({ force = opts.force == true })
  end

  local function block(snapshot, block_type, label)
    for _, candidate in ipairs(snapshot.blocks or {}) do
      if candidate.type == block_type
          and (label == nil or candidate.label == label) then
        return candidate
      end
    end
  end

  local function browse(value, transport, models)
    transport.fetches[#transport.fetches + 1] = { body = catalog(models) }
    local selected
    local run = provider_service.run(value, "catalog", {
      interact = {
        select = function(options, done)
          selected = options
          done.resolve(nil)
        end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function()
          return { ok = true, configured = false }
        end)
      end,
    })
    assert(wait(run).ok)
    return selected
  end

  it("derives loaded model entries from the router catalog", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({
        model("qwen3", "loaded"),
        model("dolphin", "unloaded"),
        model("vision", "loaded", { architecture = { input_modalities = { "text", "image" } } }),
      }) },
    }
    local value = service(transport)
    assert.are.same({}, catalog_models(value))
    local refresh = catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    })
    wait(refresh)
    local models = catalog_models(value)
    assert.are.same({ "dolphin", "qwen3", "vision" },
      vim.tbl_map(function(entry) return entry.id end, models))
    assert.are.same({ "text", "image" }, models[3].input)
    assert.are.same({ "text" }, models[1].input)
    local state = value:state()
    local endpoint = block(state, "field", "Endpoint")
    assert.are.equal("http://127.0.0.1:8080", endpoint.value)
    assert.are.equal("success", endpoint.level)
    assert.are.equal("qwen3, vision",
      block(state, "field", "Loaded models").value)
    assert.are.equal("3 available",
      block(state, "field", "Models").value)
    assert.is_nil(block(state, "field", "Events"))
    assert.is_nil(block(state, "activity"))
    assert.is_nil(block(state, "list"))
  end)

  it("drops exact overrides when the router omits their model ids", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("current", "loaded") }) },
    }
    local value = service(transport, nil, nil, nil, nil, nil, {
      removed = { context_window = 65536 },
    })

    assert(wait(catalog_refresh(value)).ok)

    assert.are.same({ "current" },
      vim.tbl_map(function(entry) return entry.id end, catalog_models(value)))
  end)

  it("bounds loaded model summaries", function()
    local long_id = string.rep("a", 508) .. "é"
    local transport = fake_transport.new()
    transport.fetches = { { body = catalog({
      model(long_id, "loaded"),
      model("z", "loaded"),
    }) } }
    local value = service(transport)

    local refreshed = wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() return true end,
    }))

    assert.is_true(refreshed.ok)
    assert.are.same({ long_id, "z" },
      vim.tbl_map(function(entry) return entry.id end, catalog_models(value)))
    local loaded_models = block(value:state(), "field", "Loaded models").value
    assert.is_true(util.is_valid_utf8(loaded_models))
    assert.is_true(#loaded_models <= 512)
    assert.are.equal("...", loaded_models:sub(-3))
  end)

  it("reports when no router model is loaded", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = catalog({
      model("qwen3", "unloaded"),
    }) } }
    local value = service(transport)
    assert(wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication)
        publication.update()
        return true
      end,
    })).ok)

    assert.are.equal("No model loaded",
      block(value:state(), "field", "Loaded model").value)
    assert.are.equal("1 available",
      block(value:state(), "field", "Models").value)
  end)

  it("loads a selected model with progress and refresh", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({
        model("qwen3", "unloaded"),
        model("dolphin", "loaded"),
      }) },
      { body = "{}" },
      { body = catalog({ model("qwen3", "loading") }) },
      { body = catalog({ model("qwen3", "loaded") }) },
      { body = catalog({ model("qwen3", "loaded"), model("dolphin", "loaded") }) },
    }
    local value = service(transport)
    local progress = {}
    local choices = {
      { "keep", "qwen3" },
      { "continue" },
    }
    local run = provider_service.run(value, "load", {
      args = "qwen3",
      interact = {
        select = function(options, done)
          done.resolve(table.remove(choices, 1))
          return function() end
        end,
        input = function(_, done) done.reject({ kind = "cancelled" }) return function() end end,
        confirm = function(_, done) done.resolve(true) return function() end end,
        progress = function(update) progress[#progress + 1] = update end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
    assert.is_true(#progress >= 1)
    assert.are.same({ "dolphin", "qwen3" },
      vim.tbl_map(function(entry) return entry.id end, catalog_models(value)))
  end)

  it("unloads a selected loaded model", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "loaded") }) },
      { body = "{}" },
      { body = catalog({ model("qwen3", "unloaded") }) },
      { body = catalog({ model("qwen3", "unloaded") }) },
    }
    local value = service(transport)
    local progress = {}
    local run = provider_service.run(value, "unload", {
      args = "qwen3",
      interact = {
        select = function() end,
        input = function() end,
        confirm = function(_, done) done.resolve(true) return function() end end,
        progress = function(update) progress[#progress + 1] = update end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
    assert.is_true(#progress >= 1)
    assert.are.same({ "qwen3" },
      vim.tbl_map(function(entry) return entry.id end, catalog_models(value)))
  end)

  it("cancels load and unload workflows from user choices", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "unloaded"), model("dolphin", "loaded") }) },
      { body = catalog({ model("qwen3", "loaded") }) },
    }
    local value = service(transport)
    local choices = { "qwen3", "cancel" }
    local run = provider_service.run(value, "load", {
      interact = {
        select = function(_, done)
          done.resolve(table.remove(choices, 1))
          return function() end
        end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
    assert.is_true(result.cancelled)
  end)

  it("downloads a model through Hugging Face search and quant selection", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ { id = "owner/repo", downloads = 100 } }) },
      { body = vim.json.encode({
        id = "owner/repo",
        gated = false,
        siblings = {
          { rfilename = "model-Q4_K_M.gguf", size = 1000 },
        },
      }) },
      { body = catalog({}) },
      { body = "{}" },
      { body = catalog({ model("owner/repo:Q4_K_M", "downloading") }) },
      { body = catalog({ model("owner/repo:Q4_K_M", "loaded") }) },
      { body = catalog({ model("owner/repo:Q4_K_M", "loaded") }) },
    }
    local value = service(transport)
    local progress = {}
    local run = provider_service.run(value, "download", {
      args = "coding",
      interact = {
        select = function(options, done)
          if options.prompt == "Select model" then
            done.resolve("owner/repo")
          else
            done.resolve("Q4_K_M")
          end
          return function() end
        end,
        input = function() end,
        confirm = function() end,
        progress = function(update) progress[#progress + 1] = update end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
    assert.is_true(#progress >= 1)
    assert.are.same({ "owner/repo:Q4_K_M" },
      vim.tbl_map(function(entry) return entry.id end, catalog_models(value)))
  end)

  it("formats context, size, and nonloaded descriptions", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({
        model("small", "loaded", { meta = { n_ctx = 2048, size = 1024 } }),
        model("argctx", "loaded", { meta = {}, status = { value = "loaded", args = { "--ctx-size", "8192" } } }),
        model("ctxflag", "loaded", { meta = {}, status = { value = "loaded", args = { "-ctx", "4096" } } }),
        model("unloadedctx", "unloaded", { meta = {}, status = { value = "unloaded", args = { "--ctx-size=16384" } } }),
        model("failed", "failed"),
        model("preset-one", "unloaded", { source = "preset" }),
        model("dir-one", "loaded", { source = "models_dir" }),
      }) },
    }
    local value = service(transport)
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    local rows = browse(value, transport, {
      model("small", "loaded", { meta = { n_ctx = 2048, size = 1024 } }),
      model("argctx", "loaded", { meta = {}, status = { value = "loaded", args = { "--ctx-size", "8192" } } }),
      model("ctxflag", "loaded", { meta = {}, status = { value = "loaded", args = { "-ctx", "4096" } } }),
      model("unloadedctx", "unloaded", { meta = {}, status = { value = "unloaded", args = { "--ctx-size=16384" } } }),
      model("failed", "failed"),
      model("preset-one", "unloaded", { source = "preset" }),
      model("dir-one", "loaded", { source = "models_dir" }),
    }).items
    local by_id = {}
    for _, row in ipairs(rows) do by_id[row.label] = row.description end
    assert.matches("2k context", by_id.small)
    assert.matches("8k context", by_id.argctx)
    assert.matches("4k context", by_id.ctxflag)
    assert.matches("16k context", by_id.unloadedctx)
    assert.matches("failed", by_id.failed)
    assert.matches("server preset", by_id["preset-one"])
    assert.matches("models dir · loaded", by_id["dir-one"])
    local entries = {}
    for _, entry in ipairs(catalog_models(value)) do entries[entry.id] = entry end
    assert.are.equal(16384, entries.unloadedctx.context_window)
  end)

  it("persists a bounded secret-free catalog projection", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = catalog({
      model("safe", "unloaded", {
        path = "/private/models/safe.gguf",
        meta = {},
        status = {
          value = "unloaded",
          args = { "--hf-token", "super-secret", "--ctx-size", "8192" },
          preset = "hf-token = super-secret",
        },
      }),
    }) } }
    local persisted
    local store = {
      read = function() return nil end,
      write = function(_, _, value) persisted = util.copy(value) return true end,
      delete = function() return true end,
    }
    local value = service(transport, store)
    local result = wait(catalog_refresh(value, { force = true }))
    assert(result.ok, vim.inspect(result.error))
    local encoded = vim.json.encode(persisted)
    assert.is_nil(encoded:find("super%-secret"))
    assert.is_nil(encoded:find("/private/models", 1, true))
    assert.is_nil(encoded:find('"args"', 1, true))
    assert.is_nil(encoded:find('"preset"', 1, true))
    assert.are.equal(8192, persisted.models[1].context_window)
    assert.are.equal(8192, catalog_models(value)[1].context_window)
  end)

  it("subscribes listeners and isolates failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("one", "loaded") }) },
      { body = catalog({ model("two", "loaded") }) },
    }
    local value = service(transport)
    local published
    local unsubscribe = value:subscribe(function(snapshot) published = snapshot end)
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    assert.is_not_nil(published)
    unsubscribe()
    unsubscribe()

    local notifications = {}
    value = service(transport, nil, nil, nil, nil, function(message)
      notifications[#notifications + 1] = message
    end)
    value:subscribe(function() error("listener boom") end)
    transport.fetches[#transport.fetches + 1] = { body = catalog({ model("three", "loaded") }) }
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    assert.matches("listener boom", notifications[1])
  end)

  it("clears failed downloads and ignores unrelated router events", function()
    local function event(kind, data, model_id)
      return "data: " .. vim.json.encode({
        model = model_id == nil and "owner/repo:Q4_K_M" or model_id,
        event = kind,
        data = data or {},
      }) .. "\n\n"
    end
    local transport = fake_transport.new()
    transport.responses = { { chunks = {
      event("model_status", { status = "loading" }, ""),
      event("download_progress", {
        progress = { model = { done = 512, total = 1024 } },
      }),
      event("metadata_changed"),
      event("download_failed", { error = "disk full" }),
    } } }
    local value = service(transport)
    local snapshots = {}
    local unsubscribe = value:subscribe(function(snapshot)
      snapshots[#snapshots + 1] = snapshot
    end)

    assert(vim.wait(1000, function() return #snapshots >= 3 end))
    assert.are.equal(3, #snapshots)
    assert.are.equal(0.5,
      block(snapshots[1], "progress", "Downloading owner/repo:Q4_K_M").value)
    assert.is_nil(block(snapshots[2], "progress"))
    assert.is_nil(block(snapshots[3], "progress"))

    unsubscribe()
    value:destroy()
  end)

  it("runs the refresh operation with resolved metadata", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "loaded") }) },
    }
    local value = service(transport)
    local run = provider_service.run(value, "reload", {
      resolve_auth = function()
        return async.run(function()
          return {
            ok = true,
            configured = true,
            request_opts = { headers = { Authorization = "Bearer local" } },
            metadata = { server_url = "http://mac.lan.internal:8080" },
          }
        end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
    assert.are.same({ "qwen3" },
      vim.tbl_map(function(entry) return entry.id end, catalog_models(value)))
    assert.matches("/models%?reload=1", transport.fetch_requests[1].url)
    assert.are.equal("http://mac.lan.internal:8080",
      block(value:state(), "field", "Endpoint").value)
  end)

  it("describes failed model entries", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({
        model("broken", "unloaded", {
          status = { value = "unloaded", failed = true, exit_code = 9 },
        }),
      }) },
    }
    local value = service(transport)
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    local items = browse(value, transport, {
      model("broken", "unloaded", {
        status = { value = "unloaded", failed = true, exit_code = 9 },
      }),
    }).items
    assert.matches("failed", items[1].description)
  end)

  it("reports empty unload and load catalogs", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({}) },
      { body = catalog({}) },
    }
    local value = service(transport)
    local load = wait(provider_service.run(value, "load", {
      interact = {
        select = function() end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert.is_false(load.ok)
    assert.matches("No unloaded models", load.error.message)

    local unload = wait(provider_service.run(value, "unload", {
      interact = {
        select = function() end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert.is_false(unload.ok)
    assert.matches("No loaded models", unload.error.message)
  end)

  it("cancels unload confirmation and download prompts", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "loaded") }) },
      { body = "{}" },
      { body = vim.json.encode({}) },
    }
    local value = service(transport)
    local unload = wait(provider_service.run(value, "unload", {
      args = "qwen3",
      interact = {
        select = function() end,
        input = function() end,
        confirm = function(_, done) done.resolve(false) return function() end end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert.is_true(unload.ok)
    assert.is_true(unload.cancelled)

    local download = wait(provider_service.run(value, "download", {
      interact = {
        select = function() end,
        input = function(_, done) done.reject({ kind = "cancelled" }) return function() end end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert.is_true(download.ok)
    assert.is_true(download.cancelled)
  end)

  it("replaces loaded models when loading", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "unloaded"), model("dolphin", "loaded") }) },
      { body = "{}" },
      { body = catalog({ model("dolphin", "unloaded") }) },
      { body = "{}" },
      { body = catalog({ model("qwen3", "loading") }) },
      { body = catalog({ model("qwen3", "loaded") }) },
      { body = catalog({ model("qwen3", "loaded") }) },
    }
    local value = service(transport)
    local run = provider_service.run(value, "load", {
      args = "qwen3",
      interact = {
        select = function(_, done) done.resolve("replace") return function() end end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
  end)

  it("selects an unload target interactively", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "loaded") }) },
      { body = "{}" },
      { body = catalog({ model("qwen3", "unloaded") }) },
      { body = catalog({ model("qwen3", "unloaded") }) },
    }
    local value = service(transport)
    local run = provider_service.run(value, "unload", {
      interact = {
        select = function(_, done) done.resolve("qwen3") return function() end end,
        input = function() end,
        confirm = function(_, done) done.resolve(true) return function() end end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
  end)

  it("handles empty Hugging Face results and gated back choices", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = "[]" },
      { body = vim.json.encode({ { id = "owner/repo", downloads = 1 } }) },
      { body = vim.json.encode({ id = "owner/repo", gated = "manual", siblings = {} }) },
    }
    local value = service(transport)
    local empty = wait(provider_service.run(value, "download", {
      args = "none",
      interact = {
        select = function() end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert.is_false(empty.ok)
    assert.matches("No GGUF models found", empty.error.message)

    local gated = wait(provider_service.run(value, "download", {
      args = "gated",
      interact = {
        select = function(options, done)
          if options.prompt == "Select model" then
            done.resolve("owner/repo:Q4_K_M")
          else
            done.resolve("back")
          end
          return function() end
        end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert.is_true(gated.ok)
    assert.is_true(gated.cancelled)
  end)

  it("preserves Hugging Face search and detail failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 503, body = vim.json.encode({ error = "search unavailable" }) },
    }
    local value = service(transport)
    local failed = wait(provider_service.run(value, "download", {
      args = "qwen",
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert.is_false(failed.ok)
    assert.matches("search unavailable", failed.error.message)

    transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ { id = "owner/repo", downloads = 1 } }) },
      { status = 502, body = vim.json.encode({ error = "details unavailable" }) },
    }
    value = service(transport)
    failed = wait(provider_service.run(value, "download", {
      args = "qwen",
      interact = {
        select = function(_, done)
          done.resolve("owner/repo")
          return function() end
        end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert.is_false(failed.ok)
    assert.matches("details unavailable", failed.error.message)
  end)

  it("handles resolved auth without request options or server metadata", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "loaded") }) },
      { body = catalog({ model("qwen3", "loaded") }) },
      { body = catalog({ model("qwen3", "loaded") }) },
    }
    local value = service(transport)
    local first = wait(provider_service.run(value, "reload", {
      resolve_auth = function()
        return async.run(function()
          return { ok = true, configured = true, metadata = { server_url = "" } }
        end)
      end,
    }))
    assert(first.ok, vim.inspect(first.error))

    local second = wait(provider_service.run(value, "reload", {
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    }))
    assert(second.ok, vim.inspect(second.error))

    local third = wait(provider_service.run(value, "reload", {
      resolve_auth = function()
        return async.run(function()
          return {
            ok = true,
            configured = true,
            metadata = { server_url = "http://localhost:9090/v1" },
          }
        end)
      end,
    }))
    assert(third.ok, vim.inspect(third.error))
    assert.are.equal("http://localhost:9090",
      block(value:state(), "field", "Endpoint").value)
  end)

  it("propagates non-cancel interaction failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "unloaded") }) },
    }
    local value = service(transport)
    local run = provider_service.run(value, "load", {
      interact = {
        select = function(_, done)
          done.reject({ kind = "provider", message = "interaction boom" })
          return function() end
        end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert.is_false(result.ok)
    assert.matches("interaction boom", result.error.message)
  end)

  it("refreshes its injected model catalog", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen3", "loaded") }) },
    }
    local store = {
      read = function() return nil end,
      write = function() return true end,
      delete = function() return true end,
    }
    local value = service(transport, store)
    local result = wait(catalog_refresh(value))
    assert(result.ok, vim.inspect(result.error))
    assert.are.same({ "qwen3" },
      vim.tbl_map(function(entry) return entry.id end, catalog_models(value)))
  end)

  it("validates model definitions at construction", function()
    assert.has_error(function()
      local provider = {
        base_url = "http://127.0.0.1:8080/v1",
        models = {},
        service_opts = { poll_interval_ms = 0 },
      }
      llama.new(provider, { catalog = model_catalog.new({
        provider_id = "llama.cpp",
        provider = provider,
        definition = {},
        models = {},
      }) })
    end, "llama.cpp service option poll_interval_ms must be a positive integer")
    assert.has_error(function()
      service(fake_transport.new(), nil, {
        qwen = { hf_repo = "missing-slash", quantization = "Q4_0" },
      })
    end, "llama.cpp model definition qwen: hf_repo must use the org/repo form")
    assert.has_error(function()
      service(fake_transport.new(), nil, {
        qwen = { hf_repo = "owner/repo", load = { ["bad key"] = 1 } },
      })
    end, "llama.cpp model definition qwen: load parameter names must contain letters, numbers, _ or -")
    assert.has_error(function()
      service(fake_transport.new(), nil, {
        qwen = {
          hf_repo = "owner/repo",
          quantization = "Q4_0",
          load = { ctx_size = 0 },
        },
      })
    end, "llama.cpp model definition qwen: load ctx_size must be positive")
    assert.has_error(function()
      service(fake_transport.new(), nil, {
        qwen = {
          hf_repo = "owner/repo:Q4_0",
          quantization = "Q8_0",
        },
      })
    end, "llama.cpp model definition qwen: quantization conflicts with hf_repo")
    assert.has_error(function()
      service(fake_transport.new(), nil, {
        qwen = {
          hf_repo = "owner/repo",
          quantization = "Q4_0",
          request_opts = function() return {} end,
        },
      })
    end, "llama.cpp model definition qwen: request_opts must be a table when the id aliases an HF source")
    local ok, err = pcall(function()
      service(fake_transport.new(), nil, {
        qwen = { request_timeout_ms = "long" },
      })
    end)
    assert.is_false(ok)
    assert.are.equal("model", err.kind)
    assert.matches("request_timeout_ms must be a positive integer", err.message)
  end)

  it("enriches catalog entries from model definitions", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({
        { id = "owner/repo:Q4_0", status = { value = "unloaded" } },
        model("plain", "loaded"),
      }) },
    }
    local value = service(transport, nil, {
      ["owner/repo:Q4_0"] = {
        context_window = 65536,
        max_output_tokens = 8192,
        thinking = { off = { body = { enable_thinking = false } } },
        request_opts = { body = { chat_template_kwargs = { enable_thinking = false } } },
      },
    })
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    local models = catalog_models(value)
    assert.are.same({ "owner/repo:Q4_0", "plain" },
      vim.tbl_map(function(entry) return entry.id end, models))
    assert.are.equal(65536, models[1].context_window)
    assert.are.equal(8192, models[1].max_output_tokens)
    assert.is_table(models[1].thinking)
    assert.is_table(models[1].request_opts)
    assert.are.equal(32000, models[2].context_window)
    assert.is_nil(models[2].request_opts)
  end)

  it("completes provider operation arguments from current state", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({
        model("z-unloaded", "unloaded"),
        model("a-unloaded", "unloaded"),
        model("sleeping", "sleeping"),
        model("loaded", "loaded"),
      }) },
    }
    local value = service(transport, nil, {
      zebra = { context_window = 4096 },
      alpha = { context_window = 4096 },
    })
    local refreshed = wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication)
        publication.update()
        return true
      end,
    }))
    assert(refreshed.ok, vim.inspect(refreshed.error))
    assert.are.same({ "a-unloaded", "z-unloaded" },
      value.operations.load.complete())
    assert.are.same({ "loaded", "sleeping" },
      value.operations.unload.complete())
    assert.are.same({ "alpha", "zebra" },
      value.operations.download.complete())
  end)

  it("emits aliased definitions routed to the router model id", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("owner/repo:Q4_0", "loaded") }) },
    }
    local value = service(transport, nil, {
      qwen = {
        hf_repo = "owner/repo",
        quantization = "Q4_0",
        context_window = 65536,
      },
    })
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    local models = catalog_models(value)
    assert.are.same({ "owner/repo:Q4_0", "qwen" },
      vim.tbl_map(function(entry) return entry.id end, models))
    local alias = models[2]
    assert.are.equal(65536, alias.context_window)
    assert.is_nil(alias.request_opts)

    local items = browse(value, transport, {
      model("owner/repo:Q4_0", "loaded"),
    }).items
    local aliases = vim.tbl_filter(function(item) return item.id == "qwen" end, items)
    assert.are.equal(1, #aliases)
    assert.are.equal("owner/repo:Q4_0", aliases[1].description)
  end)

  it("routes call-specific request options through aliased Models", function()
    local value = service(fake_transport.new(), nil, {
      qwen = { hf_repo = "owner/repo", quantization = "Q4_0" },
    })
    local captured = {}
    local inner = {
      api = "openai-completions",
      provider = "llama.cpp",
      id = "qwen",
      input = { "text" },
      stream = function(_, opts)
        captured[#captured + 1] = opts.request_opts
        return async.run(function() return { ok = true } end)
      end,
    }
    local wrapped = value:wrap_model(inner)
    local seen_request
    assert.is_true(wait(wrapped:stream({
      request_opts = function(ctx)
        seen_request = util.copy(ctx.request)
        return { body = { temperature = 0.25 } }
      end,
    })).ok)
    local resolved = captured[1]({
      request = { body = { top_p = 0.9 } },
    })
    assert.are.same({ model = "owner/repo:Q4_0", top_p = 0.9 },
      seen_request.body)
    assert.are.same({ model = "owner/repo:Q4_0", temperature = 0.25 },
      resolved.body)

    assert.is_true(wait(wrapped:stream({
      request_opts = { body = { temperature = 0.5 } },
    })).ok)
    assert.are.same({ model = "owner/repo:Q4_0", temperature = 0.5 },
      captured[2].body)
  end)

  it("publishes watcher authentication and catalog request failures", function()
    local auth = {
      resolve = function()
        return async.run(function()
          return {
            ok = false,
            error = util.error("auth", "router login failed"),
          }
        end)
      end,
    }
    local watched = service(fake_transport.new(), nil, nil, auth)
    local unsubscribe = watched:subscribe(function() end)
    assert(vim.wait(1000, function()
      return block(watched:state(), "field", "Endpoint").level == "error"
    end, 5))
    unsubscribe()

    local transport = fake_transport.new()
    transport.fetches = {
      {
        status = 503,
        body = vim.json.encode({ error = "router unavailable" }),
      },
    }
    local failed = service(transport)
    local result = wait(provider_service.run(failed, "reload", {
      resolve_auth = function()
        return async.run(function()
          return { ok = true, configured = false }
        end)
      end,
    }))
    assert.is_false(result.ok)
    assert.matches("router unavailable", result.error.message)
    assert.are.equal("error",
      block(failed:state(), "field", "Endpoint").level)
  end)

  it("routes aliased load and unload operations to the router model id", function()
    local router_id = "owner/repo:Q4_0"
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model(router_id, "unloaded") }) },
      { body = "{}" },
      { body = catalog({ model(router_id, "loaded") }) },
      { body = catalog({ model(router_id, "loaded") }) },
      { body = catalog({ model(router_id, "loaded") }) },
      { body = "{}" },
      { body = catalog({ model(router_id, "unloaded") }) },
      { body = catalog({ model(router_id, "unloaded") }) },
    }
    local value = service(transport, nil, {
      qwen = { hf_repo = "owner/repo", quantization = "Q4_0" },
    })
    local interaction = {
      select = function() end,
      input = function() end,
      confirm = function(_, done) done.resolve(true) return function() end end,
      progress = function() end,
      notify = function() end,
    }
    local function context()
      return {
        args = "qwen",
        interact = interaction,
        resolve_auth = function()
          return async.run(function()
            return { ok = true, configured = false }
          end)
        end,
      }
    end

    local loaded = wait(provider_service.run(value, "load", context()))
    assert.is_true(loaded.ok)
    local unloaded = wait(provider_service.run(value, "unload", context()))
    assert.is_true(unloaded.ok)

    assert.are.equal(router_id,
      vim.json.decode(transport.fetch_requests[2].body).model)
    assert.are.equal(router_id,
      vim.json.decode(transport.fetch_requests[6].body).model)
  end)

  it("cancels a searched download from quantization selection", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ { id = "owner/repo", downloads = 10 } }) },
      { body = vim.json.encode({
        id = "owner/repo",
        gated = false,
        siblings = { { rfilename = "model-Q4_K_M.gguf", size = 1000 } },
      }) },
    }
    local value = service(transport)
    local selection = 0
    local result = wait(provider_service.run(value, "download", {
      args = "coding",
      interact = {
        select = function(_, done)
          selection = selection + 1
          done.resolve(selection == 1 and "owner/repo" or nil)
          return function() end
        end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function()
          return { ok = true, configured = false }
        end)
      end,
    }))

    assert.is_true(result.ok)
    assert.is_true(result.cancelled)
    assert.are.equal(2, selection)
    assert.are.equal(2, #transport.fetch_requests)
  end)

  it("downloads defined models without a Hugging Face search", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        id = "owner/repo",
        gated = false,
        siblings = {},
      }) },
      { body = catalog({}) },
      { body = "{}" },
      { body = catalog({ model("owner/repo:Q4_0", "downloading") }) },
      { body = catalog({ model("owner/repo:Q4_0", "unloaded") }) },
      { body = catalog({ model("owner/repo:Q4_0", "unloaded") }) },
    }
    local value = service(transport, nil, {
      qwen = {
        hf_repo = "owner/repo",
        quantization = "Q4_0",
        load = { ctx_size = 32768, gpu_layers = 99, flash_attn = true },
      },
    })
    local run = provider_service.run(value, "download", {
      args = "qwen",
      interact = {
        select = function() end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
    assert.is_nil(transport.fetch_requests[1].url:find("/api/models%?"))
    local body = vim.json.decode(transport.fetch_requests[3].body)
    assert.are.equal("owner/repo:Q4_0", body.model)
    assert.are.same({ "owner/repo:Q4_0", "qwen" },
      vim.tbl_map(function(entry) return entry.id end, catalog_models(value)))
  end)

  it("downloads unquantized definitions from their configured repository", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        id = "owner/repo",
        gated = false,
        siblings = {
          { rfilename = "model-Q4_K_M.gguf", size = 1000 },
          { rfilename = "model-Q8_0.gguf", size = 2000 },
        },
      }) },
      { body = catalog({}) },
      { body = "{}" },
      { body = catalog({ model("owner/repo:Q8_0", "downloading") }) },
      { body = catalog({ model("owner/repo:Q8_0", "unloaded") }) },
      { body = catalog({ model("owner/repo:Q8_0", "unloaded") }) },
    }
    local value = service(transport, nil, {
      qwen = { hf_repo = "owner/repo" },
    })
    local prompts = {}
    local run = provider_service.run(value, "download", {
      args = "qwen",
      interact = {
        select = function(options, done)
          prompts[#prompts + 1] = options.prompt
          done.resolve("Q8_0")
          return function() end
        end,
        input = function() end,
        confirm = function() end,
        progress = function() end,
        notify = function() end,
      },
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
    assert.are.same({ "Select quantization\nowner/repo" }, prompts)
    assert.matches(
      "/api/models/owner/repo%?blobs=true$", transport.fetch_requests[1].url)
    assert.is_nil(transport.fetch_requests[1].url:find("?search=", 1, true))
    local body = vim.json.decode(transport.fetch_requests[3].body)
    assert.are.equal("owner/repo:Q8_0", body.model)
  end)

  it("merges definitions ahead of server preset models", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({
        model("other.gguf", "loaded"),
        { id = "owner/repo:Q4_0", status = { value = "unloaded" } },
      }) },
    }
    local value = service(transport, nil, {
      ["my-gemma"] = {
        context_window = 32768,
        input = { "text", "image" },
      },
      qwen = {
        hf_repo = "owner/repo",
        quantization = "Q4_0",
        context_window = 65536,
      },
    })
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    local models = catalog_models(value)
    assert.are.same({
      "my-gemma", "other.gguf", "owner/repo:Q4_0", "qwen",
    },
      vim.tbl_map(function(entry) return entry.id end, models))
    assert.are.equal(32768, models[1].context_window)
    assert.are.same({ "text", "image" }, models[1].input)
    assert.is_nil(models[1].request_opts)
    assert.are.equal(32000, models[2].context_window)
    assert.is_nil(models[3].context_window)
    assert.are.equal(65536, models[4].context_window)
  end)

  it("preserves definition inference parameters through model resolution", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen-test", "unloaded") }) },
    }
    local definitions = {
      ["qwen-test"] = {
        thinking = {
          off = { body = { chat_template_kwargs = { enable_thinking = false } } },
        },
        request_opts = { body = { max_tokens = 80000 } },
      },
    }
    local value = service(transport, nil, definitions)
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    local captured
    local configured = {
      providers = {
        ["llama.cpp"] = {
          api = "openai-completions",
          base_url = "http://127.0.0.1:8080/v1",
          models = definitions,
        },
      },
      _apis = {
        ["openai-completions"] = function(resolved)
          captured = util.copy(resolved.model)
          return {
            api = resolved.api,
            provider = resolved.provider_id,
            id = resolved.model_id,
            input = util.copy(resolved.model.input or { "text" }),
            context_window = resolved.model.context_window,
            thinking = util.copy(resolved.model.thinking),
            stream = function()
              return async.run(function() return { ok = true } end)
            end,
          }
        end,
      },
    }
    local model = models_module.resolve(
      "llama.cpp", "qwen-test", configured, nil, {
        ["llama.cpp"] = {
          id = "llama.cpp",
          definition = configured.providers["llama.cpp"],
          catalog = catalog_for(value),
          service = value,
        },
      })
    assert.is_table(model)
    assert.are.equal("qwen-test", captured.id)
    assert.are.same({ enable_thinking = false },
      captured.thinking.off.body.chat_template_kwargs)
    assert.are.equal(80000, captured.request_opts.body.max_tokens)
  end)

  it("guards model stream timeouts while the router is not ready", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = catalog({ model("qwen-test", "unloaded") }) },
    }
    local value = service(transport, nil, {
      ["qwen-test"] = { request_timeout_ms = 60000 },
    })
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    local captured = {}
    local events = {}
    local inner = {
      api = "openai-completions",
      provider = "llama.cpp",
      id = "qwen-test",
      input = { "text" },
      context_window = 4096,
      thinking = {},
      timeout_ms = 60000,
      stream = function(_, opts)
        captured[#captured + 1] = vim.deepcopy(opts)
        return async.run(function(run)
          run:emit({ type = "text_delta" })
          return { ok = true, text = "ok" }
        end, { on_event = opts.on_event })
      end,
    }
    local wrapped = value:wrap_model(inner)
    assert.are.equal("qwen-test", wrapped.id)
    assert.are.equal(60000, wrapped.timeout_ms)

    local before = #transport.fetch_requests
    local result = wait(wrapped:stream({
      messages = {},
      on_event = function(event) events[#events + 1] = event.type end,
    }))
    assert.is_true(result.ok)
    assert.is_false(captured[1].timeout_ms)
    assert.are.equal(before, #transport.fetch_requests)
    assert(vim.wait(100, function() return #events == 1 end))
    assert.are.same({ "text_delta" }, events)

    transport.fetches = { { body = catalog({ model("qwen-test", "loaded") }) } }
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    before = #transport.fetch_requests
    assert.is_true(wait(wrapped:stream({
      messages = {},
      timeout_ms = 60000,
    })).ok)
    assert.are.equal(60000, captured[2].timeout_ms)
    assert.are.equal(before, #transport.fetch_requests)

    transport.fetches = { { body = catalog({ model("qwen-test", "loading") }) } }
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    assert.is_true(wait(wrapped:stream({
      messages = {},
    })).ok)
    assert.is_false(captured[3].timeout_ms)

    transport.fetches = { { body = catalog({}) } }
    wait(catalog_refresh(value, {
      allow_network = true,
      publish = function(publication) publication.update() end,
    }))
    assert.is_true(wait(wrapped:stream({
      messages = {},
    })).ok)
    assert.is_false(captured[4].timeout_ms)

    assert.is_true(wait(wrapped:stream({
      messages = {},
      timeout_ms = 30000,
    })).ok)
    assert.are.equal(30000, captured[5].timeout_ms)

    before = #transport.fetch_requests
    assert.is_true(wait(wrapped:stream({
      messages = {},
      timeout_ms = false,
    })).ok)
    assert.are.equal(before, #transport.fetch_requests)
    assert.is_false(captured[#captured].timeout_ms)

    before = #transport.fetch_requests
    local plain = {
      api = "openai-completions",
      provider = "llama.cpp",
      id = "plain",
      input = { "text" },
      stream = function(_, opts)
        captured[#captured + 1] = vim.deepcopy(opts)
        return async.run(function() return { ok = true, text = "ok" } end)
      end,
    }
    assert.is_true(wait(value:wrap_model(plain):stream({ messages = {} })).ok)
    assert.are.equal(before, #transport.fetch_requests)
    assert.is_nil(captured[#captured].timeout_ms)
  end)

  it("publishes independent concurrent requests and their latest usage", function()
    local value = service(fake_transport.new())
    local pending = {}
    local inner = {
      api = "openai-completions",
      provider = "llama.cpp",
      id = "shared",
      input = { "text" },
      stream = function(_, opts)
        return async.run(function()
          return async.await(function(done)
            pending[#pending + 1] = done
            return function() end
          end)
        end, { on_event = opts.on_event })
      end,
    }
    local wrapped = value:wrap_model(inner)
    local first = wrapped:stream({ messages = {} })
    local second = wrapped:stream({ messages = {} })
    assert(vim.wait(1000, function() return #pending == 2 end))
    local function request_count()
      return #vim.tbl_filter(function(candidate)
        return candidate.type == "progress"
          and candidate.label == "Request · shared"
      end, value:state().blocks)
    end
    assert.are.equal(2, request_count())

    pending[1].resolve({
      ok = true,
      message = { usage = { inputTokens = 10, outputTokens = 2 } },
    })
    assert.is_true(wait(first).ok)
    assert.are.equal(1, request_count())
    pending[2].resolve({
      ok = true,
      message = { usage = { inputTokens = 20, outputTokens = 4 } },
    })
    assert.is_true(wait(second).ok)
    local response = block(value:state(), "field", "Last response")
    assert.are.equal("20 in · 4 out", response.value)
  end)

  it("publishes streamed usage and request failures", function()
    local value = service(fake_transport.new())
    local usage_model = {
      api = "openai-completions",
      provider = "llama.cpp",
      id = "usage",
      input = { "text" },
      stream = function(_, opts)
        return async.run(function(run)
          run:emit({
            type = "usage",
            usage = { input_tokens = 7, output_tokens = 3 },
          })
          return { ok = true }
        end, { on_event = opts.on_event })
      end,
    }
    assert.is_true(wait(value:wrap_model(usage_model):stream({})).ok)
    assert.are.equal("7 in · 3 out",
      block(value:state(), "field", "Last response").value)

    local failed_model = {
      api = "openai-completions",
      provider = "llama.cpp",
      id = "failure",
      input = { "text" },
      stream = function()
        return async.run(function()
          return { ok = false, error = util.error("model", "failed") }
        end)
      end,
    }
    local failed = wait(value:wrap_model(failed_model):stream({}))
    assert.is_false(failed.ok)
    assert.is_nil(block(value:state(), "activity"))
  end)

  it("renders defined load parameters as a router preset", function()
    local transport = fake_transport.new()
    local value = service(transport, nil, {
      ["owner/repo:Q4_0"] = {
        load = { ctx_size = 32768, gpu_layers = 99, flash_attn = true },
      },
      qwen = {
        hf_repo = "owner/other",
        quantization = "Q8_0",
        load = {
          threads = 8,
          flash_attn = false,
          zeta = 2,
          cache_ram = "8G",
          alpha = 1,
        },
      },
      plain = { context_window = 4096 },
    })
    local rows = browse(value, transport, {}).items
    assert.are.same({ "owner/repo:Q4_0", "plain", "qwen" },
      vim.tbl_map(function(row) return row.label end, rows))
    assert.are.equal("ctx 32768 · gpu-layers 99 · flash-attn", rows[1].description)
    assert.are.equal("configured model", rows[2].description)
    assert.are.equal(
      "owner/other:Q8_0 · threads 8 · no-flash-attn · alpha 1 · cache-ram 8G · zeta 2",
      rows[3].description)

    local run = provider_service.run(value, "preset", {
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local result = wait(run)
    assert(result.ok, vim.inspect(result.error))
    assert.are.equal("document", result.artifact.kind)
    assert.are.equal("llama.cpp router preset", result.artifact.name)
    assert.are.equal("dosini", result.artifact.filetype)
    local lines = vim.split(result.artifact.content, "\n", { plain = true })
    assert.are.same({
      "version = 1",
      "",
      "[owner/repo:Q4_0]",
      "c = 32768",
      "n-gpu-layers = 99",
      "flash-attn = on",
      "",
      "[owner/other:Q8_0]",
      "hf-repo = owner/other:Q8_0",
      "t = 8",
      "flash-attn = off",
      "alpha = 1",
      "cache-ram = 8G",
      "zeta = 2",
      "",
    }, lines)

    local empty = provider_service.run(service(fake_transport.new()), "preset", {
      resolve_auth = function()
        return async.run(function() return { ok = true, configured = false } end)
      end,
    })
    local empty_result = wait(empty)
    assert.is_false(empty_result.ok)
    assert.matches("No model definitions", empty_result.error.message)
  end)
end)
