local bit = require("bit")
local async = require("neoagent.async")
local M = {}
local band, bxor, bnot = bit.band, bit.bxor, bit.bnot
local ror, rshift, tobit = bit.ror, bit.rshift, bit.tobit
---@type integer[]
local K = {
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
}

---@param value integer
---@return string
local function word(value)
  return string.char(
    band(rshift(value, 24), 255),
    band(rshift(value, 16), 255),
    band(rshift(value, 8), 255),
    band(value, 255)
  )
end

-- Vim's sha256() accepts text, not a Blob. Hash image bytes without converting
-- embedded NULs or depending on a platform-specific crypto executable.
---@async
---@param bytes string
---@return string
function M.sha256(bytes)
  local length = #bytes
  local data = bytes
    .. "\128"
    .. string.rep("\0", (55 - length) % 64)
    .. word(math.floor(length / 536870912))
    .. word(length * 8)
  ---@type integer[]
  local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  ---@type table<integer, integer>
  local w = {}
  for offset = 1, #data, 64 do
    for i = 0, 15 do
      local a, b, c, d = data:byte(offset + i * 4, offset + i * 4 + 3)
      w[i] = tobit(a * 16777216 + b * 65536 + c * 256 + d)
    end
    for i = 16, 63 do
      local x, y = assert(w[i - 15]), assert(w[i - 2])
      w[i] = tobit(
        w[i - 16] + bxor(ror(x, 7), ror(x, 18), rshift(x, 3)) + w[i - 7] + bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
      )
    end
    local a, b, c, d = assert(h[1]), assert(h[2]), assert(h[3]), assert(h[4])
    local e, f, g, v = assert(h[5]), assert(h[6]), assert(h[7]), assert(h[8])
    for i = 0, 63 do
      local t1 = tobit(
        v + bxor(ror(e, 6), ror(e, 11), ror(e, 25)) + bxor(band(e, f), band(bnot(e), g)) + assert(K[i + 1]) + w[i]
      )
      local t2 = tobit(bxor(ror(a, 2), ror(a, 13), ror(a, 22)) + bxor(band(a, b), band(a, c), band(b, c)))
      v, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + t2)
    end
    local values = { a, b, c, d, e, f, g, v }
    for i = 1, 8 do
      h[i] = tobit(assert(h[i]) + assert(values[i]))
    end
    if offset % 65536 == 1 and offset > 1 and async.current() then
      async.yield()
    end
  end
  local result = {}
  for i = 1, 8 do
    result[i] = bit.tohex((assert(h[i])))
  end
  return table.concat(result)
end

return M
