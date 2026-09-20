local assert = require("luassert")
local fs = require("neoagent.fs")

describe("neoagent sandbox Tool RPC policy", function()
  local roots = {}

  after_each(function()
    for _, root in ipairs(roots) do
      vim.fn.delete(root, "rf")
    end
    roots = {}
  end)

  it("authorizes every typed filesystem intent before remote execution",
    ---@async
    function()
    local root = vim.fn.tempname()
    assert(fs.mkdirp(root))
    root = assert(vim.uv.fs_realpath(root))
    roots[#roots + 1] = root
    local denied = vim.fs.joinpath(root, "denied")
    local readonly = vim.fs.joinpath(root, "readonly")
    assert(fs.mkdirp(denied))
    assert(fs.mkdirp(readonly))
    assert(fs.write_all(vim.fs.joinpath(denied, "secret.txt"), "secret"))
    assert(fs.write_all(vim.fs.joinpath(readonly, "existing.txt"), "readonly"))
    assert(vim.uv.fs_symlink(denied, vim.fs.joinpath(root, "denied-link")))

    local api = require("neoagent.sandbox.tool_policy").new({
      profile = {
        id = "api-policy",
        filesystem = {
          default = "read",
          entries = {
            { path = root, access = "write" },
            { path = denied, access = "deny" },
            { path = readonly, access = "read" },
          },
        },
        network = "restricted",
        environment = { clear = true, inherit = {}, set = {} },
      },
      paths = require("neoagent.sandbox.path").posix,
      platform = "test",
    })
    local call = {
      workspace = { root = root, cwd = root },
      on_update = function() end,
    }
    local read_request = {
      path = "allowed.txt", resolved_path = root .. "/allowed.txt",
      offset = 1,
      max_image_input_bytes = 1024,
      max_image_pixels = 1024,
      max_image_output_bytes = 1024,
    }
    local original_target = vim.env.NEOAGENT_POLICY_TARGET
    vim.env.NEOAGENT_POLICY_TARGET = "parent-target"
    local prepared_read = api:authorize("read_file", read_request, call)
    local write_request = require("neoagent.tools.write_file").prepare({
      path = "$NEOAGENT_POLICY_TARGET.txt",
      content = "allowed",
    }, {}, call)
    local prepared_write = api:authorize("write_file", write_request, call)
    vim.env.NEOAGENT_POLICY_TARGET = original_target
    assert.are.equal("allowed.txt", prepared_read.path)
    assert.are.equal(read_request, prepared_read)
    assert.are.equal("$NEOAGENT_POLICY_TARGET.txt", prepared_write.path)
    assert.are.equal(vim.fs.joinpath(root, "parent-target.txt"), prepared_write.resolved_path)
    assert.are.equal(root .. "/allowed.txt", read_request.resolved_path)
    api:authorize("write_file", {
      path = "allowed.txt", resolved_path = root .. "/allowed.txt",
      content = "allowed",
    }, call)
    api:authorize("edit_file", {
      path = "allowed.txt", resolved_path = root .. "/allowed.txt",
      edits = { { old_text = "old", new_text = "new" } },
    }, call)
    local _, _, unlimited = api:authorize("shell", {
      argv = { "/usr/bin/true" },
    }, call)
    assert.is_nil(unlimited, "an explicitly unlimited shell must remain unlimited")
    local _, _, deadline = api:authorize("shell", {
      argv = { "/usr/bin/true" }, timeout_ms = 300000,
    }, call)
    assert.are.equal(302000, deadline)
    api:authorize("grep", {
      pattern = "needle", resolved_path = root,
      ignore_case = false,
      literal = false,
      limit = 10,
    }, call)
    api:authorize("find", {
      pattern = "*",
      path = root, resolved_path = root,
      limit = 10,
    }, call)
    local authorized, failure = pcall(api.authorize, api, "unregistered_method", {}, call)
    assert.is_false(authorized, "unknown methods must not pass sandbox authorization")
    local failure_value = require("neoagent.util").normalize_error(failure)
    assert.are.equal("sandbox", failure_value.kind)
    assert.matches("Unsupported Tool RPC method", failure_value.message, 1, true)

    ---@param callback async fun()
    ---@param operation string
    ---@param expected_path string
    ---@param expected_granted? Neoagent.SandboxAccess
    ---@async
    local function denied_call(callback, operation, expected_path, expected_granted)
      local ok, err = pcall(callback)
      assert.is_false(ok)
      if type(err) ~= "table" then
        error("expected a structured sandbox denial", 0)
      end
      ---@cast err Neoagent.SandboxToolDenial
      assert.are.equal("sandbox_denied", err.kind)
      assert.are.equal(operation, err.sandbox.operation)
      assert.are.equal(expected_path, err.sandbox.path)
      assert.are.equal(expected_granted or "deny", err.sandbox.granted)
      assert.are.equal("test", err.sandbox.backend)
    end
    denied_call(function()
      local request = vim.deepcopy(read_request)
      request.path = "denied/secret.txt"
      request.resolved_path = root .. "/denied/secret.txt"
      api:authorize("read_file", request, call)
    end, "filesystem.read", vim.fs.joinpath(denied, "secret.txt"))
    denied_call(function()
      api:authorize("write_file", { path = "denied/new.txt", resolved_path = root .. "/denied/new.txt", content = "blocked" }, call)
    end, "filesystem.write", vim.fs.joinpath(denied, "new.txt"))
    denied_call(function()
      api:authorize("edit_file", {
        path = "readonly/existing.txt", resolved_path = root .. "/readonly/existing.txt",
        edits = { { old_text = "readonly", new_text = "changed" } },
      }, call)
    end, "filesystem.write", vim.fs.joinpath(readonly, "existing.txt"), "read")
    denied_call(function()
      api:authorize("shell", { argv = { "/usr/bin/true" } }, {
        workspace = { root = root, cwd = denied },
        on_update = call.on_update,
      })
    end, "filesystem.read", denied)
    denied_call(function()
      api:authorize("grep", {
        pattern = "secret",
        path = "denied-link", resolved_path = root .. "/denied-link",
        ignore_case = false,
        literal = false,
        limit = 10,
      }, call)
    end, "filesystem.read", vim.fs.joinpath(root, "denied-link"))
    denied_call(function()
      api:authorize("find", { pattern = "*", path = denied, resolved_path = denied, limit = 10 }, call)
    end, "filesystem.read", denied)
  end)
end)
