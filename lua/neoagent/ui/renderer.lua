local util = require("neoagent.util")

local M = {}

local function failure(message)
  return nil, util.error("ui", message)
end

function M.validate(value)
  if type(value) ~= "table" then
    return failure("Renderer must be a table")
  end
  if type(value.name) ~= "string" or value.name == "" then
    return failure("Renderer name must be a non-empty string")
  end
  if type(value.theme) ~= "table"
      or type(value.theme.group) ~= "function"
      or type(value.theme.define) ~= "function" then
    return failure("Renderer must supply an Applet theme")
  end
  for _, method in ipairs({ "render_block", "render_details" }) do
    if type(value[method]) ~= "function" then
      return failure("Renderer must implement " .. method)
    end
  end
  return value
end

function M.assert(value, prefix)
  local renderer, err = M.validate(value)
  if not renderer then error((prefix or "Renderer") .. ": " .. err.message, 2) end
  return renderer
end

local block_fields = {
  "key", "revision", "kind", "content", "text", "extra", "error",
  "name", "state", "call", "raw", "update", "message", "finished",
  "summary", "tokens_before", "header", "resting_header", "overflow",
  "image_scope", "text_epoch",
}

function M.copy_block(block)
  local result = {}
  for _, key in ipairs(block_fields) do
    if block[key] ~= nil then result[key] = util.copy(block[key]) end
  end
  return result
end

local function invoke(renderer, method, block, env, optional, continuation)
  local copied = M.copy_block(block)
  local options = util.copy(env or {})
  if options.previous then options.previous = M.copy_block(options.previous) end
  if options.following then
    options.following = M.copy_block(options.following)
  end
  local ok, value, next_continuation = pcall(
    renderer[method], renderer, copied, options, continuation)
  if not ok then
    return failure("Renderer " .. renderer.name .. " " .. method
      .. " failed: " .. tostring(value))
  end
  if value == nil and not optional then
    return failure("Renderer " .. renderer.name .. " " .. method
      .. " returned no Pane content node")
  end
  if value == nil then return nil end
  return value, next_continuation
end

function M.render_block(renderer, block, env, continuation)
  return invoke(renderer, "render_block", block, env, false, continuation)
end

function M.render_details(renderer, block, env, continuation)
  return invoke(renderer, "render_details", block, env, true, continuation)
end

function M.define_highlights(renderer)
  local ok, err = pcall(renderer.theme.define, renderer.theme)
  if not ok then
    return failure("Renderer " .. renderer.name
      .. " theme definition failed: " .. tostring(err))
  end
  return true
end

return M
