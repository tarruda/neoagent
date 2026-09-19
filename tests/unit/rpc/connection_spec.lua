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
---@return Neoagent.TestToolRpcConnection, Neoagent.WorkerLease, fun(): Neoagent.WorkerResult?
local function start_remote(root)
  local remote = require("tests.helpers.tool_rpc").new()
  ---@type Neoagent.WorkerResult?
  local exited
  local child = require("neoagent.rpc.worker").start({
    cwd = root,
    nvim = vim.env.NEOAGENT_NVIM,
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
      remote:open_tool(active_call)
      local written = remote:write_file({ path = "remote.txt", content = "alpha\n" }, active_call)
      local edited = remote:edit_file({
        path = "remote.txt",
        edits = { { old_text = "alpha", new_text = "beta" } },
      }, active_call)
      local read = remote:read_file({
        path = "remote.txt",
        offset = 1,
        max_image_input_bytes = 1024 * 1024,
        max_image_pixels = 1024 * 1024,
        max_image_output_bytes = 1024 * 1024,
      }, active_call)
      local shell = remote:shell({
        argv = { "sh", "-c", "printf remote-shell" },
        timeout_ms = 5000,
      }, active_call)
      local grep = remote:grep({
        pattern = "needle",
        path = "search.txt",
        ignore_case = true,
        literal = true,
        context = 0,
        limit = 20,
      }, active_call)
      local find = remote:find({ pattern = "*.txt", path = "nested", limit = 20 }, active_call)
      local image_result = remote:read_file({
        path = "image.png",
        offset = 1,
        max_image_input_bytes = 1024 * 1024,
        max_image_pixels = 1024 * 1024,
        max_image_output_bytes = 1024 * 1024,
      }, active_call)
      local failed_shell = remote:shell({
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
    assert.are.same({ "remote.txt" }, value.written.details.changed_paths)
    assert.are.same({ "remote.txt" }, value.edited.details.changed_paths)
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
      remote:open_tool(active_call)
      local value = remote:edit_file({
        path = "large.txt",
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
      remote:open_tool(active_call)
      local written = remote:write_file({
        path = "large-request.txt",
        content = content,
      }, active_call)
      local edited = remote:edit_file({
        path = "large-edit.txt",
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
    assert.are.same({ "large-request.txt" }, assert(values.written.details).changed_paths)
    assert.are.same({ "large-edit.txt" }, assert(values.edited.details).changed_paths)
    assert.are.equal(content, assert(fs.read(root .. "/large-request.txt")))
    assert.are.equal(replacement .. "\n", assert(fs.read(root .. "/large-edit.txt")))
    assert(vim.wait(3000, function()
      return exited() ~= nil
    end))
    assert.are.equal(0, assert(exited()).code)
  end)

  it("rejects oversized paths in the worker before changing files", function()
    local root = temp()
    assert(fs.write_all(root .. "/existing.txt", "original bytes"))
    local active_call = call(root)
    local remote, child = start_remote(root)
    children[#children + 1] = child
    local oversized = string.rep("./", 600000) .. "existing.txt"
    local failures = wait(async.run(function()
      remote:open_tool(active_call)
      local errors = {}
      for _, invocation in ipairs({
        { method = "write_file", payload = { path = oversized, content = "changed" } },
        { method = "edit_file", payload = { path = oversized,
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
      remote:open_tool(active_call)
      ---@async
      ---@param operation async fun(): unknown
      local function failure(operation)
        local ok, err = pcall(operation)
        assert.is_false(ok)
        return util.normalize_error(err, "tool_arguments")
      end
      local failures = {
        read = failure(function()
          return remote:read_file({
            path = "missing.txt",
            offset = 1,
            max_image_input_bytes = 1024,
            max_image_pixels = 1024,
            max_image_output_bytes = 1024,
          }, active_call)
        end),
        edit = failure(function()
          return remote:edit_file({
            path = "existing.txt",
            edits = { { old_text = "absent", new_text = "replacement" } },
          }, active_call)
        end),
        grep = failure(function()
          return remote:grep({
            pattern = "value",
            path = "missing",
            ignore_case = false,
            literal = false,
            context = 0,
            limit = 10,
          }, active_call)
        end),
        find = failure(function()
          return remote:find({ pattern = "*", path = "missing", limit = 10 }, active_call)
        end),
        arguments = failure(function()
          return remote:write_file({
            path = "invalid.txt",
            content = "invalid",
            unexpected = true,
          } --[[@as Neoagent.WriteFileRequest]], active_call)
        end),
      }
      local recovered = remote:read_file({
        path = "existing.txt",
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
    assert.matches("unsupported field", value.failures.arguments.message)
    assert.are.equal("unchanged\n", value.recovered.content[1].text)
    assert.is_nil(fs.read(root .. "/invalid.txt"))
  end)

  it("cancels a real worker request without closing its connection or lease", function()
    local root = temp()
    local active_call = call(root)
    local remote, child, exited = start_remote(root)
    children[#children + 1] = child
    local run = async.run(function()
      remote:open_tool(active_call)
      return remote:shell({
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
end)
