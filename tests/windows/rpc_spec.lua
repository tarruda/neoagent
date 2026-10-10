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

  local custody_module = require("neoagent.sandbox.windows.custody")
  local new_custody = custody_module.new
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
    custody_module.new = new_custody
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
    local child = require("tests.helpers.sandbox").start_worker(windows, {
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
    ---@type Neoagent.WindowsSandboxCustody?
    local custody
    custody_module.new = function(directory, recover)
      custody = new_custody(directory, recover)
      return custody
    end
    local connection, child, call = start()
    custody_module.new = new_custody
    local job = assert(assert(custody)._job)
    local ffi = require("ffi")
    local kernel = ffi.load("kernel32")
    local accounting = ffi.new("NASandboxJobAccounting") --[[@as Neoagent.WindowsSandboxJobAccounting]]
    local function active_processes()
      assert(kernel.QueryInformationJobObject(assert(job.handle), 1, accounting, ffi.sizeof(accounting), nil) ~= 0)
      return accounting.ActiveProcesses
    end
    assert.are.equal(1, active_processes(), "only the RPC worker should be running")
    local fixture = vim.fs.joinpath(assert(vim.uv.cwd()), "tests", "fixtures", "rpc_cancel_tree.lua")
    local gate, descendant_ready = root .. "/spawn-child", root .. "/child-ready"
    local ready = false
    local request = connection:start_request("shell", {
      argv = {
        assert(vim.env.NEOAGENT_NVIM),
        "--headless",
        "--noplugin",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-n",
        "-l",
        fixture,
        assert(vim.env.NEOAGENT_NVIM),
        gate,
        descendant_ready,
      },
      timeout_ms = 30000,
    }, {
      on_event = function(message)
        if message.name == codec.events.update then
          local content = assert(message.value.content[1]).text
          ready = content:find("PARENT_READY", 1, true) ~= nil
        end
      end,
    })
    -- RPC progress proves that the parent is attached to its request Job.
    -- Only then let it create a descendant, which must inherit that ownership.
    assert(
      vim.wait(60000, function()
        return ready or request._run:is_done()
      end, 10),
      "command parent did not announce readiness"
    )
    assert.is_false(request._run:is_done(), vim.inspect(request._run:result()))
    assert.are.equal(2, active_processes(), "worker and command parent must be running")
    assert(fs.write_all(gate, "start"))
    assert(
      vim.wait(60000, function()
        return vim.uv.fs_stat(descendant_ready) ~= nil or request._run:is_done()
      end, 10),
      "command descendant did not announce readiness"
    )
    assert.is_false(request._run:is_done(), vim.inspect(request._run:result()))
    assert.are.equal(3, active_processes(), "worker, command, and descendant must all be running")
    request:cancel()
    wait(async.run(function()
      connection:wait_cancelled()
      -- Check before closing the sandbox worker: its outer Job must not hide
      -- a failure to terminate the request's own process tree.
      assert(
        vim.wait(5000, function()
          return active_processes() == 1
        end, 10),
        "cancelled command or descendant remains in the sandbox Job"
      )
      local value = tool_client.invoke(
        connection,
        "write_file",
        { path = "after.txt", resolved_path = root .. "/after.txt", content = "reused" },
        call
      )
      assert.is_nil(value.isError)
      connection:close()
      assert.are.equal(0, child:wait().code)
    end))
    assert.are.equal("reused", fs.read(root .. "/after.txt"))
    -- A new invocation must acquire the restored ACL lease after shutdown.
    local next_connection, next_child, next_call = start()
    wait(async.run(function()
      tool_client.invoke(
        next_connection,
        "write_file",
        { path = "after.txt", resolved_path = root .. "/after.txt", content = "new lease" },
        next_call
      )
      next_connection:close()
      assert.are.equal(0, next_child:wait().code)
    end))
    assert.are.equal("new lease", fs.read(root .. "/after.txt"))
  end)
end)
