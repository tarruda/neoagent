local async = require("neoagent.async")
local fs = require("neoagent.fs")
local Workspace = require("neoagent.workspace")

local function fixture()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  return root, Workspace.new({ root = root, cwd = root })
end

local function ctx(workspace, updates)
  return {
    context = { workspace = workspace },
    on_update = function(value) if updates then updates[#updates + 1] = value end end,
  }
end

local function execute(tool, arguments, context)
  local run = async.run(function() return tool.execute(arguments, context) end)
  assert(vim.wait(3000, function() return run:is_done() end))
  local result = run:result()
  if result.ok == false and result.error then error(result.error.message) end
  return result
end

describe("neoagent bundled tools", function()
  local roots = {}
  after_each(function()
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots = {}
  end)

  it("returns fresh exact presets", function()
    local tools = require("neoagent.tools")
    local coding = tools.coding()
    local read_only = tools.read_only()
    assert.are.same({
      "read_file", "write_file", "edit_file", "shell", "read_agent_documentation",
    }, vim.tbl_map(function(t) return t.name end, coding))
    assert.are.same({ "read_file", "grep", "find" }, vim.tbl_map(function(t) return t.name end, read_only))
    assert.are.same({
      "read_file", "write_file", "edit_file", "shell", "grep", "find", "read_agent_documentation",
    }, vim.tbl_map(function(t) return t.name end, tools.all()))
    assert.are_not.equal(coding[1], tools.coding()[1])
  end)

  it("returns the on-demand Neoagent extensibility guide", function()
    local tool = require("neoagent.tools.read_agent_documentation")
    assert.matches("Use this only when the user asks about Neoagent", tool.description)
    assert.are.same({}, tool.input_schema.properties)
    local original = vim.env.MYVIMRC
    local init = vim.fn.tempname() .. "/init.lua"
    vim.env.MYVIMRC = init
    local result = execute(tool, {}, nil)
    vim.env.MYVIMRC = original
    local text = result.content[1].text
    assert.matches("# Neoagent configuration and extensibility", text)
    assert.matches("Choose the smallest useful layer", text)
    assert.matches("Independent Controller example", text)
    assert.matches("Custom tool and execution policy", text)
    assert.matches("Custom View", text)
    assert.is_truthy(text:find("Active Neovim configuration: " .. init, 1, true))
    local root = text:match("Plugin root: ([^\n]+)")
    assert.is_truthy(root and vim.uv.fs_stat(root .. "/lua/neoagent/agent.lua"))

    vim.env.MYVIMRC = nil
    text = execute(tool, {}, nil).content[1].text
    vim.env.MYVIMRC = original
    assert.is_truthy(text:find(vim.fn.stdpath("config") .. "/init.lua", 1, true))
  end)

  it("writes and reads disk without consulting buffers", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local write = require("neoagent.tools.write_file")
    local read = require("neoagent.tools.read_file")
    local result = execute(write, { path = "nested/file.txt", content = "one\ntwo\nthree" }, ctx(workspace))
    assert.matches("Successfully wrote 13 bytes", result.content[1].text)
    result = execute(read, { path = "nested/file.txt", offset = 2, limit = 1 }, ctx(workspace))
    assert.matches("two", result.content[1].text)
    assert.matches("offset=3", result.content[1].text)
  end)

  it("validates and bounds text reads", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local read = require("neoagent.tools.read_file")
    assert.has_error(function() execute(read, { path = "" }, ctx(workspace)) end)
    assert.has_error(function() execute(read, { path = "missing" }, {}) end)
    assert.has_error(function() execute(read, { path = "missing" }, ctx(workspace)) end)
    assert.has_error(function() execute(read, { path = "missing", offset = 0 }, ctx(workspace)) end)
    assert.has_error(function() execute(read, { path = "missing", limit = 1.5 }, ctx(workspace)) end)

    assert(fs.write_all(root .. "/short.txt", "one\ntwo", "w"))
    assert.are.equal("one\ntwo", execute(read, { path = "short.txt" }, ctx(workspace)).content[1].text)
    assert.has_error(function() execute(read, { path = "short.txt", offset = 3 }, ctx(workspace)) end)
    assert.has_error(function() execute(read, { path = "." }, ctx(workspace)) end)

    assert(fs.write_all(root .. "/wide.txt", string.rep("x", 51 * 1024), "w"))
    local wide = execute(read, { path = "wide.txt" }, ctx(workspace))
    assert.matches("exceeds 50.0KB limit", wide.content[1].text)

    local lines = {}
    for index = 1, 2001 do lines[index] = "line " .. index end
    assert(fs.write_all(root .. "/long.txt", table.concat(lines, "\n"), "w"))
    local long = execute(read, { path = "long.txt" }, ctx(workspace))
    assert.matches("Showing lines 1%-2000 of 2001", long.content[1].text)
    assert.matches("offset=2001", long.content[1].text)
  end)

  it("returns supported images as raw base64 when ImageMagick is absent", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local png = "\137PNG\r\n\26\nraw"
    assert(fs.write_all(root .. "/image.png", png, "w"))
    local old_path = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    local result = execute(require("neoagent.tools.read_file"), { path = "image.png" }, ctx(workspace))
    vim.env.PATH = old_path
    assert.are.equal("image/png", result.content[2].mimeType)
    assert.are.equal(png, vim.base64.decode(result.content[2].data))
    assert.matches("unavailable", result.content[1].text)
  end)

  it("resizes images with ImageMagick and falls back on conversion failure", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local png = "\137PNG\r\n\26\nraw"
    assert(fs.write_all(root .. "/image.png", png, "w"))
    local magick = root .. "/magick"
    assert(fs.write_all(magick, table.concat({
      "#!/bin/sh",
      "if [ \"$1\" = identify ]; then",
      "  case \"$4\" in *.png|*.jpg) printf '2000 667' ;; *) printf '3000 1000' ;; esac",
      "  exit 0",
      "fi",
      "input=$1",
      "input=${input%\\[0\\]}",
      "for output do :; done",
      "cp \"$input\" \"$output\"",
    }, "\n"), "w"))
    assert(vim.uv.fs_chmod(magick, 493))
    local old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path
    local result = execute(require("neoagent.tools.read_file"), { path = "image.png" }, ctx(workspace))
    assert.matches("Resized from 3000x1000 to 2000x667", result.content[1].text)
    assert.are.equal(png, vim.base64.decode(result.content[2].data))

    assert(fs.write_all(magick, "#!/bin/sh\nprintf failure >&2\nexit 2\n", "w"))
    assert(vim.uv.fs_chmod(magick, 493))
    result = execute(require("neoagent.tools.read_file"), { path = "image.png" }, ctx(workspace))
    vim.env.PATH = old_path
    assert.matches("resize failed", result.content[1].text)
    assert.are.equal(png, vim.base64.decode(result.content[2].data))
  end)

  it("applies exact and tolerant edits while preserving BOM and CRLF", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local path = root .. "/edit.txt"
    assert(fs.write_all(path, "\239\187\191one  \r\nsmart \226\128\156quote\226\128\157\r\nlast\r\n", "w"))
    local result = execute(require("neoagent.tools.edit_file"), {
      path = "edit.txt",
      edits = {
        { oldText = "one", newText = "ONE" },
        { oldText = 'smart "quote"', newText = "smart quote" },
      },
    }, ctx(workspace))
    local changed = assert(fs.read(path))
    assert.are.equal("\239\187\191", changed:sub(1, 3))
    assert.matches("ONE\r\nsmart quote\r\nlast", changed)
    assert.is_nil(changed:gsub("\r\n", ""):find("\n", 1, true))
    assert.are.equal(1, result.details.firstChangedLine)
    assert.matches("+ONE", result.details.diff)
    assert.is_true(#result.details.patch > 0)
  end)

  it("rejects duplicate, overlapping, and no-op edits", function()
    local edit = require("neoagent.tools.edit_file")
    assert.has_error(function() edit._apply("one", { { oldText = "missing", newText = "two" } }, "f") end)
    assert.has_error(function() edit._apply("one", { { oldText = 1, newText = "two" } }, "f") end)
    assert.has_error(function() edit._apply("x x", { { oldText = "x", newText = "y" } }, "f") end)
    assert.has_error(function()
      edit._apply("abcdef", {
        { oldText = "abc", newText = "x" }, { oldText = "bc", newText = "y" },
      }, "f")
    end)
    assert.has_error(function() edit._apply("x", { { oldText = "x", newText = "x" } }, "f") end)

    local root, workspace = fixture()
    roots[#roots + 1] = root
    assert.has_error(function()
      execute(edit, { path = "missing", edits = {} }, ctx(workspace))
    end)
  end)

  it("runs shell with updates and returns non-zero output as an error result", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local updates = {}
    local result = execute(require("neoagent.tools.shell"), {
      command = "printf out; printf err >&2; exit 3",
    }, ctx(workspace, updates))
    assert.is_true(result.isError)
    assert.are.equal(3, result.details.exit_code)
    assert.matches("out", result.content[1].text)
    assert.matches("err", result.content[1].text)
    assert.is_true(#updates >= 1)
  end)

  it("keeps bounded shell output and saves the complete result", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local result = execute(require("neoagent.tools.shell"), {
      command = "i=1; while [ \"$i\" -le 2100 ]; do printf '%s\\n' \"$i\"; i=$((i + 1)); done",
    }, ctx(workspace))
    assert.is_false(result.isError)
    assert.matches("Output truncated", result.content[1].text)
    assert.is_not_nil(result.details.output_path)
    assert.is_not_nil(vim.uv.fs_stat(result.details.output_path))
    vim.fn.delete(result.details.output_path)
    assert.has_error(function()
      execute(require("neoagent.tools.shell"), { command = "true", timeout = 0 }, ctx(workspace))
    end)
  end)

  it("times out and cancels shell processes", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local timed_out = execute(require("neoagent.tools.shell"), {
      command = "sleep 2", timeout = 0.05,
    }, ctx(workspace))
    assert.is_true(timed_out.isError)
    assert.matches("timed out", timed_out.content[1].text)

    local run = async.run(function()
      return require("neoagent.tools.shell").execute({ command = "sleep 2" }, ctx(workspace))
    end)
    vim.defer_fn(function() run:cancel() end, 50)
    assert(vim.wait(3000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
    assert.are.equal("cancelled", run:result().error.kind)
  end)

  it("searches with rg and fd and treats no matches as success", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    assert(fs.write_all(root .. "/one.lua", "needle\n", "w"))
    assert(fs.write_all(root .. "/two.txt", "other\n", "w"))
    local grep = execute(require("neoagent.tools.grep"), { pattern = "needle" }, ctx(workspace))
    assert.matches("one.lua:1:needle", grep.content[1].text)
    local none = execute(require("neoagent.tools.grep"), { pattern = "absent" }, ctx(workspace))
    assert.are.equal("No matches found", none.content[1].text)
    local found = execute(require("neoagent.tools.find"), { pattern = "*.lua" }, ctx(workspace))
    assert.matches("one.lua", found.content[1].text)
  end)

  it("applies search options and reports bounded results", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    assert(fs.write_all(root .. "/one.lua", "Needle[\ncontext\nNeedle[\n", "w"))
    assert(fs.write_all(root .. "/two.lua", "Needle[\n", "w"))
    assert(fs.write_all(root .. "/ignored.txt", "Needle[\n", "w"))
    local grep_tool = require("neoagent.tools.grep")
    local grep = execute(grep_tool, {
      pattern = "needle[", ignoreCase = true, literal = true, glob = "*.lua", context = 0, limit = 1,
    }, ctx(workspace))
    assert.matches("%.lua:1:Needle%[", grep.content[1].text)
    assert.matches("Results truncated", grep.content[1].text)
    assert.is_nil(grep.content[1].text:find("ignored.txt", 1, true))
    assert.has_error(function() execute(grep_tool, { pattern = "x", context = -1 }, ctx(workspace)) end)
    assert.has_error(function() execute(grep_tool, { pattern = "x", glob = true }, ctx(workspace)) end)

    local found = execute(require("neoagent.tools.find"), { pattern = "*.lua", limit = 1 }, ctx(workspace))
    assert.matches("Results truncated", found.content[1].text)
  end)
end)
