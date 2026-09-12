local util = require("neoagent.util")

---@class Neoagent.RenderBlock: Neoagent.CardFocus
---@field kind string
---@field key? string
---@field revision? string|number
---@field content? string|Neoagent.Block[]
---@field text? string
---@field extra? string
---@field error? boolean
---@field warning? boolean
---@field name? string
---@field state? string
---@field call? Neoagent.ToolCallData
---@field raw? string
---@field update? Neoagent.ToolResult
---@field message? Neoagent.ToolResultMessage
---@field finished? boolean
---@field summary? string
---@field tokens_before? number
---@field image_scope? string
---@field text_epoch? unknown

---@class Neoagent.RenderTool
---@field name string
---@field render? fun(options: Neoagent.ToolPresentationOptions): unknown

---@class Neoagent.RenderOptions
---@field previous? Neoagent.RenderBlock
---@field following? Neoagent.RenderBlock
---@field width? integer
---@field surface_width? integer
---@field spinner? string
---@field details_key? string
---@field wrap_cards? boolean
---@field tool? Neoagent.RenderTool
---@field key? string
---@field show_images? boolean
---@field image_mode? 'details'
---@field image_source? Neoagent.ImageSourceFactory

---@class Neoagent.Renderer<C>
---@field name string
---@field theme Applet.Theme
---@field render_block fun(self: Neoagent.Renderer<C>, block: Neoagent.RenderBlock, env: Neoagent.RenderOptions, continuation?: C): Applet.Node?, C?
---@field render_details fun(self: Neoagent.Renderer<C>, block: Neoagent.RenderBlock, env: Neoagent.RenderOptions, continuation?: C): Applet.Node?, C?

local M = {}

---@param message string
---@return nil, Neoagent.Error
local function failure(message)
  return nil, util.error("ui", message)
end

---@param value unknown
---@return_overload Neoagent.Renderer<unknown>, nil
---@return_overload nil, Neoagent.Error
function M.validate(value)
  if type(value) ~= "table" then
    return failure("Renderer must be a table")
  end
  if type(value.name) ~= "string" or value.name == "" then
    return failure("Renderer name must be a non-empty string")
  end
  if
    type(value.theme) ~= "table"
    or type(value.theme.group) ~= "function"
    or type(value.theme.define) ~= "function"
  then
    return failure("Renderer must supply an Applet theme")
  end
  for _, method in ipairs({ "render_block", "render_details" }) do
    if type(value[method]) ~= "function" then
      return failure("Renderer must implement " .. method)
    end
  end
  return value --[[@as Neoagent.Renderer<unknown>]]
end

---@param value unknown
---@param prefix? string
---@return Neoagent.Renderer<unknown>
function M.assert(value, prefix)
  local renderer, err = M.validate(value)
  if not renderer then
    error((prefix or "Renderer") .. ": " .. assert(err).message, 2)
  end
  return renderer
end

local block_fields = {
  "key",
  "revision",
  "kind",
  "content",
  "text",
  "extra",
  "error",
  "warning",
  "name",
  "state",
  "call",
  "raw",
  "update",
  "message",
  "finished",
  "summary",
  "tokens_before",
  "header",
  "resting_header",
  "overflow",
  "image_scope",
  "text_epoch",
}

---@param block Neoagent.RenderBlock
---@return Neoagent.RenderBlock
function M.copy_block(block)
  local result = {}
  for _, key in ipairs(block_fields) do
    if block[key] ~= nil then
      result[key] = util.copy(block[key])
    end
  end
  return result --[[@as Neoagent.RenderBlock]]
end

---@generic C
---@param renderer Neoagent.Renderer<C>
---@param method "render_block"|"render_details"
---@param block Neoagent.RenderBlock
---@param env? Neoagent.RenderOptions
---@param optional boolean
---@param continuation? C
---@return_overload Applet.Node, C?
---@return_overload nil, Neoagent.Error?
local function invoke(renderer, method, block, env, optional, continuation)
  local copied = M.copy_block(block)
  local options = util.copy(env or {})
  if options.previous then
    options.previous = M.copy_block(options.previous)
  end
  if options.following then
    options.following = M.copy_block(options.following)
  end
  local ok, value, next_continuation = pcall(renderer[method], renderer, copied, options, continuation)
  if not ok then
    return failure("Renderer " .. renderer.name .. " " .. method .. " failed: " .. tostring(value))
  end
  if value == nil and not optional then
    return failure("Renderer " .. renderer.name .. " " .. method .. " returned no Pane content node")
  end
  if value == nil then
    return nil
  end
  ---@cast value Applet.Node
  return value, next_continuation
end

---@generic C
---@param renderer Neoagent.Renderer<C>
---@param block Neoagent.RenderBlock
---@param env? Neoagent.RenderOptions
---@param continuation? C
---@return_overload Applet.Node, C?
---@return_overload nil, Neoagent.Error?
function M.render_block(renderer, block, env, continuation)
  return invoke(renderer, "render_block", block, env, false, continuation)
end

---@generic C
---@param renderer Neoagent.Renderer<C>
---@param block Neoagent.RenderBlock
---@param env? Neoagent.RenderOptions
---@param continuation? C
---@return_overload Applet.Node, C?
---@return_overload nil, Neoagent.Error?
function M.render_details(renderer, block, env, continuation)
  return invoke(renderer, "render_details", block, env, true, continuation)
end

---@param renderer Neoagent.Renderer<unknown>
---@return true?, Neoagent.Error?
function M.define_highlights(renderer)
  local ok, err = pcall(renderer.theme.define, renderer.theme)
  if not ok then
    return failure("Renderer " .. renderer.name .. " theme definition failed: " .. tostring(err))
  end
  return true
end

return M
