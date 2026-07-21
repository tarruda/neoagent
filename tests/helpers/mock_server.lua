local M = {}

local function consume_lines(state, chunk)
  state.pending = state.pending .. (chunk or "")
  while true do
    local ending = state.pending:find("\n", 1, true)
    if not ending then break end
    local line = state.pending:sub(1, ending - 1)
    state.pending = state.pending:sub(ending + 1)
    if line ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok then state.records[#state.records + 1] = decoded else state.stderr = state.stderr .. line end
    end
  end
end

function M.start(fixture)
  local state = { pending = "", records = {}, stderr = "" }
  state.process = vim.system({ "python3", "tests/mock_openai.py", fixture }, {
    text = false,
    stdout = function(err, data)
      if err then state.stderr = state.stderr .. tostring(err) end
      if data then consume_lines(state, data) end
    end,
    stderr = function(err, data)
      if err then state.stderr = state.stderr .. tostring(err) end
      if data then state.stderr = state.stderr .. data end
    end,
  }, function(result) state.exit = result end)
  assert(vim.wait(2000, function()
    return state.records[1] and state.records[1].type == "ready" or state.exit ~= nil
  end), "mock server did not start: " .. state.stderr)
  assert.is_nil(state.exit, state.stderr)
  state.port = state.records[1].port
  function state:stop()
    if not self.exit then self.process:kill(15) end
    vim.wait(2000, function() return self.exit ~= nil end)
  end
  return state
end

return M
