local Applet = require("applet")
local applet_input = require("applet.pane.input")
local config = require("neoagent.config")
local ProviderShellView = require("neoagent.ui.provider_shell")

describe("neoagent Provider Shell UI", function()
  local views
  local original_columns

  before_each(function()
    views = {}
    original_columns = vim.o.columns
  end)

  after_each(function()
    for _, view in ipairs(views) do view:destroy() end
    vim.o.columns = original_columns
  end)

  local function ui_config(extra)
    return config.resolve({
      default_registry = false,
      providers = {},
      ui = vim.tbl_deep_extend("force", {
        position = "center",
        provider_shell = {
          position = "center",
          width = 0.75,
          height = 0.75,
        },
      }, extra or {}),
    }).ui
  end

  local function view(opts)
    opts = opts or {}
    local configured = ui_config(opts.config)
    local value = ProviderShellView.new({
      config = configured,
      renderer = configured.renderer,
      on_action = opts.on_action,
      on_select = opts.on_select,
      on_close = opts.on_close,
      on_presentation_resolve = opts.on_presentation_resolve,
      on_presentation_cancel = opts.on_presentation_cancel,
      notify = opts.notify,
      open_uri = opts.open_uri,
    })
    views[#views + 1] = value
    return value
  end

  local function native(value, key)
    return assert(value:pane(key)):native()
  end

  local function lines(value, key)
    return vim.api.nvim_buf_get_lines(native(value, key).buffer, 0, -1, false)
  end

  local function text(value, key)
    return table.concat(lines(value, key), "\n")
  end

  local function feed(keys)
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  local function line(value, key, pattern)
    for index, candidate in ipairs(lines(value, key)) do
      if candidate:find(pattern, 1, true) then return index, candidate end
    end
  end

  local function title(window)
    local value = vim.api.nvim_win_get_config(window).title or ""
    if type(value) == "string" then return value end
    return table.concat(vim.tbl_map(function(chunk)
      return type(chunk) == "table" and chunk[1] or chunk
    end, value))
  end

  local function target_is_highlighted(pane, key)
    local target = assert(pane.layout.targets[key])
    local rectangle = assert(target.rectangles[1])
    local buffer = assert(pane:native().buffer)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        buffer, pane.focus_namespace, 0, -1, { details = true })) do
      if mark[2] == rectangle.row
          and mark[4].hl_group == target.focus_style then
        return true
      end
    end
    return false
  end

  local function snapshot(name, state, operations)
    return {
      id = name:lower():gsub("%s+", "-"),
      name = name,
      state = state,
      operations = operations or {},
    }
  end

  it("renders and dispatches provider actions in one retained shell", function()
    local selected
    local closed = 0
    local value = view({
      on_action = function(id)
        selected = id
        return true
      end,
      on_close = function() closed = closed + 1 end,
    })
    assert(value:set(snapshot("Local", {
      blocks = {
        { type = "status", level = "success", text = "Connected" },
        { type = "field", label = "Endpoint", value = "localhost" },
      },
    }, {
      { id = "refresh", label = "Refresh", description = "Reload status" },
      { id = "disabled", label = "Disabled", enabled = false },
    }), {
      { id = "local", name = "Local", selected = true, enabled = true },
    }))
    assert(value:open())

    local pane = assert(value:pane("provider"))
    assert(vim.wait(1000, function() return pane.layout ~= nil end, 5))
    local first = "provider:operations:item:refresh"
    assert.are.equal(first, assert(pane:focused_target()).key)
    assert.are.equal("PmenuSel", pane.layout.targets[first].focus_style)
    assert.is_true(target_is_highlighted(pane, first))
    feed("<CR>")
    assert.are.equal("refresh", selected)
    selected = nil
    local target = assert(pane.layout.targets[
      "provider:operations:item:refresh"])
    assert.is_true(applet_input.dispatch_action(
      pane, target.action, target, 1, "n", 0, 0))
    assert.are.equal("refresh", selected)
    assert.matches("Connected", text(value, "provider"))
    assert.matches("Refresh", text(value, "provider"))
    assert.are.equal(" Local provider shell ",
      title(native(value, "provider").window))

    assert(value:set(snapshot("Local", {
      blocks = { {
        type = "status",
        level = "success",
        text = "Updated immediately",
      } },
    }, {
      { id = "refresh", label = "Refresh", description = "Reload status" },
    }), {
      { id = "local", name = "Local", selected = true, enabled = true },
    }))
    assert(vim.wait(1000, function()
      return text(value, "provider"):find("Updated immediately", 1, true)
    end, 5))

    assert(applet_input.dispatch(pane, "n", "q"))
    assert(vim.wait(1000, function() return not value:is_open() end, 5))
    assert.are.equal(1, closed)
    assert(value:open())
    assert.matches("Updated immediately", text(value, "provider"))
    assert(value:open())

    local provider_window = native(value, "provider").window
    vim.api.nvim_win_close(provider_window, true)
    assert(vim.wait(1000, function() return not value:is_open() end, 5))
    assert(value:open())
    provider_window = native(value, "provider").window
    local foreign = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(provider_window, foreign)
    assert(vim.wait(1000, function() return not value:is_open() end, 5))
    vim.api.nvim_buf_delete(foreign, { force = true })
  end)

  it("jumps into provider actions and closes from either shell pane", function()
    local closed = 0
    local value = view({
      on_close = function() closed = closed + 1 end,
    })
    assert(value:set(snapshot("Local", {
      blocks = { { type = "status", text = "Outside the action menu" } },
    }, {
      { id = "first", label = "First action" },
      { id = "second", label = "Second action" },
      { id = "third", label = "Third action" },
    }), {
      { id = "local", name = "Local", selected = true, enabled = true },
      { id = "remote", name = "Remote", selected = false, enabled = true },
    }))
    assert(value:open())

    local provider = assert(value:pane("provider"))
    local provider_window = native(value, "provider").window
    assert(vim.wait(1000, function() return provider.layout ~= nil end, 5))
    local status_row = assert(select(1,
      line(value, "provider", "Outside the action menu")))
    vim.api.nvim_win_set_cursor(provider_window, { status_row, 0 })
    assert(applet_input.dispatch(provider, "n", "J"))
    assert.are.equal("provider:operations:item:first",
      assert(provider:focused_target()).key)
    assert(applet_input.dispatch(provider, "n", "J"))
    assert.are.equal("provider:operations:item:second",
      assert(provider:focused_target()).key)
    assert(applet_input.dispatch(provider, "n", "K"))
    assert.are.equal("provider:operations:item:first",
      assert(provider:focused_target()).key)
    vim.api.nvim_win_set_cursor(provider_window, { status_row, 0 })
    assert(applet_input.dispatch(provider, "n", "K"))
    assert.are.equal("provider:operations:item:first",
      assert(provider:focused_target()).key)

    assert(applet_input.dispatch(provider, "n", "<C-c>"))
    assert(vim.wait(1000, function() return not value:is_open() end, 5))
    assert.are.equal(1, closed)

    assert(value:open())
    local providers = assert(value:pane("providers"))
    assert(vim.wait(1000, function() return providers.layout ~= nil end, 5))
    assert(applet_input.dispatch(providers, "n", "<C-c>"))
    assert(vim.wait(1000, function() return not value:is_open() end, 5))
    assert.are.equal(2, closed)
  end)

  it("shows a provider selector only when several services are available", function()
    local selected
    local value = view({
      on_select = function(id)
        selected = id
        return id
      end,
    })
    local provider = snapshot("Alpha", {
      blocks = { { type = "status", text = "Alpha ready" } },
    }, {})
    assert(value:set(provider, {
      {
        id = "alpha",
        name = "Alpha",
        selected = true,
        enabled = true,
        authentication = {
          connected = true,
          source = "stored",
        },
      },
      {
        id = "beta",
        name = "Beta",
        selected = false,
        enabled = true,
        authentication = {
          connected = true,
        },
      },
      {
        id = "gamma",
        name = "Gamma",
        selected = false,
        enabled = false,
        authentication = {
          connected = false,
          error = true,
        },
      },
      {
        id = "delta",
        name = "Delta",
        selected = false,
        enabled = true,
        authentication = {
          connected = true,
          source = "environment",
        },
      },
      {
        id = "epsilon",
        name = "Epsilon",
        selected = false,
        enabled = true,
        authentication = {
          connected = true,
          source = "configured",
        },
      },
    }))
    assert(value:open())
    local selector = assert(value:pane("providers"))
    assert(vim.wait(1000, function() return selector.layout ~= nil end, 5))
    assert(selector:focus())
    local first = "providers:item:alpha"
    assert.are.equal(first, assert(selector:focused_target()).key)
    assert.is_true(target_is_highlighted(selector, first))
    feed("<CR>")
    assert.are.equal("alpha", selected)
    assert.matches("Alpha", text(value, "providers"))
    assert.matches("Beta", text(value, "providers"))
    assert.is_nil(text(value, "providers"):find("Logged", 1, true))
    local _, alpha = assert(line(value, "providers", "Alpha"))
    local _, beta_line = assert(line(value, "providers", "Beta"))
    local _, gamma = assert(line(value, "providers", "Gamma"))
    local _, delta = assert(line(value, "providers", "Delta"))
    local _, epsilon = assert(line(value, "providers", "Epsilon"))
    assert.is_truthy(alpha:find("✅", 1, true))
    assert.is_truthy(beta_line:find("✅", 1, true))
    assert.is_truthy(gamma:find("⭕⚠️", 1, true))
    assert.is_truthy(delta:find("✅📤", 1, true))
    assert.is_truthy(epsilon:find("✅", 1, true))
    assert.is_nil(text(value, "providers"):find("💾", 1, true))
    assert.is_nil(text(value, "providers"):find("➖", 1, true))
    assert.is_nil(text(value, "providers"):find("⚙️", 1, true))
    local selector_width = vim.api.nvim_win_get_width(
      native(value, "providers").window)
    assert.is_true(selector_width >= 20)
    assert.is_true(selector_width <= 22)

    assert(applet_input.dispatch(selector, "n", "J"))
    assert.are.equal("providers:item:beta",
      assert(selector:focused_target()).key)
    feed("<CR>")
    assert.are.equal("beta", selected)

    assert(value:set(snapshot("Beta", {
      blocks = { { type = "status", text = "Beta ready" } },
    }, {}), {
      { id = "alpha", name = "Alpha", selected = false, enabled = true },
      { id = "beta", name = "Beta", selected = true, enabled = true },
    }))
    assert(vim.wait(1000, function()
      return text(value, "provider"):find("Beta ready", 1, true)
    end, 5))

    assert(value:set(snapshot("Beta", {
      blocks = { { type = "status", text = "Only provider" } },
    }, {}), {
      { id = "beta", name = "Beta", selected = true, enabled = true },
    }))
    assert(vim.wait(1000, function()
      local pane = value:pane("providers")
      return pane == nil or not pane:is_mounted()
    end, 5))
  end)

  it("mounts provider prompts above its panes", function()
    local resolved
    local cancelled
    local value = view({
      on_presentation_resolve = function(id, answer)
        resolved = { id, answer }
      end,
      on_presentation_cancel = function(id)
        cancelled = id
      end,
    })
    assert(value:set(snapshot("Codex", {
      blocks = { { type = "status", text = "Waiting for login" } },
    }, {}), {
      { id = "codex", name = "Codex", selected = true, enabled = false },
    }))
    assert(value:open())
    assert(value:set_presentation({
      active = {
        id = "authorization-code",
        kind = "input",
        prompt = "Paste the authorization code:",
        default = "",
        multiline = false,
        secret = false,
        allow_empty = false,
        mask = "•",
      },
      queue_count = 0,
    }))
    local prompt = assert(value:pane("presentation"))
    assert(vim.wait(1000, function() return prompt:is_mounted() end, 5))
    local provider_config = vim.api.nvim_win_get_config(
      native(value, "provider").window)
    local prompt_config = vim.api.nvim_win_get_config(
      native(value, "presentation").window)
    assert.is_true(prompt_config.zindex > provider_config.zindex)
    assert.are.equal("presentation", value.applet:focused_pane())
    assert.are.equal("neoagent-prompt",
      vim.bo[native(value, "presentation").buffer].filetype)

    assert(value.presentation_component:set_text("authorization"))
    assert(applet_input.dispatch(
      value.presentation_component.pane, "i", "<CR>"))
    assert.are.same({ "authorization-code", "authorization" }, resolved)

    assert(value:set_presentation({ active = nil, queue_count = 0 }))
    assert(vim.wait(1000, function() return not prompt:is_mounted() end, 5))
    assert(value:set_presentation({
      active = {
        id = "device-code",
        kind = "notice",
        prompt = "OpenAI device login · <C-c> close",
        body = "Open this page:\nhttps://device.example\n\nEnter this code:\nABCD-EFGH",
      },
      queue_count = 0,
    }))
    local notice = assert(value:pane("presentation"))
    assert(vim.wait(1000, function() return notice:is_mounted() end, 5))
    local notice_config = vim.api.nvim_win_get_config(
      native(value, "presentation").window)
    assert.is_true(notice_config.zindex > provider_config.zindex)
    assert(applet_input.dispatch(
      value.presentation_component.pane, "n", "<C-c>"))
    assert.are.equal("device-code", cancelled)
  end)

  it("filters and updates provider selections in a two-pane prompt", function()
    local resolved
    local cancelled
    local value = view({
      on_presentation_resolve = function(id, answer)
        resolved = { id, answer }
      end,
      on_presentation_cancel = function(id) cancelled = id end,
    })
    assert(value:set(snapshot("Codex", {
      blocks = { { type = "status", text = "Choose login" } },
    }, {}), {
      { id = "codex", name = "Codex", selected = true, enabled = true },
    }))
    assert(value:open())
    assert(value:set_presentation({
      active = {
        id = "login-method",
        kind = "select",
        prompt = "Choose a login method",
        items = {
          { id = "api", label = "API key" },
          { id = "subscription", label = "Subscription" },
        },
      },
      queue_count = 0,
    }))
    local component = value.presentation_component
    local filter = assert(value:pane("presentation-filter"))
    local results = assert(value:pane("presentation-results"))
    assert(vim.wait(1000, function()
      return filter:is_mounted() and results:is_mounted()
    end, 5))
    assert.are.same({ "● API key", "  Subscription" },
      lines(value, "presentation-results"))

    assert(value:set_presentation({
      active = {
        id = "login-method",
        kind = "select",
        prompt = "Choose a login method",
        items = {
          { id = "subscription", label = "Subscription" },
          { id = "device", label = "Device code" },
        },
      },
      queue_count = 1,
    }))
    assert.are.equal(component, value.presentation_component)
    assert(vim.wait(1000, function()
      return vim.deep_equal({ "● Subscription", "  Device code" },
        lines(value, "presentation-results"))
    end, 5))
    assert(applet_input.dispatch(component.filter, "i", "<C-j>"))
    assert(applet_input.dispatch(component.filter, "i", "<CR>"))
    assert.are.same({ "login-method", "device" }, resolved)

    assert(value:set_presentation({
      active = {
        id = "cancel-method",
        kind = "select",
        prompt = "Choose another method",
        items = { { id = "api", label = "API key" } },
      },
      queue_count = 0,
    }))
    assert(vim.wait(1000, function()
      return value:pane("presentation-results")
        and value:pane("presentation-results"):is_mounted()
    end, 5))
    vim.api.nvim_win_close(native(value, "presentation-results").window, true)
    assert(vim.wait(1000, function()
      return cancelled == "cancel-method"
    end, 5))
  end)

  it("restores the prior prompt when mounting its replacement fails", function()
    local value = view()
    assert(value:set(snapshot("Codex", {
      blocks = { { type = "status", text = "Choose login" } },
    }, {}), {
      { id = "codex", name = "Codex", selected = true, enabled = true },
    }))
    assert(value:open())
    assert(value:set_presentation({
      active = {
        id = "stable",
        kind = "select",
        prompt = "Stable choice",
        items = { { id = "one", label = "One" } },
      },
      queue_count = 0,
    }))
    local stable = value.presentation_component
    local flush = value.applet.flush
    value.applet.flush = function()
      return nil, "injected frame failure"
    end
    local presented, err = value:set_presentation({
      active = {
        id = "replacement",
        kind = "input",
        prompt = "Replacement",
        default = "draft",
      },
      queue_count = 0,
    })
    value.applet.flush = flush

    assert.is_nil(presented)
    assert.are.equal("injected frame failure", err)
    assert.are.equal("stable", value.presentation.active.id)
    assert.are.equal(stable, value.presentation_component)
    assert.is_false(stable:is_destroyed())
    assert(value.applet:flush())
  end)

  it("rebuilds damaged prompts and restores input defaults after reopening", function()
    local value = view()
    assert(value:set(snapshot("Codex", {
      blocks = { { type = "status", text = "Waiting" } },
    }, {}), {
      { id = "codex", name = "Codex", selected = true, enabled = true },
    }))
    assert(value:set_presentation({
      active = {
        id = "first",
        kind = "select",
        prompt = "First",
        items = { { id = "one", label = "One" } },
      },
      queue_count = 0,
    }))
    local damaged = value.presentation_component
    damaged.filter:destroy()
    assert(value:open())
    assert.is_true(damaged:is_destroyed())
    assert.is_not.equal(damaged, value.presentation_component)
    assert(value:close())

    local replaced = value.presentation_component
    assert(value:set_presentation({
      active = {
        id = "code",
        kind = "input",
        prompt = "Authorization code",
        default = "seed",
      },
      queue_count = 0,
    }))
    assert.is_true(replaced:is_destroyed())
    assert(value:open())
    assert.are.equal("seed", value.presentation_component:text())
    assert(value.presentation_component:set_text("changed"))
    assert(value:close())
    assert(value:open())
    assert.are.equal("seed", value.presentation_component:text())
  end)

  it("masks provider secrets and wipes their transient buffer", function()
    local value = view()
    assert(value:set(snapshot("API", {
      blocks = { { type = "status", text = "Authentication required" } },
    }, {}), {
      { id = "api", name = "API", selected = true, enabled = false },
    }))
    assert(value:open())
    assert(value:set_presentation({
      active = {
        id = "api-key",
        kind = "input",
        prompt = "Enter API key:",
        default = "",
        multiline = false,
        secret = true,
        allow_empty = false,
        mask = "•",
      },
      queue_count = 0,
    }))
    local pane = assert(value:pane("presentation"))
    assert(vim.wait(1000, function() return pane:is_mounted() end, 5))
    local buffer = native(value, "presentation").buffer
    assert.are.equal("neoagent-secret", vim.bo[buffer].filetype)
    assert.is_false(vim.bo[buffer].swapfile)
    assert.is_false(vim.bo[buffer].undofile)

    assert(value.presentation_component:set_text("s3cr3t"))
    local marks = vim.api.nvim_buf_get_extmarks(buffer,
      value.presentation_component.pane.mask_namespace,
      0, -1, { details = true })
    assert.are.equal(6, #marks)
    for _, mark in ipairs(marks) do
      assert.are.equal("•", mark[4].conceal)
    end

    assert(value:set_presentation({ active = nil, queue_count = 0 }))
    assert(vim.wait(1000, function()
      return not vim.api.nvim_buf_is_valid(buffer)
    end, 5))
  end)

  it("changes the visible provider through real selector input", function()
    local selected
    local value
    local providers = {
      { id = "alpha", name = "Alpha", selected = true, enabled = true },
      { id = "beta", name = "Beta", selected = false, enabled = true },
    }
    value = view({
      on_select = function(id)
        selected = id
        providers[1].selected = id == "alpha"
        providers[2].selected = id == "beta"
        return value:set(snapshot(id == "beta" and "Beta" or "Alpha", {
          blocks = { {
            type = "status",
            text = id == "beta" and "Beta ready" or "Alpha ready",
          } },
        }, {}), providers)
      end,
    })
    assert(value:set(snapshot("Alpha", {
      blocks = { { type = "status", text = "Alpha ready" } },
    }, {}), providers))
    assert(value:open())

    local selector = assert(value:pane("providers"))
    vim.api.nvim_set_current_win(native(value, "providers").window)
    assert(vim.wait(1000, function()
      return value.applet:focused_pane() == "providers"
    end, 5))
    local beta_line = assert(select(1, line(value, "providers", "Beta")))
    vim.api.nvim_win_set_cursor(native(value, "providers").window,
      { beta_line, 0 })
    assert.are.equal("beta",
      assert(selector:focused_target()).action.payload.provider)
    local mapping = vim.api.nvim_buf_call(
      native(value, "providers").buffer,
      function() return vim.fn.maparg("<CR>", "n", false, true) end)
    assert.is_true(next(mapping) ~= nil, vim.inspect(mapping))
    feed("<CR>")
    assert(vim.wait(1000, function()
      return selected == "beta"
        and text(value, "provider"):find("Beta ready", 1, true) ~= nil
    end, 5))
  end)

  it("aligns shared progress bars and stacks actions below information", function()
    vim.o.columns = 160
    local value = view()
    assert(value:set(snapshot("OpenCode Go", {
      blocks = {
        { type = "status", level = "error",
          text = "A Go usage window is exhausted" },
        { type = "field", label = "Endpoint",
          value = "https://opencode.ai/zen/go/v1", level = "error" },
        { type = "field", label = "Quota scope",
          value = "Shared across all Go models" },
        { type = "limit", label = "5-hour limit", remaining = 0,
          resets_at = os.time() + 3600, level = "error" },
        { type = "limit", label = "Weekly limit", remaining = 0.36,
          resets_at = os.time() + 3 * 86400 },
        { type = "limit", label = "Monthly limit", remaining = 0.68,
          resets_at = os.time() + 30 * 86400 },
        { type = "progress", label = "Catalog", detail = "Waiting" },
        { type = "progress", label = "Download", value = 0.42 },
        { type = "list", title = "Request estimate", items = {
          { label = "Weekly", detail = "~194 of 540 typical requests" },
        } },
        { type = "activity", title = "Activity", entries = {
          { level = "warn", message = "A warning" },
          { level = "success", message = "A success" },
        } },
      },
      operation = {
        id = "refresh",
        label = "Refresh usage",
        state = "running",
        message = "Loading quotas",
        detail = "Authoritative request",
      },
    }, {
      {
        id = "models",
        label = "Refresh models",
        description = "Load the current OpenCode Go model catalog",
      },
      {
        id = "refresh",
        label = "Refresh usage",
        description = "Load shared 5-hour, weekly, and monthly Go quotas",
      },
    }), {
      {
        id = "opencode-go",
        name = "OpenCode Go",
        selected = true,
        enabled = true,
      },
    }))
    assert(value:open())
    local provider = assert(value:pane("provider"))
    assert(vim.wait(1000, function()
      return provider.layout ~= nil
        and line(value, "provider", "Monthly limit") ~= nil
    end, 5))

    local window = native(value, "provider").window
    assert.are.equal(" OpenCode Go provider shell ", title(window))
    assert.is_false(vim.wo[window].wrap)
    local status_row, status = assert(line(value, "provider",
      "A Go usage window is exhausted"))
    local _, endpoint = assert(line(value, "provider", "Endpoint"))
    local _, five_hour = assert(line(value, "provider", "5-hour limit"))
    local _, weekly = assert(line(value, "provider", "Weekly limit"))
    local _, monthly = assert(line(value, "provider", "Monthly limit"))
    local actions_row = assert(select(1, line(value, "provider", "Actions")))
    local activity_row = assert(select(1, line(value, "provider", "A success")))
    assert.is_true(actions_row > status_row)
    assert.is_true(actions_row > activity_row)
    assert.is_nil(status:find("Actions", 1, true))
    assert.matches("Endpoint.*×", endpoint)
    local five_hour_bar = assert(five_hour:find("[█░]"))
    local weekly_bar = assert(weekly:find("[█░]"))
    local monthly_bar = assert(monthly:find("[█░]"))
    assert.are.equal(five_hour_bar, weekly_bar)
    assert.are.equal(weekly_bar, monthly_bar)
    assert.matches("Waiting", text(value, "provider"))
    assert.matches("42%%", text(value, "provider"))
    assert.matches("Activity", text(value, "provider"))
    assert.matches("A warning", text(value, "provider"))
    assert.is_nil(text(value, "provider"):find("Loading quotas", 1, true))
    assert.is_nil(text(value, "provider"):find(
      "Authoritative request", 1, true))

    vim.o.columns = 104
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(vim.wait(3000, function()
      local actions = select(1, line(value, "provider", "Actions"))
      local status_row = select(1, line(value, "provider",
        "A Go usage window is exhausted"))
      return provider.last_width == vim.api.nvim_win_get_width(window)
        and actions and status_row and actions > status_row
    end, 5))

    assert(value:set(snapshot("OpenCode Go", { blocks = {
      { type = "limit", label = "Short", remaining = 0.5 },
      { type = "limit",
        label = "An exceptionally long organization quota label",
        remaining = 0.25, resets_at = os.time() + 3 * 86400 },
    } }), {
      { id = "opencode-go", name = "OpenCode Go",
        selected = true, enabled = true },
      { id = "other", name = "Other", selected = false, enabled = true },
    }))
    assert(vim.wait(3000, function()
      local contents = text(value, "provider")
      return contents:find("exceptionally long", 1, true)
        and contents:find("resets", 1, true)
    end, 5))

    vim.o.columns = 70
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(value:set(snapshot("OpenCode Go", { blocks = {
      { type = "limit", label = "Hourly", remaining = 0.5 },
      { type = "limit", label = "Daily", remaining = 0.25,
        resets_at = os.time() + 3600 },
    } }), {
      { id = "opencode-go", name = "OpenCode Go",
        selected = true, enabled = true },
      { id = "other", name = "Other", selected = false, enabled = true },
    }))
    assert(vim.wait(3000, function()
      local contents = text(value, "provider")
      return provider.last_width == vim.api.nvim_win_get_width(window)
        and contents:find("Hourly  50%% left")
        and contents:find("Daily  25%% left")
        and contents:find("resets", 1, true)
    end, 5))
  end)

  it("routes shell host effects and releases native surfaces", function()
    local notifications = {}
    local opened_uri
    local value = view({
      notify = function(message, level)
        notifications[#notifications + 1] = { message, level }
        return true
      end,
      open_uri = function(uri)
        opened_uri = uri
        return true
      end,
    })
    assert(value:set(snapshot("Effects", false, {}), {
      { id = "effects", name = "Effects", selected = true, enabled = true },
    }))
    assert(value:open())
    assert(value:notify("notice", vim.log.levels.WARN))
    assert(value:open_uri("https://example.test/provider"))
    assert.are.same({ { "notice", vim.log.levels.WARN } }, notifications)
    assert.are.equal("https://example.test/provider", opened_uri)
    local buffer = native(value, "provider").buffer
    value:destroy()
    assert.is_false(value:is_open())
    assert.is_false(vim.api.nvim_buf_is_valid(buffer))
    local opened, err = value:open()
    assert.is_nil(opened)
    assert.matches("destroyed", err.message)
  end)
end)
