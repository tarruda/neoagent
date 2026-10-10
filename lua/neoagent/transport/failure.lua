local M = {}

-- Native codes belong to the byte transport. Recorded curl failures can
-- carry only exit_code; live transports also publish the semantic code.
local curl_codes = {
  [5] = "proxy_dns",
  [6] = "dns",
  [7] = "connection",
  [16] = "http2",
  [18] = "incomplete_response",
  [28] = "timeout",
  [35] = "tls",
  [52] = "empty_response",
  [55] = "send",
  [56] = "receive",
  [60] = "certificate",
  [77] = "certificate",
  [92] = "http2",
}
local messages = {
  proxy_dns = "Proxy DNS resolution failed",
  dns = "DNS resolution failed",
  connection = "Connection failed",
  http2 = "HTTP/2 transport failed",
  incomplete_response = "Response transfer was incomplete",
  timeout = "Request timed out",
  tls = "TLS handshake failed",
  empty_response = "Server returned no response",
  send = "Sending the request failed",
  receive = "Receiving the response failed",
  certificate = "TLS certificate verification failed",
  transport = "Transport failure",
}

---@class Neoagent.TransportFailure
---@field code string
---@field message string Fixed text; never contains URLs, headers, or response bodies.
---@field exit_code? integer

-- Classification describes the failure, not whether an operation is safe
-- to repeat. Each consumer owns its retry policy and deadline.
---@param err? Neoagent.Error
---@return Neoagent.TransportFailure?
function M.classify(err)
  if not err or err.kind ~= "transport" then
    return nil
  end
  local native = rawget(err, "exit_code")
  local exit_code
  if type(native) == "number" and native >= 1 and native <= 255 and native % 1 == 0 then
    exit_code = math.floor(native)
  end
  local supplied = rawget(err, "code")
  local code = type(supplied) == "string" and messages[supplied] and supplied or curl_codes[exit_code] or "transport"
  local message = messages[code]
  if exit_code == 77 then
    message = "Could not read the TLS certificate authority file"
  end
  return {
    code = code,
    message = message .. (exit_code and " (curl " .. exit_code .. ")" or ""),
    exit_code = exit_code,
  }
end

return M
