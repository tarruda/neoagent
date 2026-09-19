local exit = os.exit --[[@as fun(status?: integer): never]]

local source = assert(debug.getinfo(1, "S")).source
local script = source:sub(1, 1) == "@" and source:sub(2) or source
script = vim.uv.fs_realpath(script) or vim.fs.normalize(script)
local root = assert(vim.fs.dirname(assert(vim.fs.dirname(script))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

for _, name in ipairs({ "NVIM", "NVIM_LISTEN_ADDRESS", "NEOAGENT_WORKER_FILE", "NEOAGENT_WORKER_ROOT" }) do
  (vim.uv.os_unsetenv --[[@as fun(name: string): boolean?, string?]])(name)
end

local protocol = require("neoagent.rpc.protocol")
local failed = false
local failure_detail
local pending_writes = 0
local pending_bytes = 0
local stdout = assert(vim.uv.new_pipe(false))
stdout:open(1)

---@param bytes string
local function write(bytes)
  if failed then
    return
  end
  if pending_bytes + #bytes > protocol.MAX_QUEUED_BYTES then
    failed = true
    failure_detail = "Tool worker output queue exceeded its byte limit"
    error(failure_detail, 0)
  end
  pending_writes = pending_writes + 1
  pending_bytes = pending_bytes + #bytes
  stdout:write(bytes, function(err)
    pending_writes = pending_writes - 1
    pending_bytes = math.max(0, pending_bytes - #bytes)
    if err then
      failed = true
    end
  end)
end

local server = require("neoagent.rpc.server").new({
  send = function(message)
    write(protocol.encode(message))
  end,
})

local decoder = protocol.decoder(function(message)
  if failed then
    return
  end
  local ok, err = pcall(server.receive, server, message)
  if not ok then
    failed = true
    failure_detail = require("neoagent.util").safe_message(err)
    server:eof()
  end
end)

local incoming = {}
local incoming_bytes = 0
local drain_scheduled = false

local function schedule_drain()
  if drain_scheduled then
    return
  end
  drain_scheduled = true
  vim.schedule(function()
    drain_scheduled = false
    local queued = incoming
    incoming = {}
    incoming_bytes = 0
    for _, event in ipairs(queued) do
      if failed then
        return
      end
      if event == false then
        local complete, finish_err = decoder:finish()
        if not complete then
          failed = true
          failure_detail = finish_err
        end
        server:eof()
      else
        local ok, feed_err = pcall(decoder.feed, decoder, event)
        if not ok then
          failed = true
          failure_detail = require("neoagent.util").safe_message(feed_err)
          server:eof()
        end
      end
    end
  end)
end

local stdin = assert(vim.uv.new_pipe(false))
stdin:open(0)
stdin:read_start(function(err, data)
  if failed then
    return
  end
  if err then
    failed = true
    server:eof()
  elseif data then
    incoming_bytes = incoming_bytes + #data
    if incoming_bytes > protocol.MAX_FRAME * 2 then
      failed = true
      failure_detail = "Tool worker input queue exceeded its byte limit"
      server:eof()
    else
      incoming[#incoming + 1] = data
      schedule_drain()
    end
  else
    incoming[#incoming + 1] = false
    schedule_drain()
    stdin:read_stop()
    stdin:close()
  end
end)

while not failed and not server:is_terminal() do
  vim.wait(100, function()
    return failed or server:is_terminal()
  end, 10)
end
if not failed and server:failure() then
  failed = true
  failure_detail = server:failure()
end
if server:is_terminal() and not server:is_quiescent() then
  vim.wait(500, function()
    return server:is_quiescent()
  end, 10)
end
while pending_writes > 0 and not failed do
  vim.wait(100, function()
    return pending_writes == 0 or failed
  end, 10)
end
if not stdin:is_closing() then
  stdin:read_stop()
  stdin:close()
end
if not stdout:is_closing() then
  stdout:close()
end
if failed then
  io.stderr:write("neoagent Tool worker protocol failure")
  if failure_detail then
    io.stderr:write(": ", failure_detail)
  end
  io.stderr:write("\n")
  return exit(70)
end
return exit(0)
