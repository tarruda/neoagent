local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local subprocess = require("neoagent.subprocess_common")

describe("Windows PTY native ownership", function()
  for scenario, description in pairs({
    deadline = "keeps deadlines live and serializes close behind a pending resize",
    resize_failure = "reports an asynchronous resize failure and still closes its console",
    environment = "passes a name-sorted environment to native creation",
    native_strings = "preserves unpaired UTF-16 surrogates in native launch strings",
    unsupported = "rejects an unavailable native console before allocating resources",
    pipe_allocation = "releases native descriptors when stream allocation fails",
    observation = "retains ownership after native liveness observation fails",
    exit_status = "retains ownership when native exit status is unavailable",
    queue_failure = "reports rejected resize work and still releases the console",
    close_failure = "retries failed console release after reporting its operation failure",
  }) do
    local reject_resize, check_environment = scenario == "resize_failure", scenario == "environment"
    local check_strings = scenario == "native_strings"
    it(description, function()
      local native = require("ffi")
      local pty = require("neoagent.subprocess.pty")
      local trees = require("neoagent.process.windows")
      local module, executable = "neoagent.subprocess.windows_pty", "neoagent.subprocess.windows_executable"
      local original_module, original_executable = package.loaded[module], package.loaded[executable]
      local original_ffi = package.loaded.ffi
      local original_pty, original_tree, new_work = pty.new, trees.new, vim.uv.new_work
      local fs_stat = vim.uv.fs_stat
      local new_pipe = vim.uv.new_pipe
      ---@type fun()?
      local restore_queue
      ---@type Neoagent.SubprocessDriver?
      local driver
      local owner = subprocess.scope()
      local directory = check_strings and (vim.fn.tempname() .. "\237\160\128") or nil
      local stopped, exit_observed, inline_resize, completed = false, false, 0, 0
      local inject_failure = false
      local expected_completed = ({
        unsupported = 0,
        pipe_allocation = 0,
        observation = 1,
        exit_status = 1,
        queue_failure = 1,
        close_failure = 2,
        environment = 1,
        native_strings = 1,
      })[scenario] or 2
      ---@param buffer Neoagent.WindowsWideString
      ---@param block? boolean
      local function native_text(buffer, block)
        local pieces = {}
        local capacity = assert(native.sizeof(buffer)) / 2
        for index = 0, capacity - 1 do
          local unit = buffer[index]
          if unit == 0 then
            if not block then
              break
            end
            pieces[#pieces + 1] = "\0"
            if index + 1 < capacity and buffer[index + 1] == 0 then
              pieces[#pieces + 1] = "\0"
              break
            end
          else
            pieces[#pieces + 1] = unit < 128 and string.char(unit) or ("<%04x>"):format(unit)
          end
        end
        return table.concat(pieces)
      end
      ---@type string?
      local environment_block
      local launch_text = {}
      ---@type fun()[]
      local pending = {}
      ---@type Neoagent.SubprocessHandle?
      local handle
      local ok, failure = pcall(function()
        -- A Windows WTF-8 path need not be representable by the host filesystem
        -- (notably APFS). Supply its directory metadata at the same boundary as
        -- the other simulated Windows services; the launch string stays intact.
        if directory then
          local metadata = assert(fs_stat(vim.fn.getcwd()))
          vim.uv.fs_stat = function(path)
            if path == directory then
              return metadata
            end
            return fs_stat(path)
          end
        end
        -- Keep real FFI storage, streams, timers, and luv work. Inject the
        -- unavailable Windows services; native Windows tests cover their ABI.
        package.loaded.ffi = setmetatable({
          cdef = function(declarations)
            if not pcall(native.typeof, "NeoagentConsoleStartupEx") then
              native.cdef(declarations)
            end
          end,
          load = function()
            if scenario == "unsupported" then
              return setmetatable({}, {
                __index = function()
                  error("native ConPTY unavailable")
                end,
              })
            end
            return {
              CreatePseudoConsole = function(_, _, _, _, result)
                result[0] = native.cast("void *", 1)
                return 0
              end,
              ResizePseudoConsole = function()
                inline_resize = inline_resize + 1
                return 0
              end,
              InitializeProcThreadAttributeList = function(_, _, _, length)
                length[0] = 16
                return 1
              end,
              UpdateProcThreadAttribute = function()
                return 1
              end,
              DeleteProcThreadAttributeList = function() end,
              CreateProcessW = function(application, command, _, _, _, _, block, cwd, _, info)
                environment_block = native_text(block, true)
                launch_text = { native_text(application), native_text(command), native_text(cwd) }
                info.process = native.cast("void *", 2)
                info.thread = native.cast("void *", 3)
                return 1
              end,
              CloseHandle = function()
                return 1
              end,
              GetLastError = function()
                return 0
              end,
              GetExitCodeProcess = function(_, result)
                if inject_failure and scenario == "exit_status" then
                  inject_failure = false
                  return 0
                end
                exit_observed = true
                result[0] = 0
                return 1
              end,
              MultiByteToWideChar = function(_, _, text, _, buffer)
                -- Model the Windows strict converter at its native boundary.
                -- It rejects encoded lone surrogates; ASCII cases still use
                -- real UTF-16 storage inspected by CreateProcessW above.
                if text:find("\237\160\128", 1, true) then
                  return 0
                end
                if buffer then
                  for index = 1, #text do
                    buffer[index - 1] = text:byte(index)
                  end
                end
                return #text
              end,
              CompareStringOrdinal = function(left, _, right)
                -- These boundary cases use ASCII names. Native Windows tests
                -- exercise the platform's actual Unicode collation.
                local a, b = native_text(left):upper(), native_text(right):upper()
                return a < b and 1 or a == b and 2 or 3
              end,
            }
          end,
        }, { __index = native })
        package.loaded[module] = nil
        local create = require(module).new
        pty.new = function(...)
          driver = create(...)
          return driver
        end
        package.loaded.ffi = original_ffi
        package.loaded[executable] = {
          resolve = function()
            return check_strings and "program\237\160\128.exe" or "unused"
          end,
        }
        trees.new = function()
          return original_tree({
            backend = {
              create = function()
                return native.cast("void *", 4)
              end,
              open = function()
                return native.cast("void *", 2)
              end,
              assign = function()
                return true
              end,
              running = function()
                if inject_failure and scenario == "observation" then
                  inject_failure = false
                  return nil, "native observation failed"
                end
                return not stopped
              end,
              terminate = function()
                stopped = true
                return true
              end,
              close = function() end,
            },
          })
        end
        vim.uv.new_work = function(_, finished)
          ---@return boolean
          local function complete_native_operation()
            return true
          end
          ---@param _bytes string
          ---@param action string
          ---@return boolean
          local function fail_native_resize(_bytes, action)
            return action ~= "resize"
          end
          local context = new_work(reject_resize and fail_native_resize or complete_native_operation, function(result)
            completed = completed + 1
            if scenario == "close_failure" and completed == 1 then
              result = false
            end
            pending[#pending + 1] = function()
              finished(result)
            end
          end)
          if scenario == "queue_failure" then
            local methods = getmetatable(context).__index
            local queue = methods.queue
            restore_queue = function()
              methods.queue = queue
            end
            methods.queue = function()
              methods.queue = queue
              return false
            end
          end
          return context
        end
        if scenario == "pipe_allocation" then
          vim.uv.new_pipe = function()
            return nil
          end
        end
        local env = { PATH = "unused" }
        if check_environment then
          env.A, env["A!"], env.PROGRAMFILES, env["PROGRAMFILES(X86)"] = "one", "two", "base", "compat"
        elseif check_strings then
          env.MARKER = "value\237\160\128"
        end
        local selected = helper.spec("unused", {
          argv = check_strings and { "program\237\160\128.exe", "arg\237\160\128" } or nil,
          cwd = directory,
          stdio = { kind = "pty", columns = 80, rows = 24 },
          timeout_ms = reject_resize and 5000 or 50,
          kill_grace_ms = 0,
          environment = { inherit = false, set = env },
        })
        if scenario == "unsupported" or scenario == "pipe_allocation" then
          local err = helper.failure(function()
            owner:spawn(selected)
          end)
          assert.are.equal(scenario == "unsupported" and "pty_unavailable" or "process_start", err.code)
          return
        end
        handle = owner:spawn(selected)
        if scenario == "observation" or scenario == "exit_status" then
          inject_failure = true
          stopped = scenario == "exit_status"
          assert(vim.wait(1000, function()
            return handle:state().failure ~= nil
          end, 5))
          assert.are.equal("process_supervision", assert(handle:state().failure).code)
          return
        elseif scenario == "queue_failure" then
          assert.are.equal(
            "process_terminal",
            helper.failure(function()
              handle:resize(100, 30)
            end).code
          )
          assert.are.equal("process_terminal", assert(handle:state().failure).code)
          return
        elseif scenario == "close_failure" then
          stopped = true
          assert(vim.wait(1000, function()
            return #pending > 0
          end, 5))
          table.remove(pending, 1)()
          assert.are.equal("process_cleanup", assert(handle:state().failure).code)
          assert.is_false(owner:is_settled())
          return
        end
        if check_environment then
          assert.are.equal(
            "A=one\0A!=two\0PATH=unused\0PROGRAMFILES=base\0PROGRAMFILES(X86)=compat\0\0",
            environment_block
          )
          return
        elseif check_strings then
          assert.are.same({
            "program<d800>.exe",
            "program<d800>.exe arg<d800>",
            (assert(directory):gsub("\237\160\128", "<d800>")),
          }, launch_text)
          assert.are.equal("MARKER=value<d800>\0PATH=unused\0\0", environment_block)
          return
        end
        for index = 1, 1000 do
          handle:resize(80 + index % 2, 24)
        end
        assert.are.equal(0, inline_resize, "resize invoked a potentially blocking native call on the editor thread")
        if reject_resize then
          assert.is_true(
            vim.wait(2000, function()
              return #pending > 0
            end, 5),
            "resize did not complete"
          )
          table.remove(pending, 1)()
          assert.are.equal("process_terminal", assert(handle:state().failure).code)
        end
        assert.is_true(
          vim.wait(2000, function()
            return exit_observed and #pending > 0
          end, 5),
          "process deadline did not run while resize was pending"
        )
        assert.are.equal(reject_resize and 2 or 1, completed, "close raced the pending resize or requests accumulated")
        assert.are.equal(
          "process_terminal",
          helper.failure(function()
            assert(driver).resize(100, 30)
          end).code
        )
        assert.is_false(owner:is_settled())
      end)
      owner:close("test finished")
      local settled = vim.wait(4000, function()
        local callbacks = pending
        pending = {}
        for _, finish in ipairs(callbacks) do
          finish()
        end
        return owner:is_settled()
      end, 5)
      package.loaded.ffi, package.loaded[module], package.loaded[executable] =
        original_ffi, original_module, original_executable
      pty.new, trees.new, vim.uv.new_work = original_pty, original_tree, new_work
      vim.uv.fs_stat = fs_stat
      vim.uv.new_pipe = new_pipe
      if restore_queue then
        restore_queue()
      end
      assert.is_true(settled, "native console work did not finish")
      assert.is_true(helper.complete(function()
        return owner:wait(2000)
      end))
      assert.is_true(ok, vim.inspect(failure))
      assert.are.equal(expected_completed, completed, "cleanup must close the console after pending work")
    end)
  end
end)
