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
      if ok then
        state.records[#state.records + 1] = decoded
      else
        state.stderr = state.stderr .. line
      end
    end
  end
end

function M.start()
  local state = { pending = "", records = {}, stderr = "" }
  state.process = vim.system({ "python3", "tests/mock_llama.py" }, {
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
    return state.records[1] and state.records[1].type == "ready"
      or state.exit ~= nil
  end), "fake llama.cpp server did not start: " .. state.stderr)
  assert.is_nil(state.exit, state.stderr)
  state.port = state.records[1].port
  state.url = "http://127.0.0.1:" .. state.port

  function state:find_request(method, path)
    for _, record in ipairs(self.records) do
      if record.type == "request" and record.method == method
          and record.path == path then
        return record
      end
    end
  end

  function state:count_requests(method, path)
    local count = 0
    for _, record in ipairs(self.records) do
      if record.type == "request" and record.method == method
          and record.path == path then
        count = count + 1
      end
    end
    return count
  end

  function state:stop()
    if self.exit then return true end
    self.process:kill(15)
    if vim.wait(2000, function() return self.exit ~= nil end) then
      return true
    end
    self.process:kill(9)
    return vim.wait(2000, function() return self.exit ~= nil end)
  end

  return state
end

return M
