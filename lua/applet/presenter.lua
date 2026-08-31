local M = {}

local function cancelled(message)
  return { kind = "cancelled", message = message }
end

local function protected(start, done)
  local active = true
  local function settle(method, value)
    if not active then return end
    active = false
    done[method](value)
  end
  local ok, err = pcall(start, settle)
  if not ok then settle("reject", err) end
  return function() active = false end
end

local function item_label(item)
  local label = item.label or item.id
  if type(item.detail) == "string" and item.detail ~= "" then
    return label .. " · " .. item.detail
  end
  return label
end

function M.select(request, done)
  return protected(function(settle)
    local items = {}
    for _, item in ipairs(request.items) do
      if item.fallback == nil then
        items[#items + 1] = item
      else
        items[#items + 1] = item.fallback
      end
    end
    local function semantic_item(value)
      for index, item in ipairs(request.items) do
        if items[index] == value then return item end
      end
      return value
    end
    vim.ui.select(items, {
      prompt = request.prompt,
      format_item = function(item) return item_label(semantic_item(item)) end,
    }, function(item)
      if item == nil then
        settle("reject", cancelled("Selection cancelled"))
      else
        settle("resolve", semantic_item(item).id)
      end
    end)
  end, done)
end

function M.input(request, done)
  if request.secret then
    local active = true
    vim.schedule(function()
      if not active then return end
      local ok, value = pcall(vim.fn.inputsecret, request.prompt .. " ")
      if not active then return end
      active = false
      if ok and value ~= nil
          and (request.allow_empty or value ~= "") then
        done.resolve(value)
      elseif ok then
        done.reject(cancelled("Input cancelled"))
      else
        done.reject(value)
      end
    end)
    return function() active = false end
  end
  return protected(function(settle)
    vim.ui.input({
      prompt = request.prompt .. " ",
      default = request.default,
    }, function(value)
      if value == nil or not request.allow_empty and value == "" then
        settle("reject", cancelled("Input cancelled"))
      else
        settle("resolve", value)
      end
    end)
  end, done)
end

function M.notice(request, done)
  return protected(function(settle)
    vim.ui.select({ { id = "close", label = "Close" } }, {
      prompt = request.prompt .. "\n" .. request.body,
      format_item = item_label,
    }, function(item)
      if item == nil then
        settle("reject", cancelled("Notice closed"))
      else
        settle("resolve", true)
      end
    end)
  end, done)
end

function M.confirm(request, done)
  return protected(function(settle)
    vim.ui.select({
      { id = "yes", label = request.accept_label },
      { id = "no", label = request.reject_label },
    }, {
      prompt = request.prompt,
      format_item = item_label,
    }, function(item)
      if item == nil then
        settle("reject", cancelled("Confirmation cancelled"))
      else
        settle("resolve", item.id == "yes")
      end
    end)
  end, done)
end

function M.notify(message, level)
  return vim.notify(message, level)
end

function M.open_uri(uri)
  if vim.ui and type(vim.ui.open) == "function" then return vim.ui.open(uri) end
  error("URI opening is unavailable", 2)
end

return M
