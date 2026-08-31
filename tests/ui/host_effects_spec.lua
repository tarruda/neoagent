local effects = require("applet").host_effects

describe("Applet host effects", function()
  local paths = {}
  local origin_tab

  before_each(function()
    origin_tab = vim.api.nvim_get_current_tabpage()
  end)

  after_each(function()
    if vim.api.nvim_tabpage_is_valid(origin_tab) then
      vim.api.nvim_set_current_tabpage(origin_tab)
    end
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if tab ~= origin_tab and vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        vim.cmd("tabclose!")
      end
    end
    for _, path in ipairs(paths) do vim.fn.delete(path) end
    paths = {}
  end)

  it("refreshes matching unmodified buffers and preserves modified text", function()
    local path = vim.fn.tempname()
    paths[#paths + 1] = path
    assert.are.equal(0, vim.fn.writefile({ "first" }, path))
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buffer = vim.api.nvim_get_current_buf()

    assert.are.equal(0, vim.fn.writefile({ "second" }, path))
    local result = effects.refresh_file(path)
    assert.are.equal(1, result.refreshed)
    assert.are.same({}, result.modified)
    assert.are.equal("second", vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1])

    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "draft" })
    result = effects.refresh_file(path)
    assert.are.equal(0, result.refreshed)
    assert.are.same({ vim.api.nvim_buf_get_name(buffer) }, result.modified)
    assert.are.equal("draft", vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1])
    vim.bo[buffer].modified = false

    local original_cmd = vim.cmd
    vim.cmd = function() error("reload unavailable") end
    result = effects.refresh_file(path)
    vim.cmd = original_cmd
    assert.are.equal(1, #result.failures)
    assert.matches("reload unavailable", result.failures[1])
    assert.has_error(function() effects.refresh_file("") end)
  end)

  it("opens semantic documents and owns exit autocmd cleanup", function()
    assert(effects.open_document({
      name = "applet-host-document",
      filetype = "markdown",
      content = "heading\nbody\n",
    }))
    assert.are.equal("markdown", vim.bo.filetype)
    assert.are.equal("wipe", vim.bo.bufhidden)
    assert.are.same({ "heading", "body" },
      vim.api.nvim_buf_get_lines(0, 0, -1, false))

    assert.has_error(function() effects.open_document(false) end)
    assert.has_error(function()
      effects.open_document({ name = "", filetype = "text", content = "" })
    end)
    assert.has_error(function()
      effects.open_document({ name = "name", filetype = false, content = "" })
    end)
    assert.has_error(function()
      effects.open_document({ name = "name", filetype = "text", content = false })
    end)

    local original_cmd = vim.cmd
    vim.cmd = function() error("tab creation failed") end
    local opened, err = effects.open_document({
      name = "failure", filetype = "text", content = "value",
    })
    vim.cmd = original_cmd
    assert.is_nil(opened)
    assert.matches("tab creation failed", err)

    local release = effects.on_exit(function() end)
    local autocmds = vim.api.nvim_get_autocmds({ event = "VimLeavePre" })
    local found = false
    for _, autocmd in ipairs(autocmds) do
      if autocmd.group_name and autocmd.group_name:match("^AppletHostEffects") then
        found = true
      end
    end
    assert.is_true(found)
    release()
    release()
    assert.has_error(function() effects.on_exit(false) end)
  end)
end)
