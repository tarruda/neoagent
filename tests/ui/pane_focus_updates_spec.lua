local assert = require("luassert")
local Applet = require("applet")
local input = require("applet.pane.input")
local ui = Applet.Pane.nodes

describe("Pane focus updates", function()
  local set_extmark = vim.api.nvim_buf_set_extmark
  local focus_target = input.focus_target
  local ambiwidth = vim.o.ambiwidth
  local cellwidths = vim.fn.getcellwidths()
  ---@type Applet.Pane?
  local pane
  ---@type integer?
  local window

  after_each(function()
    vim.api.nvim_buf_set_extmark = set_extmark
    input.focus_target = focus_target
    if pane then
      pane:destroy()
    end
    if window and vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
    pane, window = nil, nil
    vim.o.ambiwidth = ambiwidth
    vim.fn.setcellwidths(cellwidths)
  end)

  ---@param buffer_mode? 'managed'|'editable'
  local function mount(buffer_mode)
    local buffer = vim.api.nvim_create_buf(false, true)
    local selected = vim.api.nvim_open_win(buffer, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 40,
      height = 8,
      style = "minimal",
      border = "single",
    })
    window = selected
    local value = Applet.Pane.new({ key = "focus-updates", buffer_mode = buffer_mode })
    pane = value
    value:_connect({
      buffer = buffer,
      window = function()
        return selected
      end,
      owns_buffer = true,
      buffer_options = { buftype = "nofile" },
      window_options = { wrap = false },
    })
    return value, buffer, selected
  end

  local function connect()
    local value, buffer, selected = mount()
    local regions = {}
    for index = 1, 40 do
      regions[#regions + 1] = ui.region({
        key = "region-" .. index,
        revision = 1,
        child = ui.target({
          key = "target-" .. index,
          focus = {
            inactive = { { row = 0, chunks = { { text = "[idle]" } }, position = "eol" } },
            active = { { row = 0, chunks = { { text = "[active]" } }, position = "eol" } },
          },
          child = ui.text({ key = "text-" .. index, text = "Item " .. index }),
        }),
      })
    end
    value:update(ui.column({ key = "document", children = regions }))
    assert(value:flush())
    vim.api.nvim_win_set_cursor(selected, { 1, 0 })
    value:_draw_focus()
    return value, buffer, selected
  end

  it("updates only the old and new active target when the cursor moves", function()
    local value, buffer, selected = connect()
    local marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, { 20, 0 }, { 20, -1 }, {})
    local stable_id = assert(marks[1])[1]
    local writes = 0
    vim.api.nvim_buf_set_extmark = function(target_buffer, namespace, row, col, options)
      if target_buffer == buffer and namespace == value.focus_namespace then
        writes = writes + 1
      end
      return set_extmark(target_buffer, namespace, row, col, options)
    end
    vim.api.nvim_win_set_cursor(selected, { 2, 0 })
    value:_draw_focus()
    assert.are.equal(2, writes, "moving the cursor redrew unrelated inactive target badges")
    assert.are.same({ 20, 0 }, vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, stable_id, {}))
    assert.are.equal("target-2", assert(value:focused_target()).key)
  end)

  it("does not repeat hit testing for unchanged cursor observations", function()
    local value = connect()
    local searches = 0
    input.focus_target = function(selected)
      searches = searches + 1
      return focus_target(selected)
    end
    value:_draw_focus()
    value:_draw_focus()
    assert.are.equal(0, searches, "duplicate cursor observations scanned the interaction targets")
  end)

  for _, setting in ipairs({ "ambiwidth", "cellwidths", "tabstop" }) do
    it("keeps focus consistent with hit testing after " .. setting .. " changes", function()
      local value, buffer, selected = mount("editable")
      vim.api.nvim_win_set_width(selected, 4)
      vim.o.ambiwidth = "single"
      vim.fn.setcellwidths({})
      vim.bo[buffer].tabstop = 1
      value:replace_text(setting == "tabstop" and "\txzz" or "·xzz")
      value:update(ui.row({
        key = "row",
        children = {
          ui.target({
            key = "left",
            focus_style = "ErrorMsg",
            child = ui.text({ key = "left-text", text = "·x", wrap = "none" }),
          }),
          ui.target({
            key = "right",
            focus_style = "WarningMsg",
            child = ui.text({ key = "right-text", text = "zz", wrap = "none" }),
          }),
        },
      }))
      assert(value:flush())
      vim.api.nvim_win_set_cursor(selected, { 1, setting == "tabstop" and 1 or 2 })
      assert(value:flush())
      assert.are.equal("left", assert(value:focused_target()).key)
      local marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {})
      assert.are.equal(1, #marks)
      local details =
        vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, assert(marks[1])[1], { details = true })
      assert.are.equal("ErrorMsg", assert(details[3]).hl_group)
      local cursor = vim.api.nvim_win_get_cursor(selected)
      local changedtick = vim.api.nvim_buf_get_changedtick(buffer)

      if setting == "ambiwidth" then
        vim.o.ambiwidth = "double"
      elseif setting == "cellwidths" then
        vim.fn.setcellwidths({ { 0xB7, 0xB7, 2 } })
      else
        vim.bo[buffer].tabstop = 2
      end
      assert(value:flush())
      assert.are.same(cursor, vim.api.nvim_win_get_cursor(selected))
      assert.are.equal(changedtick, vim.api.nvim_buf_get_changedtick(buffer))
      assert.are.equal("right", assert(value:focused_target()).key)
      marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {})
      assert.are.equal(1, #marks)
      details =
        vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, assert(marks[1])[1], { details = true })
      assert.are.equal("WarningMsg", assert(details[3]).hl_group)
    end)
  end

  for _, removing in ipairs({ false, true }) do
    it("keeps inactive hints aligned after an editable line is " .. (removing and "removed" or "inserted"), function()
      local value, buffer, selected = mount("editable")
      value:replace_text("First\nSecond\nThird\nTrailing")
      local children = {}
      for index, text in ipairs({ "First", "Second", "Third" }) do
        children[#children + 1] = ui.target({
          key = "target-" .. index,
          focus = {
            active = { { row = 0, chunks = { { text = "[active]" } }, position = "eol" } },
            inactive = { { row = 0, chunks = { { text = "[idle]" } }, position = "eol" } },
          },
          child = ui.text({ key = "text-" .. index, text = text }),
        })
      end
      value:update(ui.column({ key = "document", children = children }))
      assert(value:flush())
      vim.api.nvim_win_set_cursor(selected, { 1, 0 })
      value:_draw_focus()
      local marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, { 2, 0 }, { 2, -1 }, {})
      local id = assert(marks[1])[1]

      vim.api.nvim_buf_set_lines(buffer, 0, removing and 1 or 0, false, removing and {} or { "Inserted" })
      vim.api.nvim_win_set_cursor(selected, { 2, 0 })
      value:_draw_focus()
      assert.are.equal("target-2", assert(value:focused_target()).key)
      assert.are.same({ 2, 0 }, vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, id, {}))
      assert.are.equal(3, #vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))
    end)
  end

  it("restores hints after selection and removes marks for deleted targets", function()
    local value, buffer = connect()
    vim.cmd("normal! v")
    value:_draw_focus()
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))
    vim.cmd("normal! \27")
    value:_draw_focus()
    assert.are.equal(40, #vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))
    value:update(ui.text({ key = "replacement", text = "No targets" }))
    assert(value:flush())
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))
    assert.is_nil(value:focused_target())
  end)

  it("repositions focus marks after rebuilding the same immutable Layout", function()
    local value, buffer = connect()
    value.reconcile_state.unknown = true
    value:update(assert(value.tree))
    assert(value:flush())
    local marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {})
    assert.are.equal(40, #marks)
    for index, mark in ipairs(marks) do
      assert.are.equal(index - 1, mark[2])
    end
  end)

  it("keeps returned target geometry independent from the owned search index", function()
    local value = connect()
    local selected = assert(value:focused_target())
    assert(selected.rectangles[1]).row = 39
    local targets = value:targets()
    assert(assert(targets[1]).rectangles[1]).row = 38
    assert.are.equal("target-1", assert(value:focused_target()).key)
    assert.are.equal(0, assert(assert(value:focused_target()).rectangles[1]).row)
  end)

  it("repositions a retained boundary hint when the following target changes", function()
    local value, buffer = mount()
    local first = ui.region({
      key = "first",
      revision = 1,
      child = ui.target({
        key = "first-target",
        focus = { active = { { row = "end", chunks = { { text = "[boundary]" } }, position = "eol" } } },
        child = ui.text({ key = "first-text", text = "First" }),
      }),
    })
    local last = ui.region({
      key = "last",
      revision = 1,
      child = ui.target({
        key = "last-target",
        focus = { inactive = { { row = 0, chunks = { { text = "[stable]" } }, position = "eol" } } },
        child = ui.text({ key = "last-text", text = "Last" }),
      }),
    })
    ---@param revision integer
    ---@param text string
    local function document(revision, text)
      return ui.column({
        key = "document",
        children = {
          first,
          ui.region({
            key = "middle",
            revision = revision,
            child = ui.target({
              key = "middle-target",
              child = ui.text({ key = "middle-text", text = text }),
            }),
          }),
          last,
        },
      })
    end
    value:update(document(1, "one\ntwo\nthree"))
    assert(value:flush())
    local marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {})
    assert.are.equal(2, #marks)
    local boundary_id, stable_id = assert(marks[1])[1], assert(marks[2])[1]
    local writes = 0
    vim.api.nvim_buf_set_extmark = function(target_buffer, namespace, row, col, options)
      if target_buffer == buffer and namespace == value.focus_namespace then
        writes = writes + 1
      end
      return set_extmark(target_buffer, namespace, row, col, options)
    end
    value:update(document(2, "changed\ntwo\nthree"))
    assert(value:flush())
    assert.are.same({ 1, 0 }, vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, boundary_id, {}))
    assert.are.same({ 4, 0 }, vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, stable_id, {}))
    assert.are.equal(1, writes, "a neighboring edit redrew an unaffected target hint")
  end)

  for _, following in ipairs({ false, true }) do
    it(
      "keeps a retained highlight in place when repeated trailing text is " .. (following and "removed" or "appended"),
      function()
        local value, buffer, selected = mount()
        local middle = ui.region({
          key = "middle",
          revision = 1,
          child = ui.text({ key = "middle-text", text = "same\nsame\nsame" }),
        })
        local target = ui.region({
          key = "target-region",
          revision = 1,
          child = ui.target({
            key = "target",
            focus_style = "Visual",
            child = ui.text({ key = "target-text", text = "same" }),
          }),
        })
        local tail = ui.region({
          key = "following",
          revision = 1,
          child = ui.target({
            key = "following-target",
            child = ui.text({ key = "following-text", text = "same\nsame" }),
          }),
        })
        ---@param prefix string
        ---@param include_following boolean
        local function document(prefix, include_following)
          local children = {
            ui.region({
              key = "prefix",
              revision = prefix,
              child = ui.text({ key = "prefix-text", text = prefix }),
            }),
            middle,
            target,
          }
          if include_following then
            children[#children + 1] = tail
          end
          return ui.column({ key = "document", children = children })
        end
        value:update(document("prefix", following))
        assert(value:flush())
        vim.api.nvim_win_set_cursor(selected, { 5, 0 })
        value:_draw_focus()
        local marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {})
        assert.are.equal(1, #marks)
        local id = assert(marks[1])[1]
        assert.are.same({ 4, 0 }, vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, id, {}))

        value:update(document("changed", not following))
        assert(value:flush())
        assert.are.same({ 5, 0 }, vim.api.nvim_win_get_cursor(selected))
        assert.are.equal("target", assert(value:focused_target()).key)
        assert.are.same({ 4, 0 }, vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, id, {}))
        assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))
      end
    )
  end

  it("reveals a retained boundary hint after an earlier edit and an append with a common trailing line", function()
    local value, buffer = mount()
    local target = ui.region({
      key = "target-region",
      revision = 1,
      child = ui.target({
        key = "target",
        focus = { inactive = { { row = "end", chunks = { { text = "[boundary]" } }, position = "eol" } } },
        child = ui.text({ key = "target-text", text = "target\n" }),
      }),
    })
    local following = ui.region({
      key = "following",
      revision = 1,
      child = ui.target({
        key = "following-target",
        child = ui.text({ key = "following-text", text = "following\n" }),
      }),
    })
    ---@param prefix string
    ---@param include_following boolean
    local function document(prefix, include_following)
      local children = {
        ui.region({
          key = "prefix",
          revision = prefix,
          child = ui.text({ key = "prefix-text", text = prefix .. "\n" }),
        }),
        target,
      }
      if include_following then
        children[#children + 1] = following
      end
      return ui.column({ key = "document", children = children })
    end
    value:update(document("prefix", false))
    assert(value:flush())
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))

    value:update(document("changed", true))
    assert(value:flush())
    local marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {})
    assert.are.equal(1, #marks)
    assert.are.same(
      { 4, 0 },
      vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, assert(marks[1])[1], {})
    )

    value:update(document("restored", false))
    assert(value:flush())
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))
  end)

  it("updates a retained hint as its following boundary appears and disappears", function()
    local value, buffer = mount()
    local first = ui.region({
      key = "first",
      revision = 1,
      child = ui.target({
        key = "first-target",
        focus = { active = { { row = "end", chunks = { { text = "[boundary]" } }, position = "eol" } } },
        child = ui.text({ key = "first-text", text = "First" }),
      }),
    })
    local following = ui.region({
      key = "following",
      revision = 1,
      child = ui.text({ key = "following-text", text = "Following" }),
    })
    value:update(ui.column({ key = "document", children = { first } }))
    assert(value:flush())
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))
    value:update(ui.column({ key = "document", children = { first, following } }))
    assert(value:flush())
    local marks = vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {})
    assert.are.equal(1, #marks)
    assert.are.same(
      { 1, 0 },
      vim.api.nvim_buf_get_extmark_by_id(buffer, value.focus_namespace, assert(marks[1])[1], {})
    )
    value:update(ui.column({ key = "document", children = { first } }))
    assert(value:flush())
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buffer, value.focus_namespace, 0, -1, {}))
  end)
end)
