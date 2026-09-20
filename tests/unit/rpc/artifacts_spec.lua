local assert = require("luassert")
local artifacts = require("neoagent.rpc.artifacts")
local async = require("neoagent.async")
local digest = require("neoagent.files.digest")
local limits = require("neoagent.rpc.tool_limits")

---@generic T
---@param fn async fun(): T
---@return T
local function run(fn)
  local active = async.run(fn)
  assert(vim.wait(30000, function()
    return active:is_done()
  end), "artifact operation did not settle")
  local result = assert(active:result())
  if result.ok == false then
    error(result.error, 0)
  end
  return result
end

---@param put? async fun(data: string): Neoagent.LocalFile?, Neoagent.Error?
---@return Neoagent.ToolOperationCall
local function call(put)
  return {
    workspace = { root = "/workspace", cwd = "/workspace" },
    artifacts = {
      put = put or
      ---@async
      function(data)
        return { file_id = digest.sha256(data), bytes = #data }
      end,
    },
    on_update = function() end,
  }
end

describe("neoagent Tool RPC artifacts", function()
  it("chunks, verifies, and publishes bytes before image references", function()
    local events = {}
    local data = string.rep("a", limits.MAX_ARTIFACT_CHUNK_BYTES) .. "tail\0\255"
    local publisher = artifacts.publisher(function(message)
      events[#events + 1] = message
    end)
    local local_file = run(function()
      local published_file = publisher.put(data)
      local value = assert(published_file)
      return value
    end)
    local expected_id = run(function()
      return digest.sha256(data)
    end)
    assert.are.equal(expected_id, local_file.file_id)
    assert.are.same({ "artifact_begin", "artifact_chunk", "artifact_chunk", "artifact_end" },
      vim.tbl_map(function(message)
        return message.type
      end, events))

    local published
    local importer = artifacts.importer(call(
      ---@async
      function(value)
      published = value
      return { file_id = digest.sha256(value), bytes = #value }
      end))
    run(function()
      for _, event in ipairs(events) do
        importer:accept(event)
      end
      importer:check_result({
        content = { {
          type = "image",
          file_id = local_file.file_id,
          bytes = local_file.bytes,
          mime_type = "image/png",
        } },
      })
    end)
    assert.are.equal(data, published)
  end)

  it("requires an attachment writer only when an artifact is published", function()
    local importer = artifacts.importer({
      workspace = { root = "/workspace", cwd = "/workspace" },
      on_update = function() end,
    })
    importer:check_result({ content = { { type = "text", text = "ordinary result" } } })
    local data = "artifact"
    local id = run(function()
      return digest.sha256(data)
    end)
    local ok, err = pcall(function()
      run(function()
        importer:accept({
          type = "artifact_begin",
          artifact_id = 1,
          file_id = id,
          bytes = #data,
        })
        importer:accept({ type = "artifact_chunk", artifact_id = 1, data = data })
        importer:accept({ type = "artifact_end", artifact_id = 1 })
      end)
    end)
    assert.is_false(ok)
    assert.are.equal(
      "Tool image result requires a writable attachment store",
      require("neoagent.util").normalize_error(err).message
    )
  end)

  it("rejects digest, publication identity, and incomplete ordering failures", function()
    local data = "artifact"
    local id = run(function()
      return digest.sha256(data)
    end)

    local digest_importer = artifacts.importer(call())
    local ok, err = pcall(function()
      run(function()
        digest_importer:accept({
          type = "artifact_begin",
          artifact_id = 1,
          file_id = id,
          bytes = #data,
        })
        digest_importer:accept({ type = "artifact_chunk", artifact_id = 1, data = "changed!" })
        digest_importer:accept({ type = "artifact_end", artifact_id = 1 })
      end)
    end)
    assert.is_false(ok)
    assert.matches("digest", require("neoagent.util").normalize_error(err, "artifact").message)

    local identity_importer = artifacts.importer(call(
      ---@async
      function(value)
      return { file_id = digest.sha256(value .. "changed"), bytes = #value }
      end))
    ok, err = pcall(function()
      run(function()
        identity_importer:accept({
          type = "artifact_begin",
          artifact_id = 1,
          file_id = id,
          bytes = #data,
        })
        identity_importer:accept({ type = "artifact_chunk", artifact_id = 1, data = data })
        identity_importer:accept({ type = "artifact_end", artifact_id = 1 })
      end)
    end)
    assert.is_false(ok)
    assert.matches("changed the artifact identity", require("neoagent.util").normalize_error(err, "artifact").message)

    local incomplete = artifacts.importer(call())
    ok, err = pcall(function()
      run(function()
        incomplete:accept({
          type = "artifact_begin",
          artifact_id = 1,
          file_id = id,
          bytes = #data,
        })
        incomplete:check_result({ content = { { type = "text", text = "early" } } })
      end)
    end)
    assert.is_false(ok)
    assert.matches("before its artifacts completed", require("neoagent.util").normalize_error(err, "artifact").message)

    local out_of_order = artifacts.importer(call())
    ok, err = pcall(function()
      run(function()
        out_of_order:accept({
          type = "artifact_begin",
          artifact_id = 2,
          file_id = id,
          bytes = #data,
        })
      end)
    end)
    assert.is_false(ok)
    assert.matches("order is invalid", require("neoagent.util").normalize_error(err, "artifact").message)
  end)

  it("propagates parent publication failure and cancellation before references escape", function()
    local data = "publication"
    local id = run(function()
      return digest.sha256(data)
    end)
    local function events(importer)
      importer:accept({
        type = "artifact_begin",
        artifact_id = 1,
        file_id = id,
        bytes = #data,
      })
      importer:accept({ type = "artifact_chunk", artifact_id = 1, data = data })
      importer:accept({ type = "artifact_end", artifact_id = 1 })
    end

    local failed = artifacts.importer(call(function()
      return nil, require("neoagent.files").error("synthetic parent publication failure")
    end))
    local ok, err = pcall(function()
      run(function()
        events(failed)
      end)
    end)
    assert.is_false(ok)
    assert.matches("synthetic parent publication failure", require("neoagent.util").normalize_error(err).message)

    local publishing = false
    local cancelled = false
    local pending = artifacts.importer(call(
      ---@async
      function()
        publishing = true
        return async.await(function()
          return function()
            cancelled = true
          end
        end)
      end))
    local active = async.run(function()
      events(pending)
      return true
    end)
    assert(vim.wait(1000, function()
      return publishing
    end))
    active:cancel()
    assert(vim.wait(1000, function()
      return active:is_done()
    end))
    local result = assert(active:result())
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.is_true(cancelled)
    pending:discard()
    assert.has_error(function()
      pending:check_result({
        content = { { type = "image", file_id = id, bytes = #data, mime_type = "image/png" } },
      })
    end, "RPC result references an unimported artifact")
  end)

  it("enforces per-artifact, aggregate, identity, and chunk ordering bounds", function()
    local original_artifact = limits.MAX_ARTIFACT_BYTES
    local original_artifacts = limits.MAX_ARTIFACTS_BYTES
    limits.MAX_ARTIFACT_BYTES = 4
    limits.MAX_ARTIFACTS_BYTES = 6
    local ok, err = xpcall(function()
      local function fails(message, operation)
        local completed, failure = pcall(operation)
        assert.is_false(completed)
        assert.matches(message, require("neoagent.util").normalize_error(failure).message)
      end
      local publisher = artifacts.publisher(function() end)
      run(function()
        local empty, empty_err = publisher.put("")
        assert.is_nil(empty)
        assert.matches("byte limit", assert(empty_err).message)
        local large, large_err = publisher.put("12345")
        assert.is_nil(large)
        assert.matches("byte limit", assert(large_err).message)
        local stored = publisher.put("1234")
        assert.is_table(stored)
        local aggregate, aggregate_err = publisher.put("123")
        assert.is_nil(aggregate)
        assert.matches("aggregate", assert(aggregate_err).message)
      end)

      local first = "one"
      local first_id = run(function()
        return digest.sha256(first)
      end)
      local importer = artifacts.importer(call())
      run(function()
        importer:accept({ type = "artifact_begin", artifact_id = 1, file_id = first_id, bytes = #first })
        importer:accept({ type = "artifact_chunk", artifact_id = 1, data = first })
        importer:accept({ type = "artifact_end", artifact_id = 1 })
      end)
      fails("duplicate RPC artifact", function()
        run(function()
          importer:accept({ type = "artifact_begin", artifact_id = 2, file_id = first_id, bytes = #first })
        end)
      end)

      local aggregate = artifacts.importer(call())
      local aggregate_id = run(function()
        return digest.sha256("1234")
      end)
      local overflow_id = run(function()
        return digest.sha256("123")
      end)
      run(function()
        aggregate:accept({ type = "artifact_begin", artifact_id = 1, file_id = aggregate_id, bytes = 4 })
        aggregate:accept({ type = "artifact_chunk", artifact_id = 1, data = "1234" })
        aggregate:accept({ type = "artifact_end", artifact_id = 1 })
      end)
      fails("RPC artifacts exceed the aggregate byte limit", function()
        run(function()
          aggregate:accept({ type = "artifact_begin", artifact_id = 2, file_id = overflow_id, bytes = 3 })
        end)
      end)

      local unordered = artifacts.importer(call())
      fails("RPC artifact event has no active artifact", function()
        run(function()
          unordered:accept({ type = "artifact_chunk", artifact_id = 1, data = "x" })
        end)
      end)

      local excess = artifacts.importer(call())
      fails("RPC artifact contains excess bytes", function()
        run(function()
          excess:accept({ type = "artifact_begin", artifact_id = 1, file_id = first_id, bytes = 2 })
          excess:accept({ type = "artifact_chunk", artifact_id = 1, data = "123" })
        end)
      end)

      local incomplete = artifacts.importer(call())
      fails("RPC artifact is incomplete", function()
        run(function()
          incomplete:accept({ type = "artifact_begin", artifact_id = 1, file_id = first_id, bytes = 3 })
          incomplete:accept({ type = "artifact_chunk", artifact_id = 1, data = "12" })
          incomplete:accept({ type = "artifact_end", artifact_id = 1 })
        end)
      end)
    end, function(value)
      return debug.traceback(vim.inspect(value), 2)
    end)
    limits.MAX_ARTIFACT_BYTES = original_artifact
    limits.MAX_ARTIFACTS_BYTES = original_artifacts
    if not ok then
      error(err, 0)
    end
  end)
end)
