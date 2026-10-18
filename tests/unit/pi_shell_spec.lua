local assert = require("luassert")
local helper = require("tests.helpers.subprocess")
local fake = require("tests.helpers.fake_model")
local util = require("neoagent.util")
local pi = require("neoagent.tools.pi")

describe("Pi command shell selection", function()
  local executable, exepath = vim.fn.executable, vim.fn.exepath
  local editor_shell, editor_flags = vim.o.shell, vim.o.shellcmdflag
  local line_prefix = jit.os == "Windows" and "[Non-text output escaped]\n" or ""
  local line_suffix = jit.os == "Windows" and "\\x0D" or ""
  ---@type string
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.executable, vim.fn.exepath = executable, exepath
    vim.o.shell, vim.o.shellcmdflag = editor_shell, editor_flags
    vim.fn.delete(root, "rf")
  end)

  ---@param names table<string, boolean>
  local function hide(names)
    vim.fn.executable = function(name)
      return names[name] and 0 or executable(name)
    end
    vim.fn.exepath = function(name)
      return names[name] and "" or exepath(name)
    end
  end

  ---@param options? Neoagent.ToolPresetOptions
  ---@return Neoagent.Tool<unknown>
  local function command_tool(options)
    return (assert(pi.coding(options)[2]))
  end

  ---@param tool Neoagent.Tool<unknown>
  ---@param command string
  ---@param executor? Neoagent.ToolExecutor<unknown>
  ---@return Neoagent.ToolResultMessage
  local function execute(tool, command, executor)
    ---@type Neoagent.ToolResultMessage?
    local published
    local model = fake.new({
      {
        result = fake.assistant(
          { { type = "toolCall", id = "shell", name = tool.name, arguments = { command = command } } },
          "toolUse"
        ),
      },
      { result = fake.assistant({ { type = "text", text = "done" } }) },
    })
    local run = require("neoagent.agent_loop").run({
      model = model,
      messages = {},
      tools = { tool },
      execute_tool = executor,
      context = { workspace = { root = root, cwd = root } },
      commit_message = function(message)
        if message.role == "toolResult" then
          ---@cast message Neoagent.ToolResultMessage
          published = message
        end
        return true
      end,
    })
    assert.is_true(helper.wait(run, 15000).ok)
    return (assert(published))
  end

  ---@param tool Neoagent.Tool<unknown>
  ---@return string
  local function prompt(tool)
    return (assert(tool.prompt_snippet))
  end

  it("executes commands without Bash installed", function()
    hide({ bash = true, ["bash.exe"] = true, pwsh = true, ["pwsh.exe"] = true })
    local tool = command_tool()
    local result = execute(tool, jit.os == "Windows" and "Write-Output 'portable héllo'" or "printf 'portable héllo'")
    assert.is_false(result.isError, util.text_content(result.content))
    assert.are.equal(line_prefix .. "portable héllo" .. line_suffix, util.trim(util.text_content(result.content)))
    assert.are.equal(jit.os == "Windows" and "powershell" or "shell", tool.name)
    assert.is_nil((prompt(tool):find("Use bash", 1, true)))
    assert.matches(jit.os == "Windows" and "Execute PowerShell commands" or "Execute sh commands", prompt(tool))
  end)

  it("honors an explicit shell independently of the editor shell", function()
    vim.o.shell, vim.o.shellcmdflag = "missing-editor-shell", "--invalid"
    local shell = jit.os == "Windows" and "cmd.exe" or "sh"
    local tool = command_tool({ shell = shell })
    assert.are.equal("shell", tool.name)
    local result = execute(tool, jit.os == "Windows" and "echo explicit" or "printf explicit")
    assert.is_false(result.isError, util.text_content(result.content))
    assert.are.equal(line_prefix .. "explicit" .. line_suffix, util.trim(util.text_content(result.content)))
    assert.matches("Execute " .. shell:gsub("%.exe$", "") .. " commands", prompt(tool))
  end)

  it("rejects invalid explicit shells instead of ignoring them", function()
    for _, shell in ipairs({ "", "bash\0", "unsupported-shell" }) do
      assert.has_error(function()
        command_tool({ shell = shell })
      end)
    end
    local tool = command_tool({ shell = vim.fs.joinpath(root, "absent", "bash") })
    local result = execute(tool, "echo must-not-run")
    assert.is_true(result.isError)
  end)

  it("reports a missing platform shell when no candidate is available", function()
    hide({ bash = true, sh = true, pwsh = true, powershell = true })
    local tool = command_tool()
    local result = execute(tool, "echo must-not-run")
    assert.is_true(result.isError)
    assert.matches(
      "Shell executable was not found: " .. (jit.os == "Windows" and "powershell" or "sh"),
      util.text_content(result.content)
    )
  end)

  it("executes the shell request shown for approval after lookup settings change", function()
    local shell = jit.os == "Windows" and "powershell" or "sh"
    local tool = command_tool({ shell = shell })
    local command = jit.os == "Windows" and "Write-Output 'prepared héllo'" or "printf 'prepared héllo'"
    local result = execute(
      tool,
      command,
      ---@async
      function(current, arguments, ctx)
        local invocation = require("neoagent.tools.invocation")
        local forwarded = invocation.context(ctx, invocation.prepare(current, arguments, ctx))
        local summaries = require("neoagent.sandbox.approval_summary")
        local before = summaries.for_tool(current, arguments, forwarded)
        hide({ [shell] = true })
        vim.o.shell, vim.o.shellcmdflag = "missing-editor-shell", "--invalid"
        assert.are.equal(before, summaries.for_tool(current, arguments, forwarded))
        return current.execute(arguments, forwarded)
      end
    )
    assert.is_false(result.isError, util.text_content(result.content))
    assert.are.equal(line_prefix .. "prepared héllo" .. line_suffix, util.trim(util.text_content(result.content)))
  end)

  if jit.os == "Windows" then
    it("prefers PowerShell 7 and preserves Unicode, quoting and exit status", function()
      local tool = command_tool()
      assert.are.equal("powershell", tool.name)
      local edition = exepath("pwsh") ~= "" and "Core" or "Desktop"
      local result = execute(tool, "Write-Output $PSVersionTable.PSEdition; Write-Output 'héllo \"world\"'; exit 7")
      assert.is_true(result.isError)
      assert.matches(edition .. '\\x0D\nhéllo "world"\\x0D', util.text_content(result.content), 1, true)
      assert.matches("status 7", util.text_content(result.content))
    end)
  else
    it("prefers Bash when available and advertises its syntax", function()
      local tool = command_tool()
      assert.are.equal("bash", tool.name)
      local result = execute(tool, "items=(one two); printf '%s' \"${items[1]}\"")
      assert.is_false(result.isError, util.text_content(result.content))
      assert.are.equal("two", util.text_content(result.content))
      assert.matches("Execute bash commands", prompt(tool))
    end)

    it("executes a configured shell path containing spaces", function()
      local directory = vim.fs.joinpath(root, "custom shell")
      vim.fn.mkdir(directory, "p")
      local shell = vim.fs.joinpath(directory, "sh")
      assert(vim.uv.fs_symlink(exepath("sh"), shell))
      local tool = command_tool({ shell = shell })
      local result = execute(tool, "printf '%s' \"$0\"")
      assert.is_false(result.isError, util.text_content(result.content))
      assert.are.equal(shell, util.text_content(result.content))
    end)
  end
end)
