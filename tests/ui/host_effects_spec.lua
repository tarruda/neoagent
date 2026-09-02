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
    local original_tab = vim.api.nvim_get_current_tabpage()
    assert(effects.open_document({
      name = "applet-host-document",
      filetype = "markdown",
      content = "\nheading\nbody\n",
    }))
    assert.are.equal("markdown", vim.bo.filetype)
    assert.are.equal("wipe", vim.bo.bufhidden)
    assert.are.equal("nofile", vim.bo.buftype)
    assert.is_false(vim.bo.buflisted)
    assert.is_false(vim.bo.swapfile)
    assert.matches("^neoagent://provider/", vim.api.nvim_buf_get_name(0))
    assert.are.equal("\nheading\nbody\n", table.concat(
      vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"))

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
    for _, name in ipairs({ "../report", "dir/report", "dir\\report",
      "bad\nname" }) do
      assert.has_error(function()
        effects.open_document({ name = name, filetype = "text", content = "" })
      end)
    end

    local original_cmd = vim.cmd
    vim.cmd = function() error("tab creation failed") end
    local opened, err = effects.open_document({
      name = "failure", filetype = "text", content = "value",
    })
    vim.cmd = original_cmd
    assert.is_nil(opened)
    assert.matches("tab creation failed", err)

    local tabs = #vim.api.nvim_list_tabpages()
    local buffers = vim.api.nvim_list_bufs()
    local original_set_lines = vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function() error("content failed") end
    opened, err = effects.open_document({
      name = "rollback", filetype = "text", content = "value",
    })
    vim.api.nvim_buf_set_lines = original_set_lines
    assert.is_nil(opened)
    assert.matches("content failed", err)
    assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if not vim.tbl_contains(buffers, buffer) then
        assert.is_false(vim.api.nvim_buf_is_valid(buffer))
      end
    end

    local orphan
    vim.api.nvim_buf_set_lines = function(buffer)
      orphan = buffer
      vim.bo[buffer].bufhidden = "hide"
      error("detached content failed")
    end
    opened, err = effects.open_document({
      name = "detached-rollback", filetype = "text", content = "value",
    })
    vim.api.nvim_buf_set_lines = original_set_lines
    assert.is_nil(opened)
    assert.matches("detached content failed", err)
    assert.is_not_nil(orphan)
    assert.is_false(vim.api.nvim_buf_is_valid(orphan))

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
    local document_tab = vim.api.nvim_get_current_tabpage()
    if vim.api.nvim_tabpage_is_valid(original_tab) then
      vim.api.nvim_set_current_tabpage(original_tab)
    end
    if document_tab ~= original_tab
        and vim.api.nvim_tabpage_is_valid(document_tab) then
      vim.api.nvim_set_current_tabpage(document_tab)
      vim.cmd("tabclose!")
      vim.api.nvim_set_current_tabpage(original_tab)
    end
  end)
end)
