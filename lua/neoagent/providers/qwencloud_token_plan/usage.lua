local async = require("neoagent.async")
local http = require("neoagent.providers.http")
local util = require("neoagent.util")
local valid_access_token = require("neoagent.auth.qwencloud_usage").valid_access_token

local M = {}
-- QwenCloud CLI's management gateway is separate from the inference endpoint.
local ORIGIN = "https://cli.qwencloud.com"
local GATEWAY_PATH = "/data/v2/api.json"
local INDIVIDUAL_ORIGIN = "https://ap-southeast-1-cs-data.qwencloud.com"
local REGION = "ap-southeast-1"
local TEAMS = "sfm_tokenplanteams_dp_intl"
local PERSONAL = "sfm_tokenplanpersonal_dp_intl"
local INDIVIDUAL = "sfm_tokenplansolo_public_intl"
local ADDON = "sfm_tokenplanteamsaddon_dp_intl"
local MAX_RESET_MS = 253402300799000 -- 9999-12-31T23:59:59Z
local INDIVIDUAL_TIERS = { lite = "Lite", essential = "Essential", standard = "Standard", pro = "Pro" }

---@class Neoagent.QwenCloudCreditWindow
---@field plan string
---@field cycle "weekly"|"monthly"
---@field remaining number Fraction remaining.
---@field amounts? {remaining: number, total: number}
---@field resets_at? number

---@class Neoagent.QwenCloudUsage
---@field window? Neoagent.QwenCloudCreditWindow
---@field addon? number Nil means the add-on balance could not be loaded.

---@class Neoagent.QwenCloudUsageSuccess
---@field ok true
---@field usage Neoagent.QwenCloudUsage

---@class Neoagent.QwenCloudUsageOptions: Neoagent.ProviderHttpServiceOptions
---@field transport? Neoagent.ByteBackend

---@param field string
---@return never
local function invalid(field)
  error(util.error("provider", "QwenCloud quota response contains invalid " .. field), 0)
end

---@return Neoagent.Error
local function authorization_error()
  return util.error("auth", "QwenCloud quota access was denied. Log out of usage and log in again.")
end

---@param value unknown
---@return TypeGuard<Neoagent.JsonObject>
local function object(value)
  return type(value) == "table" and not util.is_list(value)
end

---@param response Neoagent.ProviderHttpResult
---@param action string
---@return Neoagent.JsonObject
local function envelope(response, action)
  if not response.ok then
    local status = rawget(response.error, "status")
    error((status == 401 or status == 403) and authorization_error() or response.error, 0)
  end
  local body = response.value
  if not object(body) then
    invalid(action .. " response")
  end
  if body.code == "401" or body.code == "403" then
    error(authorization_error(), 0)
  end
  if body.code ~= "200" then
    error(util.error("provider", "QwenCloud quota gateway refused " .. action), 0)
  end
  return body
end

---@param value unknown
---@param field string
---@return Neoagent.JsonObject[]
local function objects(value, field)
  if type(value) ~= "table" or not util.is_list(value) then
    invalid(field)
  end
  local result = {}
  for _, item in ipairs(value) do
    if not object(item) then
      invalid(field)
    end
    result[#result + 1] = item
  end
  return result
end

---@param value unknown
---@return number
local function credits(value)
  local amount = (type(value) == "number" or type(value) == "string") and tonumber(value) or nil
  if not amount or not (amount >= 0 and amount < math.huge) then
    invalid("credit values")
  end
  return amount
end

---@param plan string
---@param total number
---@param remaining number
---@param resets_at? number
---@return Neoagent.QwenCloudCreditWindow
local function monthly_credits(plan, total, remaining, resets_at)
  return {
    plan = plan,
    cycle = "monthly",
    remaining = total > 0 and math.min(1, remaining / total) or 0,
    amounts = { total = total, remaining = remaining },
    resets_at = resets_at,
  }
end

---@param value unknown
---@return string
local function plan_name(value)
  if type(value) == "string" then
    value = util.trim(value)
    if value ~= "" and #value <= 128 and util.is_valid_utf8(value) and not value:find("[%z\1-\31\127]") then
      return value
    end
  end
  return "Token Plan"
end

---@param instance Neoagent.JsonObject
---@return boolean
local function active(instance)
  local value = instance.Status
  local status = type(value) == "table" and value.Code or value
  if type(status) ~= "string" or status == "" then
    invalid("subscription status")
  end
  return status == "valid"
end

---@param group Neoagent.JsonObject
---@return Neoagent.JsonObject
local function credit_equity(group)
  if group.EquityList ~= nil then
    local equities = objects(group.EquityList, "seat equity")
    for _, equity in ipairs(equities) do
      if equity.EquityCode == "credit_value" then
        return equity
      end
    end
    if #equities > 0 then
      invalid("seat credit equity")
    end
  end
  return group
end

---@param data Neoagent.JsonObject
---@return Neoagent.QwenCloudCreditWindow?
local function seat_monthly(data)
  local summary = data.Data or data
  if not object(summary) or summary.Success == false then
    invalid("seat summary")
  end
  -- QwenCloud can return an empty Data object when there is no Team seat balance.
  if data.Success == true and next(summary) == nil then
    return nil
  end
  local groups = objects(summary.SubscriptionGroupList, "subscription groups")
  local first = groups[1]
  if not first then
    return nil
  end
  ---@type number, number
  local total, remaining = 0, 0
  for _, group in ipairs(groups) do
    local equity = credit_equity(group)
    total = total + credits(equity.TotalValue)
    remaining = remaining + credits(equity.SurplusValue)
  end
  local next_cycle = first.NextCycleFlushTime
  local milliseconds = type(next_cycle) == "number" and next_cycle or util.parse_rfc3339_ms(next_cycle)
  local resets_at = milliseconds
      and milliseconds > 0
      and milliseconds <= MAX_RESET_MS
      and math.floor(milliseconds / 1000)
    or nil
  return monthly_credits(plan_name(summary.PlanName), credits(total), credits(remaining), resets_at)
end

---@param instances Neoagent.JsonObject[]
---@return Neoagent.QwenCloudCreditWindow?
local function instance_monthly(instances)
  for _, instance in ipairs(instances) do
    if active(instance) then
      local value = instance.CurrCapacityBaseValue
      if instance.CapacityTypeCode == "periodMonthlyShift" and instance.periodCapacityBaseValue ~= nil then
        value = instance.periodCapacityBaseValue
      end
      return monthly_credits(
        plan_name(instance.TemplateName or instance.CommodityName),
        credits(instance.InitCapacityBaseValue),
        credits(value)
      )
    end
  end
end

---@param value unknown
---@return TypeGuard<integer>
local function milliseconds(value)
  return type(value) == "number" and value >= 0 and value <= MAX_RESET_MS and value % 1 == 0
end

---@async
---@param issuer Neoagent.ProviderHttpClient
---@param individual Neoagent.ProviderHttpClient
---@param bearer string
---@return Neoagent.QwenCloudCreditWindow?
local function individual_window(issuer, individual, bearer)
  -- The browser credential only goes to the issuer. The derived credential
  -- belongs to this refresh and is only used at the Individual quota gateway.
  local issue = "GenerateCLIAccessToken"
  local exchange = issuer:post(GATEWAY_PATH, issue, {
    product = "ModelStudioRegional",
    action = issue,
    version = "2026-02-10",
    region = REGION,
    params = vim.empty_dict(),
  }, { Authorization = bearer, ["User-Agent"] = "neoagent" })
  local issued = envelope(exchange:await(), issue)
  local token = object(issued.data) and issued.data.cliAccessToken or nil
  if issued.successResponse ~= true or not valid_access_token(token) or "Bearer " .. token == bearer then
    invalid("Individual gateway credential")
  end
  local headers = { Authorization = "Bearer " .. token, ["User-Agent"] = "neoagent" }

  ---@async
  ---@param action "subscription"|"usage"
  ---@param params Neoagent.JsonObject
  ---@return Neoagent.JsonObject
  local function query(action, params)
    local api = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/" .. action
    local path = "/cli/api.json?action=IntlBroadScopeAspnGateway&product=sfm_bailian&api="
      .. vim.uri_encode(api, "rfc3986")
    params.cornerstoneParam = {
      protocol = "V2",
      console = "ONE_CONSOLE",
      xsp_lang = "en-US",
      productCode = "p_efm",
      switchUserType = 3,
      consoleSite = "QWENCLOUD",
    }
    local form = "params="
      .. vim.uri_encode(vim.json.encode({ Api = api, V = "1.0", Data = params }), "rfc3986")
      .. "&region="
      .. REGION
    local resource = "Individual " .. action
    local response = envelope(individual:post_form(path, resource, form, headers):await(), resource)
    local gateway = response.data
    if response.successResponse ~= true or not object(gateway) then
      invalid(resource .. " gateway response")
    end
    if gateway.success == false and gateway.errorCode == "BailianGateway.Login.NotLogined" then
      error(authorization_error(), 0)
    end
    local payload = gateway.DataV2
    if gateway.success ~= true or (gateway.errorCode ~= nil and gateway.errorCode ~= "") or not object(payload) then
      invalid(resource .. " gateway result")
    end
    local ret = type(payload.ret) == "table" and util.is_list(payload.ret) and payload.ret[1] or nil
    local business = payload.data
    if
      type(ret) ~= "string"
      or not vim.startswith(ret, "SUCCESS::")
      or not object(business)
      or business.code ~= "SUCCESS"
      or business.success ~= true
    then
      invalid(resource .. " result")
    end
    return business
  end

  local subscription = query("subscription", { commodityCode = INDIVIDUAL }).data
  if subscription == nil then
    return nil
  end
  if not object(subscription) then
    invalid("Individual subscription")
  end
  local tier = type(subscription.specCode) == "string" and INDIVIDUAL_TIERS[subscription.specCode] or nil
  local now = util.now_ms()
  if
    subscription.status ~= "VALID"
    or not tier
    or type(subscription.instanceCode) ~= "string"
    or util.trim(subscription.instanceCode) == ""
    or (subscription.commodityCode ~= nil and subscription.commodityCode ~= INDIVIDUAL)
    or not milliseconds(subscription.startTime)
    or subscription.startTime > now
    or not milliseconds(subscription.endTime)
    or subscription.endTime <= now
  then
    invalid("Individual subscription")
  end
  local usage = query("usage", {}).data
  if not object(usage) then
    invalid("Individual usage")
  end
  ---@type "weekly"|"monthly"
  local cycle = "weekly"
  local used, reset = usage.per1WeekPercentage, usage.per1WeekResetTime
  if used == nil or used == vim.NIL then
    cycle, used, reset = "monthly", usage.per1MonthPercentage, usage.per1MonthResetTime
  end
  if type(used) ~= "number" or not (used >= 0 and used <= 1) then
    invalid("Individual usage percentage")
  end
  if reset ~= nil and reset ~= vim.NIL and not milliseconds(reset) then
    invalid("Individual reset time")
  end
  return {
    plan = "Individual " .. tier,
    cycle = cycle,
    remaining = 1 - used,
    resets_at = type(reset) == "number" and reset > 0 and math.floor(reset / 1000) or nil,
  }
end

---@param opts Neoagent.QwenCloudUsageOptions
---@return Neoagent.QwenCloudUsageClient
function M.new(opts)
  ---@param origin string
  ---@param credential_response_body? boolean
  local function client_for(origin, credential_response_body)
    return http.new({
      name = "QwenCloud Token Plan",
      base_url = origin,
      private_input = true,
      credential_response_body = credential_response_body,
      transport = opts.transport,
      timeout_ms = opts.timeout_ms,
      max_response_bytes = opts.max_response_bytes,
    })
  end
  local request = client_for(ORIGIN)
  local issuer = client_for(ORIGIN, true)
  local individual = client_for(INDIVIDUAL_ORIGIN)
  ---@class Neoagent.QwenCloudUsageClient
  local client = {}

  ---@param ctx Neoagent.ProviderAuthContext
  ---@return Neoagent.Run<Neoagent.QwenCloudUsageSuccess|Neoagent.AsyncFailure, nil>
  function client:fetch(ctx)
    return async.run(function()
      local auth = ctx.resolve_auth("usage"):await()
      if not auth.ok then
        error(auth.error, 0)
      end
      local headers = auth.configured and auth.request_opts.headers or nil
      local bearer = type(headers) == "table" and rawget(headers, "Authorization") or nil
      if not auth.configured or auth.credential_type ~= "oauth" or type(bearer) ~= "string" then
        error(util.error("auth", "Log in for QwenCloud usage before refreshing quotas"), 0)
      end
      local browser_headers = { Authorization = bearer, ["User-Agent"] = "neoagent" }

      ---@async
      ---@param action string
      ---@param params Neoagent.JsonObject
      ---@return Neoagent.JsonObject
      local function gateway(action, params)
        local pending = request:post(GATEWAY_PATH, action, {
          product = "BssOpenAPI-V3",
          action = action,
          region = REGION,
          params = params,
        }, browser_headers)
        local response = envelope(pending:await(), action)
        if not object(response.data) or response.data.Success == false then
          invalid(action .. " data")
        end
        return response.data
      end

      ---@async
      ---@param commodity string
      ---@param page_size string
      ---@return Neoagent.JsonObject[]
      local function instances(commodity, page_size)
        local result = gateway("DescribeFrInstances", {
          Group = "tokenPlan",
          CommodityCode = commodity,
          PageNum = "1",
          PageSize = page_size,
        })
        return objects(result.Data, "Token Plan instances")
      end

      -- Team eligibility selects the seat or legacy instance lookup.
      local checked, subscription = pcall(gateway, "QuerySubscriptionGray", vim.empty_dict())
      local first_error = not checked and util.normalize_error(subscription, "provider") or nil
      if first_error and (first_error.kind == "auth" or first_error.kind == "cancelled") then
        error(first_error, 0)
      end

      ---@async
      ---@param lookup async fun(): Neoagent.QwenCloudCreditWindow?
      ---@return Neoagent.QwenCloudCreditWindow?
      local function lookup_window(lookup)
        local ok, result = pcall(lookup)
        if ok then
          return result
        end
        local err = util.normalize_error(result, "provider")
        local status = rawget(err, "status")
        if
          err.kind ~= "transport"
          and not (
            err.kind == "provider"
            and type(status) == "number"
            and (status == 408 or status == 429 or (status >= 500 and status < 600))
          )
        then
          error(err, 0)
        end
        first_error = first_error or err
      end

      local window = lookup_window(function()
        if checked and subscription.IsGray == true then
          return seat_monthly(gateway("GetSeatSubscriptionSummary", { productCode = TEAMS }))
        end
        return instance_monthly(instances(TEAMS, "10"))
      end) or lookup_window(function()
        return instance_monthly(instances(PERSONAL, "10"))
      end) or lookup_window(function()
        return individual_window(issuer, individual, bearer)
      end)
      if not window and first_error then
        error(first_error, 0)
      end
      ---@async
      ---@return number
      local function addon_balance()
        ---@type number
        local total = 0
        for _, instance in ipairs(instances(ADDON, "100")) do
          if active(instance) then
            total = total + credits(instance.CurrCapacityBaseValue)
          end
        end
        return credits(total)
      end
      local loaded, addon = pcall(addon_balance)
      if not loaded and util.normalize_error(addon, "provider").kind == "cancelled" then
        error(addon, 0)
      end
      ---@type Neoagent.QwenCloudUsageSuccess
      local result =
        { ok = true, usage = { window = window, addon = loaded and type(addon) == "number" and addon or nil } }
      return result
    end, { error_kind = "provider" })
  end

  return client
end

return M
