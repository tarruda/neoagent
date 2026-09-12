local assert = require('luassert')
local async = require('neoagent.async')
local files = require('neoagent.providers.anthropic.files')
local util = require('neoagent.util')
local attachments = require('tests.helpers.attachments').new()
local image = attachments.image('synthetic')
---@type Neoagent.FileAsset
local asset = {source = attachments.files, file_id = image.file_id, bytes = image.bytes, mime_type = image.mime_type}
---@type Neoagent.FileAccess
local access = {storage_scope = 'workspace', headers = {['x-api-key'] = 'replay-key', ['anthropic-version'] = '2023-06-01'}}
---@type Neoagent.RemoteFile
local object = {locator = 'file-synthetic', state = 'ready', lifetime = {kind = 'until_deleted'}}

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(2000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe('Anthropic file protocol', function()
  ---@type Neoagent.HttpRequest[]
  local requests
  ---@type Neoagent.ByteFetchResult
  local response
  ---@type Neoagent.JsonObject
  local value
  ---@type Neoagent.FileBackend
  local backend
  local held, cancelled
  before_each(function()
    requests, held, cancelled = {}, false, 0
    value = {type = 'file', id = 'file-synthetic', size_bytes = 9, mime_type = 'image/png', expires_at = vim.NIL}
    response = {ok = true, status = 200, headers = {}, body = ''}
    backend = files.new({transport = {fetch = function(opts)
      return async.run(function()
        requests[#requests + 1] = util.copy(opts.request)
        if held then async.await(function() return function() cancelled = cancelled + 1 end end) end
        local result = util.copy(response)
        if result.ok then result.body = util.json_encode(value) end
        return result
      end)
    end}})
  end)

  it('uploads verified bytes with a supported filename and permanent metadata', function()
    assert.are.same(object, wait(backend.upload(asset, access, 1000)).object)
    local uploaded = assert(requests[1])
    local headers = assert(uploaded.headers)
    assert.are.equal('POST', uploaded.method)
    assert.matches('filename="image.png"', assert(uploaded.body), 1, true)
    assert.matches('synthetic', assert(uploaded.body), 1, true)
    for name, expected in pairs(access.headers) do assert.are.equal(expected, headers[name]) end
    assert.are.same(object, wait(backend.inspect(object, access, 1000)).object)
    assert.are.equal('https://api.anthropic.com/v1/files/file-synthetic', assert(requests[2]).url)
  end)

  it('accepts an omitted expiry on upload and inspection', function()
    value.expires_at = nil
    for _, run in ipairs({ backend.upload(asset, access, 1000), backend.inspect(object, access, 1000) }) do
      local result = wait(run)
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.same(object, result.object)
    end
  end)

  for _, case in ipairs({
    {'2026-09-09T00:00:00Z', 1788912000000},
    {'2026-09-09T03:00:00.125+03:00', 1788912000125},
    {'2026-09-08T21:00:00-03:00', 1788912000000},
    {'2024-02-29T00:00:00Z', 1709164800000},
  }) do
    it('normalizes expiration ' .. case[1] .. ' to UTC milliseconds', function()
      value.expires_at = case[1]
      local result = wait(backend.upload(asset, access, 1000))
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.same({kind = 'deadline', at = case[2]}, assert(result.object).lifetime)
    end)
  end

  for _, bad in ipairs({false, 7, 'tomorrow', '2026-01-01T00:00:00',
    '2026-01-01T00:00:00+24:00', '2026-01-01T00:00:00+00:60', '2023-02-29T00:00:00Z',
    '2026-13-01T00:00:00Z', '2026-01-01T25:00:00Z', '1969-01-01T00:00:00Z'}) do
    it('rejects invalid expiration ' .. tostring(bad), function()
      value.expires_at = bad
      local result = wait(backend.upload(asset, access, 1000))
      assert.is_false(result.ok)
      assert.matches('expiration', assert(result.error).message)
    end)
  end

  it('rejects mismatched metadata without publishing remote references', function()
    for _, changed in ipairs({{type = 'other'}, {id = '../unsafe'}, {size_bytes = 10},
      {mime_type = 'image/jpeg'}, {size_bytes = -1}, {mime_type = 'text/plain'}}) do
      local previous = util.copy(value)
      value = util.deep_merge(value, changed)
      assert.is_false(wait(backend.upload(asset, access, 1000)).ok)
      value = previous
    end
    value.id = 'another-file'
    assert.is_false(wait(backend.inspect(object, access, 1000)).ok)
  end)

  it('confirms missing files and rejects unsafe cached IDs without requesting them', function()
    response = {ok = true, status = 404, headers = {}, body = ''}
    local result = wait(backend.inspect(object, access, 1000))
    assert.is_true(result.ok)
    assert.is_nil(result.object)
    local invalid = util.copy(object)
    invalid.locator = '../unsafe'
    assert.is_nil(wait(backend.inspect(invalid, access, 1000)).object)
    assert.are.equal(1, #requests)
  end)

  it('propagates upload and inspection failures without leaking response bodies', function()
    for _, stage in ipairs({'upload', 'inspect'}) do
      for _, failure in ipairs({
        {ok = true, status = 503, headers = {}, body = ''},
        {ok = false, error = util.error('transport', 'private-response')},
      }) do
        response = failure
        local result = wait(stage == 'upload' and backend.upload(asset, access, 1000) or backend.inspect(object, access, 1000))
        assert.is_false(result.ok)
        assert.matches('Files request failed', assert(result.error).message)
        assert.is_nil((vim.inspect(result):find('private-response', 1, true)))
      end
    end
  end)

  it('rejects unavailable and mismatched local bytes before making requests', function()
    local changed = util.copy(asset)
    changed.bytes = 10
    assert.is_false(wait(backend.upload(changed, access, 1000)).ok)
    changed.file_id = string.rep('b', 64)
    assert.is_false(wait(backend.upload(changed, access, 1000)).ok)
    assert.same({}, requests)
  end)

  for _, stage in ipairs({'upload', 'inspect'}) do
    it('cancels ' .. stage .. ' without retaining a remote reference', function()
      held = true
      local run = stage == 'upload' and backend.upload(asset, access, 1000) or backend.inspect(object, access, 1000)
      assert(vim.wait(1000, function() return #requests == 1 end))
      run:cancel()
      assert.is_false(wait(run).ok)
      assert.are.equal(1, cancelled)
    end)
  end
end)
