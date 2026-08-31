local fs = require("neoagent.fs")
local profile_sessions = require("neoagent.profile_sessions")
local storage = require("neoagent.storage")
local original_write_all = fs.write_all

local function tempdir()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return assert(vim.uv.fs_realpath(path))
end

describe("neoagent.profile_sessions", function()
  local directories = {}

  after_each(function()
    fs.write_all = original_write_all
    for _, path in ipairs(directories) do vim.fn.delete(path, "rf") end
    directories = {}
  end)

  local function directory()
    local path = tempdir()
    directories[#directories + 1] = path
    return path
  end

  it("binds persisted Sessions to an immutable Profile header", function()
    local root = directory()
    local session = assert(profile_sessions.new({
      profile_id = "neo",
      workspace = root,
      persistence = { enabled = true, directory = root },
      metadata = {
        foreign = { retained = true },
        neoagent = { extension = "retained" },
      },
    }))

    assert.are.equal("neo", assert(profile_sessions.binding(session)))
    assert.is_nil(vim.uv.fs_stat(session:metadata().path))
    assert(session:append({ role = "user", content = "persist me", timestamp = 1 }))

    local header = vim.json.decode(assert(fs.read(
      session:metadata().path)):match("([^\n]+)"))
    assert.are.equal(3, header.version)
    assert.are.equal("neo", header.metadata.neoagent.profileId)
    assert.are.equal("retained", header.metadata.neoagent.extension)
    assert.is_true(header.metadata.foreign.retained)

    local opened = assert(profile_sessions.open(session:metadata().path))
    assert.are.equal("neo", opened.profile_id)
    assert.are.equal(session:id(), opened.session:id())
    assert.are.equal(root, opened.workspace)

    local index_path = fs.join(vim.fs.dirname(
      vim.fs.dirname(session:metadata().path)), "session-index.json")
    assert(vim.uv.fs_unlink(index_path))
    local listed = profile_sessions.list({
      enabled = true,
      directory = root,
    }, root)
    assert.are.equal(1, #listed)
    assert.are.equal("neo", listed[1].profile_id)
    local index_data = assert(fs.read(index_path))
    local rebuilt = vim.json.decode(index_data)
    local indexed = rebuilt.sessions[vim.fs.basename(session:metadata().path)]
    assert.are.equal("neo", indexed.attributes.profileId)
  end)

  it("rejects Profile-free and malformed bindings", function()
    local root = directory()
    local unassigned = storage.new({ directory = root, cwd = root })
    assert(unassigned:append({
      role = "user", content = "unassigned", timestamp = 1,
    }))

    local opened, open_err = profile_sessions.open(unassigned:metadata().path)
    assert.is_nil(opened)
    assert.are.equal("profile", open_err.kind)
    assert.matches("no assigned Profile", open_err.message)

    local malformed = storage.new({
      directory = root,
      cwd = root,
      metadata = { neoagent = { profileId = 42 } },
    })
    assert(malformed:append({ role = "user", content = "bad", timestamp = 2 }))
    local rejected, err = profile_sessions.open(malformed:metadata().path)
    assert.is_nil(rejected)
    assert.are.equal("profile", err.kind)
    assert.matches("profileId", err.message)
  end)

  it("validates Profile metadata and derivation boundaries", function()
    local invalid = {
      { value = false, message = "metadata must be an object" },
      { value = { neoagent = {} }, message = "no assigned Profile" },
      { value = { neoagent = false },
        message = "metadata.neoagent must be an object" },
      { value = { neoagent = { profileId = "neo", derivation = false } },
        message = "derivation must be an object" },
      { value = { neoagent = { profileId = "neo", derivation = {
        kind = "fork", sourceSessionId = "source",
      } } }, message = "kind must be copy" },
      { value = { neoagent = { profileId = "neo", derivation = {
        kind = "copy", sourceSessionId = "",
      } } }, message = "sourceSessionId must be a non%-empty string" },
      { value = { neoagent = { profileId = "neo", derivation = {
        kind = "copy", sourceSessionId = "source", sourceProfileId = 42,
      } } }, message = "sourceProfileId must be a non%-empty string" },
    }
    for _, case in ipairs(invalid) do
      local inspected, err = profile_sessions.inspect(case.value)
      assert.is_nil(inspected)
      assert.matches(case.message, err.message)
    end
    local inspected, inspect_err = profile_sessions.inspect(nil)
    assert.is_nil(inspected)
    assert.matches("no assigned Profile", inspect_err.message)

    local rejected, rejected_err = profile_sessions.new({
      profile_id = "neo",
      workspace = directory(),
      metadata = false,
    })
    assert.is_nil(rejected)
    assert.matches("metadata must be an object", rejected_err.message)
    rejected, rejected_err = profile_sessions.new({
      profile_id = "neo",
      workspace = directory(),
      metadata = { neoagent = false },
    })
    assert.is_nil(rejected)
    assert.matches("metadata.neoagent must be an object", rejected_err.message)

    local root = directory()
    local source = assert(profile_sessions.new({
      profile_id = "neo",
      workspace = root,
      persistence = { enabled = false },
    }))
    local _, _, user = source:append({
      role = "user", content = "question", timestamp = 1,
    })
    local _, _, assistant = source:append({
      role = "assistant", content = "answer", timestamp = 2,
    })
    local derived, err = profile_sessions.derive(source, {
      kind = "invalid",
      target_profile_id = "neo",
      workspace = root,
    })
    assert.is_nil(derived)
    assert.matches("kind must be copy or fork", err.message)
    derived, err = profile_sessions.derive(source, {
      kind = "copy",
      source_profile_id = "chat",
      target_profile_id = "neo",
      workspace = root,
    })
    assert.is_nil(derived)
    assert.matches("does not match", err.message)

    local cases = {
      { entry_id = "missing", detail = "entry not found" },
      { entry_id = assistant.id, position = "before",
        detail = "requires a user message" },
      { entry_id = user.id, position = "invalid",
        detail = "position must be before or at" },
    }
    for _, case in ipairs(cases) do
      derived, err = profile_sessions.derive(source, {
        kind = "fork",
        source_profile_id = "neo",
        target_profile_id = "neo",
        workspace = root,
        entry_id = case.entry_id,
        position = case.position,
      })
      assert.is_nil(derived)
      assert.matches(case.detail, err.detail)
    end

    local unrooted = assert(require("neoagent.session").new({
      metadata = { neoagent = { profileId = "neo" } },
    }))
    derived, err = profile_sessions.derive(unrooted, {
      kind = "copy",
      target_profile_id = "neo",
    })
    assert.is_nil(derived)
    assert.matches("no Workspace", err.message)

    local invalid_path = {
      id = function() return "invalid-path" end,
      snapshot = function() return {
        entries = {},
        workspace = root,
        metadata = { neoagent = { profileId = "neo" } },
      } end,
      metadata = function() return {
        data = { neoagent = { profileId = "neo" } },
      } end,
      entry = function() return {
        id = "broken",
        type = "message",
        message = { role = "user", content = "broken" },
      } end,
      path = function() return { { type = "invalid" } } end,
    }
    derived, err = profile_sessions.derive(invalid_path, {
      kind = "fork",
      target_profile_id = "neo",
      entry_id = "broken",
      position = "at",
    })
    assert.is_nil(derived)
    assert.matches("Cannot fork Session", err.message)
  end)

  it("copies a complete tree without mutating its source", function()
    local root = directory()
    local source = assert(profile_sessions.new({
      profile_id = "neo",
      workspace = root,
      persistence = { enabled = true, directory = root },
      metadata = { foreign = "preserved" },
    }))
    local _, _, first = source:append({
      role = "user", content = "question", timestamp = 1,
    }, {
      model = { provider = "fake", model = "source" },
      thinking_level = "high",
    })
    local _, _, left = source:append({
      role = "assistant", content = "left", timestamp = 2,
    })
    assert(source:move_to(first.id))
    assert(source:append({
      role = "assistant", content = "right", timestamp = 3,
    }))
    assert(source:move_to(left.id))
    local before = source:snapshot()

    local copy = assert(profile_sessions.derive(source, {
      kind = "copy",
      source_profile_id = "neo",
      target_profile_id = "chat",
      workspace = root,
      persistence = { enabled = true, directory = root },
    }))

    assert.are_not.equal(source:id(), copy:id())
    assert.are.same(before.entries, copy:entries())
    assert.are.equal(before.leaf_id, copy:leaf_id())
    assert.are.same(before, source:snapshot())
    assert.are.equal("chat", assert(profile_sessions.binding(copy)))
    local metadata = copy:metadata().data
    assert.are.equal("preserved", metadata.foreign)
    assert.are.same({
      kind = "copy",
      sourceSessionId = source:id(),
      sourceProfileId = "neo",
    }, metadata.neoagent.derivation)
    assert.are.equal("source", copy:state().model.model)

    local reopened = assert(profile_sessions.open(copy:metadata().path))
    assert.are.same(copy:entries(), reopened.session:entries())
    assert.are.equal(copy:leaf_id(), reopened.session:leaf_id())
  end)

  it("derives between persisted and in-memory Session compositions", function()
    local root = directory()
    local source = assert(profile_sessions.new({
      profile_id = "neo",
      workspace = root,
      persistence = { enabled = false },
    }))
    local _, _, first = source:append({
      role = "user", content = "first", timestamp = 1,
    })
    assert(source:append({
      role = "assistant", content = "answer", timestamp = 2,
    }))

    local fork = assert(profile_sessions.derive(source, {
      kind = "fork",
      source_profile_id = "neo",
      target_profile_id = "neo",
      workspace = root,
      entry_id = first.id,
      position = "before",
      persistence = { enabled = false },
    }))
    assert.are.same({}, fork:messages())
    assert.are.equal("neo", assert(profile_sessions.binding(fork)))
    assert.is_false(fork:metadata().persisted)

    local persisted = assert(profile_sessions.derive(source, {
      kind = "copy",
      source_profile_id = "neo",
      target_profile_id = "neo",
      workspace = root,
      persistence = { enabled = true, directory = root },
    }))
    assert.is_not_nil(vim.uv.fs_stat(persisted:metadata().path))
    assert.are.same(source:entries(), persisted:entries())
  end)

  it("publishes a persisted derivation only after its complete tree is written", function()
    local root = directory()
    local source = assert(profile_sessions.new({
      profile_id = "neo",
      workspace = root,
      persistence = { enabled = false },
    }))
    assert(source:append({ role = "user", content = "source", timestamp = 1 }))
    local before = assert(source:snapshot())
    fs.write_all = function(target, ...)
      if target:find(".jsonl.", 1, true)
          and target:sub(-4) == ".tmp" then
        return nil, "blocked derived document"
      end
      return original_write_all(target, ...)
    end

    local derived, err = profile_sessions.derive(source, {
      kind = "copy",
      source_profile_id = "neo",
      target_profile_id = "chat",
      workspace = root,
      persistence = { enabled = true, directory = root },
    })

    assert.is_nil(derived)
    assert.are.equal("storage", err.kind)
    assert.matches("blocked derived document", err.detail)
    assert.are.same(before, source:snapshot())
    assert.are.same({}, storage.list(root, root))
  end)
end)
