local it = require("tests.helpers.async_test")
local assert = require("luassert")
local fs = require("neoagent.fs")
local profile_sessions = require("neoagent.profile_sessions")
local storage = require("neoagent.storage")
local original_atomic_replace = fs.atomic_replace

---@return string
local function tempdir()
  local path = vim.fn.tempname()
  assert.are.equal(1, vim.fn.mkdir(path, "p"))
  return (assert(vim.uv.fs_realpath(path)))
end

describe("neoagent.profile_sessions", function()
  ---@type string[]
  local directories = {}

  after_each(function()
    fs.atomic_replace = original_atomic_replace
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
    assert.is_nil(vim.uv.fs_stat((assert(assert(session:metadata()).path))))
    assert(session:append({ role = "user", content = "persist me", timestamp = 1 }))

    local document = assert(fs.read((assert(assert(session:metadata()).path))))
    local header = vim.json.decode((assert(document:match("([^\n]+)"))))
    assert.are.equal("neoagent-session", header.format)
    assert.are.equal("neo", header.metadata.neoagent.profileId)
    assert.are.equal("retained", header.metadata.neoagent.extension)
    assert.is_true(header.metadata.foreign.retained)

    local opened = assert(profile_sessions.open((assert(assert(session:metadata()).path))))
    assert.are.equal("neo", opened.profile_id)
    assert.are.equal(session:id(), opened.session:id())
    assert.are.equal(root, opened.workspace)

    local index_path = fs.join(vim.fs.dirname(
      vim.fs.dirname((assert(assert(session:metadata()).path)))), "session-index.json")
    assert(vim.uv.fs_unlink(index_path))
    local listed = profile_sessions.list({
      enabled = true,
      directory = root,
    }, root)
    assert.are.equal(1, #listed)
    assert.are.equal("neo", assert(listed[1]).profile_id)
    local index_data = assert(fs.read(index_path))
    local rebuilt = vim.json.decode(index_data)
    local indexed = rebuilt.sessions[vim.fs.basename((assert(assert(session:metadata()).path)))]
    assert.are.equal("neo", indexed.attributes.profileId)
  end)

  it("imports independent attachment stores when copying between in-memory workspaces", function()
    local first, second = directory(), directory()
    local source = assert(profile_sessions.new({ profile_id = "neo", workspace = first,
      persistence = { enabled = false } }))
    local image = require("tests.helpers.attachments").new(source:files()).image("synthetic image")
    assert(source:append({ role = "user", content = { image } }))
    local copied = assert(profile_sessions.derive(source, { kind = "copy", source_profile_id = "neo",
      target_profile_id = "chat", workspace = second, persistence = { enabled = false } }))
    assert.are_not.equal(source:files().identity, copied:files().identity)
    assert.are.same(source:entries(), copied:entries())
    assert.are.equal("synthetic image", require("tests.helpers.attachments").new(copied:files()).read(image))
    assert.is_nil(copied:file_cache())
    assert.are.same({}, vim.fn.readdir(second))
    source:files().open = function() return nil, require("neoagent.files").error("synthetic source missing") end
    local failed, err = profile_sessions.derive(source, { kind = "copy", source_profile_id = "neo",
      target_profile_id = "chat", workspace = second, persistence = { enabled = false } })
    assert.is_nil(failed)
    assert.matches("source missing", assert(err).message)
  end)

  it("reports malformed cached Profile attributes as listing errors", function()
    local root = directory()
    local persistence = { enabled = true, directory = root }
    local session = assert(profile_sessions.new({
      profile_id = "neo", workspace = root, persistence = persistence,
    }))
    assert(session:append({ role = "user", content = "saved" }))
    local path = assert(assert(session:metadata()).path)
    local index_path = fs.join(vim.fs.dirname(vim.fs.dirname(path)),
      "session-index.json")
    local data = assert(fs.read(index_path))
    local index = vim.json.decode(data)
    for _, attributes in ipairs({
      { profileId = 42 }, { profileId = "" }, { profileId = vim.NIL },
      { profileError = false }, { profileError = {} }, { profileError = "" },
    }) do
      index.sessions[vim.fs.basename(path)].attributes = attributes
      assert((fs.write_all(index_path, vim.json.encode(index))))
      local listed = profile_sessions.list(persistence, root)
      assert.are.equal(1, #listed)
      assert.is_nil(assert(listed[1]).profile_id)
      assert.are.equal("string", type(assert(listed[1]).profile_error))
      assert.matches("Invalid cached Session Profile", (assert(assert(listed[1]).profile_error)))
    end
  end)

  it("rejects Profile-free and malformed bindings", function()
    local root = directory()
    local unassigned = storage.new({ directory = root, cwd = root })
    assert(unassigned:append({
      role = "user", content = "unassigned", timestamp = 1,
    }))

    local opened, open_err = profile_sessions.open(unassigned:metadata().path)
    assert.is_nil(opened)
    assert.are.equal("profile", assert(open_err).kind)
    assert.matches("no assigned Profile", assert(open_err).message)

    local malformed = storage.new({
      directory = root,
      cwd = root,
      metadata = { neoagent = { profileId = 42 } },
    })
    assert(malformed:append({ role = "user", content = "bad", timestamp = 2 }))
    local rejected, err = profile_sessions.open(malformed:metadata().path)
    assert.is_nil(rejected)
    assert.are.equal("profile", assert(err).kind)
    assert.matches("profileId", assert(err).message)
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
      assert.matches(case.message, assert(err).message)
    end
    local inspected, inspect_err = profile_sessions.inspect(nil)
    assert.is_nil(inspected)
    assert.matches("no assigned Profile", assert(inspect_err).message)

    local rejected, rejected_err = profile_sessions.new({
      profile_id = "neo",
      workspace = directory(),
      metadata = false --[[@as Neoagent.JsonObject]],
    })
    assert.is_nil(rejected)
    assert.matches("metadata must be an object", assert(rejected_err).message)
    rejected, rejected_err = profile_sessions.new({
      profile_id = "neo",
      workspace = directory(),
      metadata = { neoagent = false },
    })
    assert.is_nil(rejected)
    assert.matches("metadata.neoagent must be an object", assert(rejected_err).message)

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
      role = "assistant", content = { { type = "text", text = "answer" } },
      timestamp = 2,
    })
    local derived, err = profile_sessions.derive(source, {
      kind = "invalid" --[[@as "copy"]],
      target_profile_id = "neo",
      workspace = root,
    })
    assert.is_nil(derived)
    assert.matches("kind must be copy or fork", assert(err).message)
    derived, err = profile_sessions.derive(source, {
      kind = "copy",
      source_profile_id = "chat",
      target_profile_id = "neo",
      workspace = root,
    })
    assert.is_nil(derived)
    assert.matches("does not match", assert(err).message)

    local cases = {
      { entry_id = "missing", detail = "entry not found" },
      { entry_id = assert(assistant).id, position = "before",
        detail = "requires a user message" },
      { entry_id = assert(user).id, position = "invalid",
        detail = "position must be before or at" },
    }
    for _, case in ipairs(cases) do
      derived, err = profile_sessions.derive(source, {
        kind = "fork",
        source_profile_id = "neo",
        target_profile_id = "neo",
        workspace = root,
        entry_id = case.entry_id,
        position = case.position --[[@as "before"|"at"?]],
      })
      assert.is_nil(derived)
      assert.matches(case.detail, tostring(assert(err).detail))
    end

    local unrooted = assert(require("neoagent.session").new({
      metadata = { neoagent = { profileId = "neo" } },
    }))
    derived, err = profile_sessions.derive(unrooted, {
      kind = "copy",
      target_profile_id = "neo",
    })
    assert.is_nil(derived)
    assert.matches("no Workspace", assert(err).message)

    local invalid_path = assert(require("neoagent.session").new({
      id = "invalid-path", workspace = root,
      metadata = { neoagent = { profileId = "neo" } },
      entries = { {
        id = "broken", type = "message", parent_id = vim.NIL,
        created_at = 1767225600000,
        message = { role = "user", content = "broken", timestamp = 1 },
      } },
    }))
    function invalid_path:path()
      local malformed = { { type = "invalid" } }
      return malformed --[[@as Neoagent.JournalEntry[] ]]
    end
    derived, err = profile_sessions.derive(invalid_path, {
      kind = "fork",
      target_profile_id = "neo",
      entry_id = "broken",
      position = "at",
    })
    assert.is_nil(derived)
    assert.matches("Cannot fork Session", assert(err).message)
  end)

  it("propagates Session and storage failures at Profile boundaries", function()
    local root = directory()
    local invalid, err = profile_sessions.new({
      profile_id = "",
      workspace = root,
      persistence = { enabled = false },
    })
    assert.is_nil(invalid)
    assert.matches("Profile id", assert(err).message)

    local opened
    opened, err = profile_sessions.open(fs.join(root, "missing", "session.jsonl"))
    assert.is_nil(opened)
    assert.are.equal("storage", assert(err).kind)

    local malformed = assert(require("neoagent.session").new({
      workspace = root,
      metadata = { neoagent = { profileId = 42 } },
    }))
    local binding
    binding, err = profile_sessions.binding(malformed)
    assert.is_nil(binding)
    assert.matches("profileId", assert(err).message)

    local source = assert(profile_sessions.new({
      profile_id = "neo",
      workspace = root,
      persistence = { enabled = false },
    }))
    local _, _, entry = source:append({ role = "user", content = "source" })

    local derived
    derived, err = profile_sessions.derive(source, {
      kind = "copy",
      target_profile_id = "",
    })
    assert.is_nil(derived)
    assert.matches("Target Profile id", assert(err).message)

    local snapshot = source.snapshot
    source.snapshot = function()
      return nil, { kind = "session", message = "snapshot unavailable" }
    end
    derived, err = profile_sessions.derive(source, {
      kind = "copy",
      target_profile_id = "neo",
    })
    source.snapshot = snapshot
    assert.is_nil(derived)
    assert.are.equal("snapshot unavailable", assert(err).message)

    local metadata = source.metadata
    source.metadata = function()
      return { data = { neoagent = { profileId = false } } }
    end
    derived, err = profile_sessions.derive(source, {
      kind = "copy",
      target_profile_id = "neo",
    })
    source.metadata = metadata
    assert.is_nil(derived)
    assert.matches("profileId", assert(err).message)

    local path = source.path
    source.path = function()
      return nil, { kind = "session", message = "path unavailable" }
    end
    derived, err = profile_sessions.derive(source, {
      kind = "fork",
      target_profile_id = "neo",
      entry_id = assert(entry).id,
      position = "at",
    })
    source.path = path
    assert.is_nil(derived)
    assert.are.equal("path unavailable", assert(err).message)

    assert.are.same({}, profile_sessions.list({ enabled = false }, root))
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
      role = "assistant", content = { { type = "text", text = "left" } },
      timestamp = 2,
    })
    assert(source:move_to(assert(first).id))
    assert(source:append({
      role = "assistant", content = { { type = "text", text = "right" } },
      timestamp = 3,
    }))
    assert(source:move_to(assert(left).id))
    assert(source:append({
      role = "user", content = "plain", timestamp = 4,
    }, {
      model = { provider = "fake", model = "plain" },
      thinking_level = vim.NIL,
    }))
    local before = source:snapshot()

    local copy = assert(profile_sessions.derive(source, {
      kind = "copy",
      source_profile_id = "neo",
      target_profile_id = "chat",
      workspace = root,
      persistence = { enabled = true, directory = root },
    }))

    assert.are_not.equal(source:id(), copy:id())
    assert.are.same(assert(before).entries, copy:entries())
    assert.are.equal(assert(before).leaf_id, copy:leaf_id())
    assert.are.same(before, source:snapshot())
    assert.are.equal("chat", assert(profile_sessions.binding(copy)))
    local metadata = assert(copy:metadata()).data
    assert.are.equal("preserved", assert(metadata).foreign)
    assert.are.same({
      kind = "copy",
      sourceSessionId = source:id(),
      sourceProfileId = "neo",
    }, assert(metadata).neoagent.derivation)
    assert.are.equal("plain", assert(assert(copy:state()).model).model)
    assert.is_nil(assert(copy:state()).thinking_level)

    local reopened = assert(profile_sessions.open((assert(assert(copy:metadata()).path))))
    assert.are.same(copy:entries(), reopened.session:entries())
    assert.are.equal(copy:leaf_id(), reopened.session:leaf_id())
    assert.is_nil(assert(reopened.session:state()).thinking_level)
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
      role = "assistant", content = { { type = "text", text = "answer" } },
      timestamp = 2,
    }))

    local fork = assert(profile_sessions.derive(source, {
      kind = "fork",
      source_profile_id = "neo",
      target_profile_id = "neo",
      workspace = root,
      entry_id = assert(first).id,
      position = "before",
      persistence = { enabled = false },
    }))
    assert.are.same({}, fork:messages())
    assert.are.equal("neo", assert(profile_sessions.binding(fork)))
    assert.is_false(assert(fork:metadata()).persisted)

    local persisted = assert(profile_sessions.derive(source, {
      kind = "copy",
      source_profile_id = "neo",
      target_profile_id = "neo",
      workspace = root,
      persistence = { enabled = true, directory = root },
    }))
    assert.is_not_nil(vim.uv.fs_stat((assert(assert(persisted:metadata()).path))))
    assert.are.same(source:entries(), persisted:entries())
  end)

  it("forks before a later prompt while retaining its parent attachment history", function()
    local root = directory()
    local source = assert(profile_sessions.new({profile_id = "neo", workspace = root, persistence = {enabled = false}}))
    local attachment = require("tests.helpers.attachments").new(source:files()).image("retained image")
    assert(source:append({role = "user", content = {attachment}}))
    assert(source:append({role = "assistant", content = {{type = "text", text = "First answer"}}}))
    local retained = source:messages()
    local saved, _, prompt = source:append({role = "user", content = "Try another answer"})
    assert(saved)
    local fork = assert(profile_sessions.derive(source, {kind = "fork", source_profile_id = "neo", target_profile_id = "neo",
      workspace = root, entry_id = assert(prompt).id, position = "before", persistence = {enabled = false}}))
    assert.are.same(retained, fork:messages())
    assert.are.equal("retained image", require("tests.helpers.attachments").new(fork:files()).read(attachment))
    assert.are.equal(3, #source:messages())
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
    fs.atomic_replace = function(target, ...)
      if target:find(".jsonl.", 1, true)
          or target:sub(-6) == ".jsonl" then
        return nil, "blocked derived document", "write"
      end
      return original_atomic_replace(target, ...)
    end

    local derived, err = profile_sessions.derive(source, {
      kind = "copy",
      source_profile_id = "neo",
      target_profile_id = "chat",
      workspace = root,
      persistence = { enabled = true, directory = root },
    })

    assert.is_nil(derived)
    assert.are.equal("storage", assert(err).kind)
    assert.matches("blocked derived document", tostring(assert(err).detail))
    assert.are.same(before, source:snapshot())
    assert.are.same({}, storage.list(root, root))
  end)
end)
