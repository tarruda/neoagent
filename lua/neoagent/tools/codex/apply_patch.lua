local common = require("neoagent.tools.common")
local patch = require("neoagent.tools.codex.patch")
local util = require("neoagent.util")
local identities = require("neoagent.tools.identities")
local async = require("neoagent.async")
local limits = require("neoagent.tools.limits")
local M = {}

---@class Neoagent.ApplyPatchDetails: Neoagent.JsonObject
---@field changed_paths string[]
---@field changes Neoagent.PatchChange[]

---@class Neoagent.ApplyPatchResult: Neoagent.ToolResult
---@field details Neoagent.ApplyPatchDetails

---@class Neoagent.ApplyPatchRequest
---@field patch string
---@field paths string[] Parent-resolved source/destination paths in patch order.

---@param text string
---@param targets unknown
---@param operations Neoagent.PatchOperation[]
---@return Neoagent.ApplyPatchRequest, Neoagent.PatchOperation[]
local function request(text, targets, operations)
  assert(type(targets) == "table" and util.is_list(targets), "patch paths must be a list")
  local count = 0
  for _, operation in ipairs(operations) do
    count = count + (operation.destination and 2 or 1)
  end
  assert(count <= 128, "Patch must not target more than 128 paths")
  assert(#targets == count, "patch paths do not match operations")
  local paths, seen = {}, {}
  for _, path in ipairs(targets) do
    path = common.absolute_path(path, "patch path")
    local key = jit.os == "Windows" and path:lower() or path
    assert(not seen[key], "Patch targets a path more than once: " .. path)
    seen[key] = true
    paths[#paths + 1] = path
  end
  return common.request({ patch = text, paths = paths }, "apply_patch request"), operations
end

---@param value unknown
---@return Neoagent.ApplyPatchRequest, Neoagent.PatchOperation[]
function M.validate_request(value)
  assert(common.object(value), "apply_patch request must be an object")
  common.fields(value, { patch = true, paths = true }, "apply_patch request")
  local text = common.string(value.patch, "patch")
  return request(text, value.paths, patch.parse(text))
end

---@param arguments Neoagent.JsonObject
---@param _ table
---@param call Neoagent.ToolOperationCall
---@return Neoagent.ApplyPatchRequest, Neoagent.PatchOperation[]
function M.prepare(arguments, _, call)
  local text = common.require_string(arguments, "patch")
  local operations = patch.parse(text)
  local paths = {}
  for _, operation in ipairs(operations) do
    paths[#paths + 1] = common.resolve_path(operation.path, call)
    if operation.destination then
      paths[#paths + 1] = common.resolve_path(operation.destination, call)
    end
  end
  return request(text, paths, operations)
end

---@param options? Neoagent.ToolDependencyOverrides
---@return {fs: Neoagent.ToolFilesystem}
function M._dependencies(options)
  return { fs = options and options.fs or require("neoagent.fs") }
end

---@async
---@param request Neoagent.ApplyPatchRequest
---@param call Neoagent.ToolOperationCall
---@param deps {fs: Neoagent.ToolFilesystem}
---@param operations? Neoagent.PatchOperation[] Parsed by this owner during preparation or validation.
---@return Neoagent.ApplyPatchResult
function M.run(request, call, deps, operations)
  local fs = deps.fs
  local check = assert(fs.check_write, "apply_patch requires filesystem preflight")
  local inspect = assert(fs.preflight, "apply_patch requires verified preimages")
  local remove = assert(fs.remove_file, "apply_patch requires verified file removal")
  local path_key = assert(fs.path_key, "apply_patch requires filesystem path identities")
  local identities_by_path, seen = {}, {}
  for _, path in ipairs(request.paths) do
    async.yield()
    local key = path_key(path)
    assert(not seen[key], "Patch targets the same filesystem path more than once: " .. path)
    seen[key], identities_by_path[path] = true, key
  end
  local function verify_path(path)
    assert(path_key(path) == identities_by_path[path], "Patch path changed since preflight: " .. path)
  end
  local prepared, changed, summary = {}, {}, {}
  ---@type Neoagent.PatchChange[]
  local changes = {}
  local index, remaining_diff = 1, 256 * 1024
  local remaining_bytes = limits.MAX_PATCH_PREPARATION_BYTES
  local error_bytes = 4096
  -- Display the approved, normalized target rather than repeating arbitrary
  -- path spelling from the patch in every effect and diff header.
  local prefix = vim.fs.normalize(call.workspace.cwd, { expand_env = false }):gsub("/$", "") .. "/"
  local function display_path(path)
    return path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
  end
  ---@param content string
  local function account(content)
    assert(#content <= remaining_bytes, "Patch preparation byte budget exceeded")
    remaining_bytes = remaining_bytes - #content
  end
  ---@param kind 'add'|'delete'|'update'
  ---@param path string
  ---@param before string
  ---@param after string
  ---@return Neoagent.PatchEffect
  local function effect(kind, path, before, after)
    local diff = vim.diff(before, after, { result_type = "unified", ctxlen = 4 })
    assert(type(diff) == "string", "invalid patch diff")
    local added, removed = 0, 0
    for line in diff:gmatch("[^\n]+") do
      added = added + (line:sub(1, 1) == "+" and 1 or 0)
      removed = removed + (line:sub(1, 1) == "-" and 1 or 0)
    end
    local safe_diff, escaped_bytes = util.text_from_bytes(diff)
    local displayed = require("neoagent.tools.truncate").head(
      safe_diff,
      { max_bytes = math.max(1, math.min(65536, remaining_diff)) }
    ).content
    remaining_diff = math.max(0, remaining_diff - #displayed)
    local value = {
      kind = kind,
      path = path,
      patch = displayed,
      added = added,
      removed = removed,
      truncated = displayed ~= safe_diff,
      escaped_bytes = escaped_bytes,
      status = "pending",
    }
    return value
  end
  ---@param path string
  ---@param policy Neoagent.AtomicPolicy
  ---@return string, boolean, integer
  local function preimage(path, policy)
    verify_path(path)
    local observed, err = inspect(path, policy, math.min(limits.MAX_EDIT_INPUT_BYTES, remaining_bytes))
    assert(observed, "Patch preparation could not capture its preimage within the byte budget: " .. tostring(err))
    account(observed.content)
    policy.expected_observation = observed.observation
    policy.expected_content_fingerprint = observed.fingerprint
    if observed.observation.exists then
      policy.require_existing = true
    else
      policy.require_missing = true
    end
    return observed.content, observed.observation.exists, observed.mode
  end
  for _, operation in ipairs(operations or patch.parse(request.patch)) do
    async.yield()
    local path = assert(request.paths[index])
    index = index + 1
    local destination
    if operation.destination then
      destination = assert(request.paths[index])
      index = index + 1
    end
    local policy = {
      preserve_mode = true,
      new_mode = 420,
      require_existing = operation.kind ~= "add",
    }
    local before, exists, mode = preimage(path, policy)
    local source_policy = policy
    local content = operation.kind == "update" and patch.update(before, operation) or operation.content
    if content then
      account(content)
    end
    local publication, removal, change
    if destination then
      removal = effect("delete", display_path(path), before, "")
      policy = { mode = mode }
      local replaced, present = preimage(destination, policy)
      publication = effect(present and "update" or "add", display_path(destination), replaced, assert(content))
      change = {
        kind = "update",
        path = display_path(path),
        destination = display_path(destination),
        effects = { publication, removal },
        patch = "",
        added = 0,
        removed = 0,
        truncated = false,
        status = "pending",
      }
    else
      publication = effect(
        operation.kind == "add" and exists and "update" or operation.kind,
        display_path(path),
        before,
        content or ""
      )
    end
    change = change or publication
    changes[#changes + 1] = change
    prepared[#prepared + 1] = {
      operation = operation,
      path = path,
      destination = destination,
      content = content,
      policy = policy,
      source_policy = source_policy,
      change = change,
      publication = publication,
      removal = removal,
    }
  end
  local function published(kind, path)
    changed[#changed + 1] = path
    summary[#summary + 1] = kind .. " " .. path
    if call.on_file_changed then
      call.on_file_changed(path)
    end
  end
  -- A move has one logical identity and two independently published effects.
  -- Its partial diff contains only effects that actually completed.
  local function finish_change(change)
    if not change.effects then
      return
    end
    change.added, change.removed, change.truncated = 0, 0, false
    change.error, change.escaped_bytes = nil, 0
    local applied, failed = 0, false
    for _, item in ipairs(change.effects) do
      applied = applied + (item.status == "applied" and 1 or 0)
      failed = failed or item.status == "failed"
    end
    change.status = applied == #change.effects and "applied"
      or applied > 0 and "partial"
      or failed and "failed"
      or "pending"
    local diffs = {}
    for _, item in ipairs(change.effects) do
      if item.status == "applied" or applied == 0 then
        diffs[#diffs + 1] = item.kind .. " " .. item.path .. "\n" .. item.patch
        change.added = change.added + item.added
        change.removed = change.removed + item.removed
        change.truncated = change.truncated or item.truncated
        change.escaped_bytes = change.escaped_bytes + (item.escaped_bytes or 0)
      end
      change.error = item.error or change.error
    end
    change.patch = table.concat(diffs, "\n")
  end
  for _, change in ipairs(changes) do
    finish_change(change)
  end
  ---@param paths string[]
  ---@param lines string[]
  ---@param failure? string
  ---@return Neoagent.ApplyPatchResult
  local function result(paths, lines, failure)
    local header = failure and "Patch publication failed: " .. failure .. "\nFiles changed:\n"
      or "Success. Updated the following files:\n"
    return {
      isError = failure and true or nil,
      content = { { type = "text", text = header .. table.concat(lines, "\n") } },
      details = { changed_paths = paths, changes = changes },
    }
  end
  local all_paths, all_lines = {}, {}
  for _, entry in ipairs(prepared) do
    if entry.operation.kind ~= "delete" then
      local path = entry.destination or entry.path
      all_paths[#all_paths + 1] = path
      all_lines[#all_lines + 1] = (entry.publication.kind == "add" and "A" or "M") .. " " .. path
    end
    if entry.operation.kind == "delete" or entry.destination then
      all_paths[#all_paths + 1] = entry.path
      all_lines[#all_lines + 1] = "D " .. entry.path
    end
  end
  -- Pending details contain every possible diff, including move duplication.
  -- Publication can only remove those bytes or shorten statuses/counts. At
  -- most one failure adds a bounded diagnostic to the text, effect, and move.
  local maximum = #vim.mpack.encode(result(all_paths, all_lines)) + 3 * (error_bytes + 16) + 128
  assert(
    maximum <= limits.MAX_PATCH_RESULT_BYTES,
    "Patch result exceeds the byte budget; split the patch into smaller requests"
  )
  for _, entry in ipairs(prepared) do
    -- Yield outside publication's error conversion so cancellation retains its
    -- Run semantics. Every preceding effect has already notified its owner.
    async.yield()
    local operation = entry.operation
    local current = entry.publication
    local ok, err = pcall(function()
      if entry.destination then
        verify_path(entry.path)
        local verified, verify_err = check(entry.path, entry.source_policy)
        assert(verified, verify_err)
      end
      if operation.kind ~= "delete" then
        local destination = entry.destination or entry.path
        verify_path(destination)
        local created, create_err = fs.mkdirp(vim.fs.dirname(destination))
        assert(created, create_err)
        local written, write_err = fs.atomic_replace(destination, assert(entry.content), entry.policy)
        assert(written, write_err)
        entry.publication.status = "applied"
        published(entry.publication.kind == "add" and "A" or "M", destination)
      end
      if operation.kind == "delete" or entry.destination then
        current = entry.removal or entry.publication
        verify_path(entry.path)
        local removed, remove_err = remove(entry.path, entry.source_policy)
        assert(removed, remove_err)
        current.status = "applied"
        published("D", entry.path)
      end
    end)
    if not ok then
      local failure = util.normalize_error(err, "tool")
      if current.status == "applied" then
        -- Delivery can fail after publication. Keep the completed effect;
        -- callers must distinguish it from a filesystem failure when retrying.
        failure.message = "File change notification failed: " .. failure.message
      else
        current.status = "failed"
      end
      current.error =
        util.safe_message(failure.message, { max_characters = error_bytes / 4, max_source_bytes = error_bytes })
      finish_change(entry.change)
      return result(changed, summary, current.error)
    end
    finish_change(entry.change)
  end
  return result(changed, summary)
end

---@return Neoagent.Tool<unknown>
function M.new()
  local deps = M._dependencies()
  return identities.bind({
    name = "apply_patch",
    description = "The apply_patch tool edits files using the Begin/End Patch language. Supply raw patch text when advertised as a freeform tool.",
    text_input = { parameter = "patch", grammar = patch.grammar },
    input_schema = {
      type = "object",
      properties = { patch = { type = "string", description = "The complete patch text." } },
      required = { "patch" },
      additionalProperties = false,
    },
    render = require("neoagent.tools.common.patch_presentation").render,
  }, {
    token = identities.apply_patch,
    settings = {},
    prepare = identities.workspace_prepare(M.prepare),
    run = function(request, _, ctx)
      return M.run(request, common.call(ctx), deps)
    end,
  })
end

return M
