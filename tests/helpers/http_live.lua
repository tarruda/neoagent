local M = {}
function M.start()
  local output, port, exited = "", nil, false
  local process = vim.system({ "python3", "tests/http_live/server.py" }, {
    stdout = function(err, data)
      assert(not err, err)
      output = output .. (data or "")
      local line = output:match("^(.-)\n")
      if line then port = vim.json.decode(line).port end
    end,
  }, function() exited = true end)
  local started = vim.wait(3000, function() return port ~= nil or exited end)
  if not started or not port then
    process:kill(15)
    process:wait(3000)
    error("HTTP backend server did not start")
  end
  return {
    url = "http://127.0.0.1:" .. port,
    close = function()
      if not exited then process:kill(15) end
      assert(vim.wait(3000, function() return exited end), "HTTP backend server did not stop")
    end,
  }
end
return M
