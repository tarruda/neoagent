local assert = require('luassert')
local config = require('neoagent.config')
local util = require('neoagent.util')
local runtime = require('neoagent.provider_runtimes')

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function wait(run)
  assert(vim.wait(5000, function() return run:is_done() end))
  return (assert(run:result()))
end

describe('Anthropic provider conversations', function()
  ---@type Neoagent.ProviderRuntimes?
  local runtimes
  ---@type Neoagent.HttpReplay?
  local scenario
  after_each(function()
    if runtimes then runtime.destroy(runtimes); runtimes = nil end
    local completed = scenario
    if completed then completed.close(); scenario = nil end
    config._reset()
    if completed then completed.assert_consumed() end
  end)

  it('sends a first prompt with provider caching and resumes signed Sonnet 5 thinking', function()
    scenario = require('neoagent.http_replay').new({exchanges = {
      'tests/recordings/anthropic/sonnet-5/01.yaml',
      'tests/recordings/anthropic/sonnet-5/02.yaml',
    }})
    local provider = util.copy(require('neoagent.registry.anthropic'))
    provider.catalog = nil
    provider.models = { ['claude-sonnet-5'] = require('neoagent.registry.anthropic_common').transform({
      id = 'claude-sonnet-5', input = {'text', 'image'}, max_output_tokens = 1024,
      thinking_type = 'adaptive', reasoning_levels = {'low', 'medium', 'high'},
    }) }
    local configured = config.setup({default_registry = false, providers = {anthropic = provider}})
    local auth = require('tests.helpers.auth_manager').new(configured.auth.methods)
    assert(auth.store:write('anthropic', {type = 'api_key', key = 'anthropic-replay-key'}))
    runtimes = assert(runtime.compose(configured, {auth = auth, transport = scenario, startup = false}))
    local model = require('neoagent.models').resolve('anthropic', 'claude-sonnet-5', configured, auth, runtimes)
    local session = assert(require('neoagent.session').new())
    local choices = assert(provider.models['claude-sonnet-5'].thinking)
    local options = {model = model, model_options = {request_opts = choices.medium},
      system_prompt = 'Follow the requested output exactly.', tools = {{name = 'sample_note',
        description = 'Record a short synthetic note.', input_schema = {type = 'object',
          properties = {text = {type = 'string'}}, required = {'text'}},
        execute = function() return {content = 'Recorded.'} end}}}
    for _, word in ipairs({'OK', 'DONE'}) do
      local result = wait(require('neoagent.chat').send(session, 'Reply ' .. word .. ' without using tools.', options))
      assert.is_true(result.ok, vim.inspect(result.error))
      assert.are.equal(word, result.text)
    end
    assert.are.equal(4, #session:messages())
  end)
end)
