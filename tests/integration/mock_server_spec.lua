local mock_server = require("tests.helpers.mock_server")

describe("mock server process cleanup", function()
  it("terminates the mock server process on stop", function()
    local server = mock_server.start("tests/fixtures/openai/stream.json")
    assert(server:stop(), "stop must terminate the mock server process")
    assert.is_not_nil(server.exit, "stop must reap the mock server process")
  end)
end)
