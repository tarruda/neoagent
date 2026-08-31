local Applet = require("applet")
local protocol = require("neoagent.ui.renderer")
local util = require("neoagent.util")

local ui = Applet.Pane.nodes
local display = Applet.Pane.text
local widgets = Applet.Pane.widgets

local Transcript = {}
Transcript.__index = Transcript

local render
local image_scope = 0

local function next_image_scope()
  image_scope = image_scope + 1
  return "transcript:" .. image_scope
end

local function mapping_values(value)
  if type(value) == "string" then return { value } end
  if type(value) == "table" then return value end
  return {}
end

local function add_bindings(result, modes, lhs, action, opts)
  modes = type(modes) == "table" and modes or { modes }
  for _, mode in ipairs(modes) do
    for _, key in ipairs(mapping_values(lhs)) do
      result[#result + 1] = {
        mode = mode,
        lhs = key,
        action = action,
        count = opts and opts.count or false,
        desc = opts and opts.desc or nil,
      }
    end
  end
end

local function title(state)
  local parts = {}
  local label = state.context.name or state.config.title
  if type(label) == "string" and label ~= "" then parts[#parts + 1] = label end
  parts[#parts + 1] = state.context.model or "no model"
  if type(state.context.thinking) == "string" then
    parts[#parts + 1] = "think: " .. state.context.thinking
  end
  return { { text = " " .. table.concat(parts, " · ") .. " ", style = "window_title" } }
end

local function token_count(value)
  if value < 1000 then return tostring(math.floor(value + 0.5)) end
  local divisor = value >= 1000000 and 1000000 or 1000
  local suffix = value >= 1000000 and "m" or "k"
  return string.format("%.1f", value / divisor):gsub("%.0$", "") .. suffix
end

local function token_rate(value)
  if type(value) ~= "number" or value <= 0 or value ~= value
      or value == math.huge then
    return nil
  end
  return string.format("%.1f", value)
end

local function border_character(border)
  if type(border) == "table" then
    local value = border[6] or border[2]
    if type(value) == "table" then value = value[1] end
    if type(value) == "string" and value ~= "" then return value end
  elseif border == "double" then
    return "═"
  elseif border == "solid" then
    return " "
  end
  return "─"
end

local function slice_width(value, width, from_end)
  return display.truncate(value, width, {
    marker = "",
    side = from_end and "left" or "right",
  })
end

local function truncate(value, width)
  if display.width(value) <= width then return value end
  if width <= 1 then return "…" end
  return display.truncate(value, width)
end

local function fit_left(runs, width, maximum)
  if width <= maximum then return runs, width end
  if maximum <= 0 then return {}, 0 end
  local remaining = maximum - 1
  local fitted = {}
  for index = #runs, 1, -1 do
    if remaining <= 0 then break end
    local run = runs[index]
    local run_width = display.width(run.text)
    if run_width <= remaining then
      table.insert(fitted, 1, run)
      remaining = remaining - run_width
    else
      local suffix = slice_width(run.text, remaining, true)
      if suffix ~= "" then
        table.insert(fitted, 1, { text = suffix, style = run.style,
          group = run.group })
        remaining = remaining - display.width(suffix)
      end
    end
  end
  table.insert(fitted, 1, { text = "…", style = "muted" })
  local fitted_width = 0
  for _, run in ipairs(fitted) do
    fitted_width = fitted_width + display.width(run.text)
  end
  return fitted, fitted_width
end

local function footer(state, width)
  local context = state.context
  local active = context.state == "running" or context.state == "stopping"
    or context.state == "compacting"
  local waiting = state.dialog ~= nil
  local label = waiting and "Waiting for response"
    or context.state == "stopping" and "Stopping..."
    or context.state == "compacting" and "Compacting..."
    or active and "Working..." or "Idle"
  local padding = waiting and 1
    or display.width("Compacting...")
      - display.width(label) + 1
  local left = {
    { text = " ", style = "muted" },
    { text = active and not waiting and state.spinner or " ",
      style = active and not waiting and "accent" or "muted" },
    { text = " " .. label .. string.rep(" ", padding),
      style = waiting and "dialog_action" or "muted" },
  }
  local left_width = 0
  for _, run in ipairs(left) do
    left_width = left_width + display.width(run.text)
  end
  local usage = context.context_usage
  local right_parts = {}
  if type(usage) == "table" then
    local percent = usage.percent > 0 and usage.percent < 0.1
        and "<0.1" or string.format("%.1f", usage.percent)
    right_parts[#right_parts + 1] = string.format("ctx %s/%s (%s%%)",
      token_count(usage.used), token_count(usage.total), percent)
  end
  local stats = context.inference_stats
  if type(stats) == "table" then
    local prompt = token_rate(stats.prompt_tokens_per_second)
    local generation = token_rate(stats.generation_tokens_per_second)
    if generation then
      right_parts[#right_parts + 1] = "tg " .. generation .. " t/s"
    elseif prompt then
      right_parts[#right_parts + 1] = "pp " .. prompt .. " t/s"
    end
  end
  local right = #right_parts > 0
    and " " .. table.concat(right_parts, " · ") .. " " or nil
  local border = border_character(state.config.border)
  if not active and not waiting and not right then
    local idle = truncate(" Idle ", width)
    local idle_width = display.width(idle)
    local before = math.floor((width - idle_width) / 2)
    local after = width - idle_width - before
    return {
      { text = string.rep(border, before), group = "NeoagentBorder" },
      { text = idle, style = "muted" },
      { text = string.rep(border, after), group = "NeoagentBorder" },
    }
  end
  local midpoint = math.floor(width / 2)
  left, left_width = fit_left(left, left_width, midpoint)
  if right then right = truncate(right, width - midpoint) end
  local runs, used = {}, 0
  local function add(run)
    if run.text == "" then return end
    runs[#runs + 1] = run
    used = used + display.width(run.text)
  end
  add({ text = string.rep(border, midpoint - left_width), group = "NeoagentBorder" })
  for _, run in ipairs(left) do add(run) end
  if right then add({ text = right, style = "muted" }) end
  add({ text = string.rep(border, math.max(0, width - used)), group = "NeoagentBorder" })
  return runs
end

local function status_region(state)
  local steering = state.context.steering or {}
  if #steering == 0 then return nil end
  local lines = {}
  for _, message in ipairs(steering) do
    lines[#lines + 1] = { {
      text = " Steering: " .. util.trim(tostring(message):gsub("%s+", " ")),
      style = "muted",
    } }
  end
  lines[#lines + 1] = { {
    text = " ↳ " .. (state.dequeue_key or "Alt-Up")
      .. " to edit queued messages",
    style = "muted",
  } }
  return ui.region({
    key = "transcript:status",
    revision = state.status_revision,
    child = ui.virtual({
      key = "transcript:status:virtual",
      placement = "above-end",
      lines = lines,
    }),
  })
end

local function dialog_region(state)
  local snapshot = state.dialog
  if not snapshot then return nil end
  local dialog = snapshot.active
  local actions = {}
  for _, action in ipairs(dialog.actions or {}) do
    actions[#actions + 1] = {
      key = action.id,
      label = "[" .. action.key .. "] " .. action.label,
      quick_keys = { action.key },
      action = ui.action("transcript.dialog", {
        dialog = dialog.id,
        action = action.id,
      }),
    }
  end
  local queue
  if snapshot.queue_count and snapshot.queue_count > 0 then
    queue = ui.text({
      key = "dialog:" .. dialog.id .. ":queue",
      text = string.format("%d more dialog%s pending",
        snapshot.queue_count, snapshot.queue_count == 1 and "" or "s"),
      wrap = "word",
    })
  end
  local mappings = state.config.mappings or {}
  local root, entry = widgets.dialog({
    key = "dialog:" .. dialog.id .. ":widget",
    title = dialog.title,
    body = dialog.body,
    queue_status = queue,
    background = "dialog_background",
    actions = actions,
    initial_action = dialog.default_action,
    keys = {
      previous = mappings.menu_previous,
      next = mappings.menu_next,
      activate = mappings.card_details,
    },
  })
  return ui.region({
    key = "dialog:" .. dialog.id,
    revision = state.dialog_revision,
    child = root,
  }), entry
end

local function new_pane(self)
  return Applet.Pane.new({
    key = "transcript",
    extent = "document",
    frame_interval_ms = 50,
    theme = self.renderer.theme,
    image_system = self.image_system,
    render = function(state, env)
      return render(state, env, self.render_cache)
    end,
    handlers = {
      ["transcript.details"] = function(event)
        self.callbacks.details(event.payload.block)
      end,
      ["transcript.card_move"] = function(event)
        self.callbacks.card_move(event.payload.direction, event.count)
      end,
      ["transcript.dialog"] = function(event)
        self.callbacks.dialog(event.payload.dialog, event.payload.action)
      end,
    },
    on_error = self.on_error,
  })
end

local function root_bindings(state)
  local mappings = state.config.mappings or {}
  local bindings = {}
  if not state.dialog then
    add_bindings(bindings, "n", mappings.card_details,
      ui.action("applet.target.activate"), { desc = "Open card details" })
  end
  add_bindings(bindings, "n", mappings.card_previous,
    ui.action("transcript.card_move", { direction = -1 }), {
      count = true, desc = "Previous card",
    })
  add_bindings(bindings, "n", mappings.card_next,
    ui.action("transcript.card_move", { direction = 1 }), {
      count = true, desc = "Next card",
    })
  return bindings
end

local function cached_block_node(state, env, block, index, width, cache)
  local previous = state.blocks[index - 1]
  local following = state.blocks[index + 1]
  local signature = {
    revision = block.revision,
    previous_key = previous and previous.key or false,
    previous_revision = previous and previous.revision or false,
    following_key = following and following.key or false,
    following_revision = following and following.revision or false,
    width = width,
    surface_width = env.width,
    details_key = state.details_key or false,
    wrap_cards = state.config.wrap_cards == true,
    show_images = state.config.images ~= false
      and (type(state.config.images) ~= "table"
        or state.config.images.display ~= "expanded"),
  }
  local cached = cache[block.key]
  local matches = cached ~= nil
  for key, value in pairs(signature) do
    if not cached or cached[key] ~= value then matches = false break end
  end
  if matches then return cached.node, cached.region_revision end

  local tool
  if block.kind == "tool" and state.resolve_tool then
    local name = block.name or block.call and block.call.name
    local ok, resolved = pcall(state.resolve_tool, name)
    if ok and type(resolved) == "table" then
      tool = { name = resolved.name, render = resolved.render }
    end
  end
  local node, continuation = protocol.render_block(state.renderer, block, {
    key = block.key,
    width = width,
    surface_width = env.width,
    spinner = state.spinner,
    details_key = state.details_key,
    wrap_cards = state.config.wrap_cards == true,
    show_images = signature.show_images,
    tool = tool,
    previous = previous,
    following = following,
  }, cached and cached.renderer_continuation or nil)
  if not node then error(continuation.message, 0) end
  local revision_parts = {}
  for _, key in ipairs({
    "revision", "previous_key", "previous_revision", "following_key",
    "following_revision", "width", "surface_width", "details_key",
    "wrap_cards", "show_images",
  }) do
    local value = tostring(signature[key])
    revision_parts[#revision_parts + 1] = #value .. ":" .. value
  end
  signature.region_revision = table.concat(revision_parts)
  signature.node = node
  signature.renderer_continuation = continuation
  cache[block.key] = signature
  return node, signature.region_revision
end

render = function(state, env, cache)
  local width = math.max(1, env.width - 2)
  local document = cache.document
  if not document or document.revision ~= state.document_revision
      or document.width ~= width then
    local regions, active = {}, {}
    for index, block in ipairs(state.blocks) do
      active[block.key] = true
      local node, revision = cached_block_node(
        state, env, block, index, width, cache.blocks)
      regions[#regions + 1] = ui.region({
        key = "block:" .. block.key,
        revision = revision,
        child = node,
      })
    end
    for key in pairs(cache.blocks) do
      if not active[key] then cache.blocks[key] = nil end
    end
    local status = status_region(state)
    if status then regions[#regions + 1] = status end
    local dialog, dialog_entry = dialog_region(state)
    if dialog then regions[#regions + 1] = dialog end
    local view = { scroll = "follow_end" }
    if dialog_entry then
      view.target_intent = widgets.menu_intent(dialog_entry,
        "dialog-focus:" .. state.dialog.active.id)
    end
    document = {
      revision = state.document_revision,
      width = width,
      root = ui.scope({
        key = "transcript:scope",
        bindings = root_bindings(state),
        child = ui.column({
          key = "transcript:regions",
          children = regions,
        }),
      }),
      view = view,
    }
    cache.document = document
  end
  return {
    root = document.root,
    chrome = {
      title = title(state),
      title_pos = "center",
      footer = footer(state, env.width),
      footer_pos = "left",
      options = {
        wrap = true,
        linebreak = true,
        breakindent = true,
        cursorline = false,
      },
    },
    view = document.view,
  }
end

function Transcript.new(opts)
  opts = opts or {}
  opts.config = opts.config or {}
  opts.callbacks = opts.callbacks or {}
  local callbacks = opts.callbacks
  local self = setmetatable({
    renderer = opts.renderer,
    image_system = opts.image_system,
    on_error = opts.on_error,
    config = opts.config,
    resolve_tool = opts.resolve_tool,
    callbacks = {
      details = callbacks.details or function() end,
      card_move = callbacks.card_move or function() end,
      dialog = callbacks.dialog or function() end,
    },
    blocks = {},
    messages = {},
    calls = {},
    pending_calls = {},
    response = 1,
    counter = 0,
    text_epoch = 0,
    context = { state = "idle" },
    spinner = "⠋",
    status_revision = 0,
    dialog_revision = 0,
    dialog = nil,
    render_cache = { blocks = {} },
    block_snapshots = {},
    snapshot_blocks = {},
    dirty_blocks = {},
    block_indices = {},
    animated_blocks = {},
    document_revision = 0,
    image_scope = next_image_scope(),
  }, Transcript)
  self.pane = new_pane(self)
  self:_publish()
  return self
end

function Transcript:_state()
  local details = (self.config.mappings or {}).card_details
  local dequeue = (self.config.mappings or {}).dequeue_steering
  for block in pairs(self.dirty_blocks) do
    local index = self.block_indices[block]
    if index then
      local snapshot = util.copy(block)
      self.block_snapshots[block] = snapshot
      self.snapshot_blocks[index] = snapshot
    end
    self.dirty_blocks[block] = nil
  end
  return {
    blocks = self.snapshot_blocks,
    context = util.copy(self.context),
    dialog = util.copy(self.dialog),
    renderer = self.renderer,
    resolve_tool = self.resolve_tool,
    config = util.copy(self.config),
    spinner = self.spinner,
    details_key = type(details) == "table" and details[1] or details,
    dequeue_key = type(dequeue) == "table" and dequeue[1] or dequeue,
    status_revision = self.status_revision,
    dialog_revision = self.dialog_revision,
    document_revision = self.document_revision,
  }
end

function Transcript:mapping_bindings()
  return root_bindings({
    config = self.config,
    dialog = self.dialog,
  })
end

function Transcript:set_config(config)
  self.config = config or {}
  self.document_revision = self.document_revision + 1
  self:_publish()
end

function Transcript:set_renderer(renderer)
  self.renderer = renderer
  self.render_cache = { blocks = {} }
  self.document_revision = self.document_revision + 1
  self.pane:set_theme(renderer.theme)
  self:_publish()
end

function Transcript:_publish(eager)
  self.pane:set_state(self:_state(), eager and { eager = true } or nil)
end

function Transcript:_touch(block)
  block.revision = (block.revision or 0) + 1
  self.dirty_blocks[block] = true
  self.document_revision = self.document_revision + 1
end

local function entry_id(message)
  local value = type(message) == "table" and message._neoagent_entry_id
  return type(value) == "string" and value ~= "" and value or nil
end

function Transcript:_can_append(messages)
  local count = #self.messages
  if count == 0 then return true end
  if #messages < count then return false end
  local first = entry_id(self.messages[1])
  local last = entry_id(self.messages[count])
  return first ~= nil and last ~= nil
    and first == entry_id(messages[1])
    and last == entry_id(messages[count])
end

function Transcript:_change(block)
  self:_touch(block)
end

function Transcript:_next_text_epoch()
  self.text_epoch = self.text_epoch + 1
  return self.text_epoch
end

function Transcript:_finish_text_streams()
  for _, blocks in ipairs({ self.live_texts, self.live_thinkings }) do
    for _, block in pairs(blocks or {}) do
      if block.text_epoch ~= nil then
        block.text_epoch = nil
        self:_change(block)
      end
    end
  end
end

function Transcript:_add_block(block, key)
  self.counter = self.counter + 1
  block.key = key or "generated:" .. self.counter
  block.revision = 1
  block.image_scope = self.image_scope
  self.blocks[#self.blocks + 1] = block
  self.block_indices[block] = #self.blocks
  self.dirty_blocks[block] = true
  self.document_revision = self.document_revision + 1
  return block
end

function Transcript:_set_animated(block, active)
  self.animated_blocks[block] = active and true or nil
end

function Transcript:_message(message, prefix)
  prefix = prefix or "message:" .. (self.counter + 1)
  if message.role == "user" then
    return self:_add_block({
      kind = "user",
      content = util.copy(message.content),
      text = util.text_content(message.content),
    }, prefix .. ":user")
  elseif message.role == "assistant" then
    for index, content in ipairs(message.content or {}) do
      if content.type == "thinking" and self.config.show_thinking ~= false then
        self:_add_block({ kind = "thinking", text = content.thinking or "" },
          prefix .. ":thinking:" .. index)
      elseif content.type == "text" then
        self:_add_block({ kind = "assistant", text = content.text or "" },
          prefix .. ":text:" .. index)
      elseif content.type == "toolCall" then
        local block = self:_add_block({
          kind = "tool", name = content.name, state = "pending",
          call = util.copy(content),
        }, content.id and "tool:" .. content.id
          or prefix .. ":tool:" .. tostring(index))
        self:_set_animated(block, true)
        if content.id then self.calls[content.id] = block end
      end
    end
  elseif message.role == "toolResult" then
    local block = self.calls[message.toolCallId]
    if block and block.finished then return block end
    if not block then
      block = self:_add_block({
        kind = "tool", name = message.toolName,
        call = { name = message.toolName, arguments = {} },
      }, message.toolCallId and "tool:" .. message.toolCallId
        or prefix .. ":tool-result:unknown")
      if message.toolCallId then self.calls[message.toolCallId] = block end
    end
    block.message = util.copy(message)
    block.state = message.isError and "error" or "success"
    block.finished = true
    self:_set_animated(block, false)
    self:_change(block)
    return block
  elseif message.role == "compactionSummary" then
    return self:_add_block({
      kind = "compaction", summary = message.summary or "",
      tokens_before = message.tokensBefore,
    }, prefix .. ":compaction")
  end
end

function Transcript:set_messages(messages)
  messages = messages or {}
  if self:_can_append(messages) then
    local first = #self.messages + 1
    for index = first, #messages do
      local message = util.copy(messages[index])
      self.messages[index] = message
      self:_message(message, "message:"
        .. tostring(message._neoagent_entry_id or index))
    end
    if first <= #messages then self:_publish() end
    return
  end
  self.messages = util.copy(messages)
  self.image_scope = next_image_scope()
  self.blocks, self.calls, self.pending_calls = {}, {}, {}
  self.render_cache = { blocks = {} }
  self.block_snapshots = {}
  self.snapshot_blocks = {}
  self.dirty_blocks = {}
  self.block_indices = {}
  self.animated_blocks = {}
  self.document_revision = self.document_revision + 1
  self.counter = 0
  self.response = self.response + 1
  self.live_text, self.live_texts = nil, {}
  self.live_thinking, self.live_thinkings = nil, {}
  for index, message in ipairs(self.messages) do
    self:_message(message, "message:"
      .. tostring(message._neoagent_entry_id or index))
  end
  self:_publish()
end

function Transcript:apply(event)
  if event.type == "text_delta" then
    self.live_texts = self.live_texts or {}
    local key = event.index ~= nil and tostring(event.index) or "default"
    local block = self.live_texts[key]
    if not block then
      block = self:_add_block({
        kind = "assistant",
        text = "",
        text_epoch = self:_next_text_epoch(),
      },
        "response:" .. self.response .. ":text:" .. key)
      self.live_texts[key] = block
      if key == "default" then self.live_text = block end
    end
    block.text = block.text .. (event.text or "")
    self:_change(block)
  elseif event.type == "thinking_delta" then
    if self.config.show_thinking ~= false then
      self.live_thinkings = self.live_thinkings or {}
      local key = event.index ~= nil and tostring(event.index) or "default"
      local block = self.live_thinkings[key]
      if not block then
        block = self:_add_block({
          kind = "thinking",
          text = "",
          text_epoch = self:_next_text_epoch(),
        },
          "response:" .. self.response .. ":thinking:" .. key)
        self.live_thinkings[key] = block
        if key == "default" then self.live_thinking = block end
      end
      block.text = block.text .. (event.text or "")
      self:_change(block)
    end
  elseif event.type == "tool_call_delta" then
    local key = self.response .. ":" .. tostring(event.index)
    local block = self.pending_calls[key]
    if not block then
      block = self:_add_block({
        kind = "tool", name = event.name, state = "pending", raw = "",
      }, "response:" .. self.response .. ":tool:" .. tostring(event.index))
      self.pending_calls[key] = block
    end
    self:_set_animated(block, true)
    block.name = event.name or block.name
    block.id = event.id or block.id
    if block.id then
      self.calls[block.id] = block
      block.key = "tool:" .. block.id
    end
    block.raw = block.raw .. (event.arguments_delta or "")
    self:_change(block)
  elseif event.type == "message_end" then
    local message = event.message
    self.messages[#self.messages + 1] = util.copy(message)
    if message.role == "user" then
      self:_message(message)
    elseif message.role == "assistant" then
      local call_index = 0
      self.live_texts = self.live_texts or {}
      for _, content in ipairs(message.content or {}) do
        if content.type == "text" then
          local key = content.index ~= nil and tostring(content.index) or "default"
          local block = self.live_texts[key]
            or (key == "default" and self.live_text or nil)
          if block then
            block.text_epoch = nil
            block.text = content.text or block.text
            self:_change(block)
          else
            block = self:_add_block({ kind = "assistant", text = content.text or "" },
              "response:" .. self.response .. ":text:" .. key)
            self.live_texts[key] = block
          end
        elseif content.type == "thinking" and self.config.show_thinking ~= false then
          local key = content.index ~= nil and tostring(content.index) or "default"
          local block = self.live_thinkings and self.live_thinkings[key]
            or (key == "default" and self.live_thinking or nil)
          if block then
            block.text_epoch = nil
            block.text = content.thinking or ""
            self:_change(block)
          else
            block = self:_add_block({ kind = "thinking", text = content.thinking or "" },
              "response:" .. self.response .. ":thinking:" .. key)
          end
        elseif content.type == "toolCall" then
          local provider_index = content.index ~= nil
              and content.index or call_index
          local block = content.id and self.calls[content.id]
            or self.pending_calls[self.response .. ":" .. provider_index]
          if not block then
            block = self:_add_block({ kind = "tool", state = "pending" },
              content.id and "tool:" .. content.id
                or "response:" .. self.response .. ":tool:" .. provider_index)
          end
          self:_set_animated(block, true)
          block.call, block.id, block.name = util.copy(content), content.id, content.name
          if content.id then
            self.calls[content.id] = block
            block.key = "tool:" .. content.id
          end
          self:_change(block)
          call_index = call_index + 1
        end
      end
      self:_finish_text_streams()
      self.response = self.response + 1
      self.live_text, self.live_texts = nil, {}
      self.live_thinking, self.live_thinkings = nil, {}
    end
  elseif event.type == "tool_start" then
    local block = self.calls[event.call.id]
    if not block then
      block = self:_add_block({ kind = "tool" }, "tool:" .. event.call.id)
      self.calls[event.call.id] = block
    end
    block.call, block.name, block.state = util.copy(event.call),
      event.call.name, "running"
    self:_set_animated(block, true)
    self:_change(block)
  elseif event.type == "tool_update" then
    local block = self.calls[event.call.id]
    if block then block.update = util.copy(event.result) self:_change(block) end
  elseif event.type == "tool_end" then
    local block = self.calls[event.call.id]
    if not block then
      block = self:_add_block({ kind = "tool" }, "tool:" .. event.call.id)
      self.calls[event.call.id] = block
    end
    block.call, block.name = util.copy(event.call), event.call.name
    block.message = util.copy(event.message)
    block.state = event.message.isError and "error" or "success"
    block.update, block.finished = nil, true
    self:_set_animated(block, false)
    self:_change(block)
  elseif event.type == "compaction_end" and event.result and not event.result.ok then
    self:_add_block({
      kind = "notice",
      text = event.result.error and event.result.error.message or "Compaction failed",
      error = true,
    })
  end
  local streaming = event.type == "text_delta"
    or event.type == "thinking_delta"
    or event.type == "tool_call_delta"
    or event.type == "tool_update"
  self:_publish(not streaming)
end

function Transcript:finish(result)
  self:_finish_text_streams()
  if not result.ok then
    local cancelled = result.error and result.error.kind == "cancelled"
    self:_add_block({
      kind = "notice",
      text = result.error and result.error.message or "Unknown error",
      error = not cancelled,
    })
  end
  self.context.state = "idle"
  self.status_revision = self.status_revision + 1
  self:_publish(true)
end

function Transcript:set_context(context)
  local previous_steering = self.context and self.context.steering
  self.context = vim.tbl_extend("force", self.context or {}, util.copy(context or {}))
  if not vim.deep_equal(previous_steering, self.context.steering) then
    self.status_revision = self.status_revision + 1
    self.document_revision = self.document_revision + 1
  end
  self:_publish()
end

function Transcript:set_dialog(snapshot)
  self.dialog = snapshot and util.copy(snapshot) or nil
  self.dialog_revision = self.dialog_revision + 1
  self.status_revision = self.status_revision + 1
  self.document_revision = self.document_revision + 1
  self:_publish(true)
end

function Transcript:set_spinner(value)
  self.spinner = value
  for block in pairs(self.animated_blocks) do self:_change(block) end
  self:_publish()
end

function Transcript:block(key)
  for _, block in ipairs(self.blocks) do
    if block.key == key then return block end
  end
end

function Transcript:destroy()
  self.pane:destroy()
end

return Transcript
