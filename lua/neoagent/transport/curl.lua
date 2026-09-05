local async = require("neoagent.async")
local fs = require("neoagent.fs")
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
  table.sort(names, function(a, b)
    local left, right = a:lower(), b:lower()
    if left == right then return a < b end
    return left < right
  end)
  for _, name in ipairs(names) do
    command[#command + 1] = "-H"
    command[#command + 1] = name .. ": " .. tostring(headers[name])
  end
end

local function response_headers(path)
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if not ok then return {}, nil end
  local headers = {}
  local status
  for _, line in ipairs(lines) do
    local code = line:match("^HTTP/%S+%s+(%d%d%d)")
    if code then
      status = tonumber(code)
      headers = {}
    else
      local name, value = line:match("^([^:]+):%s*(.-)%s*$")
      if name then headers[name:lower()] = value end
    end
  end
  return headers, status
end

local function response_error(body)
  local ok, decoded = pcall(vim.json.decode, body or "")
  if not ok or type(decoded) ~= "table" then return nil end
  local value = decoded.error
  if type(value) == "table" then value = value.message or value.code end
  if type(value) ~= "string" then value = decoded.message or decoded.detail end
  return type(value) == "string" and value ~= "" and value or nil
end

local function curl_error(code, stderr)
  local detail = util.trim(stderr or "")
  local message = "curl exited with status " .. tostring(code)
  if detail ~= "" then
    local summary = detail:gsub("%s+", " ")
    if #summary > 300 then summary = summary:sub(1, 297) .. "..." end
    message = message .. ": " .. summary
  end
  local err = util.error("transport", message, detail)
  err.exit_code = code
  if detail ~= "" then err.stderr = detail end
  return err
end

local function header_file()
  local path, err = fs.create_temp("neoagent-curl-headers-")
  if not path then
    error(util.error("transport", "Failed to create curl header file", err), 0)
  end
  return path
end

local function fetch_command(request, header_path)
  local command = {
    "curl", "--silent", "--show-error", "-X", request.method or "POST",
    "--dump-header", header_path,
  }
  append_headers(command, request.headers)
  if request.body ~= nil then
    command[#command + 1] = "--data-binary"
    command[#command + 1] = "@-"
  end
  if type(request.timeout_ms) == "number" then
    command[#command + 1] = "--max-time"
    command[#command + 1] = string.format("%.3f",
      math.max(0.001, request.timeout_ms / 1000))
  end
  command[#command + 1] = "--write-out"
  command[#command + 1] = "\n%{http_code}"
  command[#command + 1] = request.url
  return command
end

function M.command(request, header_path)
  assert(type(request) == "table", "request must be a table")
  assert(type(request.url) == "string" and request.url ~= "", "request.url is required")
  local method = request.method or "POST"
  local command = {
    "curl",
    "--no-buffer",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "-X",
    method,
  }
  if header_path then
    command[#command + 1] = "--dump-header"
    command[#command + 1] = header_path
  end
  append_headers(command, request.headers)
  if request.body ~= nil then
    command[#command + 1] = "--data-binary"
    command[#command + 1] = "@-"
  end
  if type(request.timeout_ms) == "number" then
    command[#command + 1] = "--max-time"
    command[#command + 1] = string.format("%.3f",
      math.max(0.001, request.timeout_ms / 1000))
  end
  command[#command + 1] = request.url
  return command
end

function M.fetch(opts)
  opts = opts or {}
  local request = assert(opts.request, "request is required")
  assert(type(request.url) == "string" and request.url ~= "", "request.url is required")
  return async.run(function()
    local maximum = request.max_response_bytes
    if maximum ~= nil then
      assert(type(maximum) == "number" and maximum >= 0
          and maximum % 1 == 0,
        "request.max_response_bytes must be a non-negative integer")
    end
    local header_path = header_file()
    local completed_ok, completed = pcall(function()
      local command = fetch_command(request, header_path)
      return async.await(function(done)
        local process
        local stdout = ""
        local ok, err = pcall(function()
          local system_opts = {
            stdin = request.body or "",
            text = false,
          }
          if maximum then
            system_opts.stdout = function(read_err, data)
              if read_err then
                done.reject(util.error("transport",
                  "Failed reading curl stdout", read_err))
                if process then pcall(process.kill, process, 15) end
              elseif data and data ~= "" then
                stdout = stdout .. data
                if #stdout > maximum + 4 then
                  done.reject(util.error("transport",
                    "curl response exceeds " .. tostring(maximum)
                      .. " bytes"))
                  if process then pcall(process.kill, process, 15) end
                end
              end
            end
          end
          process = vim.system(command, system_opts, function(result)
            if maximum then result.stdout = stdout end
            if result.code == 0 then done.resolve(result) else done.reject(util.error(
              "transport", "curl exited with status " .. tostring(result.code), result.stderr
            )) end
          end)
        end)
        if not ok then done.reject(util.error("transport", "Failed to start curl", err)) end
        return function() if process then pcall(process.kill, process, 15) end end
      end)
    end)
    local headers, header_status = response_headers(header_path)
    pcall(vim.fn.delete, header_path)
    if not completed_ok then error(completed, 0) end
    local body, status = (completed.stdout or ""):match("^(.*)\n(%d%d%d)$")
    if not status then
      error(util.error(
        "protocol", "curl response is missing an HTTP status"), 0)
    end
    return {
      ok = true,
      status = header_status or tonumber(status),
      headers = headers,
      body = body,
    }
  end, { on_done = opts.on_done, error_kind = "transport" })
end

function M.request(opts)
  opts = opts or {}
  local request = assert(opts.request, "request is required")
  return async.run(function()
    local header_path = header_file()
    local stderr = ""
    local stdout = ""
    local completed, result = pcall(function()
      return async.await(function(done)
        local process
        local ok, err = pcall(function()
          process = vim.system(M.command(request, header_path), {
            stdin = request.body or "",
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
                    done.reject(util.normalize_error(chunk_err, "protocol"))
                    if process then pcall(process.kill, process, 15) end
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
          }, function(finished)
            if finished.code == 0 then
              done.resolve({ code = 0, stdout = stdout, stderr = stderr })
            else
              done.reject(curl_error(finished.code, stderr))
            end
          end)
        end)
        if not ok then done.reject(util.error("transport", "Failed to start curl", err)) end
        return function()
          if process then pcall(process.kill, process, 15) end
        end
      end)
    end)
    local headers, status = response_headers(header_path)
    pcall(vim.fn.delete, header_path)
    if not completed then
      local err = util.normalize_error(result, "transport")
      if status or next(headers) ~= nil then
        err.response = { status = status, headers = headers }
      end
      if status and (status < 200 or status >= 300) then
        local message = response_error(stdout)
        if not message and err.kind ~= "transport" then
          message = err.message
        end
        err.message = "HTTP " .. tostring(status) .. (message and ": " .. message or "")
        if stdout ~= "" then err.detail = stdout end
      end
      error(err, 0)
    end
    result.headers, result.status = headers, status
    return { ok = true, response = result }
  end, {
    on_done = opts.on_done,
    error_kind = "transport",
  })
end

return M
