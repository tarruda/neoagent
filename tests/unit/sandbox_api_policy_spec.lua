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

    local api = require("neoagent.sandbox.api_policy").new({
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
      path = "allowed.txt",
      offset = 1,
      max_image_input_bytes = 1024,
      max_image_pixels = 1024,
      max_image_output_bytes = 1024,
    }
    api:authorize("read_file", read_request, call)
    api:authorize("write_file", {
      path = "allowed.txt",
      content = "allowed",
    }, call)
    api:authorize("edit_file", {
      path = "allowed.txt",
      edits = { { old_text = "old", new_text = "new" } },
    }, call)
    api:authorize("shell", {
      argv = { "/usr/bin/true" },
    }, call)
    api:authorize("grep", {
      pattern = "needle",
      ignore_case = false,
      literal = false,
      limit = 10,
    }, call)
    api:authorize("find", {
      pattern = "*",
      path = root,
      limit = 10,
    }, call)

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
      ---@cast err Neoagent.SandboxApiDenial
      assert.are.equal("sandbox_denied", err.kind)
      assert.are.equal(operation, err.sandbox.operation)
      assert.are.equal(expected_path, err.sandbox.path)
      assert.are.equal(expected_granted or "deny", err.sandbox.granted)
      assert.are.equal("test", err.sandbox.backend)
    end
    denied_call(function()
      local request = vim.deepcopy(read_request)
      request.path = "denied/secret.txt"
      api:authorize("read_file", request, call)
    end, "filesystem.read", vim.fs.joinpath(denied, "secret.txt"))
    denied_call(function()
      api:authorize("write_file", { path = "denied/new.txt", content = "blocked" }, call)
    end, "filesystem.write", vim.fs.joinpath(denied, "new.txt"))
    denied_call(function()
      api:authorize("edit_file", {
        path = "readonly/existing.txt",
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
        path = "denied-link",
        ignore_case = false,
        literal = false,
        limit = 10,
      }, call)
    end, "filesystem.read", vim.fs.joinpath(root, "denied-link"))
    denied_call(function()
      api:authorize("find", { pattern = "*", path = denied, limit = 10 }, call)
    end, "filesystem.read", denied)
  end)
end)
