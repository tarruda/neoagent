local async = require("neoagent.async")
local objects = require("neoagent.files.object")
local image_encoding = require("neoagent.api.images")
local request_stream = require("neoagent.api.request_stream")
local util = require("neoagent.util")
local M = {}

---@class Neoagent.FileRequestPolicy
---@field api string
---@field bind fun(request: Neoagent.ApiRequest): Neoagent.FileAccess?
---@field accepts fun(image: Neoagent.ImageBlock): boolean
---@field max_file_bytes integer
---@field max_body_bytes? integer
---@field max_images? integer
---@field max_total_bytes? integer
---@field headers? fun(request: Neoagent.ApiRequest): table<string, string>
---@field rejected? fun(result: Neoagent.HttpResult): boolean Definitive stale-file rejection; repair inspects every used ID.

---@param manager_for fun(dependencies: Neoagent.StreamOptions): Neoagent.FileManager
---@param policy Neoagent.FileRequestPolicy
---@return Neoagent.ImageRequest
function M.new(manager_for, policy)
  assert(
    type(manager_for) == "function" and type(policy.bind) == "function" and type(policy.accepts) == "function",
    "invalid image request dependencies"
  )
  return {
    stream = function(transport, plan, dependencies, options)
      return async.run(function()
        local request = plan.request
        local access = policy.bind(request)
        if not access then
          return request_stream.send(transport, plan, dependencies, options):await()
        end
        ---@type Neoagent.FileAsset[]
        local selected = {}
        local total, count = 0, 0
        for _, message in ipairs(plan.messages) do
          if type(message.content) == "table" then
            for _, image in ipairs(message.content) do
              if image.type == "image" then
                count, total = count + 1, total + image.bytes
                if image.bytes > policy.max_file_bytes then
                  error(util.error("files", "Image exceeds the provider file size limit"), 0)
                end
                if policy.accepts(image) then
                  selected[#selected + 1] = {
                    source = assert(dependencies.files),
                    file_id = image.file_id,
                    mime_type = image.mime_type,
                    bytes = image.bytes,
                    filename = image.filename,
                  }
                end
              end
            end
          end
        end
        if policy.max_images and count > policy.max_images then
          error(util.error("files", "Too many images for the provider"), 0)
        end
        if policy.max_total_bytes and total > policy.max_total_bytes then
          error(util.error("files", "Images exceed the provider's total input size limit"), 0)
        end
        if #selected == 0 then
          local inline_options = util.copy(options)
          inline_options.max_body_bytes = policy.max_body_bytes
          return request_stream.send(transport, plan, dependencies, inline_options):await()
        end
        local manager = manager_for(dependencies)
        local lease, lease_err = manager.acquire()
        if not lease then
          error(lease_err, 0)
        end
        local ok, value = pcall(function()
          local deadline = manager.monotonic() + manager.budget_ms
          ---@type table<string, Neoagent.FileRecord>
          local prepared = {}
          ---@async
          local function prepare()
            for _, asset in ipairs(selected) do
              local key = manager:key(asset, access)
              local record = prepared[key]
              if not record or not objects.usable(record.object, manager.now(), 60000) then
                prepared[key] = manager:get(asset, access, deadline)
              end
            end
          end
          local inline = image_encoding.inline(plan.api, dependencies.files)
          ---@async
          ---@param image Neoagent.ImageBlock
          ---@return Neoagent.JsonObject
          local function encode_image(image)
            if not policy.accepts(image) then
              return inline(image)
            end
            local key = manager:key(
              {
                source = assert(dependencies.files),
                file_id = image.file_id,
                bytes = image.bytes,
                mime_type = image.mime_type,
                filename = image.filename,
              },
              access
            )
            return image_encoding.remote(plan.api, assert(prepared[key], "image was not prepared").object.locator)
          end
          local headers = util.copy(request.headers)
          if policy.headers then
            headers = util.deep_merge(headers, policy.headers(request), function(key)
              return type(key) == "string" and key:lower() or key
            end)
          end
          local seen = false
          ---@async
          local function dispatch()
            prepare()
            -- Earlier uploads can expire while later attachments are prepared.
            prepare()
            local body = util.json_encode(plan.encode(encode_image))
            for _, record in pairs(prepared) do
              if not objects.usable(record.object, manager.now(), 60000) then
                error(util.error("files", "Image reference expires before dispatch"), 0)
              end
            end
            if policy.max_body_bytes and #body > policy.max_body_bytes then
              error(util.error("files", "Request exceeds the provider HTTP body limit"), 0)
            end
            return transport
              .stream({
                request = {
                  url = request.url,
                  headers = headers,
                  body = body,
                  timeout_ms = request.timeout_ms,
                },
                on_event = function(event)
                  seen = true
                  options.on_event(event)
                end,
                on_done_marker = function()
                  seen = true
                  if options.on_done_marker then
                    options.on_done_marker()
                  end
                end,
              })
              :await()
          end
          local result = dispatch()
          if not seen and policy.rejected and policy.rejected(result) then
            local stale = false
            -- The established OpenAI error need not name a particular file.
            -- Inspect all references from this request before repairing, so a
            -- single resubmission can replace every confirmed dangling object.
            for key, record in pairs(prepared) do
              local inspected = manager.backend.inspect(record.object, access, manager:remaining(deadline)):await()
              if inspected.ok == false then
                error(inspected.error, 0)
              end
              if inspected.object and not objects.valid(inspected.object) then
                error(util.error("files", "Invalid file inspection metadata"), 0)
              end
              if not inspected.object or not objects.usable(inspected.object, manager.now(), 60000) then
                manager:invalidate(key, record.generation)
                prepared[key], stale = nil, true
              end
            end
            if stale then
              result = dispatch()
            end
          end
          return result
        end)
        lease:release()
        if not ok then
          error(value, 0)
        end
        return value
      end, { error_kind = "files" })
    end,
  }
end

return M
