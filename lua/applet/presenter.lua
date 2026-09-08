---@class Applet.PresentationCallbacks<T>
---@field resolve fun(value: T)
---@field reject fun(error: unknown)

---@class Applet.SelectItem
---@field id string
---@field label? string
---@field detail? string
---@field fallback? unknown
---@field disabled? boolean

---@class Applet.SelectRequest
---@field prompt string
---@field items Applet.SelectItem[]

---@class Applet.InputRequest
---@field prompt string
---@field default? string
---@field secret? boolean
---@field allow_empty? boolean

---@class Applet.NoticeRequest
---@field prompt string
---@field body string

---@class Applet.ConfirmRequest
---@field prompt string
---@field accept_label string
---@field reject_label string

local M = {}

---@param message string
---@return {kind: "cancelled", message: string}
local function cancelled(message)
  return { kind = "cancelled", message = message }
end

---@generic T
---@param start fun(done: Applet.PresentationCallbacks<T>)
---@param done Applet.PresentationCallbacks<T>
---@return fun()
local function protected(start, done)
  local active = true
  ---@generic V
  ---@param deliver fun(value: V)
  ---@param value V
  local function settle(deliver, value)
    if not active then return end
    active = false
    deliver(value)
  end
  ---@type Applet.PresentationCallbacks<T>
  local guarded = {
    resolve = function(value) settle(done.resolve, value) end,
    reject = function(err) settle(done.reject, err) end,
  }
  local ok, err = pcall(start, guarded)
  if not ok then guarded.reject(err) end
  return function() active = false end
end

---@param item Applet.SelectItem
---@return string
local function item_label(item)
  local label = item.label or item.id
  if type(item.detail) == "string" and item.detail ~= "" then
    return label .. " · " .. item.detail
  end
  return label
end

---@param request Applet.SelectRequest
---@param done Applet.PresentationCallbacks<string>
---@return fun()
function M.select(request, done)
  return protected(function(guarded)
    ---@type unknown[]
    local items = {}
    for _, item in ipairs(request.items) do
      if item.fallback == nil then
        items[#items + 1] = item
      else
        items[#items + 1] = item.fallback
      end
    end
    ---@param value unknown
    ---@return Applet.SelectItem
    local function semantic_item(value)
      for index, item in ipairs(request.items) do
        if items[index] == value then return item end
      end
      -- Native selection callbacks return one of the supplied items.
      return value --[[@as Applet.SelectItem]]
    end
    vim.ui.select(items, {
      prompt = request.prompt,
      format_item = function(item) return item_label(semantic_item(item)) end,
    }, function(item)
      if item == nil then
        guarded.reject(cancelled("Selection cancelled"))
      else
        guarded.resolve(semantic_item(item).id)
      end
    end)
  end, done)
end

---@param request Applet.InputRequest
---@param done Applet.PresentationCallbacks<string>
---@return fun()
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
        done.resolve(value --[[@as string]])
      elseif ok then
        done.reject(cancelled("Input cancelled"))
      else
        done.reject(value)
      end
    end)
    return function() active = false end
  end
  return protected(function(guarded)
    vim.ui.input({
      prompt = request.prompt .. " ",
      default = request.default,
    }, function(value)
      if value == nil or not request.allow_empty and value == "" then
        guarded.reject(cancelled("Input cancelled"))
      else
        guarded.resolve(value)
      end
    end)
  end, done)
end

---@param request Applet.NoticeRequest
---@param done Applet.PresentationCallbacks<boolean>
---@return fun()
function M.notice(request, done)
  return protected(function(guarded)
    vim.ui.select({ { id = "close", label = "Close" } }, {
      prompt = request.prompt .. "\n" .. request.body,
      format_item = item_label,
    }, function(item)
      if item == nil then
        guarded.reject(cancelled("Notice closed"))
      else
        guarded.resolve(true)
      end
    end)
  end, done)
end

---@param request Applet.ConfirmRequest
---@param done Applet.PresentationCallbacks<boolean>
---@return fun()
function M.confirm(request, done)
  return protected(function(guarded)
    vim.ui.select({
      { id = "yes", label = request.accept_label },
      { id = "no", label = request.reject_label },
    }, {
      prompt = request.prompt,
      format_item = item_label,
    }, function(item)
      if item == nil then
        guarded.reject(cancelled("Confirmation cancelled"))
      else
        guarded.resolve(item.id == "yes")
      end
    end)
  end, done)
end

---@param message string
---@param level? integer
function M.notify(message, level)
  return vim.notify(message, level)
end

---@param uri string
---@return vim.SystemObj?
---@return string?
function M.open_uri(uri)
  if vim.ui and type(vim.ui.open) == "function" then return vim.ui.open(uri) end
  error("URI opening is unavailable", 2)
end

return M
