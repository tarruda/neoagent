local async = require("neoagent.async")
local codex = require("neoagent.providers.codex")
local provider_service = require("neoagent.provider_service")
local fake_transport = require("tests.helpers.fake_transport")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end))
  return run:result()
end

describe("neoagent Codex provider service", function()
  local function block(snapshot, block_type, label)
    for _, candidate in ipairs(snapshot.blocks or {}) do
      if candidate.type == block_type
          and (label == nil or candidate.label == label) then
        return candidate
      end
    end
  end

  local function list_block(snapshot, title)
    for _, candidate in ipairs(snapshot.blocks or {}) do
      if candidate.type == "list" and candidate.title == title then
        return candidate
      end
    end
  end

  local function auth_context()
    return async.run(function()
      return {
        ok = true,
        configured = true,
        credential_type = "oauth",
        request_opts = { headers = {
          Authorization = "Bearer secret-token",
          ["chatgpt-account-id"] = "secret-account",
        } },
        metadata = { email = "account@example.com", plan = "Plus" },
      }
    end)
  end

  local function interact(confirm)
    local function unused(_, done)
      done.reject({ kind = "provider", message = "unused interaction" })
    end
    return {
      select = unused,
      input = unused,
      confirm = function(_, done) done.resolve(confirm ~= false) end,
      progress = function() end,
      notify = function() end,
    }
  end

  local function operation(service, id, confirm)
    return provider_service.run(service, id, {
      resolve_auth = auth_context,
      interact = interact(confirm),
    })
  end

  it("labels structured quota windows", function()
    assert.are.equal("Usage", codex.duration_label(nil))
    assert.are.equal("1 day", codex.duration_label(1440))
    assert.are.equal("2 days", codex.duration_label(2880))
    assert.are.equal("2h", codex.duration_label(120))
    assert.are.equal("45m", codex.duration_label(45))
  end)

  it("pushes structured quota meters and connection state from provider events", function()
    local service = codex.new({ base_url = "https://chatgpt.com/backend-api" })
    assert.are.equal("openai-codex", service.id)
    assert.are.equal("Codex", service.name)
    local operation_ids = vim.tbl_keys(service.operations)
    table.sort(operation_ids)
    assert.are.same({
      "activity", "redeem", "refresh", "reset_credits", "workspaces",
    }, operation_ids)
    assert.are.same({}, service:state().blocks)

    local initial, err = require("neoagent.provider_state").normalize(service:state())
    assert(initial, err and err.message)
    assert.are.same({}, initial.blocks)

    local published
    local unsubscribe = service:subscribe(function(snapshot)
      published = snapshot
    end)
    service:on_event({
      type = "provider_status",
      text = "weekly 84% left · 5h 60% left",
      details = {
        source = "headers",
        limits = {
          {
            id = "codex",
            primary = {
              used_percent = 40, remaining = 0.6,
              window_minutes = 300, resets_at = 1787793900,
            },
            secondary = {
              used_percent = 16, remaining = 0.84,
              window_minutes = 10080, resets_at = 1787870220,
            },
          },
          {
            id = "codex-sonic", name = "Sonic",
            primary = {
              used_percent = 20, remaining = 0.8,
              window_minutes = 43200,
            },
          },
        },
        credits = { has_credits = true, unlimited = false, balance = "12.50" },
      },
    })

    local snapshot = service:state()
    assert.is_nil(block(snapshot, "status"))
    assert.are.equal(0.6, block(snapshot, "limit", "5h limit").remaining)
    assert.are.equal(1787793900,
      block(snapshot, "limit", "5h limit").resets_at)
    assert.are.equal(0.84,
      block(snapshot, "limit", "Weekly limit").remaining)
    assert.are.equal(0.8,
      block(snapshot, "limit", "Sonic monthly limit").remaining)
    assert.are.equal("12.50",
      block(snapshot, "field", "Credits").value)
    assert.are.equal(0.84,
      block(published, "limit", "Weekly limit").remaining)
    snapshot.blocks[2].remaining = 0
    assert.are.equal(0.84,
      block(service:state(), "limit", "Weekly limit").remaining)

    service:on_event({ type = "provider_status", text = "Reconnecting… 1/3" })
    snapshot = service:state()
    assert.are.same({
      type = "status", text = "Reconnecting… 1/3", level = "warn",
    }, snapshot.blocks[1])
    assert.are.equal(0.84,
      block(snapshot, "limit", "Weekly limit").remaining)

    unsubscribe()
    service:on_event({ type = "provider_status", text = "weekly 50% left" })
    assert.are.equal("Reconnecting… 1/3", published.blocks[1].text)

    service:destroy()
    assert.are.same({}, service:state().blocks)
  end)

  it("pushes request token usage without polling", function()
    local service = codex.new()
    local publications = 0
    service:subscribe(function() publications = publications + 1 end)
    service:on_event({
      type = "usage",
      usage = { inputTokens = 1250, outputTokens = 87, totalTokens = 1337 },
    })
    local snapshot = service:state()
    assert.are.equal("Last response", snapshot.blocks[#snapshot.blocks].label)
    assert.are.equal("1,250 in · 87 out",
      snapshot.blocks[#snapshot.blocks].value)
    assert.are.equal(1, publications)
  end)

  it("ignores events without usable status or usage", function()
    local service = codex.new()
    service:on_event({ type = "usage" })
    service:on_event({ type = "provider_status" })
    assert.are.same({}, service:state().blocks)
  end)

  it("ignores provider status that exceeds dashboard bounds", function()
    local service = codex.new()
    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message) notifications[#notifications + 1] = message end
    service:on_event({
      type = "provider_status",
      text = string.rep("x", 513),
    })
    vim.notify = original_notify
    assert.are.equal(0, #notifications)
    assert.are.same({}, service:state().blocks)
  end)

  it("keeps startup, unavailable, and API-key states explicit", function()
    local transport = fake_transport.new()
    transport.fetches = { { body = "{}" } }
    local service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = transport,
    })
    local unsubscribe = service:subscribe(function() end)
    vim.wait(20)
    assert.are.equal(0, #transport.fetch_requests)
    unsubscribe()

    assert.is_true(wait(operation(service, "refresh")).ok)
    local snapshot = service:state()
    assert.matches("quota information unavailable",
      block(snapshot, "status").text)
    assert.are.equal("account@example.com (Plus)",
      block(snapshot, "field", "Account").value)
    assert.is_nil(vim.inspect(snapshot):find("checked_at", 1, true))

    service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = fake_transport.new(),
    })
    local result = wait(provider_service.run(service, "refresh", {
      resolve_auth = function()
        return async.run(function()
          return {
            ok = true,
            configured = true,
            credential_type = "api_key",
            request_opts = { headers = { Authorization = "Bearer secret" } },
          }
        end)
      end,
      interact = interact(),
    }))
    assert.is_false(result.ok)
    snapshot = service:state()
    assert.matches("API key authentication", block(snapshot, "status").text)
    assert.is_nil(vim.inspect(snapshot):find("Bearer secret", 1, true))
  end)

  it("refreshes authoritative account quotas and marks old data stale", function()
    local clock = 1000
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      plan_type = "self_serve_business_usage_based",
      rate_limit = {
        primary_window = {
          used_percent = 45,
          limit_window_seconds = 18000,
          reset_at = 1787793900,
        },
        secondary_window = {
          used_percent = 3,
          limit_window_seconds = 604800,
          reset_at = 1787870220,
        },
      },
      additional_rate_limits = { {
        limit_name = "Sonic",
        metered_feature = "codex_sonic",
        rate_limit = { primary_window = {
          used_percent = 20,
          limit_window_seconds = 2592000,
          reset_at = 1790000000,
        } },
      } },
      credits = {
        has_credits = true, unlimited = false, balance = "$12.50",
      },
      spend_control = {
        reached = false,
        individual_limit = {
          remaining_percent = 75,
          remaining = "$75",
          limit = "$100",
          reset_at = 1790000000,
        },
      },
      rate_limit_reset_credits = { available_count = 2 },
    }) } }
    local service = codex.new({
      base_url = "https://chatgpt.com/backend-api",
    }, {
      transport = transport,
      now = function() return clock end,
    })
    local result = wait(operation(service, "refresh"))
    assert.is_true(result.ok)
    local snapshot = service:state()
    assert.is_nil(block(snapshot, "status"))
    assert.are.equal("account@example.com (Business)",
      block(snapshot, "field", "Account").value)
    assert.are.equal(0.55,
      block(snapshot, "limit", "5h limit").remaining)
    assert.are.equal(0.97,
      block(snapshot, "limit", "Weekly limit").remaining)
    assert.are.equal(0.8,
      block(snapshot, "limit", "Sonic monthly limit").remaining)
    assert.are.equal("$12.50",
      block(snapshot, "field", "Credits").value)
    assert.are.equal(0.75,
      block(snapshot, "limit", "Monthly spend control").remaining)
    assert.are.equal("2",
      block(snapshot, "field", "Reset credits").value)
    assert.are.equal("GET", transport.fetch_requests[1].method)

    clock = clock + 15 * 60 * 1000 + 1
    snapshot = service:state()
    assert.matches("Usage data is stale", block(snapshot, "status").text)
    assert.are.equal(0.97,
      block(snapshot, "limit", "Weekly limit").remaining)
  end)

  it("clears recovered reconnect state without hiding usage warnings", function()
    local clock = 1000
    local transport = fake_transport.new()
    transport.fetches = { { body = vim.json.encode({
      rate_limit = { primary_window = {
        used_percent = 45,
        limit_window_seconds = 604800,
      } },
    }) } }
    local service = codex.new({
      base_url = "https://chatgpt.com/backend-api",
    }, {
      transport = transport,
      now = function() return clock end,
    })
    assert.is_true(wait(operation(service, "refresh")).ok)

    service:on_event({
      type = "provider_status",
      text = "Reconnecting… 1/4",
      reconnecting = true,
    })
    assert.matches("Reconnecting", block(service:state(), "status").text)
    service:on_event({ type = "provider_status", reconnecting = false })
    assert.is_nil(block(service:state(), "status"))
    assert.are.equal(0.55,
      block(service:state(), "limit", "Weekly limit").remaining)

    clock = clock + 15 * 60 * 1000 + 1
    assert.matches("Usage data is stale",
      block(service:state(), "status").text)
    service:on_event({
      type = "provider_status",
      text = "Reconnecting… 1/4",
      reconnecting = true,
    })
    assert.matches("Reconnecting", block(service:state(), "status").text)
    service:on_event({ type = "provider_status", reconnecting = false })
    assert.matches("Usage data is stale",
      block(service:state(), "status").text)
  end)

  it("renders account quota variants and bounded window durations", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        rate_limit = {
          primary_window = {
            used_percent = 10,
            limit_window_seconds = 86400,
          },
          secondary_window = {
            used_percent = 20,
            limit_window_seconds = 172800,
          },
        },
        additional_rate_limits = {
          {
            limit_name = "Sonic",
            metered_feature = "sonic",
            rate_limit = { primary = {
              remaining = 0.7, window_minutes = 120,
            } },
          },
          {
            limit_name = "Pulse",
            metered_feature = "pulse",
            rate_limit = { primary = {
              remaining = 0.6, window_minutes = 45,
            } },
          },
          {
            limit_name = "Metered",
            metered_feature = "metered",
            rate_limit = { primary = { remaining = 0.2 } },
          },
        },
        credits = { has_credits = true, unlimited = true },
        spend_control = { reached = true },
        rate_limit_reached_type = { type = "weekly_limit" },
      }) },
      { body = vim.json.encode({
        credits = { has_credits = true, unlimited = false },
      }) },
      { body = vim.json.encode({
        credits = { has_credits = false, unlimited = false },
      }) },
      { body = "{}" },
    }
    local service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = transport,
    })

    assert.is_true(wait(operation(service, "refresh")).ok)
    local snapshot = service:state()
    assert.are.equal(0.9,
      block(snapshot, "limit", "1 day limit").remaining)
    assert.are.equal(0.8,
      block(snapshot, "limit", "2 days limit").remaining)
    assert.are.equal(0.7,
      block(snapshot, "limit", "Sonic 2h limit").remaining)
    assert.are.equal(0.6,
      block(snapshot, "limit", "Pulse 45m limit").remaining)
    assert.are.equal(0.2,
      block(snapshot, "limit", "Metered usage limit").remaining)
    assert.are.equal("Unlimited", block(snapshot, "field", "Credits").value)
    assert.are.equal("Reached",
      block(snapshot, "field", "Spend control").value)
    assert.are.equal("Weekly limit", block(snapshot, "status").text)

    assert.is_true(wait(operation(service, "refresh")).ok)
    assert.are.equal("Available",
      block(service:state(), "field", "Credits").value)
    assert.is_true(wait(operation(service, "refresh")).ok)
    assert.are.equal("None",
      block(service:state(), "field", "Credits").value)

    local no_metadata = provider_service.run(service, "refresh", {
      resolve_auth = function()
        return async.run(function()
          return {
            ok = true,
            configured = true,
            credential_type = "oauth",
            request_opts = { headers = {} },
            metadata = {},
          }
        end)
      end,
      interact = interact(),
    })
    assert.is_true(wait(no_metadata).ok)
    assert.are.equal("ChatGPT",
      block(service:state(), "field", "Account").value)
  end)

  it("keeps rich state visible when refresh fails and accepts header updates", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        plan_type = "plus",
        rate_limit = { primary_window = {
          used_percent = 50, limit_window_seconds = 18000,
        } },
      }) },
      { status = 500, body = [[{"secret":"body"}]] },
    }
    local service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = transport,
    })
    assert.is_true(wait(operation(service, "refresh")).ok)
    local failed = wait(operation(service, "refresh"))
    assert.is_false(failed.ok)
    local snapshot = service:state()
    assert.matches("Usage data is stale", block(snapshot, "status").text)
    assert.is_nil(block(snapshot, "status").text:find("secret", 1, true))
    assert.are.equal(0.5,
      block(snapshot, "limit", "5h limit").remaining)

    service:on_event({
      type = "provider_status",
      text = "5h 40% left",
      details = { source = "headers", limits = { {
        id = "codex",
        primary = { remaining = 0.4, window_minutes = 300 },
      } } },
    })
    snapshot = service:state()
    assert.matches("Usage data is stale", block(snapshot, "status").text)
    assert.are.equal(0.4,
      block(snapshot, "limit", "5h limit").remaining)
  end)

  it("loads activity, workspaces, reset credits, and redeems with confirmation", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ stats = {
        lifetime_tokens = 12500,
        peak_daily_tokens = 2500,
        longest_running_turn_sec = 90,
        current_streak_days = 3,
        longest_streak_days = 7,
      } }) },
      { body = vim.json.encode({
        accounts = {
          workspace_1 = { account = {
            account_id = "secret-workspace-id",
            name = "Acme",
            structure = "workspace",
          } },
        },
        account_ordering = { "workspace_1" },
        default_account_id = "workspace_1",
      }) },
      { body = vim.json.encode({
        available_count = 1,
        credits = { {
          id = "secret-credit-id",
          status = "available",
          title = "Full reset",
          description = "Ready to redeem",
          expires_at = "2026-09-01T00:00:00Z",
        } },
      }) },
      { body = [[{"code":"reset","windows_reset":2}]] },
      { body = vim.json.encode({
        plan_type = "plus",
        rate_limit = { primary_window = {
          used_percent = 0, limit_window_seconds = 18000,
        } },
        rate_limit_reset_credits = { available_count = 0 },
      }) },
    }
    local service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = transport,
      new_id = function() return "stable-redeem-id" end,
    })
    assert.is_true(wait(operation(service, "activity")).ok)
    assert.is_true(wait(operation(service, "workspaces")).ok)
    assert.is_true(wait(operation(service, "reset_credits")).ok)
    local snapshot = service:state()
    assert.are.equal("12,500",
      list_block(snapshot, "Account activity").items[1].detail)
    assert.are.same({ label = "Acme", detail = "Default" },
      list_block(snapshot, "Workspaces").items[1])
    assert.are.equal("Full reset",
      list_block(snapshot, "Reset credits").items[1].label)
    local state_text = vim.inspect(snapshot)
    assert.is_nil(state_text:find("secret%-workspace%-id"))
    assert.is_nil(state_text:find("secret%-credit%-id"))

    local redeemed = wait(operation(service, "redeem"))
    assert.is_true(redeemed.ok)
    assert.are.equal("reset", redeemed.code)
    assert.are.same({
      redeem_request_id = "stable-redeem-id",
      credit_id = "secret-credit-id",
    }, vim.json.decode(transport.fetch_requests[4].body))
    snapshot = service:state()
    assert.are.equal("0",
      block(snapshot, "field", "Reset credits").value)
    assert.are.equal(1,
      block(snapshot, "limit", "5h limit").remaining)
  end)

  it("reports malformed and unavailable auxiliary account responses", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 500, body = [[{"error":"private body"}]] },
      { body = "{}" },
      { body = "{}" },
      { body = vim.json.encode({
        accounts = { {
          id = "private-workspace-id",
          name = "Personal",
          structure = "personal",
        } },
      }) },
      { body = "{}" },
    }
    local service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = transport,
    })

    local unavailable = wait(operation(service, "activity"))
    assert.is_false(unavailable.ok)
    assert.is_nil(block(service:state(), "status").text:find(
      "private body", 1, true))

    local malformed = wait(operation(service, "activity"))
    assert.is_false(malformed.ok)
    assert.matches("activity response is malformed", malformed.error.message)

    malformed = wait(operation(service, "workspaces"))
    assert.is_false(malformed.ok)
    assert.matches("workspace response is malformed", malformed.error.message)

    assert.is_true(wait(operation(service, "workspaces")).ok)
    assert.are.same({ label = "Personal", detail = "personal" },
      list_block(service:state(), "Workspaces").items[1])
    assert.is_nil(vim.inspect(service:state()):find(
      "private%-workspace%-id"))

    malformed = wait(operation(service, "reset_credits"))
    assert.is_false(malformed.ok)
    assert.matches("reset%-credit response is malformed",
      malformed.error.message)
  end)

  it("reports terminal redemption outcomes and preserves refresh failures", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 500, body = [[{"error":"private redeem body"}]] },
      { body = [[{"code":"no_credit"}]] },
      { body = [[{"code":"nothing_to_reset"}]] },
      { body = [[{"code":"unexpected"}]] },
      { body = [[{"code":"already_redeemed"}]] },
      { status = 500, body = [[{"error":"private usage body"}]] },
    }
    local service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = transport,
    })

    local result = wait(operation(service, "redeem"))
    assert.is_false(result.ok)
    assert.matches("request failed", block(service:state(), "status").text)
    assert.is_nil(vim.inspect(service:state()):find(
      "private redeem body", 1, true))

    result = wait(operation(service, "redeem"))
    assert.is_false(result.ok)
    assert.matches("No reset credit", result.error.message)
    result = wait(operation(service, "redeem"))
    assert.is_false(result.ok)
    assert.matches("No rate%-limit window", result.error.message)
    result = wait(operation(service, "redeem"))
    assert.is_false(result.ok)
    assert.matches("response is malformed", result.error.message)

    result = wait(operation(service, "redeem"))
    assert.is_true(result.ok)
    assert.are.equal("already_redeemed", result.code)
    assert.matches("request failed", block(service:state(), "status").text)
    assert.is_nil(vim.inspect(service:state()):find("private usage body", 1, true))

    for index = 1, 5 do
      local body = vim.json.decode(transport.fetch_requests[index].body)
      assert.matches("^neoagent%-%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x"
        .. "%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$", body.redeem_request_id)
    end
  end)

  it("deduplicates refreshes and cancels them during destruction", function()
    local pending
    local cancelled = false
    local requests = 0
    local transport = {
      fetch = function()
        requests = requests + 1
        return async.run(function(run)
          return async.await(function(done)
            pending = done
            run:on_cancel(function()
              cancelled = true
              done.reject({ kind = "cancelled", message = "cancelled" })
            end)
            return function() end
          end)
        end)
      end,
    }
    local service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = transport,
    })
    local ctx = {
      resolve_auth = auth_context,
      interact = interact(),
    }
    local first = service.operations.refresh.run(ctx)
    local second = service.operations.refresh.run(ctx)
    assert.are.equal(first, second)
    assert(vim.wait(1000, function() return requests == 1 end))
    assert.are.equal(1, requests)
    service:destroy()
    assert.is_true(cancelled)
    assert.is_false(wait(first).ok)
    assert.are.same({}, service:state().blocks)
    pending.resolve({ ok = true, status = 200, body = "{}" })
  end)

  it("requires redemption confirmation and cancels a pending redemption", function()
    local requests = 0
    local cancelled = false
    local last_body
    local transport = {
      fetch = function(opts)
        requests = requests + 1
        last_body = opts.request.body
        return async.run(function(run)
          return async.await(function(done)
            run:on_cancel(function()
              cancelled = true
              done.reject({ kind = "cancelled", message = "cancelled" })
            end)
            return function() end
          end)
        end)
      end,
    }
    local service = codex.new({ base_url = "https://example.test/backend-api" }, {
      transport = transport,
      new_id = function() return "stable-cancel-id" end,
    })
    local declined = wait(operation(service, "redeem", false))
    assert.is_true(declined.ok)
    assert.is_true(declined.cancelled)
    assert.are.equal(0, requests)

    local run = operation(service, "redeem", true)
    assert(vim.wait(1000, function() return requests == 1 end))
    assert.are.equal("stable-cancel-id",
      vim.json.decode(last_body).redeem_request_id)
    run:cancel()
    local result = wait(run)
    assert.is_false(result.ok)
    assert.are.equal("cancelled", result.error.kind)
    assert.is_true(cancelled)
  end)
end)
