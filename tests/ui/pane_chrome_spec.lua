local assert = require("luassert")
local Applet = require("applet")
local util = require("applet.util")
local ui = Applet.Pane.nodes

describe("Pane chrome updates", function()
  local equal = util.equal
  ---@type Applet.Pane?
  local pane
  ---@type integer?
  local window

  after_each(function()
    util.equal = equal
    if pane then
      pane:destroy()
    end
    if window and vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
    pane, window = nil, nil
  end)

  ---@param window_options? Applet.Options
  local function connect(window_options)
    local buffer = vim.api.nvim_create_buf(false, true)
    window = vim.api.nvim_open_win(buffer, true, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 30,
      height = 8,
      style = "minimal",
      border = "single",
    })
    local host = {
      buffer = buffer,
      window = function()
        return window
      end,
      owns_buffer = true,
      buffer_options = { buftype = "nofile" },
      window_options = window_options or { wrap = true, showbreak = ">>", linebreak = false },
    }
    pane = Applet.Pane.new({ key = "chrome-update" })
    pane:_connect(host)
    return pane, host
  end

  it("does not visit unchanged decoration regions when only the footer changes", function()
    local value = connect()
    local regions = {}
    for index = 1, 25 do
      regions[#regions + 1] = ui.region({
        key = "region-" .. index,
        revision = 1,
        child = ui.text({ key = "text-" .. index, text = "stable " .. index, background = "NormalFloat" }),
      })
    end
    local root = ui.column({ key = "document", children = regions })
    value:update({ root = root, chrome = { footer = { { text = "first" } } } })
    assert(value:flush())
    local stable_lines = {}
    for _, region in ipairs(assert(value.layout).regions) do
      stable_lines[region.lines] = true
    end
    local visits = 0
    util.equal = function(left, right)
      if stable_lines[left] then
        visits = visits + 1
      end
      return equal(left, right)
    end
    value:update({ root = root, chrome = { footer = { { text = "second" } } } })
    assert(value:flush())
    assert.are.equal(0, visits, "a footer-only update scanned unchanged decoration regions")
    assert.are.equal("stable 1", assert(value.layout).lines[1])
  end)

  it("refreshes continuation decorations when native wrapping options change", function()
    local value, host = connect({})
    local root = ui.text({
      key = "wrapped",
      text = string.rep("word ", 20),
      wrap = "native",
      background = "NormalFloat",
    })
    value:update({ root = root, chrome = { options = { wrap = true, showbreak = ">>", linebreak = false } } })
    assert(value:flush())
    local initial = vim.api.nvim_buf_get_extmarks(host.buffer, value.namespace, 0, -1, { details = true })
    assert.matches(">>", vim.inspect(initial), 1, true)
    value:update({ root = root, chrome = { options = { wrap = true, showbreak = "++", linebreak = false } } })
    assert(value:flush())
    local changed = vim.api.nvim_buf_get_extmarks(host.buffer, value.namespace, 0, -1, { details = true })
    assert.matches("++", vim.inspect(changed), 1, true)
    value:update({ root = root, chrome = { options = { wrap = false, showbreak = "++", linebreak = false } } })
    assert(value:flush())
    local unwrapped = vim.api.nvim_buf_get_extmarks(host.buffer, value.namespace, 0, -1, { details = true })
    assert.is_nil((vim.inspect(unwrapped):find("virt_text", 1, true)))
  end)
end)
