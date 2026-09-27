local it = require("tests.helpers.async_test")
local assert = require("luassert")
local plan_compaction = require("tests.helpers.compaction")
local async = require("neoagent.async")
local Session = require("neoagent.session")
local compaction = require("neoagent.compaction")
local fake_model = require("tests.helpers.fake_model")

---@generic T, E
---@param run Neoagent.Run<T, E>
---@return Neoagent.RunResult<T>
local function finish(run)
  assert(vim.wait(1000, function()
    return run:is_done()
  end))
  return (assert(run:result()))
end

describe("neoagent.native_compaction", function()
  it("rejects mismatched strategies and stops when opaque context cannot be reduced", function()
    local component = require("neoagent.compaction.codex").component
    local settings = compaction.settings({})
    local model = fake_model.new()
    local native = { role = "nativeCompaction", api = "openai-codex-responses", provider = model.provider,
      model = model.id, encrypted_content = "synthetic-ciphertext" }
    ---@type Neoagent.NativeCompactionPreparation
    local preparation = { kind = "native", source_messages = { native }, request_messages = { native },
      retained_users = {}, tokens_before = 100, settings = settings }
    local result = finish(component.run({ model = model, preparation = preparation }))
    assert.is_false(result.ok)
    assert.matches("requires a Codex Model", assert(result.error).message)
    result = finish(compaction.run({ model = model, preparation = preparation }))
    assert.is_false(result.ok)
    assert.matches("requires summary preparation", assert(result.error).message)
    model.api = native.api
    local calls, events = 0, {}
    model.compact = function(_, options)
      calls = calls + 1
      return async.run(function(run)
        run:emit({ type = "provider_status", text = "Native request" })
        return { ok = false, error = { kind = "model", message = "maximum context length exceeded" } }
      end, { on_event = options.on_event })
    end
    result = finish(component.run({ model = model, preparation = { kind = "summary", messages = {},
      turn_prefix = {}, split_turn = false, tokens_before = 1, settings = settings } }))
    assert.is_false(result.ok)
    assert.matches("requires native preparation", assert(result.error).message)
    result = finish(component.run({ model = model, preparation = preparation,
      on_event = function(event) events[#events + 1] = event end }))
    assert.is_false(result.ok)
    assert.are.equal("native_reduction", assert(result.error).retry_exhausted)
    assert.are.equal(1, calls)
    assert.are.same({ { type = "provider_status", text = "Native request" } }, events)
    local session = assert(Session.new())
    local evaluated = plan_compaction(component, { model = model, path = {}, messages = {}, configured = {}, force = true })
    assert.is_nil(evaluated.preparation)
    assert(session:append({ role = "user", content = "History" }))
    assert(session:append_compaction({ summary = "Earlier checkpoint", tokens_before = 1 }))
    evaluated = plan_compaction(component, { model = model, path = assert(session:path()),
      messages = assert(session:context_messages()), configured = {}, force = true })
    assert.is_nil(evaluated.preparation)
    assert.are.equal(1, calls)
  end)

  it("propagates projection failures throughout native retention fitting", function()
    local fit = assert(require("neoagent.compaction.codex").component.fit)
    local checkpoint = require("neoagent.compaction.checkpoint")
    for _, phase in ipairs({ "initial", "minimum", "partial", "dropped" }) do
      local session = assert(Session.new())
      local content = { { type = "text", text = string.rep("x", 400) } }
      if phase == "dropped" then
        content[#content + 1] = require("tests.helpers.attachments").new(session:files()).image("synthetic-image")
      end
      local _, _, user = session:append({ role = "user", content = content })
      local model = fake_model.new()
      model.api, model.context_window, model.input = "openai-codex-responses", 200, { "text", "image" }
      function model:estimate_request(options)
        local total = 100
        for _, message in ipairs(options.messages) do
          if message.role == "user" then
            total = total + 4 * compaction.estimate_tokens(message)
          end
        end
        return total
      end
      local candidate = { ok = true, tokens_before = 1000,
        native = { role = "nativeCompaction", api = model.api, provider = model.provider,
          model = model.id, encrypted_content = "synthetic-ciphertext" },
        retained_users = { { entry_id = assert(user).id } } }
      local failure = { kind = "session", message = "Projection unavailable at " .. phase }
      local options = { model = model, settings = compaction.settings({ reserve_tokens = 50 }),
        model_options = { files = session:files() },
        project = function(payload)
          local retained = assert(payload.retained_users)
          local first = retained[1]
          local chars = first and first.text_chars
          if phase == "initial" or phase == "minimum" and chars == 0
            or phase == "partial" and chars and chars > 0 or phase == "dropped" and #retained == 0 then
            return nil, failure
          end
          return session:preview_compaction(payload)
        end }
      local fitted, err = fit(candidate, options)
      assert.is_nil(fitted)
      assert.are.equal(failure, err)
      assert.is_nil(candidate.retained_users[1].text_chars)
      assert.are.equal(1, #session:entries())
      if phase == "initial" then
        local accepted, acceptance_err = checkpoint.accept(candidate, options)
        assert.is_nil(accepted)
        assert.are.equal(failure, acceptance_err)
      end
    end
  end)

  it("rejects a checkpoint projection belonging to another Model", function()
    local model = fake_model.new()
    local native = { role = "nativeCompaction", api = "openai-codex-responses", provider = model.provider,
      model = model.id, encrypted_content = "synthetic-ciphertext" }
    local accepted, err = require("neoagent.compaction.checkpoint").accept({ ok = true, native = native,
      retained_users = {}, tokens_before = 1 }, { model = model, settings = compaction.settings({}),
      project = function() return { native } end })
    assert.is_nil(accepted)
    assert.matches("Encrypted context", assert(err).message)
  end)

  it("drops a native image boundary that cannot fit the returned checkpoint", function()
    local session = assert(Session.new())
    local attachments = require("tests.helpers.attachments").new(session:files())
    local _, _, oldest = session:append({ role = "user", content = "Older history" })
    local _, _, boundary = session:append({ role = "user", content = { attachments.image("synthetic-image") } })
    local _, _, newest = session:append({ role = "user", content = "Recent" })
    assert(oldest)
    local before = session:entries()
    local model = fake_model.new()
    model.api, model.context_window, model.input = "openai-codex-responses", 2000, { "text", "image" }
    model.estimate_request = function(_, options)
      local tokens = 0
      for _, message in ipairs(options.messages) do
        tokens = tokens + (message.role == "nativeCompaction" and 1500
          or compaction.estimate_tokens(message))
      end
      return tokens
    end
    local candidate = { ok = true, tokens_before = 5000,
      native = { role = "nativeCompaction", api = model.api, provider = model.provider,
        model = model.id, encrypted_content = "synthetic-checkpoint" },
      retained_users = { { entry_id = assert(boundary).id }, { entry_id = assert(newest).id } } }
    local checkpoint = require("neoagent.compaction.checkpoint")
    local options = { model = model, settings = compaction.settings({ reserve_tokens = 100 }),
      model_options = { files = session:files() },
      project = function(payload) return session:preview_compaction(payload) end }
    local fit = assert(require("neoagent.compaction.codex").component.fit)
    local unfit, unfit_err = checkpoint.accept(candidate, options)
    assert.is_nil(unfit)
    assert.matches("Checkpoint exceeds", assert(unfit_err).message)
    local fitted = assert(fit(candidate, options))
    local accepted, err = checkpoint.accept(fitted, options)
    assert.is_nil(err)
    assert.are.same({ { entry_id = assert(newest).id } }, assert(accepted).retained_users)
    assert.are.same(candidate.native, assert(accepted).native)
    assert.are.equal(2, #candidate.retained_users)
    assert.are.same(before, session:entries())
    model.context_window = 1000
    local rejected, rejection = checkpoint.accept(assert(fit(candidate, options)), options)
    assert.is_nil(rejected)
    assert.matches("Checkpoint exceeds", assert(rejection).message)
    assert.are.same(before, session:entries())
  end)

  it("cancels native reduction before sending its prepared request", function()
    local session = assert(Session.new())
    assert(session:append({ role = "user", content = string.rep("evidence ", 1000) }))
    local model = fake_model.new()
    model.api, model.context_window = "openai-codex-responses", 1000
    local estimates, calls = 0, 0
    model.estimate_request = function(_, options)
      estimates = estimates + 1
      if estimates == 1 then
        local owner = assert(async.current())
        vim.schedule(function() owner:cancel() end)
      end
      return require("neoagent.api.request_estimate").messages(options.messages)
    end
    model.compact = function()
      calls = calls + 1
      return async.run(function()
        return { ok = false, error = { kind = "model", message = "Unexpected request" } }
      end)
    end
    local component = require("neoagent.compaction.codex").component
    local result = finish(async.run(function()
      local evaluation = plan_compaction(component, { model = model, path = assert(session:path()),
        messages = assert(session:context_messages()), configured = {}, force = true })
      return component.run({ model = model, preparation = assert(evaluation.preparation) }):await()
    end))
    assert.is_false(result.ok)
    assert.are.equal("cancelled", assert(result.error).kind)
    assert.are.equal(0, calls)
  end)
  it("reduces native requests for context overflow messages without an error code", function()
    local session = assert(Session.new())
    assert(session:append({ role = "user", content = string.rep("evidence ", 100) }))
    local model = fake_model.new()
    model.api, model.context_window = "openai-codex-responses", 1000
    local attempts = 0
    model.compact = function(self)
      attempts = attempts + 1
      return async.run(function()
        if attempts == 1 then
          return { ok = false, error = { kind = "model", message = "Input exceeds the context window" } }
        end
        return {
          ok = true,
          item = {
            role = "nativeCompaction",
            api = self.api,
            provider = self.provider,
            model = self.id,
            encrypted_content = "synthetic-ciphertext",
          },
        }
      end)
    end
    local component = require("neoagent.compaction.codex").component
    local evaluation = plan_compaction(component, {
      model = model,
      path = assert(session:path()),
      messages = assert(session:context_messages()),
      configured = {},
      force = true,
    })
    assert.is_true(finish(component.run({ model = model, preparation = assert(evaluation.preparation) })).ok)
    assert.are.equal(2, attempts)
  end)

end)
