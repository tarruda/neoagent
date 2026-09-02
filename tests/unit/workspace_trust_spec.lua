local trust = require("neoagent.workspace_trust")

local function wait(run)
  assert(vim.wait(3000, function() return run:is_done() end, 5))
  return run:result()
end

describe("neoagent workspace trust", function()
  local paths = {}

  after_each(function()
    for _, path in ipairs(paths) do vim.fn.delete(path, "rf") end
    paths = {}
  end)

  it("uses the canonical Git worktree root or canonical cwd", function()
    local plain = vim.fn.tempname()
    local repo = vim.fn.tempname()
    paths = { plain, repo }
    vim.fn.mkdir(plain, "p")
    vim.fn.mkdir(repo .. "/nested/deep", "p")
    vim.fn.writefile({ "gitdir: elsewhere" }, repo .. "/.git")

    assert.are.equal(vim.uv.fs_realpath(plain), trust.target(plain))
    assert.are.equal(vim.uv.fs_realpath(repo), trust.target(repo .. "/nested/deep"))

    local alias = vim.fn.tempname()
    local linked = vim.uv.fs_symlink(repo, alias, { dir = true })
    if linked then
      paths[#paths + 1] = alias
      assert.are.equal(vim.uv.fs_realpath(repo), trust.target(alias .. "/nested"))
    end
  end)

  it("persists sorted positive decisions atomically with restrictive modes", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/trust.json"
    local first = vim.fn.tempname()
    local second = vim.fn.tempname()
    paths = { directory, first, second }
    vim.fn.mkdir(first, "p")
    vim.fn.mkdir(second, "p")
    local store = trust.new_store(path)

    assert.is_false(store:is_trusted(first))
    assert.are.same({}, assert(store:list()))
    assert.is_nil(vim.uv.fs_stat(directory))

    assert.is_true(wait(store:trust(second)).ok)
    assert.is_true(wait(store:trust(first)).ok)
    assert.is_true(wait(store:trust(first)).ok)
    local expected = { trust.target(first), trust.target(second) }
    table.sort(expected)
    assert.are.same(expected, assert(store:list()))
    assert.is_true(assert(store:is_trusted(first)))

    local content = assert(require("neoagent.fs").read(path))
    local decoded = vim.json.decode(content)
    assert.are.equal(1, decoded.version)
    assert.are.same(expected, decoded.trusted)
    local bit = require("bit")
    assert.are.equal(448, bit.band(vim.uv.fs_stat(directory).mode, 511))
    assert.are.equal(384, bit.band(vim.uv.fs_stat(path).mode, 511))

    assert.is_true(wait(store:remove(first)).ok)
    assert.is_false(store:is_trusted(first))
    assert.are.same({ trust.target(second) }, assert(store:list()))
  end)

  it("validates the complete trust document and fails closed", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/trust.json"
    paths = { directory }
    vim.fn.mkdir(directory, "p")
    local store = trust.new_store(path)
    local invalid = {
      "[]",
      "{}",
      '{"version":2,"trusted":[]}',
      '{"version":1,"trusted":{}}',
      '{"version":1,"trusted":[1]}',
      '{"version":1,"trusted":["relative"]}',
      '{"version":1,"trusted":["/same","/same"]}',
      '{"version":1,"trusted":["/z","/a"]}',
      '{"version":1,"trusted":["/tmp/../tmp/workspace"]}',
      '{"version":1,"trusted":[],"extra":true}',
      "{",
    }
    for _, content in ipairs(invalid) do
      assert(require("neoagent.fs").write_all(path, content .. "\n"))
      local value, err = store:list()
      assert.is_nil(value)
      assert.are.equal("workspace_trust", err.kind)
      assert.matches("trust", err.message:lower())
    end

    local target = directory .. "/target"
    local alias = directory .. "/alias"
    vim.fn.mkdir(target, "p")
    if vim.uv.fs_symlink(target, alias, { dir = true }) then
      assert(require("neoagent.fs").write_all(path,
        vim.json.encode({ version = 1, trusted = { alias } }) .. "\n"))
      local value, err = store:list()
      assert.is_nil(value)
      assert.are.equal("workspace_trust", err.kind)
    end

    vim.fn.delete(path)
    vim.fn.mkdir(path, "p")
    local value, err = store:list()
    assert.is_nil(value)
    assert.are.equal("workspace_trust", err.kind)

    vim.fn.delete(path, "rf")
    assert(require("neoagent.fs").write_all(path,
      '{"version":1,"trusted":[]}\n'))
    local fs = require("neoagent.fs")
    local read = fs.read
    fs.read = function() return nil, "read denied" end
    value, err = store:list()
    fs.read = read
    assert.is_nil(value)
    assert.are.equal("workspace_trust", err.kind)

    local stat = vim.uv.fs_stat
    vim.uv.fs_stat = function(candidate, ...)
      if candidate == path then return nil, "EACCES" end
      return stat(candidate, ...)
    end
    value, err = store:list()
    vim.uv.fs_stat = stat
    assert.is_nil(value)
    assert.are.equal("workspace_trust", err.kind)
  end)

  it("fails closed for local storage and lock failures", function()
    local fs = require("neoagent.fs")
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    paths = { root }

    local function patch(owner, key, replacement, fn)
      local original = owner[key]
      owner[key] = replacement
      local ok, value = pcall(fn)
      owner[key] = original
      assert(ok, value)
      return value
    end

    local function directory(name)
      local value = vim.fn.tempname() .. "-" .. name
      paths[#paths + 1] = value
      return value
    end

    local missing = trust.new_store("relative-trust.json")
    assert.is_true(wait(missing:remove(root)).ok)
    assert.is_true(require("neoagent.fs").is_absolute(missing.path))

    local denied = directory("mkdir") .. "/trust.json"
    local result = patch(fs, "mkdirp", function()
      return nil, "mkdir denied"
    end, function()
      return wait(trust.new_store(denied):trust(root))
    end)
    assert.is_false(result.ok)
    assert.are.equal("workspace_trust", result.error.kind)

    local insecure_dir = directory("chmod")
    result = patch(vim.uv, "fs_chmod", function()
      return nil, "chmod denied"
    end, function()
      return wait(trust.new_store(insecure_dir .. "/trust.json"):trust(root))
    end)
    assert.is_false(result.ok)

    local random_dir = directory("random")
    vim.fn.mkdir(random_dir, "p")
    result = patch(vim.uv, "random", function()
      return nil, "random unavailable"
    end, function()
      return wait(trust.new_store(random_dir .. "/trust.json"):trust(root))
    end)
    assert.is_false(result.ok)

    local write_dir = directory("write")
    vim.fn.mkdir(write_dir, "p")
    result = patch(fs, "atomic_replace", function()
      return nil, "write denied", "write"
    end, function()
      return wait(trust.new_store(write_dir .. "/trust.json"):trust(root))
    end)
    assert.is_false(result.ok)

    local rename_dir = directory("rename")
    vim.fn.mkdir(rename_dir, "p")
    result = patch(vim.uv, "fs_rename", function()
      return nil, "rename denied"
    end, function()
      return wait(trust.new_store(rename_dir .. "/trust.json"):trust(root))
    end)
    assert.is_false(result.ok)

    local open_dir = directory("open")
    vim.fn.mkdir(open_dir, "p")
    local original_open = vim.uv.fs_open
    result = patch(vim.uv, "fs_open", function(path, flags, mode)
      if path:sub(-5) == ".lock" then return nil, "EACCES" end
      return original_open(path, flags, mode)
    end, function()
      return wait(trust.new_store(open_dir .. "/trust.json"):trust(root))
    end)
    assert.is_false(result.ok)

    local close_dir = directory("close")
    vim.fn.mkdir(close_dir, "p")
    local original_close = vim.uv.fs_close
    local first_close = true
    result = patch(vim.uv, "fs_close", function(fd)
      if first_close then
        first_close = false
        original_close(fd)
        return nil, "close failed"
      end
      return original_close(fd)
    end, function()
      return wait(trust.new_store(close_dir .. "/trust.json"):trust(root))
    end)
    assert.is_false(result.ok)

    local release_dir = directory("release")
    vim.fn.mkdir(release_dir, "p")
    local posix = require("neoagent.file_lock.posix")
    local original_backend_new = posix.new
    result = patch(posix, "new", function(...)
      local backend = original_backend_new(...)
      local open = backend.open
      backend.open = function(owner, ...)
        local handle, open_err = open(owner, ...)
        if handle then
          handle.release = function()
            return nil, { code = "release", message = "unlock failed" }
          end
        end
        return handle, open_err
      end
      return backend
    end, function()
      return wait(trust.new_store(release_dir .. "/trust.json"):trust(root))
    end)
    assert.is_false(result.ok)
    assert.matches("release", result.error.message:lower())

    local lock_dir = directory("timeout")
    vim.fn.mkdir(lock_dir, "p")
    local lock_path = lock_dir .. "/trust.json.lock"
    local holder = assert(require("neoagent.file_lock").new({
      path = lock_path,
    }):acquire())
    local blocked = trust.new_store(lock_dir .. "/trust.json"):trust(root)
    assert(vim.wait(4000, function() return blocked:is_done() end, 10))
    assert.is_false(blocked:result().ok)
    assert.matches("Timed out", blocked:result().error.message)

    local cancelled = trust.new_store(lock_dir .. "/trust.json"):trust(root)
    vim.wait(100)
    assert.is_false(cancelled:is_done())
    cancelled:cancel()
    assert(vim.wait(1000, function() return cancelled:is_done() end, 5))
    assert.are.equal("cancelled", cancelled:result().error.kind)
    assert(holder:release())
  end)

  it("reports effective sandbox status and prompt preparation failures", function()
    local root = vim.fn.tempname()
    local second = vim.fn.tempname()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.mkdir(second, "p")
    paths = { root, second, directory }

    local function prompt(status, target)
      local dialogs = require("neoagent.dialog").new()
      local captured, chosen
      local unsubscribe = dialogs:subscribe(function(snapshot)
        if snapshot.active and not chosen then
          captured, chosen = snapshot.active, true
          vim.schedule(function()
            dialogs:choose(snapshot.active.id, "session")
          end)
        end
      end)
      local policy = trust.new({
        path = directory .. "/status.json",
        dialogs = dialogs,
        session = {},
      })
      policy:set_sandbox_status(status)
      assert.is_false(policy:request(target))
      assert(vim.wait(1000, function()
        return captured ~= nil and policy:is_trusted(target)
      end, 5))
      unsubscribe()
      return captured
    end

    local active = prompt({ enabled = true, active = true, platform = "linux" }, root)
    assert.is_not_nil(active.body:find("native linux sandbox", 1, true))
    local failed = prompt({
      enabled = true,
      active = false,
      message = "native probe failed",
    }, second)
    assert.is_not_nil(failed.body:find(
      "sandbox activation failed: native probe failed", 1, true))

    local invalid_path = directory .. "/invalid.json"
    vim.fn.mkdir(directory, "p")
    assert(require("neoagent.fs").write_all(invalid_path, "{\n"))
    local notices = {}
    local unavailable = trust.new({
      path = invalid_path,
      dialogs = { show = function() error("must not prompt") end },
      notify = function(err) notices[#notices + 1] = err end,
      session = {},
    })
    local requested, request_err = unavailable:request(root)
    assert.is_nil(requested)
    assert.are.equal("workspace_trust", request_err.kind)
    assert.are.equal(1, #notices)
    local checked, check_err = unavailable:check(root)
    assert.is_nil(checked)
    assert.are.equal("workspace_trust", check_err.kind)

    local default_notice
    local default_notifier = trust.new({
      path = invalid_path,
      dialogs = { show = function() error("must not prompt") end },
      session = {},
    })
    local default_requested = default_notifier:request(root)
    assert.is_nil(default_requested)
    assert.is_nil(default_notice)

    local activation_path = directory .. "/activation.json"
    local activation = trust.new({
      path = activation_path,
      dialogs = { show = function() error("must not prompt") end },
      notify = function(err) notices[#notices + 1] = err end,
      session = {},
    })
    local activation_result
    activation:attach({
      activate = function() error("View unavailable") end,
      on_result = function(result) activation_result = result end,
    })
    assert.is_false(activation:request(root))
    assert(vim.wait(1000, function()
      return #notices == 2 and activation_result ~= nil
    end, 5))
    assert.matches("activate", notices[2].message:lower())
    assert.is_false(activation_result.ok)

    local changed_path = directory .. "/changed.json"
    local changed = trust.new({
      path = changed_path,
      dialogs = { show = function() error("must not prompt") end },
      notify = function(err) notices[#notices + 1] = err end,
      session = {},
    })
    assert.is_false(changed:request(root))
    assert(require("neoagent.fs").write_all(changed_path, "{\n"))
    assert(vim.wait(1000, function() return #notices == 3 end, 5))

    local dialogs = require("neoagent.dialog").new()
    local selected
    local unsubscribe = dialogs:subscribe(function(snapshot)
      if snapshot.active and not selected then
        selected = true
        vim.schedule(function()
          dialogs:choose(snapshot.active.id, "trust")
        end)
      end
    end)
    local persistence = trust.new({
      path = directory .. "/unused.json",
      dialogs = dialogs,
      notify = function(err) notices[#notices + 1] = err end,
      session = {},
      store = {
        is_trusted = function() return false end,
        trust = function()
          return require("neoagent.async").run(function()
            return {
              ok = false,
              error = { kind = "workspace_trust", message = "write failed" },
            }
          end)
        end,
      },
    })
    local persistence_result
    persistence:attach({
      on_result = function(result) persistence_result = result end,
    })
    assert.is_false(persistence:request(root))
    assert(vim.wait(1000, function()
      return #notices == 4 and persistence_result ~= nil
    end, 5))
    unsubscribe()
    assert.is_false(persistence:is_trusted(root))
    assert.are.equal("write failed", notices[4].message)
    assert.are.equal("write failed", persistence_result.error.message)

    local dismissals = require("neoagent.dialog").new()
    local cancellation_settled = false
    local detach = dismissals:subscribe(function(snapshot)
      if snapshot.active then
        vim.schedule(function()
          dismissals:cancel(snapshot.active.id, "dialog dismissed by user")
          vim.schedule(function() cancellation_settled = true end)
        end)
      end
    end)
    local dismissed = trust.new({
      path = directory .. "/dismissed.json",
      dialogs = dismissals,
      notify = function(err) notices[#notices + 1] = err end,
      session = {},
    })
    assert.is_false(dismissed:request(root))
    assert(vim.wait(1000, function()
      return dismissals:snapshot().active == nil and cancellation_settled
    end, 5))
    detach()
    assert.are.equal(4, #notices)
    assert.is_false(dismissed:is_trusted(root))
  end)

  it("shares process-lifetime decisions and normalizes Windows keys", function()
    local root = vim.fn.tempname()
    local directory = vim.fn.tempname()
    paths = { root, directory }
    vim.fn.mkdir(root, "p")
    local dialogs = {
      show = function() error("trusted workspaces must not prompt") end,
    }
    local first = trust.new({
      path = directory .. "/one.json",
      dialogs = dialogs,
    })
    local second = trust.new({
      path = directory .. "/two.json",
      dialogs = dialogs,
    })
    assert.is_false(first:is_trusted(root))
    assert.is_true(first:trust_session(root))
    assert.is_true(second:is_trusted(root))
    assert.are.equal(trust.key("C:\\Repo", "Windows"),
      trust.key("c:\\repo", "Windows"))
  end)

  it("merges serialized updates through one stable lock", function()
    local directory = vim.fn.tempname()
    local path = directory .. "/trust.json"
    local first = vim.fn.tempname()
    local second = vim.fn.tempname()
    paths = { directory, first, second }
    vim.fn.mkdir(directory, "p")
    vim.fn.mkdir(first, "p")
    vim.fn.mkdir(second, "p")
    local store = trust.new_store(path)

    local one = store:trust(first)
    local two = store:trust(second)
    assert.is_true(wait(one).ok)
    assert.is_true(wait(two).ok)
    local expected = { trust.target(first), trust.target(second) }
    table.sort(expected)
    assert.are.same(expected, assert(store:list()))
    assert.is_not_nil(vim.uv.fs_stat(path .. ".lock"))
  end)
end)
