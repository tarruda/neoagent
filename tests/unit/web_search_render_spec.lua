local assert = require("luassert")
local Applet = require("applet")
local async = require("neoagent.async")
local fake = require("tests.helpers.fake_model")
local protocol = require("neoagent.ui.renderer")
local renderers = require("neoagent.ui.renderers")
local tools = require("neoagent.tools")
local util = require("neoagent.util")

---@param entries Neoagent.WebSearchEntry[]
---@return Neoagent.ToolResultMessage
local function search_result(entries)
  local model = fake.new({
    {
      result = fake.assistant({
        {
          type = "toolCall",
          id = "search",
          name = "web_search",
          arguments = { query = "Neoagent documentation", include_content = true },
        },
      }, "toolUse"),
    },
    { result = fake.assistant({ { type = "text", text = "Done" } }) },
  })
  local run = require("neoagent.agent_loop").run({
    model = model,
    messages = {},
    tools = { tools.web_search() },
    context = {
      web_search = function()
        return async.run(function()
          return { ok = true, results = entries }
        end)
      end,
    },
    commit_message = function()
      return true
    end,
  })
  assert(vim.wait(1000, function()
    return run:is_done()
  end))
  local result = assert(run:result())
  assert(result.ok)
  local message = assert(assert(result.new_messages)[2])
  assert(message.role == "toolResult")
  assert.is_not_true(message.isError)
  -- Rendering a restored result must not depend on the backend response or a live request.
  return vim.json.decode(vim.json.encode(message))
end

---@param count integer
---@return Neoagent.WebSearchEntry[]
local function entries(count)
  local result = {}
  for index = 1, count do
    result[index] = {
      title = "Guide " .. index,
      url = "https://example.test/" .. index,
      summary = "Summary " .. index,
      content = "Full page " .. index,
      published_at = "2026-01-02",
    }
  end
  return result
end

---@param selected Neoagent.Renderer<unknown>
---@param state string
---@param result? Neoagent.ToolResultMessage
---@param expanded? boolean
---@param width? integer
---@param arguments? Neoagent.JsonObject
---@return string, Applet.PaneLayout
local function rendered(selected, state, result, expanded, width, arguments)
  local block = {
    key = "search",
    kind = "tool",
    state = state,
    call = { id = "search", name = "web_search", arguments = arguments or { query = "Neoagent documentation" } },
    message = result,
  }
  local tool = tools.web_search()
  local options = {
    width = (width or 64) - 2,
    surface_width = width or 64,
    tool = { name = tool.name, render = tool.render },
    details_key = "<CR>",
    spinner = "*",
  }
  local render = expanded and protocol.render_details or protocol.render_block
  local node, err = render(selected, block, options)
  assert(node, vim.inspect(err))
  local layout = Applet.Pane.compile({ tree = node, width = width or 64, theme = selected.theme })
  return table.concat(layout.lines, "\n"), layout
end

describe("web search cards", function()
  it("shows the query and backend while waiting for results in both styles", function()
    for _, selected in ipairs({ renderers.pi, renderers.codex }) do
      for _, state in ipairs({ "pending", "running" }) do
        local text = rendered(selected, state)
        assert.matches("Searching web", text)
        assert.matches("DeepSeek", text)
        assert.matches("Neoagent documentation", text)
        assert.is_nil((text:find("No results", 1, true)))
      end
    end
  end)

  it("previews top sources and expands the complete returned result after replay", function()
    local result = search_result(entries(4))
    for _, selected in ipairs({ renderers.pi, renderers.codex }) do
      local text = rendered(selected, "success", result)
      assert.matches("Searched web", text)
      assert.matches("DeepSeek", text)
      assert.matches("Neoagent documentation", text)
      assert.matches("4 results", text)
      for index = 1, 3 do
        assert.matches("Guide " .. index, text)
        assert.is_truthy((text:find("https://example.test/" .. index, 1, true)))
      end
      assert.is_nil((text:find("Guide 4", 1, true)))
      assert.matches("1 more result", text)
      assert.is_nil((text:find("Full page", 1, true)))

      local details = rendered(selected, "success", result, true)
      assert.matches("Searched web", details)
      assert.matches("Neoagent documentation", details)
      assert.matches("Guide 4", details)
      assert.matches("Summary 4", details)
      assert.matches("Full page 4", details)
      assert.matches("Published: 2026%-01%-02", details)
    end
  end)

  it("shows the query while Tool arguments are still streaming", function()
    local tool = tools.web_search()
    for _, selected in ipairs({ renderers.pi, renderers.codex }) do
      local node = assert(protocol.render_block(selected, {
        key = "partial-search",
        kind = "tool",
        name = "web_search",
        state = "pending",
        raw = '{"query":"Neovim docs',
      }, { width = 64, tool = { name = tool.name, render = tool.render } }))
      local layout = Applet.Pane.compile({ tree = node, width = 64, theme = selected.theme })
      assert.matches("Neovim docs", table.concat(layout.lines, "\n"))
    end
  end)

  it("distinguishes empty results, one result, and omitted sources", function()
    for _, count in ipairs({ 0, 1, 5 }) do
      local result = search_result(entries(count))
      for _, selected in ipairs({ renderers.pi, renderers.codex }) do
        local text = rendered(selected, "success", result)
        if count == 0 then
          assert.matches("No results found", text)
        elseif count == 1 then
          assert.matches("1 result", text)
          assert.is_nil((text:find("1 results", 1, true)))
          assert.matches("Guide 1", text)
          assert.is_nil((text:find("more result", 1, true)))
        else
          assert.matches("2 more results", text)
        end
      end
    end
  end)

  it("keeps authentication errors and cancellation visible", function()
    for _, failure in ipairs({ "Log in to the DeepSeek provider or set DEEPSEEK_API_KEY", "Search cancelled" }) do
      local result = {
        role = "toolResult",
        toolCallId = "search",
        toolName = "web_search",
        isError = true,
        content = { { type = "text", text = failure } },
      }
      for _, selected in ipairs({ renderers.pi, renderers.codex }) do
        for _, expanded in ipairs({ false, true }) do
          local text, layout = rendered(selected, "error", result, expanded, 100)
          assert.matches("Web search failed", text)
          assert.matches("Neoagent documentation", text)
          assert.is_truthy((text:find(failure, 1, true)))
          assert.is_nil((text:find("No results found", 1, true)))
          local highlighted = false
          for _, highlight in ipairs(layout.decorations) do
            highlighted = highlighted or highlight.group == "NeoagentError"
          end
          assert.is_true(highlighted)
        end
      end
    end
  end)

  it("bounds stored source previews and reports truncated output", function()
    local values = entries(1)
    local value = assert(values[1])
    value.title = string.rep("标题", 400) .. "\ntrailing title"
    value.url = "https://example.test/" .. string.rep("path/", 400)
    value.content = string.rep("page content\n", 6000)
    local result = search_result(values)
    local details = result.details
    assert(type(details) == "table")
    assert.is_true(details.truncated)
    assert.is_true(#vim.json.encode(details) < 6 * 1024)
    assert.is_true(util.is_valid_utf8(vim.json.encode(details)))
    local sources = details.sources
    assert(type(sources) == "table")
    local source = sources[1]
    assert(type(source) == "table")
    assert.is_nil(source.content)
    assert.is_nil(source.summary)
    for _, selected in ipairs({ renderers.pi, renderers.codex }) do
      local text = rendered(selected, "success", result)
      assert.matches("Search output truncated", text)
      local expanded = rendered(selected, "success", result, true)
      assert.matches("narrow the query", expanded)
    end
  end)

  it("fits Unicode queries and source previews in narrow cards without changing details", function()
    local values = entries(2)
    local first, second = assert(values[1]), assert(values[2])
    first.title = string.rep("é漢", 50)
    first.url = "https://example.test/" .. string.rep("long-path/", 20)
    second.title = ""
    local result = search_result(values)
    local query = string.rep("検索", 15) .. " end"
    local details = result.details
    assert(type(details) == "table")
    details.query = query
    for _, selected in ipairs({ renderers.pi, renderers.codex }) do
      local text, narrow = rendered(selected, "success", result, false, 32)
      assert.matches("end", text)
      assert.matches("%(untitled%)", text)
      assert.matches("…", text)
      assert.is_true(util.is_valid_utf8(text))
      for _, line in ipairs(narrow.lines) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= 32)
      end
      local short_details = rendered(selected, "success", result, true, 32)
      local wide_details = rendered(selected, "success", result, true, 100)
      assert.are.equal(short_details, wide_details)
      assert.is_truthy((short_details:find(first.url, 1, true)))
      assert.is_truthy((short_details:find(query, 1, true)))
    end
  end)

  it("falls back to result text for missing or malformed source metadata", function()
    for _, metadata in ipairs({ true, {}, { sources = false }, { sources = { { title = false, url = "url" } } } }) do
      local result = search_result(entries(1))
      result.details = metadata
      for _, selected in ipairs({ renderers.pi, renderers.codex }) do
        local text = rendered(selected, "success", result)
        assert.matches("Searched web", text)
        assert.matches("Summary 1", text)
      end
    end
    for _, selected in ipairs({ renderers.pi, renderers.codex }) do
      assert.matches("Searching web", (rendered(selected, "pending", nil, false, 64, {})))
      assert.matches(
        "multi line query",
        (rendered(selected, "pending", nil, false, 64, { query = "multi\nline\tquery" }))
      )
    end
  end)

  it("uses the saved backend and query when rendering historical results", function()
    local result = search_result(entries(1))
    local details = result.details
    assert(type(details) == "table")
    details.backend_name = "Saved Search"
    details.query = "original query"
    for _, selected in ipairs({ renderers.pi, renderers.codex }) do
      local text = rendered(selected, "success", result)
      assert.matches("Saved Search", text)
      assert.matches("original query", text)
      assert.is_nil((text:find("DeepSeek", 1, true)))
      assert.is_nil((text:find("Neoagent documentation", 1, true)))
    end
  end)

  it("rejects malformed semantic previews without hiding the Tool output", function()
    local ok, absent = pcall(assert(tools.web_search().render))
    assert.is_true(ok)
    assert.is_nil(absent)
    for _, invalid in ipairs({
      { backend = false },
      { backend = "invalid\nbackend" },
      { query = false },
      { query = "invalid\nquery" },
      { sources = false },
      { sources = { false } },
      { sources = { { title = false, url = "url" } } },
      { sources = { { title = "invalid\ntitle", url = "url" } } },
      { sources = { { title = "title", url = false } } },
      { sources = { { title = "title", url = "invalid\nurl" } } },
      { truncated = "yes" },
    }) do
      local semantic = vim.tbl_extend("force", {
        kind = "web_search",
        backend = "Search",
        query = "test",
      }, invalid)
      for _, selected in ipairs({ renderers.pi, renderers.codex }) do
        local block = {
          key = "invalid-preview",
          kind = "tool",
          name = "web_search",
          state = "success",
          update = { content = { { type = "text", text = "Returned results" } } },
        }
        local tool = {
          name = "web_search",
          render = function()
            return semantic
          end,
        }
        local node = protocol.render_block(selected, block, { width = 64, tool = tool })
        assert(node)
        local layout = Applet.Pane.compile({ tree = node, width = 64, theme = selected.theme })
        assert.matches("Returned results", table.concat(layout.lines, "\n"))
      end
    end
  end)
end)
