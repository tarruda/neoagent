local assert = require("luassert")
local command = require("neoagent.process.windows_command")

describe("Windows process command lines", function()
  it("preserves empty arguments, embedded quotes, and backslashes for CreateProcess", function()
    assert.are.equal(
      [["C:\Program Files\nvim.exe" "" plain "two words" "a\"b" "C:\with space\\" "a\\\"b" "back\slash spaced"]],
      command.line({
        [[C:\Program Files\nvim.exe]], "", "plain", "two words", [[a"b]],
        [[C:\with space\]], [[a\"b]], [[back\slash spaced]],
      })
    )
  end)

  it("uses the same literal cmd tail for jobs and native launchers", function()
    local tail = [[echo "quoted" & echo %0 & exit /b 7]]
    for _, shell in ipairs({ "cmd", "cmd.exe", "C:/Windows/System32/cmd.exe" }) do
      local argv = { shell, "/d", "/s", "/c", tail }
      local prepared = assert(command.prepare_cmd(argv))
      local prefix = shell:gsub("/", "\\") .. " /d /s /c "
      assert.are.equal('"' .. tail .. '"', prepared[5])
      assert.are.equal(prefix .. prepared[5], command.line(argv))
      assert.are.equal(tail, argv[5])
    end
    assert.are.equal(
      [[C:\Windows\System32\cmd.exe /d /c echo canonical]],
      command.line({ "C:/Windows/System32/cmd.exe", "/d", "/c", "echo", "canonical" })
    )
  end)
end)
