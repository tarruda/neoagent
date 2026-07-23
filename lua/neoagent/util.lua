local M = {}

local list_mt = { __neoagent_list = true }

function M.list(values)
  return setmetatable(values or {}, list_mt)
end

function M.is_list(value)
  if type(value) ~= "table" then
    return false
  end
  if getmetatable(value) == list_mt then
    return true
  end
  if vim.islist then
    return vim.islist(value)
  end
  return vim.tbl_islist(value)
end

local function encode_json(value, stack)
  if type(value) ~= "table" then return vim.json.encode(value) end
  if stack[value] then error("cannot encode circular JSON value", 0) end
  stack[value] = true
  local parts = {}
  if M.is_list(value) then
    for index = 1, #value do parts[index] = encode_json(value[index], stack) end
    stack[value] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then error("JSON object keys must be strings", 0) end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = vim.json.encode(key) .. ":" .. encode_json(value[key], stack)
  end
  stack[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.json_encode(value)
  return encode_json(value, {})
end

function M.copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local result = {}
  seen[value] = result
  for key, child in pairs(value) do
    result[M.copy(key, seen)] = M.copy(child, seen)
  end
  return setmetatable(result, getmetatable(value))
end

function M.deep_merge(base, override, key_normalizer)
  local result = M.copy(base or {})
  for key, value in pairs(override or {}) do
    local target_key = key
    if key_normalizer then
      local normalized = key_normalizer(key)
      for existing in pairs(result) do
        if key_normalizer(existing) == normalized then
          target_key = existing
          break
        end
      end
    end
    if type(value) == "table" and type(result[target_key]) == "table"
        and not M.is_list(value) and not M.is_list(result[target_key]) then
      result[target_key] = M.deep_merge(result[target_key], value, key_normalizer)
    else
      result[target_key] = M.copy(value)
    end
  end
  return result
end

function M.error(kind, message, detail)
  local err = { kind = kind, message = message }
  if detail ~= nil and detail ~= "" then
    err.detail = detail
  end
  return err
end

function M.normalize_error(err, kind)
  if type(err) == "table" and type(err.kind) == "string" and type(err.message) == "string" then
    return err
  end
  return M.error(kind or "tool", tostring(err))
end

function M.schedule(fn)
  vim.schedule(fn)
end

function M.now_ms()
  local seconds, microseconds = vim.uv.gettimeofday()
  return seconds * 1000 + math.floor(microseconds / 1000)
end

function M.trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.text_content(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      parts[#parts + 1] = block.text or ""
    end
  end
  return table.concat(parts)
end

function M.content_blocks(content)
  if type(content) == "string" then
    return { { type = "text", text = content } }
  end
  return M.copy(content or {})
end

return M
