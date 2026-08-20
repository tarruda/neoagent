local agent = require("neoagent.agent")
local async = require("neoagent.async")
local composition = require("neoagent.sandbox.composition")
local fake_model = require("tests.helpers.fake_model")
local fs = require("neoagent.fs")
local platform_dispatch = require("neoagent.sandbox.platform")
local process = require("neoagent.process")
local tools_module = require("neoagent.tools")
local Workspace = require("neoagent.workspace")

local platform, dispatch_status = platform_dispatch.select()
local status = dispatch_status
if platform then
  local ok, value = pcall(platform.check, {
    fs = fs,
    process = process.run,
  })
  status = ok and value or {
    ok = false,
    platform = platform.name,
    stage = "requirements",
    message = tostring(value),
  }
end
local active = platform ~= nil and status and status.ok == true
local required = vim.env.NEOAGENT_REQUIRE_SANDBOX == "1"
local sandbox_test = active and it or pending
local linux_sandbox_test =
  active and platform.name == "linux" and it or pending
-- Only the hosted 0.10 runner demonstrated a persistent startup helper, so
-- keep the regression on that reported path while the shared contract covers
-- the other supported releases.
local linux_v010_sandbox_test = active and platform.name == "linux"
  and vim.version().major == 0 and vim.version().minor == 10 and it or pending

local function diagnostic()
  if not status then return "no platform status" end
  local stage = status.stage and status.stage .. ": " or ""
  return stage .. tostring(status.message or "requirements check failed")
end

local function tool_call(id, name, arguments)
  return {
    type = "toolCall",
    id = id,
    name = name,
    arguments = arguments,
  }
end

local function wait(run, timeout)
  assert(vim.wait(timeout or 30000, function() return run:is_done() end, 10))
  local value = run:result()
  if type(value) == "table" and value.ok == false then
    assert.is_true(value.ok,
      value.error and value.error.message or "asynchronous operation failed")
  end
  return value
end

local function messages_by_id(messages)
  local result = {}
  for _, message in ipairs(messages) do
    if message.role == "toolResult" then
      result[message.toolCallId] = message
    end
  end
  return result
end

local function text(message)
  return message and message.content and message.content[1]
    and message.content[1].text or ""
end

local function temporary_directory()
  local path = vim.fn.tempname()
  assert(fs.mkdirp(path))
  return assert(vim.uv.fs_realpath(path))
end

describe("neoagent shared sandbox contract", function()
  local original_cwd
  local original_inherited
  local original_path
  local original_secret
  local roots
  local workspace
  local outside
  local host_readonly
  local denied
  local metadata
  local context
  local configured
  local spill_paths

  if required then
    it("meets the native sandbox requirements required by CI", function()
      assert.is_true(active, diagnostic())
    end)
  end

  before_each(function()
    original_cwd = vim.fn.getcwd()
    original_inherited = vim.env.NEOAGENT_SANDBOX_TEST_INHERITED
    original_path = vim.env.PATH
    original_secret = vim.env.NEOAGENT_SANDBOX_TEST_SECRET
    roots = {}
    spill_paths = {}
    workspace = temporary_directory()
    outside = temporary_directory()
    host_readonly = vim.fs.joinpath(
      original_cwd, ".test-data",
      "sandbox-readonly-" .. tostring(vim.uv.hrtime()))
    denied = vim.fs.joinpath(workspace, "denied")
    metadata = vim.fs.joinpath(workspace, ".git")
    for _, path in ipairs({
      workspace, outside, host_readonly, denied, metadata,
    }) do
      assert(fs.mkdirp(path))
    end
    roots = { workspace, outside, host_readonly }
    assert(fs.write_all(vim.fs.joinpath(metadata, "config"), "protected\n"))
    assert(fs.write_all(vim.fs.joinpath(denied, "secret.txt"), "secret\n"))
    assert(fs.write_all(
      vim.fs.joinpath(host_readonly, "default.txt"), "default-read\n"))
    assert(vim.uv.fs_symlink(denied,
      vim.fs.joinpath(workspace, "denied-link")))
    assert(vim.uv.fs_symlink(outside,
      vim.fs.joinpath(workspace, "escape")))
    vim.env.NEOAGENT_SANDBOX_TEST_INHERITED = "inherited"
    vim.env.NEOAGENT_SANDBOX_TEST_SECRET = "must-not-leak"
    vim.api.nvim_set_current_dir(workspace)
    context = {
      workspace = Workspace.new({ root = workspace, cwd = workspace }),
      controller = "Sandbox integration",
    }
  end)

  after_each(function()
    vim.env.NEOAGENT_SANDBOX_TEST_INHERITED = original_inherited
    vim.env.PATH = original_path
    vim.env.NEOAGENT_SANDBOX_TEST_SECRET = original_secret
    if original_cwd then vim.api.nvim_set_current_dir(original_cwd) end
    for _, path in ipairs(spill_paths or {}) do vim.fn.delete(path) end
    for _, path in ipairs(roots or {}) do vim.fn.delete(path, "rf") end
  end)

  linux_v010_sandbox_test(
    "starts Linux isolation after a Neovim 0.10 helper thread",
    function()
      local wrapper = vim.fs.joinpath(workspace, "threaded-runtime.lua")
      local checked = platform.check({
        fs = fs,
        nvim = vim.env.NEOAGENT_NVIM,
        system = function(argv, opts, timeout)
          local launch = vim.deepcopy(argv)
          local runtime
          for index, argument in ipairs(launch) do
            if argument == "-ll" then
              runtime = launch[index + 1]
              launch[index + 1] = wrapper
              break
            end
          end
          assert.is_string(runtime)
          -- Hold a real OS thread across script loading to reproduce the
          -- hosted process state without depending on its unknown helper.
          assert(fs.write_all(wrapper, table.concat({
            "_G.neoagent_sandbox_test_thread = vim.uv.new_thread(",
            "  function() require('luv').sleep(10000) end)",
            "dofile(" .. string.format("%q", runtime) .. ")",
            "",
          }, "\n")))
          return vim.system(launch, opts):wait(timeout)
        end,
      })
      assert.is_true(checked.ok, checked.message)
    end)

  local function profile(default)
    default.id = "shared-integration"
    vim.list_extend(default.filesystem.entries, {
      { path = denied, access = "deny" },
      {
        path = vim.fs.joinpath(workspace, "reserved"),
        access = "deny",
      },
      { path = outside, access = "deny" },
    })
    local temporary_root = vim.uv.fs_realpath(vim.uv.os_tmpdir())
      or vim.fs.normalize(vim.uv.os_tmpdir())
    default.environment.clear = true
    default.environment.inherit = { "NEOAGENT_SANDBOX_TEST_INHERITED" }
    default.environment.set = {
      PATH = vim.env.PATH,
      HOME = temporary_root,
      SAFE = "visible",
      TMPDIR = temporary_root,
      TMP = temporary_root,
      TEMP = temporary_root,
    }
    return default
  end

  local function sandboxed_config(selected_tools, profile_callback)
    configured = composition.controller({
      name = "Sandbox integration",
      tools = selected_tools,
      _tools_supplied = true,
      sandbox = {
        enabled = true,
        profile = profile_callback or profile,
      },
    }, {
      platform = platform,
      status = status,
    })
    return configured
  end

  sandbox_test("runs every bundled tool through one platform-neutral composition",
    function()
      local bin = vim.fs.joinpath(workspace, "bin")
      assert(fs.mkdirp(bin))
      local magick = vim.fs.joinpath(bin, "magick")
      assert(fs.write_all(magick, table.concat({
        "#!/bin/sh",
        "if [ \"$1\" = identify ]; then",
        "  printf '1 1'",
        "else",
        "  cat",
        "fi",
        "",
      }, "\n")))
      assert(vim.uv.fs_chmod(magick, 493))
      vim.env.PATH = bin .. ":" .. original_path

      local image = "\137PNG\r\n\26\nsandbox\0image"
      assert(fs.write_all(vim.fs.joinpath(workspace, "image.png"), image))
      assert(fs.write_all(vim.fs.joinpath(workspace, "search.txt"),
        "Needle one\nneedle two\n"))
      assert(fs.mkdirp(vim.fs.joinpath(workspace, "nested")))
      assert(fs.write_all(
        vim.fs.joinpath(workspace, "nested", "found.txt"), "found\n"))

      local calls = {
        tool_call("write", "write_file", {
          path = "managed.txt",
          content = "alpha\n",
        }),
        tool_call("edit", "edit_file", {
          path = "managed.txt",
          edits = { { oldText = "alpha", newText = "beta" } },
        }),
        tool_call("read", "read_file", { path = "managed.txt" }),
        tool_call("shell", "shell", {
          command = "printf shell > shell.txt; "
            .. "python3 -c 'import sys; sys.stdout.write(\"x\" * 60000)'",
        }),
        tool_call("grep", "grep", {
          pattern = "needle",
          path = "search.txt",
          ignoreCase = true,
          literal = true,
          context = 0,
          glob = "*.txt",
        }),
        tool_call("find", "find", {
          pattern = "*.txt",
          path = "nested",
          limit = 20,
        }),
        tool_call("plan", "update_plan", {
          explanation = "Sandboxed tool execution",
          plan = {
            { step = "Run every bundled tool", status = "completed" },
          },
        }),
        tool_call("documentation", "read_agent_documentation", {}),
        tool_call("image", "read_file", { path = "image.png" }),
      }
      local selected = tools_module.all()
      local options = sandboxed_config(selected)
      local model = fake_model.new({
        { result = fake_model.assistant(calls, "toolUse") },
        { result = fake_model.assistant({
          { type = "text", text = "complete" },
        }) },
      })
      local completed = wait(agent.run({
        model = model,
        messages = {},
        tools = options.tools,
        execute_tool = options.execute_tool,
        context = context,
      }), 60000)
      assert.is_true(completed.ok)
      local results = messages_by_id(completed.new_messages)
      for id in pairs({
        write = true,
        edit = true,
        read = true,
        shell = true,
        grep = true,
        find = true,
        plan = true,
        documentation = true,
        image = true,
      }) do
        assert.is_false(results[id].isError, text(results[id]))
      end
      assert.are.equal("beta\n",
        assert(fs.read(vim.fs.joinpath(workspace, "managed.txt"))))
      assert.are.equal("shell",
        assert(fs.read(vim.fs.joinpath(workspace, "shell.txt"))))
      assert.matches("beta", text(results.read))
      assert.matches("search.txt", text(results.grep), 1, true)
      assert.matches("found.txt", text(results.find), 1, true)
      assert.are.equal("Plan updated", text(results.plan))
      assert.matches("# Neoagent API map", text(results.documentation))
      assert.are.equal(image,
        vim.base64.decode(results.image.content[2].data))
      assert.is_truthy(results.shell.details.output_path)
      spill_paths[#spill_paths + 1] = results.shell.details.output_path
      local spilled = assert(fs.read(results.shell.details.output_path))
      assert.are.equal(60000, #spilled)
      assert.are.equal(384,
        bit.band(assert(vim.uv.fs_stat(results.shell.details.output_path)).mode,
          511))

      local observed = {}
      for _, call in ipairs(calls) do observed[call.name] = true end
      local expected = {}
      for _, tool in ipairs(tools_module.all()) do expected[tool.name] = true end
      assert.are.same(expected, observed)
      for index, tool in ipairs(selected) do
        assert.is_nil(tool.input_schema.properties.options)
        assert.is_table(options.tools[index].input_schema.properties.options)
      end
    end)

  sandbox_test("classifies native command failures by sandbox-denial evidence",
    function()
      local selected = require("neoagent.tools.shell").new()
      local options = sandboxed_config({ selected })
      local function execute(command)
        return wait(async.run(function()
          return options.execute_tool(selected, {
            command = command,
          }, { context = context })
        end), 30000)
      end
      local function assert_ordinary(value)
        assert.is_true(value.isError)
        assert.is_nil(value.details.sandbox)
        assert.is_nil(text(value):find("blocked by the sandbox", 1, true))
      end
      local function assert_restricted(value)
        assert.is_true(value.isError)
        assert.is_true(value.details.sandbox.ran_restricted)
        assert.matches("blocked by the sandbox", text(value), 1, true)
      end

      assert(fs.write_all(
        vim.fs.joinpath(workspace, "no-match.txt"), "present\n"))
      local no_match = execute(
        "rg --quiet --fixed-strings absent no-match.txt")
      assert_ordinary(no_match)
      assert.are.equal(1, no_match.details.exit_code)
      assert.are.equal(
        "[Command exited with status 1]\n(no output)",
        no_match.content[1].text)

      local protected_write = execute(table.concat({
        "cat > .git/created.txt <<'EOF'",
        "blocked",
        "EOF",
      }, "\n"))
      assert_restricted(protected_write)
      assert.is_nil(vim.uv.fs_stat(
        vim.fs.joinpath(metadata, "created.txt")))

      local missing_write = execute(table.concat({
        "cat > missing/created.txt <<'EOF'",
        "blocked",
        "EOF",
      }, "\n"))
      assert_ordinary(missing_write)
      assert.is_nil(vim.uv.fs_stat(
        vim.fs.joinpath(workspace, "missing")))

      assert_restricted(execute("cat < denied/secret.txt"))
      assert_ordinary(execute("cat < absent.txt"))
    end)

  sandbox_test(
    "reads shell overflow logs and shared temporary replacements",
    function()
      local options = sandboxed_config(tools_module.all())
      local selected = {}
      for _, tool in ipairs(options.tools) do selected[tool.name] = tool end
      local value = wait(async.run(function()
        local shell_result = options.execute_tool(selected.shell, {
          command =
            "python3 -c 'import sys; sys.stdout.write(\"x\\n\" * 30000)'",
        }, { context = context })
        local output_path = assert(shell_result.details.output_path)
        spill_paths[#spill_paths + 1] = output_path
        local ok, read_result = pcall(options.execute_tool,
          selected.read_file, { path = output_path }, { context = context })
        local moved_path = output_path .. ".original"
        assert(vim.uv.fs_rename(output_path, moved_path))
        spill_paths[#spill_paths + 1] = moved_path
        assert(fs.write_all(output_path, "replacement\n"))
        local replacement_ok, replacement_result = pcall(
          options.execute_tool, selected.read_file,
          { path = output_path }, { context = context })
        return {
          read_ok = ok,
          read_result = read_result,
          replacement_ok = replacement_ok,
          replacement_result = replacement_result,
        }
      end), 60000)
      assert.is_true(value.read_ok, tostring(value.read_result))
      assert.is_nil(value.read_result.isError)
      assert.matches("x\nx", text(value.read_result), 1, true)
      assert.is_true(value.replacement_ok,
        tostring(value.replacement_result))
      assert.matches("replacement", text(value.replacement_result), 1, true)
    end)

  sandbox_test("enforces tool filesystem, environment, network, and path boundaries",
    function()
      local server = assert(vim.uv.new_tcp())
      local socket_path = vim.fs.joinpath(workspace, "host.sock")
      local socket_server = assert(vim.uv.new_pipe(false))
      assert(server:bind("127.0.0.1", 0))
      assert(socket_server:bind(socket_path))
      local address = assert(server:getsockname())
      assert(server:listen(4, function()
        local client = vim.uv.new_tcp()
        if client then
          server:accept(client)
          client:close()
        end
      end))
      assert(socket_server:listen(4, function()
        local client = vim.uv.new_pipe(false)
        if client then
          socket_server:accept(client)
          client:close()
        end
      end))

      assert(fs.write_all(vim.fs.joinpath(outside, "edit.txt"), "outside\n"))
      local protected_path = vim.fs.joinpath(metadata, "config")
      local escaped_path = vim.fs.joinpath(outside, "escaped.txt")
      local default_path = vim.fs.joinpath(host_readonly, "default.txt")
      local command = table.concat({
        "set -eu",
        "test \"$(cat " .. vim.fn.shellescape(default_path)
          .. ")\" = default-read",
        "if printf blocked > " .. vim.fn.shellescape(default_path)
          .. " 2>/dev/null; then exit 19; fi",
        "if printf blocked > " .. vim.fn.shellescape(escaped_path)
          .. " 2>/dev/null; then exit 20; fi",
        "if printf blocked > .git/config 2>/dev/null; then exit 21; fi",
        "if printf blocked > denied/created.txt 2>/dev/null; then exit 22; fi",
        "if printf blocked > reserved 2>/dev/null; then exit 23; fi",
        "test \"${NEOAGENT_SANDBOX_TEST_SECRET-unset}\" = unset",
        "test \"${NEOAGENT_SANDBOX_TEST_INHERITED-unset}\" = inherited",
        "test \"${SAFE-unset}\" = visible",
        "python3 - <<'PY'",
        "import socket",
        "try:",
        "    socket.create_connection(('127.0.0.1', "
          .. address.port .. "), timeout=0.2)",
        "except OSError:",
        "    pass",
        "else:",
        "    raise AssertionError('sandbox network escape')",
        "try:",
        "    unix = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)",
        "    unix.connect(" .. string.format("%q", socket_path) .. ")",
        "except OSError:",
        "    pass",
        "else:",
        "    raise AssertionError('sandbox Unix socket escape')",
        "PY",
      }, "\n")
      local calls = {
        tool_call("read-default", "read_file", { path = default_path }),
        tool_call("write-default", "write_file",
          { path = default_path, content = "blocked" }),
        tool_call("read-denied", "read_file",
          { path = "denied/secret.txt" }),
        tool_call("read-link", "read_file",
          { path = "denied-link/secret.txt" }),
        tool_call("write-outside", "write_file",
          { path = escaped_path, content = "blocked" }),
        tool_call("write-metadata", "write_file",
          { path = ".git/config", content = "blocked" }),
        tool_call("write-link", "write_file",
          { path = "escape/escaped.txt", content = "blocked" }),
        tool_call("edit-outside", "edit_file", {
          path = vim.fs.joinpath(outside, "edit.txt"),
          edits = { { oldText = "outside", newText = "changed" } },
        }),
        tool_call("edit-metadata", "edit_file", {
          path = ".git/config",
          edits = { { oldText = "protected", newText = "changed" } },
        }),
        tool_call("grep-denied", "grep",
          { pattern = "secret", path = "denied" }),
        tool_call("grep-link", "grep",
          { pattern = "secret", path = "denied-link" }),
        tool_call("find-denied", "find",
          { pattern = "*", path = "denied" }),
        tool_call("find-link", "find",
          { pattern = "*", path = "denied-link" }),
        tool_call("shell-boundaries", "shell", {
          command = command,
          timeout = 5,
        }),
      }
      local options = sandboxed_config(tools_module.all())
      local model = fake_model.new({
        { result = fake_model.assistant(calls, "toolUse") },
        { result = fake_model.assistant({
          { type = "text", text = "continued" },
        }) },
      })
      local completed = wait(agent.run({
        model = model,
        messages = {},
        tools = options.tools,
        execute_tool = options.execute_tool,
        context = context,
      }), 60000)
      server:close()
      socket_server:close()
      assert.is_true(completed.ok)
      local results = messages_by_id(completed.new_messages)
      for _, id in ipairs({
        "write-default", "read-denied", "read-link", "write-outside",
        "write-metadata", "write-link", "edit-outside", "edit-metadata",
        "grep-denied", "grep-link", "find-denied", "find-link",
      }) do
        assert.is_true(results[id].isError, id .. ": " .. text(results[id]))
      end
      for _, id in ipairs({
        "write-default", "read-denied", "read-link", "write-outside",
        "write-metadata", "write-link", "edit-outside", "edit-metadata",
      }) do
        assert.matches("require_escalation", text(results[id]), 1, true)
      end
      for _, id in ipairs({
        "grep-denied", "grep-link",
      }) do
        assert.is_true(results[id].details.sandbox.ran_restricted)
        assert.matches("blocked by the sandbox", text(results[id]), 1, true)
      end
      for _, id in ipairs({ "find-denied", "find-link" }) do
        assert.is_truthy(
          text(results[id]):find("require_escalation", 1, true),
          id .. ": " .. text(results[id]))
      end
      assert.is_false(results["shell-boundaries"].isError,
        text(results["shell-boundaries"]))
      assert.is_false(results["read-default"].isError,
        text(results["read-default"]))
      assert.matches("default-read", text(results["read-default"]), 1, true)
      assert.are.equal("default-read\n", assert(fs.read(default_path)))
      assert.are.equal("protected\n", assert(fs.read(protected_path)))
      assert.are.equal("outside\n",
        assert(fs.read(vim.fs.joinpath(outside, "edit.txt"))))
      assert.is_nil(vim.uv.fs_stat(escaped_path))
      assert.is_nil(vim.uv.fs_stat(
        vim.fs.joinpath(denied, "created.txt")))
      assert.is_nil(vim.uv.fs_stat(
        vim.fs.joinpath(workspace, "reserved")))
    end)

  sandbox_test("protects read-only paths before they exist", function()
    vim.fn.delete(metadata, "rf")
    assert.is_nil(vim.uv.fs_stat(metadata))
    local selected = {
      require("neoagent.tools.write_file").new(),
      require("neoagent.tools.shell").new(),
    }
    local options = sandboxed_config(selected)
    local value = options.execute_tool(selected[1], {
      path = ".git/config",
      content = "created\n",
    }, { context = context })
    assert.is_true(value.isError, text(value))
    assert.matches("require_escalation", text(value), 1, true)
    assert.is_nil(vim.uv.fs_stat(metadata))
    value = wait(async.run(function()
      return options.execute_tool(selected[2], {
        command = "if mkdir .git 2>/dev/null"
          .. " && printf created > .git/config 2>/dev/null;"
          .. " then exit 41; fi",
      }, { context = context })
    end), 30000)
    assert.is_false(value.isError, text(value))
    assert.is_nil(vim.uv.fs_stat(metadata))
  end)

  sandbox_test("preserves Git discovery across a missing workspace marker",
    function()
      local parent = vim.fs.joinpath(
        original_cwd, ".test-data",
        "sandbox-parent-" .. tostring(vim.uv.hrtime()))
      local nested = vim.fs.joinpath(parent, "workspace")
      assert(fs.mkdirp(nested))
      roots[#roots + 1] = parent
      local initialized = vim.system({
        "git", "-C", parent, "init", "-q",
      }, { text = true }):wait()
      assert.are.equal(0, initialized.code, initialized.stderr)
      assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(nested, ".git")))
      local discovered = vim.system({
        "git", "-C", nested, "rev-parse", "--show-toplevel",
      }, { text = true }):wait()
      assert.are.equal(0, discovered.code, discovered.stderr)
      assert.are.equal(vim.uv.fs_realpath(parent),
        vim.trim(discovered.stdout))
      local nested_context = {
        workspace = Workspace.new({ root = nested, cwd = nested }),
        controller = "Nested sandbox integration",
      }
      local active_profile = composition.default_profile({
        context = nested_context,
      })
      active_profile.environment.set.PATH = vim.env.PATH
      local value = wait(async.run(function()
        return require("neoagent.sandbox").sandbox_exec({
          "git", "rev-parse", "--show-toplevel",
        }, {
          profile = active_profile,
          cwd = nested,
          env = active_profile.environment.set,
        })
      end), 30000)
      assert.are.equal(0, value.code, value.stderr)
      assert.are.equal(vim.uv.fs_realpath(parent), vim.trim(value.stdout))
      assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(nested, ".git")))
    end)

  linux_sandbox_test(
    "keeps a protected marker absent while a command runs and preserves replacements",
    function()
      local parent = vim.fs.joinpath(
        original_cwd, ".test-data",
        "sandbox-live-parent-" .. tostring(vim.uv.hrtime()))
      local nested = vim.fs.joinpath(parent, "workspace")
      local protected = vim.fs.joinpath(nested, ".git")
      local ready = vim.fs.joinpath(nested, "ready")
      local release = vim.fs.joinpath(nested, "release")
      local discovered_path = vim.fs.joinpath(nested, "discovered")
      assert(fs.mkdirp(nested))
      roots[#roots + 1] = parent
      local initialized = vim.system({
        "git", "-C", parent, "init", "-q",
      }, { text = true }):wait()
      assert.are.equal(0, initialized.code, initialized.stderr)
      local nested_context = {
        workspace = Workspace.new({ root = nested, cwd = nested }),
        controller = "Live sandbox integration",
      }
      local active_profile = composition.default_profile({
        context = nested_context,
      })
      active_profile.environment.set.PATH = vim.env.PATH
      local run = async.run(function()
        return require("neoagent.sandbox").sandbox_exec({
          "sh", "-c", table.concat({
            "set -eu",
            "git rev-parse --show-toplevel > discovered",
            ": > ready",
            "while test ! -e release; do sleep 0.01; done",
            "rm -rf .git 2>/dev/null || true",
          }, "\n"),
        }, {
          profile = active_profile,
          cwd = nested,
          env = active_profile.environment.set,
        })
      end)
      assert(vim.wait(10000, function()
        return vim.uv.fs_stat(ready) ~= nil or run:is_done()
      end, 10))
      assert.is_false(run:is_done(),
        run:is_done() and vim.inspect(run:result()) or nil)
      assert.is_nil(vim.uv.fs_lstat(protected))
      local discovered = vim.system({
        "git", "-C", nested, "rev-parse", "--show-toplevel",
      }, { text = true }):wait()
      assert.are.equal(0, discovered.code, discovered.stderr)
      assert.are.equal(vim.uv.fs_realpath(parent),
        vim.trim(discovered.stdout))

      assert(fs.mkdirp(protected))
      assert(fs.write_all(
        vim.fs.joinpath(protected, "host-owned"), "preserve\n"))
      assert(fs.write_all(release, "release\n"))
      local value = wait(run, 30000)
      assert.are.equal(0, value.code, value.stderr)
      assert.are.equal(vim.uv.fs_realpath(parent),
        vim.trim(assert(fs.read(discovered_path))))
      assert.are.equal("preserve\n",
        assert(fs.read(vim.fs.joinpath(protected, "host-owned"))))
    end)

  linux_sandbox_test(
    "mediates creation syscalls for missing protected paths",
    function()
      local names = {
        "protected-open",
        "protected-mkdir",
        "protected-rename",
        "protected-symlink",
        "protected-link",
        "protected-fifo",
        "protected-socket",
      }
      assert(fs.write_all(
        vim.fs.joinpath(workspace, "creation-source"), "source\n"))
      assert(fs.write_all(
        vim.fs.joinpath(workspace, "rename-source"), "rename\n"))
      local active_profile = profile(
        composition.default_profile({ context = context }))
      active_profile.network = "enabled"
      for index, name in ipairs(names) do
        active_profile.filesystem.entries[
          #active_profile.filesystem.entries + 1
        ] = {
          path = vim.fs.joinpath(workspace, name),
          access = index % 2 == 0 and "read" or "deny",
        }
      end
      local value = wait(async.run(function()
        return require("neoagent.sandbox").sandbox_exec({
          "python3", "-c", table.concat({
            "import os",
            "import socket",
            "directory = os.open('.', os.O_RDONLY | os.O_DIRECTORY)",
            "sock = socket.socket(socket.AF_UNIX)",
            "operations = [",
            "  lambda: os.open('protected-open', "
              .. "os.O_WRONLY | os.O_CREAT, 0o600, dir_fd=directory),",
            "  lambda: os.mkdir('protected-mkdir', dir_fd=directory),",
            "  lambda: os.rename('rename-source', 'protected-rename'),",
            "  lambda: os.symlink('target', 'protected-symlink', "
              .. "dir_fd=directory),",
            "  lambda: os.link('creation-source', 'protected-link', "
              .. "dst_dir_fd=directory),",
            "  lambda: os.mkfifo('protected-fifo', dir_fd=directory),",
            "  lambda: sock.bind('protected-socket'),",
            "]",
            "for operation in operations:",
            "    try:",
            "        operation()",
            "    except OSError:",
            "        pass",
            "    else:",
            "        raise AssertionError('protected creation succeeded')",
            "sock.close()",
            "allowed = socket.socket(socket.AF_UNIX)",
            "allowed.bind('allowed-socket')",
            "allowed.close()",
            "os.unlink('allowed-socket')",
            "os.close(directory)",
          }, "\n"),
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
        })
      end), 30000)
      assert.are.equal(0, value.code, value.stderr)
      for _, name in ipairs(names) do
        assert.is_nil(vim.uv.fs_lstat(vim.fs.joinpath(workspace, name)))
      end
      assert.are.equal("rename\n",
        assert(fs.read(vim.fs.joinpath(workspace, "rename-source"))))
    end)

  linux_sandbox_test(
    "mediates protected paths with inherited host procfs",
    function()
      vim.fn.delete(metadata, "rf")
      local active_profile = profile(
        composition.default_profile({ context = context }))
      local inherited = vim.deepcopy(status.capabilities)
      inherited.procfs = "host"
      inherited.procfs_isolated = false
      local value = wait(async.run(function()
        return platform.exec({
          argv = {
            "sh", "-c",
            "printf allowed > inherited-proc.txt; test ! -e .git",
          },
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
        }, {
          fs = fs,
          process = process.run,
          capabilities = inherited,
        })
      end), 30000)
      assert.are.equal(0, value.code, value.stderr)
      assert.are.equal("allowed",
        assert(fs.read(vim.fs.joinpath(workspace, "inherited-proc.txt"))))
      assert.is_nil(vim.uv.fs_lstat(metadata))
    end)

  sandbox_test("supports explicit grants beneath denied directories", function()
    local public = vim.fs.joinpath(denied, "public")
    assert(fs.mkdirp(public))
    assert(fs.write_all(vim.fs.joinpath(public, "visible.txt"), "visible\n"))
    local active_profile = profile(
      composition.default_profile({ context = context }))
    active_profile.filesystem.entries[
      #active_profile.filesystem.entries + 1
    ] = { path = public, access = "read" }
    local value = wait(async.run(function()
      return require("neoagent.sandbox").sandbox_exec({
        "sh", "-c", table.concat({
          "set -eu",
          "test \"$(cat denied/public/visible.txt)\" = visible",
          "if cat denied/secret.txt >/dev/null 2>&1; then exit 31; fi",
          "if printf changed > denied/public/visible.txt 2>/dev/null; then",
          "  exit 32",
          "fi",
        }, "\n"),
      }, {
        profile = active_profile,
        cwd = workspace,
        env = active_profile.environment.set,
      })
    end), 30000)
    assert.is_true(value.code == 0, vim.inspect(value))
    assert.are.equal("visible\n",
      assert(fs.read(vim.fs.joinpath(public, "visible.txt"))))
  end)

  sandbox_test("enforces the profile inside the native filesystem backend",
    function()
      local active_profile = profile(
        composition.default_profile({ context = context }))
      local services = {
        fs = fs,
        process = process.run,
        capabilities = status.capabilities,
      }
      local denied_read = wait(async.run(function()
        local value, err = platform.fs({
          operation = "read",
          path = vim.fs.joinpath(denied, "secret.txt"),
          profile = active_profile,
        }, services)
        return { value = value, error = err }
      end), 30000)
      assert.is_nil(denied_read.value)
      assert.is_string(denied_read.error)

      local denied_write = wait(async.run(function()
        local value, err = platform.fs({
          operation = "write_all",
          path = vim.fs.joinpath(metadata, "config"),
          data = "blocked\n",
          profile = active_profile,
        }, services)
        return { value = value, error = err }
      end), 30000)
      assert.is_nil(denied_write.value)
      assert.is_string(denied_write.error)
      assert.are.equal("protected\n",
        assert(fs.read(vim.fs.joinpath(metadata, "config"))))

      local nonregular = wait(async.run(function()
        local value, err = platform.fs({
          operation = "read",
          path = "/dev/null",
          profile = active_profile,
        }, services)
        return { value = value, error = err }
      end), 30000)
      assert.is_nil(nonregular.value)
      assert.matches("regular file", nonregular.error)
    end)

  sandbox_test("preserves binary process I/O and public execution controls",
    function()
      local sandbox = require("neoagent.sandbox")
      local active_profile = profile(
        composition.default_profile({ context = context }))
      local binary = "input\0bytes\255"
      local chunks = {}
      local value = wait(async.run(function()
        return sandbox.sandbox_exec({
          "python3", "-c", table.concat({
            "import sys",
            "assert sys.argv[1] == ''",
            "data = sys.stdin.buffer.read()",
            "sys.stdout.buffer.write(data)",
            "sys.stderr.buffer.write(b'error' + bytes([0]) + b'bytes')",
          }, "\n"), "",
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
          stdin = binary,
          on_output = function(data, is_stderr)
            chunks[#chunks + 1] = { data = data, stderr = is_stderr }
          end,
        })
      end), 30000)
      assert.is_true(value.code == 0, vim.inspect(value))
      assert.are.equal(binary, value.stdout)
      assert.are.equal("error\0bytes", value.stderr)
      assert.is_true(#chunks >= 2)

      local uncaptured = ""
      value = wait(async.run(function()
        return sandbox.sandbox_exec({
          "python3", "-c",
          "import sys; sys.stdout.buffer.write(b'x' * 70000)",
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
          capture = false,
          on_output = function(data, is_stderr)
            assert.is_false(is_stderr)
            uncaptured = uncaptured .. data
          end,
        })
      end), 30000)
      assert.are.equal(0, value.code)
      assert.are.equal("", value.stdout)
      assert.are.equal("", value.output)
      assert.are.equal(70000, #uncaptured)

      value = wait(async.run(function()
        return sandbox.sandbox_exec({
          "python3", "-c", "import sys; sys.exit(17)",
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
        })
      end), 30000)
      assert.are.equal(17, value.code)

      value = wait(async.run(function()
        return sandbox.sandbox_exec({
          "python3", "-c", "import time; time.sleep(5)",
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
          timeout_ms = 30,
          kill_grace_ms = 30,
        })
      end), 30000)
      assert.is_true(value.timed_out)

      local function detached_writer(path)
        local program = table.concat({
          "import os, sys, time",
          "os.setsid()",
          "time.sleep(0.2)",
          "open(sys.argv[1], 'w').write('late')",
        }, "\n")
        return "python3 -c " .. vim.fn.shellescape(program)
          .. " " .. vim.fn.shellescape(path) .. " >/dev/null 2>&1 &"
      end

      local completed_marker = vim.fs.joinpath(workspace, "late-completed")
      value = wait(async.run(function()
        return sandbox.sandbox_exec({
          "sh", "-c", detached_writer(completed_marker),
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
        })
      end), 30000)
      assert.is_true(value.code == 0, vim.inspect(value))
      vim.wait(500, function()
        return vim.uv.fs_stat(completed_marker) ~= nil
      end, 10)
      assert.is_nil(vim.uv.fs_stat(completed_marker))

      local cancelled_marker = vim.fs.joinpath(workspace, "late-cancelled")
      local cancelled = async.run(function()
        return sandbox.sandbox_exec({
          "sh", "-c", detached_writer(cancelled_marker) .. " wait",
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
          kill_grace_ms = 30,
        })
      end)
      vim.defer_fn(function() cancelled:cancel() end, 30)
      assert(vim.wait(30000, function() return cancelled:is_done() end, 10))
      local cancelled_result = cancelled:result()
      assert.is_false(cancelled_result.ok)
      assert.are.equal("cancelled", cancelled_result.error.kind)
      vim.wait(500, function()
        return vim.uv.fs_stat(cancelled_marker) ~= nil
      end, 10)
      assert.is_nil(vim.uv.fs_stat(cancelled_marker))
    end)

  sandbox_test("shares host temporary files across process invocations",
    function()
      local sandbox = require("neoagent.sandbox")
      local active_profile = profile(
        composition.default_profile({ context = context }))
      local marker = "neoagent-sandbox-shared-" .. tostring(vim.uv.hrtime())
      local host_marker = vim.fs.joinpath(
        active_profile.environment.set.TMPDIR, marker)
      spill_paths[#spill_paths + 1] = host_marker
      assert.is_nil(vim.uv.fs_stat(host_marker))

      local value = wait(async.run(function()
        return sandbox.sandbox_exec({
          "sh", "-c", "printf shared > \"$TMPDIR/" .. marker
            .. "\"; printf %s \"$TMPDIR/" .. marker .. "\"",
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
        })
      end), 30000)
      assert.is_true(value.code == 0, vim.inspect(value))
      assert.are.equal(host_marker, value.stdout)
      assert.are.equal("shared", assert(fs.read(host_marker)))

      value = wait(async.run(function()
        return sandbox.sandbox_exec({
          "sh", "-c", "cat \"$TMPDIR/" .. marker .. "\"",
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
        })
      end), 30000)
      assert.is_true(value.code == 0, vim.inspect(value))
      assert.are.equal("shared", value.stdout)
    end)

  sandbox_test("allows networking when the profile enables it", function()
    local server = assert(vim.uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    local address = assert(server:getsockname())
    assert(server:listen(4, function()
      local client = vim.uv.new_tcp()
      if client then
        server:accept(client)
        client:close()
      end
    end))

    local active_profile = profile(
      composition.default_profile({ context = context }))
    active_profile.network = "enabled"
    local value = wait(async.run(function()
      return require("neoagent.sandbox").sandbox_exec({
        "python3", "-c", table.concat({
          "import socket",
          "listener = socket.socket()",
          "listener.bind(('127.0.0.1', 0))",
          "listener.listen()",
          "listener.close()",
          "connection = socket.create_connection(('127.0.0.1', "
            .. address.port .. "), timeout=1)",
          "connection.close()",
        }, "\n"),
      }, {
        profile = active_profile,
        cwd = workspace,
        env = active_profile.environment.set,
      })
    end), 30000)
    server:close()
    assert.is_true(value.code == 0, vim.inspect(value))
  end)

  linux_sandbox_test("allows clone flags after inspecting namespace bits",
    function()
      local clone_number = jit.arch == "x64" and 56 or 220
      local exit_signal = jit.arch == "x64" and 41 or 39
      local active_profile = profile(
        composition.default_profile({ context = context }))
      local value = wait(async.run(function()
        return require("neoagent.sandbox").sandbox_exec({
          "python3", "-c", table.concat({
            "import ctypes",
            "import os",
            "import signal",
            "libc = ctypes.CDLL(None, use_errno=True)",
            "signal.signal(" .. exit_signal .. ", signal.SIG_IGN)",
            "pid = libc.syscall(" .. clone_number .. ", "
              .. exit_signal .. ", 0, 0, 0, 0)",
            "if pid == -1:",
            "    raise OSError(ctypes.get_errno(), 'clone failed')",
            "if pid == 0:",
            "    os._exit(0)",
            "os.waitpid(pid, 0x40000000)",
          }, "\n"),
        }, {
          profile = active_profile,
          cwd = workspace,
          env = active_profile.environment.set,
        })
      end), 30000)
      assert.is_true(value.code == 0, vim.inspect(value))
    end)

  sandbox_test("activates the built-in Neo composition from setup", function()
    package.loaded["neoagent"] = nil
    local neoagent = require("neoagent")
    local controller = neoagent.setup({
      workspace_trust = false,
      sandbox = { enabled = true, profile = profile },
      persistence = {
        enabled = false,
        workspace_settings = false,
      },
      agents = false,
      skills = false,
      compaction = false,
    })
    local options = controller:config()
    assert.is_true(options.sandbox.enabled)
    assert.is_nil(options._sandbox_status)
    local sandbox_status = neoagent.sandbox_info()
    assert.is_true(sandbox_status.active)
    assert.is_true(sandbox_status.capabilities.filesystem)
    assert.is_true(sandbox_status.capabilities.shared_tmp)
    local rendered = require("neoagent.sandbox").format_info(sandbox_status)
    if platform.name == "linux" then
      assert.is_true(
        sandbox_status.capabilities.process_supervision)
      assert.is_true(sandbox_status.capabilities.procfs == "fresh"
        or sandbox_status.capabilities.procfs == "host")
      assert.are.equal(
        sandbox_status.capabilities.procfs == "fresh",
        sandbox_status.capabilities.procfs_isolated)
      assert.matches(
        "capability.procfs: " .. sandbox_status.capabilities.procfs,
        rendered, 1, true)
    else
      assert.are.equal("macos", platform.name)
      assert.is_true(sandbox_status.capabilities.process)
      assert.is_true(
        sandbox_status.capabilities.process_supervision)
      assert.is_true(sandbox_status.capabilities.seatbelt)
      assert.matches("capability.seatbelt: yes", rendered, 1, true)
    end
    assert.is_table(controller:get_toolset().tools[1]
      .input_schema.properties.options.properties.require_escalation)
    local controllers = neoagent.default_window():controllers()
    assert.are.equal("Neo", controllers[1]:config().name)
    assert.are.equal("Chat", controllers[2]:config().name)
    assert.is_false(controllers[2]:config().sandbox.enabled)
    controller = neoagent.setup({
      workspace_trust = false,
      sandbox = { enabled = false, profile = profile },
      persistence = {
        enabled = false,
        workspace_settings = false,
      },
      agents = false,
      skills = false,
      compaction = false,
    })
    assert.is_false(controller:config().sandbox.enabled)
    assert.is_false(neoagent.sandbox_info().enabled)
    local stable = controller:get_toolset()
    assert.is_table(stable.tools[1].input_schema.properties.options)
    sandbox_status = assert(neoagent.toggle_sandbox())
    assert.is_true(sandbox_status.active)
    assert.is_false(controller:config().sandbox.enabled)
    assert.are.same(stable.tools, controller:get_toolset().tools)
    assert.are.equal(stable.execute_tool,
      controller:get_toolset().execute_tool)
    sandbox_status = assert(neoagent.toggle_sandbox())
    assert.is_false(sandbox_status.enabled)
    assert.are.same(stable.tools, controller:get_toolset().tools)
    assert.are.equal(stable.execute_tool,
      controller:get_toolset().execute_tool)
  end)
end)
