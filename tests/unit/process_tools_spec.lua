local assert = require("luassert")
local async = require("neoagent.async")
local loop = require("neoagent.agent_loop")
local fake_model = require("tests.helpers.fake_model")
local helper = require("tests.helpers.subprocess")
local util = require("neoagent.util")
local tools = require("neoagent.tools.process")
local pipe = require("neoagent.subprocess.pipe")
local result_receipt = require("neoagent.result_receipt")
local new_pipe = pipe.new

describe("Codex process Tools", function()
  -- Keep the waiting command in the root shell; this test does not race the
  -- Windows pipe driver's documented post-creation Job attachment.
  local shell = jit.os == "Windows" and "powershell.exe" or "sh"
  local sleeper = jit.os == "Windows" and "Start-Sleep -Seconds 30" or "exec sleep 30"
  ---@type Neoagent.ProcessSessions
  local owner
  ---@type string
  local root
  ---@type Neoagent.Agent?
  local agent
  before_each(function()
    owner = require("neoagent.process_sessions").new({ capacity = 2 })
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)
  after_each(function()
    pipe.new = new_pipe
    if agent then
      agent:destroy()
      agent = nil
    end
    owner:close("test finished")
    helper.complete(function()
      return owner:wait_cleanup(10000)
    end, 15000)
    assert.is_true(helper.complete(function()
      return owner:wait_release(10000)
    end, 15000))
    vim.fn.delete(root, "rf")
  end)

  ---@param name string
  ---@param arguments Neoagent.JsonObject
  ---@param commit? Neoagent.MessageCommit
  ---@param execute? Neoagent.ToolExecutor<unknown>
  ---@return Neoagent.Run<Neoagent.AgentLoopResult, Neoagent.AgentLoopEvent>, fun(): Neoagent.ToolResultMessage
  local function start(name, arguments, commit, execute)
    ---@type Neoagent.ToolResultMessage?
    local published
    local model = fake_model.new({
      {
        result = fake_model.assistant(
          { { type = "toolCall", id = "p1", name = name, arguments = arguments } },
          "toolUse"
        ),
      },
      { result = fake_model.assistant({ { type = "text", text = "done" } }) },
    })
    return loop.run({
      model = model,
      messages = {},
      tools = { tools.exec_command(), tools.write_stdin() },
      context = { workspace = { root = root, cwd = root }, processes = owner },
      execute_tool = execute,
      commit_message = function(message)
        if message.role == "toolResult" then
          ---@cast message Neoagent.ToolResultMessage
          published = message
        end
        if commit then
          return commit(message)
        end
        return true
      end,
    }),
      function()
        return assert(published)
      end
  end

  ---@param name string
  ---@param arguments Neoagent.JsonObject
  ---@return Neoagent.ToolResultMessage
  local function call(name, arguments)
    local run, published = start(name, arguments)
    local result = helper.wait(run, 15000)
    assert.is_true(result.ok, vim.inspect(result))
    return published()
  end
  ---@param value Neoagent.ToolResultMessage
  ---@return Neoagent.ProcessToolDetails
  local function details(value)
    assert.is_false(value.isError, util.text_content(value.content))
    local observed = value.details
    assert(type(observed) == "table" and type(rawget(observed, "output")) == "string")
    ---@cast observed Neoagent.ProcessToolDetails
    return observed
  end
  local function launch(command, tty)
    return details(call("exec_command", { cmd = command, shell = shell, login = false, tty = tty, yield_time_ms = 0 }))
  end

  it("returns ordinary command output, cwd and exit status without retaining a session", function()
    vim.fn.mkdir(root .. "/sub directory", "p")
    local command = jit.os == "Windows" and "Get-Location; Write-Output hello" or "pwd; printf hello"
    local observed = details(call("exec_command", {
      cmd = command,
      shell = shell,
      login = false,
      workdir = "sub directory",
      yield_time_ms = 5000,
    }))
    assert.are.equal(0, observed.exit_code)
    assert.is_nil(observed.session_id)
    assert.matches("sub directory", observed.output, 1, true)
    assert.matches("hello", observed.output, 1, true)
    assert.are.equal(0, owner:status().provisional)
    local failed = call("exec_command", { cmd = "exit 7", shell = shell, login = false, yield_time_ms = 5000 })
    assert.is_true(failed.isError)
    assert.are.equal(7, assert(failed.details).exit_code)
  end)

  for _, execution in ipairs({ "not_started", "started" }) do
    it("reports headless startup execution evidence: " .. execution, function()
      pipe.new = function(...)
        local driver = new_pipe(...)
        local native_start = driver.start
        driver.start = function()
          if execution == "started" then native_start() end
          error(util.error("process_start", "Injected admission failure"), 0)
        end
        return driver
      end
      local message = call("exec_command", {
        cmd = sleeper, shell = shell, login = false, yield_time_ms = 0,
      })
      assert.is_true(message.isError)
      local observed = assert(message.details, "headless failure discarded native execution evidence")
      assert.are.equal(execution, observed.execution)
      assert.are.equal(execution == "started", observed.outcome_uncertain)
      assert.is_nil(observed.session_id)
      if execution == "started" then
        assert.matches("Do not retry automatically", util.text_content(message.content), 1, true)
      end
      assert.are.equal(0, owner:status().provisional)
    end)
  end

  for _, wrapped in ipairs({ false, true }) do
    for _, failure in ipairs({ "throws", "malformed" }) do
      for _, completed in ipairs({ false, true }) do
        it("retains execution facts after " .. failure .. " with composition=" .. tostring(wrapped)
          .. " completed=" .. tostring(completed), function()
          ---@type Neoagent.ToolExecutor<unknown>
          local execute = function(tool, args, ctx)
            tool.execute(args, ctx)
            if failure == "throws" then error("executor failed after command execution") end
            return {} --[[@as Neoagent.ToolResult]]
          end
          if wrapped then
            execute = assert(require("neoagent.sandbox.composition").compose({
              tools = { tools.exec_command(), tools.write_stdin() }, execute_tool = execute,
            }, { enabled = false }).execute_tool)
          end
          local run, published = start("exec_command", {
            cmd = completed and "exit 0" or sleeper, shell = shell, login = false,
            yield_time_ms = completed and 5000 or 0,
          }, nil, execute)
          assert.is_true(helper.wait(run, 15000).ok)
          local message = published()
          assert.is_true(message.isError)
          local observed = assert(message.details, "executor failure erased the process observation")
          assert.are.equal("started", observed.execution)
          assert.are.equal(not completed, observed.outcome_uncertain)
          assert.are.equal(completed and 0 or nil, observed.exit_code)
          assert.is_nil(observed.session_id, "failed initial publication retained a provisional reference")
          assert.matches("retry", util.text_content(message.content), 1, true)
        end)
      end
    end
  end

  it("preserves the live process reference when input is rejected", function()
    local id = assert(launch(sleeper, false).session_id)
    local message = call("write_stdin", { session_id = id, chars = "rejected", yield_time_ms = 0 })
    assert.is_true(message.isError)
    assert.is_false(assert(message.details).done)
    assert.are.equal(id, assert(message.details).session_id)
    assert.matches(id, util.text_content(message.content), 1, true)
  end)

  it("publishes a live ID only after storage accepts it and preserves it across cancellation", function()
    ---@type string?
    local id
    local run, published = start(
      "exec_command",
      { cmd = sleeper, shell = shell, login = false, yield_time_ms = 0 },
      function(message)
        if message.role == "toolResult" then
          id = assert(assert(message.details).session_id)
          assert.are.equal(1, owner:status().provisional)
          assert.are.equal(
            "process_session_missing",
            assert(helper.complete(function()
              return owner:interact(assert(id), 0)
            end).error).code
          )
          assert(async.current()):cancel()
        end
        return true
      end
    )
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert.are.equal(id, details(published()).session_id)
    assert.are.equal(0, owner:status().provisional)
    assert.is_false(helper.success(function()
      return owner:interact(assert(id), 0)
    end).done)
  end)

  it("disposes native execution when result storage rejects the handoff", function()
    local run = start(
      "exec_command",
      { cmd = sleeper, shell = shell, login = false, yield_time_ms = 0 },
      function(message)
        if message.role == "toolResult" then
          return nil, util.error("storage", "disk unavailable")
        end
        return true
      end
    )
    assert.are.equal("storage", assert(helper.wait(run).error).kind)
    assert.is_true(helper.complete(function()
      return owner:wait_release(10000)
    end, 15000))
    assert.are.equal(0, owner:status().reserved)
    assert.are.equal(0, owner:status().provisional)
  end)

  it("aborts a handoff when an executor removes the process reference", function()
    local run = start(
      "exec_command",
      { cmd = sleeper, shell = shell, login = false, yield_time_ms = 0 },
      nil,
      function(tool, args, ctx)
        tool.execute(args, ctx)
        return { content = { { type = "text", text = "Result replaced by executor" } } }
      end
    )
    assert.is_true(helper.wait(run).ok)
    assert.are.equal(0, owner:status().provisional)
    assert.is_true(
      helper.complete(function()
        return owner:wait_release(2000)
      end, 5000),
      "Unpublished process remained alive"
    )
  end)

  for _, transformation in ipairs({
    "split text",
    "reference only",
    "hidden reference",
    "different reference",
    "unacknowledged edit",
  }) do
    it("acknowledges references separately from output after " .. transformation, function()
      local command = jit.os == "Windows" and [[python -u -c "print('FIRST', flush=True); input()"]]
        or "printf 'FIRST\\n'; read line"
      local id, output
      local run = start(
        "exec_command",
        {
          cmd = command,
          shell = shell,
          login = false,
          tty = true,
          yield_time_ms = 5000,
        },
        nil,
        function(tool, args, ctx)
          local value = tool.execute(args, ctx)
          local receipt = assert(result_receipt.read(value))
          id, output = assert(value.details).session_id, assert(value.details).output
          assert(type(id) == "string" and type(output) == "string")
          assert.matches("FIRST", output, 1, true)
          if transformation == "hidden reference" then
            value.content = { { type = "text", text = output } }
            receipt.session_id = nil
          else
            value.content = {
              {
                type = "text",
                text = "Retained: " .. id .. (transformation == "different reference" and "0" or ""),
              },
            }
            if transformation ~= "reference only" then
              value.content[#value.content + 1] = { type = "text", text = "Command output:" }
              value.content[#value.content + 1] = { type = "text", text = output }
            end
          end
          if transformation == "unacknowledged edit" then
            return value
          end
          if transformation == "different reference" then
            receipt.session_id = id .. "0"
          elseif transformation == "reference only" then
            receipt.output = false
          end
          return result_receipt.bind(value, receipt)
        end
      )
      assert.is_true(helper.wait(run, 15000).ok)
      if
        transformation == "hidden reference"
        or transformation == "different reference"
        or transformation == "unacknowledged edit"
      then
        assert.is_true(helper.complete(function()
          return owner:wait_release(5000)
        end, 8000))
        assert.are.equal(0, owner:status().reserved)
      else
        local replay = details(call("write_stdin", { session_id = assert(id), yield_time_ms = 0 }))
        assert.are.equal(id, replay.session_id)
        assert.are.equal(transformation == "reference only" and output or "", replay.output)
      end
    end)
  end

  for _, replacement in ipairs({ "session reference", "unrelated text" }) do
    it("replays omitted output that also appears in " .. replacement, function()
      local command = jit.os == "Windows"
          and "while (-not [IO.File]::Exists('output-gate')) { Start-Sleep -Milliseconds 10 }; [Console]::Write('1'); " .. sleeper
        or "while [ ! -f output-gate ]; do sleep 0.01; done; printf 1; " .. sleeper
      local id = assert(launch(command, false).session_id)
      vim.fn.writefile({ "ready" }, root .. "/output-gate")
      local captured
      local run = start("write_stdin", { session_id = id, yield_time_ms = 5000 }, nil, function(tool, args, ctx)
        local value = tool.execute(args, ctx)
        captured = assert(value.details).output
        value.content = {
          {
            type = "text",
            text = replacement == "session reference" and "Retained: " .. id or "Request 1: output omitted",
          },
        }
        return value
      end)
      assert.is_true(helper.wait(run, 15000).ok)
      assert.are.equal("1", captured)
      local replay = details(call("write_stdin", { session_id = id, yield_time_ms = 0 }))
      assert.are.equal("1", replay.output)
    end)
  end

  for _, scenario in ipairs({ "rejected", "replaced", "mutated", "executor failed" }) do
    it("replays unaccepted poll output without repeating its input: " .. scenario, function()
      local command = jit.os == "Windows"
          and [[python -u -c "import sys; print('READY', flush=True); print('VALUE=' + sys.stdin.readline(), flush=True); print('SECOND=' + sys.stdin.readline(), flush=True)"]]
        or [[printf 'READY\n'; read value; printf 'VALUE=%s\n' "$value"; read value; printf 'SECOND=%s\n' "$value"]]
      local initial = launch(command, true)
      local id, ready = assert(initial.session_id), initial.output
      assert(vim.wait(10000, function()
        if not ready:find("READY", 1, true) then
          ready = ready .. details(call("write_stdin", { session_id = id, yield_time_ms = 100 })).output
        end
        return ready:find("READY", 1, true) ~= nil
      end, 5))
      local captured = ""
      local run = start(
        "write_stdin",
        { session_id = id, chars = "first" .. (jit.os == "Windows" and "\r" or "\n"), yield_time_ms = 5000 },
        function(message)
          if message.role == "toolResult" and scenario == "rejected" then
            return nil, util.error("storage", "publication rejected")
          end
          return true
        end,
        function(tool, args, ctx)
          local value = tool.execute(args, ctx)
          captured = assert(value.details).output
          if scenario == "executor failed" then
            error("executor failed after collection")
          end
          if scenario == "replaced" then
            return { content = { { type = "text", text = "Result replaced" } } }
          end
          if scenario == "mutated" then
            value.content[1] = { type = "text", text = "Result edited in place" }
          end
          return value
        end
      )
      helper.wait(run, 15000)
      assert.is_not.equal("", captured)
      local replay = details(call("write_stdin", { session_id = id, yield_time_ms = 0 }))
      assert.are.equal(captured, replay.output)
      local response = details(
        call(
          "write_stdin",
          { session_id = id, chars = "second" .. (jit.os == "Windows" and "\r" or "\n"), yield_time_ms = 5000 }
        )
      )
      local output = replay.output .. response.output
      assert(vim.wait(10000, function()
        if response.session_id then
          response = details(call("write_stdin", { session_id = id, yield_time_ms = 100 }))
          output = output .. response.output
        end
        return not response.session_id
      end, 5))
      assert.matches("SECOND=second", output, 1, true)
    end)
  end

  it("preserves a successful command outcome when cleanup reports a separate failure", function()
    local omit_status = false
    owner = require("neoagent.process_sessions").new(nil, nil, function(spec, maximum, cleanup, released)
      local controller = require("neoagent.process_sessions.local").new(spec, maximum, cleanup, released)
      local collect = controller.collect
      function controller:collect(wait_ms, until_exit)
        local value = collect(self, wait_ms, until_exit)
        value.cleanup_error = util.error("process_cleanup", "synthetic cleanup failure")
        value.release_error = util.error("process_cleanup", "synthetic release uncertainty")
        if omit_status then
          value.outcome = nil
        end
        return value
      end
      return controller
    end)
    local message = call("exec_command", { cmd = "exit 0", shell = shell, login = false, yield_time_ms = 5000 })
    assert.is_false(message.isError, util.text_content(message.content))
    assert.are.equal(0, assert(message.details).exit_code)
    assert.are.equal("synthetic cleanup failure", assert(assert(message.details).cleanup_error).message)
    assert.are.equal("synthetic release uncertainty", assert(assert(message.details).release_error).message)
    assert.matches("do not retry it automatically", util.text_content(message.content), 1, true)
    omit_status = true
    message = call("exec_command", { cmd = "exit 0", shell = shell, login = false, yield_time_ms = 5000 })
    assert.is_true(message.isError)
    assert.is_nil(assert(message.details).exit_code)
  end)

  it("preserves native success when finalizing the driver fails", function()
    pipe.new = function(...)
      local driver = new_pipe(...)
      local dispose = driver.dispose
      driver.dispose = function()
        dispose()
        error(util.error("process_cleanup", "native finalization failed"), 0)
      end
      return driver
    end
    local message = call("exec_command", { cmd = "exit 0", shell = shell, login = false, yield_time_ms = 5000 })
    assert.is_false(message.isError, util.text_content(message.content))
    assert.are.equal(0, assert(message.details).exit_code)
    assert.is_nil(assert(message.details).error)
    assert.is_not_nil(assert(message.details).cleanup_error)
    assert.is_nil((util.text_content(message.content):find("Process error:", 1, true)))
    assert.matches("do not retry it automatically", util.text_content(message.content), 1, true)
  end)

  it("cancels initial observation without retaining an unpublished target", function()
    local executing = false
    local run = start(
      "exec_command",
      { cmd = sleeper, shell = shell, login = false, yield_time_ms = 30000 },
      nil,
      function(tool, args, ctx)
        executing = true
        return tool.execute(args, ctx)
      end
    )
    assert(vim.wait(3000, function()
      return executing
    end, 5))
    run:cancel()
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert.is_true(helper.complete(function()
      return owner:wait_release(10000)
    end, 15000))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("preserves cancellation through process policy and aborts its unpublished admission", function()
    local selected = require("neoagent.sandbox.composition").compose({
      tools = { tools.exec_command() },
      execute_tool = function(tool, args, ctx)
        tool.execute(args, ctx)
        ctx.run:cancel()
        error(async.cancelled_error, 0)
      end,
    }, { enabled = false })
    local run = start("exec_command", { cmd = sleeper, shell = shell, login = false, yield_time_ms = 0 }, nil,
      selected.execute_tool)
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert.is_true(helper.complete(function() return owner:wait_release(5000) end, 8000))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("cancels a later poll without terminating the target and interrupts through its retained ID", function()
    local id = assert(launch(sleeper, false).session_id)
    local polling = false
    local run = start("write_stdin", { session_id = id, yield_time_ms = 300000 }, nil, function(tool, args, ctx)
      polling = true
      return tool.execute(args, ctx)
    end)
    assert(vim.wait(3000, function()
      return polling
    end, 5))
    run:cancel()
    assert.are.equal("cancelled", assert(helper.wait(run).error).kind)
    assert.are.equal(id, details(call("write_stdin", { session_id = id, yield_time_ms = 0 })).session_id)
    local interrupted = call("write_stdin", { session_id = id, chars = "\3", yield_time_ms = 5000 })
    assert.is_nil(assert(interrupted.details).session_id, util.text_content(interrupted.content))
    assert.is_true(helper.complete(function()
      return owner:wait_release(10000)
    end, 15000))
  end)

  it("retains PTY input across Tool calls until the target exits", function()
    local command = jit.os == "Windows"
        and "python -u -c \"import sys; print('READY', flush=True); print('VALUE=' + sys.stdin.readline(), flush=True)\""
      or "printf 'READY\\n'; read value; printf 'VALUE=%s\\n' \"$value\""
    local initial = launch(command, true)
    local id = assert(initial.session_id)
    local output = initial.output
    assert(vim.wait(10000, function()
      if not output:find("READY", 1, true) then
        output = output .. details(call("write_stdin", { session_id = id, yield_time_ms = 100 })).output
      end
      return output:find("READY", 1, true) ~= nil
    end, 5), output)
    assert.matches("READY", output, 1, true)
    local reply = details(
      call(
        "write_stdin",
        { session_id = id, chars = jit.os == "Windows" and "retained\r" or "retained\n", yield_time_ms = 5000 }
      )
    )
    output = output .. reply.output
    assert(vim.wait(10000, function()
      if reply.session_id then
        reply = details(call("write_stdin", { session_id = id, yield_time_ms = 100 }))
        output = output .. reply.output
      end
      return not reply.session_id
    end, 5))
    assert.are.equal(0, reply.exit_code)
    assert.matches("VALUE=retained", output, 1, true)
  end)

  it("bounds output and validates requests before reserving resources", function()
    local value = details(call("exec_command", {
      cmd = jit.os == "Windows" and "[Console]::Write('0123456789')" or "printf 0123456789",
      shell = shell,
      login = false,
      yield_time_ms = 5000,
      max_output_tokens = 1,
    }))
    assert.is_true(value.truncated)
    assert.matches("6789", value.output, 1, true)
    for _, arguments in ipairs({
      { cmd = "exit 0", yield_time_ms = 30001 },
      { cmd = "exit 0", max_output_tokens = -1 },
      { cmd = "exit 0", max_output_tokens = 10001 },
      { cmd = "exit 0", timeout_ms = 0 },
      { cmd = "exit 0", shell = "/unsupported" },
      { cmd = "exit 0", login = "no" },
    }) do
      assert.is_true(call("exec_command", arguments).isError)
      assert.are.equal(0, owner:status().provisional)
    end
    assert.is_true(call("write_stdin", { session_id = 999 }).isError)
    assert.is_true(call("write_stdin", { session_id = 1, chars = string.rep("x", 65537) }).isError)
  end)

  if jit.os ~= "Windows" then
    it("terminates a target that ignores interruption", function()
      local initial = launch([[trap '' INT TERM; printf 'IGNORE_READY\n'; while :; do sleep 1; done]], true)
      local id, output = assert(initial.session_id), initial.output
      assert(vim.wait(5000, function()
        if not output:find("IGNORE_READY", 1, true) then
          output = output .. details(call("write_stdin", { session_id = id, yield_time_ms = 100 })).output
        end
        return output:find("IGNORE_READY", 1, true) ~= nil
      end, 5))
      assert.are.equal(
        id,
        details(call("write_stdin", { session_id = id, chars = "\3", yield_time_ms = 0 })).session_id
      )
      local response = call("write_stdin", { session_id = id, terminate = true, yield_time_ms = 5000 })
      assert.is_table(response.details, util.text_content(response.content))
      assert(vim.wait(10000, function()
        if assert(response.details).session_id then
          response = call("write_stdin", { session_id = id, yield_time_ms = 100 })
        end
        return assert(response.details).session_id == nil
      end, 5))
      assert.is_nil(assert(response.details).session_id, util.text_content(response.content))
      assert.is_true(helper.complete(function()
        return owner:wait_release(5000)
      end, 8000))
    end)

    it("delivers Ctrl-C as PTY input when the application disables terminal signals", function()
      local initial =
        launch("stty -echo -icanon -isig; printf 'RAW_READY\\n'; dd bs=1 count=1 2>/dev/null | od -An -tu1", true)
      local id = assert(initial.session_id)
      local output = initial.output
      if not output:find("RAW_READY", 1, true) then
        output = output .. details(call("write_stdin", { session_id = id, yield_time_ms = 5000 })).output
      end
      assert.matches("RAW_READY", output, 1, true)
      local response = details(call("write_stdin", { session_id = id, chars = "\3", yield_time_ms = 5000 }))
      output = response.output
      assert(vim.wait(5000, function()
        if response.session_id then
          response = details(call("write_stdin", { session_id = id, yield_time_ms = 100 }))
          output = output .. response.output
        end
        return not response.session_id
      end, 5))
      assert.are.equal(0, response.exit_code)
      assert.matches("3", output, 1, true)
    end)
  end

  it("uses the configured shell and supports login/profile selection", function()
    local ordinary = details(call("exec_command", { cmd = "echo default", yield_time_ms = 5000 }))
    assert.matches("default", ordinary.output, 1, true)
    if jit.os == "Windows" then
      for _, login in ipairs({ false, true }) do
        local response = details(
          call(
            "exec_command",
            { cmd = "Write-Output profile", shell = "powershell.exe", login = login, yield_time_ms = 10000 }
          )
        )
        assert.matches("profile", response.output, 1, true)
      end
    end
  end)

  if jit.os == "Windows" then
    it("preserves PowerShell script arguments after File", function()
      local saved_shell, saved_flags = vim.o.shell, vim.o.shellcmdflag
      local path = root .. "/arguments.ps1"
      assert(require("neoagent.fs").write_all(path, "[Console]::Write(($args -join '|'))"))
      vim.o.shell = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' .. path .. '" -NoProfile'
      vim.o.shellcmdflag = ""
      local ok, err = pcall(function()
        local observed = details(call("exec_command", {
          cmd = "literal argument", login = true, yield_time_ms = 10000,
        }))
        assert.are.equal("-NoProfile|literal argument", observed.output)
      end)
      vim.o.shell, vim.o.shellcmdflag = saved_shell, saved_flags
      if not ok then error(err, 0) end
    end)

    for _, flag in ipairs({ "-EncodedCommand", "-ec" }) do
      it("preserves PowerShell encoded commands with " .. flag, function()
        local saved_shell, saved_flags = vim.o.shell, vim.o.shellcmdflag
        vim.o.shell, vim.o.shellcmdflag = "powershell.exe -NoProfile", flag
        local source = "[Console]::Write('ENCODED')"
        local encoded = vim.base64.encode((source:gsub(".", function(char) return char .. "\0" end)))
        local ok, err = pcall(function()
          local observed = details(call("exec_command", {
            cmd = encoded, login = false, yield_time_ms = 10000,
          }))
          assert.are.equal("ENCODED", observed.output)
        end)
        vim.o.shell, vim.o.shellcmdflag = saved_shell, saved_flags
        if not ok then error(err, 0) end
      end)
    end

    for _, flag in ipairs({ "-NoProfile", "-NoP" }) do
      it("overrides configured PowerShell profile suppression " .. flag, function()
        local saved_shell, saved_flags = vim.o.shell, vim.o.shellcmdflag
        vim.o.shell, vim.o.shellcmdflag = "powershell.exe " .. flag, "-Command"
        local ok, err = pcall(function()
          local observed = details(call("exec_command", {
            cmd = "[Console]::Write([Environment]::GetCommandLineArgs() -contains '" .. flag .. "')",
            login = true, yield_time_ms = 10000,
          }))
          assert.are.equal("False", observed.output)
        end)
        vim.o.shell, vim.o.shellcmdflag = saved_shell, saved_flags
        if not ok then error(err, 0) end
      end)
    end
  else
    for _, source in ipairs({ "shell", "flags", "option operand" }) do
      it("enables Bash login mode with configured long options in " .. source, function()
        local saved_shell, saved_flags = vim.o.shell, vim.o.shellcmdflag
        vim.o.shell = source == "flags" and "bash" or "bash --noprofile"
        vim.o.shellcmdflag = source == "flags" and "--noprofile -c" or "-c"
        if source == "option operand" then
          vim.o.shell = 'bash --rcfile "-l" --noprofile'
        end
        local ok, err = pcall(function()
          local observed = details(call("exec_command", {
            cmd = "if shopt -q login_shell; then printf LOGIN; else printf PLAIN; fi",
            yield_time_ms = 5000,
          }))
          assert.are.equal("LOGIN", observed.output)
        end)
        vim.o.shell, vim.o.shellcmdflag = saved_shell, saved_flags
        if not ok then
          error(err, 0)
        end
      end)
    end

    for _, source in ipairs({ "shell", "flags", "long option", "option operand" }) do
      it("disables configured login mode in " .. source, function()
        local saved_shell, saved_flags = vim.o.shell, vim.o.shellcmdflag
        vim.o.shell = "bash --noprofile" .. (source == "shell" and " -l" or "")
        vim.o.shellcmdflag = source == "flags" and "-lc" or "-c"
        if source == "long option" then vim.o.shell = "bash --noprofile --login" end
        if source == "option operand" then vim.o.shell = 'bash --rcfile "-l" --noprofile -l' end
        local ok, err = pcall(function()
          local observed = details(call("exec_command", {
            cmd = "if shopt -q login_shell; then printf LOGIN; else printf PLAIN; fi",
            login = false, yield_time_ms = 5000,
          }))
          assert.are.equal("PLAIN", observed.output)
        end)
        vim.o.shell, vim.o.shellcmdflag = saved_shell, saved_flags
        if not ok then error(err, 0) end
      end)
    end

    it("preserves script arguments after the shell option terminator", function()
      local saved_shell, saved_flags = vim.o.shell, vim.o.shellcmdflag
      assert(require("neoagent.fs").write_all(root .. "/-l", [[printf '[%s]%s' "$1" "$2"]]))
      vim.o.shell, vim.o.shellcmdflag = 'bash --noprofile -- -l ""', ""
      local ok, err = pcall(function()
        local observed = details(call("exec_command", { cmd = "literal argument", login = false, yield_time_ms = 5000 }))
        assert.are.equal("[]literal argument", observed.output)
      end)
      vim.o.shell, vim.o.shellcmdflag = saved_shell, saved_flags
      if not ok then error(err, 0) end
    end)
  end

  it("rejects a process reference from a previous Agent lifetime", function()
    local previous = assert(launch(sleeper, false).session_id)
    owner:close("Agent replaced")
    assert.is_true(helper.complete(function() return owner:wait_release(10000) end, 15000))
    owner = require("neoagent.process_sessions").new()
    local current = assert(launch(sleeper, false).session_id)
    local stale = call("write_stdin", { session_id = previous, chars = "\3", yield_time_ms = 0 })
    assert.is_true(stale.isError, "A stale process reference was accepted")
    assert.is_not.equal(previous, current)
    assert.are.equal(current, details(call("write_stdin", { session_id = current, yield_time_ms = 0 })).session_id)
  end)

  if jit.os ~= "Windows" then
    it("uses Neovim option quoting for configured shell paths and arguments", function()
      local saved_shell, saved_flags = vim.o.shell, vim.o.shellcmdflag
      local path = root .. "/quoted shell"
      vim.fn.writefile({ '#!/bin/sh', 'printf "%s|%s|%s|" "$1" "$2" "$3"', 'shift 3', 'exec sh "$@"' }, path)
      assert(vim.uv.fs_chmod(path, 448))
      vim.o.shell = string.format([["%s" "quoted\"value" "path\\name" ""]], path)
      vim.o.shellcmdflag = "-c"
      local ok, err = pcall(function()
        local response = details(call("exec_command", { cmd = "printf done", login = false, yield_time_ms = 5000 }))
        assert.are.equal('quoted"value|path\\name||done', response.output)
      end)
      vim.o.shell, vim.o.shellcmdflag = saved_shell, saved_flags
      if not ok then error(err, 0) end
    end)

    it("preserves configured shell arguments and command flags", function()
      local saved_shell, saved_flags = vim.o.shell, vim.o.shellcmdflag
      vim.o.shell, vim.o.shellcmdflag = "sh -e", "-c"
      local ok, err = pcall(function()
        local response = call("exec_command", { cmd = "false; printf should-not-run", login = false, yield_time_ms = 5000 })
        assert.is_number(assert(response.details).exit_code, require("neoagent.util").text_content(response.content))
        assert.are.equal(1, assert(response.details).exit_code)
        assert.is_nil((require("neoagent.util").text_content(response.content):find("should-not-run", 1, true)))
      end)
      vim.o.shell, vim.o.shellcmdflag = saved_shell, saved_flags
      if not ok then error(err, 0) end
    end)
  end

  it("presents the command as an activity", function()
    local render = (assert(tools.exec_command().render))
    local presentation = render({ arguments = { cmd = "echo preview" }, state = "running" })
    assert.are.same({
      kind = "activity",
      operation = "command",
      ongoing = "Running",
      complete = "Ran",
      subject = "echo preview",
      command = "echo preview",
    }, presentation)
  end)

  it("presents process polling, input, and interruption as distinct activities", function()
    local render = tools.write_stdin().render
    assert(render)
    assert.is_nil(render())
    for _, case in ipairs({
      { chars = "", ongoing = "Waiting for", complete = "Read from", command = "process job-1" },
      { chars = "yes\n", ongoing = "Sending input to", complete = "Sent input to",
        command = 'process job-1\n"yes\\n"' },
      { chars = "\3", ongoing = "Interrupting", complete = "Interrupted", command = "process job-1" },
    }) do
      local value = assert(render({
        arguments = { session_id = "job-1", chars = case.chars }, state = "running",
      }))
      assert.are.equal("activity", value.kind)
      assert.are.equal("command", value.operation)
      assert.are.equal(case.ongoing, value.ongoing)
      assert.are.equal(case.complete, value.complete)
      assert.are.equal(case.command, value.command)
    end
  end)

  it("uses Agent ownership and the Session journal across separate activities", function()
    local model = fake_model.new({
      {
        result = fake_model.assistant({
          {
            type = "toolCall",
            id = "start",
            name = "exec_command",
            arguments = { cmd = sleeper, shell = shell, login = false, yield_time_ms = 0 },
          },
        }, "toolUse"),
      },
      { result = fake_model.assistant({ { type = "text", text = "running" } }) },
    })
    agent = require("neoagent").new({
      default_registry = false,
      workspace_trust = false,
      default_model = { provider = "fake", model = "test" },
      providers = { fake = { api = "fake-api", models = { test = {} } } },
      _apis = {
        ["fake-api"] = function()
          return model
        end,
      },
      persistence = { enabled = false },
      recording = { enabled = false },
      agent_instructions = false,
      skills = false,
      tools = { tools.exec_command(), tools.write_stdin() },
    }, { workspace = root })
    owner = agent:get_process_sessions()
    local run = assert(agent:send("Start the command"))
    assert(type(run) == "table")
    local finished = helper.wait(run, 15000)
    assert.is_true(finished.ok, vim.inspect(finished))
    assert(vim.wait(3000, function()
      return not assert(agent):is_running()
    end, 5))
    local message = agent:get_session():messages()[3]
    assert(message)
    assert.are.equal("toolResult", message.role)
    ---@cast message Neoagent.ToolResultMessage
    local id = assert(details(message).session_id)
    agent:stop()
    assert.are.equal(1, owner:status().reserved)
    model.responses = {
      {
        result = fake_model.assistant({
          { type = "toolCall", id = "poll", name = "write_stdin", arguments = { session_id = id, yield_time_ms = 0 } },
        }, "toolUse"),
      },
      { result = fake_model.assistant({ { type = "text", text = "still running" } }) },
    }
    run = assert(agent:send("Check the command"))
    assert(type(run) == "table")
    assert.is_true(helper.wait(run, 15000).ok)
    agent:destroy()
    assert.is_true(helper.complete(function()
      return owner:wait_release(10000)
    end, 15000))
    assert.are.equal(0, owner:status().reserved)
  end)

  it("enforces an explicit lifetime independently of the initial yield", function()
    local first = details(
      call("exec_command", { cmd = sleeper, shell = shell, login = false, yield_time_ms = 0, timeout_ms = 100 })
    )
    local response = call("write_stdin", { session_id = assert(first.session_id), yield_time_ms = 5000 })
    assert.is_true(response.isError)
    assert.matches("timed out", util.text_content(response.content), 1, true)
    assert.is_nil(assert(response.details).session_id)
  end)
end)
