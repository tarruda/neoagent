local assert = require("luassert")

describe("Windows Tool paths", function()
  it("prepares UNC and extended absolute targets without rebasing them", function()
    local implementation = require("neoagent.tools.write_file")
    local call = {
      workspace = { root = "C:/workspace", cwd = "C:/workspace" },
      on_update = function() end,
    }
    for _, case in ipairs({
      { path = [[\\server\share\file.txt]], expected = "//server/share/file.txt" },
      { path = "//server/share/file.txt", expected = "//server/share/file.txt" },
      { path = [[\\?\UNC\server\share\file.txt]], expected = "//?/UNC/server/share/file.txt" },
      { path = [[\\?\C:\repo\file.txt]], expected = "//?/C:/repo/file.txt" },
    }) do
      local request = implementation.prepare({ path = case.path, content = "contents" }, {}, call)
      assert.are.equal(case.expected, request.resolved_path)
    end
    call.workspace = { root = "//server/share", cwd = "//server/share/workspace" }
    local request = implementation.prepare({ path = "file.txt", content = "contents" }, {}, call)
    assert.are.equal("//server/share/workspace/file.txt", request.resolved_path)
  end)
end)
