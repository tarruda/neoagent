local assert = require("luassert")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")
local fs = require("neoagent.fs")

describe("Linux pipe executable text", function()
  if jit.os ~= "Linux" then
    pending("requires native Linux/glibc")
    return
  end
  local ffi = require("ffi")
  ffi.cdef("const char *gnu_get_libc_version(void);")
  local C = ffi.C --[[@as Neoagent.PosixExecutableLibc]]
  if not pcall(function()
    return C.gnu_get_libc_version()
  end) then
    pending("requires native glibc")
    return
  end

  local spawn = vim.uv.spawn
  ---@type Neoagent.SubprocessScope
  local owner
  ---@type string
  local root
  ---@type table<string, boolean>
  local formats
  ---@type string[]
  local attempts
  local force_format, shell_failure

  before_each(function()
    owner = subprocess.scope()
    root = vim.fn.tempname()
    assert(fs.mkdirp(root .. "/scripts with spaces"))
    formats, attempts = {}, {}
    force_format, shell_failure = false, nil
    vim.uv.spawn = function(file, options, callback)
      attempts[#attempts + 1] = file
      if force_format and formats[file] then
        return nil, "ENOEXEC: exec format error", "ENOEXEC"
      elseif file == "/bin/sh" and shell_failure then
        if shell_failure == "throw" then
          error("native shell launch failed")
        end
        return nil, "EACCES: permission denied", "EACCES"
      end
      return spawn(file, options, callback)
    end
  end)

  after_each(function()
    vim.uv.spawn = spawn
    owner:close("test finished")
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
    vim.fn.delete(root, "rf")
  end)

  local function script(path)
    assert(
      fs.write_all(
        path,
        'IFS= read -r input; printf "%s\\n" "$1:$VALUE:$input"; pwd; printf "%s" "$2" >&2; exit 23\n',
        "w",
        448
      )
    )
    formats[path] = true
  end

  for _, forced in ipairs({ false, true }) do
    it("preserves arguments, environment, cwd, and pipes with forced ENOEXEC=" .. tostring(forced), function()
      force_format = forced
      assert(fs.mkdirp(root .. "/denied"))
      assert(fs.mkdirp(root .. "/broken"))
      assert(fs.write_all(root .. "/denied/target", "exit 99\n", "w", 384))
      assert(fs.write_all(root .. "/broken/target", "#!" .. root .. "/absent\nexit 98\n", "w", 448))
      local target = root .. "/scripts with spaces/target"
      script(target)
      formats.target = true
      for _, program in ipairs({ target, "scripts with spaces/target", "target" }) do
        formats[program] = true
        local result = helper.complete(function()
          return owner:run({
            argv = { program, "literal $() *", "stderr $() *" },
            cwd = root,
            stdio = { kind = "pipes", stdin = "open" },
            environment = {
              inherit = false,
              set = { PATH = "denied:missing:broken:scripts with spaces", VALUE = "environment" },
            },
          }, { capture = { max_bytes = 1024 }, input = { chunks = { "input\n" }, close = true } })
        end)
        assert.are.equal(23, result.code, vim.inspect(result))
        assert.are.equal("literal $() *:environment:input\n" .. root .. "\n", result.stdout)
        assert.are.equal("stderr $() *", result.stderr)
      end
    end)
  end

  it("uses the target cwd for empty PATH entries and option-like script names", function()
    force_format = true
    script(root .. "/-target")
    formats["-target"] = true
    formats["./-target"] = true
    local result = helper.complete(function()
      return owner:run({
        argv = { "-target", "literal", "stderr" },
        cwd = root,
        stdio = { kind = "pipes", stdin = "open" },
        environment = { inherit = false, set = { PATH = "", VALUE = "environment" } },
      }, { capture = { max_bytes = 1024 }, input = { chunks = { "input\n" }, close = true } })
    end)
    assert.are.equal(23, result.code, vim.inspect(result))
    assert.are.equal("literal:environment:input\n" .. root .. "\n", result.stdout)
    assert.are.equal("stderr", result.stderr)
  end)

  it("retains the native default PATH when a candidate becomes executable before retry", function()
    force_format = true
    formats.printf = true
    local result = helper.complete(function()
      return owner:run({
        argv = { "printf", "literal" },
        cwd = root,
        stdio = { kind = "pipes" },
        environment = { inherit = false, set = {} },
      }, { capture = { max_bytes = 1024 } })
    end)
    assert.are.equal(0, result.code, vim.inspect(result))
    assert.are.equal("literal", result.stdout)
    assert.is_false(vim.tbl_contains(attempts, "/bin/sh"))
  end)

  for _, rejected in ipairs({ "missing", "interpreter", "permission" }) do
    it("preserves native " .. rejected .. " failures without invoking a shell", function()
      local target = root .. "/target"
      if rejected == "interpreter" then
        assert(fs.write_all(target, "#!" .. root .. "/absent\n", "w", 448))
      elseif rejected == "permission" then
        assert(fs.write_all(target, "exit 99\n", "w", 384))
      end
      local failure = helper.failure(function()
        owner:spawn(helper.spec("unused", { argv = { target }, cwd = root }))
      end)
      assert.are.equal("process_start", failure.code)
      assert.are.equal("not_started", rawget(failure, "execution"))
      assert.are.same({ target }, attempts)
    end)
  end

  for _, rejected in ipairs({ "EACCES", "throw" }) do
    it("releases partial startup and retains execution evidence when the shell returns " .. rejected, function()
      force_format, shell_failure = true, rejected
      local target = root .. "/target"
      script(target)
      local failure = helper.failure(function()
        owner:spawn(helper.spec("unused", { argv = { target }, cwd = root }))
      end)
      assert.are.equal("process_start", failure.code)
      assert.are.equal(rejected == "throw" and "unknown" or "not_started", rawget(failure, "execution"))
      assert.are.same({ target, "/bin/sh" }, attempts)
      assert.is_true(helper.complete(function()
        return owner:wait(4000)
      end))
    end)
  end
end)
