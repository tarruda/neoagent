local config = require("neoagent.config")
local util = require("neoagent.util")

local M = {}

local state = {
  session = nil,
  model = nil,
  workspace = nil,
  view = nil,
  run = nil,
  run_id = 0,
  status = "idle",
}

local function notify(message, level)
  vim.notify("neoagent: " .. message, level or vim.log.levels.INFO)
end

local function configured()
  return config.get()
end

local function model_label()
  return state.model and (state.model.provider .. "/" .. state.model.id) or "no model"
end

local function make_session(cwd)
  local Session = require("neoagent.session")
  local options = configured().persistence
  if options.enabled then
    return Session.new({ store = require("neoagent.storage").new({ directory = options.directory, cwd = cwd }) })
  end
  return Session.new()
end

local function ensure_session()
  if state.session then return state.session end
  local cwd = vim.fn.getcwd()
  local session, err = make_session(cwd)
  if not session then error(err, 0) end
  state.session = session
  state.workspace = require("neoagent.workspace").new({ root = cwd, cwd = cwd })
  return session
end

local function ensure_model()
  if state.model then return state.model end
  state.model = require("neoagent.models").resolve()
  return state.model
end

local function system_prompt(value)
  local prompt = configured().system_prompt
  if type(prompt) == "function" then
    return prompt({ session = state.session, model = state.model, workspace = state.workspace, prompt = value })
  end
  return prompt
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
    on_event = options.on_event,
    on_done = options.on_done,
  })
end

local function update_context()
  if state.view then
    state.view:set_context({
      model = model_label(),
      workspace = state.workspace and state.workspace.root or nil,
      state = state.status,
    })
  end
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
    local run_id = state.run_id + 1
    state.run_id = run_id
    local selected_interaction = options.interaction or interaction
    local run = selected_interaction({
      session = state.session,
      prompt = prompt,
      model = state.model,
      system_prompt = system_prompt(prompt),
      tools = tool_array(),
      workspace = state.workspace,
      context = { workspace = state.workspace },
      execute_tool = options.execute_tool,
      max_rounds = options.max_tool_rounds,
      on_event = function(event)
        if run_id ~= state.run_id then return end
        if state.view then state.view:apply(event) end
        if event.type == "tool_end" and not event.message.isError
            and (event.call.name == "write_file" or event.call.name == "edit_file") then
          refresh_buffer(event.call.arguments.path)
        end
      end,
      on_done = function(done)
        if run_id ~= state.run_id then return end
        state.run = nil
        state.status = "idle"
        update_context()
        if state.view then state.view:finish(done) end
      end,
    })
    assert(type(run) == "table" and type(run.cancel) == "function", "interaction must return a Run")
    state.run = run
    state.status = "running"
    if state.view then
      state.view:set_messages(state.session:messages())
      state.view:set_input("")
    end
    update_context()
    return run
  end)
  if not ok then
    local err = util.normalize_error(result, "session")
    notify(err.message, vim.log.levels.ERROR)
    return nil, err
  end
  return result
end

local function ensure_view()
  if state.view and not state.view.destroyed then return state.view end
  local options = configured()
  state.view = require("neoagent.ui").new({
    config = options.ui,
    on_submit = submit,
    on_stop = M.stop,
  })
  if state.session then state.view:set_messages(state.session:messages()) end
  update_context()
  return state.view
end

function M.setup(opts)
  if state.run then error("Cannot reconfigure neoagent while a run is active") end
  if state.view then state.view:destroy() end
  state.session, state.model, state.workspace, state.view = nil, nil, nil, nil
  state.status = "idle"
  return config.setup(opts)
end

function M.open()
  local ok, opened, open_err = pcall(function()
    ensure_session()
    return ensure_view():open()
  end)
  if not ok then notify(util.normalize_error(opened, "ui").message, vim.log.levels.ERROR) return nil, opened end
  return opened, open_err
end

function M.close()
  if state.view then state.view:close() end
end

function M.toggle()
  local view = ensure_view()
  if view:is_open() then M.close() else return M.open() end
end

function M.send(text)
  return submit(text)
end

function M.stop()
  if not state.run then return false end
  state.status = "stopping"
  update_context()
  state.run:cancel()
  return true
end

function M.new_session()
  if state.run then notify("cannot create a session while the agent is running", vim.log.levels.WARN) return nil end
  local cwd = vim.fn.getcwd()
  local session, err = make_session(cwd)
  if not session then notify(err.message, vim.log.levels.ERROR) return nil, err end
  state.session = session
  state.workspace = require("neoagent.workspace").new({ root = cwd, cwd = cwd })
  if state.view then
    state.view:set_messages({})
    update_context()
  end
  return session
end

local function resume_path(path)
  local store, err = require("neoagent.storage").open(path)
  if not store then notify(err.message .. (err.detail and ": " .. err.detail or ""), vim.log.levels.ERROR) return nil, err end
  local session
  session, err = require("neoagent.session").new({ store = store })
  if not session then notify(err.message, vim.log.levels.ERROR) return nil, err end
  state.session = session
  local cwd = store:metadata().cwd
  state.workspace = require("neoagent.workspace").new({ root = cwd, cwd = cwd })
  if state.view then
    state.view:set_messages(session:messages())
    update_context()
  end
  return session
end

function M.resume(path)
  if state.run then notify("cannot resume while the agent is running", vim.log.levels.WARN) return nil end
  if path and path ~= "" then return resume_path(vim.fn.fnamemodify(path, ":p")) end
  local options = configured().persistence
  local paths = require("neoagent.storage").list(options.directory, vim.fn.getcwd())
  if #paths == 0 then notify("no sessions found for the current directory") return nil end
  vim.ui.select(paths, { prompt = "Resume Neoagent session:" }, function(choice)
    if choice then resume_path(choice) end
  end)
end

function M.set_model(provider_id, model_id)
  if state.run then notify("cannot change model while the agent is running", vim.log.levels.WARN) return nil end
  local ok, model = pcall(require("neoagent.models").resolve, provider_id, model_id)
  if not ok then notify(tostring(model), vim.log.levels.ERROR) return nil, model end
  state.model = model
  update_context()
  return model
end

function M.get_session() return state.session end
function M.get_model() return state.model end
function M._state() return state end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("NeoagentLifecycle", { clear = true }),
  callback = function() if state.run then state.run:cancel() end end,
})

return M
