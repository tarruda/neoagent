local async = require("neoagent.async")
local fs = require("neoagent.fs")
local util = require("neoagent.util")
local failures = require("neoagent.transport.failure")

local M = {}

---@class Neoagent.HttpRequest
---@field url string
---@field method? string
---@field headers? table<string, unknown>
---@field body? string
---@field timeout_ms? number|false
---@field max_response_bytes? integer
---@field private_input? boolean Send the URL, headers, and optional text body through stdin.

---@class Neoagent.HttpMetadata
---@field status? number
---@field headers table<string, string>

---@class Neoagent.HttpError: Neoagent.Error
---@field response? Neoagent.HttpMetadata
---@field exit_code? integer
---@field stderr? string
---@field detail? unknown

---@class Neoagent.ByteFetchSuccess: Neoagent.HttpMetadata
---@field ok true
---@field body string

---@class Neoagent.ByteStreamSuccess
---@field ok true
---@field response Neoagent.HttpMetadata

---@alias Neoagent.ByteFetchResult Neoagent.ByteFetchSuccess|Neoagent.AsyncFailure
---@alias Neoagent.ByteStreamResult Neoagent.ByteStreamSuccess|Neoagent.AsyncFailure

---@class Neoagent.ByteCall<R>
---@field request Neoagent.HttpRequest
---@field on_chunk? fun(chunk: string) Streaming requests only.
---@field on_done? fun(result: R)

---@alias Neoagent.ByteFetchOptions Neoagent.ByteCall<Neoagent.ByteFetchResult>
---@alias Neoagent.ByteStreamOptions Neoagent.ByteCall<Neoagent.ByteStreamResult>

---@class Neoagent.ByteBackend
---@field fetch? fun(opts: Neoagent.ByteFetchOptions): Neoagent.Run<Neoagent.ByteFetchResult, nil>
---@field request? fun(opts: Neoagent.ByteStreamOptions): Neoagent.Run<Neoagent.ByteStreamResult, nil>
---@field with_context? fun(context?: Neoagent.RequestIdentity): Neoagent.ByteBackend

local STDERR_LIMIT = 64 * 1024

---@param current string
---@param chunk? string
---@return string
local function append_bounded(current, chunk)
  current = current .. (chunk or "")
  if #current > STDERR_LIMIT then
    current = current:sub(#current - STDERR_LIMIT + 1)
  end
  return current
end

---@param headers? table<string, unknown>
---@return string[]
local function header_lines(headers)
  headers = headers or {}
  local names = vim.tbl_keys(headers)
  table.sort(names, function(a, b)
    local left, right = a:lower(), b:lower()
    if left == right then
      return a < b
    end
    return left < right
  end)
  return vim.tbl_map(function(name)
    return name .. ": " .. tostring(headers[name])
  end, names)
end

local config_escape = {
  ["\\"] = "\\\\",
  ['"'] = '\\"',
  ["\t"] = "\\t",
  ["\r"] = "\\r",
  ["\n"] = "\\n",
  ["\v"] = "\\v",
}

---@param name string
---@param value string
---@return string
local function config_line(name, value)
  if value:find("%z") then
    error(util.error("transport", "Private curl requests require text without NUL bytes"), 0)
  end
  return name .. ' = "' .. value:gsub('[\\"\t\r\n\v]', config_escape) .. '"\n'
end

---@param command string[]
---@param request Neoagent.HttpRequest
---@return string
local function request_input(command, request)
  local headers = header_lines(request.headers)
  if request.private_input then
    -- curl accepts the small text payload as a literal in the same config
    -- stream. Disable the user's curlrc before curl processes any options.
    table.insert(command, 2, "--disable")
    vim.list_extend(command, { "--config", "-" })
    local config = { config_line("url", request.url) }
    for _, header in ipairs(headers) do
      config[#config + 1] = config_line("header", header)
    end
    if request.body ~= nil then
      config[#config + 1] = config_line("data-raw", request.body)
    end
    return table.concat(config)
  end
  for _, header in ipairs(headers) do
    command[#command + 1] = "-H"
    command[#command + 1] = header
  end
  if request.body ~= nil then
    command[#command + 1] = "--data-binary"
    command[#command + 1] = "@-"
  end
  return request.body or ""
end

---@param path string
---@return table<string, string>? headers
---@return number? status
---@return unknown? error
local function response_headers(path)
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if not ok then
    return nil, nil, lines
  end
  -- Neovim readfile in binary mode returns a list of lines.
  ---@cast lines string[]
  local headers = {}
  local status
  for _, line in ipairs(lines) do
    local code = line:match("^HTTP/%S+%s+(%d%d%d)")
    if code then
      status = tonumber(code)
      headers = {}
    else
      local name, value = line:match("^([^:]+):%s*(.-)%s*$")
      if name then
        headers[name:lower()] = value
      end
    end
  end
  return headers, status
end

---@param code integer
---@param stderr? string
---@return Neoagent.Error
local function curl_error(code, stderr)
  local detail = util.trim(stderr or "")
  local message = "curl exited with status " .. tostring(code)
  if detail ~= "" then
    local summary = detail:gsub("%s+", " ")
    if #summary > 300 then
      summary = summary:sub(1, 297) .. "..."
    end
    message = message .. ": " .. summary
  end
  ---@type Neoagent.HttpError
  local err = util.error("transport", message, detail)
  err.exit_code = code
  err.code = assert(failures.classify(err)).code
  if detail ~= "" then
    err.stderr = detail
  end
  return err
end

---@return string
local function header_file()
  local path, err = fs.create_temp("neoagent-curl-headers-")
  if not path then
    error(util.error("transport", "Failed to create curl header file", err), 0)
  end
  return path
end

---@param request Neoagent.HttpRequest
---@param header_path? string
---@param stream boolean
---@return string[], string
local function build_command(request, header_path, stream)
  assert(type(request) == "table", "request must be a table")
  assert(type(request.url) == "string" and request.url ~= "", "request.url is required")
  local command = { "curl" }
  if stream then
    command[#command + 1] = "--no-buffer"
  end
  vim.list_extend(command, { "--silent", "--show-error", "-X", request.method or "POST" })
  if header_path then
    command[#command + 1] = "--dump-header"
    command[#command + 1] = header_path
  end
  local stdin = request_input(command, request)
  if type(request.timeout_ms) == "number" then
    command[#command + 1] = "--max-time"
    command[#command + 1] = string.format("%.3f", math.max(0.001, request.timeout_ms / 1000))
  end
  if not stream then
    command[#command + 1] = "--write-out"
    command[#command + 1] = "\n%{http_code}"
  end
  if not request.private_input then
    command[#command + 1] = request.url
  end
  return command, stdin
end

---@param request Neoagent.HttpRequest
---@param header_path? string
---@return string[], string
function M.command(request, header_path)
  return build_command(request, header_path, true)
end

---@param opts Neoagent.ByteFetchOptions
---@return Neoagent.Run<Neoagent.ByteFetchResult, nil>
function M.fetch(opts)
  opts = opts or {}
  local request = assert(opts.request, "request is required")
  assert(type(request.url) == "string" and request.url ~= "", "request.url is required")
  return async.run(
    ---@return Neoagent.ByteFetchResult
    function()
      local maximum = request.max_response_bytes
      if maximum ~= nil then
        assert(
          type(maximum) == "number" and maximum >= 0 and maximum % 1 == 0,
          "request.max_response_bytes must be a non-negative integer"
        )
      end
      local header_path = header_file()
      local completed_ok, completed = pcall(function()
        local command, stdin = build_command(request, header_path, false)
        return async.await(
          ---@param done Neoagent.AwaitCallbacks<vim.SystemCompleted>
          function(done)
            ---@type vim.SystemObj?
            local process
            local stdout = ""
            local ok, err = pcall(function()
              ---@type vim.SystemOpts
              local system_opts = {
                stdin = stdin,
                text = false,
              }
              if maximum then
                system_opts.stdout = function(read_err, data)
                  if read_err then
                    done.reject(util.error("transport", "Failed reading curl stdout", read_err))
                    if process then
                      pcall(process.kill, process, 15)
                    end
                  elseif data and data ~= "" then
                    stdout = stdout .. data
                    if #stdout > maximum + 4 then
                      done.reject(util.error("transport", "curl response exceeds " .. tostring(maximum) .. " bytes"))
                      if process then
                        pcall(process.kill, process, 15)
                      end
                    end
                  end
                end
              end
              process = vim.system(command, system_opts, function(result)
                if maximum then
                  result.stdout = stdout
                end
                if result.code == 0 then
                  done.resolve(result)
                else
                  done.reject(curl_error(result.code, not request.private_input and result.stderr or nil))
                end
              end)
            end)
            if not ok then
              done.reject(util.error("transport", "Failed to start curl", not request.private_input and err or nil))
            end
            return function()
              if process then
                pcall(process.kill, process, 15)
              end
            end
          end
        )
      end)
      local headers, header_status, header_error = response_headers(header_path)
      pcall(vim.fn.delete, header_path)
      if not completed_ok then
        ---@type Neoagent.HttpError
        local err = util.normalize_error(completed, "transport")
        if headers and (header_status or next(headers) ~= nil) then
          err.response = { status = header_status, headers = headers }
        end
        -- Response metadata is protocol input; another Run error conversion
        -- would sanitize opaque header values before their consumer sees them.
        return { ok = false, error = err }
      end
      if not headers then
        error(util.error("transport", "Failed reading curl response headers", header_error), 0)
      end
      local body, status = (completed.stdout or ""):match("^(.*)\n(%d%d%d)$")
      if not status then
        error(util.error("protocol", "curl response is missing an HTTP status"), 0)
      end
      -- Both captures exist when the trailing HTTP status matched.
      ---@cast body string
      return {
        ok = true,
        status = header_status or tonumber(status),
        headers = headers,
        body = body,
      }
    end,
    { on_done = opts.on_done, error_kind = "transport" }
  )
end

---@param opts Neoagent.ByteStreamOptions
---@return Neoagent.Run<Neoagent.ByteStreamResult, nil>
function M.request(opts)
  opts = opts or {}
  local request = assert(opts.request, "request is required")
  return async.run(
    ---@return Neoagent.ByteStreamResult
    function()
      local header_path = header_file()
      local stderr = ""
      local stdout = ""
      local completed, result = pcall(function()
        local command, stdin = M.command(request, header_path)
        return async.await(
          ---@param done Neoagent.AwaitCallbacks<{ code: integer, stdout: string, stderr: string, headers?: table<string, string>, status?: number }>
          function(done)
            ---@type vim.SystemObj?
            local process
            local ok, err = pcall(function()
              process = vim.system(command, {
                stdin = stdin,
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
                        if process then
                          pcall(process.kill, process, 15)
                        end
                      end
                    end
                  end
                end,
                stderr = function(read_err, data)
                  if request.private_input then
                    return
                  end
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
            if not ok then
              done.reject(util.error("transport", "Failed to start curl", not request.private_input and err or nil))
            end
            return function()
              if process then
                pcall(process.kill, process, 15)
              end
            end
          end
        )
      end)
      local headers, status, header_error = response_headers(header_path)
      pcall(vim.fn.delete, header_path)
      if not completed then
        ---@type Neoagent.HttpError
        local err = util.normalize_error(result, "transport")
        if headers and (status or next(headers) ~= nil) then
          err.response = { status = status, headers = headers }
        end
        return { ok = false, error = err }
      end
      if not headers then
        error(util.error("transport", "Failed reading curl response headers", header_error), 0)
      end
      return {
        ok = true,
        response = {
          headers = headers,
          status = status,
          code = result.code,
          stdout = result.stdout,
          stderr = result.stderr,
        },
      }
    end,
    {
      on_done = opts.on_done,
      error_kind = "transport",
    }
  )
end

return M
