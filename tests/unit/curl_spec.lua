local curl = require("neoagent.transport.curl")

describe("neoagent.transport.curl", function()
  it("builds an argument vector without a shell", function()
    assert.are.same({
      "curl", "--no-buffer", "--silent", "--show-error", "--fail-with-body",
      "-X", "POST", "-H", "Authorization: Bearer x", "-H",
      "Content-Type: application/json", "--data-binary", "@-", "http://localhost",
    }, curl.command({
      url = "http://localhost",
      headers = { ["Content-Type"] = "application/json", Authorization = "Bearer x" },
    }))
  end)
end)
