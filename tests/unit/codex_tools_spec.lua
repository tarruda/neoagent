local assert = require("luassert")
local async_test = require("tests.helpers.async_test")
local it = async_test
local fs = require("neoagent.fs")
local patch_tool = require("neoagent.tools.codex.apply_patch")
local patch = require("neoagent.tools.codex.patch")
local util = require("neoagent.util")

describe("Codex file Tools", function()
  local roots = {}

  after_each(function()
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
  end)

  local function workspace()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    assert(fs.mkdirp(root))
    return root
  end

  ---@param root string
  ---@param changed? string[]
  ---@return Neoagent.ToolOperationCall
  local function call(root, changed)
    return {
      workspace = { root = root, cwd = root },
      on_update = function() end,
      on_file_changed = changed and function(path)
        changed[#changed + 1] = path
      end or nil,
    }
  end

  it("matches blank EOF context against files without a trailing blank line", function()
    local operation = assert(patch.parse("*** Begin Patch\n*** Update File: file\n@@\n-old\n+new\n\n*** End Patch")[1])
    assert.are.equal("new\n", patch.update("old\n", operation))
    local append = assert(patch.parse("*** Begin Patch\n*** Update File: file\n@@ line\n\n@@\n+tail\n*** End Patch")[1])
    assert.are.equal("line\ntail\n", patch.update("line\n", append))
  end)

  it("offers optional plans and renders image and patch activity defensively", function()
    local tools = require("neoagent.tools.codex").coding({ update_plan = true })
    assert.are.equal("update_plan", assert(tools[5]).name)
    local view = require("neoagent.tools.codex.view_image").new()
    local render = view.render
    assert(render)
    assert.is_nil(render())
    local presentation = render({ arguments = { path = "image.png" } })
    assert(type(presentation) == "table")
    assert.are.equal("image.png", presentation.subject)
    local render_patch = require("neoagent.tools.common.patch_presentation").render
    assert.is_nil(render_patch())
    local pending = assert(render_patch({ arguments = {}, state = "running" }))
    assert.are.equal("activity", pending.kind)
    assert.are.equal("Applying", pending.ongoing)
    assert.is_nil(render_patch({ arguments = {}, result = { content = {}, details = { changes = { {} } } } }))
  end)

  async_test("validates image capabilities before direct execution and preserves original bytes", function()
    local root = workspace()
    local created = require("neoagent.subprocess_common").run({
      argv = { "magick", "-size", "2x1", "xc:blue", root .. "/image.png" },
      cwd = root,
      stdio = { kind = "pipes" },
      timeout_ms = 10000,
    }, { capture = { max_bytes = 10000 } })
    assert.are.equal(0, created.code)
    local attachments = require("tests.helpers.attachments").new()
    local model = require("tests.helpers.fake_model").new()
    model.input = { "text", "image" }
    local tool = require("neoagent.tools.codex.view_image").new()
    local ctx = {
      model = model,
      run = assert(require("neoagent.async").current()),
      execute_tool = function()
        error("unused")
      end,
      context = { workspace = { root = root, cwd = root }, files = attachments.files },
      call = { type = "toolCall", id = "image", name = "view_image", arguments = {} },
      on_update = function() end,
    }
    local allowed, err =
      pcall(require("neoagent.tools.invocation").prepare, tool, { path = "image.png", detail = "original" }, ctx)
    assert.is_false(allowed)
    assert.matches("does not support original", tostring(err))
    model.supports_image_detail_original = true
    local result = tool.execute({ path = "image.png", detail = "original" }, ctx)
    local image = assert(result.content[1])
    assert(image.type == "image")
    assert.are.equal("original", image.detail)
    assert.are.equal(fs.read(root .. "/image.png"), attachments.read(image))
  end)

  it("rejects oversized patch text before interpreting its contents", function()
    local text = string.rep("\255", require("neoagent.tools.limits").MAX_INPUT_BYTES + 1)
    local ok, err = pcall(patch_tool.prepare, { patch = text }, {}, call(workspace()))
    assert.is_false(ok)
    assert.matches("request limit", tostring(err))
  end)

  it("accepts padded boundary markers without trimming hunk payload", function()
    local root = workspace()
    assert(fs.write_all(root .. "/file", "  before  \n"))
    local invocation = call(root)
    local text = " \t*** Begin Patch \t\n*** Update File: file\n@@\n-  before  \n+  after  \n \t*** End Patch \t\n"
    local result = patch_tool.run(patch_tool.prepare({ patch = text }, {}, invocation), invocation, { fs = fs })
    assert.is_nil(result.isError)
    assert.are.equal("  after  \n", fs.read(root .. "/file"))
  end)

  async_test("bounds aggregate patch preparation before publishing any file", function()
    local root = workspace()
    assert(fs.write_all(root .. "/one", "before\n"))
    assert(fs.write_all(root .. "/two", "before\n"))
    local invocation = call(root)
    local request = patch_tool.prepare({ patch = table.concat({
      "*** Begin Patch", "*** Update File: one", "@@", "-before", "+after",
      "*** Update File: two", "@@", "-before", "+after", "*** End Patch",
    }, "\n") }, {}, invocation)
    local limits = require("neoagent.tools.limits")
    local previous = limits.MAX_PATCH_PREPARATION_BYTES
    limits.MAX_PATCH_PREPARATION_BYTES = 20
    local ok, err = pcall(patch_tool.run, request, invocation, { fs = fs })
    limits.MAX_PATCH_PREPARATION_BYTES = previous
    assert.is_false(ok)
    assert.matches("preparation.*budget", tostring(err))
    assert.are.equal("before\n", fs.read(root .. "/one"))
    assert.are.equal("before\n", fs.read(root .. "/two"))
  end)

  async_test("honors cancellation during patch preparation before publication", function()
    local root = workspace()
    assert(fs.write_all(root .. "/one", "before\n"))
    assert(fs.write_all(root .. "/two", "before\n"))
    local invocation = call(root)
    local request = patch_tool.prepare({ patch = table.concat({
      "*** Begin Patch", "*** Update File: one", "@@", "-before", "+after",
      "*** Update File: two", "@@", "-before", "+after", "*** End Patch",
    }, "\n") }, {}, invocation)
    local filesystem = util.shallow_copy(fs)
    local queued = false
    local run = require("neoagent.async").run(function(owner)
      filesystem.preflight = function(...)
        if not queued then
          queued = true
          vim.schedule(function() owner:cancel() end)
        end
        return fs.preflight(...)
      end
      return patch_tool.run(request, invocation, { fs = filesystem })
    end)
    local result = run:await()
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal("before\n", fs.read(root .. "/one"))
    assert.are.equal("before\n", fs.read(root .. "/two"))
  end)

  it("cancels preparation within a single repetitive file", function()
    local root = workspace()
    local before = string.rep("  repeated_entry = true,\n", 5000)
    assert(fs.write_all(root .. "/file", before))
    local text = "*** Begin Patch\n*** Update File: file\n@@\n"
      .. string.rep("   repeated_entry = true,\n", 24)
      .. "-stale\n+replacement\n*** End Patch"
    local invocation = call(root)
    local request = patch_tool.prepare({ patch = text }, {}, invocation)
    local filesystem = util.shallow_copy(fs)
    local run = require("neoagent.async").run(function(owner)
      filesystem.preflight = function(...)
        local preimage, err = fs.preflight(...)
        vim.schedule(function() owner:cancel() end)
        return preimage, err
      end
      return patch_tool.run(request, invocation, { fs = filesystem })
    end)
    local result = run:await()
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal(before, fs.read(root .. "/file"))
  end)

  it("matches overlapping context and prefers an exact match over earlier fuzzy text", function()
    local operation = patch.parse("*** Begin Patch\n*** Update File: file\n@@\n same\n same\n-last\n+new\n*** End Patch")[1]
    assert(operation)
    assert.are.equal("same\nsame\nsame\nnew\n", patch.update("same\nsame\nsame\nlast\n", operation))
    assert.are.equal(" same \nsame\nlast\nsame\nsame\nnew\n",
      patch.update(" same \nsame\nlast\nsame\nsame\nlast\n", operation))
  end)

  async_test("retains published patch effects when cancelled between files", function()
    local root = workspace()
    assert(fs.write_all(root .. "/one", "before\n"))
    assert(fs.write_all(root .. "/two", "before\n"))
    local changed = {}
    local run = require("neoagent.async").run(function(owner)
      local invocation = call(root)
      invocation.on_file_changed = function(path)
        changed[#changed + 1] = path
        vim.schedule(function() owner:cancel() end)
      end
      local request = patch_tool.prepare({ patch = table.concat({
        "*** Begin Patch", "*** Update File: one", "@@", "-before", "+after",
        "*** Update File: two", "@@", "-before", "+after", "*** End Patch",
      }, "\n") }, {}, invocation)
      return patch_tool.run(request, invocation, { fs = fs })
    end)
    local result = run:await()
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.same({ root .. "/one" }, changed)
    assert.are.equal("after\n", fs.read(root .. "/one"))
    assert.are.equal("before\n", fs.read(root .. "/two"))
  end)

  async_test("omits image display filenames containing control characters", function()
    if jit.os == "Windows" then return end
    local root = workspace()
    local name = "image\twith\ncontrols.png"
    local created = require("neoagent.subprocess_common").run({
      argv = { "magick", "-size", "1x1", "xc:blue", root .. "/" .. name },
      cwd = root, stdio = { kind = "pipes" }, timeout_ms = 10000,
    }, { capture = { max_bytes = 10000 } })
    assert.are.equal(0, created.code)
    local bytes = assert(fs.read(root .. "/" .. name))
    local attachments = require("tests.helpers.attachments").new()
    local invocation = call(root)
    invocation.artifacts = { put = attachments.files.put }
    local view = require("neoagent.tools.codex.view_image")
    local result = view.run(view.prepare({ path = name, detail = "original" }, {}, invocation), invocation,
      require("neoagent.tools.read_file")._dependencies())
    local normalized, err = require("neoagent.semantic_message").normalize_tool_result(result)
    assert(normalized, err)
    local block = assert(normalized.content[1])
    assert(block.type == "image")
    assert.is_nil(block.filename)
    assert.are.equal(bytes, attachments.read(block))
  end)

  it("preserves fuzzy context bytes and mixed line endings outside replacements", function()
    local root = workspace()
    local before = "    before\r\nold\n    after\r\ntail\n"
    assert(fs.write_all(root .. "/file.txt", before))
    local invocation = call(root)
    local request = patch_tool.prepare(
      { patch = [[*** Begin Patch
*** Update File: file.txt
@@
 before
-old
+new
 after
*** End Patch]] },
      {},
      invocation
    )
    local result = patch_tool.run(request, invocation, { fs = fs })
    assert.is_nil(result.isError)
    assert.are.equal("    before\r\nnew\n    after\r\ntail\n", fs.read(root .. "/file.txt"))
  end)

  it("applies append hunks without consuming later replacement searches", function()
    local root = workspace()
    assert(fs.write_all(root .. "/file.txt", "a\r\n"))
    local invocation = call(root)
    local request = patch_tool.prepare({ patch = [[*** Begin Patch
*** Update File: file.txt
@@
+tail
@@
-a
+b
@@
+last
*** End Patch]] }, {}, invocation)
    local result = patch_tool.run(request, invocation, { fs = fs })
    assert.is_nil(result.isError)
    assert.are.equal("b\r\ntail\r\nlast\r\n", fs.read(root .. "/file.txt"))
  end)

  it("matches jump contexts and EOF hunks while preserving BOM, CRLF, and mode", function()
    local root = workspace()
    local before = "\239\187\191section one\r\n  repeated  \r\nsection two\r\n  repeated  \r\n"
    assert(fs.write_all(root .. "/file.txt", before))
    if jit.os ~= "Windows" then
      assert(vim.uv.fs_chmod(root .. "/file.txt", 384))
    end
    local text = [[*** Begin Patch
*** Update File: file.txt
@@ section two
-repeated
+changed
*** End of File
*** End Patch]]
    local changed = {}
    local invocation = call(root, changed)
    local result = patch_tool.run(patch_tool.prepare({ patch = text }, {}, invocation), invocation, { fs = fs })
    assert.is_nil(result.isError)
    assert.are.equal(
      "\239\187\191section one\r\n  repeated  \r\nsection two\r\nchanged\r\n",
      fs.read(root .. "/file.txt")
    )
    assert.are.same({ root .. "/file.txt" }, changed)
    if jit.os ~= "Windows" then
      assert.are.equal(384, bit.band(assert(vim.uv.fs_stat(root .. "/file.txt")).mode, 511))
    end
    local operation = patch.parse([[*** Begin Patch
*** Update File: file.txt
@@
-“old”—value
+new
*** End Patch]])[1]
    assert(operation)
    assert.are.equal("new\n", patch.update('"old"-value\n', operation))
  end)

  it("preflights every file and rejects aliases before any publication", function()
    local root = workspace()
    assert(fs.write_all(root .. "/existing.txt", "old\n"))
    local text = [[*** Begin Patch
*** Update File: existing.txt
@@
-old
+new
*** Delete File: missing.txt
*** End Patch]]
    local invocation = call(root)
    local request = patch_tool.prepare({ patch = text }, {}, invocation)
    assert.is_false(pcall(patch_tool.run, request, invocation, { fs = fs }))
    assert.are.equal("old\n", fs.read(root .. "/existing.txt"))
    assert.is_false(pcall(
      patch_tool.prepare,
      { patch = [[*** Begin Patch
*** Add File: same.txt
+first
*** Add File: ./same.txt
+second
*** End Patch]] },
      {},
      invocation
    ))
    assert.is_nil(vim.uv.fs_stat(root .. "/same.txt"))
    if jit.os ~= "Windows" then
      assert(vim.uv.fs_symlink(root .. "/existing.txt", root .. "/link.txt"))
      request = patch_tool.prepare(
        { patch = [[*** Begin Patch
*** Add File: new.txt
+first
*** Delete File: link.txt
*** End Patch]] },
        {},
        invocation
      )
      assert.is_false(pcall(patch_tool.run, request, invocation, { fs = fs }))
      assert.is_nil(vim.uv.fs_stat(root .. "/new.txt"))
      assert.are.equal("old\n", fs.read(root .. "/existing.txt"))
    end
  end)

  it("reports earlier effects when a later publication fails identity validation", function()
    local root = workspace()
    assert(fs.write_all(root .. "/second.txt", "old\n"))
    local changed = {}
    local invocation = call(root, changed)
    local filesystem = util.copy(fs)
    filesystem.atomic_replace = function(path, content, policy)
      if path == root .. "/second.txt" then
        assert(fs.write_all(path, "concurrent change\n"))
      end
      return fs.atomic_replace(path, content, policy)
    end
    local request = patch_tool.prepare({
      patch = [[*** Begin Patch
*** Add File: first.txt
+first
*** Update File: second.txt
@@
-old
+new
*** Add File: third.txt
+third
*** End Patch]],
    }, {}, invocation)
    local result = patch_tool.run(request, invocation, { fs = filesystem })
    assert.is_true(result.isError)
    assert.are.equal("first\n", fs.read(root .. "/first.txt"))
    assert.are.equal("concurrent change\n", fs.read(root .. "/second.txt"))
    assert.is_nil(vim.uv.fs_stat(root .. "/third.txt"))
    assert.are.same({ root .. "/first.txt" }, changed)
    local presentation = require("neoagent.tools.common.patch_presentation").render({
      arguments = { patch = request.patch },
      result = result,
      state = "error",
    })
    assert(presentation and presentation.kind == "patch")
    assert.are.equal("applied", assert(presentation.files[1]).status)
    assert.are.equal(1, assert(presentation.files[1]).added)
    assert.are.equal("failed", assert(presentation.files[2]).status)
    assert.are.equal("pending", assert(presentation.files[3]).status)
    local card = assert(require("neoagent.ui.tool_presentation").codex(presentation, { width = 80 }))
    local title = assert(card.title)
    assert(type(title) == "table")
    assert.are.equal("+1", assert(title[3]).text)
    assert.are.equal("-0", assert(title[5]).text)
  end)

  it("retains a moved destination when source removal detects a concurrent change", function()
    local root = workspace()
    assert(fs.write_all(root .. "/source.txt", "old\n"))
    local invocation = call(root)
    local filesystem = util.copy(fs)
    filesystem.remove_file = function(path, fingerprint)
      assert(fs.write_all(path, "changed concurrently\n"))
      return fs.remove_file(path, fingerprint)
    end
    local request = patch_tool.prepare({
      patch = [[*** Begin Patch
*** Update File: source.txt
*** Move to: destination.txt
@@
-old
+new
*** End Patch]],
    }, {}, invocation)
    local result = patch_tool.run(request, invocation, { fs = filesystem })
    assert.is_true(result.isError)
    assert.are.equal("new\n", fs.read(root .. "/destination.txt"))
    assert.are.equal("changed concurrently\n", fs.read(root .. "/source.txt"))
    assert.are.same({ root .. "/destination.txt" }, assert(result.details).changed_paths)
    local presentation = require("neoagent.tools.common.patch_presentation").render({
      arguments = { patch = request.patch },
      result = result,
      state = "error",
    })
    assert(presentation and presentation.kind == "patch")
    local moved = assert(presentation.files[1])
    assert.are.equal(1, #presentation.files)
    assert.are.equal("partial", moved.status)
    assert.are.equal("source.txt", moved.path)
    assert.are.equal("destination.txt", moved.destination)
    assert.are.equal(1, moved.added)
    assert.are.equal(0, moved.removed)
    local effects = assert(assert(result.details.changes[1]).effects)
    assert.are.equal("applied", assert(effects[1]).status)
    assert.are.equal("failed", assert(effects[2]).status)
  end)

  async_test("snapshots original and processed images and preserves detail through request encoding", function()
    local root = workspace()
    local converted = require("neoagent.subprocess_common").run({
      argv = { "magick", "-size", "2400x128", "xc:blue", root .. "/image.png" },
      cwd = root,
      stdio = { kind = "pipes" },
      timeout_ms = 10000,
    }, { capture = { max_bytes = 10000 } })
    assert.are.equal(0, converted.code)
    local bytes = assert(fs.read(root .. "/image.png"))
    local attachments = require("tests.helpers.attachments").new()
    local invocation = call(root)
    invocation.artifacts = { put = attachments.files.put }
    local view = require("neoagent.tools.codex.view_image")
    local original = view.run(
      view.prepare({ path = "image.png", detail = "original" }, {}, invocation),
      invocation,
      require("neoagent.tools.read_file")._dependencies()
    )
    local high = view.run(
      view.prepare({ path = "image.png" }, {}, invocation),
      invocation,
      require("neoagent.tools.read_file")._dependencies()
    )
    local first, second = original.content[1], high.content[1]
    assert(first and first.type == "image" and second and second.type == "image")
    assert.are.equal("original", first.detail)
    assert.are.equal("high", second.detail)
    assert.are_not.equal(first.file_id, second.file_id)
    assert(fs.write_all(root .. "/image.png", "not an image"))
    assert.are.equal(bytes, require("neoagent.files").read(attachments.files, first.file_id, first.bytes))
    local fake = require("tests.helpers.fake_transport").new({
      {
        chunks = {
          'data: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n',
        },
      },
    })
    local model = require("neoagent.api.openai_responses").new({
      provider = "test",
      model = "test",
      base_url = "https://example.test",
      input = { "text", "image" },
      supports_image_detail_original = true,
      transport = fake,
    })
    assert(
      model
        :stream({ messages = { { role = "user", content = { first, second } } }, files = attachments.files })
        :await().ok
    )
    local body = vim.json.decode((assert(assert(fake.requests[1]).body)))
    assert.are.equal("original", body.input[1].content[1].detail)
    assert.are.equal("high", body.input[1].content[2].detail)
    assert.is_false(
      pcall(
        view.run,
        view.prepare({ path = "image.png" }, {}, invocation),
        invocation,
        require("neoagent.tools.read_file")._dependencies()
      )
    )
    local proxy = assert(require("neoagent.rpc.registry").proxy(view.new(), {
      call = invocation,
      invoke = function()
        error("image request must fail before worker dispatch")
      end,
    }))
    local model_context = {
      model = require("tests.helpers.fake_model").new(),
      run = assert(require("neoagent.async").current()),
      execute_tool = function()
        error("unused")
      end,
      context = { workspace = invocation.workspace, files = attachments.files },
      call = { type = "toolCall", id = "image", name = "view_image", arguments = {} },
      on_update = function() end,
    }
    local allowed, failure = pcall(proxy.execute, { path = "image.png" }, model_context)
    assert.is_false(allowed)
    assert.matches("image%-capable Models", tostring(failure))
  end)
end)
