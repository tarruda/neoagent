local assert = require("luassert")
local auth = require("neoagent.auth")
local config = require("neoagent.config")
local fake_transport = require("tests.helpers.fake_transport")
local models = require("neoagent.models")
local provider_runtimes = require("neoagent.provider_runtimes")
local provider_shell = require("neoagent.provider_shell")
local fs = require("neoagent.fs")

local block = require("tests.helpers.provider_state").block
local PROVIDER = "qwencloud-token-plan"
local USAGE = "qwencloud-token-plan-usage"
local ACTIVATE = "https://account.qwencloud.com/activate?token=synthetic-device-token"
local USAGE_TOKEN = "synthetic:management-token"
local DERIVED_TOKEN = "synthetic:individual-gateway"

---@param data Neoagent.JsonObject
---@return Neoagent.TestByteResponse
local function individual_reply(data)
  return {
    body = vim.json.encode({
      code = "200",
      successResponse = true,
      data = {
        success = true,
        DataV2 = {
          ret = { "SUCCESS::ok" },
          data = { code = "SUCCESS", success = true, data = data },
        },
      },
    }),
  }
end

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function()
    return run:is_done()
  end))
  return (assert(run:result()))
end

describe("QwenCloud Token Plan usage", function()
  ---@type Neoagent.ProviderRuntimes?
  local runtimes
  ---@type Neoagent.ProviderShell?
  local shell
  ---@type Neoagent.Presenter?
  local presenter
  ---@type Neoagent.Recorder?
  local recorder
  ---@type string
  local directory

  before_each(function()
    directory = vim.fn.tempname()
  end)

  after_each(function()
    if shell then
      shell:destroy()
      shell = nil
    end
    if presenter then
      presenter:destroy()
      presenter = nil
    end
    provider_runtimes.destroy(runtimes)
    runtimes = nil
    if recorder then
      recorder:destroy()
      recorder = nil
    end
    vim.fn.delete(directory, "rf")
  end)

  it("updates the open Provider Shell when usage authorization expires", function()
    local async = require("neoagent.async")
    local configured = config.resolve({
      default_registry = false,
      auth = { path = directory .. "/auth.json" },
      providers = { [PROVIDER] = require("neoagent.registry.qwencloud_token_plan") },
    })
    local now = 1798761600000
    local expires = now + 100
    local store = require("neoagent.auth.store").new(configured.auth.path)
    assert(store:write(USAGE, { type = "oauth", access = USAGE_TOKEN, expires = expires }))
    local manager = auth.new({
      methods = configured.auth.methods,
      store = store,
      now = function()
        return now
      end,
    })
    local transport = fake_transport.new()
    transport.fetches = {
      { body = [[{"code":"200","data":{"IsGray":true}}]] },
      { body = [[{"code":"200","data":{"SubscriptionGroupList":[{"TotalValue":"100","SurplusValue":"50"}]}}]] },
      { body = [[{"code":"200","data":{"Data":[]}}]] },
    }
    local providers = assert(provider_runtimes.compose(configured, {
      auth = manager,
      transport = transport,
      startup = false,
    }))
    runtimes = providers
    local panel = provider_shell.new({ config = configured, auth = manager, runtimes = providers })
    shell = panel
    assert(panel:open())
    local buffer = assert(assert(panel:view():pane("provider")):native().buffer)
    local function rendered()
      return (table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"):gsub("%s+", " "))
    end
    assert(vim.wait(2000, function()
      return not panel:is_active() and rendered():find("Monthly Credits", 1, true) ~= nil
    end, 5), "Expected quotas to appear before expiry")
    assert.matches("Logged in", rendered(), 1, true)
    assert.is_true(wait(async.run(function()
      async.yield()
      return { ok = true }
    end)).ok)

    now = expires
    assert(vim.wait(2000, function()
      return rendered():find("Authorization expired", 1, true) ~= nil
    end, 5), "The open Provider Shell did not show credential expiry")
    assert.is_nil((rendered():find("Monthly Credits", 1, true)))
    assert.matches("Log in for usage", rendered(), 1, true)
    assert.are.same({}, panel:operations())
    assert.are.equal(3, #transport.fetch_requests)
  end)

  it("logs in for usage without an inference key and keeps both credentials independent", function()
    local selected = { provider = PROVIDER, model = "qwen3.8-max" }
    local fallback = { provider = "fallback", model = "ready" }
    local snapshot = config.snapshot({
      default_registry = false,
      default_profile = "pi",
      default_model = fallback,
      auth = { path = directory .. "/auth.json" },
      persistence = { enabled = true, workspace_settings = true, directory = directory .. "/sessions" },
      providers = {
        [PROVIDER] = require("neoagent.registry.qwencloud_token_plan"),
        fallback = { api = "openai-completions", base_url = "https://example.invalid/v1", models = { ready = {} } },
      },
    })
    local configured = snapshot.config
    local transport = fake_transport.new()
    local directory_recordings = directory .. "/recordings"
    local recording = assert((require("neoagent.http_recording").new({
      config = { enabled = true, format = "json", retention = "all" },
      directory = directory_recordings,
    })))
    recorder = recording
    local recorded = recording:transport(transport)
    local manager = auth.configured({ auth = configured.auth }, { transport = recorded })
    local providers = assert(provider_runtimes.compose(configured, {
      auth = manager,
      transport = recorded,
      startup = false,
    }))
    runtimes = providers
    local provider = assert(providers[PROVIDER])
    local presentation = require("neoagent.presenter").new()
    presenter = presentation
    local url
    presentation:attach({
      present = function(snapshot)
        local active = snapshot.active
        if active and active.kind == "select" then
          vim.schedule(function()
            assert(presentation:resolve(active.id, "yes"))
          end)
        elseif active and active.kind == "input" then
          vim.schedule(function()
            assert(presentation:resolve(active.id, "sk-sp-synthetic-inference-key"))
          end)
        end
        return true
      end,
      notify = function() end,
      open_uri = function(uri)
        url = uri
        return true
      end,
    })
    local panel = provider_shell.new({
      config = configured,
      auth = manager,
      runtimes = providers,
      presenter = presentation,
    })
    shell = panel
    assert((panel:select(PROVIDER)))
    local function operations()
      return vim.tbl_map(function(operation)
        return operation.id
      end, panel:operations())
    end
    local function offers_inference()
      local choices = assert(models.available(configured, manager, providers))
      return vim.tbl_contains(choices, PROVIDER .. "/" .. selected.model)
    end
    local workspace = directory .. "/workspace"
    assert(fs.mkdirp(workspace))
    assert(
      require("neoagent.workspace_settings")
        .new({ root = workspace, directory = configured.persistence.directory })
        :write({ default_model = selected })
    )
    local function workspace_choice()
      return require("neoagent.profiles.selection").resolve({
        snapshot = snapshot,
        profiles = { pi = { id = "pi", label = "Pi" } },
        policy = "pi",
        workspace = workspace,
        auth = manager,
        runtimes = providers,
      })
    end
    ---@param operation string
    local function run(operation)
      local pending, err = panel:run(operation)
      assert(type(pending) == "table", err and err.message)
      local result = wait(pending)
      assert.is_true(result.ok, result.error and result.error.message)
    end

    assert.are.equal(USAGE, (configured.providers[PROVIDER].auth_scopes or {}).usage)
    local actions = assert(panel:info()).operations
    assert.are.equal("Log in for usage", assert(actions[2]).label)
    assert.are.same({}, operations())
    local device_response = {
      body = vim.json.encode({
        Success = true,
        Data = {
          Token = "synthetic-device-token",
          VerificationUrl = ACTIVATE,
          ExpiresIn = 900,
          Interval = 1,
        },
      }),
    }
    transport.fetches = {
      device_response,
      {
        body = vim.json.encode({
          Success = true,
          Data = {
            Status = "complete",
            Credentials = {
              AccessToken = USAGE_TOKEN,
              ExpireTime = "2099-01-01T00:00:00Z",
              User = { Email = "synthetic-private-user@example.test" },
            },
          },
        }),
      },
      { body = [[{"code":"200","data":{"IsGray":true}}]] },
      { body = [[{"code":"200","data":{"Success":true,"Data":{}}}]] },
      { body = [[{"code":"200","data":{"Data":[]}}]] },
      {
        body = vim.json.encode({ code = "200", successResponse = true, data = { cliAccessToken = DERIVED_TOKEN } }),
      },
      individual_reply({
        status = "VALID",
        instanceCode = "synthetic-subscription",
        specCode = "essential",
        startTime = 946684800000,
        endTime = 4070908800000,
      }),
      individual_reply({ per1WeekPercentage = 0.25, per1WeekResetTime = 1798761600000 }),
      {
        body = [[{"code":"200","data":{"Data":[
        {"Status":{"Code":"valid"},"CurrCapacityBaseValue":"12.25"}
      ]}}]],
      },
      device_response,
      {
        body = [[{"Success":true,"Data":{"Status":"complete","Credentials":{
        "AccessToken":"synthetic-renewed-token","ExpireTime":"2199-01-01T00:00:00Z"
      }}}]],
      },
    }
    run("neoagent.auth.login:usage")
    assert.are.equal(ACTIVATE, url)
    local state = assert(assert(panel:info()).state)
    local usage = assert(block(state, "field", "QwenCloud usage"))
    assert.are.equal("Logged in", usage.value)
    assert.is_true((manager:has_credentials(USAGE)))
    local poll = assert(transport.fetch_requests[2])
    local verifier = assert(poll.url:match("code_verifier=([^&]+)"))
    assert.is_true(assert(transport.fetch_requests[1]).private_input)
    assert.is_true(poll.private_input)
    local paths = vim.fn.globpath(directory_recordings, "**/*.jsonl", false, true)
    assert.are.equal(2, #paths)
    for _, path in ipairs(paths) do
      local body = assert((fs.read(path)))
      for _, secret in ipairs({
        "synthetic-device-token",
        USAGE_TOKEN,
        "synthetic-private-user@example.test",
        verifier,
      }) do
        assert.is_nil((body:find(secret, 1, true)))
      end
    end
    assert.matches("only for usage", assert(wait(manager:resolve(USAGE)).error).message, 1, true)
    assert.is_false((manager:has_credentials(PROVIDER)))
    assert.are.same({ "refresh" }, operations())
    assert.is_false(offers_inference())
    assert.are.equal(2, #transport.fetch_requests)

    run("refresh")
    local quota = assert(provider.service:state())
    local status = block(quota, "status")
    assert.is_nil(status, status and status.text)
    local weekly = assert(block(quota, "limit", "Weekly Credits"))
    assert.are.equal(0.75, weekly.remaining)
    assert.are.equal(1798761600, weekly.resets_at)
    assert.is_nil(weekly.detail)
    assert.are.equal("Individual Essential", assert(block(quota, "field", "Plan")).value)
    local addon = assert(block(quota, "field", "Add-on Credits remaining"))
    assert.are.equal("12.25", addon.value)
    for _, index in ipairs({ 3, 4, 5, 6, 9 }) do
      local request = assert(transport.fetch_requests[index])
      assert.are.equal("https://cli.qwencloud.com/data/v2/api.json", request.url)
      assert.is_true(request.private_input)
      assert.are.equal("Bearer " .. USAGE_TOKEN, rawget(assert(request.headers), "Authorization"))
    end
    local issue = assert(transport.fetch_requests[6])
    assert.are.same({
      product = "ModelStudioRegional",
      action = "GenerateCLIAccessToken",
      version = "2026-02-10",
      region = "ap-southeast-1",
      params = vim.empty_dict(),
    }, vim.json.decode((assert(issue.body))))
    for index, action in ipairs({ "subscription", "usage" }) do
      local api = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/" .. action
      local request = assert(transport.fetch_requests[6 + index])
      assert.are.equal(
        "https://ap-southeast-1-cs-data.qwencloud.com/cli/api.json"
          .. "?action=IntlBroadScopeAspnGateway&product=sfm_bailian&api="
          .. vim.uri_encode(api, "rfc3986"),
        request.url
      )
      assert.is_true(request.private_input)
      local headers = assert(request.headers)
      assert.are.equal("Bearer " .. DERIVED_TOKEN, rawget(headers, "Authorization"))
      assert.are.equal("application/x-www-form-urlencoded", rawget(headers, "Content-Type"))
      local encoded = assert(assert(request.body):match("^params=([^&]+)&region=ap%-southeast%-1$"))
      local payload = vim.json.decode(vim.uri_decode(encoded))
      assert.are.equal(api, payload.Api)
      assert.are.equal("1.0", payload.V)
      assert.are.equal(action == "subscription" and "sfm_tokenplansolo_public_intl" or nil, payload.Data.commodityCode)
      assert.are.same({
        protocol = "V2",
        console = "ONE_CONSOLE",
        xsp_lang = "en-US",
        productCode = "p_efm",
        switchUserType = 3,
        consoleSite = "QWENCLOUD",
      }, payload.Data.cornerstoneParam)
    end
    local recorded_quota = vim.fn.globpath(directory_recordings, "**/*.jsonl", false, true)
    assert.are.equal(9, #recorded_quota)
    for _, path in ipairs(recorded_quota) do
      local contents = assert((fs.read(path)))
      assert.is_nil((contents:find(USAGE_TOKEN, 1, true)))
      assert.is_nil((contents:find(DERIVED_TOKEN, 1, true)))
    end
    assert.is_nil((assert((fs.read(configured.auth.path))):find(DERIVED_TOKEN, 1, true)))

    run("neoagent.auth.login")
    assert.is_true(offers_inference())
    assert.are.same(selected, workspace_choice().config.default_model)
    assert.are.same({ "refresh" }, operations())
    assert.is_not_nil(block(assert(provider.service:state()), "limit", "Weekly Credits"))
    transport.responses = {
      {
        chunks = {
          'data: {"choices":[{"index":0,"delta":{"content":"Synthetic reply."},"finish_reason":"stop"}]}\n\n',
          "data: [DONE]\n\n",
        },
      },
    }
    local model = models.resolve(PROVIDER, selected.model, configured, manager, providers)
    local reply = wait(model:stream({ messages = { { role = "user", content = "Synthetic request." } } }))
    assert.are.equal("Synthetic reply.", reply.text)
    local inference = assert(transport.requests[1])
    assert.matches("/compatible-mode/v1/chat/completions", inference.url, 1, true)
    assert.are.equal("Bearer sk-sp-synthetic-inference-key", rawget(assert(inference.headers), "Authorization"))

    run("neoagent.auth.logout")
    assert.are.same({ "refresh" }, operations())
    assert.is_true((manager:has_credentials(USAGE)))
    assert.is_not_nil(block(assert(provider.service:state()), "limit", "Weekly Credits"))
    assert.is_false(offers_inference())
    local choice = workspace_choice()
    assert.are.same(fallback, choice.config.default_model)
    assert.matches("Not logged in for inference", assert(choice.warnings[1]), 1, true)

    run("neoagent.auth.login")
    manager.now = function()
      return 4102444800000
    end
    assert.are.same({}, operations())
    local expired = assert(panel:info())
    local expired_state = assert(expired.state)
    local usage_auth = assert(block(expired_state, "field", "QwenCloud usage"))
    local value = usage_auth.value
    assert(type(value) == "string")
    assert.matches("expired", value, 1, true)
    assert.is_nil(block(expired_state, "limit", "Weekly Credits"))
    assert.is_nil(block(expired_state, "field", "Add-on Credits remaining"))
    assert.is_true(vim.tbl_contains(
      vim.tbl_map(function(operation)
        return operation.id
      end, expired.operations),
      "neoagent.auth.login:usage"
    ))
    run("neoagent.auth.login:usage")
    assert.are.same({ "refresh" }, operations())
    assert.is_nil(block(assert(provider.service:state()), "limit", "Weekly Credits"))
    assert.is_true(offers_inference())
    manager.now = function()
      return 7307251200000
    end
    run("neoagent.auth.logout:usage")
    assert.are.same({}, operations())
    assert.is_nil(block(assert(provider.service:state()), "limit", "Weekly Credits"))
    assert.is_true((manager:has_credentials(PROVIDER)))
    assert.is_true(offers_inference())
    assert.are.equal(11, #transport.fetch_requests)
  end)
end)
