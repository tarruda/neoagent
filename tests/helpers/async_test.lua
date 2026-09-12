local async = require("neoagent.async")

---@param name string
---@param callback async fun()
return function(name, callback)
  it(name, function()
    local run = async.run(callback)
    if not vim.wait(10000, function() return run:is_done() end) then
      run:cancel()
      error("Asynchronous test exceeded its deadline")
    end
    local result = assert(run:result())
    if result.ok == false then error(vim.inspect(result.error), 0) end
  end)
end
