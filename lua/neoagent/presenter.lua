local Applet = require("applet")
local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

---@class Neoagent.SelectItem
---@field id? string
---@field label? string
---@field detail? string
---@field description? string
---@field disabled? boolean
---@field value? unknown
---@field fallback? unknown

---@class Neoagent.SelectRequest
---@field prompt? string
---@field items (Neoagent.SelectItem|string)[]

---@class Neoagent.InputRequest
---@field prompt? string
---@field default? string
---@field multiline? boolean
---@field secret? boolean
---@field allow_empty? boolean
---@field mask? string

---@class Neoagent.NoticeRequest
---@field prompt? string
---@field body? string

---@class Neoagent.ConfirmRequest
---@field prompt? string
---@field accept_label? string
---@field reject_label? string

---@class Neoagent.NotificationRequest
---@field message string
---@field level? integer

---@class Neoagent.NormalizedSelectItem: Applet.PresentationItem
---@field value? unknown

---@class Neoagent.NormalizedSelect: Applet.SelectRequest
---@field kind 'select'
---@field items Neoagent.NormalizedSelectItem[]

---@class Neoagent.NormalizedInput: Applet.InputRequest
---@field kind 'input'
---@field default string
---@field multiline boolean
---@field secret boolean
---@field allow_empty boolean
---@field mask string

---@class Neoagent.NormalizedNotice: Applet.NoticeRequest
---@field kind 'notice'

---@alias Neoagent.PresentationRequest Neoagent.NormalizedSelect|Neoagent.NormalizedInput|Neoagent.NormalizedNotice

---@class Neoagent.PresentationSuccess
---@field ok true
---@field value? unknown

---@alias Neoagent.PresentationResult Neoagent.PresentationSuccess|Neoagent.AsyncFailure
---@alias Neoagent.PresentationRun Neoagent.Run<Neoagent.PresentationResult, nil>

---@class Neoagent.PresentationEntry
---@field id string
---@field request Neoagent.PresentationRequest
---@field done Neoagent.AwaitCallbacks<unknown>
---@field cancel_fallback? fun()

---@class Neoagent.PublicSelect: Neoagent.NormalizedSelect
---@field id string

---@class Neoagent.PublicInput: Neoagent.NormalizedInput
---@field id string

---@class Neoagent.PublicNotice: Neoagent.NormalizedNotice
---@field id string

---@alias Neoagent.PublicPresentation Neoagent.PublicSelect|Neoagent.PublicInput|Neoagent.PublicNotice
---@alias Neoagent.CancelPresentation fun()

---@class Neoagent.PresentationState
---@field active? Neoagent.PresentationEntry
---@field queue Neoagent.PresentationEntry[]
---@field sequence integer

---@class Neoagent.PresentationSnapshot
---@field active? Neoagent.PublicPresentation
---@field queue_count integer

---@class Neoagent.PresenterAttachment
---@field present fun(snapshot: Neoagent.PresentationSnapshot): unknown
---@field notify? fun(message: string, level?: integer): unknown
---@field open_uri? fun(uri: string): unknown, unknown?

---@class Neoagent.PresenterHost
---@field select fun(request: Applet.SelectRequest, done: Applet.PresentationCallbacks<string>): Neoagent.CancelPresentation?
---@field input fun(request: Applet.InputRequest, done: Applet.PresentationCallbacks<string>): Neoagent.CancelPresentation?
---@field notice fun(request: Applet.NoticeRequest, done: Applet.PresentationCallbacks<boolean>): Neoagent.CancelPresentation?
---@field notify fun(message: string, level?: integer): unknown
---@field open_uri fun(uri: string): unknown

---@class Neoagent.Presenter: Neoagent.AuthenticationPresenter
---@field host Neoagent.PresenterHost
---@field state Neoagent.PresentationState
---@field attachment? Neoagent.PresenterAttachment
---@field destroyed boolean
local Presenter = {}
Presenter.__index = Presenter

---@param message string
---@return Neoagent.Error
local function presentation_error(message)
  return util.error("presentation", message)
end

---@param value unknown
---@param name string
---@param allow_empty? boolean
---@return string
local function valid_text(value, name, allow_empty)
  assert(
    type(value) == "string" and (allow_empty or value ~= "") and not value:find("\0", 1, true),
    name .. " must be valid text"
  )
  return value
end

---@param request Neoagent.SelectRequest
---@return Neoagent.NormalizedSelect
local function normalize_select(request)
  assert(
    type(request) == "table" and (next(request) == nil or not util.is_list(request)),
    "selection request must be an object"
  )
  ---@type Neoagent.NormalizedSelect
  local result = {
    kind = "select",
    prompt = valid_text(request.prompt or "Select", "selection prompt"),
    items = {},
  }
  assert(type(request.items) == "table" and util.is_list(request.items), "selection items must be a list")
  local seen = {}
  for index, source in ipairs(request.items) do
    ---@type Neoagent.NormalizedSelectItem
    local item
    if type(source) == "string" then
      item = {
        id = tostring(index),
        label = source,
        value = source,
        fallback = source,
      }
    else
      assert(type(source) == "table" and not util.is_list(source), "selection item must be an object or string")
      local id = valid_text(source.id or tostring(index), "selection item id")
      local value = source.value
      if value == nil then
        value = source.id or source
      end
      local fallback = source.fallback
      if fallback == nil then
        fallback = source
      end
      item = {
        id = id,
        label = valid_text(source.label or id, "selection item label"),
        detail = source.detail or source.description,
        disabled = source.disabled == true,
        value = value,
        fallback = fallback,
      }
      if item.detail ~= nil then
        valid_text(item.detail, "selection item detail", true)
      end
    end
    assert(not seen[item.id], "selection item ids must be unique")
    seen[item.id] = true
    result.items[#result.items + 1] = item
  end
  return result
end

---@param request Neoagent.InputRequest
---@return Neoagent.NormalizedInput
local function normalize_input(request)
  assert(
    type(request) == "table" and (next(request) == nil or not util.is_list(request)),
    "input request must be an object"
  )
  local result = {
    kind = "input",
    prompt = valid_text(request.prompt or "Input", "input prompt"),
    default = valid_text(request.default or "", "input default", true),
    multiline = request.multiline == true,
    secret = request.secret == true,
    allow_empty = request.allow_empty == true,
    mask = request.mask or "•",
  }
  assert(not result.secret or not result.multiline, "secret input must be a single line")
  return result
end

---@param request Neoagent.NoticeRequest
---@return Neoagent.NormalizedNotice
local function normalize_notice(request)
  assert(
    type(request) == "table" and (next(request) == nil or not util.is_list(request)),
    "notice request must be an object"
  )
  return {
    kind = "notice",
    prompt = valid_text(request.prompt or "Notice", "notice prompt"),
    body = valid_text(request.body or "", "notice body", true),
  }
end

---@param entry? Neoagent.PresentationEntry
---@return Neoagent.PublicPresentation?
local function public_entry(entry)
  if not entry then
    return nil
  end
  local request = entry.request
  local result = {
    id = entry.id,
    kind = request.kind,
    prompt = request.prompt,
  }
  if request.kind == "select" then
    ---@cast request Neoagent.NormalizedSelect
    result.items = {}
    for _, item in ipairs(request.items) do
      result.items[#result.items + 1] = {
        id = item.id,
        label = item.label,
        detail = item.detail,
        disabled = item.disabled,
      }
    end
  elseif request.kind == "input" then
    result.default = request.default
    result.multiline = request.multiline
    result.secret = request.secret
    result.allow_empty = request.allow_empty
    result.mask = request.mask
  else
    result.body = request.body
  end
  return result --[[@as Neoagent.PublicPresentation]]
end

---@param state Neoagent.PresentationState
---@return Neoagent.PresentationSnapshot
local function snapshot(state)
  return {
    active = public_entry(state.active),
    queue_count = #state.queue,
  }
end

---@param entry? Neoagent.PresentationEntry
---@return boolean
local function finish_fallback(entry)
  if not entry then
    return false
  end
  local cancel = entry.cancel_fallback
  entry.cancel_fallback = nil
  if not cancel then
    return false
  end
  pcall(cancel)
  return true
end

---@return true?, string?
function Presenter:_publish()
  if not self.attachment then
    return true
  end
  local ok, err = pcall(self.attachment.present, snapshot(self.state))
  if ok then
    return true
  end
  local failure = util.normalize_error(err, "presentation")
  local message = "Presenter surface failed: " .. failure.message
  self:detach(self.attachment, message)
  return nil, message
end

---@param entry Neoagent.PresentationEntry
function Presenter:_remove(entry)
  local state = self.state
  if state.active == entry then
    finish_fallback(entry)
    state.active = table.remove(state.queue, 1)
    self:_start_active()
    return true
  end
  for index, queued in ipairs(state.queue) do
    if queued == entry then
      table.remove(state.queue, index)
      self:_publish()
      return true
    end
  end
end

---@return true?, string?
function Presenter:_start_active()
  local entry = self.state.active
  if not entry then
    return self:_publish()
  end
  if self.attachment then
    return self:_publish()
  end
  local host = self.host
  ---@type Applet.PresentationCallbacks<unknown>
  local done = {
    resolve = function(value)
      self:resolve(entry.id, value)
    end,
    reject = function(err)
      self:reject(entry.id, err)
    end,
  }
  local ok, cancel_or_error = pcall(function()
    local request = entry.request
    if request.kind == "select" then
      ---@cast request Neoagent.NormalizedSelect
      return host.select(request, done)
    elseif request.kind == "input" then
      ---@cast request Neoagent.NormalizedInput
      return host.input(request, done)
    end
    ---@cast request Neoagent.NormalizedNotice
    return host.notice(request, done)
  end)
  if not ok then
    self:reject(entry.id, cancel_or_error)
  elseif type(cancel_or_error) == "function" then
    if self.state.active == entry then
      entry.cancel_fallback = cancel_or_error
    else
      pcall(cancel_or_error)
    end
  end
end

---@param request Neoagent.PresentationRequest
---@return Neoagent.PresentationRun
---@return Neoagent.PresentationEntry?
function Presenter:_request(request)
  assert(not self.destroyed, "Presenter is destroyed")
  ---@type Neoagent.PresentationEntry?
  local entry
  local run = async.run(
    ---@return Neoagent.PresentationResult
    function()
      local value = async.await(
        ---@param done Neoagent.AwaitCallbacks<unknown>
        function(done)
          self.state.sequence = self.state.sequence + 1
          entry = {
            id = "presentation-" .. self.state.sequence,
            request = request,
            done = done,
          }
          if self.state.active then
            self.state.queue[#self.state.queue + 1] = entry
            self:_publish()
          else
            self.state.active = entry
            self:_start_active()
          end
          return function()
            self:_remove(assert(entry))
          end
        end
      )
      return { ok = true, value = value }
    end,
    { error_kind = "presentation" }
  )
  return run, entry
end

---@param entry? Neoagent.PresentationEntry
---@param request Neoagent.PresentationRequest
---@return boolean?, string?
function Presenter:_update(entry, request)
  if self.destroyed or not entry or entry.request.kind ~= request.kind then
    return false
  end
  if self.state.active == entry then
    if not self.attachment then
      return false
    end
    entry.request = request
    return self:_publish()
  end
  for _, queued in ipairs(self.state.queue) do
    if queued == entry then
      entry.request = request
      return true
    end
  end
  return false
end

---@param request Neoagent.SelectRequest
---@return Neoagent.PresentationRun
---@return fun(items: (Neoagent.SelectItem|string)[]): boolean?, string?
function Presenter:select(request)
  local normalized = normalize_select(request)
  local run, entry = self:_request(normalized)
  return run,
    function(items)
      return self:_update(
        entry,
        normalize_select({
          prompt = normalized.prompt,
          items = items,
        })
      )
    end
end

---@param request Neoagent.InputRequest
---@return Neoagent.PresentationRun
function Presenter:input(request)
  local run = self:_request(normalize_input(request))
  return run
end

---@param request Neoagent.NoticeRequest
---@return Neoagent.PresentationRun
function Presenter:notice(request)
  local run = self:_request(normalize_notice(request))
  return run
end

---@param request? Neoagent.ConfirmRequest
---@return Neoagent.PresentationRun
function Presenter:confirm(request)
  request = request or {}
  assert(
    type(request) == "table" and (next(request) == nil or not util.is_list(request)),
    "confirmation request must be an object"
  )
  local normalized = normalize_select({
    prompt = request.prompt or "Confirm",
    items = {
      { id = "yes", label = request.accept_label or "Yes", value = true },
      { id = "no", label = request.reject_label or "No", value = false },
    },
  })
  local run = self:_request(normalized)
  return run
end

---@param id string
---@param value unknown
---@return true?, Neoagent.Error?
function Presenter:resolve(id, value)
  local entry = self.state.active
  if not entry or entry.id ~= id then
    return nil, presentation_error("Presentation is not active: " .. tostring(id))
  end
  local request = entry.request
  if request.kind == "select" then
    ---@cast request Neoagent.NormalizedSelect
    ---@type Neoagent.NormalizedSelectItem?
    local selected
    for _, item in ipairs(request.items) do
      if item.id == value and not item.disabled then
        selected = item
        break
      end
    end
    if not selected then
      return nil, presentation_error("Selection is unavailable: " .. tostring(value))
    end
    value = selected.value
  elseif entry.request.kind == "notice" then
    value = true
  else
    if
      type(value) ~= "string"
      or value:find("\0", 1, true)
      or not entry.request.multiline and value:find("\n", 1, true)
    then
      return nil, presentation_error("Input response is invalid")
    end
    if value == "" and not entry.request.allow_empty then
      return nil, presentation_error("Input response must not be empty")
    end
  end
  finish_fallback(entry)
  self.state.active = table.remove(self.state.queue, 1)
  entry.done.resolve(value)
  self:_start_active()
  return true
end

---@param id string
---@param err unknown
---@return boolean
function Presenter:reject(id, err)
  local entry = self.state.active
  if not entry or entry.id ~= id then
    return false
  end
  finish_fallback(entry)
  self.state.active = table.remove(self.state.queue, 1)
  entry.done.reject(util.normalize_error(err, "presentation"))
  self:_start_active()
  return true
end

---@param id string
---@param reason? string
---@return boolean
function Presenter:cancel(id, reason)
  return self:reject(id, util.error("cancelled", reason or "Presentation cancelled"))
end

---@param opts Neoagent.PresenterAttachment
---@return fun(reason?: string)
function Presenter:attach(opts)
  assert(not self.destroyed, "Presenter is destroyed")
  assert(type(opts) == "table" and type(opts.present) == "function", "Presenter attachment requires present")
  assert(opts.notify == nil or type(opts.notify) == "function", "Presenter attachment notify must be a function")
  assert(opts.open_uri == nil or type(opts.open_uri) == "function", "Presenter attachment open_uri must be a function")
  if self.attachment then
    self:detach(self.attachment, "Presenter surface replaced")
  end
  local attachment = {
    present = opts.present,
    notify = opts.notify,
    open_uri = opts.open_uri,
  }
  finish_fallback(self.state.active)
  self.attachment = attachment
  local ok, err = self:_publish()
  if not ok then
    error(err, 0)
  end
  local active = true
  return function(reason)
    if not active then
      return
    end
    active = false
    self:detach(attachment, reason)
  end
end

---@param attachment Neoagent.PresenterAttachment
---@param reason? string
---@return boolean
function Presenter:detach(attachment, reason)
  if self.attachment ~= attachment then
    return false
  end
  self.attachment = nil
  if reason then
    local pending = {}
    if self.state.active then
      pending[#pending + 1] = self.state.active
    end
    vim.list_extend(pending, self.state.queue)
    self.state.active, self.state.queue = nil, {}
    for _, entry in ipairs(pending) do
      finish_fallback(entry)
      entry.done.reject(presentation_error(reason))
    end
  elseif self.state.active then
    self:_start_active()
  end
  return true
end

---@return Neoagent.PresentationSnapshot
function Presenter:snapshot()
  return util.copy(snapshot(self.state))
end

---@param request string|Neoagent.NotificationRequest
---@param level? integer
---@return unknown
function Presenter:notify(request, level)
  local message = type(request) == "table" and request.message or request
  level = type(request) == "table" and request.level or level
  message = valid_text(message, "notification message", true)
  local effect = self.attachment and self.attachment.notify or self.host.notify
  return effect(message, level)
end

---@param request string|{uri: string}
---@return unknown
function Presenter:open_uri(request)
  local uri = type(request) == "table" and request.uri or request
  uri = valid_text(uri, "URI")
  local effect = self.attachment and self.attachment.open_uri or self.host.open_uri
  return effect(uri)
end

function Presenter:destroy()
  if self.destroyed then
    return
  end
  self.destroyed = true
  local pending = {}
  if self.state.active then
    pending[#pending + 1] = self.state.active
  end
  vim.list_extend(pending, self.state.queue)
  self.state.active, self.state.queue, self.attachment = nil, {}, nil
  for _, entry in ipairs(pending) do
    finish_fallback(entry)
    entry.done.reject(presentation_error("Presenter was destroyed"))
  end
end

---@param opts? { host?: Neoagent.PresenterHost }
---@return Neoagent.Presenter
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table" and (next(opts) == nil or not util.is_list(opts)), "Presenter options must be an object")
  local host = opts.host or Applet.Presenter
  for _, method in ipairs({ "select", "input", "notice", "notify", "open_uri" }) do
    assert(type(host[method]) == "function", "Presenter host requires " .. method)
  end
  return setmetatable({
    host = host,
    state = { active = nil, queue = {}, sequence = 0 },
    attachment = nil,
    destroyed = false,
  }, Presenter)
end

M.Presenter = Presenter

return M
