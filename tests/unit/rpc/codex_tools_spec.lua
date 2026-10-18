local assert = require("luassert")
local it = require("tests.helpers.async_test")
local async = require("neoagent.async")
local codec = require("neoagent.rpc.codec")
local fs = require("neoagent.fs")
local util = require("neoagent.util")

describe("Codex Tool worker publication", function()
  local roots, children, servers = {}, {}, {}

  after_each(function()
    for _, server in ipairs(servers) do
      server:eof()
    end
    for _, child in ipairs(children) do
      child:dispose("test finished")
      require("tests.helpers.subprocess").complete(function()
        return child:wait()
      end, 10000)
    end
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
  end)

  local function workspace()
    local root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    roots[#roots + 1] = root
    return root
  end

  it("validates and publishes image artifacts through the worker server dispatch", function()
    local root = workspace()
    local created = require("neoagent.subprocess_common").run({
      argv = { "magick", "-size", "2x1", "xc:blue", root .. "/image.png" },
      cwd = root,
      stdio = { kind = "pipes" },
      timeout_ms = 10000,
    }, { capture = { max_bytes = 10000 } })
    assert.are.equal(0, created.code)
    local domain = require("neoagent.rpc.tool_server").new({})
    local call = { workspace = { root = root, cwd = root }, on_update = function() end }
    domain.open(codec.encode_context(call))
    local events = {}
    local view = require("neoagent.tools.codex.view_image")
    local request = domain.request(
      "view_image",
      view.prepare({ path = "image.png", detail = "original" }, {}, call),
      function(name, value)
        events[#events + 1] = { name = name, value = value }
      end,
      function()
        return false
      end
    )
    local result = request.finish(request.execute())
    domain.close("test finished")
    local block = assert(result.content[1])
    assert(block)
    assert.are.equal("image", block.type)
    assert.are.equal("original", block.detail)
    local first, last = events[1], events[#events]
    assert(first and last)
    assert.are.equal(codec.events.artifact_begin, first.name)
    assert.are.equal(codec.events.artifact_end, last.name)
    local chunks = {}
    for _, event in ipairs(events) do
      if event.name == codec.events.artifact_chunk then
        chunks[#chunks + 1] = event.value.data
      end
    end
    assert.are.equal(fs.read(root .. "/image.png"), table.concat(chunks))
  end)

  it("delivers verified file effects independently of request cancellation", function()
    local root = workspace()
    local filesystem = util.copy(fs)
    local waiting = false
    ---@async
    filesystem.atomic_replace = function(path, content, policy)
      if path == root .. "/second.txt" then
        waiting = true
        async.await(function() end)
      end
      return fs.atomic_replace(path, content, policy)
    end
    local events = {}
    local server = require("neoagent.rpc.server").new({
      send = function(message)
        events[#events + 1] = message
      end,
      dependencies = { fs = filesystem },
    })
    servers[#servers + 1] = server
    local call = { workspace = { root = root, cwd = root }, on_update = function() end }
    server:receive({ type = "open", call_id = "patch", context = codec.encode_context(call) })
    local patch = require("neoagent.tools.codex.apply_patch").prepare(
      { patch = [[*** Begin Patch
*** Add File: first.txt
+first
*** Add File: second.txt
+second
*** End Patch]] },
      {},
      call
    )
    server:receive({ type = "request", call_id = "patch", request_id = 1, method = "apply_patch", payload = patch })
    assert(vim.wait(1000, function()
      return waiting
    end))
    local publication = assert(events[#events])
    assert(publication)
    assert.are.equal(codec.events.file_changed, publication.name)
    assert.is_nil(publication.request_id)
    assert.are.equal(root .. "/first.txt", publication.value.path)
    server:receive({ type = "cancel", call_id = "patch", request_id = 1 })
    assert(vim.wait(1000, function()
      return server:is_quiescent()
    end))
    local terminal = events[#events]
    assert(terminal)
    assert(terminal.type == "cancelled" or terminal.type == "response")
    if terminal.type == "response" then
      assert.are.equal(true, rawget(terminal.value, "isError"))
    end
    assert.are.equal("first\n", fs.read(root .. "/first.txt"))
    assert.is_nil(vim.uv.fs_stat(root .. "/second.txt"))
    server:receive({ type = "close", call_id = "patch" })
    assert.is_true(server:is_quiescent())
  end)

  it("publishes completed file effects before a later write reaches its deadline", function()
    local root = workspace()
    local protocol = require("neoagent.rpc.protocol")
    local filesystem = util.copy(fs)
    local waiting = false
    ---@async
    filesystem.atomic_replace = function(path, content, policy)
      if path == root .. "/second.txt" then
        waiting = true
        async.await(function() end)
      end
      return fs.atomic_replace(path, content, policy)
    end
    local published = {}
    local remote = require("neoagent.rpc.connection").new({
      on_event = function(message)
        published[#published + 1] = message.value.path
      end,
    })
    local server = require("neoagent.rpc.server").new({
      send = function(message)
        remote:feed(protocol.encode(message))
      end,
      dependencies = { fs = filesystem },
    })
    servers[#servers + 1] = server
    local decoder = protocol.decoder(function(message)
      vim.schedule(function()
        server:receive(message)
      end)
    end)
    remote:attach({
      write = function(_, bytes)
        decoder:feed(bytes)
        return true
      end,
      close_stdin = function()
        return true
      end,
      terminate = function()
        server:eof()
      end,
      dispose = function()
        server:eof()
      end,
      wait = function()
        return { code = 0, signal = 0, stderr = "" }
      end,
    })
    local call = { workspace = { root = root, cwd = root }, on_update = function() end }
    local patch = require("neoagent.tools.codex.apply_patch").prepare(
      { patch = [[*** Begin Patch
*** Add File: first.txt
+first
*** Add File: second.txt
+second
*** End Patch]] },
      {},
      call
    )
    local run = async.run(function()
      remote:open(codec.encode_context(call))
      return require("neoagent.rpc.tool_client").invoke(remote, "apply_patch", patch, call)
    end)
    local reached = vim.wait(1000, function()
      return waiting
    end)
    -- Match the parent deadline: cancel the request and revoke its channel.
    remote:cancel()
    remote:abort()
    assert(vim.wait(1000, function()
      return run:is_done() and server:is_quiescent()
    end))
    assert(reached)
    assert.are.equal("first\n", fs.read(root .. "/first.txt"))
    assert.is_nil(vim.uv.fs_stat(root .. "/second.txt"))
    assert.are.same({ root .. "/first.txt" }, published)
  end)

  it("runs patches and imports original image artifacts through a real worker", function()
    local root = workspace()
    local converted = require("neoagent.subprocess_common").run({
      argv = { "magick", "-size", "4x3", "xc:red", root .. "/image.png" },
      cwd = root,
      stdio = { kind = "pipes" },
      timeout_ms = 10000,
    }, { capture = { max_bytes = 10000 } })
    assert.are.equal(0, converted.code)
    local published = {}
    local remote = require("neoagent.rpc.connection").new({
      on_event = function(message)
        assert.are.equal(codec.events.file_changed, message.name)
        published[#published + 1] = message.value.path
      end,
    })
    local child = require("tests.helpers.tool_worker").start_worker({
      cwd = root,
      nvim = vim.env.NEOAGENT_NVIM,
      on_stdout = function(data)
        remote:feed(data)
      end,
      on_exit = function(result)
        remote:eof(result)
      end,
    })
    children[#children + 1] = child
    remote:attach(child)
    local files = require("neoagent.files.memory").new()
    local call =
      { workspace = { root = root, cwd = root }, artifacts = { put = files.put }, on_update = function() end }
    remote:open(codec.encode_context(call))
    local patch = require("neoagent.tools.codex.apply_patch").prepare(
      { patch = [[*** Begin Patch
*** Add File: first.txt
+first
*** Add File: second.txt
+second
*** End Patch]] },
      {},
      call
    )
    local result = require("neoagent.rpc.tool_client").invoke(remote, "apply_patch", patch, call)
    assert.is_nil(result.isError)
    local view = require("neoagent.tools.codex.view_image")
    local image = require("neoagent.rpc.tool_client").invoke(
      remote,
      "view_image",
      view.prepare({ path = "image.png", detail = "original" }, {}, call),
      call
    )
    remote:close()
    child:wait()
    assert.are.same({ root .. "/first.txt", root .. "/second.txt" }, published)
    assert.are.equal("first\n", fs.read(root .. "/first.txt"))
    local block = image.content[1]
    assert(block and block.type == "image")
    assert.are.equal("original", block.detail)
    assert.are.equal(fs.read(root .. "/image.png"), require("neoagent.files").read(files, block.file_id, block.bytes))
  end)
end)
