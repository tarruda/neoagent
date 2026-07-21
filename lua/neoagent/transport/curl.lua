local async = require("neoagent.async")
local util = require("neoagent.util")

local M = {}

local STDERR_LIMIT = 64 * 1024

local function append_bounded(current, chunk)
  current = current .. (chunk or "")
  if #current > STDERR_LIMIT then
    current = current:sub(#current - STDERR_LIMIT + 1)
  end
  return current
end

local function append_headers(command, headers)
  local names = {}
  for name in pairs(headers or {}) do names[#names + 1] = name end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  for _, name in ipairs(names) do
    command[#command + 1] = "-H"
    command[#command + 1] = name .. ": " .. tostring(headers[name])
  end
end

function M.command(request)
  assert(type(request) == "table", "request must be a table")
  assert(type(request.url) == "string" and request.url ~= "", "request.url is required")
  local command = {
    "curl",
    "--no-buffer",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "-X",
    "POST",
  }
  append_headers(command, request.headers)
  command[#command + 1] = "--data-binary"
  command[#command + 1] = "@-"
  command[#command + 1] = request.url
  return command
end

function M.fetch(opts)
  opts = opts or {}
  local request = assert(opts.request, "request is required")
  assert(type(request.url) == "string" and request.url ~= "", "request.url is required")
  local command = { "curl", "--silent", "--show-error", "-X", request.method or "POST" }
  append_headers(command, request.headers)
  command[#command + 1] = "--data-binary"
  command[#command + 1] = "@-"
  command[#command + 1] = "--write-out"
  command[#command + 1] = "\n%{http_code}"
  command[#command + 1] = request.url
  return async.run(function()
    local completed = async.await(function(done)
      local process
      local ok, err = pcall(function()
        process = vim.system(command, {
          stdin = request.body or "",
          text = false,
        }, function(result)
          if result.code == 0 then done.resolve(result) else done.reject(util.error(
            "transport", "curl exited with status " .. tostring(result.code), result.stderr
          )) end
        end)
      end)
      if not ok then done.reject(util.error("transport", "Failed to start curl", err)) end
      return function() if process then pcall(process.kill, process, 15) end end
    end)
    local body, status = (completed.stdout or ""):match("^(.*)\n(%d%d%d)$")
    if not status then error(util.error("protocol", "curl response is missing an HTTP status"), 0) end
    return { ok = true, status = tonumber(status), body = body }
  end, { on_done = opts.on_done, error_kind = "transport" })
end

function M.request(opts)
  opts = opts or {}
  local request = assert(opts.request, "request is required")
  return async.run(function()
    local stderr = ""
    local stdout = ""
    local result = async.await(function(done)
      local process
      local ok, err = pcall(function()
        process = vim.system(M.command(request), {
          stdin = assert(request.body, "request.body is required"),
          text = false,
          stdout = function(read_err, data)
            if read_err then
              done.reject(util.error("transport", "Failed reading curl stdout", read_err))
              return
            end
            if data and data ~= "" then
              stdout = append_bounded(stdout, data)
              if opts.on_chunk then
                local chunk_ok, chunk_err = pcall(opts.on_chunk, data)
                if not chunk_ok then
                  done.reject(util.error("protocol", "Failed to process response stream", chunk_err))
                  if process then
                    pcall(process.kill, process, 15)
                  end
                end
              end
            end
          end,
          stderr = function(read_err, data)
            if read_err then
              stderr = append_bounded(stderr, tostring(read_err))
            elseif data then
              stderr = append_bounded(stderr, data)
            end
          end,
        }, function(completed)
          if completed.code == 0 then
            done.resolve({ code = 0, stdout = stdout, stderr = stderr })
          else
            done.reject(util.error(
              "transport",
              "curl exited with status " .. tostring(completed.code),
              (stderr ~= "" and stderr or "") .. (stdout ~= "" and ((stderr ~= "" and "\n" or "") .. stdout) or "")
            ))
          end
        end)
      end)
      if not ok then
        done.reject(util.error("transport", "Failed to start curl", err))
      end
      return function()
        if process then
          pcall(process.kill, process, 15)
        end
      end
    end)
    return { ok = true, response = result }
  end, {
    on_done = opts.on_done,
    error_kind = "transport",
  })
end

return M
