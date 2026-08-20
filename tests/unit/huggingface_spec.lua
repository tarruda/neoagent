local huggingface = require("neoagent.providers.llama.huggingface")
local fake_transport = require("tests.helpers.fake_transport")

describe("neoagent Hugging Face client", function()
  local function wait(run)
    assert(vim.wait(3000, function() return run:is_done() end))
    return run:result()
  end

  it("discovers HF_TOKEN from environment and token files", function()
    local original = vim.env.HF_TOKEN
    local original_home = vim.env.HF_HOME
    vim.env.HF_TOKEN = nil
    local directory = vim.fn.tempname()
    vim.fn.delete(directory)
    vim.fn.mkdir(directory, "p")
    require("neoagent.fs").write_all(directory .. "/token", "file-token\n", "w", 384)
    vim.env.HF_HOME = directory
    assert.are.equal("file-token", huggingface.find_token())
    vim.env.HF_TOKEN = "env-token"
    assert.are.equal("env-token", huggingface.find_token())
    vim.env.HF_TOKEN = original
    vim.env.HF_HOME = original_home
    vim.fn.delete(directory, "rf")
  end)

  it("searches GGUF models", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ { id = "owner/repo", downloads = 42 }, { bad = true } }) },
    }
    local value = huggingface.new({ transport = transport })
    local result = wait(value:search("a b"))
    assert.are.same({ { id = "owner/repo", downloads = 42 } }, result)
    assert.matches("search=a%%20b", transport.fetch_requests[1].url)
  end)

  it("parses model details and quantization sizes", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        id = "owner/repo",
        gated = "auto",
        siblings = {
          { rfilename = "model-Q4_K_M.gguf", size = 1000 },
          { rfilename = "model-Q4_K_M-00001-of-00002.gguf", size = 2000 },
          { rfilename = "mmproj-F16.gguf", size = 500 },
        },
      }) },
    }
    local value = huggingface.new({ transport = transport })
    local result = wait(value:details("owner/repo"))
    assert.are.equal("auto", result.gated)
    assert.are.same({ { name = "Q4_K_M", size = 3000 } }, result.quantizations)
  end)

  it("reports Hugging Face HTTP errors", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { status = 404, body = vim.json.encode({ error = "missing model" }) },
    }
    local value = huggingface.new({ transport = transport })
    local result = wait(value:search("missing"))
    assert.is_false(result.ok)
    assert.matches("missing model", result.error.message)
  end)

  it("reports invalid search and details payloads", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({ error = "not a list" }) },
    }
    local value = huggingface.new({ transport = transport })
    local result = wait(value:search("bad"))
    assert.is_false(result.ok)
    assert.matches("invalid search results", result.error.message)

    transport.fetches = { { body = vim.json.encode("bad") } }
    result = wait(value:details("owner/repo"))
    assert.is_false(result.ok)
    assert.matches("invalid model details", result.error.message)
  end)

  it("sorts quantizations with recommended and incomplete sizes", function()
    local transport = fake_transport.new()
    transport.fetches = {
      { body = vim.json.encode({
        id = "owner/repo",
        siblings = {
          { rfilename = "model-Q8_0.gguf", size = 900 },
          { rfilename = "model-Q4_K_M.gguf" },
          { rfilename = "model-F16.gguf", size = 100 },
          { rfilename = "model-Q4_0.gguf", size = 100 },
          { rfilename = "model-Q5_0.gguf", size = 100 },
        },
      }) },
    }
    local value = huggingface.new({ transport = transport })
    local result = wait(value:details("owner/repo"))
    assert.are.same({
      { name = "Q4_K_M" },
      { name = "F16", size = 100 },
      { name = "Q4_0", size = 100 },
      { name = "Q5_0", size = 100 },
      { name = "Q8_0", size = 900 },
    }, result.quantizations)
  end)
end)
