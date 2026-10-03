local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local subprocess = require("neoagent.subprocess_common")

describe("Linux native executable lookup failures", function()
  if jit.os ~= "Linux" then
    pending("requires native Linux")
    return
  end
  local module = "neoagent.subprocess.linux_pty"
  local original = require("neoagent.subprocess.linux_pty")
  local ffi = require("ffi")
  local C = ffi.C --[[@as Neoagent.PtyLibc]]
  local glibc = pcall(function()
    return C.gnu_get_libc_version()
  end)
  ---@type Neoagent.SubprocessScope
  local owner
  ---@type string
  local root
  local failure = 2
  before_each(function()
    owner = subprocess.scope()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/good", "p")
    vim.fn.mkdir(root .. "/denied", "p")
    local fs = require("neoagent.fs")
    assert(fs.write_all(root .. "/good/target", "#!/bin/sh\nprintf selected\n", "w", 448))
    assert(fs.write_all(root .. "/denied/target", "#!/bin/sh\n", "w", 384))
    package.loaded.ffi = setmetatable({
      cdef = function() end,
      C = setmetatable({
        posix_spawn = function(pid, path, actions, attrs, argv, env)
          if path == root .. "/unavailable/target" then
            return failure
          end
          return C.posix_spawn(pid, path, actions, attrs, argv, env)
        end,
      }, { __index = C }),
    }, { __index = ffi })
    package.loaded[module] = nil
    local ok, err = pcall(require, module)
    package.loaded.ffi = ffi
    assert.is_true(ok, vim.inspect(err))
  end)
  after_each(function()
    package.loaded.ffi = ffi
    package.loaded[module] = original
    owner:close("test finished")
    assert.is_true(helper.complete(function()
      return owner:wait(4000)
    end))
    vim.fn.delete(root, "rf")
  end)

  local function run(path)
    return helper.complete(function()
      return owner:run(
        helper.spec("unused", {
          argv = { "target" },
          stdio = { kind = "pty", columns = 80, rows = 24 },
          environment = { inherit = false, set = { PATH = path } },
        }),
        { capture = { max_bytes = 1024 } }
      )
    end)
  end

  for _, errno in ipairs({ 19, 110, 116 }) do
    it("uses libc PATH fallback after native error " .. errno, function()
      failure = errno
      local result = run(root .. "/unavailable:" .. root .. "/good")
      if glibc then
        assert.are.equal(0, result.code, vim.inspect(result))
        assert.are.equal("selected", result.output)
      else
        assert.matches("errno " .. errno, assert(assert(result.error).message), 1, true)
      end
    end)

    it("uses libc permission-error precedence after native error " .. errno, function()
      failure = errno
      local result = run(root .. "/denied:" .. root .. "/unavailable")
      assert.matches("errno " .. (glibc and 13 or errno), assert(assert(result.error).message), 1, true)
    end)
  end
end)
