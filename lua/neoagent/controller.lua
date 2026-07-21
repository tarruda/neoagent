local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}
local next_id = 0
local ui_positions = { auto = true, left = true, right = true, top = true, bottom = true, center = true }

local function relative_age(modified_at, now)
  local milliseconds = math.max(0, now - modified_at)
  local minutes = math.floor(milliseconds / 60000)
  local hours = math.floor(milliseconds / 3600000)
  local days = math.floor(milliseconds / 86400000)
  if minutes < 1 then return "now" end
  if minutes < 60 then return minutes .. "m" end
  if hours < 24 then return hours .. "h" end
  if days < 7 then return days .. "d" end
  if days < 30 then return math.floor(days / 7) .. "w" end
  if days < 365 then return math.floor(days / 30) .. "mo" end
  return math.floor(days / 365) .. "y"
end

local function session_text(info)
  local text = info.name or info.first_message or "(no messages)"
  text = util.trim(text:gsub("[%c%s]+", " "))
  if text == "" then text = "(no messages)" end
  if vim.fn.strchars(text) > 80 then text = vim.fn.strcharpart(text, 0, 80) .. "…" end
  return text
end

local function session_choices(sessions, current_path)
  local fs = require("neoagent.fs")
  local by_path = {}
  local nodes = {}
  for _, info in ipairs(sessions) do
    local node = { info = info, children = {}, latest = info.modified_at }
    nodes[#nodes + 1] = node
    by_path[fs.canonical(info.path)] = node
  end

  local roots = {}
  for _, node in ipairs(nodes) do
    local parent = node.info.parent_session and by_path[fs.canonical(node.info.parent_session)]
    if parent and parent ~= node then
      parent.children[#parent.children + 1] = node
    else
      roots[#roots + 1] = node
    end
  end

  local function update_latest(node)
    for _, child in ipairs(node.children) do
      node.latest = math.max(node.latest, update_latest(child))
    end
    return node.latest
  end
  local function sort_nodes(values)
    table.sort(values, function(a, b)
      if a.latest == b.latest then return a.info.path > b.info.path end
      return a.latest > b.latest
    end)
    for _, node in ipairs(values) do sort_nodes(node.children) end
  end
  for _, root in ipairs(roots) do update_latest(root) end
  sort_nodes(roots)

  local choices = {}
  local current = current_path and fs.canonical(current_path)
  local now = util.now_ms()
  local function visit(node, prefix, branch, is_last)
    local info = util.copy(node.info)
    info.current = current ~= nil and fs.canonical(info.path) == current
    local marker = info.current and "● " or "  "
    info.label = string.format("%s%s%s  %d  %s", marker, prefix .. branch,
      session_text(info), info.message_count, relative_age(info.modified_at, now))
    choices[#choices + 1] = info
    local child_prefix = prefix
    if branch ~= "" then child_prefix = child_prefix .. (is_last and "   " or "│  ") end
    for index, child in ipairs(node.children) do
      local child_last = index == #node.children
      visit(child, child_prefix, child_last and "└─ " or "├─ ", child_last)
    end
  end
  for _, root in ipairs(roots) do visit(root, "", "", true) end
  return choices
end

function M.from_config(options)
  assert(type(options) == "table", "controller configuration is required")
  options = util.copy(options)
  local settings_name = options.name or "default"
  next_id = next_id + 1
  local controller = { _neoagent_controller = true }
  local state = {
    session = nil,
    model = nil,
    model_selection = nil,
    thinking_level = nil,
    workspace = nil,
    workspace_settings = nil,
    workspace_overrides = {},
    store = nil,
    store_seeded = false,
    run = nil,
    login_run = nil,
    live_usage = nil,
    provider_status = nil,
    pending_events = {},
    last_result = nil,
    listeners = {},
    next_listener_id = 0,
    run_id = 0,
    status = "idle",
    destroyed = false,
  }
  local auth_manager = require("neoagent.auth").configured(options)

  local function notify(message, level)
    vim.notify("neoagent: " .. message, level or vim.log.levels.INFO)
  end

  local function configured()
    return options
  end

  local function publish(update)
    for _, listener in pairs(state.listeners) do
      local ok, err = pcall(listener, update)
      if not ok then notify("controller listener failed: " .. tostring(err), vim.log.levels.ERROR) end
    end
  end

  local function model_label()
    local selected = state.model_selection
    return selected and (selected.provider .. "/" .. selected.model) or "no model"
  end

  local function usage_tokens(usage)
    if type(usage) ~= "table" then return nil end
    if type(usage.totalTokens) == "number" and usage.totalTokens >= 0 then
      return usage.totalTokens
    end
    local total = 0
    for _, key in ipairs({ "input", "output", "cacheRead", "cacheWrite" }) do
      if type(usage[key]) == "number" then total = total + usage[key] end
    end
    return total
  end

  local function estimate_messages(messages, first)
    local characters = 0
    for index = first, #messages do
      local ok, encoded = pcall(vim.json.encode, messages[index])
      if ok then characters = characters + #encoded end
    end
    return math.ceil(characters / 4)
  end

  local function context_usage()
    local total = state.model and state.model.context_window
    if type(total) ~= "number" or total <= 0 or not state.session then return false end
    local messages = state.session:context_messages()
    if not messages then return false end
    local used
    if state.live_usage then
      used = state.live_usage.tokens
      used = used + estimate_messages(messages, state.live_usage.message_count + 1)
    else
      for index = #messages, 1, -1 do
        local message = messages[index]
        local tokens = message.role == "assistant" and usage_tokens(message.usage) or nil
        if tokens and message.stopReason ~= "aborted" and message.stopReason ~= "error" then
          used = tokens + estimate_messages(messages, index + 1)
          break
        end
      end
      used = used or estimate_messages(messages, 1)
    end
    return { used = used, total = total, percent = used / total * 100 }
  end

  local function preference_defaults()
    local options = configured()
    return {
      default_model = options.default_model,
      default_thinking_level = options.default_thinking_level,
      ui_position = options.ui.position,
    }
  end

  local function preferences()
    return util.deep_merge(preference_defaults(), state.workspace_overrides)
  end

  local function thinking_level(model, preferred)
    return require("neoagent.thinking").clamp(model, preferred or preferences().default_thinking_level)
  end

  local function scoped_workspace_settings(settings, warn)
    local accepted = { ui_position = settings.ui_position }
    local controllers = settings.controllers
    if controllers ~= nil and (type(controllers) ~= "table" or util.is_list(controllers)) then
      if warn then notify("ignoring invalid workspace controllers", vim.log.levels.WARN) end
      controllers = nil
    end
    local scoped = controllers and controllers[settings_name]
    if scoped ~= nil and (type(scoped) ~= "table" or util.is_list(scoped)) then
      if warn then
        notify("ignoring invalid workspace settings for " .. settings_name, vim.log.levels.WARN)
      end
      scoped = nil
    end
    scoped = scoped or {}
    accepted.default_model = scoped.default_model
    accepted.default_thinking_level = scoped.default_thinking_level
    if accepted.default_model == nil then accepted.default_model = settings.default_model end
    if accepted.default_thinking_level == nil then
      accepted.default_thinking_level = settings.default_thinking_level
    end
    local merged = util.deep_merge(preference_defaults(), accepted)
    if merged.default_model ~= nil and (type(merged.default_model) ~= "table"
        or type(merged.default_model.provider) ~= "string" or type(merged.default_model.model) ~= "string") then
      if warn then notify("ignoring invalid workspace default_model", vim.log.levels.WARN) end
      accepted.default_model = nil
    end
    if not require("neoagent.thinking").is_level(merged.default_thinking_level) then
      if warn then notify("ignoring invalid workspace default_thinking_level", vim.log.levels.WARN) end
      accepted.default_thinking_level = nil
    end
    if not ui_positions[merged.ui_position] then
      if warn then notify("ignoring invalid workspace ui_position", vim.log.levels.WARN) end
      accepted.ui_position = nil
    end
    return accepted
  end

  local function workspace_patch(patch)
    local result = {}
    if patch.ui_position ~= nil then result.ui_position = patch.ui_position end
    local scoped = {}
    if patch.default_model ~= nil then scoped.default_model = patch.default_model end
    if patch.default_thinking_level ~= nil then
      scoped.default_thinking_level = patch.default_thinking_level
    end
    if next(scoped) ~= nil then result.controllers = { [settings_name] = scoped } end
    return result
  end

  local function save_workspace_settings(patch)
    local persistence = configured().persistence
    if not state.workspace_settings or not persistence.workspace_settings then return true end
    local saved, err = state.workspace_settings:update(workspace_patch(patch))
    if not saved then return nil, err end
    state.workspace_overrides = scoped_workspace_settings(saved, false)
    return true
  end

  local function activate_workspace(cwd)
    local root = require("neoagent.fs").canonical(cwd)
    if state.workspace and state.workspace.root == root then return end
    state.workspace = require("neoagent.workspace").new({ root = root, cwd = root })
    state.workspace_settings, state.workspace_overrides = nil, {}
    state.model, state.model_selection, state.thinking_level = nil, nil, nil
    state.live_usage, state.provider_status = nil, nil
    local options = configured().persistence
    if not options.enabled then return end
    state.workspace_settings = require("neoagent.workspace_settings").new({
      directory = options.directory,
      root = root,
    })
    if not options.workspace_settings then return end
    local settings, settings_err = state.workspace_settings:load()
    if not settings then
      notify(settings_err.message .. (settings_err.detail and ": " .. settings_err.detail or ""),
        vim.log.levels.WARN)
      return
    end
    state.workspace_overrides = scoped_workspace_settings(settings, true)
  end

  local function seed_store()
    if not state.store or state.store_seeded or not state.model then return true end
    local selected = state.model_selection or { provider = state.model.provider, model = state.model.id }
    local ok, err = state.store:append_model_change(selected.provider, selected.model)
    if not ok then return nil, err end
    if state.thinking_level then
      ok, err = state.store:append_thinking_level_change(state.thinking_level)
      if not ok then return nil, err end
    end
    state.store_seeded = true
    return true
  end

  local function make_session(cwd)
    local Session = require("neoagent.session")
    activate_workspace(cwd)
    local options = configured().persistence
    if options.enabled then
      state.store = require("neoagent.storage").new({ directory = options.directory, cwd = state.workspace.root })
      state.store_seeded = false
      local session, err = Session.new({ store = state.store })
      if not session then return nil, err end
      local seeded, seed_err = seed_store()
      if not seeded then return nil, seed_err end
      return session
    end
    state.store, state.store_seeded = nil, false
    return Session.new()
  end

  local function ensure_session()
    if state.session then return state.session end
    local cwd = vim.fn.getcwd()
    local session, err = make_session(cwd)
    if not session then error(err, 0) end
    state.session = session
    return session
  end

  local function ensure_model()
    if state.model then
      local seeded, seed_err = seed_store()
      if not seeded then error(seed_err, 0) end
      return state.model
    end
    if not state.workspace then activate_workspace(vim.fn.getcwd()) end
    local selected = preferences().default_model
    if selected then
      state.model = require("neoagent.models").resolve(selected.provider, selected.model, options, auth_manager)
      state.model_selection = util.copy(selected)
    else
      state.model = require("neoagent.models").resolve(nil, nil, options, auth_manager)
      state.model_selection = { provider = state.model.provider, model = state.model.id }
    end
    state.thinking_level = thinking_level(state.model, state.thinking_level)
    local seeded, seed_err = seed_store()
    if not seeded then error(seed_err, 0) end
    return state.model
  end

  local function system_prompt(value, tools)
    local options = configured()
    local agents_result = options.agents and require("neoagent.agents").discover({
      cwd = state.workspace.root,
      global_files = options.agents.global_files,
      project_filenames = options.agents.project_filenames,
    }) or { files = {}, diagnostics = {} }
    local has_read = vim.tbl_contains(vim.tbl_map(function(tool) return tool.name end, tools), "read_file")
    local skills_result = options.skills and has_read and require("neoagent.skills").discover({
      cwd = state.workspace.root,
      global_dirs = options.skills.global_dirs,
      project_dirs = options.skills.project_dirs,
    }) or { skills = {}, diagnostics = {} }
    for _, diagnostic in ipairs(vim.list_extend(agents_result.diagnostics, skills_result.diagnostics)) do
      notify(diagnostic.message .. ": " .. diagnostic.path, vim.log.levels.WARN)
    end
    local context = {
      session = state.session,
      model = state.model,
      workspace = state.workspace,
      prompt = value,
      tools = tools,
      agents = agents_result.files,
      skills = skills_result.skills,
    }
    local prompt = options.system_prompt
    if type(prompt) == "function" then
      prompt = prompt(context)
    elseif prompt == nil then
      prompt = require("neoagent.system_prompt").default(context)
    end
    return require("neoagent.system_prompt").compose(prompt, context)
  end

  local function tool_array()
    local options = configured()
    if options._tools_supplied then return options.tools end
    return require("neoagent.tools").coding()
  end

  local function refresh_buffer(path)
    local absolute = state.workspace and state.workspace:resolve(path)
    if not absolute then return end
    local canonical = vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buffer) then
        local name = vim.api.nvim_buf_get_name(buffer)
        if name ~= "" and (vim.uv.fs_realpath(name) or vim.fs.normalize(name)) == canonical then
          if vim.bo[buffer].modified then
            notify("did not reload modified buffer " .. name, vim.log.levels.WARN)
          else
            vim.api.nvim_buf_call(buffer, function() vim.cmd("silent checktime") end)
          end
        end
      end
    end
  end

  local function close_unmatched_calls()
    local messages = state.session:messages()
    local pending = {}
    local order = {}
    for _, message in ipairs(messages) do
      if message.role == "assistant" then
        for _, block in ipairs(message.content or {}) do
          if block.type == "toolCall" then
            pending[block.id] = block
            order[#order + 1] = block.id
          end
        end
      elseif message.role == "toolResult" then
        pending[message.toolCallId] = nil
      end
    end
    for _, id in ipairs(order) do
      local call = pending[id]
      if call then
        local ok, err = state.session:append({
          role = "toolResult",
          toolCallId = call.id,
          toolName = call.name,
          content = { { type = "text", text = "Tool execution was interrupted; side effects may already have occurred." } },
          isError = true,
          timestamp = util.now_ms(),
        })
        if not ok then return nil, err end
      end
    end
    return true
  end

  local function interaction(options)
    return require("neoagent.chat").run(options.session, options.prompt, {
      model = options.model,
      system_prompt = options.system_prompt,
      tools = options.tools,
      context = options.context,
      execute_tool = options.execute_tool,
      max_rounds = options.max_rounds,
      model_options = options.model_options,
      on_event = options.on_event,
      on_done = options.on_done,
    })
  end

  local function continuation(options)
    return require("neoagent.chat").continue(options.session, {
      model = options.model,
      system_prompt = options.system_prompt,
      tools = options.tools,
      context = options.context,
      execute_tool = options.execute_tool,
      max_rounds = options.max_rounds,
      model_options = options.model_options,
      on_event = options.on_event,
      on_done = options.on_done,
    })
  end

  local function is_context_overflow(result)
    if not result or result.ok or not result.error then return false end
    local parts = { result.error.message or "" }
    if result.error.detail ~= nil then
      local ok, encoded = pcall(vim.json.encode, result.error.detail)
      parts[#parts + 1] = ok and encoded or tostring(result.error.detail)
    end
    local text = table.concat(parts, " "):lower()
    for _, pattern in ipairs({ "rate limit", "too many requests" }) do
      if text:find(pattern, 1, true) then return false end
    end
    for _, pattern in ipairs({
      "context_length_exceeded", "model_context_window_exceeded",
      "request_too_large", "prompt is too long", "prompt too long",
      "input is too long for requested model", "exceeds the context window",
      "maximum context length", "maximum prompt length",
      "reduce the length of the messages", "maximum allowed input length",
      "longer than the model's context length",
      "exceeds the available context size", "greater than the context length",
      "context window exceeds limit", "exceeded model token limit",
      "token limit exceeded", "too many tokens", "too large for model",
      "configured context size", "range of input length should be",
      "request too large",
    }) do
      if text:find(pattern, 1, true) then return true end
    end
    return false
  end

  local function context()
    return {
      name = options.name or false,
      model = model_label(),
      thinking = state.thinking_level or false,
      workspace = state.workspace and state.workspace.root or nil,
      position = preferences().ui_position,
      state = state.status,
      context_usage = context_usage(),
      provider_status = state.provider_status or false,
    }
  end

  local function update_context()
    publish({ type = "context", context = context() })
  end

  local function compaction_settings()
    local selected = configured().compaction
    if selected == false or not state.model then return nil end
    return require("neoagent.compaction").settings(selected, state.model.context_window)
  end

  local function needs_compaction()
    local settings = compaction_settings()
    if not settings or not settings.auto or not state.session then return false end
    local messages = state.session:context_messages()
    if not messages then return false end
    local estimate = require("neoagent.compaction").estimate_context(messages)
    return require("neoagent.compaction").should_compact(
      estimate.tokens, state.model.context_window or 0, settings)
  end

  local function start_compaction(reason, instructions, run_id, after)
    local settings = compaction_settings()
    if not settings or not state.session then return nil end
    local path, path_err = state.session:path()
    if not path then return nil, path_err end
    local preparation, prepare_err = require("neoagent.compaction").prepare(path, settings)
    if not preparation then return nil, prepare_err end

    local selected = configured().compaction.run or require("neoagent.compaction").run
    state.status = "compacting"
    state.pending_events = {}
    publish({ type = "event", event = { type = "compaction_start", reason = reason } })
    update_context()
    local run
    run = selected({
      preparation = preparation,
      model = state.model,
      model_options = {
        request_opts = require("neoagent.thinking").request_opts(state.model, state.thinking_level),
      },
      instructions = instructions,
      reason = reason,
      session = state.session,
      on_event = function(event)
        if run_id ~= state.run_id then return end
        if event.type == "provider_status" then
          state.provider_status = type(event.text) == "string" and event.text or nil
          update_context()
        end
        publish({ type = "event", event = event })
      end,
      on_done = function(done)
        if run_id ~= state.run_id then return end
        local result = util.copy(done)
        if done.ok then
          local ok, err = state.session:append_entry("compaction", {
            summary = done.summary,
            firstKeptEntryId = done.first_kept_entry_id,
            tokensBefore = done.tokens_before,
            usage = done.usage,
            details = done.details,
            fromHook = selected ~= require("neoagent.compaction").run or nil,
          })
          if not ok then result = { ok = false, error = err } end
        end
        if result.ok then
          local projected = assert(state.session:context_messages())
          result.estimated_tokens_after = require("neoagent.compaction").estimate_context(projected).tokens
          publish({ type = "messages", messages = state.session:messages() })
        end
        state.run = nil
        state.status = "idle"
        state.live_usage = nil
        update_context()
        publish({ type = "event", event = {
          type = "compaction_end", reason = reason, result = result,
        } })
        if after then after(result) end
      end,
    })
    assert(type(run) == "table" and type(run.cancel) == "function", "compaction.run must return a Run")
    state.run = run
    return run
  end

  local function finish_interaction(done)
    state.run = nil
    state.status = "idle"
    state.live_usage = nil
    state.last_result = util.copy(done)
    update_context()
    publish({ type = "finish", result = done })
  end

  local function submit(prompt)
    if util.trim(prompt) == "" then return nil end
    if state.status ~= "idle" then notify("the agent is busy", vim.log.levels.WARN) return nil end
    local ok, result = pcall(function()
      ensure_session()
      ensure_model()
      local closed, close_err = close_unmatched_calls()
      if not closed then error(close_err, 0) end
      local options = configured()
      local tools = tool_array()
      local run_id = state.run_id + 1
      state.run_id = run_id
      state.pending_events = {}
      state.last_result = nil
      local overflow_retried = false
      local base = {
        session = state.session,
        prompt = prompt,
        model = state.model,
        system_prompt = system_prompt(prompt, tools),
        tools = tools,
        workspace = state.workspace,
        context = { workspace = state.workspace },
        execute_tool = options.execute_tool,
        max_rounds = options.max_tool_rounds,
        thinking_level = state.thinking_level,
        model_options = {
          request_opts = require("neoagent.thinking").request_opts(state.model, state.thinking_level),
        },
      }
      local function on_event(event)
        if run_id ~= state.run_id then return end
        if event.type == "usage" then
          state.live_usage = {
            tokens = usage_tokens(event.usage) or 0,
            message_count = #assert(state.session:context_messages()) + 1,
          }
          update_context()
        elseif event.type == "provider_status" then
          state.provider_status = type(event.text) == "string" and event.text or nil
          update_context()
        elseif event.type == "message_end" then
          update_context()
        end
        if event.type == "message_end" then
          state.pending_events = {}
        elseif event.type ~= "usage" and event.type ~= "provider_status" then
          state.pending_events[#state.pending_events + 1] = util.copy(event)
        end
        publish({ type = "event", event = event })
        if event.type == "tool_end" and not event.message.isError
            and (event.call.name == "write_file" or event.call.name == "edit_file") then
          refresh_buffer(event.call.arguments.path)
        end
      end

      local launch
      local function abandon_overflow_message()
        local path = assert(state.session:path())
        local last = path[#path]
        if last and last.type == "message" and last.message.role == "assistant"
            and last.message.stopReason == "error" then
          local parent = last.parentId == vim.NIL and nil or last.parentId
          local moved, move_err = state.session:move_to(parent)
          if not moved then error(move_err, 0) end
          publish({ type = "messages", messages = state.session:messages() })
        end
      end

      local function on_done(done)
        if run_id ~= state.run_id then return end
        local can_continue = options.continuation ~= nil or options.interaction == nil
        if not overflow_retried and can_continue and is_context_overflow(done) then
          overflow_retried = true
          abandon_overflow_message()
          local compacted = start_compaction("overflow", nil, run_id, function(result)
            if result.ok then launch(true) else finish_interaction(done) end
          end)
          if compacted then return end
        end
        if needs_compaction() then
          local compacted = start_compaction("threshold", nil, run_id, function()
            finish_interaction(done)
          end)
          if compacted then return end
        end
        finish_interaction(done)
      end

      launch = function(continuing)
        local call = vim.tbl_extend("force", {}, base)
        call.on_event, call.on_done = on_event, on_done
        local selected = continuing and (options.continuation or continuation)
          or (options.interaction or interaction)
        local run = selected(call)
        assert(type(run) == "table" and type(run.cancel) == "function", "interaction must return a Run")
        state.run = run
        state.status = "running"
        state.pending_events = {}
        publish({ type = "messages", messages = state.session:messages() })
        update_context()
        return run
      end

      if needs_compaction() then
        local compacted = start_compaction("threshold", nil, run_id, function() launch(false) end)
        if compacted then return compacted end
      end
      return launch(false)
    end)
    if not ok then
      local err = util.normalize_error(result, "session")
      notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    return result
  end

  function controller:prepare()
    local ok, err = pcall(function()
      if not state.workspace then activate_workspace(vim.fn.getcwd()) end
      if preferences().default_model then ensure_model() end
      update_context()
    end)
    if not ok then
      err = util.normalize_error(err, "controller")
      notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    return true
  end

  function controller:send(text)
    return submit(text)
  end

  function controller:compact(instructions)
    if state.run then notify("cannot compact while the agent is running", vim.log.levels.WARN) return nil end
    if configured().compaction == false then notify("compaction is disabled") return nil end
    if not state.session then notify("no active session") return nil end
    local ok, err = pcall(ensure_model)
    if not ok then
      err = util.normalize_error(err, "compaction")
      notify(err.message, vim.log.levels.ERROR)
      return nil, err
    end
    local run_id = state.run_id + 1
    state.run_id = run_id
    state.last_result = nil
    local run, compact_err = start_compaction("manual", instructions, run_id)
    if not run then
      compact_err = compact_err or util.error("compaction", "Nothing to compact")
      notify(compact_err.message, vim.log.levels.WARN)
      return nil, compact_err
    end
    return run
  end

  function controller:stop()
    if not state.run then return false end
    state.status = "stopping"
    update_context()
    state.run:cancel()
    return true
  end

  function controller:new_session()
    if state.run then notify("cannot create a session while the agent is running", vim.log.levels.WARN) return nil end
    local cwd = vim.fn.getcwd()
    local root = require("neoagent.fs").canonical(cwd)
    if state.workspace and state.workspace.root == root then
      state.model, state.model_selection, state.thinking_level = nil, nil, nil
    end
    state.live_usage, state.provider_status = nil, nil
    state.pending_events, state.last_result = {}, nil
    local session, err = make_session(cwd)
    if not session then notify(err.message, vim.log.levels.ERROR) return nil, err end
    state.session = session
    publish({ type = "messages", messages = {} })
    update_context()
    return session
  end

  local function restore_session_preferences(stored)
    state.model, state.model_selection, state.thinking_level = nil, nil, nil
    local workspace_default = preferences().default_model
    local candidates = {}
    if stored.model then candidates[#candidates + 1] = stored.model end
    if workspace_default and (not stored.model or workspace_default.provider ~= stored.model.provider
        or workspace_default.model ~= stored.model.model) then
      candidates[#candidates + 1] = workspace_default
    end
    for _, selected in ipairs(candidates) do
      local ok, model = pcall(require("neoagent.models").resolve, selected.provider, selected.model,
        options, auth_manager)
      if ok then
        state.model = model
        state.model_selection = util.copy(selected)
        break
      else
        notify("could not restore model " .. tostring(selected.provider) .. "/" .. tostring(selected.model)
          .. ": " .. tostring(model), vim.log.levels.WARN)
      end
    end
    if state.model then
      state.thinking_level = thinking_level(state.model, stored.thinking_level)
    end
  end

  local function resume_path(path)
    local store, err = require("neoagent.storage").open(path)
    if not store then notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR) return nil, err end
    local cwd = store:metadata().cwd
    activate_workspace(cwd)
    local session
    session, err = require("neoagent.session").new({ store = store })
    if not session then notify(err.message, vim.log.levels.ERROR) return nil, err end
    state.session = session
    state.store, state.store_seeded = store, true
    state.live_usage, state.provider_status = nil, nil
    state.pending_events, state.last_result = {}, nil
    restore_session_preferences(store:state())
    publish({ type = "messages", messages = session:messages() })
    update_context()
    return session
  end

  local function entry_label(entry, current)
    local label = entry.type .. " · " .. entry.id:sub(1, 8)
    if entry.type == "message" then
      local ok, value = pcall(util.text_content, entry.message.content)
      value = ok and util.trim(value:gsub("[%c%s]+", " ")) or ""
      if value ~= "" then
        if vim.fn.strchars(value) > 70 then value = vim.fn.strcharpart(value, 0, 70) .. "…" end
        label = entry.message.role .. " · " .. value
      else
        label = entry.message.role .. " · " .. entry.id:sub(1, 8)
      end
    end
    return entry.id == current and "● " .. label or label
  end

  function controller:branch(entry_id, summary)
    if state.run then notify("cannot change branches while the agent is running", vim.log.levels.WARN) return nil end
    if not state.session then notify("no active session") return nil end
    local ok, err = state.session:move_to(entry_id, summary)
    if not ok then notify(err.message, vim.log.levels.ERROR) return nil, err end
    state.pending_events, state.last_result = {}, nil
    state.live_usage, state.provider_status = nil, nil
    local stored = assert(state.session:state())
    restore_session_preferences(stored)
    state.store_seeded = stored.model ~= nil
    publish({ type = "messages", messages = state.session:messages() })
    update_context()
    return true
  end

  function controller:select_branch(on_selected)
    if not state.session then notify("no active session") return nil end
    local entries = state.session:entries()
    local current = state.session:leaf_id()
    local choices = {}
    for _, entry in ipairs(entries) do
      if entry.type == "message" or entry.type == "custom_message"
          or entry.type == "branch_summary" or entry.type == "compaction" then
        choices[#choices + 1] = { id = entry.id, label = entry_label(entry, current) }
      end
    end
    if #choices == 0 then notify("the active session has no entries") return nil end
    vim.ui.select(choices, {
      prompt = "Neoagent branch",
      format_item = function(item) return item.label end,
    }, function(choice)
      if not choice then return end
      local moved = controller:branch(choice.id)
      if moved and on_selected then on_selected(choice.id) end
    end)
    return true
  end

  function controller:fork(entry_id, position)
    if state.run then notify("cannot fork while the agent is running", vim.log.levels.WARN) return nil end
    if not state.store or not state.store:metadata().persisted then
      notify("the active session is not persisted")
      return nil
    end
    local selected_text
    if entry_id and (position == nil or position == "before") then
      local target = state.session:entry(entry_id)
      if target and target.type == "message" and target.message.role == "user" then
        local text_ok, text = pcall(util.text_content, target.message.content)
        if text_ok then selected_text = text end
      end
    end
    local persistence = configured().persistence
    local store, err = require("neoagent.storage").fork(state.store, {
      directory = persistence.directory,
      cwd = state.workspace.root,
      entry_id = entry_id,
      position = position,
    })
    if not store then notify(err.message, vim.log.levels.ERROR) return nil, err end
    local session
    session, err = require("neoagent.session").new({ store = store })
    if not session then notify(err.message, vim.log.levels.ERROR) return nil, err end
    state.store, state.store_seeded, state.session = store, true, session
    state.pending_events, state.last_result = {}, nil
    state.live_usage, state.provider_status = nil, nil
    restore_session_preferences(store:state())
    publish({ type = "messages", messages = session:messages() })
    update_context()
    return session, selected_text
  end

  function controller:select_fork(on_selected)
    if not state.session then notify("no active session") return nil end
    local choices = {}
    for _, entry in ipairs(state.session:entries()) do
      if entry.type == "message" and entry.message.role == "user" then
        choices[#choices + 1] = { id = entry.id, label = entry_label(entry) }
      end
    end
    if #choices == 0 then notify("the active session has no user messages") return nil end
    vim.ui.select(choices, {
      prompt = "Fork Neoagent session from",
      format_item = function(item) return item.label end,
    }, function(choice)
      if not choice then return end
      local forked, selected_text = controller:fork(choice.id, "before")
      if forked and on_selected then on_selected(forked, selected_text) end
    end)
    return true
  end

  function controller:resume(path, on_resumed)
    if state.run then notify("cannot resume while the agent is running", vim.log.levels.WARN) return nil end
    if path and path ~= "" then return resume_path(vim.fn.fnamemodify(path, ":p")) end
    local options = configured().persistence
    local sessions = require("neoagent.storage").list_sessions(options.directory, vim.fn.getcwd())
    if #sessions == 0 then notify("no sessions found for the current directory") return nil end
    local metadata = state.session and state.session:metadata()
    local current_path = metadata and metadata.path
    local choices = session_choices(sessions, current_path)
    vim.ui.select(choices, {
      prompt = "Resume Neoagent session:",
      format_item = function(item) return item.label end,
    }, function(choice)
      if choice then
        local session = controller:resume(choice.path)
        if session and on_resumed then on_resumed(session) end
      end
    end)
    return true
  end

  function controller:select_model(on_selected)
    if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
    local choices, err = require("neoagent.models").available(options, auth_manager)
    if not choices then
      notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR)
      return nil
    end
    if #choices == 0 then notify("no models configured") return nil end
    vim.ui.select(choices, { prompt = "Select Neoagent model:" }, function(choice)
      if not choice then return end
      local provider_id, model_id = choice:match("^([^/]+)/(.+)$")
      if provider_id then
        local model = controller:set_model(provider_id, model_id)
        if model and on_selected then on_selected(model) end
      end
    end)
    return true
  end

  function controller:set_model(provider_id, model_id)
    if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
    if not state.workspace then activate_workspace(vim.fn.getcwd()) end
    local ok, model = pcall(require("neoagent.models").resolve, provider_id, model_id, options, auth_manager)
    if not ok then notify(tostring(model), vim.log.levels.ERROR) return nil, model end
    local next_thinking = thinking_level(model, state.thinking_level)
    if state.store then
      local recorded, record_err = state.store:append_model_change(provider_id, model_id)
      if not recorded then notify(record_err.message, vim.log.levels.ERROR) return nil, record_err end
      if not state.store_seeded and next_thinking then
        recorded, record_err = state.store:append_thinking_level_change(next_thinking)
        if not recorded then notify(record_err.message, vim.log.levels.ERROR) return nil, record_err end
      end
      state.store_seeded = true
    end
    local saved, save_err = save_workspace_settings({
      default_model = { provider = provider_id, model = model_id },
    })
    if not saved and not state.store then
      notify(save_err.message, vim.log.levels.ERROR)
      return nil, save_err
    elseif not saved then
      notify("model changed for this session but workspace settings were not saved: " .. save_err.message,
        vim.log.levels.WARN)
    end
    state.model = model
    state.model_selection = { provider = provider_id, model = model_id }
    state.thinking_level = next_thinking
    state.live_usage, state.provider_status = nil, nil
    update_context()
    return model
  end

  function controller:available_thinking_levels()
    local ok, model = pcall(ensure_model)
    if not ok then return nil, util.normalize_error(model, "model") end
    return require("neoagent.thinking").levels(model)
  end

  function controller:get_thinking_level()
    return state.thinking_level
  end

  function controller:set_thinking_level(level)
    if state.run then notify("cannot change thinking level while the agent is running", vim.log.levels.WARN) return nil end
    if not require("neoagent.thinking").is_level(level) then
      notify("unknown thinking level: " .. tostring(level), vim.log.levels.ERROR)
      return nil
    end
    local levels, err = self:available_thinking_levels()
    if not levels then notify(err.message, vim.log.levels.ERROR) return nil, err end
    if not vim.tbl_contains(levels, level) then
      notify("thinking level " .. level .. " is not supported by " .. model_label(), vim.log.levels.WARN)
      return nil
    end
    if state.store then
      local recorded, record_err = state.store:append_thinking_level_change(level)
      if not recorded then notify(record_err.message, vim.log.levels.ERROR) return nil, record_err end
    end
    local saved, save_err = save_workspace_settings({ default_thinking_level = level })
    if not saved and not state.store then
      notify(save_err.message, vim.log.levels.ERROR)
      return nil, save_err
    elseif not saved then
      notify("thinking changed for this session but workspace settings were not saved: " .. save_err.message,
        vim.log.levels.WARN)
    end
    state.store_seeded = state.store and true or state.store_seeded
    state.thinking_level = level
    update_context()
    return level
  end

  function controller:cycle_thinking_level()
    if state.run then notify("cannot change thinking level while the agent is running", vim.log.levels.WARN) return nil end
    local ok, model = pcall(ensure_model)
    if not ok then notify(util.normalize_error(model, "model").message, vim.log.levels.ERROR) return nil end
    local level = require("neoagent.thinking").next(model, state.thinking_level)
    if not level then notify("current model does not support thinking", vim.log.levels.WARN) return nil end
    level = self:set_thinking_level(level)
    if not level then return nil end
    notify("thinking level: " .. level)
    return level
  end

  local function login_prompt(prompt, done)
    if prompt.type == "select" then
      vim.ui.select(prompt.options, {
        prompt = prompt.message,
        format_item = function(item) return item.label end,
      }, function(choice)
        if choice then done.resolve(choice.id) else done.reject(util.error("auth", "Login cancelled")) end
      end)
    else
      vim.ui.input({ prompt = prompt.message .. " ", default = "" }, function(value)
        if value and value ~= "" then done.resolve(value) else done.reject(util.error("auth", "Login cancelled")) end
      end)
    end
  end

  local function login_event(event)
    if event.type == "auth_url" then
      notify((event.instructions or "Open this URL to authenticate:") .. "\n" .. event.url)
      pcall(vim.ui.open, event.url)
    elseif event.type == "device_code" then
      notify("Open " .. event.verificationUri .. " and enter code " .. event.userCode)
      pcall(vim.ui.open, event.verificationUri)
    elseif event.message then
      notify(event.message)
    end
  end

  function controller:login(method_id)
    if state.login_run then notify("a login is already active", vim.log.levels.WARN) return nil end
    local methods = configured().auth.methods
    if method_id == nil or method_id == "" then
      local choices = {}
      for id, method in pairs(methods) do choices[#choices + 1] = { id = id, label = method.name } end
      table.sort(choices, function(a, b) return a.label < b.label end)
      if #choices == 0 then notify("no login methods configured") return nil end
      vim.ui.select(choices, {
        prompt = "Select Neoagent login:",
        format_item = function(item) return item.label end,
      }, function(choice) if choice then controller:login(choice.id) end end)
      return true
    end
    if not methods[method_id] then notify("unknown login method: " .. method_id, vim.log.levels.ERROR) return nil end
    local run = auth_manager:login(method_id, {
      prompt = login_prompt,
      notify = login_event,
      on_done = function(result)
        state.login_run = nil
        if result.ok then
          notify("logged in with " .. methods[method_id].name .. "; credentials saved to " .. configured().auth.path)
        elseif result.error.kind ~= "cancelled" then
          notify(result.error.message, vim.log.levels.ERROR)
        end
      end,
    })
    state.login_run = run
    return run
  end

  function controller:cancel_login()
    if not state.login_run then return false end
    state.login_run:cancel()
    return true
  end

  function controller:set_ui_position(position)
    if not ui_positions[position] then return nil, util.error("ui", "invalid window position") end
    if not state.workspace then activate_workspace(vim.fn.getcwd()) end
    local saved, err = save_workspace_settings({ ui_position = position })
    if not saved then return nil, err end
    state.workspace_overrides.ui_position = position
    update_context()
    return position
  end

  function controller:subscribe(listener)
    assert(type(listener) == "function", "controller listener must be a function")
    state.next_listener_id = state.next_listener_id + 1
    local id = state.next_listener_id
    state.listeners[id] = listener
    local subscribed = true
    return function()
      if not subscribed then return end
      subscribed = false
      state.listeners[id] = nil
    end
  end

  function controller:snapshot()
    local messages = state.session and state.session:messages() or {}
    return {
      messages = messages,
      context = context(),
      events = util.copy(state.pending_events),
      result = util.copy(state.last_result),
    }
  end

  function controller:get_session() return state.session end
  function controller:get_model() return state.model end
  function controller:config() return util.copy(options) end
  function controller:is_running() return state.run ~= nil end
  function controller:_state() return state end

  function controller:destroy()
    if state.destroyed then return end
    state.destroyed = true
    state.run_id = state.run_id + 1
    if state.run then state.run:cancel() end
    if state.login_run then state.login_run:cancel() end
    state.run, state.login_run = nil, nil
    state.listeners = {}
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end

  state.augroup = vim.api.nvim_create_augroup("NeoagentLifecycle" .. next_id, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.augroup,
    callback = function()
      if state.run then state.run:cancel() end
      if state.login_run then state.login_run:cancel() end
    end,
  })

  return controller
end

function M.new(opts)
  return M.from_config(config.resolve(opts))
end

return M
