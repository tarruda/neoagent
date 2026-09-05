local Applet = require("applet")
local protocol = require("neoagent.ui.renderer")
local renderers = require("neoagent.ui.renderers")

local ui = Applet.Pane.nodes

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

local function find_node(node, kind)
  if type(node) ~= "table" then return nil end
  if node.type == kind then return node end
  for _, value in pairs(node) do
    if type(value) == "table" then
      local found = find_node(value, kind)
      if found then return found end
    end
  end
end

local function renderer(overrides)
  return vim.tbl_extend("force", {
    name = "custom",
    theme = Applet.Theme.new(),
    render_block = function(_, block)
      return ui.text({ key = "custom:block", text = block.text or block.kind })
    end,
    render_details = function() return nil end,
  }, overrides or {})
end

local function layout(node, theme, width)
  return assert(Applet.Pane.compile({
    tree = node,
    width = width or 60,
    theme = theme or renderers.pi.theme,
  }))
end

local function rendered(selected, block, opts)
  return table.concat(layout(assert(protocol.render_block(
    selected, block, opts or { width = 60, spinner = "*" })),
    selected.theme, opts and opts.width or 60).lines, "\n")
end

describe("neoagent native Renderer protocol", function()
  it("validates explicit values and exposes bundled Renderers", function()
    assert.are.equal(renderers.pi, protocol.validate(renderers.pi))
    assert.are.equal(renderers.codex, renderers.get("codex"))
    assert.are.same({ "pi", "codex" }, renderers.names())
    assert.is_nil(renderers.get("unknown"))

    for _, value in ipairs({
      false,
      {},
      { name = 1 },
      { name = "missing" },
      renderer({ theme = false }),
      renderer({ theme = { group = function() end } }),
      renderer({ render_block = true }),
      renderer({ render_details = true }),
    }) do
      local selected, err = protocol.validate(value)
      assert.is_nil(selected)
      assert.are.equal("ui", err.kind)
    end
    local ok, err = pcall(protocol.assert, {}, "configured Renderer")
    assert.is_false(ok)
    assert.matches("configured Renderer", err)
  end)

  it("constructs the Applet View through the UI facade", function()
    local facade = require("neoagent.ui")
    local value = facade.new({
      config = { renderer = renderers.pi, style = "pi", position = "center" },
    })
    assert.is_table(value.transcript)
    assert.is_table(value.input)
    value:destroy()
  end)

  it("passes copied semantic blocks and bounded render context", function()
    local seen
    local selected = renderer({
      render_block = function(_, block, opts)
        seen = { block = block, opts = opts }
        block.call.arguments.value = 2
        opts.previous.text = "changed"
        opts.tool.name = "changed"
        return ui.text({ key = "copy", text = "copied" })
      end,
    })
    local block = {
      kind = "tool",
      call = { arguments = { value = 1 } },
      dirty = true,
      mark = 42,
    }
    local opts = {
      previous = { kind = "assistant", text = "before", dirty = true },
      following = { kind = "assistant", text = "after" },
      tool = { name = "shell", render = function() end },
    }
    local node = assert(protocol.render_block(selected, block, opts))
    assert.are.same({ "copied" }, layout(node, selected.theme).lines)
    assert.are.equal(1, block.call.arguments.value)
    assert.are.equal("before", opts.previous.text)
    assert.are.equal("shell", opts.tool.name)
    assert.is_nil(seen.block.dirty)
    assert.is_nil(seen.block.mark)
    assert.is_nil(seen.opts.previous.dirty)
    assert.are.equal("after", seen.opts.following.text)
  end)

  it("round trips opaque continuations for one rendering surface", function()
    local previous = {}
    local following = {}
    local received
    local selected = renderer({
      render_block = function(_, block, opts, continuation)
        received = continuation
        return ui.text({ key = "continued", text = block.text }), following
      end,
    })

    local node, continuation = protocol.render_block(selected, {
      kind = "assistant",
      text = "continued",
    }, { width = 40 }, previous)

    assert.are.same({ "continued" }, layout(node, selected.theme).lines)
    assert.is_true(rawequal(previous, received))
    assert.is_true(rawequal(following, continuation))
  end)

  it("retains completed expanded Markdown Trees across appends", function()
    local lines = {}
    for index = 1, 130 do
      lines[index] = "line " .. index .. " with **emphasis**"
    end
    local source = table.concat(lines, "\n")
    local first, continuation = protocol.render_details(renderers.pi, {
      key = "retained-details",
      kind = "thinking",
      text = source,
      text_epoch = 1,
    }, { width = 50 })
    assert.are.equal(3, #first.children)
    local stable_first, stable_second, changing_tail =
      first.children[1], first.children[2], first.children[3]

    local second = assert(protocol.render_details(renderers.pi, {
      key = "retained-details",
      kind = "thinking",
      text = source .. " continues",
      text_epoch = 1,
    }, { width = 50 }, continuation))

    assert.is_true(rawequal(stable_first, second.children[1]))
    assert.is_true(rawequal(stable_second, second.children[2]))
    assert.is_false(rawequal(changing_tail, second.children[3]))
    assert.matches("line 130 with emphasis continues",
      table.concat(layout(second, renderers.pi.theme, 50).lines, "\n"))
  end)

  it("keeps image output beside retained expanded Markdown", function()
    local details = assert(protocol.render_details(renderers.pi, {
      key = "generated-image-details",
      kind = "assistant",
      text = "Generated **preview**",
      content = { {
        type = "image",
        mimeType = "image/png",
        data = png(8, 4),
      } },
    }, { width = 40 }))

    local image = assert(find_node(details, "image"))
    assert.are.equal("native", image.width)
    local rendered_details = table.concat(
      layout(details, renderers.pi.theme, 40).lines, "\n")
    assert.matches("Generated preview", rendered_details)
    assert.matches("Image · PNG · 8×4", rendered_details)
  end)

  it("bounds Renderer failures and leaves Tree validation to Applet", function()
    local _, thrown = protocol.render_block(renderer({
      render_block = function() error("renderer exploded") end,
    }), { kind = "notice" }, {})
    assert.matches("renderer exploded", thrown.message)

    local missing, missing_error = protocol.render_block(renderer({
      render_block = function() end,
    }), { kind = "notice" }, {})
    assert.is_nil(missing)
    assert.matches("returned no Pane content node", missing_error.message)
    assert.is_nil(protocol.render_details(renderer(), { kind = "notice" }, {}))

    local physical = assert(protocol.render_block(renderer({
      render_block = function() return { lines = { "physical" } } end,
    }), { kind = "notice" }, {}))
    local ok, compile_error = pcall(Applet.Pane.compile, {
      tree = physical,
      width = 40,
      theme = Applet.Theme.new(),
    })
    assert.is_false(ok)
    assert.matches("tree.root", compile_error)
  end)

  it("defines highlights exclusively through the Applet Theme", function()
    local theme = Applet.Theme.new()
    local calls = 0
    theme.define = function() calls = calls + 1 end
    assert.is_true(protocol.define_highlights(renderer({ theme = theme })))
    assert.are.equal(1, calls)
    theme.define = function() error("theme exploded") end
    local defined, err = protocol.define_highlights(renderer({ theme = theme }))
    assert.is_nil(defined)
    assert.matches("theme exploded", err.message)
  end)

  it("renders every transcript block family as native Trees", function()
    local cases = {
      { { key = "user", kind = "user", text = "prompt" }, "prompt" },
      { { key = "assistant", kind = "assistant", text = "answer" }, "answer" },
      { { key = "thinking", kind = "thinking", text = "reasoning" }, "reasoning" },
      { { key = "notice", kind = "notice", text = "notice" }, "notice" },
      { { key = "compact", kind = "compaction", summary = "summary",
          tokens_before = 1200 }, "summary" },
      { { key = "tool", kind = "tool", state = "pending", name = "read_file",
          call = { name = "read_file", arguments = { path = "README.md" } } },
        "README.md" },
    }
    for _, case in ipairs(cases) do
      for _, selected in ipairs({ renderers.pi, renderers.codex }) do
        assert.matches(case[2], rendered(selected, case[1], {
          width = 50,
          spinner = "*",
          details_key = "<CR>",
        }))
      end
    end
  end)

  it("renders tool output containing tabs as a live transcript card", function()
    local output = rendered(renderers.codex, {
      key = "tabular-tool",
      kind = "tool",
      state = "success",
      call = { name = "shell", arguments = { command = "printf tabular" } },
      message = {
        toolName = "shell",
        isError = false,
        content = { { type = "text", text = "name\tvalue\nalpha\t42" } },
      },
    }, {
      width = 50,
      spinner = "*",
      details_key = "<CR>",
    })
    assert.matches("name", output)
    assert.matches("value", output)
    assert.matches("alpha", output)
  end)

  it("attaches native focus chrome to bundled card targets", function()
    local node = assert(protocol.render_block(renderers.pi, {
      key = "answer",
      kind = "assistant",
      text = "two words",
    }, {
      width = 48,
      surface_width = 50,
      details_key = "<CR>",
    }))
    local value = layout(node, renderers.pi.theme, 50)
    local target = assert(value.targets["card:answer"])
    assert.is_nil(target.focus_style)
    assert.is_true(#target.focus.active >= 2)
    local text = {}
    for _, decoration in ipairs(target.focus.active) do
      for _, chunk in ipairs(decoration.chunks) do
        text[#text + 1] = chunk[1]
      end
    end
    local focus_text = table.concat(text)
    assert.matches("<CR> to expand", focus_text)
    assert.is_nil(focus_text:find("word", 1, true))
    assert.are.same({}, target.focus.inactive)
  end)

  it("keeps source metadata aligned across group separators", function()
    local written = layout(assert(protocol.render_block(renderers.codex, {
      key = "grouped-write",
      kind = "tool",
      state = "success",
      call = { name = "write_file", arguments = {
        path = "example.lua",
        content = "local one = 1\nlocal two = 2",
      } },
      message = {
        toolName = "write_file",
        isError = false,
        content = { { type = "text", text = "wrote file" } },
      },
    }, {
      width = 48,
      previous = { kind = "assistant" },
    })), renderers.codex.theme, 50)
    assert.matches("─", written.lines[1])
    assert.are.equal("example.lua", written.source_ranges[1].path)
    assert.are.equal(3, written.source_ranges[1].first)
    assert.are.equal(5, written.source_ranges[1].last)
  end)

  it("keeps expanded semantic tool rows independent of width", function()
    local edit_tool = require("neoagent.tools.edit_file").new()
    local edit_line = "local value = " .. string.rep("long_expression + ", 12)
      .. "final_value"
    local edit_block = {
      key = "expanded-edit",
      kind = "tool",
      state = "success",
      call = { name = "edit_file", arguments = {
        path = "example.lua",
        edits = {},
      } },
      message = {
        toolName = "edit_file",
        isError = false,
        content = { { type = "text", text = "edited" } },
        details = { patch = "@@ -1 +1 @@\n-old\n+" .. edit_line },
      },
    }
    local plan_tool = require("neoagent.tools.update_plan").new()
    local explanation = "Explain " .. string.rep("one logical line ", 10)
      .. "completely"
    local step = "Implement " .. string.rep("one logical step ", 10)
      .. "completely"
    local plan = {
      explanation = explanation,
      plan = { { step = step, status = "pending" } },
    }
    local plan_block = {
      key = "expanded-plan",
      kind = "tool",
      state = "success",
      call = { name = "update_plan", arguments = plan },
      message = {
        toolName = "update_plan",
        isError = false,
        content = { { type = "text", text = "Plan updated" } },
        details = plan,
      },
    }
    local function details_lines(block, tool, width)
      return layout(assert(protocol.render_details(renderers.codex, block, {
        width = width,
        spinner = "*",
        tool = tool,
      })), renderers.codex.theme, width).lines
    end

    local narrow_edit = details_lines(edit_block, edit_tool, 24)
    local wide_edit = details_lines(edit_block, edit_tool, 80)
    assert.are.same(wide_edit, narrow_edit)
    assert.is_true(vim.tbl_contains(narrow_edit, "   1 +" .. edit_line))

    local narrow_plan = details_lines(plan_block, plan_tool, 24)
    local wide_plan = details_lines(plan_block, plan_tool, 80)
    assert.are.same(wide_plan, narrow_plan)
    assert.is_true(vim.tbl_contains(narrow_plan, "   └ " .. explanation))
    assert.is_true(vim.tbl_contains(narrow_plan, "     □ " .. step))
  end)

  it("keeps unsupported images searchable through fixed fallback text", function()
    local text = rendered(renderers.pi, {
      key = "image-block",
      kind = "user",
      text = "attached",
      content = {
        { type = "image", mimeType = "image/jpeg", data = "not-png" },
        { type = "image", mimeType = "image/jpeg",
          data = vim.base64.encode(string.rep("x", 2 * 1024)) },
        { type = "image", mimeType = "image/jpeg",
          data = vim.base64.encode(string.rep("x", 2 * 1024 * 1024)) },
      },
    }, { width = 40, spinner = "*" })
    assert.matches("Image · JPEG", text)
    assert.matches("2.0 KiB", text)
    assert.matches("2.0 MiB", text)
  end)

  it("emits native image nodes for raw and encoded PNG attachments", function()
    local landscape = png(160, 80)
    local encoded = assert(vim.base64.encode(landscape))
    local cases = {
      {
        key = "raw-image",
        kind = "user",
        text = "raw attachment",
        content = { { type = "image", mimeType = "image/png", data = landscape } },
      },
      {
        key = "encoded-image",
        kind = "tool",
        state = "success",
        call = { name = "read_file", arguments = {} },
        message = {
          toolName = "read_file",
          content = { { type = "image", mimeType = "image/png", data = encoded } },
        },
      },
      {
        key = "untyped-image",
        kind = "user",
        text = "untyped attachment",
        content = { { type = "image", data = landscape } },
      },
    }
    for _, block in ipairs(cases) do
      local node = assert(protocol.render_block(renderers.pi, block, {
        width = 40,
        spinner = "*",
      }))
      local image = assert(find_node(node, "image"))
      assert.are.equal("fill", image.width)
      assert.are.equal("auto", image.height)
      assert.are.equal(12, image.max_height)
      assert.are.equal("contain", image.fit)
      assert.are.equal("left", image.align)
      local source = require("applet.image.source")
      local identity = source.identity(image.source)
      local info = source.png_info(image.source.data)
      local value = assert(Applet.Pane.compile({
        tree = node,
        width = 40,
        theme = renderers.pi.theme,
        images = {
          status = "available",
          generation = 1,
          cell_width = 1,
          cell_height = 2,
          resources = { [identity] = {
            id = identity,
            width = info.width,
            height = info.height,
          } },
        },
      }))
      assert.matches("Image · PNG", table.concat(value.lines, "\n"))
      assert.not_matches("image attachment", table.concat(value.lines, "\n"))
      local placed = assert(next(value.images))
      assert.are.equal(1, value.images[placed].col)
      assert.are.equal(39, value.images[placed].width)
    end

    local portrait = {
      key = "portrait-image",
      kind = "user",
      text = "portrait attachment",
      content = {
        { type = "image", mimeType = "image/png", data = png(40, 160) },
      },
    }
    local transcript = assert(protocol.render_block(renderers.pi, portrait, {
      width = 40,
      spinner = "*",
    }))
    local transcript_image = assert(find_node(transcript, "image"))
    assert.are.equal("auto", transcript_image.height)
    assert.are.equal(12, transcript_image.max_height)
    assert.are.equal("contain", transcript_image.fit)
    local details = assert(protocol.render_details(renderers.pi, portrait, {
      width = 40,
      spinner = "*",
    }))
    local details_image = assert(find_node(details, "image"))
    assert.are.equal("native", details_image.width)
    assert.are.equal("auto", details_image.height)
    assert.is_nil(details_image.max_height)
    assert.are.equal("contain", details_image.fit)
    assert.are.equal("center", details_image.align)
    assert.matches("portrait attachment", table.concat(
      layout(details, renderers.pi.theme, 40).lines, "\n"))
  end)

  it("keeps semantic image slots stable and resource identities collision-safe", function()
    local data = png(16, 8)
    local function rendered_image(block)
      return assert(find_node(assert(protocol.render_block(renderers.pi, block, {
        width = 40,
        spinner = "*",
      })), "image"))
    end
    local first = rendered_image({
      key = "preview-card",
      kind = "user",
      image_scope = "conversation",
      content = {
        { type = "text", text = "before" },
        { type = "image", mimeType = "image/png", data = data,
          id = "preview", revision = 9 },
      },
    })
    local reordered = rendered_image({
      key = "preview-card",
      kind = "user",
      image_scope = "conversation",
      content = {
        { type = "image", mimeType = "image/png", data = data,
          id = "preview", revision = 9 },
        { type = "text", text = "after" },
      },
    })
    assert.are.equal(first.key, reordered.key)
    assert.are.equal(first.source.id, reordered.source.id)
    assert.are.equal(9, first.source.revision)

    local left = rendered_image({
      key = "c",
      kind = "user",
      image_scope = "a:b",
      content = { { type = "image", mimeType = "image/png", data = data,
        id = "slot", revision = 1 } },
    })
    local right = rendered_image({
      key = "b:c",
      kind = "user",
      image_scope = "a",
      content = { { type = "image", mimeType = "image/png", data = data,
        id = "slot", revision = 1 } },
    })
    assert.are_not.equal(left.source.id, right.source.id)
  end)

  it("selects final, transient, and direct image content in lifecycle order", function()
    local function image(block)
      return find_node(assert(protocol.render_block(renderers.pi, block, {
        width = 40,
        spinner = "*",
      })), "image")
    end
    local block = {
      key = "animated-tool",
      kind = "tool",
      state = "running",
      call = { name = "animate", arguments = {} },
      content = { {
        type = "image",
        mimeType = "image/png",
        data = png(10, 10),
        id = "preview",
        revision = 1,
      } },
      update = { content = { {
        type = "image",
        mimeType = "image/png",
        data = png(20, 20),
        id = "preview",
        revision = 2,
      } } },
    }

    local transient = assert(image(block))
    assert.are.equal(2, transient.source.revision)
    assert.are.equal(20,
      require("applet.image.source").png_info(transient.source.data).width)

    block.message = { content = { {
      type = "image",
      mimeType = "image/png",
      data = png(30, 30),
      id = "preview",
      revision = 3,
    } } }
    local final = assert(image(block))
    assert.are.equal(3, final.source.revision)
    assert.are.equal(30,
      require("applet.image.source").png_info(final.source.data).width)

    block.message = { content = { { type = "text", text = "complete" } } }
    assert.is_nil(image(block))
  end)

  it("keeps transcript image rows inside their owning card target", function()
    local data = png(160, 80)
    local node = assert(protocol.render_block(renderers.pi, {
      key = "read-image-target",
      kind = "tool",
      state = "success",
      call = { name = "read_file", arguments = { path = "image.png" } },
      message = {
        toolName = "read_file",
        content = { { type = "image", mimeType = "image/png", data = data } },
      },
    }, {
      width = 40,
      surface_width = 42,
      details_key = "<CR>",
    }))
    local image_node = assert(find_node(node, "image"))
    local identity = require("applet.image.source").identity(image_node.source)
    local value = assert(Applet.Pane.compile({
      tree = node,
      width = 40,
      theme = renderers.pi.theme,
      images = {
        status = "available",
        generation = 1,
        cell_width = 1,
        cell_height = 2,
        resources = { [identity] = {
          id = identity,
          width = 160,
          height = 80,
        } },
      },
    }))
    local _, image = next(value.images)
    assert.is_table(image)
    local target = require("applet.pane.input").target_at(
      value, image.row, image.col)
    assert.are.equal("card:read-image-target", target and target.key)
    assert.are.equal("transcript.details", target and target.action.action)
    assert.are.equal("read-image-target", target.action.payload.block)
  end)

  it("renders semantic tool plans, edits, activities, and fallbacks", function()
    local function tool(selected, semantic, width, state)
      return rendered(selected, {
        key = "semantic-tool",
        kind = "tool",
        state = state or "success",
        call = { name = "semantic", arguments = {} },
        message = {
          toolName = "semantic",
          content = { { type = "text", text = "ordinary fallback" } },
        },
      }, {
        width = width or 40,
        spinner = "*",
        details_key = "<CR>",
        tool = { name = "semantic", render = function() return semantic end },
      })
    end

    local plan = tool(renderers.codex, {
      kind = "plan",
      explanation = "A deliberately long explanation",
      plan = { { step = "Completed step", status = "completed" } },
    }, 30)
    assert.matches("A deliberately long", plan)
    assert.matches("Completed step", plan)

    local empty_plan = tool(renderers.pi, {
      kind = "plan",
      plan = {},
    })
    assert.matches("no steps provided", empty_plan)

    local pending_plan = tool(renderers.codex, {
      kind = "plan",
      plan = {
        { step = "Pending step", status = "pending" },
        { step = "Active step", status = "in_progress" },
      },
    })
    assert.matches("Pending step", pending_plan)
    assert.matches("Active step", pending_plan)

    local updating_plan = tool(renderers.codex, {
      kind = "plan",
    }, nil, "running")
    assert.matches("Updating plan", updating_plan)

    local edit = tool(renderers.codex, {
      kind = "edit",
      path = "narrow.lua",
      rows = {
        { kind = "context", number = 1, text = "one" },
        { kind = "delete", number = 2, text = "old" },
        { kind = "add", number = 2, text = "new" },
      },
    }, 32)
    assert.matches("narrow.lua", edit)
    assert.matches("new", edit)

    local overflowing_rows = { { kind = "separator" }, {
      kind = "add", number = 1, text = string.rep("x", 500),
    } }
    for index = 1, 12 do
      overflowing_rows[#overflowing_rows + 1] = {
        kind = "add",
        number = index,
        text = string.rep(tostring(index % 10), 50),
      }
    end
    overflowing_rows[#overflowing_rows + 1] = { kind = "separator" }
    local overflowing = tool(renderers.codex, {
      kind = "edit",
      path = "overflow.lua",
      rows = overflowing_rows,
    }, 24)
    assert.matches("more line", overflowing)

    local activity = tool(renderers.codex, {
      kind = "activity",
      operation = "read",
      ongoing = "Reading",
      complete = "Read",
      subject = "lua/neoagent/ui.lua",
    })
    assert.matches("ui.lua", activity)

    for _, malformed in ipairs({
      { kind = "activity", operation = "read", ongoing = "Reading" },
      { kind = "plan", explanation = {}, plan = {} },
      { kind = "edit", path = "bad.lua", rows = {
        { kind = "add", number = "one", text = "bad" },
      } },
    }) do
      assert.matches("ordinary fallback", tool(renderers.codex, malformed))
    end
  end)

  it("falls back from malformed policy presentations", function()
    local function fallback(presentation)
      local content = require("neoagent.ui.render").block({
        policy = {
          plain_output_group = function() return "NeoagentToolOutput" end,
          present_tool = function() return presentation end,
          separator = function() end,
          tool_background = function() end,
          tool_title = function(parts) return parts end,
        },
        config = { mappings = {} },
        resolve_tool = function()
          return { render = function() return {} end }
        end,
        spinner_frames = { "*" },
        spinner_frame = 1,
        _content_width = function() return 40 end,
      }, {
        key = "malformed-presentation",
        kind = "tool",
        state = "success",
        call = { name = "semantic", arguments = {} },
        message = {
          toolName = "semantic",
          content = { { type = "text", text = "ordinary fallback" } },
        },
      }, {})
      assert.matches("ordinary fallback", table.concat(content.lines, "\n"))
    end

    fallback({ title = { { text = 1 } } })
    fallback({ title = { { text = "invalid style", style = false } } })
    fallback({ title = true, status = "success" })
  end)

  it("renders partial write content and complete details", function()
    for _, block in ipairs({
      {
        key = "pending-write",
        kind = "tool",
        name = "write_file",
        state = "pending",
        raw = '{"content":"new content","path":"',
      },
      {
        key = "running-write",
        kind = "tool",
        name = "write_file",
        state = "running",
        call = {
          name = "write_file",
          arguments = { path = "", content = "new content" },
        },
      },
    }) do
      assert.matches("new content", rendered(renderers.codex, block, {
        width = 40,
        spinner = "*",
        details_key = "<CR>",
      }))
    end

    local details = assert(protocol.render_details(renderers.pi, {
      key = "shell",
      kind = "tool",
      state = "success",
      call = { name = "shell", arguments = {
        command = "printf a very long command that remains available in details",
      } },
      message = { toolName = "shell", isError = false,
        content = { { type = "text", text = "complete output" } } },
    }, { width = 30, spinner = "*" }))
    local text = table.concat(layout(details, renderers.pi.theme, 30).lines, "\n")
    assert.matches("very long command", text)
    assert.matches("complete output", text)
  end)

  it("renders physical shell command newlines in card details", function()
    local details = assert(protocol.render_details(renderers.codex, {
      key = "multiline-shell-details",
      kind = "tool",
      state = "running",
      call = { name = "shell", arguments = {
        command = table.concat({
          "printf 'literal\\n'",
          "printf second-line",
          "printf third-line",
          "printf fourth-line",
        }, "\n"),
      } },
    }, {
      width = 80,
      spinner = "*",
      tool = require("neoagent.tools.shell").new(),
    }))

    assert.are.same({
      "• Running printf 'literal\\n'",
      "  │ printf second-line",
      "  │ printf third-line",
      "  │ printf fourth-line",
    }, layout(details, renderers.codex.theme, 80).lines)
  end)

  it("separates Codex tool headings and commands from their bodies", function()
    local cases = {
      {
        tool = require("neoagent.tools.write_file").new(),
        header_end = "Written write.lua",
        body = "return true",
        block = {
          key = "spaced-write",
          kind = "tool",
          state = "success",
          call = { name = "write_file", arguments = {
            path = "write.lua",
            content = "return true",
          } },
          message = {
            toolName = "write_file",
            isError = false,
            content = { { type = "text", text = "wrote write.lua" } },
          },
        },
      },
      {
        tool = require("neoagent.tools.edit_file").new(),
        header_end = "Edited edit.lua",
        body = "-old",
        block = {
          key = "spaced-edit",
          kind = "tool",
          state = "success",
          call = { name = "edit_file", arguments = {
            path = "edit.lua",
            edits = {},
          } },
          message = {
            toolName = "edit_file",
            isError = false,
            content = { { type = "text", text = "edited edit.lua" } },
            details = { patch = "@@ -1 +1 @@\n-old\n+new" },
          },
        },
      },
      {
        tool = require("neoagent.tools.shell").new(),
        header_end = "printf second-command",
        body = "command-output",
        block = {
          key = "spaced-shell",
          kind = "tool",
          state = "success",
          call = { name = "shell", arguments = {
            command = "printf first-command\nprintf second-command",
          } },
          message = {
            toolName = "shell",
            isError = false,
            content = { { type = "text", text = "command-output" } },
          },
        },
      },
    }

    local function row_containing(lines, text)
      for index, line in ipairs(lines) do
        if line:find(text, 1, true) then return index end
      end
    end

    for _, case in ipairs(cases) do
      for _, surface in ipairs({ "transcript", "details" }) do
        local render = surface == "transcript"
            and protocol.render_block or protocol.render_details
        local node = assert(render(renderers.codex, case.block, {
          width = 80,
          spinner = "*",
          tool = case.tool,
        }))
        local lines = layout(node, renderers.codex.theme, 80).lines
        local header = assert(row_containing(lines, case.header_end))
        local body = assert(row_containing(lines, case.body))
        assert.are.equal(header + 2, body,
          surface .. " " .. case.block.key)
        assert.is_nil(lines[header + 1]:find("%S"))
      end
    end
  end)

  it("converts rich line metadata into native ranges", function()
    local tree = require("neoagent.ui.tree")
    local node = tree.content("converted", {
      lines = { "abc", "def", "tail" },
      highlights = {
        { row = 0, col = 0, end_col = 1, group = "String" },
        { row = 0, col = 1, end_col = 2, group = "String" },
      },
      line_groups = { [0] = "NormalFloat" },
      source = { path = "example.lua", first = 0, last = 1 },
      card = { first = 0, last = 1 },
    }, {
      target_key = "converted:target",
      action = ui.action("converted.open"),
    })
    local value = layout(node, renderers.pi.theme, 20)
    assert.are.same({ "abc", "def", "tail" }, value.lines)
    assert.is_not_nil(value.targets["converted:target"])
    assert.are.equal("example.lua", value.source_ranges[1].path)

    local attached = layout(tree.content("standalone", {
      lines = { "body" },
      highlights = {},
      line_groups = {},
    }, {
      attachments = {
        ui.text({ key = "standalone:attachment", text = "attachment" }),
      },
    }), renderers.pi.theme, 20)
    assert.is_true(vim.tbl_contains(attached.lines, "body"))
    assert.is_true(vim.tbl_contains(attached.lines, "attachment"))
  end)

  it("packs expanded Markdown at soft semantic boundaries", function()
    local markdown = require("neoagent.markdown")
    local tree = require("neoagent.ui.tree")
    local prose = {}
    for index = 1, 130 do
      prose[index] = "prose line " .. index .. " with **emphasis**"
    end
    local content = markdown.render(table.concat(prose, "\n"))
    local node = tree.content("partitioned", content, {
      wrap = "native",
      partition_rows = 64,
    })
    assert.are.equal(3, #node.children)
    for _, child in ipairs(node.children) do
      assert.are.equal("region", child.type)
    end
    local partitioned = layout(node, renderers.pi.theme, 40)
    local implicit = layout(tree.content("implicit", content, {
      wrap = "native",
    }), renderers.pi.theme, 40)
    assert.are.same(content.lines, partitioned.lines)
    assert.are.same(implicit.decorations, partitioned.decorations)

    local separated = {}
    for index = 1, 50 do separated[index] = "first block " .. index end
    separated[51] = ""
    for index = 52, 71 do separated[index] = "second block " .. index end
    local separated_content = markdown.render(table.concat(separated, "\n"))
    local separated_layout = layout(tree.content(
      "separated", separated_content, {
        wrap = "native",
        partition_rows = 64,
      }), renderers.pi.theme, 40)
    assert.are.same({ 51, 20 }, vim.tbl_map(function(region)
      return region.last - region.first
    end, separated_layout.regions))

    local table_source = { "| Value |", "| --- |" }
    for index = 1, 80 do
      table_source[#table_source + 1] = "| row " .. index .. " |"
    end
    local rendered_table = markdown.render(
      table.concat(table_source, "\n"), { width = 40 })
    local table_node = tree.content("table", rendered_table, {
      wrap = "native",
      partition_rows = 64,
    })
    assert.are.equal(1, #table_node.children)
    assert.are.equal("region", table_node.children[1].type)
    assert.are.same(rendered_table.lines,
      layout(table_node, renderers.pi.theme, 40).lines)
  end)

  it("rejects malformed Markdown partitions at the Tree boundary", function()
    local markdown = require("neoagent.markdown")
    local tree = require("neoagent.ui.tree")
    local function fails(callback, message)
      local ok, err = pcall(callback)
      assert.is_false(ok)
      assert.matches(message, err)
    end

    fails(function()
      tree.content("invalid-target", markdown.render("line"), {
        partition_rows = 0,
      })
    end, "partition_rows must be a positive integer")
    fails(function()
      tree.content("invalid-start", {
        lines = { "first", "second" },
        highlights = {},
        markdown_blocks = {
          { first = 1, last = 2, splittable = true },
        },
      }, { partition_rows = 1 })
    end, "Markdown block ranges must cover rendered lines in order")
    fails(function()
      tree.content("incomplete-ranges", {
        lines = { "first", "second" },
        highlights = {},
        markdown_blocks = {
          { first = 0, last = 1, splittable = true },
        },
      }, { partition_rows = 1 })
    end, "Markdown block ranges must cover rendered lines in order")

    local document = markdown.new():update("line")
    fails(function()
      tree.retained_markdown("invalid-retained-target", {
        markdown_document = document,
      }, { partition_rows = 0 })
    end, "partition_rows must be a positive integer")
  end)

  it("preserves retained Markdown styling beside attachments", function()
    local markdown = require("neoagent.markdown")
    local tree = require("neoagent.ui.tree")
    local view = {
      markdown_document = markdown.new():update("**styled**"),
      markdown_groups = { "NeoagentThinking" },
    }
    local opts = {
      partition_rows = 64,
      line_group = "NeoagentUserBackground",
    }
    local retained = tree.retained_markdown("styled-retained", view, opts)
    local attached = tree.retained_markdown("styled-attached", view,
      vim.tbl_extend("force", opts, {
        attachments = {
          ui.text({ key = "styled-attachment", text = "attachment" }),
        },
      }))
    local retained_layout = layout(retained, renderers.pi.theme, 40)
    local attached_layout = layout(attached, renderers.pi.theme, 40)

    assert.are.same({ "styled" }, retained_layout.lines)
    assert.are.same({ "styled", "", "attachment" }, attached_layout.lines)
    assert.are.same(retained_layout.decorations,
      attached_layout.decorations)
  end)

  it("reuses completed subdivisions of an incomplete Markdown block", function()
    local markdown = require("neoagent.markdown")
    local tree = require("neoagent.ui.tree")
    local cache = {}
    local stats = { region_compilations = 0, region_reuses = 0 }
    local function document(count)
      local source = { "```lua" }
      for index = 1, count do source[#source + 1] = "value " .. index end
      return tree.content("incomplete-fence",
        markdown.render(table.concat(source, "\n")), {
          wrap = "native",
          partition_rows = 64,
        })
    end
    local first = Applet.Pane.compile({
      tree = document(130),
      width = 40,
      theme = renderers.pi.theme,
      cache = cache,
      stats = stats,
    })
    assert.are.equal("```", first.lines[#first.lines])
    local before = vim.deepcopy(stats)
    local second = Applet.Pane.compile({
      tree = document(131),
      width = 40,
      theme = renderers.pi.theme,
      cache = cache,
      stats = stats,
    })
    assert.are.equal("```", second.lines[#second.lines])
    assert.are.equal(before.region_compilations + 1,
      stats.region_compilations)
    assert.are.equal(before.region_reuses + 2, stats.region_reuses)
  end)

  it("builds native assistant and compact-tool focus decorations", function()
    local tree = require("neoagent.ui.tree")
    local response = assert(tree.focus({ kind = "assistant" }, {
      lines = { "", "" },
      card = { first = 0, last = 0, after = 1 },
    }, {
      width = 40,
      details_key = "<CR>",
      focus = {},
    }))
    local response_text, response_bottom = {}, nil
    for _, decoration in ipairs(response.active) do
      for _, chunk in ipairs(decoration.chunks) do
        response_text[#response_text + 1] = chunk.text
        if chunk.text:find("to expand", 1, true) then
          response_bottom = decoration.row
        end
      end
    end
    local assistant_focus = table.concat(response_text)
    assert.matches("to expand", assistant_focus)
    assert.is_nil(assistant_focus:find("word", 1, true))
    assert.are.equal(1, response_bottom)

    local compact = assert(tree.focus({ kind = "tool" }, {
      lines = { "tool" },
      card = { first = 0, last = 0 },
    }, {
      width = 40,
      details_key = "<CR>",
      focus = { inline_single_line_tool_hint = true },
    }))
    local compact_text = {}
    for _, decoration in ipairs(compact.active) do
      for _, chunk in ipairs(decoration.chunks) do
        compact_text[#compact_text + 1] = chunk.text
      end
    end
    assert.matches("to expand", table.concat(compact_text))
  end)

  it("bounds thinking focus chrome across constrained rows", function()
    local tree = require("neoagent.ui.tree")
    local function chunks(value)
      local result = {}
      for _, decoration in ipairs(value.active) do
        for _, chunk in ipairs(decoration.chunks) do
          result[#result + 1] = chunk.text
        end
      end
      return result
    end

    local default = assert(tree.focus({ kind = "thinking" }, {
      lines = { "trace" },
      card = { first = 0, last = 0 },
    }, {
      width = 80,
      details_key = "<CR>",
      focus = {},
    }))
    assert.matches("thinking: 0 words, <CR> to expand",
      table.concat(chunks(default)))

    local narrow = assert(tree.focus({ kind = "thinking" }, {
      lines = { "trace" },
      card = { first = 0, last = 0 },
    }, {
      width = 8,
      focus = { header = "a deliberately long header" },
    }))
    assert.is_true(vim.tbl_contains(chunks(narrow), "...ader"))

    local tiny = assert(tree.focus({ kind = "thinking" }, {
      lines = { "trace" },
      card = { first = 0, last = 0 },
    }, {
      width = 3,
      focus = { header = "header" },
    }))
    assert.is_true(vim.tbl_contains(chunks(tiny), "er"))

    local empty_bottom = assert(tree.focus({ kind = "thinking" }, {
      lines = { "trace", "" },
      card = { first = 0, last = 1 },
    }, {
      width = 10,
      focus = { header = "trace" },
    }))
    assert.is_true(vim.tbl_contains(chunks(empty_bottom), "╰────────╯"))

    local attached = assert(tree.focus({ kind = "thinking" }, {
      lines = { "trace", "tail" },
      card = { first = 0, last = 1 },
    }, {
      width = 10,
      attachments = true,
      focus = { header = "trace" },
    }))
    assert.is_true(vim.tbl_contains(chunks(attached), "╰────────╯"))
    assert.are.equal("end", attached.active[#attached.active].row)

    local overflow = assert(tree.focus({ kind = "thinking" }, {
      lines = { "trace", "a tail wider than the card" },
      card = { first = 0, last = 1 },
    }, {
      width = 10,
      focus = { header = "trace" },
    }))
    assert.are.equal(2, overflow.active[#overflow.active].row)
  end)
end)
