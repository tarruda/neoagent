local decoder = require("neoagent.api.openai_responses.decoder")
local http_response = require("neoagent.api.http_response")
local semantic_message = require("neoagent.semantic_message")
local util = require("neoagent.util")

local M = {}

---@param response Neoagent.JsonObject
---@param incomplete boolean
---@return Neoagent.Error
local function failure(response, incomplete)
  local source = type(response.error) == "table" and response.error or response
  local details = type(response.incomplete_details) == "table" and response.incomplete_details or {}
  local code = incomplete and details.reason or source.code
  local message = http_response.error_message(
    response,
    incomplete and "Compaction response incomplete" or "Compaction response failed"
  )
  if incomplete and type(code) == "string" then
    message = "Compaction response incomplete: " .. code
  end
  local err = util.error("model", message)
  if type(code) == "string" and #code <= 128 and code:match("^[%w_-]+$") then
    err.code = code
  end
  return err
end

---@class Neoagent.ResponsesCompactDecoder
---@field process fun(event: Neoagent.JsonValue)
---@field result fun(): Neoagent.NativeCompactionSuccess

---@param model Neoagent.Model
---@return Neoagent.ResponsesCompactDecoder
function M.new(model)
  local terminal = false
  local count = 0
  ---@type Neoagent.NativeCompactionMessage?
  local item
  ---@type Neoagent.Usage?
  local usage
  return {
    process = function(event)
      if type(event) ~= "table" or terminal then
        return
      end
      if event.type == "response.output_item.done" then
        local output = event.item
        if type(output) == "table" and output.type == "compaction" then
          count = count + 1
          local normalized, err = semantic_message.normalize_native_compaction({
            role = "nativeCompaction",
            api = model.api,
            provider = model.provider,
            model = model.id,
            id = output.id,
            encrypted_content = output.encrypted_content,
          })
          if not normalized then
            error(util.error("protocol", "Invalid encrypted compaction output", err), 0)
          end
          item = normalized
        end
      elseif event.type == "response.completed" or event.type == "response.done" then
        terminal = true
        local response = event.response
        if type(response) ~= "table" or type(response.id) ~= "string" or response.id == "" then
          error(util.error("protocol", "Compaction completion requires a response id"), 0)
        end
        if response.status ~= nil and response.status ~= "completed" then
          error(failure(response, response.status == "incomplete"), 0)
        end
        if type(response.usage) == "table" then
          usage = decoder.usage_from(response.usage)
        end
      elseif event.type == "error" or event.type == "response.failed" or event.type == "response.incomplete" then
        local response = type(event.response) == "table" and event.response or event
        error(failure(response, event.type == "response.incomplete"), 0)
      end
    end,
    result = function()
      if not terminal then
        error(util.error("protocol", "Compaction stream ended before a terminal response event"), 0)
      end
      if count ~= 1 or not item then
        error(util.error("protocol", "Compaction response requires exactly one encrypted output item"), 0)
      end
      return { ok = true, item = item, usage = usage }
    end,
  }
end

return M
