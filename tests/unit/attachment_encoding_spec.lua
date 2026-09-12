local assert = require("luassert")
local async_test = require("tests.helpers.async_test")
local memory = require("neoagent.files.memory")
local images = require("neoagent.api.images")
local util = require("neoagent.util")

describe("semantic attachment request encoding", function()
  async_test("rejects unsupported remote protocols and inconsistent retained metadata", function()
    local remote_ok, remote_err = pcall(function()
      images.remote("future-images", "remote-id")
    end)
    assert.is_false(remote_ok)
    assert.matches("Unsupported image protocol", tostring(remote_err))

    local source = memory.new()
    local file = assert(source.put("stable image"))
    local encode = images.inline("openai-responses", source)
    assert.is_table(encode({
      type = "image", file_id = file.file_id, bytes = file.bytes,
      mime_type = "image/png",
    }))
    local ok, err = pcall(encode, {
      type = "image", file_id = file.file_id, bytes = file.bytes + 1,
      mime_type = "image/png",
    })
    assert.is_false(ok)
    if type(err) ~= "table" then
      error("attachment error was not structured")
    end
    assert.matches("size does not match", tostring(err.message))
  end)

  for _, api in ipairs({ "openai_responses", "openai_completions", "anthropic_messages" }) do
    async_test("resolves local references only while encoding " .. api, function()
      local source = memory.new()
      local file = assert(source.put("\0synthetic image\255"))
      ---@type Neoagent.ImageBlock
      local image = { type = "image", file_id = file.file_id, bytes = file.bytes,
        mime_type = "image/png", filename = "sample.png" }
      ---@type Neoagent.Message[]
      local messages = { { role = "user", content = { image, image } } }
      local before = util.copy(messages)
      local reads = 0
      local open = source.open
      source.open = function(id, limit) reads = reads + 1; return open(id, limit) end
      local model = require("neoagent.api." .. api).new({
        provider = "synthetic", model = "synthetic-vision", base_url = "https://synthetic.example/v1",
        input = { "text", "image" },
      })
      local plan = model:_request({ messages = messages, files = source })
      assert.are.equal(0, reads)
      assert.is_nil(plan.request.body.input)
      assert.is_nil(plan.request.body.messages)
      local body = plan.encode(images.inline(plan.api, source))
      assert.are.equal(1, reads)
      local wire = util.json_encode(body)
      assert.is_not_nil((wire:find(vim.base64.encode("\0synthetic image\255"), 1, true)))
      assert.is_nil((wire:find(file.file_id, 1, true)))
      assert.same(before, messages)
      assert.same(before, plan.messages)
    end)

    async_test("shapes semantic messages before encoding " .. api, function()
      local source = memory.new()
      local file = assert(source.put("synthetic image"))
      local model = require("neoagent.api." .. api).new({
        provider = "synthetic", model = "synthetic-vision", base_url = "https://synthetic.example/v1",
        input = { "text", "image" },
      })
      local shapes = 0
      local plan = model:_request({ files = source, messages = { { role = "user", content = {
        { type = "image", file_id = file.file_id, bytes = file.bytes, mime_type = "image/png" },
      } } }, request_opts = function(context)
        shapes = shapes + 1
        assert.are.equal(file.file_id, context.messages[1].content[1].file_id)
        return { messages = { { role = "user", content = "replacement" } }, body = { temperature = 0.1 } }
      end })
      source.open = function() error("removed attachment must not be opened") end
      local first = plan.encode(images.inline(plan.api, source))
      local second = plan.encode(images.inline(plan.api, source))
      assert.same(first, second)
      assert.are.equal(1, shapes)
      assert.are.equal(0.1, first.temperature)
      assert.is_not_nil((util.json_encode(first):find("replacement", 1, true)))
      for _, field in ipairs({ "messages", "input" }) do
        assert.has_error(function()
          model:_request({ messages = {}, request_opts = { body = { [field] = {} } } })
        end)
      end
      assert.has_error(function()
        model:_request({messages = {}, request_opts = function()
          return vim.json.decode('{"messages":{"role":"user","content":"not a message list"}}')
        end})
      end)
    end)
  end
end)
