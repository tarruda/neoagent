local M = {}

---@param value string
---@return string
local function base64url(value)
  return (vim.base64.encode(value):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

---@param bytes integer
---@return string
function M.random_urlsafe(bytes)
  return base64url(assert(vim.uv.random(bytes)))
end

---@param verifier string
---@return string
function M.challenge(verifier)
  local digest = vim.fn.sha256(verifier):gsub("..", function(pair)
    return string.char((assert(tonumber(pair, 16))))
  end)
  return base64url(digest)
end

return M
