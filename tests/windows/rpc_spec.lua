local tool_client = require("neoagent.rpc.tool_client")
local codec = require("neoagent.rpc.codec")
local assert = require("luassert")
local async = require("neoagent.async")
local fs = require("neoagent.fs")
local tool_worker = require("tests.helpers.tool_worker")
local windows = require("neoagent.sandbox.windows")

---@generic T
---@param run Neoagent.Run<T, unknown>
---@return T
local function wait(run)
  assert(
    vim.wait(120000, function()
      return run:is_done()
    end, 10),
    "native Tool RPC did not settle"
  )
  local value = assert(run:result())
  if value.ok == false then
    error(vim.inspect(value.error))
  end
  return value --[[@as T]]
end

describe("Windows native Tool RPC", function()
  if jit.os ~= "Windows" then
    pending("requires Windows")
    return
  end

  ---@type string
  local root
  ---@type Neoagent.WorkerLease[]
  local children = {}

  before_each(function()
    root = vim.fn.tempname() .. "-native-rpc"
    assert(fs.mkdirp(root))
    root = assert(vim.uv.fs_realpath(root))
  end)

  after_each(function()
    for _, child in ipairs(children) do
      child:dispose("native RPC scenario teardown")
      wait(async.run(function()
        return child:wait()
      end))
    end
    children = {}
    if root then
      vim.fn.delete(root, "rf")
    end
  end)

  local function start()
    local worker = require("neoagent.rpc.worker")
    local source = worker.worker_file()
    local nvim = worker.nvim_command(vim.env.NEOAGENT_NVIM)
    local bootstrap = worker.bootstrap_paths(source, nvim)
    local profile = require("neoagent.sandbox.profile").resolve({
      id = "windows-native-rpc",
      filesystem = {
        default = "read",
        entries = {
          { path = root, access = "write" },
          { path = windows.temporary_root(), access = "write" },
        },
      },
      network = "restricted",
      environment = { clear = true, inherit = {}, set = {} },
    }, nil, { paths = windows.paths })
    profile = windows.compile(profile)
    local environment = tool_worker.environment()
    environment.NEOAGENT_WORKER_FILE = source
    environment.TEMP = windows.temporary_root()
    environment.TMP = environment.TEMP
    environment.TMPDIR = environment.TEMP
    local connection = require("neoagent.rpc.connection").new()
    local child = windows.start_worker({
      argv = worker.argv(nvim, source),
      cwd = root,
      env = environment,
      profile = profile,
      bootstrap_paths = bootstrap,
      on_stdout = function(bytes)
        connection:feed(bytes)
      end,
      on_exit = function(value)
        connection:eof(value)
      end,
    }, { fs = fs, nvim = nvim })
    children[#children + 1] = child
    connection:attach(child)
    local files = require("neoagent.files.memory").new()
    local call =
      { workspace = { root = root, cwd = root }, artifacts = { put = files.put }, on_update = function() end }
    wait(async.run(function()
      assert(child.wait_ready)(child)
      connection:open(codec.encode_context(call))
    end))
    return connection, child, call, files
  end

  it("streams large file requests and verified binary artifacts through the restricted account", function()
    local connection, child, call, files = start()
    local original = string.rep("a", 3 * 1024 * 1024) .. "MARKER\r\n"
    local image = vim.base64.decode(
      "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAAAIklEQVR4nGP4z8BAEiJR+X9SlY9aMGrBqAWjFoxaMCAWAABQpv4QX+h4RQAAAABJRU5ErkJggg=="
    )
    assert(fs.write_all(root .. "/image.png", image))
    local result = wait(async.run(function()
      local written =
        tool_client.invoke(connection, "write_file", { path = "large.txt", resolved_path = root .. "/large.txt", content = original }, call)
      assert.is_nil(written.isError)
      local edited = tool_client.invoke(connection, "edit_file",
        {
          path = "large.txt",
          resolved_path = root .. "/large.txt",
          edits = { { old_text = "MARKER", new_text = "REPLACED" } },
        },
        call
      )
      assert.is_nil(edited.isError)
      assert.is_true(assert(edited.details).patch_truncated)
      local image_result = tool_client.invoke(connection, "read_file",
        {
          path = "image.png",
          resolved_path = root .. "/image.png",
          offset = 1,
          max_image_input_bytes = 1024 * 1024,
          max_image_pixels = 1024 * 1024,
          max_image_output_bytes = 1024 * 1024,
        },
        call
      )
      connection:close()
      assert.are.equal(0, child:wait().code)
      return image_result
    end))
    assert.are.equal(original:gsub("MARKER", "REPLACED"), fs.read(root .. "/large.txt"))
    local block = assert(result.content[2])
    assert.are.equal("image", block.type)
    local bytes = require("tests.helpers.attachments").new(files).read(block)
    assert.are.equal(block.bytes, #bytes)
    assert.are.equal(block.file_id, require("neoagent.files.digest").sha256(bytes))
  end)

  it("cancels a command tree, reuses its connection, and releases the native lease", function()
    local connection, child, call = start()
    local ready, late = root .. "/ready", root .. "/late"
    local program = root .. "/child.cmd"
    assert(fs.write_all(
      program,
      table.concat({
        "@echo off",
        'echo started>"' .. ready .. '"',
        "ping.exe -n 5 127.0.0.1 >nul",
        'echo survived>"' .. late .. '"',
        "",
      }, "\r\n")
    ))
    local request = connection:start_request("shell", {
      argv = { assert(vim.env.COMSPEC), "/d", "/s", "/c", 'call "' .. program .. '"' },
      timeout_ms = 30000,
    }, { on_event = function() end })
    assert(vim.wait(60000, function()
      return vim.uv.fs_stat(ready) ~= nil
    end, 10))
    request:cancel()
    wait(async.run(function()
      connection:wait_cancelled()
      local value =
        tool_client.invoke(connection, "write_file", { path = "after.txt", resolved_path = root .. "/after.txt", content = "reused" }, call)
      assert.is_nil(value.isError)
      connection:close()
      assert.are.equal(0, child:wait().code)
    end))
    assert.is_false((vim.wait(5500, function()
      return vim.uv.fs_stat(late) ~= nil
    end, 10)))
    assert.are.equal("reused", fs.read(root .. "/after.txt"))
    -- A new invocation must acquire the restored ACL lease after shutdown.
    local next_connection, next_child, next_call = start()
    wait(async.run(function()
      tool_client.invoke(next_connection, "write_file",
        { path = "after.txt", resolved_path = root .. "/after.txt", content = "new lease" },
        next_call
      )
      next_connection:close()
      assert.are.equal(0, next_child:wait().code)
    end))
    assert.are.equal("new lease", fs.read(root .. "/after.txt"))
  end)
end)
