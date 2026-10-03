local assert = require("luassert")
local subprocess = require("neoagent.subprocess_common")
local helper = require("tests.helpers.subprocess")
local limits = require("neoagent.subprocess.validate")

describe("native POSIX terminal failure ownership", function()
  if jit.os ~= "Linux" and jit.os ~= "OSX" then
    pending("requires native POSIX terminals")
    return
  end
  local module = "neoagent.subprocess." .. (jit.os == "Linux" and "linux" or "darwin") .. "_pty"
  local original = require(module)
  local native = require("ffi")
  local C = native.C
  local children = require("neoagent.subprocess.posix_child")
  local new_child = children.new
  ---@type Neoagent.SubprocessScope
  local owner
  ---@type string?
  local fault
  local cleanup_failed
  ---@type integer[]
  local allocated
  ---@type integer[]
  local closed

  before_each(function()
    owner = subprocess.scope()
    fault, cleanup_failed = nil, false
    allocated, closed = {}, {}
    package.loaded.ffi = setmetatable({
      cdef = function() end,
      C = setmetatable({
        posix_openpt = function(flags)
          if fault == "allocation" then
            local _ = native.errno(24)
            return -1
          end
          local fd = C.posix_openpt(flags)
          if fd >= 0 then
            allocated[#allocated + 1] = fd
          end
          return fd
        end,
        openpty = function(master, slave, name, termios, size)
          if fault == "allocation" then
            local _ = native.errno(24)
            return -1
          end
          local result = C.openpty(master, slave, name, termios, size)
          if result == 0 then
            allocated[#allocated + 1] = master[0]
            allocated[#allocated + 1] = slave[0]
          end
          return result
        end,
        close = function(fd)
          local result = C.close(fd)
          assert.are.equal(0, result)
          closed[#closed + 1] = fd
          return result
        end,
        fcntl = function(fd, command, value)
          if fault == "duplicate" and (command == 67 or command == 1030) then
            local _ = native.errno(24)
            return -1
          end
          return C.fcntl(fd, command, value)
        end,
        ioctl = function(fd, request, value)
          if fault == "resize" then
            local _ = native.errno(5)
            return -1
          end
          return C.ioctl(fd, request, value)
        end,
      }, {
        __index = function(_, name)
          if fault == "unsupported" and name == "posix_spawn_file_actions_addchdir_np" then
            error("native spawn working-directory API unavailable")
          end
          return C[name]
        end,
      }),
    }, { __index = native })
    package.loaded[module] = nil
    local ok, failure = pcall(require, module)
    package.loaded.ffi = native
    assert.is_true(ok, vim.inspect(failure))
  end)
  after_each(function()
    package.loaded.ffi, package.loaded[module] = native, original
    children.new = new_child
    owner:close("native failure test complete")
    local result = helper.complete(function()
      return owner:wait(4000)
    end)
    if cleanup_failed then
      assert.are.equal("process_cleanup", assert(result.error).code)
    else
      assert.is_true(result, vim.inspect(result))
    end
  end)

  local function spec()
    return helper.spec("exec sleep 10", { stdio = { kind = "pty", columns = 80, rows = 24 } })
  end

  for _, operation in ipairs({ "allocation", "duplicate" }) do
    it("owns partial resources when terminal " .. operation .. " fails", function()
      fault = operation
      local failure = helper.failure(function()
        owner:spawn(spec())
      end)
      assert.are.equal("process_start", failure.code)
      assert.matches("errno 24", assert(failure.message), 1, true)
      assert.is_true(helper.complete(function()
        return owner:wait(4000)
      end))
      table.sort(allocated)
      table.sort(closed)
      assert.are.same(allocated, closed, "failed terminal setup retained native descriptors")
    end)
  end

  it("reports failed resize while retaining the running target", function()
    local handle = owner:spawn(spec())
    fault = "resize"
    local failure = helper.failure(function()
      handle:resize(100, 30)
    end)
    assert.are.equal("process_terminal", failure.code)
    assert.are.equal("running", handle:state().phase)
  end)

  it("reports terminal cleanup failure independently of a successful exit", function()
    children.new = function(callbacks)
      local child = new_child(callbacks)
      local close = child.close
      child.close = function()
        close()
        error(limits.error("process_cleanup", "native reap failed"), 0)
      end
      return child
    end
    cleanup_failed = true
    local selected = spec()
    selected.argv = { "sh", "-c", "exit 23" }
    local handle = owner:spawn(selected)
    local result = helper.complete(function()
      return handle:wait()
    end)
    assert.are.equal("process_cleanup", assert(result.error).code)
    assert.are.equal(23, assert(handle:state().terminal).code)
  end)

  if jit.os == "Linux" then
    it("rejects native terminals when libc lacks the required spawn action", function()
      fault = "unsupported"
      local failure = helper.failure(function()
        owner:spawn(spec())
      end)
      assert.are.equal("pty_unavailable", failure.code)
      assert.is_true(owner:is_settled())
    end)
  end
end)
