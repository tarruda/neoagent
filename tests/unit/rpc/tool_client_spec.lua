local tool_client = require("neoagent.rpc.tool_client")
local codec = require("neoagent.rpc.codec")
local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local protocol = require("neoagent.rpc.protocol")
local util = require("neoagent.util")

---@generic T
---@param run Neoagent.Run<T, unknown>
---@param detail? fun(): unknown
---@return Neoagent.RunResult<T>
local function wait(run, detail)
  assert(vim.wait(10000, function()
    return run:is_done()
  end), "Tool RPC connection did not settle: " .. vim.inspect(detail and detail() or {}))
  local result = assert(run:result())
  return result
end

---@param root string
---@param files? Neoagent.Files
---@return Neoagent.ToolOperationCall
local function call(root, files)
  return {
    workspace = { root = root, cwd = root },
    artifacts = files and { put = files.put } or nil,
    on_update = function() end,
  }
end

---@param root string
---@return Neoagent.RpcConnection, Neoagent.WorkerLease, fun(): Neoagent.WorkerResult?
local function start_remote(root, environment)
  local remote = require("neoagent.rpc.connection").new()
  ---@type Neoagent.WorkerResult?
  local exited
  local child = require("tests.helpers.tool_worker").start_worker({
    cwd = root,
    nvim = vim.env.NEOAGENT_NVIM,
    env = environment,
    on_stdout = function(data)
      remote:feed(data)
    end,
    on_exit = function(result)
      exited = result
      remote:eof(result)
    end,
  })
  remote:attach(child)
  return remote, child, function()
    return exited
  end
end

describe("neoagent Tool RPC connection", function()
  local roots = {}
  local children = {}

  after_each(function()
    for _, child in ipairs(children) do
      child:dispose("Tool RPC connection test cleanup")
    end
    children = {}
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
    roots = {}
  end)

  local function temp()
    local root = vim.fn.tempname()
    roots[#roots + 1] = root
    assert(vim.fn.mkdir(root, "p") == 1)
    return root
  end

  it("uses copied workspace paths literally in a different worker environment", function()
    if jit.os == "Windows" then
      pending("POSIX literal dollar paths")
      return
    end
    local root = temp()
    local literal = root .. "/$NEOAGENT_WORKER_CWD/value"
    local expanded = root .. "/other/value"
    assert(fs.mkdirp(literal))
    assert(fs.mkdirp(expanded))
    assert(fs.write_all(literal .. "/literal.txt", "needle literal\n"))
    assert(fs.write_all(expanded .. "/expanded.txt", "needle expanded\n"))
    local environment = require("tests.helpers.tool_worker").environment()
    environment.NEOAGENT_WORKER_CWD = "other"
    local remote, child = start_remote(literal, environment)
    children[#children + 1] = child
    local active_call = call(literal)
    local value = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      local shell = tool_client.invoke(remote, "shell", { argv = { "sh", "-c", "pwd" }, timeout_ms = 5000 }, active_call)
      local found = tool_client.invoke(remote, "find", { pattern = "*.txt", resolved_path = literal, limit = 20 }, active_call)
      local matched = tool_client.invoke(remote, "grep", {
        pattern = "needle", resolved_path = literal, literal = true, ignore_case = false, limit = 20,
      }, active_call)
      remote:close()
      child:wait()
      return { shell = shell, found = found, matched = matched }
    end))
    assert.is_not_false(value.ok, vim.inspect(value))
    assert.matches(literal, value.shell.content[1].text, 1, true)
    assert.matches("literal.txt", value.found.content[1].text, 1, true)
    assert.matches("needle literal", value.matched.content[1].text, 1, true)
  end)

  for _, ending in ipairs({ "cancellation", "timeout" }) do
    it("stops command descendants after " .. ending .. " while retaining the worker connection", function()
      if jit.os == "Windows" then
        pending("POSIX shell descendants")
        return
      end
      local root = temp()
      local started, late = root .. "/started", root .. "/late"
      local remote, child = start_remote(root)
      children[#children + 1] = child
      local active_call = call(root)
      assert.is_true(wait(async.run(function()
        remote:open(codec.encode_context(active_call))
        return true
      end)))
      local command = (ending == "cancellation" and "trap '' TERM; " or "")
        .. "(trap '' TERM; sleep 0.5; printf late > " .. vim.fn.shellescape(late)
        .. ") </dev/null >/dev/null 2>&1 & printf started > " .. vim.fn.shellescape(started) .. "; wait"
      local request = remote:start_request("shell", {
        argv = { "sh", "-c", command }, timeout_ms = ending == "timeout" and 200 or 5000,
      }, { on_event = function() end })
      assert(vim.wait(5000, function() return vim.uv.fs_stat(started) ~= nil end, 5))
      if ending == "cancellation" then
        request:cancel()
      end
      assert(vim.wait(3000, function() return remote._state == "open" end, 5))
      local survived = vim.wait(1000, function() return vim.uv.fs_stat(late) ~= nil end, 5)
      local reused = wait(async.run(function()
        local written = tool_client.invoke(remote, "write_file", { path = "next.txt", resolved_path = root .. "/next.txt", content = "next" }, active_call)
        remote:close()
        child:wait()
        return written
      end))
      assert.is_false(survived)
      assert.is_nil(reused.isError)
      assert.are.equal("next", fs.read(root .. "/next.txt"))
    end)
  end

  it("executes every sandbox-eligible typed operation through one real isolated child", function()
    local root = temp()
    local image = vim.base64.decode(
      "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAAAIklEQVR4nGP4z8BAEiJR+X9SlY9aMGrBqAWjFoxaMCAWAABQpv4QX+h4RQAAAABJRU5ErkJggg=="
    )
    assert(fs.write_all(root .. "/image.png", image))
    assert(fs.write_all(root .. "/search.txt", "Needle one\nneedle two\n"))
    assert(fs.mkdirp(root .. "/nested"))
    assert(fs.write_all(root .. "/nested/found.txt", "found\n"))

    local files = require("neoagent.files.memory").new()
    local active_call = call(root, files)
    local updates = {}
    active_call.on_update = function(update)
      updates[#updates + 1] = update
    end
    local remote, child, exited = start_remote(root)
    children[#children + 1] = child

    local value = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      local written = tool_client.invoke(remote, "write_file", { path = "remote.txt", resolved_path = root .. "/remote.txt", content = "alpha\n" }, active_call)
      local edited = tool_client.invoke(remote, "edit_file", {
        path = "remote.txt", resolved_path = root .. "/remote.txt",
        edits = { { old_text = "alpha", new_text = "beta" } },
      }, active_call)
      local read = tool_client.invoke(remote, "read_file", {
        path = "remote.txt", resolved_path = root .. "/remote.txt",
        offset = 1,
        max_image_input_bytes = 1024 * 1024,
        max_image_pixels = 1024 * 1024,
        max_image_output_bytes = 1024 * 1024,
      }, active_call)
      local shell = tool_client.invoke(remote, "shell", {
        argv = { "sh", "-c", "printf remote-shell" },
        timeout_ms = 5000,
      }, active_call)
      local grep = tool_client.invoke(remote, "grep", {
        pattern = "needle",
        path = "search.txt", resolved_path = root .. "/search.txt",
        ignore_case = true,
        literal = true,
        context = 0,
        limit = 20,
      }, active_call)
      local find = tool_client.invoke(remote, "find", { pattern = "*.txt", path = "nested", resolved_path = root .. "/nested", limit = 20 }, active_call)
      local image_result = tool_client.invoke(remote, "read_file", {
        path = "image.png", resolved_path = root .. "/image.png",
        offset = 1,
        max_image_input_bytes = 1024 * 1024,
        max_image_pixels = 1024 * 1024,
        max_image_output_bytes = 1024 * 1024,
      }, active_call)
      local failed_shell = tool_client.invoke(remote, "shell", {
        argv = { "sh", "-c", "printf failed; exit 7" },
        timeout_ms = 5000,
      }, active_call)
      remote:close()
      return {
        written = written,
        edited = edited,
        read = read,
        shell = shell,
        grep = grep,
        find = find,
        image = image_result,
        failed_shell = failed_shell,
      }
    end), function()
      return {
        state = remote._state,
        queue = remote._queue,
        failure = remote._failure,
        exit = remote._exit,
      }
    end)

    assert.are.equal("beta\n", assert(fs.read(root .. "/remote.txt")))
    assert.are.equal("beta\n", assert(value.read.content[1]).text)
    assert.are.same({ root .. "/remote.txt" }, value.written.details.changed_paths)
    assert.are.same({ root .. "/remote.txt" }, value.edited.details.changed_paths)
    assert.matches("remote%-shell", assert(value.shell.content[1]).text)
    assert.matches("Needle one", assert(value.grep.content[1]).text, 1, true)
    assert.matches("found.txt", assert(value.find.content[1]).text, 1, true)
    assert.is_true(value.failed_shell.isError)
    assert.are.equal(7, value.failed_shell.details.exit_code)
    assert.is_nil(value.failed_shell.details.diagnostic_output)
    assert.is_true(#updates >= 2)
    local image_block = assert(value.image.content[2])
    assert.are.equal("image", image_block.type)
    local retained = require("tests.helpers.attachments").new(files).read(image_block)
    assert.is_truthy(require("neoagent.tools.read_file").detect_mime(retained))
    assert(vim.wait(3000, function()
      return exited() ~= nil
    end))
    assert.are.equal(0, assert(exited()).code)
  end)

  it("returns a successful bounded result after editing a very long line", function()
    local root = temp()
    local original = string.rep("a", 265000)
      .. "OLD_MARKER"
      .. string.rep("b", 265000)
      .. "\n"
    assert(fs.write_all(root .. "/large.txt", original))
    local active_call = call(root)
    local remote, child, exited = start_remote(root)
    children[#children + 1] = child

    local edited = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      local value = tool_client.invoke(remote, "edit_file", {
        path = "large.txt", resolved_path = root .. "/large.txt",
        edits = { { old_text = "OLD_MARKER", new_text = "NEW_MARKER" } },
      }, active_call)
      remote:close()
      return value
    end))

    if edited.ok == false then
      assert.is_true(false, assert(edited.error).message)
    end
    local changed = assert(fs.read(root .. "/large.txt"))
    assert.matches("NEW_MARKER", changed, 1, true)
    local details = assert(edited.details)
    assert.is_true(details.patch_truncated)
    assert.is_true(details.patch_bytes > protocol.MAX_FRAME)
    assert.is_true(#details.patch < protocol.MAX_FRAME)
    assert(vim.wait(3000, function()
      return exited() ~= nil
    end))
    assert.are.equal(0, assert(exited()).code)
  end)

  it("streams large write and edit request bodies across protocol frames", function()
    local root = temp()
    assert(fs.write_all(root .. "/large-edit.txt", "old\n"))
    local active_call = call(root)
    local remote, child, exited = start_remote(root)
    children[#children + 1] = child
    local content = string.rep("x", protocol.MAX_FRAME * 3)
    local replacement = string.rep("y", protocol.MAX_FRAME)

    local values = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      local written = tool_client.invoke(remote, "write_file", {
        path = "large-request.txt", resolved_path = root .. "/large-request.txt",
        content = content,
      }, active_call)
      local edited = tool_client.invoke(remote, "edit_file", {
        path = "large-edit.txt", resolved_path = root .. "/large-edit.txt",
        edits = { { old_text = "old", new_text = replacement } },
      }, active_call)
      remote:close()
      return { written = written, edited = edited }
    end), function()
      return {
        state = remote._state,
        failure = remote._failure,
        exit = remote._exit,
      }
    end)

    assert.is_nil(values.written.isError)
    assert.is_nil(values.edited.isError)
    assert.are.same({ root .. "/large-request.txt" }, assert(values.written.details).changed_paths)
    assert.are.same({ root .. "/large-edit.txt" }, assert(values.edited.details).changed_paths)
    assert.are.equal(content, assert(fs.read(root .. "/large-request.txt")))
    assert.are.equal(replacement .. "\n", assert(fs.read(root .. "/large-edit.txt")))
    assert(vim.wait(3000, function()
      return exited() ~= nil
    end))
    assert.are.equal(0, assert(exited()).code)
  end)

  it("rejects unprepared targets without effects and keeps the worker reusable", function()
    local root = temp()
    local target = root .. "/existing.txt"
    assert(fs.write_all(target, "original bytes"))
    local active_call = call(root)
    local remote, child = start_remote(root)
    children[#children + 1] = child
    local completed = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      for _, invocation in ipairs({
        { method = "write_file", payload = { path = "existing.txt", content = "changed" } },
        { method = "edit_file", payload = { path = "existing.txt",
          edits = { { old_text = "original", new_text = "changed" } } } },
        { method = "read_file", payload = { path = "existing.txt", offset = 1,
          max_image_input_bytes = 1024, max_image_pixels = 1024, max_image_output_bytes = 1024 } },
        { method = "grep", payload = { pattern = "original", ignore_case = false, literal = false, limit = 10 } },
        { method = "find", payload = { pattern = "*", limit = 10 } },
      }) do
        for _, unresolved in ipairs({ false, "existing.txt" }) do
          local payload = vim.tbl_extend("force", {}, invocation.payload, { resolved_path = unresolved or nil })
          local accepted, err = pcall(remote.request, remote, invocation.method, payload)
          assert.is_false(accepted, invocation.method)
          assert.matches("resolved path", util.normalize_error(err).message, 1, true)
          assert.are.equal("original bytes", fs.read(target))
        end
      end
      local result = tool_client.invoke(remote, "write_file", { path = "existing.txt", resolved_path = target, content = "prepared" }, active_call)
      remote:close()
      child:wait()
      return result
    end))
    assert.is_nil(completed.isError)
    assert.are.equal("prepared", fs.read(target))
  end)

  it("rejects oversized paths in the worker before changing files", function()
    local root = temp()
    assert(fs.write_all(root .. "/existing.txt", "original bytes"))
    local active_call = call(root)
    local remote, child = start_remote(root)
    children[#children + 1] = child
    local oversized = string.rep("./", 600000) .. "existing.txt"
    local failures = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      local errors = {}
      for _, invocation in ipairs({
        { method = "write_file", payload = { path = oversized, resolved_path = root .. "/existing.txt", content = "changed" } },
        { method = "edit_file", payload = { path = oversized, resolved_path = root .. "/existing.txt",
          edits = { { old_text = "original", new_text = "changed" } } } },
      }) do
        local ok, err = pcall(remote.request, remote, invocation.method, invocation.payload)
        assert.is_false(ok)
        errors[#errors + 1] = util.normalize_error(err)
      end
      remote:close()
      return errors
    end))
    assert.are.equal(2, #failures)
    for _, err in ipairs(failures) do
      assert.are.equal("tool", err.kind)
      assert.matches("path must not exceed", err.message, 1, true)
    end
    assert.are.equal("original bytes", assert(fs.read(root .. "/existing.txt")))
  end)

  it("keeps the child usable after typed request and operation failures", function()
    local root = temp()
    assert(fs.write_all(root .. "/existing.txt", "unchanged\n"))
    local active_call = call(root)
    local remote, child = start_remote(root)
    children[#children + 1] = child

    local value = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      ---@async
      ---@param operation async fun(): unknown
      local function failure(operation)
        local ok, err = pcall(operation)
        assert.is_false(ok)
        return util.normalize_error(err, "tool_arguments")
      end
      local failures = {
        read = failure(function()
          return tool_client.invoke(remote, "read_file", {
            path = "missing.txt", resolved_path = root .. "/missing.txt",
            offset = 1,
            max_image_input_bytes = 1024,
            max_image_pixels = 1024,
            max_image_output_bytes = 1024,
          }, active_call)
        end),
        edit = failure(function()
          return tool_client.invoke(remote, "edit_file", {
            path = "existing.txt", resolved_path = root .. "/existing.txt",
            edits = { { old_text = "absent", new_text = "replacement" } },
          }, active_call)
        end),
        grep = failure(function()
          return tool_client.invoke(remote, "grep", {
            pattern = "value",
            path = "missing", resolved_path = root .. "/missing",
            ignore_case = false,
            literal = false,
            context = 0,
            limit = 10,
          }, active_call)
        end),
        find = failure(function()
          return tool_client.invoke(remote, "find", { pattern = "*", path = "missing", resolved_path = root .. "/missing", limit = 10 }, active_call)
        end),
        arguments = failure(function()
          return tool_client.invoke(remote, "write_file", {
            path = "invalid.txt", resolved_path = root .. "/invalid.txt",
            content = "invalid",
            unexpected = true,
          } --[[@as Neoagent.WriteFileRequest]], active_call)
        end),
      }
      local recovered = tool_client.invoke(remote, "read_file", {
        path = "existing.txt", resolved_path = root .. "/existing.txt",
        offset = 1,
        max_image_input_bytes = 1024,
        max_image_pixels = 1024,
        max_image_output_bytes = 1024,
      }, active_call)
      remote:close()
      return { failures = failures, recovered = recovered }
    end))

    assert.matches("Could not read file", value.failures.read.message)
    assert.matches("Could not find", value.failures.edit.message)
    assert.matches("rg exited", value.failures.grep.message)
    assert.matches("Failed to start process", value.failures.find.message)
    assert.matches("unknown field", value.failures.arguments.message)
    assert.are.equal("unchanged\n", value.recovered.content[1].text)
    assert.is_nil(fs.read(root .. "/invalid.txt"))
  end)

  it("cancels a real worker request without closing its connection or lease", function()
    local root = temp()
    local active_call = call(root)
    local remote, child, exited = start_remote(root)
    children[#children + 1] = child
    local run = async.run(function()
      remote:open(codec.encode_context(active_call))
      return tool_client.invoke(remote, "shell", {
        argv = { "sh", "-c", "sleep 30" },
        timeout_ms = 60000,
      }, active_call)
    end)
    assert(vim.wait(5000, function()
      return remote._state == "request"
    end), vim.inspect(remote._failure))

    run:cancel()

    local value = wait(run)
    assert.is_false(value.ok)
    assert.are.equal("cancelled", value.error.kind)
    assert(vim.wait(3000, function()
      return remote._state == "open"
    end), vim.inspect({ state = remote._state, failure = remote._failure }))
    assert.is_nil(exited())
    local shutdown = wait(async.run(function()
      remote:close()
      return child:wait()
    end))
    assert.are.equal("closed", remote._state)
    assert.are.equal(0, shutdown.code)
    assert.are.equal(0, assert(exited()).code)
  end)

  it("contains host-worker subprocesses when cancellation is followed by shutdown", function()
    if jit.os == "Windows" then
      pending("POSIX process groups exercise host-worker descendant containment")
      return
    end
    local root = temp()
    local started = root .. "/host-worker-started"
    local late = root .. "/host-worker-late"
    local active_call = call(root)
    local remote, child = start_remote(root)
    children[#children + 1] = child
    local opened = wait(async.run(function()
      remote:open(codec.encode_context(active_call))
      return true
    end))
    assert.is_true(opened)
    local command = "trap '' TERM; (trap '' TERM; sleep 0.5; printf late > "
      .. vim.fn.shellescape(late)
      .. ") & printf started > "
      .. vim.fn.shellescape(started)
      .. "; wait"
    local request = remote:start_request("shell", {
      argv = { "sh", "-c", command }, timeout_ms = 60000,
    })
    assert(vim.wait(5000, function()
      return vim.uv.fs_stat(started) ~= nil or request._run:is_done()
    end, 10))
    assert.is_false(request._run:is_done())

    request:cancel()

    local cancelled = wait(async.run(function() return request:result() end))
    assert.is_false(cancelled.ok)
    assert.are.equal("cancelled", cancelled.error.kind)
    assert(vim.wait(3000, function() return remote._state == "open" end, 10))
    local shutdown = wait(async.run(function()
      remote:close()
      return child:wait()
    end))
    assert.are.equal(0, shutdown.code)
    local appeared = vim.wait(1200, function()
      return vim.uv.fs_stat(late) ~= nil
    end, 10)
    assert.is_false(appeared)
    assert.is_nil(vim.uv.fs_stat(late))
  end)
end)
