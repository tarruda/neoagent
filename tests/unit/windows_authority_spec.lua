local assert = require("luassert")
local authority = require("scripts.sandbox_windows_authority")

describe("Windows authority termination evidence", function()
  local id = string.rep("1", 32)
  ---@type Neoagent.WindowsAuthorityLease
  local lease
  ---@type Neoagent.WindowsRuntimeState, Neoagent.WindowsRuntimeState
  local state, persisted
  ---@type Neoagent.WindowsAuthorityJournal
  local journal
  ---@type string[]
  local events
  local available, fail_stop, fail_save, empty, same_boot

  before_each(function()
    lease = {
      job = "unconfirmed",
      account = { name = "na_0000000000000000" },
      paths = {},
      policy = { write_roots = {}, deny_write = {} },
    }
    state = {
      v = 9,
      owner_sid = "host",
      coordinator = string.rep("2", 32),
      provisioned = true,
      launcher = { name = "launcher", marker = "test", password = "synthetic" },
      offline_group = { name = "offline", marker = "test" },
      leases = { [id] = lease },
      placeholders = {},
      wfp = { filters = {} },
    }
    persisted = vim.deepcopy(state)
    events = {}
    available, fail_stop, fail_save, empty, same_boot = true, false, false, false, true
    journal = authority.new(state, {
      mark_execution = function() same_boot = true end,
      execution_exists = function() return same_boot end,
      clear_execution = function()
        assert.are.equal("empty", persisted.leases[id].job)
        same_boot = false
      end,
      failure = function(stage, code)
        error({ stage = stage, errno = code }, 0)
      end,
      acquire = function()
        return function()
          events[#events + 1] = "unlock"
        end
      end,
      new_job = function()
        return {
          open = function()
            events[#events + 1] = "open"
            return available
          end,
          stop = function()
            events[#events + 1] = "stop"
            if fail_stop then
              error("termination unconfirmed")
            end
            empty = true
          end,
          is_empty = function()
            return empty
          end,
          close = function()
            assert.are.equal("empty", persisted.leases[id].job)
            events[#events + 1] = "close"
          end,
        }
      end,
      save = function(value)
        local record = value.leases[id]
        if record and record.job == "empty" and fail_save then
          error("journal unavailable")
        end
        persisted = vim.deepcopy(value)
        events[#events + 1] = "save:" .. (record and record.job or "retired")
      end,
      retire = function()
        assert.are.equal("empty", persisted.leases[id].job)
        events[#events + 1] = "retire"
      end,
      prune = function()
        events[#events + 1] = "prune"
      end,
      path_key = string.lower,
      contains = function(root, path)
        return root == path
      end,
      overlap = function(left, right)
        return left == right
      end,
    })
  end)

  it("preserves an abandoned policy when the Job cannot be reopened", function()
    available = false
    local ok, err = pcall(journal.recover, journal)
    assert.is_false(ok)
    assert.are.same({ stage = "lease-job-unconfirmed", errno = 2 }, err)
    assert.are.equal("unconfirmed", persisted.leases[id].job)
    assert.are.same({ "open", "unlock" }, events)
  end)

  it("retires an abandoned policy after the machine's volatile execution evidence is gone", function()
    available, same_boot = false, false
    journal:recover()
    assert.is_nil(persisted.leases[id])
    assert.are.same({ "save:empty", "retire", "prune", "save:retired", "unlock" }, events)
  end)

  it("keeps the observation handle and policy after termination fails", function()
    fail_stop = true
    local ok = pcall(journal.recover, journal)
    assert.is_false(ok)
    assert.are.equal("unconfirmed", persisted.leases[id].job)
    assert.are.same({ "open", "stop", "unlock" }, events)
  end)

  it("cannot publish or reuse emptiness when its journal write fails", function()
    fail_save = true
    local ok = pcall(journal.recover, journal)
    assert.is_false(ok)
    assert.are.equal("unconfirmed", persisted.leases[id].job)
    assert.are.equal("unconfirmed", lease.job)
    assert.are.same({ "open", "stop", "unlock" }, events)
    local retried, err = pcall(journal.finish, journal, id)
    assert.is_false(retried)
    assert.are.same({ stage = "lease-job-unconfirmed", errno = 0 }, err)
  end)

  it("persists termination before native close and permission retirement", function()
    journal:recover()
    assert.are.same({ "open", "stop", "save:empty", "close", "retire", "prune", "save:retired", "unlock" }, events)
    assert.is_nil(persisted.leases[id])
  end)

  for _, fact in ipairs({ "unstarted", "empty" }) do
    it("recovers " .. fact .. " authority independently of a missing Job name", function()
      lease.job = fact
      persisted = vim.deepcopy(state)
      available = false
      journal:recover()
      assert.is_nil(persisted.leases[id])
      local expected = { "retire", "prune", "save:retired", "unlock" }
      if fact == "unstarted" then
        table.insert(expected, 1, "save:empty")
      end
      assert.are.same(expected, events)
    end)
  end

  it("records both reservation and permission to execute before launch", function()
    state.leases[id] = nil
    lease.job = "unstarted"
    journal:reserve(id, lease)
    assert.are.equal("unstarted", persisted.leases[id].job)
    journal:permit_launch(id)
    assert.are.equal("unconfirmed", persisted.leases[id].job)
    assert.are.same({ "save:unstarted", "save:unconfirmed" }, events)
  end)
end)
