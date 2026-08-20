local async = require("neoagent.async")
local fs = require("neoagent.fs")
local Workspace = require("neoagent.workspace")

local function fixture()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local workspace = Workspace.new({ root = root, cwd = root })
  return workspace.root, workspace
end

local function ctx(workspace, updates, capabilities)
  local result = {
    context = { workspace = workspace },
    on_update = function(value) if updates then updates[#updates + 1] = value end end,
  }
  for key, value in pairs(capabilities or {}) do
    result[key] = value
  end
  return result
end

local function execute(tool, arguments, context)
  local run = async.run(function() return tool.execute(arguments, context) end)
  assert(vim.wait(3000, function() return run:is_done() end))
  local result = run:result()
  if result.ok == false and result.error then error(result.error.message) end
  return result
end

-- The fake magick script needs an absolute interpreter: vim.o.shell may
-- resolve to a relative name in restricted environments.
local function shebang_shell()
  local shell = vim.fn.exepath(vim.o.shell)
  return shell ~= "" and shell or vim.o.shell
end

describe("neoagent bundled tools", function()
  local roots = {}
  after_each(function()
    for _, root in ipairs(roots) do vim.fn.delete(root, "rf") end
    roots = {}
  end)

  it("returns fresh exact presets", function()
    local tools = require("neoagent.tools")
    local coding = tools.coding()
    local read_only = tools.read_only()
    assert.are.same({
      "read_file", "write_file", "edit_file", "shell", "read_agent_documentation",
    }, vim.tbl_map(function(t) return t.name end, coding))
    assert.are.same({ "read_file", "grep", "find" }, vim.tbl_map(function(t) return t.name end, read_only))
    assert.are.same({
      "read_file", "write_file", "edit_file", "shell", "grep", "find",
      "read_agent_documentation", "update_plan",
    }, vim.tbl_map(function(t) return t.name end, tools.all()))
    assert.is_true(coding[1].capabilities.read_files)
    assert.are_not.equal(coding[1], tools.coding()[1])
  end)

  it("exposes update_plan without adding it to the default coding preset", function()
    local tools = require("neoagent.tools")
    assert.is_false(vim.tbl_contains(
      vim.tbl_map(function(tool) return tool.name end, tools.coding()),
      "update_plan"))
    assert.are.equal("update_plan", tools.update_plan().name)
    assert.are_not.equal(tools.update_plan(), tools.update_plan())
    assert.is_true(vim.tbl_contains(
      vim.tbl_map(function(tool) return tool.name end, tools.all()),
      "update_plan"))
  end)

  it("matches Codex update_plan payloads and results", function()
    local tool = require("neoagent.tools.update_plan")
    assert.matches("Updates the task plan", tool.description)
    assert.are.same({ "plan" }, tool.input_schema.required)
    assert.are.same({ "step", "status" },
      tool.input_schema.properties.plan.items.required)
    assert.are.same({ "pending", "in_progress", "completed" },
      tool.input_schema.properties.plan.items.properties.status.enum)
    assert.is_false(tool.input_schema.additionalProperties)
    assert.is_false(tool.input_schema.properties.plan.items.additionalProperties)

    local arguments = {
      explanation = "Implementation is underway.",
      plan = {
        { step = "Inspect Codex behavior", status = "completed" },
        { step = "Add the optional tool", status = "in_progress" },
        { step = "Verify the UI", status = "pending" },
      },
    }
    local result = tool.execute(arguments)
    assert.are.equal("Plan updated", result.content[1].text)
    assert.are.same(arguments, result.details)
    assert.are_not.equal(arguments, result.details)
    arguments.plan[1].step = "mutated"
    assert.are.equal("Inspect Codex behavior", result.details.plan[1].step)

    assert.are.same({}, tool.execute({ plan = {} }).details.plan)
    assert.has_no_error(function()
      tool.execute({ plan = {
        { step = "one", status = "in_progress" },
        { step = "two", status = "in_progress" },
      } })
    end)

    local presentation = assert(tool.render({
      state = "success",
      arguments = {
        explanation = "Implementation is underway.",
        plan = {},
      },
    }))
    assert.are.same({
      kind = "plan",
      explanation = "Implementation is underway.",
      plan = {},
    }, presentation)
    assert.are.same({ kind = "plan" }, tool.render({
      state = "running", arguments = { plan = {} },
    }))
  end)

  it("provides renderer-neutral activity data for bundled tools", function()
    local cases = {
      { module = "read_file", arguments = { path = "file.lua" },
        active = "Reading", complete = "Read", value = "file.lua",
        operation = "read" },
      { module = "write_file", arguments = { path = "file.lua" },
        active = "Writing", complete = "Written", value = "file.lua",
        operation = "write" },
      { module = "edit_file", arguments = { path = "file.lua" },
        active = "Editing", complete = "Edited", value = "file.lua",
        operation = "edit" },
      { module = "grep",
        arguments = { pattern = "needle", path = "lua", glob = "*.lua" },
        active = "Searching", complete = "Searched",
        value = "needle in lua (*.lua)", operation = "search" },
      { module = "find", arguments = { pattern = "*.lua", path = "src" },
        active = "Finding", complete = "Found",
        value = "*.lua in src", operation = "search" },
      { module = "shell", arguments = { command = "make test" },
        active = "Running", complete = "Ran", value = "make test",
        operation = "command" },
    }
    for _, case in ipairs(cases) do
      local tool = require("neoagent.tools." .. case.module).new()
      local semantic = assert(tool.render({
        state = "running", arguments = case.arguments,
      }))
      assert.are.equal("activity", semantic.kind)
      assert.are.equal(case.active, semantic.ongoing)
      assert.are.equal(case.complete, semantic.complete)
      assert.are.equal(case.value, semantic.subject)
      assert.are.equal(case.operation, semantic.operation)
      if case.module == "shell" then
        assert.are.equal(case.arguments.command, semantic.command)
      else
        assert.is_nil(semantic.command)
      end
    end
  end)

  it("derives renderer-neutral edit rows from tool results", function()
    local tool = require("neoagent.tools.edit_file").new()
    local legacy = assert(tool.render({
      state = "success", arguments = { path = "legacy.lua" },
      result = { details = {
        diff = " context\n-old\n+new", firstChangedLine = 7,
      } },
    }))
    assert.are.equal("edit", legacy.kind)
    assert.are.equal("legacy.lua", legacy.path)
    assert.are.same({
      { kind = "context", number = 7, text = "context" },
      { kind = "delete", number = 8, text = "old" },
      { kind = "add", number = 8, text = "new" },
    }, legacy.rows)

    local patch = table.concat({
      "@@ -1,8 +1,8 @@",
      " one", "-two", "+a long\tchanged line", " three", " four",
      " five", " six", " seven", " eight has wrapped content",
      "@@ -20 +20 @@",
      "-old tail", "+new tail",
    }, "\n")
    local semantic = assert(tool.render({
      state = "success", arguments = { path = "wrapped.lua" },
      result = { details = { patch = patch } },
    }))
    assert.are.equal("edit", semantic.kind)
    assert.are.equal("separator", semantic.rows[10].kind)
    assert.are.equal("delete", semantic.rows[11].kind)
    assert.are.equal(20, semantic.rows[11].number)
    assert.are.equal("old tail", semantic.rows[11].text)
    assert.are.equal("new tail", semantic.rows[12].text)

    local failed = assert(tool.render({
      state = "error",
      arguments = { path = "failed.lua" },
      result = { details = { patch = patch } },
    }))
    assert.are.equal("activity", failed.kind)
    assert.are.equal("edit", failed.operation)
    assert.are.equal("Editing", failed.ongoing)
    assert.are.equal("Edited", failed.complete)
    assert.are.equal("failed.lua", failed.subject)
  end)

  it("derives independent current plans from Session conversations", function()
    local tool = require("neoagent.tools.update_plan").new()
    local first_session, second_session = {}, {}
    local first = { plan = {
      { step = "First session", status = "in_progress" },
    } }
    local second = { explanation = "Restored", plan = {
      { step = "Old state", status = "completed" },
      { step = "Latest state", status = "pending" },
    } }

    tool.on_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "first", name = "update_plan",
        arguments = first,
      } } },
      { role = "toolResult", toolCallId = "first", toolName = "update_plan",
        isError = false, content = { { type = "text", text = "Plan updated" } } },
    }, { session_id = first_session })
    assert.are.same(first, tool.current({ session_id = first_session }))
    assert.is_nil(tool.current({ session_id = second_session }))

    tool.on_messages({
      { role = "assistant", content = { {
        type = "toolCall", id = "old", name = "update_plan",
        arguments = first,
      } } },
      { role = "toolResult", toolCallId = "old", toolName = "update_plan",
        isError = false, content = { { type = "text", text = "Plan updated" } } },
      { role = "assistant", content = { {
        type = "toolCall", id = "failed", name = "update_plan",
        arguments = { plan = { { step = "Ignored", status = "pending" } } },
      } } },
      { role = "toolResult", toolCallId = "failed", toolName = "update_plan",
        isError = true, content = { { type = "text", text = "denied" } } },
      { role = "assistant", content = { {
        type = "toolCall", id = "latest", name = "update_plan",
        arguments = second,
      } } },
      { role = "toolResult", toolCallId = "latest", toolName = "update_plan",
        isError = false, content = { { type = "text", text = "Plan updated" } },
        details = second },
    }, { session_id = second_session })

    assert.are.same(first, tool.current({ session_id = first_session }))
    assert.are.same(second, tool.current({ session_id = second_session }))
    local copy = tool.current({ session_id = second_session })
    copy.plan[2].step = "mutated"
    assert.are.equal("Latest state",
      tool.current({ session_id = second_session }).plan[2].step)

    tool.on_messages({}, { session_id = second_session })
    assert.is_nil(tool.current({ session_id = second_session }))
  end)

  it("rejects update_plan payloads that Codex cannot deserialize", function()
    local tool = require("neoagent.tools.update_plan")
    assert.has_error(function() tool.execute(nil) end)
    for _, arguments in ipairs({
      { "array" },
      {},
      { plan = "pending" },
      { plan = {}, explanation = 1 },
      { plan = {}, unknown = true },
      { plan = { { "array item" } } },
      { plan = { { status = "pending" } } },
      { plan = { { step = "missing status" } } },
      { plan = { { step = "invalid", status = "cancelled" } } },
      { plan = { { step = "extra", status = "pending", unknown = true } } },
    }) do
      assert.has_error(function() tool.execute(arguments) end)
    end
  end)

  it("reports write_file parent and write failures", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    assert.error_matches(function()
      execute(require("neoagent.tools.write_file"), {
        path = "x.txt", content = "data",
      }, ctx(workspace, nil, {
        fs = { mkdirp = function() return false, "permission denied" end },
      }))
    end, "Could not create parent directory")
    assert.error_matches(function()
      execute(require("neoagent.tools.write_file"), {
        path = "x.txt", content = "data",
      }, ctx(workspace, nil, {
        fs = {
          mkdirp = function() return true end,
          write_all = function() return false, "read-only" end,
        },
      }))
    end, "Could not write file")
  end)

  it("reports fd failures for non-directory search paths", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    assert.error_matches(function()
      execute(require("neoagent.tools.find"), {
        pattern = "x",
      }, ctx(workspace, nil, {
        process = function()
          return { code = 1, stdout = "", stderr = "not a directory" }
        end,
      }))
    end, "find path is not a directory")
  end)

  it("uses injected filesystem and process operations", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local files = {
      [root .. "/read.txt"] = "injected read",
      [root .. "/edit.txt"] = "before",
    }
    local operations = {}
    local injected_fs = {
      create_temp = function() return root .. "/shell.log" end,
      read = function(path)
        operations[#operations + 1] = { "read", path }
        return files[path], files[path] and nil or "missing"
      end,
      mkdirp = function(path)
        operations[#operations + 1] = { "mkdirp", path }
        return true
      end,
      write_all = function(path, data, flags)
        operations[#operations + 1] = { "write", path, data }
        files[path] = flags == "a" and (files[path] or "") .. data or data
        return true
      end,
    }
    local commands = {}
    local injected_process = function(command, opts)
      commands[#commands + 1] = { command = command, opts = opts }
      if command[1] == "rg" then
        return { code = 1, signal = 0, stdout = "", stderr = "", output = "" }
      elseif command[1] == "fd" then
        opts.on_output("found.lua\n", false)
        return {
          code = 0,
          signal = 0,
          stdout = "",
          stderr = "",
          output = "",
        }
      end
      if opts.capture == false and opts.on_output then
        opts.on_output("injected", false)
      end
      return {
        code = 0,
        signal = 0,
        stdout = "injected",
        stderr = "",
        output = "injected",
      }
    end
    local context = ctx(workspace, nil, {
      fs = injected_fs,
      process = injected_process,
    })

    local read = execute(require("neoagent.tools.read_file"), {
      path = "read.txt",
    }, context)
    assert.are.equal("injected read", read.content[1].text)
    execute(require("neoagent.tools.write_file"), {
      path = "nested.txt",
      content = "written",
    }, context)
    execute(require("neoagent.tools.edit_file"), {
      path = "edit.txt",
      edits = { { oldText = "before", newText = "after" } },
    }, context)
    local shell = execute(require("neoagent.tools.shell"), {
      command = "ignored",
    }, context)
    local grep = execute(require("neoagent.tools.grep"), {
      pattern = "ignored",
    }, context)
    local found = execute(require("neoagent.tools.find"), {
      pattern = "*.lua",
    }, context)

    assert.are.equal("written", files[root .. "/nested.txt"])
    assert.are.equal("after", files[root .. "/edit.txt"])
    assert.are.equal("injected", shell.content[1].text)
    assert.are.equal("No matches found", grep.content[1].text)
    assert.are.equal("found.lua", found.content[1].text)
    assert.are.equal("mkdirp", operations[2][1])
    local expected_shell = vim.fn.split(vim.o.shell)
    vim.list_extend(expected_shell, vim.fn.split(vim.o.shellcmdflag))
    expected_shell[#expected_shell + 1] = "ignored"
    assert.are.same(expected_shell, commands[1].command)
    assert.are.equal("rg", commands[2].command[1])
    assert.are.equal("fd", commands[3].command[1])
  end)

  it("passes each shell command flag as a separate process argument",
    function()
      local root, workspace = fixture()
      roots[#roots + 1] = root
      local command
      local original = vim.o.shellcmdflag
      vim.o.shellcmdflag = "/s /c"
      local ok, value = pcall(execute,
        require("neoagent.tools.shell"), {
          command = "echo ok",
        }, ctx(workspace, nil, {
          process = function(argv, opts)
            command = argv
            opts.on_output("ok", false)
            return { code = 0, signal = 0 }
          end,
        }))
      vim.o.shellcmdflag = original
      assert.is_true(ok, tostring(value))
      assert.are.same({
        vim.o.shell, "/s", "/c", "echo ok",
      }, command)
    end)

  it("streams every ImageMagick invocation through stdin and stdout", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local magick = root .. "/magick"
    assert(fs.write_all(magick, "placeholder\n", "w"))
    assert(vim.uv.fs_chmod(magick, 493))
    local old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path

    local png = "\137PNG\r\n\26\ninjected"
    local converted = "\137PNG\r\n\26\nconverted"
    local calls = {}
    local process = function(command, opts)
      calls[#calls + 1] = { command = command, opts = opts }
      if command[2] == "identify" then
        return {
          code = 0,
          signal = 0,
          stdout = opts.stdin == png and "3000 1000" or "2000 667",
          stderr = "",
          output = opts.stdin == png and "3000 1000" or "2000 667",
        }
      end
      return {
        code = 0,
        signal = 0,
        stdout = converted,
        stderr = "",
        output = converted,
      }
    end
    local result = execute(require("neoagent.tools.read_file"), {
      path = "image.png",
    }, ctx(workspace, nil, {
      fs = {
        read = function(path)
          assert.are.equal(root .. "/image.png", path)
          return png
        end,
      },
      process = process,
    }))
    vim.env.PATH = old_path

    assert.are.equal(converted, vim.base64.decode(result.content[2].data))
    assert.matches("Resized from 3000x1000 to 2000x667", result.content[1].text)
    assert.are.equal(3, #calls)
    for _, call in ipairs(calls) do
      assert.are.equal("magick", call.command[1])
      assert.is_truthy(call.command[#call.command]:find(":-", 1, true))
      assert.is_truthy(call.opts.stdin)
      assert.are.equal(30000, call.opts.timeout_ms)
      assert.is_not_nil(call.opts.max_capture_bytes)
      local command = table.concat(call.command, " ")
      assert.matches("%-limit memory 128MiB", command)
      assert.matches("%-limit map 256MiB", command)
      assert.matches("%-limit disk 0", command)
      assert.matches("%-limit area 40000000", command)
    end
  end)

  it("returns the on-demand Neoagent extensibility guide", function()
    local tool = require("neoagent.tools.read_agent_documentation")
    assert.matches("Use this only when the user asks about Neoagent", tool.description)
    assert.are.same({}, tool.input_schema.properties)
    local original = vim.env.MYVIMRC
    local init = vim.fn.tempname() .. "/init.lua"
    vim.env.MYVIMRC = init
    local result = execute(tool, {}, nil)
    vim.env.MYVIMRC = original
    local text = result.content[1].text
    assert.matches("# Neoagent configuration and extensibility", text)
    assert.matches("Choose the smallest useful layer", text)
    assert.matches("Independent Controller example", text)
    assert.matches("Custom tool and execution policy", text)
    assert.matches("update_plan", text)
    assert.matches("resolve_tool", text)
    assert.matches("Custom View", text)
    assert.is_truthy(text:find("Active Neovim configuration: " .. init, 1, true))
    local root = text:match("Plugin root: ([^\n]+)")
    assert.is_truthy(root and vim.uv.fs_stat(root .. "/lua/neoagent/agent.lua"))

    vim.env.MYVIMRC = nil
    text = execute(tool, {}, nil).content[1].text
    vim.env.MYVIMRC = original
    assert.is_truthy(text:find(vim.fn.stdpath("config") .. "/init.lua", 1, true))
  end)

  it("writes and reads disk without consulting buffers", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local write = require("neoagent.tools.write_file")
    local read = require("neoagent.tools.read_file")
    local result = execute(write, { path = "nested/file.txt", content = "one\ntwo\nthree" }, ctx(workspace))
    assert.matches("Successfully wrote 13 bytes", result.content[1].text)
    result = execute(read, { path = "nested/file.txt", offset = 2, limit = 1 }, ctx(workspace))
    assert.matches("two", result.content[1].text)
    assert.matches("offset=3", result.content[1].text)
  end)

  it("validates and bounds text reads", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local read = require("neoagent.tools.read_file")
    assert.has_error(function() execute(read, { path = "" }, ctx(workspace)) end)
    assert.has_error(function() execute(read, { path = "missing" }, {}) end)
    assert.has_error(function() execute(read, { path = "missing" }, ctx(workspace)) end)
    assert.has_error(function() execute(read, { path = "missing", offset = 0 }, ctx(workspace)) end)
    assert.has_error(function() execute(read, { path = "missing", limit = 1.5 }, ctx(workspace)) end)

    assert(fs.write_all(root .. "/short.txt", "one\ntwo", "w"))
    assert.are.equal("one\ntwo", execute(read, { path = "short.txt" }, ctx(workspace)).content[1].text)
    assert.has_error(function() execute(read, { path = "short.txt", offset = 3 }, ctx(workspace)) end)
    assert.has_error(function() execute(read, { path = "." }, ctx(workspace)) end)

    assert(fs.write_all(root .. "/wide.txt", string.rep("x", 51 * 1024), "w"))
    local wide = execute(read, { path = "wide.txt" }, ctx(workspace))
    assert.matches("exceeds 50.0KB limit", wide.content[1].text)

    local lines = {}
    for index = 1, 2001 do lines[index] = "line " .. index end
    assert(fs.write_all(root .. "/long.txt", table.concat(lines, "\n"), "w"))
    local long = execute(read, { path = "long.txt" }, ctx(workspace))
    assert.matches("Showing lines 1%-2000 of 2001", long.content[1].text)
    assert.matches("offset=2001", long.content[1].text)
  end)

  it("streams text reads without loading the complete file", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local chunks = { "zero\none", "\ntwo\nthree" }
    local streamed = 0
    local result = execute(require("neoagent.tools.read_file"), {
      path = "streamed.txt", offset = 2, limit = 2,
    }, ctx(workspace, nil, {
      fs = {
        read = function() error("complete file read was used") end,
        read_chunks = function(path, on_chunk)
          assert.are.equal(root .. "/streamed.txt", path)
          for _, chunk in ipairs(chunks) do
            streamed = streamed + 1
            on_chunk(chunk)
          end
          return true
        end,
      },
    }))

    assert.are.equal(2, streamed)
    assert.matches("^one\ntwo", result.content[1].text)
    assert.matches("1 more lines in file", result.content[1].text)
    assert.matches("offset=4", result.content[1].text)
  end)

  it("returns supported images as raw base64 when ImageMagick is absent", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local png = "\137PNG\r\n\26\nraw"
    assert(fs.write_all(root .. "/image.png", png, "w"))
    local old_path = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    local result = execute(require("neoagent.tools.read_file"), { path = "image.png" }, ctx(workspace))
    vim.env.PATH = old_path
    assert.are.equal("image/png", result.content[2].mimeType)
    assert.are.equal(png, vim.base64.decode(result.content[2].data))
    assert.matches("unavailable", result.content[1].text)
  end)

  it("bounds image input and fallback payloads", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local png = "\137PNG\r\n\26\n" .. string.rep("x", 16)
    assert(fs.write_all(root .. "/image.png", png, "w"))
    local read = require("neoagent.tools.read_file")

    local ok, err = pcall(execute,
      read.new({ max_image_input_bytes = 12 }),
      { path = "image.png" }, ctx(workspace))
    assert.is_false(ok)
    assert.matches("image input exceeds 12 bytes", tostring(err))

    local short_png = "\137PNG\r\n\26\nraw"
    assert(fs.write_all(root .. "/short.png", short_png, "w"))
    ok, err = pcall(execute,
      read.new({ max_image_input_bytes = 10 }),
      { path = "short.png" }, ctx(workspace))
    assert.is_false(ok)
    assert.matches("image input exceeds 10 bytes", tostring(err))

    local old_path = vim.env.PATH
    vim.env.PATH = root
    ok, err = pcall(execute,
      read.new({ max_image_payload_bytes = 16 }),
      { path = "image.png" }, ctx(workspace))
    assert.is_false(ok)
    assert.matches("image payload exceeds 16 bytes", tostring(err))

    local magick = root .. "/magick"
    assert(fs.write_all(magick, "placeholder\n", "w"))
    assert(vim.uv.fs_chmod(magick, 493))
    ok, err = pcall(execute,
      read.new({ max_image_payload_bytes = 16 }),
      { path = "image.png" }, ctx(workspace, nil, {
        process = function(argv)
          if argv[2] == "identify" then
            return { code = 0, stdout = "10 10", stderr = "" }
          end
          return { code = 2, stdout = "", stderr = "failed" }
        end,
      }))
    vim.env.PATH = old_path
    assert.is_false(ok)
    assert.matches("image payload exceeds 16 bytes", tostring(err))
  end)

  it("rejects excessive image dimensions and converted payloads", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local png = "\137PNG\r\n\26\nraw"
    assert(fs.write_all(root .. "/image.png", png, "w"))
    local read = require("neoagent.tools.read_file")
    local magick = root .. "/magick"
    assert(fs.write_all(magick, "placeholder\n", "w"))
    assert(vim.uv.fs_chmod(magick, 493))
    local old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path
    local seen_options
    local identify_output = "100 100"
    local identify_code = 0
    local capability = {
      process = function(argv, opts)
        seen_options = opts
        if argv[2] == "identify" then
          return {
            code = identify_code,
            signal = 0,
            stdout = identify_output,
            stderr = identify_code == 0 and "" or "identify failed",
          }
        end
        return { code = 0, signal = 0, stdout = string.rep("x", 20), stderr = "" }
      end,
    }

    local pixel_ok, pixel_err = pcall(execute,
      read.new({ max_image_pixels = 9999 }),
      { path = "image.png" }, ctx(workspace, nil, capability))
    local payload_ok, payload_err = pcall(execute,
      read.new({ max_image_payload_bytes = 8 }),
      { path = "image.png" }, ctx(workspace, nil, capability))
    identify_output = "invalid"
    local inspect_ok, inspect_err = pcall(execute, read,
      { path = "image.png" }, ctx(workspace, nil, capability))
    identify_code = 2
    local identify_ok, identify_err = pcall(execute, read,
      { path = "image.png" }, ctx(workspace, nil, capability))
    vim.env.PATH = old_path

    assert.is_false(pixel_ok)
    assert.matches("image dimensions exceed 9999 pixels", tostring(pixel_err))
    assert.are.equal(30000, seen_options.timeout_ms)
    assert.is_not_nil(seen_options.max_capture_bytes)
    assert.is_false(payload_ok)
    assert.matches("image payload exceeds 8 bytes", tostring(payload_err))
    assert.is_false(inspect_ok)
    assert.matches("could not inspect image dimensions", tostring(inspect_err))
    assert.is_false(identify_ok)
    assert.matches("identify failed", tostring(identify_err))
  end)

  it("resizes images with ImageMagick and falls back on conversion failure", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local png = "\137PNG\r\n\26\nraw"
    assert(fs.write_all(root .. "/image.png", png, "w"))
    local magick = root .. "/magick"
    assert(fs.write_all(magick, table.concat({
      "#!" .. shebang_shell(),
      "if [ \"$1\" = identify ]; then",
      "  input=$(cat)",
      "  case \"$input\" in *converted*) printf '2000 667' ;; *) printf '3000 1000' ;; esac",
      "  exit 0",
      "fi",
      "printf converted",
      "cat",
    }, "\n"), "w"))
    assert(vim.uv.fs_chmod(magick, 493))
    local old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path
    local result = execute(require("neoagent.tools.read_file"), { path = "image.png" }, ctx(workspace))
    assert.matches("Resized from 3000x1000 to 2000x667", result.content[1].text)
    assert.are.equal("converted" .. png, vim.base64.decode(result.content[2].data))

    assert(fs.write_all(magick, table.concat({
      "#!" .. shebang_shell(),
      "if [ \"$1\" = identify ]; then printf '3000 1000'; exit 0; fi",
      "printf failure >&2",
      "exit 2",
    }, "\n"), "w"))
    assert(vim.uv.fs_chmod(magick, 493))
    result = execute(require("neoagent.tools.read_file"), { path = "image.png" }, ctx(workspace))
    vim.env.PATH = old_path
    assert.matches("resize failed", result.content[1].text)
    assert.are.equal(png, vim.base64.decode(result.content[2].data))
  end)

  it("re-encodes oversized images as bounded JPEG payloads", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local png = "\137PNG\r\n\26\nraw"
    assert(fs.write_all(root .. "/image.png", png, "w"))
    local magick = root .. "/magick"
    assert(fs.write_all(magick, table.concat({
      "#!" .. shebang_shell(),
      "if [ \"$1\" = identify ]; then",
      "  input=$(cat)",
      "  case \"$input\" in *bounded*) printf '1600 1600' ;; *) printf '3000 3000' ;; esac",
      "  exit 0",
      "fi",
      "case \" $* \" in",
      "  *' -quality '*) printf 'bounded jpeg' ;;",
      "  *) dd if=/dev/zero bs=3600000 count=1 2>/dev/null ;;",
      "esac",
    }, "\n"), "w"))
    assert(vim.uv.fs_chmod(magick, 493))
    local old_path = vim.env.PATH
    vim.env.PATH = root .. ":" .. old_path
    local result = execute(require("neoagent.tools.read_file"), { path = "image.png" }, ctx(workspace))
    vim.env.PATH = old_path

    assert.are.equal("image/jpeg", result.content[2].mimeType)
    assert.are.equal("bounded jpeg", vim.base64.decode(result.content[2].data))
    assert.matches("Resized from 3000x3000 to 1600x1600", result.content[1].text)
  end)

  it("applies exact and tolerant edits while preserving BOM and CRLF", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local path = root .. "/edit.txt"
    assert(fs.write_all(path, "\239\187\191one  \r\nsmart \226\128\156quote\226\128\157\r\nlast\r\n", "w"))
    local result = execute(require("neoagent.tools.edit_file"), {
      path = "edit.txt",
      edits = {
        { oldText = "one", newText = "ONE" },
        { oldText = 'smart "quote"', newText = "smart quote" },
      },
    }, ctx(workspace))
    local changed = assert(fs.read(path))
    assert.are.equal("\239\187\191", changed:sub(1, 3))
    assert.matches("ONE\r\nsmart quote\r\nlast", changed)
    assert.is_nil(changed:gsub("\r\n", ""):find("\n", 1, true))
    assert.are.equal(1, result.details.firstChangedLine)
    assert.matches("+ONE", result.details.diff)
    assert.is_true(#result.details.patch > 0)
  end)

  it("rejects duplicate, overlapping, and no-op edits", function()
    local edit = require("neoagent.tools.edit_file")
    assert.has_error(function() edit._apply("one", { { oldText = "missing", newText = "two" } }, "f") end)
    assert.has_error(function() edit._apply("one", { { oldText = 1, newText = "two" } }, "f") end)
    assert.has_error(function() edit._apply("x x", { { oldText = "x", newText = "y" } }, "f") end)
    assert.has_error(function()
      edit._apply("abcdef", {
        { oldText = "abc", newText = "x" }, { oldText = "bc", newText = "y" },
      }, "f")
    end)
    assert.has_error(function() edit._apply("x", { { oldText = "x", newText = "x" } }, "f") end)

    local root, workspace = fixture()
    roots[#roots + 1] = root
    assert.has_error(function()
      execute(edit, { path = "missing", edits = {} }, ctx(workspace))
    end)
  end)

  it("runs shell with updates and returns non-zero output as an error result", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local updates = {}
    local result = execute(require("neoagent.tools.shell"), {
      command = "printf out; printf err >&2; exit 3",
    }, ctx(workspace, updates))
    assert.is_true(result.isError)
    assert.are.equal(3, result.details.exit_code)
    assert.matches("out", result.content[1].text)
    assert.matches("err", result.content[1].text)
    assert.is_true(#updates >= 1)
  end)

  it("defaults shell commands to five minutes and accepts an override", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local timeouts = {}
    local context = ctx(workspace, nil, {
      process = function(_, opts)
        timeouts[#timeouts + 1] = opts.timeout_ms
        return { code = 0, signal = 0 }
      end,
    })
    local shell = require("neoagent.tools.shell")

    execute(shell, { command = "default" }, context)
    execute(shell, { command = "override", timeout = 2.5 }, context)

    local unbounded = "unset"
    execute(shell.new({ default_timeout = false }), { command = "unbounded" },
      ctx(workspace, nil, {
        process = function(_, opts)
          unbounded = opts.timeout_ms
          return { code = 0, signal = 0 }
        end,
      }))

    assert.are.same({ 300000, 2500 }, timeouts)
    assert.is_nil(unbounded)
  end)

  it("escapes non-text shell bytes in updates and the final result", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local updates = {}
    local result = execute(require("neoagent.tools.shell"), {
      command = "ignored",
    }, ctx(workspace, updates, {
      process = function(_, opts)
        opts.on_output("plain\0\27\255\195(tail\n", false)
        return { code = 0, signal = 0 }
      end,
    }))

    assert.is_false(result.isError)
    assert.matches("Non%-text output escaped", result.content[1].text)
    assert.matches("plain\\x00\\x1B\\xFF\\xC3%(tail", result.content[1].text)
    assert.is_true(require("neoagent.util").is_valid_utf8(result.content[1].text))
    assert.is_nil(result.content[1].text:find("\0", 1, true))
    assert.is_true(#updates >= 1)
    for _, update in ipairs(updates) do
      assert.is_true(require("neoagent.util").is_valid_utf8(update.content[1].text))
      assert.is_nil(update.content[1].text:find("\0", 1, true))
    end
  end)

  it("preserves a safe ANSI display copy for shell renderers", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local updates = {}
    local ansi = "plain \27[1;31mred\27[0m \27]0;title\7tail\n"
    local result = execute(require("neoagent.tools.shell"), {
      command = "ignored",
    }, ctx(workspace, updates, {
      process = function(_, opts)
        opts.on_output(ansi, false)
        return { code = 0, signal = 0 }
      end,
    }))

    assert.matches("plain \\x1B%[1;31mred\\x1B%[0m", result.content[1].text)
    assert.are.equal("plain \27[1;31mred\27[0m \27]0;title\\x07tail\n",
      result.details.ansi)
    assert.is_true(#updates >= 1)
    assert.are.equal(result.details.ansi, updates[#updates].details.ansi)
  end)

  it("bounds expanded non-text output and saves the original bytes", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local truncate = require("neoagent.tools.truncate")
    local max_bytes = truncate.MAX_BYTES
    truncate.MAX_BYTES = 50
    local original = string.rep("\0", 20)
    local ok, result = pcall(execute, require("neoagent.tools.shell"), {
      command = "ignored",
    }, ctx(workspace, nil, {
      process = function(_, opts)
        opts.on_output(original, false)
        return { code = 0, signal = 0 }
      end,
    }))
    truncate.MAX_BYTES = max_bytes

    assert.is_true(ok, tostring(result))
    assert.is_false(result.isError)
    assert.is_true(result.details.truncation.truncated)
    assert.are.equal("bytes", result.details.truncation.truncatedBy)
    assert.is_not_nil(result.details.output_path)
    assert.are.equal(original, assert(fs.read(result.details.output_path)))
    assert.is_true(#result.content[1].text < 200)
    vim.fn.delete(result.details.output_path)
  end)

  it("keeps bounded shell output and saves the complete result", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local result = execute(require("neoagent.tools.shell"), {
      command = "i=1; while [ \"$i\" -le 2100 ]; do printf '%s\\n' \"$i\"; i=$((i + 1)); done",
    }, ctx(workspace))
    assert.is_false(result.isError)
    assert.matches("Output truncated", result.content[1].text)
    assert.is_not_nil(result.details.output_path)
    assert.is_not_nil(vim.uv.fs_stat(result.details.output_path))
    vim.fn.delete(result.details.output_path)
    assert.has_error(function()
      execute(require("neoagent.tools.shell"), { command = "true", timeout = 0 }, ctx(workspace))
    end)
    assert.has_error(function()
      execute(require("neoagent.tools.shell"), {
        command = "true", timeout = math.huge,
      }, ctx(workspace))
    end)
  end)

  it("spills shell output incrementally through the injected filesystem", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local spill_path = root .. "/full.log"
    local files = {}
    local writes = {}
    local injected_fs = {
      create_temp = function(prefix)
        assert.are.equal("neoagent-shell-", prefix)
        return spill_path
      end,
      write_all = function(path, data, flags, mode)
        writes[#writes + 1] = { path = path, data = data, flags = flags, mode = mode }
        files[path] = flags == "a" and (files[path] or "") .. data or data
        return true
      end,
    }
    local expected = {}
    local injected_process = function(_, opts)
      assert.is_false(opts.capture)
      for index = 1, 2101 do
        local chunk = tostring(index) .. "\n"
        expected[#expected + 1] = chunk
        opts.on_output(chunk, false)
      end
      return {
        code = 0,
        signal = 0,
        stdout = "",
        stderr = "",
        output = "",
        timed_out = false,
      }
    end
    local result = execute(require("neoagent.tools.shell"), {
      command = "ignored",
    }, ctx(workspace, nil, {
      fs = injected_fs,
      process = injected_process,
    }))

    assert.is_false(result.isError)
    assert.are.equal(spill_path, result.details.output_path)
    assert.are.equal(table.concat(expected), files[spill_path])
    assert.are.equal("w", writes[1].flags)
    assert.are.equal(384, writes[1].mode)
    assert.is_true(#writes > 1)
    for index = 2, #writes do
      assert.are.equal("a", writes[index].flags)
    end
  end)

  it("keeps a bounded shell tail when spill creation or writing fails", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    for _, failure in ipairs({ "create failed", "write failed" }) do
      local injected_fs = {
        create_temp = function()
          if failure == "create failed" then return nil, failure end
          return root .. "/partial.log"
        end,
        write_all = function() return nil, failure end,
      }
      local injected_process = function(_, opts)
        assert.is_false(opts.capture)
        opts.on_output(string.rep("x", 120 * 1024), false)
        return {
          code = 0,
          signal = 0,
          stdout = "",
          stderr = "",
          output = "",
          timed_out = false,
        }
      end
      local result = execute(require("neoagent.tools.shell"), {
        command = "ignored",
      }, ctx(workspace, nil, {
        fs = injected_fs,
        process = injected_process,
      }))

      assert.is_false(result.isError)
      assert.matches(failure, result.content[1].text)
      assert.is_true(#result.content[1].text < 52 * 1024)
      assert.is_nil(result.details.output_path)
      assert.are.equal(120 * 1024, result.details.truncation.totalBytes)
      assert.are.equal("bytes", result.details.truncation.truncatedBy)
    end
  end)

  it("times out and cancels shell processes", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local timed_out = execute(require("neoagent.tools.shell"), {
      command = "sleep 2", timeout = 0.05,
    }, ctx(workspace))
    assert.is_true(timed_out.isError)
    assert.matches("timed out", timed_out.content[1].text)

    local run = async.run(function()
      return require("neoagent.tools.shell").execute({ command = "sleep 2" }, ctx(workspace))
    end)
    vim.defer_fn(function() run:cancel() end, 50)
    assert(vim.wait(3000, function() return run:is_done() end))
    assert.is_false(run:result().ok)
    assert.are.equal("cancelled", run:result().error.kind)
  end)

  it("searches with rg and fd and treats no matches as success", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    assert(fs.write_all(root .. "/one.lua", "needle\n", "w"))
    assert(fs.write_all(root .. "/two.txt", "other\n", "w"))
    local grep = execute(require("neoagent.tools.grep"), { pattern = "needle" }, ctx(workspace))
    assert.matches("one.lua:1:needle", grep.content[1].text)
    local none = execute(require("neoagent.tools.grep"), { pattern = "absent" }, ctx(workspace))
    assert.are.equal("No matches found", none.content[1].text)
    local found = execute(require("neoagent.tools.find"), { pattern = "*.lua" }, ctx(workspace))
    assert.matches("one.lua", found.content[1].text)
    local no_files = execute(
      require("neoagent.tools.find"), { pattern = "*.missing" }, ctx(workspace))
    assert.are.equal("No files found", no_files.content[1].text)
  end)

  it("applies search options and reports bounded results", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    assert(fs.write_all(root .. "/one.lua", "Needle[\ncontext\nNeedle[\n", "w"))
    assert(fs.write_all(root .. "/two.lua", "Needle[\n", "w"))
    assert(fs.write_all(root .. "/ignored.txt", "Needle[\n", "w"))
    local grep_tool = require("neoagent.tools.grep")
    local grep = execute(grep_tool, {
      pattern = "needle[", ignoreCase = true, literal = true, glob = "*.lua", context = 0, limit = 1,
    }, ctx(workspace))
    assert.matches("%.lua:1:Needle%[", grep.content[1].text)
    assert.matches("Results truncated", grep.content[1].text)
    assert.is_nil(grep.content[1].text:find("ignored.txt", 1, true))
    assert.has_error(function() execute(grep_tool, { pattern = "x", context = -1 }, ctx(workspace)) end)
    assert.has_error(function() execute(grep_tool, { pattern = "x", glob = true }, ctx(workspace)) end)

    local found = execute(require("neoagent.tools.find"), { pattern = "*.lua", limit = 1 }, ctx(workspace))
    assert.matches("Results truncated", found.content[1].text)
  end)

  it("bounds search output while the process is running", function()
    local root, workspace = fixture()
    roots[#roots + 1] = root
    local calls = 0
    local process = function(command, opts)
      calls = calls + 1
      assert.is_false(opts.capture)
      assert.is_function(opts.on_output)
      local prefix = command[1] == "rg" and "file.lua:1:" or ""
      for index = 1, 1000 do
        opts.on_output(prefix .. "result-" .. index .. "\n", false)
      end
      return { code = 0, signal = 0, stdout = "", stderr = "", output = "" }
    end
    local context = ctx(workspace, nil, { process = process })

    local grep = execute(require("neoagent.tools.grep"), {
      pattern = "result", limit = 2,
    }, context)
    local found = execute(require("neoagent.tools.find"), {
      pattern = "*", limit = 2,
    }, context)

    assert.are.equal(2, calls)
    assert.matches("showing 2 of at least 1000 lines", grep.content[1].text)
    assert.matches("showing 2 of at least 1000 entries", found.content[1].text)
    assert.is_true(#grep.content[1].text < 1024)
    assert.is_true(#found.content[1].text < 1024)
  end)
end)
