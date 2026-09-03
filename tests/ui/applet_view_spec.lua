local config = require("neoagent.config")
local Applet = require("applet")
local applet_input = require("applet.pane.input")
local renderers = require("neoagent.ui.renderers")
local neoagent_ui = require("neoagent.ui")
local Details = require("neoagent.ui.panes.details")
local Dialog = require("neoagent.ui.panes.dialog")
local Input = require("neoagent.ui.panes.input")
local view_handles = require("tests.helpers.view_handles")
local Provider = require("neoagent.ui.panes.provider")
local Providers = require("neoagent.ui.panes.providers")
local Transcript = require("neoagent.ui.panes.transcript")

local function uint32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256)
end

local function png(width, height)
  return "\137PNG\r\n\26\n\0\0\0\rIHDR"
    .. uint32(width) .. uint32(height)
end

local function image_backend(overrides)
  local value = {
    name = "test",
    available = true,
    cell_dimensions = function() return { width = 1, height = 1 } end,
    replace = function() end,
    clear = function() end,
    release = function() end,
    redraw = function() return false end,
    destroy = function() end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function lines(buffer)
  return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
end

local function contains(buffer, value)
  for _, line in ipairs(lines(buffer)) do
    if line:find(value, 1, true) then return true end
  end
  return false
end

local function chrome_text(value)
  local result = {}
  for _, chunk in ipairs(value or {}) do
    result[#result + 1] = chunk[1]
  end
  return table.concat(result)
end

local function line_index(buffer, value)
  for index, line in ipairs(lines(buffer)) do
    if line:find(value, 1, true) then return index, line end
  end
end

local function highlight_groups(buffer, namespace, row, start_col, end_col)
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    buffer, namespace, { row, start_col }, { row, end_col }, { details = true }
  )) do
    local details = mark[4]
    if mark[2] == row and mark[3] == start_col
        and details.end_row == row and details.end_col == end_col
        and details.hl_group then
      result[details.hl_group] = true
    end
  end
  return result
end

local function persistent_highlight_counts(buffer, namespace)
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    buffer, namespace, 0, -1, { details = true }
  )) do
    local group = mark[4].hl_group or mark[4].line_hl_group
    if group then result[group] = (result[group] or 0) + 1 end
  end
  return result
end

describe("neoagent Applet View composition", function()
  local views = {}
  local components = {}
  local base64_decode

  before_each(function()
    config._reset()
    base64_decode = vim.base64.decode
    vim.o.columns = 120
    vim.o.lines = 40
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  end)

  after_each(function()
    vim.base64.decode = base64_decode
    for _, view in ipairs(views) do view:destroy() end
    for _, component in ipairs(components) do component:destroy() end
    views = {}
    components = {}
    vim.cmd("silent! only")
    vim.cmd("stopinsert")
  end)

  local function view(opts)
    local resolved = config.setup({
      ui = vim.tbl_extend("force", {
        style = "pi",
        position = "center",
      }, opts or {}),
    }).ui
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
    })
    views[#views + 1] = value
    return value
  end

  it("retains input text and state before its Pane is connected", function()
    local input = Input.new({
      config = {},
      callbacks = {
        close = function() end,
        history = function() return {} end,
        submit = function() end,
      },
    })
    components[#components + 1] = input

    local cursor = { line = 1, column = 3 }
    assert(input:set_text("draft", cursor))
    assert.are.equal("draft", input:text())
    assert.are.same(cursor, input.pending_cursor)

    input:set_state({
      config = { mappings = { submit = "<C-g>" } },
      completion = false,
      virtual_lines = {},
    })
    assert.are.equal("<C-g>", input:mapping_bindings()[1].lhs)

    local dialog = Dialog.new({
      editable = true,
      callbacks = {
        cancel = function() end,
        choose = function() end,
      },
    })
    components[#components + 1] = dialog
    assert(dialog:set_text("prepared dialog input", cursor))
    assert.are.equal("prepared dialog input", dialog.input_value)
  end)

  it("updates retained Provider component configuration and themes", function()
    local provider = Provider.new({
      config = { mappings = {} },
      callbacks = {},
      theme = renderers.pi.theme,
    })
    components[#components + 1] = provider
    provider:set_config(nil)
    assert.are.same({}, provider.config)
    assert.are.equal(provider.config, provider.state.config)
    provider:set_theme(renderers.codex.theme)
    assert.are.equal(renderers.codex.theme, provider.theme)
    assert.are.equal(renderers.codex.theme, provider.pane.theme)

    local providers = Providers.new({
      config = { mappings = {} },
      callbacks = {},
      theme = renderers.pi.theme,
    })
    components[#components + 1] = providers
    providers:set_theme(renderers.codex.theme)
    assert.are.equal(renderers.codex.theme, providers.theme)
    assert.are.equal(renderers.codex.theme, providers.pane.theme)
  end)

  it("connects transcript and editable input Panes to retained buffers", function()
    local value = view()
    value:set_input("draft")
    value:set_messages({
      { role = "user", content = "question" },
      { role = "assistant", content = { { type = "text", text = "answer" } } },
    })
    assert(value:open())
    assert(vim.wait(1000, function()
      return value.transcript.pane.layout ~= nil
        and value.input.pane.layout ~= nil
    end))

    assert.is_false(value.transcript.pane:is_editable())
    assert.is_true(value.input.pane:is_editable())
    assert.is_false(vim.bo[view_handles.buffer(value, "transcript")].modifiable)
    assert.is_true(vim.bo[view_handles.buffer(value, "input")].modifiable)
    assert.is_true(contains(view_handles.buffer(value, "transcript"), "question"))
    assert.is_true(contains(view_handles.buffer(value, "transcript"), "answer"))
    assert.are.equal("draft", value:get_input())
    assert.is_nil(rawget(value, "domain"))
    assert.is_nil(rawget(value, "namespace"))
    assert.is_nil(rawget(value, "card_namespace"))
    assert.are.equal(value.transcript.pane.domain, value.input.pane.domain)

    local input_generations = value.input.pane:_stats().requested_generations
    value:focus_input()
    value:focus_input()
    assert.are.equal(input_generations,
      value.input.pane:_stats().requested_generations)

    value:close()
    assert.are.equal("draft", value:get_input())
    assert(value:open())
    assert(vim.wait(1000, function()
      return value.transcript.pane.layout ~= nil
    end))
    assert.are.equal("draft", value:get_input())
  end)

  it("owns the configured image system for the transcript lifecycle", function()
    local image_options
    local image_new = Applet.ImageSystem.new
    Applet.ImageSystem.new = function(options)
      image_options = vim.deepcopy(options)
      return image_new(options)
    end
    local ok, value = pcall(view)
    Applet.ImageSystem.new = image_new
    assert(ok, value)
    assert.are.same({ backend = "kitty" }, image_options)
    local images = value.image_system

    assert.is_table(images)
    assert.are.equal("unavailable", images.status)
    assert.are.equal(images, value.transcript.image_system)
    assert.are.equal(images, value.transcript.pane.image_system)

    value:destroy()
    assert.is_true(images.destroyed)

    local disabled = view({ images = false })
    assert.is_nil(disabled.image_system)

    local resolved = config.setup({ ui = { style = "pi" } }).ui
    local explicitly_disabled = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      image_system = false,
    })
    views[#views + 1] = explicitly_disabled
    assert.is_nil(explicitly_disabled.image_system)

    local external = Applet.ImageSystem._new({
      _backend = image_backend({
        available = false,
      }),
    })
    local injected = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      image_system = external,
    })
    views[#views + 1] = injected
    injected:destroy()
    assert.is_false(external.destroyed)
    external:destroy()
  end)

  it("prepares and places transcript PNGs through the configured backend", function()
    local placements = {}
    local images = Applet.ImageSystem._new({
      _backend = image_backend({
        replace = function(_, _, presented)
          for _, image in ipairs(presented) do
            placements[#placements + 1] = image
          end
        end,
      }),
    })
    local resolved = config.setup({ ui = { style = "pi" } }).ui
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      image_system = images,
    })
    views[#views + 1] = value
    value:set_messages({ {
      role = "toolResult",
      toolCallId = "read-image",
      toolName = "read_file",
      isError = false,
      content = { {
        type = "image",
        mimeType = "image/png",
        data = vim.base64.encode(png(4, 3)),
      } },
    } })
    assert(value:open())
    assert(vim.wait(1000, function() return #placements > 0 end))
    assert.are.equal(4, placements[#placements].resource.width)
    assert.are.equal(3, placements[#placements].resource.height)
    assert.are.equal(12, placements[#placements].height)
    assert.is_true(contains(view_handles.buffer(value, "transcript"), "Image · PNG"))
    value:destroy()
    images:destroy()
  end)

  it("animates transient tool images across transcript and details", function()
    local batches = {}
    local images = Applet.ImageSystem._new({
      _backend = image_backend({
        replace = function(_, owner, placements)
          batches[#batches + 1] = {
            owner = owner,
            identities = vim.tbl_map(function(image)
              return image.resource.id
            end, placements),
          }
        end,
      }),
    })
    local resolved = config.setup({ ui = { style = "pi" } }).ui
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      image_system = images,
    })
    views[#views + 1] = value

    local function frame(width, revision)
      return {
        type = "image",
        mimeType = "image/png",
        data = vim.base64.encode(png(width, width)),
        id = "preview",
        revision = revision,
      }
    end

    local function source_id(pane, width)
      local resources = images:snapshot(pane).resources
      for _, image in pairs(pane.layout and pane.layout.images or {}) do
        local resource = resources[image.source_identity]
        if resource and resource.width == width then
          return image.source_identity
        end
      end
    end

    value:apply({ type = "tool_start", call = {
      id = "animated", name = "animate", arguments = {},
    } })
    value:apply({
      type = "tool_update",
      call = { id = "animated", name = "animate" },
      result = { content = { frame(12, 1) } },
    })
    assert(value:open())
    assert(vim.wait(1000, function()
      return images:_stats().preparations == 1
        and source_id(value.transcript.pane, 12) ~= nil
    end))
    local first = source_id(value.transcript.pane, 12)

    assert(value:show_card_details("tool:animated"))
    assert(vim.wait(1000, function()
      return value.details and source_id(value.details.pane, 12) == first
    end))
    assert.are.equal(1, images:_stats().preparations)
    assert.are.equal(1, images:_stats().prepared_resources)

    value:apply({
      type = "tool_update",
      call = { id = "animated", name = "animate" },
      result = { content = { frame(18, 2) } },
    })
    assert(vim.wait(1000, function()
      local transcript = source_id(value.transcript.pane, 18)
      local details = value.details and source_id(value.details.pane, 18)
      return images:_stats().preparations == 2 and transcript ~= nil
        and details == transcript and transcript ~= first
    end))

    assert(value.transcript.pane:flush())
    assert(value.details.pane:flush())
    local batch_count = #batches
    value:apply({
      type = "tool_end",
      call = { id = "animated", name = "animate", arguments = {} },
      message = {
        role = "toolResult",
        toolCallId = "animated",
        toolName = "animate",
        isError = false,
        content = { frame(18, 2) },
      },
    })
    assert(value.transcript.pane:flush())
    assert(value.details.pane:flush())
    assert.are.equal(2, images:_stats().preparations)
    assert.are.equal(batch_count, #batches)
    assert.is_nil(value.transcript:block("tool:animated").update)

    value:apply({ type = "tool_start", call = {
      id = "removed", name = "animate", arguments = {},
    } })
    value:apply({
      type = "tool_update",
      call = { id = "removed", name = "animate" },
      result = { content = { frame(15, 1) } },
    })
    assert(vim.wait(1000, function()
      return images:_stats().preparations == 3
        and source_id(value.transcript.pane, 15) ~= nil
    end))
    assert(value:show_card_details("tool:removed"))
    assert(vim.wait(1000, function()
      return value.details and source_id(value.details.pane, 15) ~= nil
    end))
    batch_count = #batches

    value:apply({
      type = "tool_end",
      call = { id = "removed", name = "animate", arguments = {} },
      message = {
        role = "toolResult",
        toolCallId = "removed",
        toolName = "animate",
        isError = false,
        content = { { type = "text", text = "complete" } },
      },
    })
    assert(vim.wait(1000, function()
      return value.details and value.details.pane.layout
        and next(value.details.pane.layout.images) == nil
        and source_id(value.transcript.pane, 15) == nil
    end))
    assert.is_true(#batches >= batch_count + 2)
    assert.is_nil(value.transcript:block("tool:removed").update)
    images:destroy()
  end)

  it("retains stable image placements while clipped thinking streams", function()
    local decodes = 0
    vim.base64.decode = function(value)
      decodes = decodes + 1
      return base64_decode(value)
    end
    local batches = {}
    local images = Applet.ImageSystem._new({
      _backend = image_backend({
        replace = function(_, _, placements)
          batches[#batches + 1] = vim.deepcopy(placements)
        end,
      }),
    })
    local resolved = config.setup({
      ui = { style = "codex", images = { display = "always" } },
    }).ui
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      image_system = images,
    })
    views[#views + 1] = value
    value:set_messages({ {
      role = "toolResult",
      toolCallId = "screenshot",
      toolName = "read_file",
      isError = false,
      content = { {
        type = "image",
        mimeType = "image/png",
        data = vim.base64.encode(png(640, 400)),
      } },
    } })
    value:set_context({ state = "running" })
    local lines = {}
    for index = 1, 11 do lines[index] = "thinking line " .. index end
    value:apply({
      type = "thinking_delta",
      index = 0,
      text = table.concat(lines, "\n"),
    })
    assert(value:open())
    assert(vim.wait(1000, function()
      return #batches > 0 and #batches[#batches] > 0
        and contains(view_handles.buffer(value, "transcript"), "thinking line 11")
    end))
    value.transcript.pane:flush()

    local batch_count = #batches
    local decode_count = decodes
    local image_layout = vim.deepcopy(value.transcript.pane.layout.images)
    value:apply({
      type = "thinking_delta",
      index = 0,
      text = "\nthinking line 12",
    })
    assert(value.transcript.pane:flush())
    assert.is_true(contains(view_handles.buffer(value, "transcript"), "thinking line 12"))
    assert.are.same(image_layout, value.transcript.pane.layout.images)
    assert.are.equal(batch_count, #batches)
    assert.are.equal(decode_count, decodes)

    local row, line = line_index(view_handles.buffer(value, "transcript"), "thinking line 12")
    row = row - 1
    local start = assert(line:find("thinking line 12", 1, true)) - 1
    local groups = highlight_groups(view_handles.buffer(value, "transcript"),
      value.transcript.pane.namespace, row, start, start + #"thinking line 12")
    assert.is_true(groups.NeoagentThinking)
    assert.is_true(groups.NeoagentMarkdownItalic)
    images:destroy()
  end)

  it("places selected tool card chrome below an inline image", function()
    local images = Applet.ImageSystem._new({
      _backend = image_backend(),
    })
    local resolved = config.setup({
      ui = { style = "codex", images = { display = "always" } },
    }).ui
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      image_system = images,
    })
    views[#views + 1] = value
    value:set_messages({ {
      role = "assistant",
      content = { {
        type = "toolCall",
        id = "screenshot",
        name = "read_file",
        arguments = { path = "/tmp/shot.png" },
      } },
    }, {
      role = "toolResult",
      toolCallId = "screenshot",
      toolName = "read_file",
      isError = false,
      content = { {
        type = "image",
        mimeType = "image/png",
        data = vim.base64.encode(png(640, 400)),
      } },
    }, {
      role = "assistant",
      content = { { type = "text", text = "after screenshot" } },
    } })
    assert(value:open())
    assert(vim.wait(1000, function()
      return value.transcript.pane.layout
        and next(value.transcript.pane.layout.images) ~= nil
        and contains(view_handles.buffer(value, "transcript"), "after screenshot")
    end))
    value.transcript.pane:flush()
    value:focus_transcript()

    local transcript_buffer = view_handles.buffer(value, "transcript")
    local image_key = assert(next(value.transcript.pane.layout.images))
    local image = value.transcript.pane.layout.images[image_key]
    local separator_row = assert(line_index(
      transcript_buffer, "────────────────")) - 1
    assert.are.equal(image.row + image.height, separator_row)

    local header_row = assert(line_index(transcript_buffer, "/tmp/shot.png"))
    vim.api.nvim_win_set_cursor(
      view_handles.window(value, "transcript"), { header_row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = view_handles.buffer(value, "transcript"),
    })

    local bottom_row
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      view_handles.buffer(value, "transcript"),
      value.transcript.pane.focus_namespace, 0, -1, { details = true }
    )) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1]:find("╰", 1, true) then bottom_row = mark[2] end
      end
    end
    assert.are.equal(separator_row, bottom_row)
    images:destroy()
  end)

  it("prepares replacement-conversation images with independent identities", function()
    local images = Applet.ImageSystem._new({
      _backend = image_backend(),
    })
    local resolved = config.setup({ ui = { style = "pi" } }).ui
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      image_system = images,
    })
    views[#views + 1] = value
    local function messages(width, height)
      return { {
        role = "user",
        content = { {
          type = "image",
          mimeType = "image/png",
          data = vim.base64.encode(png(width, height)),
        } },
      } }
    end

    value:set_messages(messages(1, 1))
    assert(value:open())
    assert(vim.wait(1000, function()
      return images:_stats().prepared_resources == 1
    end))

    value:set_messages(messages(2, 2))
    assert.is_true(value.transcript.pane:flush())
    assert(vim.wait(1000, function()
      local stats = images:_stats()
      return stats.preparations == 2
        and stats.prepared_resources == 1 and stats.releases == 1
    end))
    local prepared = {}
    for _, resource in pairs(images:snapshot().resources) do
      prepared[#prepared + 1] = { resource.width, resource.height }
    end
    table.sort(prepared, function(left, right) return left[1] < right[1] end)
    assert.are.same({ { 2, 2 } }, prepared)
    images:destroy()
  end)

  it("can defer transcript images until their card details are open", function()
    local placements = {}
    local images = Applet.ImageSystem._new({
      _backend = image_backend({
        replace = function(_, _, presented)
          for _, image in ipairs(presented) do
            placements[#placements + 1] = image
          end
        end,
      }),
    })
    local resolved = config.setup({
      ui = { style = "pi", images = { display = "expanded" } },
    }).ui
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      image_system = images,
    })
    views[#views + 1] = value
    value:set_messages({ {
      role = "toolResult",
      toolCallId = "expanded-image",
      toolName = "read_file",
      isError = false,
      content = { {
        type = "image",
        mimeType = "image/png",
        data = vim.base64.encode(png(6, 5)),
      } },
    } })
    assert(value:open())
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "Image · PNG · 6×5")
    end))
    assert.is_false(vim.wait(100, function() return #placements > 0 end))

    assert(value:show_card_details(value.blocks[#value.blocks].key))
    assert(vim.wait(1000, function() return #placements > 0 end))
    assert.are.equal(6, placements[#placements].resource.width)
    assert.are.equal(5, placements[#placements].resource.height)
    local detail_image = assert(next(value.details.pane.layout.images))
    assert.are.equal(6, value.details.pane.layout.images[detail_image].width)
    assert.are.equal(5, value.details.pane.layout.images[detail_image].height)
    images:destroy()
  end)

  it("opens, idles, and closes card details through real mappings", function()
    local value = view()
    value:set_messages({
      { role = "assistant", content = {
        { type = "text", text = "expand this response" },
      } },
    })
    assert(value:open())
    assert(vim.wait(1000, function()
      return line_index(view_handles.buffer(value, "transcript"), "expand this response") ~= nil
    end))
    value:focus_transcript()
    local row = assert(line_index(view_handles.buffer(value, "transcript"), "expand this response"))
    vim.api.nvim_win_set_cursor(view_handles.window(value, "transcript"), { row, 0 })

    local resize_events = 0
    local group = vim.api.nvim_create_augroup(
      "NeoagentDetailsInteractionRegression", { clear = true })
    vim.api.nvim_create_autocmd("WinResized", {
      group = group,
      callback = function() resize_events = resize_events + 1 end,
    })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
      "<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return view_handles.window(value, "details") and vim.api.nvim_win_is_valid(view_handles.window(value, "details"))
    end))
    assert.are.equal(view_handles.window(value, "details"), vim.api.nvim_get_current_win())

    local responsive = false
    vim.defer_fn(function() responsive = true end, 50)
    assert(vim.wait(500, function() return responsive end))
    assert.is_true(resize_events < 10)

    vim.api.nvim_feedkeys("q", "x", false)
    assert(vim.wait(1000, function()
      return view_handles.window(value, "details") == nil
        and vim.api.nvim_get_current_win() == view_handles.window(value, "transcript")
    end))
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("coalesces independently delivered thinking details into frames", function()
    local value = view()
    local initial = {}
    for index = 1, 100 do initial[index] = "seed " .. index end
    value:set_context({ state = "running" })
    value:apply({
      type = "thinking_delta",
      index = 0,
      text = table.concat(initial, "\n"),
    })
    assert(value:open())
    assert(vim.wait(1000, function()
      return line_index(
        view_handles.buffer(value, "transcript"), "seed 100") ~= nil
    end))
    value:focus_transcript()
    local row = assert(line_index(
      view_handles.buffer(value, "transcript"), "seed 100"))
    vim.api.nvim_win_set_cursor(view_handles.window(value, "transcript"), { row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(
      "<CR>", true, false, true), "x", false)
    assert(vim.wait(1000, function()
      return value.details and value.details.pane.layout ~= nil
    end))

    local details = value.details
    local before = details.pane:_stats()
    local started = vim.uv.hrtime()
    for index = 1, 24 do
      value:apply({
        type = "thinking_delta",
        index = 0,
        text = "\nlive trace " .. index,
      })
      vim.wait(4, function() return false end, 1)
    end
    assert(vim.wait(3000, function()
      return details:text():find("live trace 24", 1, true) ~= nil
    end))

    local after = details.pane:_stats()
    local frame_interval_ns = 50 * 1000000
    local maximum_frames = math.ceil(
      (vim.uv.hrtime() - started) / frame_interval_ns
    ) + 2
    local renders = after.renders - before.renders
    local commits = after.commits - before.commits
    local extmark_writes = after.extmark_writes - before.extmark_writes
    assert.is_true(commits <= maximum_frames, string.format(
      "details committed %d frames while rendering %d times; expected at most %d commits",
      commits, renders, maximum_frames))
    assert.is_true(extmark_writes <= 24 * 2 + maximum_frames, string.format(
      "details wrote %d extmarks across %d commits; expected only appended highlights",
      extmark_writes, commits))

    local responsive = false
    vim.defer_fn(function() responsive = true end, 20)
    assert(vim.wait(500, function() return responsive end))
    vim.api.nvim_feedkeys("q", "x", false)
    assert(vim.wait(1000, function()
      return view_handles.window(value, "details") == nil
        and vim.api.nvim_get_current_win() == view_handles.window(value, "transcript")
    end))
  end)

  it("reuses stable regions in a growing expanded Markdown block", function()
    local value = view()
    local initial = {}
    for index = 1, 160 do
      initial[index] = string.format(
        "reasoning line %03d with **stable emphasis**", index)
    end
    value:set_context({ state = "running" })
    value:apply({
      type = "thinking_delta",
      index = 0,
      text = table.concat(initial, "\n"),
    })
    assert(value:open())
    local block = assert(value.transcript.blocks[1])
    assert(value:show_card_details(block.key))
    assert(vim.wait(1000, function()
      return value.details and value.details.pane.layout
        and value.details:text():find("reasoning line 160", 1, true) ~= nil
    end))

    local details = value.details
    local details_buffer = view_handles.buffer(value, "details")
    local first_line = lines(details_buffer)[1]
    local emphasis_first, emphasis_last = assert(
      first_line:find("stable emphasis", 1, true))
    local initial_groups = highlight_groups(details_buffer,
      details.pane.namespace, 0, emphasis_first - 1, emphasis_last)
    assert.is_true(initial_groups.NeoagentMarkdownBold)
    assert.is_true(highlight_groups(details_buffer,
      details.pane.namespace, 0, 0, #first_line).NeoagentThinking)
    local before = details.pane:_stats()
    value:apply({
      type = "thinking_delta",
      index = 0,
      text = " continues",
    })
    assert(details.pane:flush())
    local after = details.pane:_stats()

    assert.is_true(#details.pane.layout.regions >= 3)
    assert.are.equal(before.document_reuses + 1, after.document_reuses)
    assert.are.equal(before.region_compilations + 1,
      after.region_compilations)
    assert.is_true(details:text():find(
      "reasoning line 160 with stable emphasis continues", 1, true) ~= nil)
    local retained_groups = highlight_groups(details_buffer,
      details.pane.namespace, 0, emphasis_first - 1, emphasis_last)
    assert.is_true(retained_groups.NeoagentMarkdownBold)
    assert.is_true(highlight_groups(details_buffer,
      details.pane.namespace, 0, 0, #first_line).NeoagentThinking)
  end)

  it("coalesces spinner frames while the interaction domain is unsafe", function()
    local value = view()
    value:set_messages({ { role = "assistant", content = {
      { type = "text", text = "keep this transcript stable" },
    } } })
    assert(value:open())
    assert(vim.wait(1000, function()
      return line_index(view_handles.buffer(value, "transcript"), "keep this transcript stable") ~= nil
    end))
    value:focus_transcript()
    vim.api.nvim_feedkeys("v", "x", false)
    assert.are.equal("v", vim.api.nvim_get_mode().mode)

    value:set_context({ state = "running" })
    local requested = value.transcript.pane:_stats().requested_generations
    vim.wait(300, function() return false end, 10)
    assert.are.equal(requested,
      value.transcript.pane:_stats().requested_generations)

    vim.api.nvim_feedkeys("v", "x", false)
    assert.are.equal("n", vim.api.nvim_get_mode().mode)
    assert.is_true(value.transcript.pane:flush())
    assert.are.equal(value.transcript.pane.generation,
      value.transcript.pane.committed_generation)
  end)

  it("returns Renderer continuations to transcript and details updates", function()
    local continued = { transcript = false, details = false }
    local renderer = {
      name = "retained-renderer",
      theme = renderers.pi.theme,
      render_block = function(_, block, env, continuation)
        if block.kind == "assistant" and continuation then
          continued.transcript = true
        end
        return renderers.pi:render_block(block, env, continuation)
      end,
      render_details = function(_, block, env, continuation)
        if block.kind == "assistant" and continuation then
          continued.details = true
        end
        return renderers.pi:render_details(block, env, continuation)
      end,
    }
    local value = view({ renderer = renderer })
    assert(value:open())
    value:apply({ type = "text_delta", text = "streamed prefix" })
    assert.is_true(value.transcript.pane:flush())
    local block = assert(value.transcript.live_text)
    assert.is_true(value:show_card_details(block.key))

    value:apply({ type = "text_delta", text = " and suffix" })
    assert.is_true(value.transcript.pane:flush())
    assert.is_true(value.details.pane:flush())
    assert.is_true(continued.transcript)
    assert.is_true(continued.details)
  end)

  it("renders only changed regions during long-transcript streaming", function()
    local calls = 0
    local renderer = {
      name = "render-count",
      theme = renderers.pi.theme,
      render_block = function(_, block, env)
        calls = calls + 1
        return renderers.pi:render_block(block, env)
      end,
      render_details = function(_, block, env)
        return renderers.pi:render_details(block, env)
      end,
    }
    local value = view({ renderer = renderer })
    local messages = {}
    for index = 1, 200 do
      messages[index] = { role = "user", content = "history " .. index }
    end
    value:set_messages(messages)
    assert(value:open())
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "history 200")
    end))

    local stable_snapshot = value.transcript.pane.pending_state.blocks[1]
    calls = 0
    local before = value.transcript.pane:_stats()
    for index = 1, 50 do
      value:apply({ type = "text_delta", index = 0,
        text = " streamed " .. index })
    end
    assert.is_true(value.transcript.pane:flush())
    assert.is_true(contains(view_handles.buffer(value, "transcript"), "streamed 50"))
    local after = value.transcript.pane:_stats()
    assert.is_true(after.renders <= before.renders + 2)
    assert.is_true(after.region_compilations <= before.region_compilations + 3)
    assert.is_true(after.region_reuses <= before.region_reuses + 3)
    assert.are.equal(before.document_reuses + 1, after.document_reuses)
    assert.is_true(after.line_splices <= before.line_splices + 2)
    assert.is_true(calls <= 3)
    assert.is_true(rawequal(stable_snapshot,
      value.transcript.pane.pending_state.blocks[1]))
  end)

  it("coalesces independently delivered stream deltas into presentation frames", function()
    local value = view()
    value:set_messages({ {
      role = "user",
      content = "stream a response",
    } })
    assert(value:open())
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"),
        "stream a response")
    end))

    local before = value.transcript.pane:_stats()
    local started = vim.uv.hrtime()
    for index = 1, 24 do
      value:apply({
        type = "text_delta",
        index = 0,
        text = " part-" .. index,
      })
      vim.wait(4, function() return false end, 1)
    end
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "part-24")
    end))

    local after = value.transcript.pane:_stats()
    local frame_interval_ns = 50 * 1000000
    local maximum_frames = math.ceil(
      (vim.uv.hrtime() - started) / frame_interval_ns
    ) + 2
    assert.is_true(after.renders - before.renders <= maximum_frames)
    assert.is_true(after.commits - before.commits <= maximum_frames)
  end)

  it("appends a submitted message without rebuilding a long transcript", function()
    local calls = 0
    local renderer = {
      name = "append-count",
      theme = renderers.pi.theme,
      render_block = function(_, block, env)
        calls = calls + 1
        return renderers.pi:render_block(block, env)
      end,
      render_details = function(_, block, env)
        return renderers.pi:render_details(block, env)
      end,
    }
    local value = view({ renderer = renderer })
    local messages = {}
    for index = 1, 200 do
      messages[index] = {
        role = index % 2 == 0 and "assistant" or "user",
        content = index % 2 == 0
            and { { type = "text", text = "answer " .. index } }
          or "question " .. index,
        _neoagent_entry_id = "entry-" .. index,
      }
    end
    value:set_messages(messages)
    assert(value:open())
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "answer 200")
    end))

    local stable_snapshot = value.transcript.pane.pending_state.blocks[1]
    calls = 0
    messages[#messages + 1] = {
      role = "user",
      content = "new prompt",
      _neoagent_entry_id = "entry-201",
    }
    value:set_messages(messages)
    assert.is_true(value.transcript.pane:flush())

    assert.is_true(contains(view_handles.buffer(value, "transcript"), "new prompt"))
    assert.is_true(calls <= 3)
    assert.is_true(rawequal(stable_snapshot,
      value.transcript.pane.pending_state.blocks[1]))
  end)

  it("coalesces resize bursts before reflowing a long transcript", function()
    local calls = 0
    local renderer = {
      name = "resize-count",
      theme = renderers.pi.theme,
      render_block = function(_, block, env)
        calls = calls + 1
        return renderers.pi:render_block(block, env)
      end,
      render_details = function(_, block, env)
        return renderers.pi:render_details(block, env)
      end,
    }
    local value = view({ renderer = renderer })
    local messages = {}
    for index = 1, 200 do
      messages[index] = { role = "user", content = "history " .. index }
    end
    value:set_messages(messages)
    assert(value:open())
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "history 200")
    end))

    calls = 0
    for index, columns in ipairs({ 116, 112, 108, 104 }) do
      vim.defer_fn(function()
        vim.o.columns = columns
        vim.api.nvim_exec_autocmds("VimResized", {})
      end, index * 5)
    end
    assert(vim.wait(5000, function()
      return value.transcript.pane.committed_generation
        == value.transcript.pane.generation
        and value.transcript.pane.last_width
          == vim.api.nvim_win_get_width(view_handles.window(value, "transcript"))
    end))

    assert.is_true(calls <= 250)
  end)

  it("updates long-transcript chrome without recomposing document regions", function()
    local value = view()
    local messages = {}
    for index = 1, 200 do
      messages[index] = { role = "user", content = "history " .. index }
    end
    value:set_messages(messages)
    value:set_context({ state = "running" })
    assert(value:open())
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "history 200")
    end))

    local before = value.transcript.pane:_stats()
    value.transcript:set_spinner("*")
    assert.is_true(value.transcript.pane:flush())
    local after = value.transcript.pane:_stats()
    local transcript = vim.api.nvim_win_get_config(view_handles.window(value, "transcript"))

    assert.matches("%* Working%.%.%.", chrome_text(transcript.footer))
    assert.are.equal(before.region_compilations, after.region_compilations)
    assert.are.equal(before.region_reuses, after.region_reuses)
  end)

  it("preserves centered labels and the complete transcript border", function()
    local value = view({ border = "double" })
    value:set_context({ name = "Agent", model = "fake/model", state = "idle" })
    assert(value:open())
    assert(vim.wait(1000, function()
      return value.transcript.pane.layout ~= nil
        and value.input.pane.layout ~= nil
    end))

    local transcript = vim.api.nvim_win_get_config(view_handles.window(value, "transcript"))
    local input = vim.api.nvim_win_get_config(view_handles.window(value, "input"))
    assert.are.equal("center", transcript.title_pos)
    assert.are.equal("left", transcript.footer_pos)
    assert.are.equal("center", input.footer_pos)

    local width = vim.api.nvim_win_get_width(view_handles.window(value, "transcript"))
    local before = math.floor((width - vim.fn.strdisplaywidth(" Idle ")) / 2)
    local idle = string.rep("═", before) .. " Idle "
      .. string.rep("═", width - before - vim.fn.strdisplaywidth(" Idle "))
    assert.are.equal(idle, chrome_text(transcript.footer))

    value:set_context({
      name = "Agent",
      model = "fake/model",
      state = "running",
      context_usage = { used = 1500, total = 2000000, percent = 0.05 },
    })
    value.transcript:set_spinner("*")
    value.transcript.pane:flush()
    transcript = vim.api.nvim_win_get_config(view_handles.window(value, "transcript"))
    local working = chrome_text(transcript.footer)
    assert.are.equal(width, vim.fn.strdisplaywidth(working))
    assert.matches("Working%.%.%.", working)
    assert.matches("ctx 1%.5k/2m %(<0%.1%%%)", working)
  end)

  it("preserves response focus outlines and bottom expansion hints", function()
    local value = view()
    value:set_messages({ { role = "assistant", content = {
      { type = "text", text = "two words" },
    } } })
    assert(value:open())
    assert(vim.wait(1000, function()
      return value.transcript.pane.layout ~= nil
        and value.transcript.pane.layout.targets[
          "card:message:1:text:1"] ~= nil
    end))
    local target = value.transcript.pane.layout.targets[
      "card:message:1:text:1"]
    local rectangle = target.rectangles[1]
    vim.api.nvim_set_current_win(view_handles.window(value, "transcript"))
    vim.api.nvim_win_set_cursor(view_handles.window(value, "transcript"), {
      rectangle.row + 1, rectangle.col,
    })
    value.transcript.pane:_draw_focus()

    local decorations = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        view_handles.buffer(value, "transcript"), value.transcript.pane.focus_namespace, 0, -1,
        { details = true })) do
      local chunks = mark[4].virt_text
      if chunks then
        decorations[#decorations + 1] = table.concat(
          vim.tbl_map(function(chunk) return chunk[1] end, chunks))
      end
    end
    local text = table.concat(decorations)
    assert.matches("╭", text)
    assert.matches("<CR> to expand", text)
    assert.is_nil(text:find("word", 1, true))
  end)

  it("uses Tree dialog actions for inline and editable floating dialogs", function()
    local chosen = {}
    local value = view()
    value.callbacks.on_dialog_action = function(id, action, input)
      chosen = { id, action, input }
      return true
    end
    value:set_messages({ { role = "assistant", content = {
      { type = "text", text = "before dialog" },
    } } })
    assert(value:open())

    local inline = {
      active = {
        id = "inline",
        placement = "transcript",
        title = "Inline question",
        body = "Continue?",
        actions = { { id = "yes", key = "y", label = "Yes" } },
      },
      queue_count = 0,
    }
    value:set_dialog(inline)
    value.transcript.pane:flush()
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "Continue?")
    end))
    local action = value.transcript.pane.layout.targets[
      "dialog:inline:widget:actions:item:yes"].action
    assert.is_true(applet_input.dispatch_action(value.transcript.pane,
      action, value.transcript.pane.layout.targets[
        "dialog:inline:widget:actions:item:yes"], 1, "n", 0, 0))
    assert.are.same({ "inline", "yes", nil }, chosen)

    inline.active.body = "Changed inline question"
    value:set_dialog(inline)
    value.transcript.pane:flush()
    assert.is_true(contains(view_handles.buffer(value, "transcript"), "Changed inline question"))

    value:set_dialog({
      active = {
        id = "input",
        placement = "float",
        title = "Input question",
        body = "Tell me",
        input = { label = "Answer", value = "old", multiline = false },
        actions = { { id = "send", key = "s", label = "Send" } },
      },
      queue_count = 1,
    })
    assert(vim.wait(1000, function()
      return value.dialog_component and value.dialog_component.pane.layout ~= nil
    end))
    value.dialog_component:set({
      active = {
        id = "input",
        placement = "float",
        title = "Input question",
        body = "Tell me",
        input = { label = "Answer", value = "reset", multiline = false },
        actions = { { id = "send", key = "s", label = "Send" } },
      },
      queue_count = 1,
    })
    assert.are.equal("reset", value.dialog_component:text())
    assert(value.dialog_component.pane:replace_text("new"))
    assert.is_true(applet_input.dispatch_action(value.dialog_component.pane,
      Applet.Pane.nodes.action("dialog.changed"), nil, 1, "i", 0, 0))
    assert.are.equal("new", value.dialog_component.input_value)
    local dialog_target = value.dialog_component.pane.layout.targets
    assert.is_table(dialog_target)
    assert.is_true(applet_input.dispatch(value.dialog_component.pane, "i", "s"))
    assert.are.same({ "input", "send", "new" }, chosen)

    local dismissed = {}
    value.callbacks.on_dialog_dismiss = function(id)
      dismissed[#dismissed + 1] = id
    end
    value:set_dialog({
      active = {
        id = "info",
        placement = "float",
        title = "Information",
        body = "Done",
        actions = { { id = "ok", key = "o", label = "OK" } },
      },
      queue_count = 2,
    })
    assert(vim.wait(1000, function()
      return value.dialog_component and value.dialog_component.pane.layout ~= nil
    end))
    vim.wait(50)
    assert.are.same({}, dismissed)
    assert.is_true(applet_input.dispatch_action(value.dialog_component.pane,
      Applet.Pane.nodes.action("dialog.cancel"), nil, 1, "n", 0, 0))
    assert.are.same({ "info" }, dismissed)
  end)

  it("renders a deferred topology generation from its submitted ViewState", function()
    local value = view()
    assert(value:set_dialog({
      active = {
        id = "deferred",
        placement = "float",
        title = "Submitted dialog",
        body = "Submitted body",
        actions = { { id = "ok", key = "o", label = "OK" } },
      },
      queue_count = 0,
    }))
    local submitted = assert(value.dialog_component)
    value.dialog = nil
    value.dialog_component = nil

    assert(value.applet:open())
    assert.are.equal(submitted.pane, value:pane("dialog"))

    value.dialog_component = submitted
    value:_close_dialog_surface(false)
  end)

  it("reconciles streamed transcript events and card details through Panes", function()
    local value = view()
    value:set_messages({
      { role = "assistant", content = {
        { type = "thinking", thinking = "trace" },
        { type = "text", text = "answer" },
        { type = "toolCall", id = "call", name = "shell", arguments = {} },
      } },
      { role = "toolResult", toolCallId = "call", toolName = "shell",
        isError = false, content = { { type = "text", text = "done" } } },
      { role = "compactionSummary", summary = "summary", tokensBefore = 10 },
    })
    assert(value:open())
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "summary")
    end))
    value:set_context({ state = "running", model = "fake" })
    value:apply({ type = "text_delta", index = 0, text = "stream" })
    value:apply({ type = "thinking_delta", index = 0, text = "think" })
    value:apply({ type = "tool_call_delta", index = 0, id = "stream-call",
      name = "shell", arguments_delta = "{}" })
    value:apply({ type = "message_end", message = {
      role = "assistant", content = {
        { type = "text", text = "stream" },
        { type = "thinking", thinking = "think" },
        { type = "toolCall", id = "stream-call", name = "shell", arguments = {} },
      },
    } })
    value:apply({ type = "tool_start", call = {
      id = "stream-call", name = "shell", arguments = {},
    } })
    value:apply({ type = "tool_update", call = { id = "stream-call" },
      result = { content = { { type = "text", text = "working" } } } })
    value:apply({ type = "tool_end", call = {
      id = "stream-call", name = "shell", arguments = {},
    }, message = {
      role = "toolResult", toolCallId = "stream-call", toolName = "shell",
      isError = true, content = { { type = "text", text = "failed" } },
    } })
    value:apply({ type = "compaction_end", result = {
      ok = false, error = { message = "compaction failed" },
    } })
    value.transcript.pane:flush()
    assert(contains(view_handles.buffer(value, "transcript"), "compaction failed"))
    local block = value.transcript.blocks[1]
    assert(value:show_card_details(block.key))
    assert(vim.wait(1000, function()
      return value.details and value.details.pane.layout ~= nil
    end))
    assert.is_true(applet_input.dispatch_action(value.details.pane,
      Applet.Pane.nodes.action("details.raw"), nil, 1, "n", 0, 0))
    value.details.pane:flush()
    assert.is_true(value.details:text():find("trace", 1, true) ~= nil)
    assert.is_true(applet_input.dispatch_action(value.details.pane,
      Applet.Pane.nodes.action("details.close"), nil, 1, "n", 0, 0))
    value:finish({ ok = false, error = { kind = "cancelled", message = "cancelled" } })
    value.transcript.pane:flush()
  end)

  it("preserves layered transcript highlights", function()
    local value = view()
    value:set_messages({
      { role = "assistant", content = {
        { type = "thinking", thinking = "private trace" },
        { type = "text", text = "# Visible **answer**" },
      } },
    })
    assert(value:open())
    assert(vim.wait(1000, function()
      return line_index(view_handles.buffer(value, "transcript"), "private trace") ~= nil
    end))

    local thinking_row, thinking_line = line_index(
      view_handles.buffer(value, "transcript"), "private trace")
    thinking_row = thinking_row - 1
    local thinking_start = assert(thinking_line:find("private trace", 1, true)) - 1
    local thinking = highlight_groups(view_handles.buffer(value, "transcript"),
      value.transcript.pane.namespace, thinking_row, thinking_start,
      thinking_start + #"private trace")
    assert.is_true(thinking.NeoagentThinking)
    assert.is_true(thinking.NeoagentMarkdownItalic)

    local heading_row, heading_line = line_index(view_handles.buffer(value, "transcript"), "Visible answer")
    heading_row = heading_row - 1
    local heading_start = assert(heading_line:find("Visible answer", 1, true)) - 1
    local heading = highlight_groups(view_handles.buffer(value, "transcript"),
      value.transcript.pane.namespace, heading_row, heading_start,
      heading_start + #"Visible answer")
    assert.is_true(heading.NeoagentMarkdownHeading)
    assert.is_true(heading.NeoagentMarkdownBold)
    assert.is_true(heading.NeoagentMarkdownUnderline)
  end)

  it("preserves transcript highlights while scrolling during streaming", function()
    local value = view({ height = 12, input_height = 3 })
    local messages = {}
    for index = 1, 3 do
      messages[#messages + 1] = {
        role = "assistant",
        content = {
          { type = "thinking", thinking = "trace " .. index },
          { type = "text", text = "# Answer **" .. index .. "**" },
        },
      }
    end
    value:set_messages(messages)
    value:set_context({ state = "running" })
    value:apply({ type = "thinking_delta", text = "live trace" })
    value:apply({ type = "text_delta", text = "# Live **answer**" })
    assert(value:open())
    assert(vim.wait(1000, function()
      return line_index(view_handles.buffer(value, "transcript"), "live trace") ~= nil
    end))

    local before = persistent_highlight_counts(
      view_handles.buffer(value, "transcript"), value.transcript.pane.namespace)
    assert.is_true((before.NeoagentThinking or 0) >= 4)
    assert.is_true((before.NeoagentMarkdownHeading or 0) >= 3)
    value:focus_transcript()
    vim.api.nvim_win_call(view_handles.window(value, "transcript"), function()
      vim.cmd("normal! gg")
      vim.cmd("normal! G")
    end)
    assert.is_true(vim.api.nvim_win_call(view_handles.window(value, "transcript"),
      function() return vim.fn.winsaveview().topline end) > 1)

    for index = 1, 2 do
      value:apply({ type = "thinking_delta", text = "\ndelta" .. index })
    end
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "delta2")
    end))
    local after = persistent_highlight_counts(
      view_handles.buffer(value, "transcript"), value.transcript.pane.namespace)
    assert.is_true((after.NeoagentThinking or 0) >= 4)
    assert.is_true((after.NeoagentMarkdownHeading or 0) >= 4)
    assert.is_true((after.NeoagentMarkdownBold or 0) >= 4)

    value:apply({ type = "message_end", message = {
      role = "assistant",
      content = {
        { type = "thinking", thinking = "live trace\ndelta1\ndelta2" },
        { type = "text", text = "# Live **answer**" },
      },
    } })
    value:finish({ ok = true })
    value.transcript.pane:flush()
    local heading_row, heading_line = line_index(
      view_handles.buffer(value, "transcript"), "Live answer")
    heading_row = heading_row - 1
    local heading_start = assert(heading_line:find("Live answer", 1, true)) - 1
    local heading = highlight_groups(view_handles.buffer(value, "transcript"),
      value.transcript.pane.namespace, heading_row, heading_start,
      heading_start + #"Live answer")
    assert.is_true(heading.NeoagentMarkdownHeading)
    assert.is_true(heading.NeoagentMarkdownBold)
  end)

  it("keeps composer history and focus in the shared domain", function()
    local history = { "older prompt", "oldest prompt" }
    local submitted
    local value = view()
    value.callbacks.on_input_history = function() return history end
    value.callbacks.on_submit = function(text)
      submitted = text
      return true
    end
    value:set_messages({ { role = "assistant", content = {
      { type = "text", text = "card" },
    } } })
    assert(value:set_position("center"))
    assert(value:open())
    value.input.callbacks.history = function() return history end
    value.input:set_text("draft")
    assert.is_true(value.input:_move_history(-1))
    assert.are.equal("older prompt", value:get_input())
    assert.is_true(value.input:_move_history(1))
    assert.are.equal("draft", value:get_input())
    value.input.callbacks.submit = function(text)
      submitted = text
      return true
    end
    assert(value.input:_submit())
    assert.are.equal("draft", submitted)
    value:focus_transcript()
    value:focus_input()
    value:set_context({ position = "left" })
    assert(value:set_position("left"))
    assert(value:set_position("center"))
    assert.are.equal(renderers.codex, value:set_renderer(renderers.codex))
    assert.are.equal(renderers.pi, value:set_renderer(renderers.pi))
    local completion = view({ completion = true })
    completion:set_input("")
    assert(completion:open())
    assert.is_true(completion.input:_complete())
    completion.input:set_virtual_lines({ { { text = "status", style = "muted" } } })
    completion.input:set_config(completion.config)
    completion.input:replace_text("")
    completion.input:_close_empty("<C-c>")
    assert.is_not_truthy(completion:is_open())
  end)

  it("publishes status and transcript blocks for complete message lifecycles", function()
    local value = view()
    local transcript = value.transcript
    transcript:set_config({
      mappings = { card_details = false, card_previous = false, card_next = false },
      show_thinking = true,
      wrap_cards = false,
    })
    value:set_context({
      name = "Status",
      model = "fake/model",
      thinking = "high",
      state = "running",
      steering = { " queued   instruction " },
      context_usage = { used = 1500, total = 2000000, percent = 0.05 },
    })
    value:set_messages({
      { role = "toolResult", toolCallId = "missing", toolName = "inspect",
        isError = false, content = { { type = "text", text = "result" } } },
      { role = "compactionSummary", summary = "compact", tokensBefore = 2000 },
    })
    value:apply({ type = "message_end", message = {
      role = "user", content = "new prompt",
    } })
    value:apply({ type = "message_end", message = {
      role = "assistant", content = {
        { type = "text", index = 1, text = "indexed" },
        { type = "thinking", index = 1, thinking = "deep thought" },
        { type = "toolCall", id = "new-call", name = "inspect", arguments = {} },
      },
    } })
    value:apply({ type = "tool_start", call = {
      id = "unannounced", name = "inspect", arguments = {},
    } })
    value:apply({ type = "tool_update", call = { id = "unannounced" },
      result = { content = { { type = "text", text = "progress" } } } })
    value:apply({ type = "tool_end", call = {
      id = "unannounced", name = "inspect", arguments = {},
    }, message = {
      role = "toolResult", toolCallId = "unannounced", toolName = "inspect",
      isError = false, content = { { type = "text", text = "done" } },
    } })
    value:apply({ type = "tool_end", call = {
      id = "second-unannounced", name = "inspect", arguments = {},
    }, message = {
      role = "toolResult", toolCallId = "second-unannounced",
      toolName = "inspect", isError = true, content = {},
    } })
    value:apply({ type = "compaction_end", result = { ok = false } })
    transcript:set_spinner("*")
    assert(value:open())
    transcript.pane:flush()
    local title = vim.api.nvim_win_get_config(view_handles.window(value, "transcript")).title
    assert.matches("Status", title[1][1])
    assert.is_true(#transcript.pane.layout.virtuals > 0)
    assert(contains(view_handles.buffer(value, "transcript"), "new prompt"))
    assert(contains(view_handles.buffer(value, "transcript"), "compact"))
    value:finish({ ok = true })
    transcript.pane:flush()
  end)

  it("routes View callbacks across retained surfaces and transient dialogs", function()
    local submitted, stopped, dequeued = {}, false, false
    local value = view()
    value.callbacks.on_submit = function(text)
      submitted[#submitted + 1] = text
      return true
    end
    value.callbacks.on_stop = function()
      stopped = true
      return true
    end
    value.callbacks.on_dequeue_steering = function()
      dequeued = true
      return { "queued" }
    end
    assert.is_false(value:_focus_previous_card())
    value:set_input("draft")
    assert(value:open())
    assert(value:open())
    assert.is_false(value:_focus_previous_card())
    assert(value:_submit("direct"))
    assert.are.same({ "direct" }, submitted)
    local input = value.input
    input:set_config({
      mappings = {
        submit = false, interrupt = false, close_empty = false,
        history_previous = false, history_next = false,
      },
      completion = false,
    })
    input.pane:flush()
    input.replacing = true
    input:_changed()
    input.replacing = false
    input:_changed()
    local original_pumvisible = vim.fn.pumvisible
    vim.fn.pumvisible = function() return 1 end
    assert(value:_submit("completed"))
    assert.are.same({ "direct" }, submitted)
    assert(input:_complete())
    assert(input:_submit())
    assert(input:_move_history(-1))
    vim.fn.pumvisible = original_pumvisible
    input:set_text("draft")
    vim.api.nvim_win_set_cursor(view_handles.window(value, "input"), { 1, 1 })
    assert.is_false(input:_move_history(-1))
    input:set_text("one\ntwo")
    vim.api.nvim_win_set_cursor(view_handles.window(value, "input"), { 1, 0 })
    assert.is_false(input:_move_history(1))
    vim.api.nvim_win_set_cursor(view_handles.window(value, "input"), { 2, 0 })
    assert.is_false(input:_move_history(1))

    value:set_input("current")
    assert.are.equal(2, value:_restore_steering())
    assert.is_true(dequeued)
    assert.are.equal("queued\n\ncurrent", value:get_input())
    value:set_input("clear me")
    assert.is_false(value:_interrupt())
    assert.are.equal("", value:get_input())
    value:set_input("")
    value:set_context({ state = "running" })
    assert(value:_interrupt())
    assert.is_true(stopped)

    local margin = value.config.margin
    value.config.margin = 1000
    local positioned, position_error = value:_reposition()
    assert.is_nil(positioned)
    assert.matches("does not fit", position_error)
    value.config.margin = margin
    assert(value:_reposition())
    assert(value:set_position("left"))

    value:set_messages({
      { role = "assistant", content = {
        { type = "text", text = "one" },
      } },
      { role = "assistant", content = {
        { type = "text", text = "two" },
      } },
    })
    value.transcript.pane:flush()
    assert(value:_focus_previous_card())
    assert.are.equal("two", value:_current_block().text)
    assert.is_true(applet_input.dispatch_action(value.transcript.pane,
      Applet.Pane.nodes.action("transcript.card_move", { direction = -1 }),
      nil, 1, "n", 0, 0))
    value:set_dialog({
      active = {
        id = "inline-navigation",
        placement = "transcript",
        title = "Choose",
        body = "Body",
        actions = { { id = "ok", key = "o", label = "OK" } },
      },
      queue_count = 0,
    })
    assert(value:_navigate_transcript(1, 1))
    value:set_dialog(nil)
    assert(value:_focus_previous_card())
    assert(value:_navigate_transcript(1, 1))
    assert.are.equal(view_handles.window(value, "input"), vim.api.nvim_get_current_win())
    assert(value:show_card_details(value.transcript.blocks[1].key))
    assert(value:_details_move(1))
    assert(value:_details_move(1))
    assert.is_nil(view_handles.window(value, "details"))
    assert(value:show_card_details(value.transcript.blocks[1].key))
    assert.is_false(value:_details_move(-1))
    value:set_messages({})
    assert.is_nil(view_handles.window(value, "details"))

    value:set_dialog({
      active = {
        id = "transient",
        placement = "float",
        title = "Transient",
        body = "Body",
        actions = { { id = "ok", key = "o", label = "OK" } },
      },
      queue_count = 0,
    })
    assert.is_true(vim.api.nvim_win_is_valid(view_handles.window(value, "dialog")))
    local dialog_window = view_handles.window(value, "dialog")
    vim.api.nvim_win_close(dialog_window, true)
    assert.is_nil(view_handles.window(value, "dialog"))
    value:set_renderer(renderers.codex)
    value:set_dialog(nil)
    value:close()
    value:close()
  end)

  it("updates retained surface Panes when the active Renderer changes", function()
    local value = view()
    value:set_messages({ { role = "assistant", content = {
      { type = "text", text = "original" },
    } } })
    value:set_input("renderer draft")
    assert(value:open())
    assert(value:show_card_details(value.transcript.blocks[1].key))
    value.details:set(value.details.block, true)
    value.details.pane:flush()
    value:set_dialog({
      active = {
        id = "renderer-dialog",
        placement = "float",
        title = "Renderer dialog",
        body = "Body",
        actions = { { id = "ok", key = "o", label = "OK" } },
      },
      queue_count = 0,
    })
    local renderer = {
      name = "native-test",
      theme = renderers.pi.theme,
      render_block = function(_, block)
        return Applet.Pane.nodes.text({
          key = "native:" .. block.key,
          runs = { { text = "native " .. (block.text or block.kind) } },
        })
      end,
      render_details = function(_, block)
        return Applet.Pane.nodes.text({
          key = "native-details:" .. block.key,
          text = block.text or block.kind,
        })
      end,
    }
    local transcript = value.transcript.pane
    local input = value.input.pane
    local transcript_buffer = view_handles.buffer(value, "transcript")
    local input_buffer = view_handles.buffer(value, "input")
    assert.are.equal(renderer, value:set_renderer(renderer))
    value:apply({ type = "text_delta", text = "updated" })
    value.transcript.pane:flush()
    assert(vim.wait(1000, function()
      return contains(view_handles.buffer(value, "transcript"), "native updated")
    end))
    assert.is_nil(rawget(value, "domain"))
    assert.are.equal("native-test", value.renderer.name)
    assert.are.equal(transcript, value.transcript.pane)
    assert.are.equal(input, value.input.pane)
    assert.is_false(transcript:is_destroyed())
    assert.is_false(input:is_destroyed())
    assert.are.equal(transcript_buffer, view_handles.buffer(value, "transcript"))
    assert.are.equal(input_buffer, view_handles.buffer(value, "input"))
    assert.are.equal("renderer draft", value:get_input())
    assert.is_true(vim.api.nvim_win_is_valid(view_handles.window(value, "details")))
    assert.is_true(value.details.raw)
    assert.is_true(vim.api.nvim_win_is_valid(view_handles.window(value, "dialog")))
  end)

  it("preserves the transcript viewport when the Renderer changes", function()
    local value = view()
    local content = {}
    for index = 1, 80 do
      content[index] = ("line %02d"):format(index)
    end
    value:set_messages({ { role = "assistant", content = {
      { type = "text", text = table.concat(content, "\n") },
    } } })
    assert(value:open())
    assert(vim.wait(1000, function()
      return value.transcript.pane.layout ~= nil
        and vim.api.nvim_buf_line_count(view_handles.buffer(value, "transcript")) >= 80
    end))
    value:focus_transcript()
    vim.api.nvim_win_set_cursor(view_handles.window(value, "transcript"), { 35, 0 })
    vim.api.nvim_win_call(view_handles.window(value, "transcript"), function()
      vim.cmd("normal! zt")
    end)

    assert.are.equal(renderers.codex, value:set_renderer(renderers.codex))
    assert(vim.wait(1000, function()
      return value.transcript.pane.committed_generation
        == value.transcript.pane.generation
    end))
    local restored = vim.api.nvim_win_call(view_handles.window(value, "transcript"), function()
      return vim.fn.winsaveview()
    end)
    assert.are.equal(35, restored.lnum)
    assert.are.equal(35, restored.topline)
  end)

  it("invalidates adjacency-dependent transcript regions", function()
    local value = view()
    local renderer = {
      name = "neighbors",
      theme = renderers.pi.theme,
      render_block = function(_, block, env)
        local following = env.following and env.following.state or "none"
        return Applet.Pane.nodes.text({
          key = "neighbor:" .. block.key,
          text = (block.text or block.kind) .. " next=" .. following,
        })
      end,
      render_details = function() end,
    }
    assert.are.equal(renderer, value:set_renderer(renderer))
    assert(value:open())
    value:apply({ type = "text_delta", text = "answer" })
    value:apply({
      type = "tool_call_delta", index = 0, id = "call",
      name = "shell", arguments_delta = "{}",
    })
    value.transcript.pane:flush()
    assert.is_true(contains(view_handles.buffer(value, "transcript"), "answer next=pending"))
    value:apply({ type = "tool_start", call = {
      id = "call", name = "shell", arguments = {},
    } })
    value.transcript.pane:flush()
    assert.is_true(contains(view_handles.buffer(value, "transcript"), "answer next=running"))
  end)

  it("bounds transcript invalidation to a changed block and its neighbors", function()
    local calls = {}
    local value = view()
    local renderer = {
      name = "bounded-neighbors",
      theme = renderers.pi.theme,
      render_block = function(_, block)
        calls[block.key] = (calls[block.key] or 0) + 1
        return Applet.Pane.nodes.text({
          key = "bounded:" .. block.key,
          text = block.text or block.kind,
        })
      end,
      render_details = function() end,
    }
    assert.are.equal(renderer, value:set_renderer(renderer))
    value:set_messages({
      { role = "user", content = "first" },
      { role = "assistant", content = { { type = "text", text = "second" } } },
      { role = "user", content = "third" },
    })
    assert(value:open())
    value:apply({ type = "text_delta", text = "fourth" })
    assert(value.transcript.pane:flush())

    calls = {}
    value:apply({ type = "text_delta", text = " updated" })
    assert(value.transcript.pane:flush())

    assert.are.same({
      ["message:3:user"] = 1,
      ["response:1:text:default"] = 1,
    }, calls)
  end)

  it("resolves semantic tool rendering in details", function()
    local resolved = config.setup({
      ui = { style = "pi", position = "center" },
    }).ui
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      resolve_tool = function(name)
        if name ~= "semantic" then return end
        return {
          name = name,
          render = function()
            return {
              kind = "text",
              title = "Semantic result",
              lines = { "semantic full detail" },
            }
          end,
        }
      end,
    })
    views[#views + 1] = value
    value:set_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "semantic-call", name = "semantic",
        arguments = {},
      } } },
      {
        role = "toolResult", toolCallId = "semantic-call",
        toolName = "semantic", isError = false,
        content = { { type = "text", text = "ordinary fallback" } },
      },
    })
    assert(value:open())
    local block = value.transcript.blocks[1]
    assert(value:show_card_details(block.key))
    assert(vim.wait(1000, function()
      return view_handles.buffer(value, "details")
        and contains(view_handles.buffer(value, "details"), "semantic full detail")
    end))
  end)

  it("restores auto placement after host changes", function()
    local origin = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local host = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(origin)
    local value = view({
      position = "auto",
    })
    assert(value:open(origin))
    local config_before = vim.api.nvim_win_get_config(view_handles.window(value, "transcript"))
    local host_position = vim.api.nvim_win_get_position(host)
    assert.is_true(config_before.col >= host_position[2])
    assert.is_true(config_before.width <= vim.api.nvim_win_get_width(host))

    value:set_position("center")
    assert.is_true(vim.api.nvim_win_is_valid(view_handles.window(value, "transcript")))
  end)

  it("redefines bundled highlights after a colorscheme event", function()
    local value = view()
    assert(value:open())
    vim.api.nvim_set_hl(0, "NeoagentAccent", { link = "Error" })
    vim.cmd("colorscheme default")
    local accent = vim.api.nvim_get_hl(0, {
      name = "NeoagentAccent",
      link = true,
    })
    assert.are.equal("Identifier", accent.link)
  end)

  it("uses persisted entry identities for transcript block keys", function()
    local value = view()
    value:set_messages({
      { _neoagent_entry_id = "entry-b", role = "user", content = "second" },
      { _neoagent_entry_id = "entry-c", role = "user", content = "third" },
    })
    assert.are.equal("message:entry-b:user", value.transcript.blocks[1].key)
    assert.are.equal("message:entry-c:user", value.transcript.blocks[2].key)
    value:set_messages({
      { _neoagent_entry_id = "entry-a", role = "user", content = "first" },
      { _neoagent_entry_id = "entry-b", role = "user", content = "second" },
      { _neoagent_entry_id = "entry-c", role = "user", content = "third" },
    })
    assert.are.equal("message:entry-b:user", value.transcript.blocks[2].key)
  end)

  it("resolves custom Hosts and restores pending input presentations on reopen", function()
    local resolved = config.setup({
      ui = {
        style = "pi",
        position = "center",
        provider_shell = { position = "right", width = 20 },
      },
    }).ui
    local host_state, host_config
    local value = neoagent_ui.new({
      config = resolved,
      renderer = resolved.renderer,
      host_factory = function(state, ui_config)
        host_state, host_config = state, ui_config
        return Applet.host.floating({
          side = "center",
          width = 0.9,
          height = 0.9,
        })
      end,
    })
    views[#views + 1] = value

    assert.is_false(value:focus_transcript())
    value:set_dialog({
      active = {
        id = "before-open",
        placement = "float",
        title = "Before open",
        body = "Prepared while closed",
        actions = { { id = "ok", key = "o", label = "OK" } },
      },
      queue_count = 0,
    })
    assert.is_table(value.dialog_component)
    assert.is_nil(view_handles.window(value, "dialog"))
    value:set_dialog(nil)

    assert(value:set_presentation({
      active = {
        id = "pending-input",
        kind = "input",
        prompt = "Pending input",
        default = "seed",
        multiline = false,
        secret = false,
        allow_empty = true,
        mask = "•",
      },
      queue_count = 0,
    }))
    assert(value:open())
    assert.are.equal("center", host_state.position)
    assert.are.equal(20, host_config.provider_shell.width)
    assert.are.equal("seed", value.presentation_component:text())

    value:pane("presentation"):replace_text("edited", {
      line = 1,
      column = 6,
    })
    value:close()
    assert(value:open())
    assert.are.equal("seed", value.presentation_component:text())
    assert(value:set_presentation({ active = nil, queue_count = 0 }))
  end)

  it("rolls back transient component construction after frame failures", function()
    local value = view()
    local cancelled
    value.callbacks.on_presentation_cancel = function(id) cancelled = id end
    assert(value:open())
    assert(value:set_presentation({
      active = {
        id = "stable",
        kind = "select",
        prompt = "Stable",
        items = { { id = "one", label = "One" } },
      },
      queue_count = 0,
    }))
    local stable = value.presentation_component
    assert(value:set_presentation({
      active = {
        id = "stable",
        kind = "select",
        prompt = "Updated stable request",
        items = { { id = "one", label = "One" } },
      },
      queue_count = 2,
    }))
    assert.are.equal(stable, value.presentation_component)
    assert.are.equal(2, value.presentation.queue_count)
    assert.is_false(value:_seed_presentation())
    local flush = value.applet.flush
    value.applet.flush = function()
      return nil, "injected frame failure"
    end
    local presented, presentation_error = value:set_presentation({
      active = {
        id = "replacement",
        kind = "input",
        prompt = "Replacement",
        default = "draft",
      },
      queue_count = 0,
    })
    value.applet.flush = flush
    assert.is_nil(presented)
    assert.are.equal("injected frame failure", presentation_error)
    assert.are.equal(stable, value.presentation_component)
    assert.are.equal("stable", value.presentation.active.id)
    assert(require("applet.pane.input").dispatch(
      value.presentation_component.pane, "n", "q"))
    assert.are.equal("stable", cancelled)

    local failing_details = view()
    failing_details:set_messages({
      { role = "assistant", content = { { type = "text", text = "answer" } } },
    })
    assert(failing_details:open())
    failing_details.applet.flush = function()
      return nil, "injected details failure"
    end
    assert.is_false(failing_details:show_card_details(
      failing_details.transcript.blocks[1].key))
    assert.is_nil(failing_details.details_component)
  end)

  it("closes the composition when a required Pane changes buffer", function()
    local value = view()
    value:set_input("retained draft")
    assert(value:open())
    local replacement = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(replacement, 0, -1, false, { "foreign" })

    vim.api.nvim_win_set_buf(view_handles.window(value, "input"), replacement)

    assert(vim.wait(1000, function() return not value:is_open() end))
    assert.is_true(vim.api.nvim_buf_is_valid(replacement))
    assert.are.same({ "foreign" }, lines(replacement))
    assert.are.equal("retained draft", value:get_input())
  end)

end)
