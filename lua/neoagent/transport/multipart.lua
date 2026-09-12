local M = {}

---@class Neoagent.MultipartField
---@field name string
---@field value string
---@field filename? string
---@field mime_type? string

---@param value string
---@return string
local function quoted(value)
  assert(
    type(value) == "string" and value ~= "" and not value:find("[\r\n%z]"),
    "multipart names must be non-empty single-line strings"
  )
  return (value:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

---@param fields Neoagent.MultipartField[]
---@return string body
---@return string content_type
function M.encode(fields)
  assert(type(fields) == "table" and #fields > 0, "multipart fields are required")
  local boundary = "neoagent-" .. vim.fn.sha256(tostring(vim.uv.hrtime()))
  for _, field in ipairs(fields) do
    assert(type(field.value) == "string", "multipart values must be strings")
    while field.value:find(boundary, 1, true) do
      boundary = boundary .. "x"
    end
  end
  local parts = {}
  for _, field in ipairs(fields) do
    local disposition = 'Content-Disposition: form-data; name="' .. quoted(field.name) .. '"'
    if field.filename then
      disposition = disposition .. '; filename="' .. quoted(field.filename) .. '"'
    end
    local headers = disposition .. "\r\n"
    if field.mime_type then
      assert(field.mime_type:match("^[%w.+-]+/[%w.+-]+$"), "invalid multipart MIME type")
      headers = headers .. "Content-Type: " .. field.mime_type .. "\r\n"
    end
    parts[#parts + 1] = "--" .. boundary .. "\r\n" .. headers .. "\r\n" .. field.value .. "\r\n"
  end
  parts[#parts + 1] = "--" .. boundary .. "--\r\n"
  return table.concat(parts), "multipart/form-data; boundary=" .. boundary
end

return M
