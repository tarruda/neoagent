local util = require("neoagent.util")
local async = require("neoagent.async")
local image_encoding = require("neoagent.api.images")
local files = require("neoagent.files")
local M = {}

---@class Neoagent.ImageRequest
---@field stream fun(transport: Neoagent.HttpClient, plan: Neoagent.RequestPlan, dependencies: Neoagent.StreamOptions, options: Neoagent.RequestStreamOptions): Neoagent.Run<Neoagent.HttpResult, nil>

---@class Neoagent.RequestStreamOptions
---@field on_event fun(value: Neoagent.JsonValue)
---@field on_done_marker? fun()
---@field max_body_bytes? integer

---@param images? Neoagent.ImageRequest
---@return Neoagent.ImageRequest?
function M.validate(images)
  assert(
    images == nil or type(images) == "table" and type(images.stream) == "function",
    "image request dependency requires stream"
  )
  return images
end

---@param transport Neoagent.HttpClient
---@param plan Neoagent.RequestPlan
---@param dependencies Neoagent.StreamOptions
---@param options Neoagent.RequestStreamOptions
---@param images? Neoagent.ImageRequest
---@return Neoagent.Run<Neoagent.HttpResult, nil>
function M.send(transport, plan, dependencies, options, images)
  return async.run(function()
    local published, err = files.check_messages(dependencies.files, plan.messages)
    if not published then
      error(err, 0)
    end
    if images then
      return images.stream(transport, plan, dependencies, options):await()
    end
    local request = plan.request
    local body = util.json_encode(plan.encode(image_encoding.inline(plan.api, dependencies.files)))
    if options.max_body_bytes and #body > options.max_body_bytes then
      error(util.error("files", "Request exceeds the provider HTTP body limit"), 0)
    end
    return transport
      .stream({
        request = { url = request.url, headers = request.headers, body = body, timeout_ms = request.timeout_ms },
        on_event = options.on_event,
        on_done_marker = options.on_done_marker,
      })
      :await()
  end)
end

return M
