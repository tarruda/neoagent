local assert = require("luassert")
local config = require("neoagent.config")
local models = require("neoagent.models")
local replay = require("neoagent.http_replay")
local runtimes_module = require("neoagent.provider_runtimes")
local util = require("neoagent.util")
local workspace_storage = require("neoagent.workspace_storage")

local PNG =
  "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAAAIklEQVR4nGP4z8BAEiJR+X9SlY9aMGrBqAWjFoxaMCAWAABQpv4QX+h4RQAAAABJRU5ErkJggg=="
local MODEL = "claude-sonnet-5"
local WORKSPACE_A, WORKSPACE_B = "wrkspc_review_a", "wrkspc_review_b"

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  if not vim.wait(5000, function()
    return run:is_done()
  end) then
    run:cancel()
    error("Anthropic file request did not settle")
  end
  return (assert(run:result()))
end

-- Adapt existing synthetic-content captures; keep Authentication and HTTP
-- decoding real while varying provider workspace and optional metadata.
---@param exchange Neoagent.ReplayExchange
---@param value Neoagent.JsonObject
local function response_body(exchange, value)
  exchange.body = util.json_encode(value)
  exchange.chunks = { { data = exchange.body, bytes = #exchange.body, at_us = 1000 } }
end

---@param workspace? string
---@param id string
---@param omit_expiry? boolean
---@return Neoagent.ReplayEntryOptions
local function upload(workspace, id, omit_expiry)
  local exchange = replay.read("tests/recordings/anthropic/managed-files/01.yaml")
  local headers = util.copy(exchange.request.headers or {})
  headers["anthropic-workspace-id"] = workspace
  exchange.request.headers = headers
  local body = vim.json.decode(exchange.body)
  body.id = id
  if omit_expiry then
    body.expires_at = nil
  end
  response_body(exchange, body)
  return { exchange = exchange, headers_subset = true }
end

---@param workspace? string
---@param id string
---@param rejected? boolean
---@return Neoagent.ReplayEntryOptions
local function inference(workspace, id, rejected)
  local exchange = replay.read("tests/recordings/anthropic/managed-files/" .. (rejected and "05" or "02") .. ".yaml")
  local headers = util.copy(exchange.request.headers or {})
  headers["anthropic-workspace-id"] = workspace
  exchange.request.headers = headers
  exchange.request.body = util.json_encode({
    model = MODEL,
    stream = true,
    max_tokens = 1024,
    messages = {
      {
        role = "user",
        content = {
          { type = "text", text = "(see attached image)" },
          { type = "image", source = { type = "file", file_id = id } },
        },
      },
    },
  })
  if rejected then
    response_body(
      exchange,
      {
        type = "error",
        error = {
          type = "not_found_error",
          message = "File `" .. id .. "` not found.",
        },
      }
    )
  end
  return { exchange = exchange, headers_subset = true }
end

---@param workspace string
---@param id string
---@return Neoagent.ReplayEntryOptions
local function missing(workspace, id)
  local exchange = replay.read("tests/recordings/anthropic/managed-files/06.yaml")
  local headers = util.copy(exchange.request.headers or {})
  headers["anthropic-workspace-id"] = workspace
  exchange.request.headers = headers
  exchange.request.url = "https://api.anthropic.com/v1/files/" .. id
  response_body(
    exchange,
    {
      type = "error",
      error = {
        type = "not_found_error",
        message = "File `" .. id .. "` not found.",
      },
    }
  )
  return { exchange = exchange, headers_subset = true }
end

describe("Anthropic workspace file access", function()
  ---@type Neoagent.ProviderRuntimes?
  local runtimes
  ---@type Neoagent.HttpReplay?
  local scenario
  ---@type Neoagent.WorkspaceStorage?
  local workspace
  ---@type Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>[]
  local runs = {}
  after_each(function()
    for _, run in ipairs(runs) do
      run:cancel()
    end
    if runtimes then
      runtimes_module.destroy(runtimes)
      runtimes = nil
    end
    local completed = scenario
    if completed then
      completed.close()
      scenario = nil
    end
    assert(vim.wait(5000, function()
      for _, run in ipairs(runs) do
        if not run:is_done() then
          return false
        end
      end
      return true
    end))
    runs = {}
    if workspace then
      vim.fn.delete(workspace.directory, "rf")
      workspace = nil
    end
    config._reset()
  end)

  ---@param entries Neoagent.ReplayEntryOptions[]
  ---@return fun(selected?: string, header_name?: string): Neoagent.Run<Neoagent.ModelResult, Neoagent.ModelEvent>
  ---@return fun()
  local function fixture(entries)
    scenario = replay.new({ exchanges = entries })
    local configured = config.setup({
      default_registry = false,
      providers = {
        anthropic = {
          api = "anthropic-messages",
          base_url = "https://api.anthropic.com/v1",
          auth = "anthropic",
          models = { [MODEL] = { input = { "text", "image" }, max_output_tokens = 1024 } },
        },
      },
    })
    local auth = require("tests.helpers.auth_manager").new(configured.auth.methods)
    assert(auth.store:write("anthropic", { type = "api_key", key = "upload-replay-key" }))
    workspace = workspace_storage.new(vim.fn.tempname())
    local attachments = require("tests.helpers.attachments").new(workspace.files)
    local image = attachments.image(vim.base64.decode(PNG))
    ---@type Neoagent.Model
    local model
    local function restart()
      if runtimes then
        runtimes_module.destroy(runtimes)
      end
      runtimes = assert(runtimes_module.compose(configured, { auth = auth, transport = scenario, startup = false }))
      model = models.resolve("anthropic", MODEL, configured, auth, runtimes)
    end
    restart()
    return function(selected, header_name)
      local run = model:stream({
        files = attachments.files,
        file_cache = assert(workspace).file_cache,
        messages = { { role = "user", content = { image } } },
        request_opts = { headers = { [header_name or "anthropic-workspace-id"] = selected } },
      })
      runs[#runs + 1] = run
      return run
    end,
      restart
  end

  it("carries case-insensitive workspace selection through upload, inspection and repair", function()
    local send = fixture({
      upload(WORKSPACE_A, "file-scope-a"),
      inference(WORKSPACE_A, "file-scope-a"),
      inference(WORKSPACE_A, "file-scope-a", true),
      missing(WORKSPACE_A, "file-scope-a"),
      upload(WORKSPACE_A, "file-scope-replacement"),
      inference(WORKSPACE_A, "file-scope-replacement"),
    })
    for _ = 1, 2 do
      local result = wait(send(WORKSPACE_A, "Anthropic-Workspace-Id"))
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.equal("blue, red", assert(result.text):lower())
    end
    assert.are.equal(6, #assert(scenario).requests)
    assert(scenario).assert_consumed()
  end)

  it("separates simultaneous uploads and persisted mappings for the same key in different workspaces", function()
    local first, second = upload(nil, "file-scope-a"), upload(nil, "file-scope-b")
    -- Workspace headers are checked by the repair test. Here matching permits
    -- either header shape so the regression isolates producer/cache identity.
    first.finish_after, second.finish_after = { "release-uploads" }, { "release-uploads" }
    local send, restart = fixture({
      first,
      second,
      inference(WORKSPACE_A, "file-scope-a"),
      inference(WORKSPACE_B, "file-scope-b"),
      inference(WORKSPACE_A, "file-scope-a"),
      inference(WORKSPACE_B, "file-scope-b"),
      upload(nil, "file-scope-default"),
      inference(nil, "file-scope-default"),
    })
    local a, b = send(WORKSPACE_A), send(WORKSPACE_B)
    assert(
      vim.wait(1000, function()
        return #assert(scenario).requests == 2
      end),
      "different workspaces shared one upload producer"
    )
    assert(scenario).release("release-uploads")
    for _, run in ipairs({ a, b }) do
      local result = wait(run)
      assert.is_true(result.ok, vim.inspect(result.error))
    end
    assert.are.equal(2, #vim.fn.globpath(assert(workspace).directory .. "/provider-cache", "*/*.json", false, true))
    restart()
    for _, selected in ipairs({ WORKSPACE_A, WORKSPACE_B }) do
      local result = wait(send(selected))
      assert.is_true(result.ok, vim.inspect(result.error))
    end
    local unscoped = wait(send())
    assert.is_true(unscoped.ok, vim.inspect(unscoped.error))
    assert.are.equal(3, #vim.fn.globpath(assert(workspace).directory .. "/provider-cache", "*/*.json", false, true))
    assert(scenario).assert_consumed()
  end)

  it("continues inference when successful upload metadata omits the optional expiry", function()
    local send = fixture({ upload(nil, "file-no-expiry", true), inference(nil, "file-no-expiry") })
    local result = wait(send())
    assert.is_true(result.ok, vim.inspect(result.error))
    assert(scenario).assert_consumed()
  end)

  for _, invalid in ipairs({ "", "wrkspc_invalid\nheader" }) do
    it("keeps images inline when workspace selection is invalid: " .. vim.inspect(invalid), function()
      local expected = inference(invalid, "unused")
      local exchange = assert(expected.exchange)
      local body = vim.json.decode((assert(exchange.request.body)))
      body.messages[1].content[2].source = { type = "base64", media_type = "image/png", data = PNG }
      exchange.request.body = util.json_encode(body)
      local send = fixture({ expected })
      local result = wait(send(invalid))
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.equal(1, #assert(scenario).requests)
      assert.are.equal(0, #vim.fn.globpath(assert(workspace).directory .. "/provider-cache", "*/*.json", false, true))
      assert(scenario).assert_consumed()
    end)
  end
end)
