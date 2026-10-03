local assert = require("luassert")
local strings = require("neoagent.subprocess.windows_text")

describe("Windows native string conversion", function()
  it("preserves Unicode, unpaired surrogates, and environment block terminators", function()
    local text = "A\0\194\128\223\191\224\160\128\237\160\128x\237\191\191" .. "\240\144\128\128\244\143\191\191\0\0"
    local expected = { 65, 0, 0x80, 0x7ff, 0x800, 0xd800, 120, 0xdfff, 0xd800, 0xdc00, 0xdbff, 0xdfff, 0, 0 }
    local wide, length = strings.wide(text)
    assert(wide)
    assert.are.equal(#expected, length)
    for index, unit in ipairs(expected) do
      assert.are.equal(unit, tonumber(wide[index - 1]))
    end
    assert.are.equal(0, tonumber(wide[#expected]))
    assert.are.equal(text, strings.narrow(wide, assert(length)))
    local empty, count = strings.wide("")
    assert.are.equal(0, count)
    assert.are.equal("", strings.narrow(assert(empty), assert(count)))
  end)

  it("preserves trailing lone high surrogates and combines actual UTF-16 pairs", function()
    local paired = assert(strings.wide("\237\160\128\237\176\128"))
    assert.are.equal("\240\144\128\128", strings.narrow(paired, 2))
    local lone = assert(strings.wide("\237\175\191"))
    assert.are.equal("\237\175\191", strings.narrow(lone, 1))
  end)

  it("rejects malformed bytes instead of changing the selected native string", function()
    for _, value in ipairs({
      "\128",
      "\192\128",
      "\193\191",
      "\194",
      "\194x",
      "\194\255",
      "\224\128\128",
      "\224\160",
      "\240\128\128\128",
      "\244\144\128\128",
      "\245\128\128\128",
      "\255",
    }) do
      assert.is_nil(strings.wide(value), vim.inspect(value))
    end
  end)
end)
