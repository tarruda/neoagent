local fs = require("neoagent.fs")
local Session = require("neoagent.session")
local storage = require("neoagent.storage")
local util = require("neoagent.util")

local M = {}

local function profile_error(message, detail)
  return util.error("profile", message, detail)
end

local function object(value)
  return type(value) == "table"
    and (next(value) == nil or not util.is_list(value))
end

local function profile_id(value, label)
  if type(value) ~= "string" or value == "" then
    return nil, profile_error((label or "Profile id")
      .. " must be a non-empty string")
  end
  return value
end

local function inspect_metadata(metadata)
  if metadata == nil or metadata == vim.NIL then
    return nil, profile_error("Session has no assigned Profile")
  end
  if not object(metadata) then
    return nil, profile_error("Session metadata must be an object")
  end
  local namespace = metadata.neoagent
  if namespace == nil or namespace == vim.NIL then
    return nil, profile_error("Session has no assigned Profile")
  end
  if not object(namespace) then
    return nil, profile_error("Session metadata.neoagent must be an object")
  end
  if namespace.profileId == nil or namespace.profileId == vim.NIL then
    return nil, profile_error("Session has no assigned Profile")
  end
  local selected, err = profile_id(namespace.profileId,
    "Session metadata.neoagent.profileId")
  if not selected then return nil, err end
  local derivation = namespace.derivation
  if derivation ~= nil and derivation ~= vim.NIL then
    if not object(derivation) then
      return nil, profile_error(
        "Session metadata.neoagent.derivation must be an object")
    end
    if derivation.kind ~= "copy" then
      return nil, profile_error(
        "Session metadata.neoagent.derivation.kind must be copy")
    end
    if type(derivation.sourceSessionId) ~= "string"
        or derivation.sourceSessionId == "" then
      return nil, profile_error(
        "Session metadata.neoagent.derivation.sourceSessionId must be a non-empty string")
    end
    if derivation.sourceProfileId ~= nil
        and derivation.sourceProfileId ~= vim.NIL
        and (type(derivation.sourceProfileId) ~= "string"
          or derivation.sourceProfileId == "") then
      return nil, profile_error(
        "Session metadata.neoagent.derivation.sourceProfileId must be a non-empty string")
    end
  end
  return {
    profile_id = selected,
    derivation = derivation ~= nil and derivation ~= vim.NIL
        and util.copy(derivation) or nil,
  }
end

local function bind_metadata(metadata, target_profile_id, derivation)
  local selected, id_err = profile_id(target_profile_id)
  if not selected then return nil, id_err end
  metadata = metadata == nil and {} or util.copy(metadata)
  if not object(metadata) then
    return nil, profile_error("Session metadata must be an object")
  end
  local namespace = metadata.neoagent
  if namespace == nil or namespace == vim.NIL then namespace = {} end
  if not object(namespace) then
    return nil, profile_error("Session metadata.neoagent must be an object")
  end
  namespace = util.copy(namespace)
  namespace.profileId = selected
  if derivation == false then
    namespace.derivation = nil
  elseif derivation ~= nil then
    namespace.derivation = util.copy(derivation)
  end
  metadata.neoagent = namespace
  local _, inspect_err = inspect_metadata(metadata)
  if inspect_err then return nil, inspect_err end
  return metadata
end

local function index_attributes(metadata)
  local inspected, err = inspect_metadata(metadata)
  if not inspected then return { profileError = err.message } end
  return { profileId = inspected.profile_id }
end

local function persistence(value)
  value = value or { enabled = false }
  assert(type(value) == "table" and not util.is_list(value),
    "persistence must be an object")
  assert(type(value.enabled) == "boolean",
    "persistence.enabled must be boolean")
  if value.enabled then
    assert(type(value.directory) == "string" and value.directory ~= "",
      "persistence.directory is required")
  end
  return value
end

function M.inspect(metadata)
  return inspect_metadata(util.copy(metadata))
end

function M.binding(session)
  assert(type(session) == "table" and type(session.metadata) == "function",
    "Session is required")
  local metadata = session:metadata()
  local inspected, err = inspect_metadata(metadata and metadata.data or nil)
  if not inspected then return nil, err end
  return inspected.profile_id
end

function M.new(opts)
  opts = opts or {}
  local selected, id_err = profile_id(opts.profile_id)
  if not selected then return nil, id_err end
  assert(type(opts.workspace) == "string" and opts.workspace ~= "",
    "workspace is required")
  local root = fs.canonical(opts.workspace)
  local configured = persistence(opts.persistence)
  local metadata, metadata_err = bind_metadata(
    opts.metadata, selected, false)
  if not metadata then return nil, metadata_err end
  if configured.enabled then
    local store = storage.new({
      directory = configured.directory,
      cwd = root,
      metadata = metadata,
      index_attributes = index_attributes(metadata),
    })
    return Session.new({ store = store })
  end
  return Session.new({
    workspace = root,
    metadata = metadata,
  })
end

function M.open(path)
  local store, err = storage.open(path)
  if not store then return nil, err end
  local metadata = store:metadata()
  local inspected, inspect_err = inspect_metadata(metadata.data)
  if not inspected then return nil, inspect_err end
  local session
  session, err = Session.new({ store = store })
  if not session then return nil, err end
  return {
    session = session,
    profile_id = inspected.profile_id,
    workspace = metadata.cwd,
    path = metadata.path,
  }
end

local function fork_entries(source, snapshot, entry_id, position)
  if not entry_id then return snapshot.entries, snapshot.leaf_id end
  local target = source:entry(entry_id)
  if not target then
    return nil, profile_error("Cannot fork Session",
      "entry not found: " .. tostring(entry_id))
  end
  local leaf_id = target.id
  position = position or "before"
  if position == "before" then
    if target.type ~= "message" or target.message.role ~= "user" then
      return nil, profile_error("Cannot fork Session",
        "before position requires a user message")
    end
    if target.parentId == nil or target.parentId == vim.NIL then
      leaf_id = nil
    else
      leaf_id = target.parentId
    end
  elseif position ~= "at" then
    return nil, profile_error("Cannot fork Session",
      "position must be before or at")
  end
  local entries, err = source:path(leaf_id)
  if not entries then return nil, err end
  local validated, validation_err = require("neoagent.session_tree")
    .validate_entries(entries)
  if not validated then
    return nil, profile_error("Cannot fork Session", validation_err)
  end
  return entries, validated.leaf_id
end

function M.derive(source, opts)
  opts = opts or {}
  assert(type(source) == "table" and type(source.id) == "function"
      and type(source.snapshot) == "function"
      and type(source.path) == "function" and type(source.entry) == "function",
    "source Session is required")
  if opts.kind ~= "copy" and opts.kind ~= "fork" then
    return nil, profile_error("Session derivation kind must be copy or fork")
  end
  local target_profile, target_err = profile_id(opts.target_profile_id,
    "Target Profile id")
  if not target_profile then return nil, target_err end
  local snapshot, snapshot_err = source:snapshot()
  if not snapshot then return nil, snapshot_err end
  local actual_source, binding_err = M.binding(source)
  if binding_err then return nil, binding_err end
  if actual_source and opts.source_profile_id
      and actual_source ~= opts.source_profile_id then
    return nil, profile_error("Source Session Profile does not match the Agent")
  end
  local source_profile = opts.source_profile_id or actual_source
  local workspace = opts.workspace or snapshot.workspace
  if type(workspace) ~= "string" or workspace == "" then
    return nil, profile_error("Source Session has no Workspace")
  end
  workspace = fs.canonical(workspace)
  local entries, leaf_or_err
  if opts.kind == "fork" then
    entries, leaf_or_err = fork_entries(
      source, snapshot, opts.entry_id, opts.position)
    if not entries then return nil, leaf_or_err end
  else
    entries, leaf_or_err = snapshot.entries, snapshot.leaf_id
  end
  local derivation = false
  if opts.kind == "copy" then
    derivation = {
      kind = "copy",
      sourceSessionId = source:id(),
    }
    if source_profile then derivation.sourceProfileId = source_profile end
  end
  local metadata, metadata_err = bind_metadata(
    snapshot.metadata, target_profile, derivation)
  if not metadata then return nil, metadata_err end
  local configured = persistence(opts.persistence)
  local parent_session
  if opts.kind == "fork" then
    local source_metadata = source:metadata()
    parent_session = source_metadata and source_metadata.path or nil
  end
  if configured.enabled then
    local store, store_err = storage.derive({
      entries = entries,
      leaf_id = leaf_or_err,
    }, {
      directory = configured.directory,
      cwd = workspace,
      parent_session = parent_session,
      metadata = metadata,
      index_attributes = index_attributes(metadata),
    })
    if not store then return nil, store_err end
    return Session.new({ store = store })
  end
  return Session.new({
    entries = entries,
    leaf_id = leaf_or_err,
    workspace = workspace,
    parent_session = parent_session,
    metadata = metadata,
  })
end

function M.list(configured, workspace)
  configured = persistence(configured)
  if not configured.enabled then return {} end
  local sessions = storage.list_sessions(configured.directory, workspace, {
    index_attributes = index_attributes,
  })
  for _, info in ipairs(sessions) do
    local attributes = info.attributes or {}
    info.profile_id = attributes.profileId
    info.profile_error = attributes.profileError
  end
  return sessions
end

return M
