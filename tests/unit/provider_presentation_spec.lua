local provider_presentation = require("neoagent.ui.provider_presentation")

describe("neoagent provider presentation", function()
  local function lines(presentation)
    return table.concat(presentation.content.lines, "\n")
  end

  it("renders declarative statuses, fields, progress, lists, and activity", function()
    local presentation = provider_presentation.render({
      id = "llama",
      name = "llama.cpp",
      state = {
        blocks = {
          { type = "status", text = "Router online", level = "success" },
          { type = "field", label = "Endpoint", value = "127.0.0.1:8080" },
          {
            type = "progress", label = "Downloading qwen3",
            value = 0.5, detail = "4 GiB / 8 GiB",
          },
          {
            type = "limit", label = "Weekly limit", remaining = 0.97,
            resets_at = 1787812620, level = "success",
          },
          {
            type = "list", title = "Workers",
            items = { { label = "slot 0", detail = "generating" } },
          },
          {
            type = "activity", title = "Recent activity",
            entries = {
              { level = "info", message = "Started" },
              { level = "warn", message = "Slow" },
              { level = "error", message = "Failed" },
            },
          },
        },
        operation = {
          id = "download",
          label = "Download model",
          state = "running",
          message = "Downloading",
          ratio = 0.25,
          detail = "2 files remaining",
        },
      },
      operations = {
        { id = "download", label = "Download model", enabled = true },
        { id = "reset", label = "Reset", enabled = false },
      },
    })
    local text = lines(presentation)
    assert.matches("Router online", text)
    assert.matches("Endpoint  127.0.0.1:8080", text)
    assert.matches("Downloading qwen3", text)
    assert.matches("50%%", text)
    assert.matches("4 GiB / 8 GiB", text)
    assert.matches("Weekly limit", text)
    assert.matches("97%% left", text)
    assert.matches("Workers", text)
    assert.matches("slot 0 · generating", text)
    assert.matches("Recent activity", text)
    assert.matches("Started", text)
    assert.matches("Slow", text)
    assert.matches("Failed", text)
    assert.matches("Download model", text)
    assert.matches("25%%", text)
    assert.matches("2 files remaining", text)
    assert.matches("Reset", text)
    assert.are.equal("llama.cpp", presentation.title)
    assert.are.equal("download", presentation.selectable[#presentation.content.lines - 2].id)
    assert.is_nil(presentation.selectable[#presentation.content.lines - 1])
    local progress_row
    for row, line in ipairs(presentation.content.lines) do
      if line:match("50%%$") then progress_row = row - 1 end
    end
    local groups = {}
    for _, highlight in ipairs(presentation.content.highlights) do
      if highlight.row == progress_row then groups[highlight.group] = true end
    end
    assert.is_true(groups.NeoagentAccent)
    assert.is_true(groups.NeoagentMuted)
  end)

  it("renders unavailable and truly empty states without operation chrome", function()
    local presentation = provider_presentation.render({
      name = "Codex",
      state = false,
      operations = {},
    })
    assert.matches("No provider information", lines(presentation))
    assert.is_nil(lines(presentation):find("Operations", 1, true))

    presentation = provider_presentation.render({
      name = "Codex",
      state = { blocks = { { type = "status", text = "Awaiting first response", level = "muted" } } },
      operations = {},
    })
    assert.matches("Awaiting first response", lines(presentation))
    assert.is_nil(lines(presentation):find("Operations", 1, true))

    presentation = provider_presentation.render(nil)
    assert.matches("No provider information", lines(presentation))
    assert.are.equal("Provider", presentation.title)
  end)

  it("sizes all progress bars to the presentation width", function()
    local presentation = provider_presentation.render({
      name = "Provider",
      state = {
        blocks = {
          { type = "progress", label = "Weekly window", value = 0.84 },
        },
        operation = {
          id = "work",
          label = "Work",
          state = "running",
          ratio = 0.5,
        },
      },
      operations = {},
    }, { width = 16 })
    local bars = 0
    for _, line in ipairs(presentation.content.lines) do
      if line:match("%%$") then
        bars = bars + 1
        assert.is_true(vim.fn.strdisplaywidth(line) <= 16)
      end
    end
    assert.are.equal(2, bars)
  end)

  it("renders adaptive quota rows with deterministic local reset metadata", function()
    local snapshot = {
      name = "Codex",
      state = { blocks = {
        { type = "field", label = "Account", value = "account@example.com (Plus)" },
        {
          type = "limit", label = "5h limit", remaining = 0.55,
          resets_at = 1787793900,
        },
        {
          type = "limit", label = "Weekly limit", remaining = 0.97,
          resets_at = 1787870220,
        },
        { type = "field", label = "Last response", value = "1,250 in · 87 out" },
      } },
      operations = {},
    }
    local format_time = function(timestamp)
      return timestamp == 1787793900 and "09:25" or "07:37 on 27 Aug"
    end
    local wide = provider_presentation.render(snapshot, {
      width = 80,
      format_reset_time = format_time,
    })
    local wide_text = lines(wide)
    assert.matches("Account  account@example.com %(Plus%)", wide_text)
    assert.matches("5h limit  ███████████░░░░░░░░░ 55%% left %(resets 09:25%)",
      wide_text)
    assert.matches("Weekly limit  ███████████████████░ 97%% left %(resets 07:37 on 27 Aug%)",
      wide_text)
    assert.is_true(wide_text:find("Account", 1, true)
      < wide_text:find("5h limit", 1, true))
    assert.is_true(wide_text:find("Weekly limit", 1, true)
      < wide_text:find("Last response", 1, true))

    local narrow = provider_presentation.render(snapshot, {
      width = 28,
      format_reset_time = format_time,
    })
    local narrow_text = lines(narrow)
    assert.is_nil(narrow_text:find("█", 1, true))
    assert.matches("5h limit  55%% left", narrow_text)
    assert.matches("          resets 09:25", narrow_text)
    assert.matches("Weekly limit  97%% left", narrow_text)
    assert.matches("  resets 07:37 on 27 Aug", narrow_text)
    for _, line in ipairs(narrow.content.lines) do
      if line:find("limit", 1, true) or line:find("resets", 1, true) then
        assert.is_true(vim.fn.strdisplaywidth(line) <= 28)
      end
    end
  end)
end)
