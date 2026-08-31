local Pane = require("applet.pane")
local nodes = require("applet.pane.nodes")
local util = require("applet.util")

local M = {}
local Presentation = {}
Presentation.__index = Presentation

local function action(name, payload)
  return nodes.action("presentation." .. name, payload)
end

local function append_binding(result, modes, keys, name, payload, desc)
  modes = type(modes) == "table" and modes or { modes }
  keys = type(keys) == "table" and keys or { keys }
  for _, mode in ipairs(modes) do
    for _, lhs in ipairs(keys) do
      result[#result + 1] = {
        mode = mode,
        lhs = lhs,
        action = action(name, payload),
        desc = desc,
      }
    end
  end
end

local function cancel_bindings(editable)
  local result = {}
  append_binding(result, "n", { "q", "<Esc>", "<C-c>" },
    "cancel", nil, "Cancel prompt")
  if editable then
    append_binding(result, "i", "<C-c>", "cancel", nil, "Cancel prompt")
  end
  return result
end

local function picker_bindings()
  local result = cancel_bindings(true)
  append_binding(result, { "n", "i" }, { "<Down>", "<C-j>", "<C-n>" },
    "move", { direction = 1 }, "Select next item")
  append_binding(result, { "n", "i" }, { "<Up>", "<C-k>", "<C-p>" },
    "move", { direction = -1 }, "Select previous item")
  append_binding(result, "n", "j", "move", { direction = 1 },
    "Select next item")
  append_binding(result, "n", "k", "move", { direction = -1 },
    "Select previous item")
  append_binding(result, { "n", "i" }, "<CR>", "choose", nil,
    "Choose selected item")
  return result
end

local function render_input(state)
  local request = state.request
  local bindings = cancel_bindings(true)
  local submit_keys = request.multiline and { "<C-s>" } or { "<CR>" }
  for _, lhs in ipairs(submit_keys) do
    append_binding(bindings, "i", lhs, "submit", nil, "Submit prompt")
  end
  append_binding(bindings, "n", "<CR>", "submit", nil, "Submit prompt")
  local help = request.multiline and "<C-s> submit · <C-c> cancel"
    or "<CR> submit · <C-c> cancel"
  return {
    root = nodes.scope({
      key = "presentation:" .. request.id .. ":modal",
      modal = true,
      bindings = bindings,
      child = nodes.virtual({
        key = "presentation:" .. request.id .. ":prompt",
        placement = "above",
        lines = {
          { { text = request.prompt, style = "strong" } },
          { { text = help, style = "muted" } },
        },
      }),
    }),
    chrome = {
      title = { { text = " " .. request.prompt .. " ", style = "window_title" } },
      title_pos = "center",
      options = { wrap = request.multiline, cursorline = true },
    },
    edit = { mask = request.secret and request.mask or nil },
  }
end

local function render_notice(state)
  local request = state.request
  return {
    root = nodes.scope({
      key = "presentation:" .. request.id .. ":notice-scope",
      modal = true,
      bindings = cancel_bindings(false),
      child = nodes.text({
        key = "presentation:" .. request.id .. ":notice-body",
        text = request.body,
        wrap = "word",
      }),
    }),
    chrome = {
      title = { { text = " " .. request.prompt .. " ", style = "window_title" } },
      title_pos = "center",
      options = { wrap = true, cursorline = false },
    },
  }
end

local function render_filter(state)
  local request = state.request
  return {
    root = nodes.scope({
      key = "presentation:" .. request.id .. ":filter-scope",
      modal = true,
      bindings = picker_bindings(),
      child = nodes.virtual({
        key = "presentation:" .. request.id .. ":filter-virtual",
        placement = "above",
        lines = {},
      }),
    }),
    chrome = {
      title = { { text = " " .. request.prompt .. " ", style = "window_title" } },
      title_pos = "center",
      options = { wrap = false, cursorline = false },
    },
    edit = { on_change = action("filter") },
  }
end

local function item_runs(item, selected)
  local selected_style = selected and "menu_selected" or nil
  local result = {
    { text = selected and "● " or "  ", style = selected and "accent" or nil },
    { text = item.label, style = item.disabled and "muted" or selected_style },
  }
  if item.detail ~= nil then
    result[#result + 1] = { text = " · ", style = "muted" }
    result[#result + 1] = { text = item.detail, style = "muted" }
  end
  return result
end

local function render_results(state)
  local request = state.request
  local children = {}
  local selected_target = state.selected and ("presentation:" .. request.id .. ":item:" .. state.selected) or nil
  for _, item in ipairs(state.items) do
    local selected = item.id == state.selected
    children[#children + 1] = nodes.target({
      key = "presentation:" .. request.id .. ":item:" .. item.id,
      group = "presentation:" .. request.id,
      role = "menuitem",
      disabled = item.disabled == true,
      action = item.disabled and nil or action("choose_item", { id = item.id }),
      child = nodes.text({
        key = "presentation:" .. request.id .. ":item:" .. item.id .. ":text",
        runs = item_runs(item, selected),
        wrap = "native",
      }),
    })
  end
  local root
  if #children == 0 then
    root = nodes.text({
      key = "presentation:" .. request.id .. ":empty",
      runs = { { text = "  No matches", style = "muted" } },
      wrap = "native",
    })
  else
    root = nodes.column({
      key = "presentation:" .. request.id .. ":items",
      gap = 0,
      children = children,
    })
  end
  return {
    root = nodes.scope({
      key = "presentation:" .. request.id .. ":results-scope",
      modal = true,
      bindings = picker_bindings(),
      child = root,
    }),
    view = selected_target and {
      target_intent = {
        key = "presentation:" .. request.id .. ":selection:" .. state.revision,
        select = selected_target,
      },
    } or nil,
    chrome = { options = { wrap = false, cursorline = false } },
  }
end

local function fuzzy_score(text, query)
  query = vim.fn.tolower(query):gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then return 0 end
  local haystack = util.characters(vim.fn.tolower(text), "picker item")
  local needle = util.characters(query, "picker query")
  local previous, score = 0, 0
  for _, character in ipairs(needle) do
    local found
    for index = previous + 1, #haystack do
      if haystack[index] == character then found = index break end
    end
    if not found then return nil end
    local gap = found - previous - 1
    score = score + gap * 4
    if found == 1 or haystack[found - 1]:match("[%s%p]") then
      score = score - 3
    elseif gap == 0 then
      score = score - 1
    end
    previous = found
  end
  return score + #haystack - previous
end

local function searchable_text(item)
  return item.label .. (item.detail and (" " .. item.detail) or "")
end

local function copy_items(items)
  util.expect(type(items) == "table", "presentation items",
    "must be a list", 4)
  local count = 0
  for key in pairs(items) do
    util.expect(type(key) == "number" and key >= 1 and key % 1 == 0,
      "presentation items", "must be a list", 4)
    count = count + 1
  end
  util.expect(count == #items, "presentation items", "must be a list", 4)
  local selected, seen = {}, {}
  for index, item in ipairs(items) do
    util.expect(type(item) == "table", "presentation item " .. index,
      "must be a table", 4)
    util.expect(util.nonempty_string(item.id), "presentation item " .. index,
      "requires an id", 4)
    util.expect(type(item.label) == "string", "presentation item " .. index,
      "requires a label", 4)
    util.expect(item.detail == nil or type(item.detail) == "string",
      "presentation item " .. index .. ".detail", "must be a string", 4)
    util.expect(item.disabled == nil or type(item.disabled) == "boolean",
      "presentation item " .. index .. ".disabled", "must be a boolean", 4)
    util.expect(not seen[item.id], "presentation item " .. index,
      "id must be unique", 4)
    seen[item.id] = true
    selected[#selected + 1] = util.copy(item)
  end
  return selected
end

function Presentation:_publish_results(query)
  local matches = {}
  for index, item in ipairs(self.request.items) do
    local score = fuzzy_score(searchable_text(item), query)
    if score ~= nil then
      matches[#matches + 1] = { item = item, score = score, index = index }
    end
  end
  if query:match("%S") then
    table.sort(matches, function(left, right)
      if left.score == right.score then return left.index < right.index end
      return left.score < right.score
    end)
  end
  local items, selected = {}, nil
  for _, match in ipairs(matches) do
    items[#items + 1] = match.item
    if match.item.id == self.selected and not match.item.disabled then
      selected = self.selected
    end
  end
  if not selected then
    for _, item in ipairs(items) do
      if not item.disabled then selected = item.id break end
    end
  end
  self.query, self.visible, self.selected = query, items, selected
  self.revision = self.revision + 1
  self.results:set_state({
    request = self.request,
    items = items,
    selected = selected,
    revision = self.revision,
  })
  if self.on_results then
    self.on_results({
      query = query,
      count = #items,
      selected = selected,
    })
  end
end

function Presentation:_move(direction)
  if not self.selected then return false end
  local enabled, current = {}, nil
  for _, item in ipairs(self.visible) do
    if not item.disabled then
      enabled[#enabled + 1] = item.id
      if item.id == self.selected then current = #enabled end
    end
  end
  if not current or #enabled == 0 then return false end
  local next_index = ((current - 1 + direction) % #enabled) + 1
  self.selected = enabled[next_index]
  self.revision = self.revision + 1
  self.results:set_state({
    request = self.request,
    items = self.visible,
    selected = self.selected,
    revision = self.revision,
  })
  return true
end

function Presentation:_choose(id)
  id = id or self.selected
  if self.finished or not id then return false end
  if self.request.kind == "input" then
    self.finished = true
    self.on_choose(id)
    return true
  end
  for _, item in ipairs(self.visible) do
    if item.id == id and not item.disabled then
      self.finished = true
      self.on_choose(id)
      return true
    end
  end
  return false
end

function Presentation:_cancel()
  if self.finished then return false end
  self.finished = true
  self.on_cancel()
  return true
end

local function new_input(self, opts)
  local request = self.request
  self.pane = Pane.new({
    key = opts.key or "presentation-input",
    extent = "document",
    buffer_mode = "editable",
    theme = opts.theme,
    render = render_input,
    handlers = {
      ["presentation.submit"] = function()
        return self:_choose(self.pane:text())
      end,
      ["presentation.cancel"] = function() return self:_cancel() end,
    },
    on_error = opts.on_error,
  })
  self.pane:set_state({ request = request })
end

local function new_notice(self, opts)
  local request = self.request
  self.pane = Pane.new({
    key = opts.key or "presentation-notice",
    extent = "document",
    buffer_mode = "managed",
    theme = opts.theme,
    render = render_notice,
    handlers = {
      ["presentation.cancel"] = function() return self:_cancel() end,
    },
    on_error = opts.on_error,
  })
  self.pane:set_state({ request = request })
end

local function new_picker(self, opts)
  local request = self.request
  self.filter = Pane.new({
    key = opts.filter_key or (opts.key or "presentation-select")
      .. "-filter",
    extent = "document",
    buffer_mode = "editable",
    theme = opts.theme,
    render = render_filter,
    handlers = {
      ["presentation.filter"] = function()
        self:_publish_results(self.filter:text())
      end,
      ["presentation.move"] = function(event)
        return self:_move(event.payload.direction)
      end,
      ["presentation.choose"] = function() return self:_choose() end,
      ["presentation.cancel"] = function() return self:_cancel() end,
    },
    on_error = opts.on_error,
  })
  self.results = Pane.new({
    key = opts.results_key or (opts.key or "presentation-select")
      .. "-results",
    extent = "document",
    buffer_mode = "managed",
    theme = opts.theme,
    render = render_results,
    handlers = {
      ["presentation.move"] = function(event)
        return self:_move(event.payload.direction)
      end,
      ["presentation.choose"] = function() return self:_choose() end,
      ["presentation.choose_item"] = function(event)
        return self:_choose(event.payload.id)
      end,
      ["presentation.cancel"] = function() return self:_cancel() end,
    },
    on_error = opts.on_error,
  })
  self.pane = self.results
  self.filter:set_state({ request = request })
  self:_publish_results("")
end

function Presentation.new(opts)
  opts = opts or {}
  util.expect(type(opts) == "table", "presentation", "options must be a table", 3)
  util.expect(type(opts.request) == "table", "presentation.request", "must be a table", 3)
  util.expect(type(opts.on_choose) == "function", "presentation.on_choose",
    "must be a function", 3)
  util.expect(type(opts.on_cancel) == "function", "presentation.on_cancel",
    "must be a function", 3)
  util.expect(opts.on_results == nil or type(opts.on_results) == "function",
    "presentation.on_results", "must be a function", 3)
  local request = util.copy(opts.request)
  util.expect(request.kind == "input" or request.kind == "select"
      or request.kind == "notice",
    "presentation.request.kind", "must be select, input, or notice", 3)
  local self = setmetatable({
    request = request,
    on_choose = opts.on_choose,
    on_cancel = opts.on_cancel,
    on_results = opts.on_results,
    query = nil,
    visible = {},
    selected = nil,
    revision = 0,
    finished = false,
    destroyed = false,
  }, Presentation)
  if request.kind == "input" then
    new_input(self, opts)
  elseif request.kind == "notice" then
    new_notice(self, opts)
  else
    request.items = copy_items(request.items)
    new_picker(self, opts)
  end
  return self
end

function Presentation:is_picker()
  return self.filter ~= nil
end

function Presentation:is_destroyed()
  return self.destroyed == true
end

function Presentation:editable_pane()
  return self.filter or self.pane
end

function Presentation:text()
  return self:editable_pane():text()
end

function Presentation:set_text(value)
  util.expect(type(value) == "string", "presentation text", "must be a string", 3)
  local editable = self:editable_pane()
  local changed = editable:replace_text(value)
  if changed and self:is_picker() then self:_publish_results(value) end
  return changed
end

function Presentation:set_theme(theme)
  self.pane:set_theme(theme)
  if self.filter then self.filter:set_theme(theme) end
end

function Presentation:set_items(items)
  util.expect(self:is_picker(), "presentation items",
    "require a selection presentation", 3)
  local selected = copy_items(items)
  self.request.items = selected
  self:_publish_results(self.query or "")
  return #selected
end

function Presentation:destroy()
  if self.destroyed then return end
  self.destroyed = true
  self.pane:destroy()
  if self.filter then self.filter:destroy() end
end

M.new = Presentation.new
M.Presentation = Presentation

return M
