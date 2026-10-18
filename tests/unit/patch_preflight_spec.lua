local assert = require("luassert")
local it = require("tests.helpers.async_test")
local fs = require("neoagent.fs")
local patch = require("neoagent.tools.codex.apply_patch")
local semantic = require("neoagent.semantic_message")

-- Exercise real paths and publication, including aliases that string
-- normalization cannot distinguish.
describe("patch filesystem preflight", function()
  ---@type string
  local root

  before_each(function()
    root = vim.fn.tempname()
    assert(fs.mkdirp(root .. "/real"))
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  ---@async
  ---@param text string
  ---@param filesystem? Neoagent.ToolFilesystem
  ---@return Neoagent.ApplyPatchResult
  local function apply(text, filesystem)
    local call = { workspace = { root = root, cwd = root }, on_update = function() end }
    return patch.run(patch.prepare({ patch = text }, {}, call), call, { fs = filesystem or fs })
  end

  for _, move in ipairs({ false, true }) do
    it("retains completed " .. (move and "move" or "update") .. " effects when notification fails", function()
      local source, destination = root .. "/source", root .. "/destination"
      assert(fs.write_all(source, "before\n"))
      local call = {
        workspace = { root = root, cwd = root },
        on_update = function() end,
        on_file_changed = function()
          error("observer failed", 0)
        end,
      }
      local text = "*** Begin Patch\n*** Update File: source\n"
        .. (move and "*** Move to: destination\n" or "")
        .. "@@\n-before\n+after\n*** End Patch"
      local result = patch.run(patch.prepare({ patch = text }, {}, call), call, { fs = fs })
      assert.is_true(result.isError)
      local change = assert(result.details.changes[1])
      assert.are.equal(move and "partial" or "applied", change.status)
      assert.matches("observer failed", require("neoagent.util").text_content(result.content))
      assert.are.equal("after\n", fs.read(move and destination or source))
      assert.are.same({ move and destination or source }, result.details.changed_paths)
      if move then
        assert.are.equal("before\n", fs.read(source))
        local effects = assert(change.effects)
        assert.are.equal("applied", assert(effects[1]).status)
        assert.are.equal("pending", assert(effects[2]).status)
      end
    end)
  end

  it("returns changed paths as well as publication events", function()
    local observed = {}
    local call = {
      workspace = { root = root, cwd = root },
      on_update = function() end,
      on_file_changed = function(path)
        observed[#observed + 1] = path
      end,
    }
    local text = "*** Begin Patch\n*** Add File: created\n+contents\n*** End Patch"
    local result = patch.run(patch.prepare({ patch = text }, {}, call), call, { fs = fs })
    assert.is_nil(result.isError)
    assert.are.same({ root .. "/created" }, observed)
    assert.are.same(observed, result.details.changed_paths)
  end)

  for _, kind in ipairs({ "delete", "update", "move", "overwrite" }) do
    it("preserves an identical replacement made after " .. kind .. " preflight", function()
      local source = root .. "/source"
      assert(fs.write_all(source, "before\n"))
      local original = assert(vim.uv.fs_lstat(source)).ino
      local replacement
      local filesystem = require("neoagent.util").shallow_copy(fs)
      filesystem.path_key = function(path)
        local key = fs.path_key(path)
        -- The second visit is preflight. The scheduled edit runs at the
        -- publication yield, after the preimage has been captured.
        if path == source then
          if replacement == nil then
            replacement = false
          elseif replacement == false then
            replacement = true
            vim.schedule(function()
              assert(fs.write_all(root .. "/replacement", "before\n"))
              assert.are_not.equal(original, assert(vim.uv.fs_lstat(root .. "/replacement")).ino)
              assert(vim.uv.fs_rename(root .. "/replacement", source))
            end)
          end
        end
        return key
      end
      local operation = kind == "delete" and "*** Delete File: source"
        or kind == "overwrite" and "*** Add File: source\n+after"
        or "*** Update File: source\n"
          .. (kind == "move" and "*** Move to: destination\n" or "")
          .. "@@\n-before\n+after"
      local result = apply("*** Begin Patch\n" .. operation .. "\n*** End Patch", filesystem)
      assert.is_true(result.isError)
      assert.are.equal("before\n", fs.read(source))
      assert.is_nil(vim.uv.fs_lstat(root .. "/destination"))
      assert.are.equal("failed", assert(result.details.changes[1]).status)
    end)
  end

  it("rejects a source mode change before publishing a move", function()
    if jit.os == "Windows" then
      return
    end
    local source = root .. "/source"
    assert(fs.write_all(source, "before\n"))
    assert(vim.uv.fs_chmod(source, 420))
    local filesystem = require("neoagent.util").shallow_copy(fs)
    local visits = 0
    filesystem.path_key = function(path)
      if path == source then
        visits = visits + 1
        if visits == 2 then
          vim.schedule(function()
            assert(vim.uv.fs_chmod(source, 384))
          end)
        end
      end
      return fs.path_key(path)
    end
    local result = apply(
      "*** Begin Patch\n*** Update File: source\n*** Move to: destination\n*** End Patch",
      filesystem
    )
    assert.is_true(result.isError)
    assert.are.equal("before\n", fs.read(source))
    assert.are.equal(384, require("bit").band(assert(vim.uv.fs_lstat(source)).mode, 511))
    assert.is_nil(vim.uv.fs_lstat(root .. "/destination"))
  end)

  it("reports a partial move when an identical source replacement follows destination publication", function()
    local source = root .. "/source"
    assert(fs.write_all(source, "before\n"))
    local filesystem = require("neoagent.util").shallow_copy(fs)
    filesystem.atomic_replace = function(path, content, policy)
      local written, err, stage = fs.atomic_replace(path, content, policy)
      if written then
        assert(fs.write_all(root .. "/replacement", "before\n"))
        assert(vim.uv.fs_rename(root .. "/replacement", source))
      end
      return written, err, stage
    end
    local result = apply(
      "*** Begin Patch\n*** Update File: source\n*** Move to: destination\n@@\n-before\n+after\n*** End Patch",
      filesystem
    )
    assert.is_true(result.isError)
    assert.are.equal("before\n", fs.read(source))
    assert.are.equal("after\n", fs.read(root .. "/destination"))
    local changed = assert(result.details.changes[1])
    assert.are.equal("partial", changed.status)
    local effects = assert(changed.effects)
    assert.are.equal("applied", assert(effects[1]).status)
    assert.are.equal("failed", assert(effects[2]).status)
  end)

  it("returns transportable results for moves with redundant path components", function()
    local lines = { "*** Begin Patch" }
    local prefix = string.rep("./", 3000)
    for index = 1, 32 do
      assert(fs.write_all(root .. "/before" .. index, "before\n"))
      lines[#lines + 1] = "*** Update File: " .. prefix .. "before" .. index
      lines[#lines + 1] = "*** Move to: " .. prefix .. "after" .. index
      lines[#lines + 1] = "@@\n-before\n+after"
    end
    lines[#lines + 1] = "*** End Patch"
    local result = apply(table.concat(lines, "\n"))
    assert.is_nil(result.isError)
    local protocol = require("neoagent.rpc.protocol")
    assert(protocol.encode({
      type = "response",
      call_id = "patch",
      request_id = 1,
      value = require("neoagent.rpc.codec").result(result),
    }))
    assert.are.equal(32, #result.details.changes)
    for index = 1, 32 do
      assert.are.equal("after\n", fs.read(root .. "/after" .. index))
      assert.is_nil(vim.uv.fs_stat(root .. "/before" .. index))
      assert.are.equal("applied", assert(result.details.changes[index]).status)
    end
  end)

  it("bounds publication diagnostics while retaining authoritative partial effects", function()
    local filesystem = require("neoagent.util").shallow_copy(fs)
    filesystem.atomic_replace = function(path, content, policy)
      if path == root .. "/second" then
        return nil, string.rep("publication failed ", 100000)
      end
      return fs.atomic_replace(path, content, policy)
    end
    local result =
      apply("*** Begin Patch\n*** Add File: first\n+one\n*** Add File: second\n+two\n*** End Patch", filesystem)
    assert.is_true(result.isError)
    assert(require("neoagent.rpc.protocol").encode({
      type = "response",
      call_id = "patch",
      request_id = 1,
      value = require("neoagent.rpc.codec").result(result),
    }))
    assert.are.equal("one\n", fs.read(root .. "/first"))
    assert.is_nil(vim.uv.fs_stat(root .. "/second"))
    assert.are.equal("applied", assert(result.details.changes[1]).status)
    assert.are.equal("failed", assert(result.details.changes[2]).status)
    assert.matches("publication failed", assert(assert(result.details.changes[2]).error))
  end)

  it("rejects an untransportable complete result before filesystem publication", function()
    local lines = { "*** Begin Patch" }
    for index = 1, 128 do
      lines[#lines + 1] = "*** Add File: " .. string.rep("directory/", 300) .. index
      lines[#lines + 1] = "+content"
    end
    lines[#lines + 1] = "*** End Patch"
    local filesystem = require("neoagent.util").shallow_copy(fs)
    filesystem.path_key = function(path)
      return path
    end
    filesystem.preflight = function()
      return { content = "", mode = 420, observation = { exists = false } }
    end
    local effects = 0
    filesystem.mkdirp = function()
      effects = effects + 1
      return true
    end
    filesystem.atomic_replace = function()
      effects = effects + 1
      return true
    end
    local ok, err = pcall(apply, table.concat(lines, "\n"), filesystem)
    assert.is_false(ok)
    assert.matches("Patch result exceeds the byte budget", tostring(err))
    assert.are.equal(0, effects)
  end)

  it("rejects moves to the same directory entry through a directory alias", function()
    if jit.os == "Windows" then
      return
    end
    assert(fs.write_all(root .. "/real/file", "original\n"))
    assert(vim.uv.fs_symlink(root .. "/real", root .. "/alias", { dir = true, junction = false }))
    local ok, failure =
      pcall(apply, "*** Begin Patch\n*** Update File: real/file\n*** Move to: alias/file\n*** End Patch")
    assert.is_false(ok)
    assert.matches("same filesystem path", tostring(failure))
    assert.are.equal("original\n", fs.read(root .. "/real/file"))
  end)

  it("rejects aliased additions before publishing any file", function()
    if jit.os == "Windows" then
      return
    end
    assert(vim.uv.fs_symlink(root .. "/real", root .. "/alias", { dir = true, junction = false }))
    local ok = pcall(
      apply,
      table.concat({
        "*** Begin Patch",
        "*** Add File: earlier",
        "+untouched",
        "*** Add File: real/new/file",
        "+one",
        "*** Add File: alias/new/file",
        "+two",
        "*** End Patch",
      }, "\n")
    )
    assert.is_false(ok)
    assert.is_nil(vim.uv.fs_stat(root .. "/earlier"))
    assert.is_nil(vim.uv.fs_stat(root .. "/real/new/file"))
  end)

  it("rejects a parent alias retargeted between preparation and publication", function()
    if jit.os == "Windows" then
      return
    end
    assert(fs.mkdirp(root .. "/other"))
    assert(fs.write_all(root .. "/real/file", "source\n"))
    assert(fs.write_all(root .. "/other/file", "destination\n"))
    assert(vim.uv.fs_symlink(root .. "/other", root .. "/alias", { dir = true, junction = false }))
    local filesystem = require("neoagent.util").shallow_copy(fs)
    filesystem.preflight = function(path, policy, maximum)
      local data, err = fs.preflight(path, policy, maximum)
      if path == root .. "/alias/file" then
        vim.schedule(function()
          assert(vim.uv.fs_unlink(root .. "/alias"))
          assert(vim.uv.fs_symlink(root .. "/real", root .. "/alias", { dir = true, junction = false }))
        end)
      end
      return data, err
    end
    local result =
      apply("*** Begin Patch\n*** Update File: real/file\n*** Move to: alias/file\n*** End Patch", filesystem)
    assert.is_true(result.isError)
    assert.are.equal("source\n", fs.read(root .. "/real/file"))
    assert.are.equal("destination\n", fs.read(root .. "/other/file"))
    assert(semantic.normalize_tool_result(result))
  end)

  it("allows distinct hard-linked directory entries to be moved", function()
    assert(fs.write_all(root .. "/real/source", "original\n"))
    assert(vim.uv.fs_link(root .. "/real/source", root .. "/real/destination"))
    local result = apply("*** Begin Patch\n*** Update File: real/source\n*** Move to: real/destination\n*** End Patch")
    assert.is_nil(result.isError)
    assert.is_nil(vim.uv.fs_stat(root .. "/real/source"))
    assert.are.equal("original\n", fs.read(root .. "/real/destination"))
  end)

  for _, kind in ipairs({ "delete", "overwrite", "move" }) do
    it("reports a non-UTF-8 preimage safely during " .. kind, function()
      assert(fs.write_all(root .. "/binary", string.char(255) .. "\n"))
      assert(fs.write_all(root .. "/source", "replacement\n"))
      local operation = kind == "delete" and "*** Delete File: binary"
        or kind == "overwrite" and "*** Add File: binary\n+replacement"
        or "*** Update File: source\n*** Move to: binary"
      local result = apply("*** Begin Patch\n" .. operation .. "\n*** End Patch")
      local normalized, err = semantic.normalize_tool_result(result)
      assert(normalized, err)
      assert.is_nil(result.isError)
      assert.matches("\\xFF", assert(result.details.changes[1]).patch)
      if kind == "delete" then
        assert.is_nil(vim.uv.fs_stat(root .. "/binary"))
      else
        assert.are.equal("replacement\n", fs.read(root .. "/binary"))
      end
    end)
  end

  it("retains logical move identity and destination replacement effects", function()
    assert(fs.write_all(root .. "/source", "source\n"))
    assert(fs.write_all(root .. "/destination", "overwritten\n"))
    local result = apply("*** Begin Patch\n*** Update File: source\n*** Move to: destination\n*** End Patch")
    local changes = result.details.changes
    assert.are.equal(1, #changes)
    local moved = changes[1]
    assert(moved)
    assert.are.equal("source", moved.path)
    assert.are.equal("destination", moved.destination)
    assert.are.equal("applied", moved.status)
    assert.matches("overwritten", moved.patch)
    local effects = moved.effects
    assert(effects)
    assert.are.equal(2, #effects)
    assert.are.equal("applied", assert(effects[1]).status)
    assert.are.equal("applied", assert(effects[2]).status)
  end)

  it("retains a pending move's diff when an earlier publication fails", function()
    assert(fs.write_all(root .. "/source", "source\n"))
    local filesystem = require("neoagent.util").shallow_copy(fs)
    filesystem.atomic_replace = function()
      return nil, "publication unavailable"
    end
    local result = apply(
      table.concat({
        "*** Begin Patch",
        "*** Add File: earlier",
        "+new",
        "*** Update File: source",
        "*** Move to: destination",
        "*** End Patch",
      }, "\n"),
      filesystem
    )
    assert.is_true(result.isError)
    local moved = assert(result.details.changes[2])
    assert.are.equal("pending", moved.status)
    assert.are.equal("destination", moved.destination)
    assert.matches("source", moved.patch)
    assert.are.equal(1, moved.added)
    assert.are.equal(1, moved.removed)
    assert.are.equal("source\n", fs.read(root .. "/source"))
    assert.is_nil(vim.uv.fs_stat(root .. "/destination"))
  end)
end)
