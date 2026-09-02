local settings_module = require("neoagent.workspace_settings")

describe("neoagent workspace settings", function()
  local paths = {}

  after_each(function()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  it("uses one readable canonical directory for Workspace state", function()
    local parent = vim.fn.tempname()
    local root = parent .. "/readable-workspace"
    local directory = vim.fn.tempname()
    paths = { parent, directory }
    assert.are.equal(1, vim.fn.mkdir(root, "p"))
    root = assert(vim.uv.fs_realpath(root))
    local expected = directory .. "/readable-workspace-"
      .. vim.fn.sha256(root)

    local settings = settings_module.new({
      directory = directory,
      root = root,
    })
    local history = require("neoagent.input_history").new({
      directory = directory,
      root = root,
    })
    assert.are.equal(expected, settings.directory)
    assert.are.equal(expected, history.directory)

    if jit.os ~= "Windows" then
      local filesystem_root = settings_module.new({
        directory = directory,
        root = "/",
      })
      assert.are.equal(directory .. "/root-" .. vim.fn.sha256("/"),
        filesystem_root.directory)
    end
  end)

  it("recursively merges and atomically persists cwd-scoped overrides", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local settings = settings_module.new({ directory = directory, root = root })
    local metadata = settings:metadata()
    assert.are.equal(vim.uv.fs_realpath(root), metadata.root)
    assert.are.equal(directory .. "/" .. vim.fs.basename(metadata.root)
      .. "-" .. vim.fn.sha256(metadata.root), metadata.directory)
    assert.are.equal(metadata.directory .. "/settings.json", metadata.settings_path)
    assert.are.equal(metadata.directory .. "/sessions", metadata.sessions_directory)

    local merged, overrides = assert(settings:merge({ nested = { first = true }, value = "base" }))
    assert.are.same({}, overrides)
    assert.are.same({ nested = { first = true }, value = "base" }, merged)
    assert.is_nil(vim.uv.fs_stat(directory))

    assert(settings:write({ nested = { second = true }, value = "local" }))
    local updated = assert(settings:update({ nested = { third = true } }))
    assert.are.same({ nested = { second = true, third = true }, value = "local" }, updated)
    assert.are.same(updated, assert(settings:load()))
    local bit = require("bit")
    assert.are.equal(448, bit.band(vim.uv.fs_stat(metadata.directory).mode, 511))
    assert.are.equal(384, bit.band(vim.uv.fs_stat(metadata.settings_path).mode, 511))
  end)

  it("merges updates serialized with a concurrent writer", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local settings = settings_module.new({ directory = directory, root = root })
    assert(settings:write({ first = true }))
    local lock_path = settings.settings_path .. ".lock"
    local holder = assert(require("neoagent.file_lock").new({
      path = lock_path,
    }):acquire())

    local concurrent_done, concurrent_err
    vim.defer_fn(function()
      local written, write_err = require("neoagent.fs").write_all(
        settings.settings_path, vim.json.encode({ first = true, concurrent = true }) .. "\n")
      local released, release_err = holder:release()
      concurrent_err = write_err or release_err
      concurrent_done = written and released
    end, 20)

    local updated = assert(settings:update({ local_update = true }))
    assert(vim.wait(1000, function() return concurrent_done or concurrent_err ~= nil end, 5))
    assert.is_nil(concurrent_err)
    assert.are.same({ first = true, concurrent = true, local_update = true }, updated)
    assert.are.same(updated, assert(settings:load()))
  end)

  it("deletes tombstoned settings and prunes empty Agent scopes", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local settings = settings_module.new({ directory = directory, root = root })
    assert(settings:write({ agents = {
      Neo = {
        default_model = { provider = "fake", model = "thinking" },
        default_thinking_level = "high",
      },
      Chat = { default_thinking_level = "low" },
    } }))

    local updated = assert(settings:update({ agents = { Neo = {
      default_thinking_level = vim.NIL,
    } } }))
    assert.is_nil(updated.agents.Neo.default_thinking_level)
    assert.are.same({ provider = "fake", model = "thinking" },
      updated.agents.Neo.default_model)
    assert.are.equal("low", updated.agents.Chat.default_thinking_level)

    updated = assert(settings:update({ agents = {
      Neo = { default_model = vim.NIL },
      Chat = vim.NIL,
    } }))
    assert.is_nil(updated.agents)
    local encoded = assert(require("neoagent.fs").read(settings.settings_path))
    assert.is_nil(encoded:find("null", 1, true))
  end)

  it("reports malformed and non-object settings", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local settings = settings_module.new({ directory = directory, root = root })
    vim.fn.mkdir(settings.directory, "p")
    vim.fn.writefile({ "[]" }, settings.settings_path)
    local value, err = settings:load()
    assert.is_nil(value)
    assert.are.equal("settings", err.kind)
    assert.matches("object", err.detail)
    vim.fn.writefile({ "{" }, settings.settings_path)
    value, err = settings:merge({})
    assert.is_nil(value)
    assert.matches("Invalid", err.message)
    value, err = settings:write({ callback = function() end })
    assert.is_nil(value)
    assert.matches("encode", err.message)

    local original_random = vim.uv.random
    local random_calls = 0
    vim.uv.random = function(...)
      random_calls = random_calls + 1
      if random_calls == 2 then return nil, "random unavailable" end
      return original_random(...)
    end
    local called, written, write_err = pcall(
      settings.write, settings, { valid = true })
    vim.uv.random = original_random
    assert(called)
    assert.is_nil(written)
    assert.matches("temporary file", write_err.message)

    local original_rename = vim.uv.fs_rename
    vim.uv.fs_rename = function() return nil, "denied" end
    called, written, write_err = pcall(
      settings.write, settings, { valid = true })
    vim.uv.fs_rename = original_rename
    assert(called)
    assert.is_nil(written)
    assert.matches("replace", write_err.message)

    vim.fn.delete(settings.settings_path)
    vim.fn.mkdir(settings.settings_path, "p")
    value, err = settings:load()
    assert.is_nil(value)
    assert.matches("read", err.message)

    vim.fn.delete(settings.settings_path, "rf")
    local original_open = vim.uv.fs_open
    vim.uv.fs_open = function(candidate, ...)
      if candidate == settings.settings_path .. ".lock" then
        return nil, "EACCES: denied"
      end
      return original_open(candidate, ...)
    end
    value, err = settings:update({ blocked = true })
    vim.uv.fs_open = original_open
    assert.is_nil(value)
    assert.matches("acquire workspace settings lock", err.message)
  end)
end)
