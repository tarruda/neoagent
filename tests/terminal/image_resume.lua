local root = assert(vim.env.NEOAGENT_IMAGE_RESUME_ROOT)
vim.opt.runtimepath:prepend(root)
vim.opt.termguicolors = true

local ready_path = assert(vim.env.NEOAGENT_IMAGE_RESUME_READY)
local state_path = assert(vim.env.NEOAGENT_IMAGE_RESUME_STATE)
local done_path = assert(vim.env.NEOAGENT_IMAGE_RESUME_DONE)
local stop_path = assert(vim.env.NEOAGENT_IMAGE_RESUME_STOP)
local source_path = assert(vim.env.NEOAGENT_IMAGE_RESUME_SOURCE)
local persistence = assert(vim.env.NEOAGENT_IMAGE_RESUME_PERSISTENCE)
local workspace = assert(vim.env.NEOAGENT_IMAGE_RESUME_WORKSPACE)

local function publish(path, value)
  local temporary = path .. ".tmp"
  assert(vim.fn.writefile({ vim.json.encode(value) }, temporary) == 0)
  assert(vim.uv.fs_rename(temporary, path))
end

local function read_file(path)
  local descriptor = assert(vim.uv.fs_open(path, "r", 0))
  local stat = assert(vim.uv.fs_fstat(descriptor))
  local data = assert(vim.uv.fs_read(descriptor, stat.size, 0))
  assert(vim.uv.fs_close(descriptor))
  return data
end

local function assistant(content, stop_reason)
  return {
    role = "assistant",
    content = content,
    api = "fake-api",
    provider = "fake",
    model = "test",
    stopReason = stop_reason or "stop",
    timestamp = 2,
    usage = {
      input = 0,
      output = 0,
      cacheRead = 0,
      cacheWrite = 0,
      totalTokens = 0,
      cost = {
        input = 0,
        output = 0,
        cacheRead = 0,
        cacheWrite = 0,
        total = 0,
      },
    },
  }
end

local session = assert(require("neoagent.profile_sessions").new({
  profile_id = "neo",
  workspace = workspace,
  persistence = { enabled = true, directory = persistence },
}))
assert(session:append({
  role = "user",
  content = "Inspect the persisted image fixture.",
  timestamp = 1,
}, {
  model = { provider = "fake", model = "test" },
  thinking_level = "high",
}))
assert(session:append(assistant({
  { type = "thinking", thinking = "I will inspect the image." },
  {
    type = "toolCall",
    id = "read-image",
    name = "read_file",
    arguments = { path = source_path },
  },
}, "toolUse")))
assert(session:append({
  role = "toolResult",
  toolCallId = "read-image",
  toolName = "read_file",
  isError = false,
  timestamp = 3,
  content = {
    { type = "text", text = "Read image file [image/png]" },
    {
      type = "image",
      mimeType = "image/png",
      data = vim.base64.encode(read_file(source_path)),
    },
  },
}))
assert(session:append(assistant({
  {
    type = "thinking",
    thinking = table.concat({
      "The image is followed by enough persisted transcript content",
      "to place it outside the viewport when the last card is selected.",
      "This mirrors a resumed tool-result image followed by analysis.",
      "The terminal placement must follow the final transcript viewport.",
    }, "\n\n"),
  },
  {
    type = "toolCall",
    id = "inspect-image",
    name = "shell",
    arguments = { command = "identify fixture.png" },
  },
}, "toolUse")))
assert(session:append({
  role = "toolResult",
  toolCallId = "inspect-image",
  toolName = "shell",
  isError = false,
  timestamp = 4,
  content = { {
    type = "text",
    text = table.concat({
      "fixture.png PNG 640x384",
      "The diagnostic completed successfully.",
      "The persisted result has no additional image.",
      "Rendering can continue with the final response.",
    }, "\n"),
  } },
}))
assert(session:append(assistant({
  {
    type = "thinking",
    thinking = table.concat({
      "I can now summarize the fixture.",
      "The earlier image belongs above this final card.",
      "Its terminal pixels must not cover this text after navigation.",
    }, "\n\n"),
  },
  {
    type = "text",
    text = table.concat({
      "The fixture uses a deliberately distinctive palette.",
      "It has a wide landscape aspect ratio.",
      "The bright pixels make stale terminal placement measurable.",
      "This final response is the card selected from the composer.",
      "The original image is semantically higher in the transcript.",
    }, "\n\n"),
  },
})))

local model = {
  api = "fake-api",
  provider = "fake",
  id = "test",
  input = { "text", "image" },
}
function model:stream()
  error("the image resume harness must not make model requests", 0)
end

local errors = {}
local neoagent = require("neoagent")
local applet = neoagent.setup({
  workspace_trust = false,
  default_registry = false,
  default_model = { provider = "fake", model = "test" },
  providers = {
    fake = { api = "fake-api", models = { test = {
      input = { "text", "image" },
    } } },
  },
  _apis = { ["fake-api"] = function() return model end },
  persistence = {
    enabled = true,
    directory = persistence,
    workspace_settings = false,
  },
  tools = {},
  agent_instructions = false,
  skills = false,
  ui = {
    position = "center",
    style = "codex",
    show_thinking = true,
    images = { display = "always" },
  },
})
assert(applet:open())
assert(applet:is_open())

local view = assert(applet:view())
local pane = assert(view.transcript.pane)
local images = assert(view.image_system)
local backend = assert(images.backend)
local navigated = false
local action_started
local stable_since
local finishing = false
local last_state = 0

local function current_placements()
  local owner = backend.owners and backend.owners[pane]
  local result = {}
  for _, placement in ipairs(owner and owner.placements or {}) do
    result[#result + 1] = {
      key = placement.key,
      geometry = vim.deepcopy(placement.geometry),
    }
  end
  return result
end

local function snapshot(phase)
  local native = pane:native()
  local window = native and native.window
  local input = view:pane("input")
  local input_native = input and input:native()
  local presentation = view:pane("presentation-filter")
    or view:pane("presentation")
  local presentation_native = presentation and presentation:native()
  local image_key, image = next(pane.layout and pane.layout.images or {})
  local position
  if window and image then
    local line = vim.api.nvim_buf_get_lines(
      native.buffer, image.row, image.row + 1, false)[1] or ""
    position = vim.fn.screenpos(window, image.row + 1,
      require("applet.util").byte_col(line, image.col) + 1)
  end
  return {
    phase = phase,
    errors = vim.deepcopy(errors),
    mode = vim.api.nvim_get_mode().mode,
    current_window = vim.api.nvim_get_current_win(),
    transcript_window = window,
    input_window = input_native and input_native.window,
    presentation_window = presentation_native and presentation_native.window,
    image_key = image_key,
    image = image and {
      row = image.row,
      col = image.col,
      width = image.width,
      height = image.height,
    } or nil,
    image_position = position,
    placements = current_placements(),
    view = window and vim.api.nvim_win_call(window, vim.fn.winsaveview) or nil,
    cursor = window and vim.api.nvim_win_get_cursor(window) or nil,
    image_stats = images:_stats(),
    output_pending = backend.output_operation ~= nil,
    pending_presentations = backend.pending and vim.tbl_count(backend.pending) or 0,
  }
end

local function current_phase()
  if navigated then return "navigated" end
  if next(pane.layout and pane.layout.images or {}) then return "resumed" end
  if view:pane("presentation-filter") or view:pane("presentation") then
    return "selection"
  end
  return "draft"
end

local timer = vim.uv.new_timer()
local started = vim.uv.hrtime()
timer:start(5, 5, vim.schedule_wrap(function()
  if finishing then return end
  local ok, err = xpcall(function()
    if #errors > 0 then error(table.concat(errors, "\n"), 0) end
    local current_view = applet:view()
    if current_view and current_view ~= view then
      view = current_view
      pane = assert(view.transcript.pane)
      images = assert(view.image_system)
      backend = assert(images.backend)
    end
    local state = snapshot(current_phase())
    local now = vim.uv.hrtime()
    if now - last_state >= 20 * 1e6 then
      last_state = now
      publish(state_path, state)
    end
    if state.image and state.current_window == state.input_window
        and vim.fn.filereadable(ready_path) ~= 1 then
      publish(ready_path, state)
    end
    if not navigated and state.image
        and state.current_window == state.transcript_window then
      navigated = true
      action_started = now
      state.phase = "navigated"
      stable_since = nil
    end
    if navigated then
      local settled = state.current_window == state.transcript_window
        and state.image_stats.pending_preparations == 0
        and not state.output_pending
        and state.pending_presentations == 0
      if settled then
        stable_since = stable_since or now
      else
        stable_since = nil
      end
      if stable_since and now - stable_since >= 250 * 1e6
          and vim.fn.filereadable(done_path) ~= 1 then
        state.phase = "navigated"
        publish(done_path, state)
      end
    end
    if vim.fn.filereadable(stop_path) == 1 then
      finishing = true
      timer:stop()
      timer:close()
      vim.schedule(function() vim.cmd("qa!") end)
      return
    end
    if action_started and now - action_started > 10 * 1e9 then
      error("resume navigation did not settle: "
        .. vim.inspect(snapshot("timeout")), 0)
    end
    if now - started > 30 * 1e9 then
      error("image resume harness timed out: "
        .. vim.inspect(snapshot("timeout")), 0)
    end
  end, debug.traceback)
  if not ok then
    finishing = true
    pcall(publish, done_path, { phase = "error", error = err })
    timer:stop()
    timer:close()
    vim.api.nvim_err_writeln(err)
    vim.schedule(function() vim.cmd("cquit 1") end)
  end
end))
