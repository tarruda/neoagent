local protocol = require("neoagent.ui.renderer")

local function content(lines)
  return {
    lines = lines or { "content" },
    highlights = {},
    line_groups = {},
  }
end

local function renderer(overrides)
  return vim.tbl_extend("force", {
    name = "custom",
    render_block = function() return content() end,
    render_details = function() return nil end,
    render_dialog = function()
      return { content = content({ "dialog" }) }
    end,
  }, overrides or {})
end

describe("neoagent UI Renderer protocol", function()
  it("validates explicit Renderer values and bundled compositions", function()
    local renderers = require("neoagent.ui.renderers")
    assert.are.equal(renderers.pi, protocol.validate(renderers.pi))
    assert.are.equal(renderers.codex, renderers.get("codex"))
    assert.are.same({ "pi", "codex" }, renderers.names())
    assert.is_nil(renderers.get("unknown"))

    local invalid = {
      false,
      {},
      { name = 1 },
      { name = "missing" },
      renderer({ render_details = "invalid" }),
      renderer({ define_highlights = true }),
      renderer({ render_focus = true }),
      renderer({ render_status = true }),
    }
    for _, value in ipairs(invalid) do
      local selected, err = protocol.validate(value)
      assert.is_nil(selected)
      assert.are.equal("ui", err.kind)
    end
    local ok, err = pcall(protocol.assert, {}, "configured Renderer")
    assert.is_false(ok)
    assert.matches("configured Renderer", err)
  end)

  it("passes copied semantic inputs and returns copied presentations", function()
    local seen, produced
    local selected = renderer({
      render_block = function(_, block, opts)
        seen = { block = block, opts = opts }
        block.call.arguments.value = 2
        opts.previous.text = "changed"
        opts.tool.name = "changed"
        produced = {
          lines = { "hello", "" },
          highlights = { {
            row = 0,
            col = 0,
            end_col = 5,
            group = "NeoagentAccent",
            priority = 101,
          } },
          line_groups = { [0] = "NeoagentUserBackground" },
          card = { first = 0, last = 0, after = 1 },
          separators = { after = 1 },
          source = { path = "hello.lua", first = 0, last = 0 },
          animated = true,
          background = "NeoagentToolBackground",
          focus = {
            header = "header",
            resting_header = "resting",
            overflow = false,
            inline_multiline_tool_outline = true,
            inline_single_line_tool_hint = false,
          },
        }
        return produced
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
    local presentation = assert(protocol.render_block(selected, block, opts))
    assert.are.equal(1, block.call.arguments.value)
    assert.are.equal("before", opts.previous.text)
    assert.are.equal("shell", opts.tool.name)
    assert.is_nil(seen.block.dirty)
    assert.is_nil(seen.block.mark)
    assert.is_nil(seen.opts.previous.dirty)
    assert.are.equal("after", seen.opts.following.text)
    presentation.lines[1] = "changed"
    assert.are.equal("hello", produced.lines[1])
  end)

  it("rejects exceptions and malformed content before drawing", function()
    local outputs = {
      false,
      {},
      { lines = { true }, highlights = {}, line_groups = {} },
      { lines = { "two\nlines" }, highlights = {}, line_groups = {} },
      { lines = { "x" }, highlights = false, line_groups = {} },
      { lines = { "x" }, highlights = {}, line_groups = false },
      { lines = { "x" }, highlights = { true }, line_groups = {} },
      { lines = { "x" }, highlights = {
        { row = 0, col = 0, end_col = 1, group = "Group", priority = -1 },
      }, line_groups = {} },
      { lines = { "x" }, highlights = {}, line_groups = { [1] = "Group" } },
      { lines = { "x" }, highlights = {}, line_groups = {},
        card = { first = 0, last = 1 } },
      { lines = { "x" }, highlights = {}, line_groups = {}, separators = false },
      { lines = { "x" }, highlights = {}, line_groups = {},
        separators = { middle = 0 } },
      { lines = { "x" }, highlights = {}, line_groups = {},
        source = { path = "", first = 0, last = 0 } },
      { lines = { "x" }, highlights = {}, line_groups = {}, animated = 1 },
      { lines = { "x" }, highlights = {}, line_groups = {}, background = false },
      { lines = { "x" }, highlights = {}, line_groups = {},
        focus = { header = true } },
    }
    for index = 1, #outputs do
      local _, err = protocol.render_block(renderer({
        render_block = function() return outputs[index] end,
      }), { kind = "notice" }, {})
      assert.is_table(err)
      assert.are.equal("ui", err.kind)
    end

    local _, thrown = protocol.render_block(renderer({
      render_block = function() error("renderer exploded") end,
    }), { kind = "notice" }, {})
    assert.matches("renderer exploded", thrown.message)
    assert.is_nil(protocol.render_details(renderer(), { kind = "notice" }, {}))
  end)

  it("validates dialogs and isolates highlight setup failures", function()
    local snapshot = { active = { title = "Question" }, queue_count = 0 }
    local seen
    local selected = renderer({
      render_dialog = function(_, value, opts)
        seen = { value = value, opts = opts }
        value.active.title = "changed"
        opts.width = 1
        return { content = content({ "prompt" }), title = " Prompt " }
      end,
    })
    local opts = { surface = "float", width = 80 }
    local result = assert(protocol.render_dialog(selected, snapshot, opts))
    assert.are.equal(" Prompt ", result.title)
    assert.are.equal("Question", snapshot.active.title)
    assert.are.equal(80, opts.width)
    assert.are.equal(1, seen.opts.width)

    for _, value in ipairs({
      false,
      { content = content(), title = true },
      { content = content(), title = "two\nlines" },
    }) do
      local _, err = protocol.render_dialog(renderer({
        render_dialog = function() return value end,
      }), snapshot, {})
      assert.is_table(err)
    end
    local _, thrown = protocol.render_dialog(renderer({
      render_dialog = function() error("dialog exploded") end,
    }), snapshot, {})
    assert.matches("dialog exploded", thrown.message)

    assert.is_true(protocol.define_highlights(renderer()))
    assert.is_true(protocol.define_highlights(renderer({
      define_highlights = function() end,
    })))
    local defined, define_err = protocol.define_highlights(renderer({
      define_highlights = function() error("highlight exploded") end,
    }))
    assert.is_nil(defined)
    assert.matches("highlight exploded", define_err.message)
  end)

  it("validates optional status and focus presentations", function()
    assert.is_nil(protocol.render_status(renderer(), { steering = {} }, {}))
    assert.are.same({}, protocol.render_focus(
      renderer(), { kind = "assistant" }, { lines = { "text" } }))

    local status = { steering = { "queued" } }
    local focus_opts = { lines = { "text" }, width = 20 }
    local selected = renderer({
      render_status = function(_, value, opts)
        value.steering[1] = "changed"
        opts.key = "changed"
        return { lines = { "queued" } }
      end,
      render_focus = function(_, block, opts)
        block.text = "changed"
        opts.lines[1] = "changed"
        return { {
          row = 0,
          chunks = { { text = "badge", group = "NeoagentMuted" } },
          position = "overlay",
          win_col = 2,
          priority = 200,
        } }
      end,
    })
    assert.are.same({
      lines = { "queued" }, highlights = {}, line_groups = {},
    }, protocol.render_status(selected, status, { key = "original" }))
    assert.are.equal("queued", status.steering[1])
    local decorations = assert(protocol.render_focus(selected, {
      kind = "assistant", text = "original",
    }, focus_opts))
    assert.are.equal("badge", decorations[1].chunks[1].text)
    assert.are.equal("text", focus_opts.lines[1])

    for _, value in ipairs({
      false,
      { { row = 1, chunks = { { text = "x", group = "Group" } } } },
      { { row = 0, chunks = {}, position = "unknown" } },
      { { row = 0, chunks = { { text = "x\n", group = "Group" } } } },
      { { row = 0, chunks = { { text = "x", group = "" } } } },
    }) do
      local _, err = protocol.render_focus(renderer({
        render_focus = function() return value end,
      }), { kind = "assistant" }, { lines = { "text" } })
      assert.is_table(err)
    end
    local _, focus_err = protocol.render_focus(renderer({
      render_focus = function() error("focus exploded") end,
    }), { kind = "assistant" }, { lines = { "text" } })
    assert.matches("focus exploded", focus_err.message)
    local _, status_err = protocol.render_status(renderer({
      render_status = function() error("status exploded") end,
    }), { steering = {} }, {})
    assert.matches("status exploded", status_err.message)
  end)

  it("renders bundled semantic tools across narrow layout boundaries", function()
    local renderers = require("neoagent.ui.renderers")

    local function tool(renderer_value, semantic, width)
      return assert(protocol.render_block(renderer_value, {
        kind = "tool",
        state = "success",
        call = { name = "semantic", arguments = {} },
        message = {
          toolName = "semantic",
          content = { { type = "text", text = "ordinary fallback" } },
        },
      }, {
        width = width or 20,
        spinner = "*",
        details_key = "<CR>",
        tool = {
          name = "semantic",
          render = function() return semantic end,
        },
      }))
    end

    local empty_plan = tool(renderers.codex, {
      kind = "plan",
      explanation = "A deliberately long explanation",
      plan = {},
    }, 30)
    assert.matches("A deliberately long", table.concat(empty_plan.lines, "\n"))
    assert.matches("%(no steps provided%)", table.concat(empty_plan.lines, "\n"))

    local pi_plan = tool(renderers.pi, {
      kind = "plan",
      plan = { {
        step = "A completed step that wraps",
        status = "completed",
      } },
    }, 24)
    assert.matches("%[x%] A", table.concat(pi_plan.lines, "\n"))
    assert.matches("completed", table.concat(pi_plan.lines, "\n"))

    local rows = {
      { kind = "context", number = 1, text = "one" },
      { kind = "separator" },
    }
    for number = 2, 8 do
      rows[#rows + 1] = {
        kind = "context", number = number, text = tostring(number),
      }
    end
    rows[#rows + 1] = {
      kind = "add", number = 9,
      text = "a line that wraps into several preview rows",
    }
    rows[#rows + 1] = { kind = "separator" }
    rows[#rows + 1] = { kind = "delete", number = 10, text = "omitted" }
    local edit = tool(renderers.codex, {
      kind = "edit", path = "narrow.lua", rows = rows,
    }, 24)
    local edit_text = table.concat(edit.lines, "\n")
    assert.matches("⋮", edit_text)
    assert.matches("more lines", edit_text)

    for _, malformed in ipairs({
      { kind = "activity", operation = "read" },
      { kind = "plan", explanation = {}, plan = {} },
      { kind = "edit", path = "bad.lua", rows = {
        { kind = "add", number = "one", text = "bad" },
      } },
    }) do
      assert.matches("ordinary fallback",
        table.concat(tool(renderers.codex, malformed).lines, "\n"))
    end
  end)

  it("derives default focus badges and merges adjacent virtual chunks", function()
    local renderers = require("neoagent.ui.renderers")
    local decorations = assert(protocol.render_focus(renderers.pi, {
      kind = "assistant",
    }, {
      active = true,
      lines = { "answer" },
      width = 40,
      card = { first = 0, last = 0 },
      focus = {},
      details_key = "<CR>",
    }))
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(decoration)
      return decoration.chunks[1].text
    end, decorations), "[text: 0 words, <CR> to expand]"))

    local chunks = require("neoagent.ui.presentation").virtual_lines({
      lines = { "abc" },
      highlights = {
        { row = 0, col = 0, end_col = 1, group = "Accent" },
        { row = 0, col = 1, end_col = 2, group = "Accent" },
      },
      line_groups = {},
    })
    assert.are.same({ { { "ab", "Accent" }, { "c", "NormalFloat" } } }, chunks)
  end)

  it("renders write previews while the streamed path is incomplete", function()
    local renderers = require("neoagent.ui.renderers")
    local blocks = {
      {
        kind = "tool",
        name = "write_file",
        state = "pending",
        raw = '{"content":"new content","path":"',
      },
      {
        kind = "tool",
        name = "write_file",
        state = "running",
        call = {
          name = "write_file",
          arguments = { path = "", content = "new content" },
        },
      },
    }
    for _, block in ipairs(blocks) do
      local content, err = protocol.render_block(renderers.codex, block, {
        width = 40,
        spinner = "*",
        details_key = "<CR>",
      })
      assert.is_nil(err)
      assert.matches("new content", table.concat(content.lines, "\n"))
      assert.is_nil(content.source)
    end
  end)
end)
