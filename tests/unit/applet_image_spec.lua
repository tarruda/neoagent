local ImageSystem = require("applet.image")
local detect = require("applet.image.detect")
local geometry = require("applet.image.geometry")
local Kitty = require("applet.image.kitty")
local source = require("applet.image.source")
local transport = require("applet.image.transport")

local function uint32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256)
end

local function png(width, height, suffix)
  return "\137PNG\r\n\26\n\0\0\0\rIHDR"
    .. uint32(width) .. uint32(height) .. (suffix or "")
end

local function fails(pattern, callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  assert.matches(pattern, tostring(err))
end

local function backend(overrides)
  local value = {
    name = "test",
    available = true,
    cell_dimensions = function() return { width = 1, height = 2 } end,
    replace = function() end,
    clear = function() return false end,
    release = function() end,
    redraw = function() return false end,
    destroy = function() end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function wait_for_kitty(value)
  assert(vim.wait(1000, function()
    return value.output_operation == nil and next(value.pending) == nil
  end))
end

local function replace(value, owner, placements)
  value:replace(owner, placements)
  wait_for_kitty(value)
end

describe("Applet images", function()
  it("identifies, validates, and loads bounded PNG sources", function()
    local bytes = png(3, 4)
    local inline = {
      kind = "png_bytes", id = "inline", data = bytes, revision = 2,
    }
    assert.matches("^bytes:6:inline8:number:2$", source.identity(inline))
    assert.are.equal(source.identity(inline), source.identity({
      kind = "png_bytes", id = "inline", data = png(9, 7), revision = 2,
    }))
    assert.are_not.equal(source.identity(inline), source.identity({
      kind = "png_bytes", id = "inline", data = bytes, revision = "2",
    }))
    assert.are.same({ width = 3, height = 4, bytes = #bytes },
      source.png_info(bytes))
    local loaded = assert(source.load(inline))
    assert.are.equal(source.identity(inline), loaded.id)
    assert.are.equal(bytes, loaded.data)

    local file = {
      kind = "png_file", path = "/tmp/example.png", revision = "v1",
    }
    assert.are.equal("file:16:/tmp/example.png9:string:v1",
      source.identity(file))
    local read = assert(source.load(file, {
      read_file = function(path, maximum)
        assert.are.equal(file.path, path)
        assert.is_true(maximum > #bytes)
        return bytes
      end,
    }))
    assert.are.equal(4, read.height)
    local missing, missing_error = source.load(file, {
      read_file = function() return nil, "missing" end,
    })
    assert.is_nil(missing)
    assert.are.equal("missing", missing_error)

    local path = vim.fn.tempname()
    local descriptor = assert(vim.uv.fs_open(path, "w", 384))
    assert(vim.uv.fs_write(descriptor, bytes, 0))
    assert(vim.uv.fs_close(descriptor))
    local disk_source = {
      kind = "png_file", path = path, revision = "disk",
    }
    assert.are.equal(bytes, assert(source.load(disk_source)).data)
    local oversized, oversized_error = source.load(disk_source, {
      max_bytes = #bytes - 1,
    })
    assert.is_nil(oversized)
    assert.are.equal("file exceeds the byte limit", oversized_error)
    assert.are.equal(0, vim.fn.delete(path))
    local absent, absent_error = source.load(disk_source)
    assert.is_nil(absent)
    assert.is_string(absent_error)

    fails("revision", function()
      source.identity({ kind = "png_bytes", id = "x", data = bytes })
    end)
    for _, revision in ipairs({ math.huge, -math.huge }) do
      fails("finite", function()
        source.identity({
          kind = "png_bytes", id = "x", data = bytes, revision = revision,
        })
      end)
    end
    fails("finite", function()
      source.identity({
        kind = "png_bytes", id = "x", data = bytes, revision = 0 / 0,
      })
    end)
    fails("id", function()
      source.identity({ kind = "png_bytes", data = bytes, revision = 1 })
    end)
    fails("data", function()
      source.identity({
        kind = "png_bytes", id = "x", data = false, revision = 1,
      })
    end)
    fails("must be png", function()
      source.identity({ kind = "jpeg", revision = 1 })
    end)
    fails("path", function()
      source.identity({ kind = "png_file", revision = 1 })
    end)
    fails("invalid signature", function() source.png_info("bad") end)
    fails("no IHDR", function()
      source.png_info("\137PNG\r\n\26\nmissing")
    end)
    fails("invalid dimensions", function() source.png_info(png(0, 1)) end)
    fails("pixel limit", function()
      source.png_info(bytes, { max_pixels = 10 })
    end)
    fails("byte limit", function()
      source.png_info(bytes, { max_bytes = 2 })
    end)
  end)

  it("loads files asynchronously and suppresses cancelled completions", function()
    local bytes = png(2, 3)
    local path = vim.fn.tempname()
    local descriptor = assert(vim.uv.fs_open(path, "w", 384))
    assert(vim.uv.fs_write(descriptor, bytes, 0))
    assert(vim.uv.fs_close(descriptor))
    local result, failure
    local cancel = source.load_async({
      kind = "png_file", path = path, revision = 1,
    }, {}, function(value, err) result, failure = value, err end)
    assert.is_function(cancel)
    assert(vim.wait(1000, function() return result or failure end))
    assert.are.equal(3, result.height)
    cancel()

    local inline
    source.load_async({
      kind = "png_bytes", id = "inline", data = bytes, revision = 1,
    }, {}, function(value) inline = value end)
    assert(vim.wait(1000, function() return inline ~= nil end))

    local custom
    source.load_async({
      kind = "png_file", path = "/virtual.png", revision = 1,
    }, { read_file = function() return bytes end },
      function(value) custom = value end)
    assert(vim.wait(1000, function() return custom ~= nil end))

    local invalid_error
    source.load_async({ kind = "png_bytes", id = "missing-revision" }, {},
      function(_, err) invalid_error = err end)
    assert(vim.wait(1000, function() return invalid_error ~= nil end))
    assert.matches("revision", invalid_error)

    local called = false
    local cancel_inline = source.load_async({
      kind = "png_bytes", id = "cancel", data = bytes, revision = 1,
    }, {}, function() called = true end)
    cancel_inline()
    assert.is_false(vim.wait(20, function() return called end))
    vim.fn.delete(path)
  end)

  it("reports asynchronous file boundaries and closes cancelled reads", function()
    local bytes = png(2, 3)
    local function load(options)
      local resource, failure, completed
      local fake = {
        fs_open = function(_, _, _, done)
          done(options.open_error,
            options.open_error and nil or (options.opened or 7))
        end,
        fs_fstat = function(_, done)
          done(options.stat_error,
            options.stat_error and nil or { size = options.size or #bytes })
        end,
        fs_read = function(_, _, _, done)
          done(options.read_error,
            options.read_error and nil or (options.data or bytes))
        end,
        fs_close = function(_, done) done(options.close_error) end,
      }
      source.load_async({
        kind = "png_file", path = "/virtual.png", revision = 1,
      }, { uv = fake, max_bytes = options.maximum }, function(value, err)
        resource, failure, completed = value, err, true
      end)
      assert(vim.wait(1000, function() return completed end))
      return resource, failure
    end
    assert.matches("open", select(2, load({ open_error = "open failed" })))
    assert.matches("stat failed", select(2, load({ stat_error = "stat failed" })))
    assert.matches("byte limit", select(2, load({ maximum = 2, size = 3 })))
    assert.matches("read", select(2, load({ read_error = "read failed" })))
    assert.matches("close", select(2, load({ close_error = "close failed" })))
    assert.matches("invalid signature", select(2, load({ data = "bad" })))

    local callbacks, closes, published = {}, 0, false
    local cancel = source.load_async({
      kind = "png_file", path = "/cancel.png", revision = 1,
    }, { uv = {
      fs_open = function(_, _, _, done) callbacks.open = done end,
      fs_fstat = function(_, done) callbacks.stat = done end,
      fs_read = function(_, _, _, done) callbacks.read = done end,
      fs_close = function(_, done) closes = closes + 1 done() end,
    } }, function() published = true end)
    callbacks.open(nil, 9)
    cancel()
    callbacks.stat(nil, { size = #bytes })
    assert.are.equal(1, closes)
    assert.is_nil(callbacks.read)
    assert.is_false(published)

    local before_open_closes = 0
    local callbacks_before = {}
    local cancel_before = source.load_async({
      kind = "png_file", path = "/before.png", revision = 1,
    }, { uv = {
      fs_open = function(_, _, _, done) callbacks_before.open = done end,
      fs_close = function() before_open_closes = before_open_closes + 1 end,
    } }, function() published = true end)
    cancel_before()
    callbacks_before.open(nil, 10)
    assert.are.equal(1, before_open_closes)
    callbacks_before.open("late", nil)
  end)

  it("serializes Kitty protocol commands and detects tmux explicitly", function()
    assert.are.equal("YWJj", transport.base64("abc"))
    assert.are.same({ "" }, transport.chunks(""))
    assert.are.same({ "YW", "Jj" }, transport.chunks("abc", 2))
    assert.are.equal("\27_Ga=1,z=2;data\27\\",
      transport.command({ z = 2, a = 1 }, "data"))
    assert.are.equal("plain", transport.envelope("plain"))
    assert.are.equal("\27Ptmux;\27\27_Gx\27\27\\\27\\",
      transport.envelope("\27_Gx\27\\", "tmux"))
    assert.is_nil(detect.envelope({ TERM = "xterm-kitty" }))
    assert.are.equal("tmux", detect.envelope({ TERM = "tmux-256color" }))
    assert.are.equal("tmux", detect.envelope({
      TERM = "screen-256color", TMUX = "/tmp/tmux",
    }))
    assert.is_nil(detect.envelope({ TERM = "screen-256color" }))
    assert.is_true(detect.eligible({ { chan = 1 } }))
    assert.is_false(detect.eligible({}))
    assert.is_false(detect.eligible({ { chan = "one" } }))
    assert.is_false(detect.eligible({ { chan = 1 }, { chan = 2 } }))

    local ui_send, sent = vim.api.nvim_ui_send, {}
    vim.api.nvim_ui_send = function(value) sent[#sent + 1] = value end
    local ok, err = pcall(transport.write, "serialized")
    vim.api.nvim_ui_send = ui_send
    assert(ok, err)
    assert.are.same({ "serialized" }, sent)
  end)

  it("orders graphics after Neovim redraws", function()
    local redraw, ui_send, schedule =
      vim.cmd, vim.api.nvim_ui_send, vim.schedule
    local events, scheduled = {}, {}
    vim.cmd = function(command)
      assert.are.equal("redraw", command)
      events[#events + 1] = "redraw"
    end
    vim.api.nvim_ui_send = function() end
    vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
    local ok, err = pcall(function()
      transport.schedule(function(value)
        assert.is_nil(value)
        events[#events + 1] = "graphics"
      end)
      table.remove(scheduled, 1)()
      assert.are.same({ "redraw" }, events)
      table.remove(scheduled, 1)()
      assert.are.same({ "redraw", "graphics" }, events)

      events = {}
      local cancel = transport.schedule(function()
        events[#events + 1] = "cancelled"
      end)
      table.remove(scheduled, 1)()
      cancel()
      table.remove(scheduled, 1)()
      assert.are.same({ "redraw" }, events)

      local failure
      vim.cmd = function() error("redraw failed") end
      transport.schedule(function(value) failure = value end)
      table.remove(scheduled, 1)()
      assert.matches("terminal UI flush failed", failure)
    end)
    vim.cmd, vim.api.nvim_ui_send, vim.schedule = redraw, ui_send, schedule
    assert(ok, err)
  end)

  it("uses the built-in TUI acknowledgement as an output barrier", function()
    local redraw, schedule, rpcrequest = vim.cmd, vim.schedule, vim.rpcrequest
    local ui_send = vim.api.nvim_ui_send
    local list_uis, get_chan_info =
      vim.api.nvim_list_uis, vim.api.nvim_get_chan_info
    local events, scheduled = {}, {}
    vim.api.nvim_ui_send = nil
    vim.api.nvim_list_uis = function()
      return { { chan = 7, stdin_tty = true, stdout_tty = true } }
    end
    vim.api.nvim_get_chan_info = function()
      return { mode = "rpc", stream = "stdio" }
    end
    vim.cmd = function() events[#events + 1] = "redraw" end
    vim.rpcrequest = function(channel, method)
      assert.are.equal(7, channel)
      assert.are.equal("redraw", method)
      events[#events + 1] = "barrier"
      error("'redraw' cannot be sent as a request")
    end
    vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
    local ok, err = pcall(function()
      transport.schedule(function(value)
        assert.is_nil(value)
        events[#events + 1] = "graphics"
      end)
      table.remove(scheduled, 1)()
      table.remove(scheduled, 1)()
      assert.are.same({ "redraw", "barrier", "graphics" }, events)

      local failure
      vim.rpcrequest = function() error("channel closed") end
      transport.after_redraw(function(value) failure = value end)
      table.remove(scheduled, 1)()
      assert.matches("terminal UI synchronization failed", failure)
    end)
    vim.cmd, vim.schedule, vim.rpcrequest = redraw, schedule, rpcrequest
    vim.api.nvim_ui_send = ui_send
    vim.api.nvim_list_uis, vim.api.nvim_get_chan_info =
      list_uis, get_chan_info
    assert(ok, err)
  end)

  it("writes complete output through the ordered TUI descriptor", function()
    local loaded_transport = package.loaded["applet.image.transport"]
    local loaded_ffi = package.loaded.ffi
    local ui_send = vim.api.nvim_ui_send
    local list_uis, get_chan_info =
      vim.api.nvim_list_uis, vim.api.nvim_get_chan_info
    local rpcrequest = vim.rpcrequest
    local nonblocking = ({ Linux = 0x800, OSX = 0x4, BSD = 0x4 })[jit.os]
    local flags, attempts = nonblocking, 0
    local interrupt, fail_write = true, false
    local fail_blocking, fail_restore = false, false
    local writes = {}
    local pointer = {}
    pointer.__index = pointer
    pointer.__add = function(value, offset)
      return setmetatable({ data = value.data, offset = offset }, pointer)
    end
    local fake_ffi = {
      cdef = function() end,
      cast = function(_, data)
        return setmetatable({ data = data, offset = 0 }, pointer)
      end,
      errno = function() return 4 end,
      C = {},
    }
    fake_ffi.C.open = function() return 9 end
    fake_ffi.C.close = function() error("descriptor must remain open") end
    fake_ffi.C.fcntl = function(_, command, value)
      if command == 2 then return 0 end
      if command == 3 then return flags end
      if fail_blocking and value == 0 then return -1 end
      if fail_restore and value == nonblocking then return -1 end
      flags = value
      return 0
    end
    fake_ffi.C.write = function(_, value, count)
      attempts = attempts + 1
      if interrupt and attempts == 1 then return -1 end
      if fail_write then return 0 end
      writes[#writes + 1] = {
        data = value.data, offset = value.offset, count = count,
      }
      return count
    end
    package.loaded.ffi = fake_ffi
    package.loaded["applet.image.transport"] = nil
    vim.api.nvim_ui_send = nil
    vim.api.nvim_list_uis = function()
      return { { chan = 4, stdin_tty = true, stdout_tty = true } }
    end
    vim.api.nvim_get_chan_info = function()
      return { mode = "rpc", stream = "stdio" }
    end
    vim.rpcrequest = function() error("'redraw' cannot be sent as a request") end
    local ok, err = pcall(function()
      local direct = require("applet.image.transport")
      assert.is_true(direct.available())
      assert.is_true(direct.write("payload"))
      assert.are.same({ { data = "payload", offset = 0, count = 7 } }, writes)
      assert.are.equal(nonblocking, flags)

      fail_blocking, interrupt, attempts = true, false, 0
      local blocked, blocked_error = pcall(direct.write, "blocked")
      assert.is_false(blocked)
      assert.matches("serialized terminal output is unavailable", blocked_error)
      fail_blocking = false

      fail_write, attempts = true, 0
      local written, write_error = pcall(direct.write, "broken")
      assert.is_false(written)
      assert.matches("terminal output write failed", write_error)

      fail_write, fail_restore, attempts = false, true, 0
      local restored, restore_error = pcall(direct.write, "restore")
      assert.is_false(restored)
      assert.matches("flags could not be restored", restore_error)

      fail_restore = false
      vim.rpcrequest = function() error("channel closed") end
      local synchronized, synchronize_error = pcall(direct.write, "ordered")
      assert.is_false(synchronized)
      assert.matches("terminal UI synchronization failed", synchronize_error)
    end)
    vim.api.nvim_ui_send = ui_send
    vim.api.nvim_list_uis, vim.api.nvim_get_chan_info =
      list_uis, get_chan_info
    vim.rpcrequest = rpcrequest
    package.loaded.ffi = loaded_ffi
    package.loaded["applet.image.transport"] = loaded_transport
    assert(ok, err)
  end)

  it("degrades cleanly without an ordered terminal descriptor", function()
    local loaded_transport = package.loaded["applet.image.transport"]
    local loaded_ffi = package.loaded.ffi
    local preload_ffi = package.preload.ffi
    local ui_send = vim.api.nvim_ui_send
    local list_uis, get_chan_info =
      vim.api.nvim_list_uis, vim.api.nvim_get_chan_info
    package.loaded.ffi = nil
    package.preload.ffi = function() error("ffi unavailable") end
    package.loaded["applet.image.transport"] = nil
    vim.api.nvim_ui_send = nil
    vim.api.nvim_list_uis = function()
      return { { chan = 9, stdin_tty = true, stdout_tty = true } }
    end
    vim.api.nvim_get_chan_info = function()
      return { mode = "rpc", stream = "stdio" }
    end
    local ok, err = pcall(function()
      local unavailable = require("applet.image.transport")
      assert.is_false(unavailable.available())
      local written, write_error = pcall(unavailable.write, "blocked")
      assert.is_false(written)
      assert.matches(
        "serialized terminal output is unavailable", write_error)
    end)
    vim.api.nvim_ui_send = ui_send
    vim.api.nvim_list_uis, vim.api.nvim_get_chan_info =
      list_uis, get_chan_info
    package.preload.ffi = preload_ffi
    package.loaded.ffi = loaded_ffi
    package.loaded["applet.image.transport"] = loaded_transport
    assert(ok, err)
  end)

  it("rejects terminal descriptors without an ordered built-in TUI", function()
    local loaded_transport = package.loaded["applet.image.transport"]
    local loaded_ffi = package.loaded.ffi
    local ui_send = vim.api.nvim_ui_send
    local list_uis, get_chan_info =
      vim.api.nvim_list_uis, vim.api.nvim_get_chan_info
    local closed
    package.loaded.ffi = {
      cdef = function() end,
      C = {
        open = function() return -1 end,
        isatty = function(descriptor) return descriptor == 2 and 1 or 0 end,
        dup = function() return 12 end,
        close = function(descriptor) closed = descriptor end,
        fcntl = function(_, command)
          if command == 2 then return 0 end
          return 0x800
        end,
      },
    }
    package.loaded["applet.image.transport"] = nil
    vim.api.nvim_ui_send = nil
    vim.api.nvim_list_uis = function() return {} end
    local ok, err = pcall(function()
      local inherited = require("applet.image.transport")
      assert.is_false(inherited.available())
      local unavailable
      inherited.after_redraw(function(value) unavailable = value end)
      assert(vim.wait(1000, function() return unavailable ~= nil end))
      assert.matches("serialized terminal output is unavailable", unavailable)
      local written, write_error = pcall(inherited.write, "blocked")
      assert.is_false(written)
      assert.matches("serialized terminal output is unavailable", write_error)

      local fired = false
      local cancel = inherited.after_redraw(function() fired = true end)
      cancel()
      vim.wait(20)
      assert.is_false(fired)

      package.loaded.ffi = {
        cdef = function() end,
        C = {
          open = function() return 13 end,
          fcntl = function(_, command)
            if command == 2 then return -1 end
          end,
          close = function(descriptor) closed = descriptor end,
        },
      }
      package.loaded["applet.image.transport"] = nil
      vim.api.nvim_list_uis = function()
        return { { chan = 8, stdin_tty = true, stdout_tty = true } }
      end
      vim.api.nvim_get_chan_info = function()
        return { mode = "rpc", stream = "stdio" }
      end
      local rejected = require("applet.image.transport")
      assert.is_false(rejected.available())
      assert.are.equal(13, closed)
    end)
    vim.api.nvim_ui_send = ui_send
    vim.api.nvim_list_uis, vim.api.nvim_get_chan_info =
      list_uis, get_chan_info
    package.loaded.ffi = loaded_ffi
    package.loaded["applet.image.transport"] = loaded_transport
    assert(ok, err)
  end)

  it("writes injected streams and reports their failures", function()
    local writes, flushes = {}, 0
    local stream = {
      write = function(_, value) writes[#writes + 1] = value return true end,
      flush = function() flushes = flushes + 1 return true end,
    }
    transport.write("one", nil, stream)
    assert.are.same({ "one" }, writes)
    assert.are.equal(1, flushes)
    fails("write failed", function()
      transport.write("two", nil, {
        write = function() return false, "write failed" end,
      })
    end)
    fails("flush failed", function()
      transport.write("three", nil, {
        write = function() return true end,
        flush = function() return false, "flush failed" end,
      })
    end)
  end)

  it("measures terminal cell pixels and calculates fitted viewports", function()
    local loaded_cell_size = package.loaded["applet.image.cell_size"]
    local loaded_ffi = package.loaded.ffi
    local dimensions = {
      ws_row = 48, ws_col = 120, ws_xpixel = 1920, ws_ypixel = 960,
    }
    package.loaded.ffi = {
      cdef = function() end,
      new = function() return { [0] = dimensions } end,
      C = { ioctl = function() return 0 end },
    }
    package.loaded["applet.image.cell_size"] = nil
    local ok, err = pcall(function()
      local cell_size = require("applet.image.cell_size")
      assert.are.same({
        width = 16, height = 20,
        screen_width = 1920, screen_height = 960,
        columns = 120, rows = 48,
      }, cell_size.get())
      dimensions.ws_xpixel = 0
      assert.is_nil(cell_size.get())
    end)
    package.loaded.ffi = loaded_ffi
    package.loaded["applet.image.cell_size"] = loaded_cell_size
    assert(ok, err)

    local covered = geometry.calculate({
      width = 10, height = 4, fit = "cover",
      resource = { width = 10, height = 20 },
    }, 2, 2)
    assert.are.same({
      columns = 10, rows = 4, screen_row = 1, screen_col = 1,
      source_x = 0, source_y = 8,
      source_width = 10, source_height = 4,
    }, covered)
    assert.are.same({
      columns = 4, rows = 4, screen_row = 1, screen_col = 1,
      source_x = 5, source_y = 0,
      source_width = 10, source_height = 10,
    }, geometry.calculate({
      width = 4, height = 4, fit = "cover",
      resource = { width = 20, height = 10 },
    }, 1, 1))
    local contained = geometry.calculate({
      width = 8, height = 8, fit = "contain",
      resource = { width = 16, height = 4 },
    }, 1, 1)
    assert.are.equal(2, contained.rows)
    assert.are.equal(4, contained.screen_row)
    local portrait = geometry.calculate({
      width = 8, height = 4, fit = "contain",
      resource = { width = 2, height = 8 },
    }, 1, 1)
    assert.are.equal(1, portrait.columns)
    local viewport = geometry.calculate({
      width = 12, height = 6, fit = "fill",
      resource = { width = 120, height = 60 },
      screen_row = 10, screen_col = 20,
      viewport = { row = 2, col = 3, width = 5, height = 2 },
    }, 1, 2)
    assert.are.same({
      columns = 5, rows = 2, screen_row = 12, screen_col = 23,
      source_x = 30, source_y = 20,
      source_width = 50, source_height = 20,
    }, viewport)
    assert.is_nil(geometry.calculate({
      width = 1, height = 1, resource = { width = 1, height = 1 },
      viewport = { row = 2, col = 0, width = 1, height = 1 },
    }, 1, 1))
  end)

  it("reports the explicit Kitty and tmux requirements", function()
    assert.are.same({ {
      level = "ok",
      message = "Kitty graphics backend is selected",
    } }, ImageSystem._diagnostics({ env = {} }))
    assert.are.same({
      {
        level = "warn",
        message = "tmux terminal images require: set -g allow-passthrough all",
      },
      { level = "ok", message = "Kitty graphics backend is selected" },
    }, ImageSystem._diagnostics({
      env = { TERM = "tmux-256color" },
      executable = function() return 1 end,
      system = function() return "on\n", 0 end,
    }))
    assert.are.same({
      { level = "error", message = "tmux is required but was not found" },
      { level = "ok", message = "Kitty graphics backend is selected" },
    }, ImageSystem._diagnostics({
      env = { TMUX = "/tmp/tmux" },
      executable = function() return 0 end,
    }))
    local enabled = ImageSystem._diagnostics({
      env = { TMUX = "/tmp/tmux" },
      executable = function() return 1 end,
      system = function() return "all\n", 0 end,
    })
    assert.matches("passes terminal graphics", enabled[1].message)
  end)

  it("replaces persistent Kitty placements and reuses visible uploads", function()
    local writes = {}
    local kitty = Kitty.new({
      available = true,
      first_content_id = 8,
      first_placement_id = 12,
      cell_width = 2,
      cell_height = 2,
      write = function(value) writes[#writes + 1] = value end,
    })
    assert.is_true(kitty.available)
    local resource = {
      data = png(20, 10), bytes = 24, width = 20, height = 10,
    }
    local owner = {}
    replace(kitty, owner, { {
      key = "preview", resource = resource,
      width = 10, height = 3, fit = "cover",
      screen_row = 4, screen_col = 7,
    } })
    assert.matches("a=t,f=100,i=8,m=0,q=2", writes[1])
    assert.matches(
      "\27%[4;7H\27_GC=1,a=p,c=10,h=6,i=8,p=12,q=2,r=3,w=20,x=0,y=2;",
      writes[1])
    assert.are.equal("preview", kitty.owners[owner].placements[1].key)

    replace(kitty, owner, { {
      key = "preview", resource = resource,
      width = 10, height = 3, fit = "fill",
      screen_row = 8, screen_col = 2,
    } })
    assert.is_nil(writes[2]:match("a=t"))
    local placed = assert(writes[2]:find("a=p", 1, true))
    local deleted = assert(writes[2]:find("a=d,d=i", 1, true))
    assert.is_true(placed < deleted)

    assert.is_true(kitty:redraw(owner))
    wait_for_kitty(kitty)
    assert.matches("a=p", writes[3])
    assert.is_nil(writes[3]:match("a=t"))

    assert.is_true(kitty:clear(owner))
    wait_for_kitty(kitty)
    assert.is_nil(kitty.owners[owner])
    assert.is_false(kitty.resources[resource].uploaded)
    assert.matches("a=d,d=I,i=8,q=2", writes[4])

    replace(kitty, owner, { {
      key = "preview", resource = resource,
      width = 2, height = 1, fit = "fill",
    } })
    assert.matches("a=t", writes[5])
    kitty:clear(owner)
    wait_for_kitty(kitty)
    kitty:release(resource)
    wait_for_kitty(kitty)
    assert.is_nil(kitty.resources[resource])
    kitty:destroy()
    kitty:destroy()
  end)

  it("passes complete cursor placements through tmux", function()
    local writes = {}
    local kitty = Kitty.new({
      available = true,
      env = { TERM = "tmux-256color" },
      first_content_id = 18,
      first_placement_id = 22,
      write = function(value) writes[#writes + 1] = value end,
    })
    replace(kitty, {}, { {
      key = "preview",
      resource = { data = png(4, 3), width = 4, height = 3 },
      width = 5,
      height = 2,
      fit = "fill",
      screen_row = 4,
      screen_col = 7,
    } })

    local command = transport.command({
      a = "p", C = 1, c = 5, i = 18, p = 22, q = 2, r = 2,
    })
    local sequence = "\27" .. "7" .. "\27[4;7H" .. command .. "\27" .. "8"
    local expected = transport.envelope(sequence, "tmux")
    assert.is_truthy(writes[1]:find(expected, 1, true))
    kitty:destroy()
  end)

  it("shares chunked uploads and replaces animation frames before deletion", function()
    local writes = {}
    local kitty = Kitty.new({
      available = true,
      first_content_id = 31,
      first_placement_id = 41,
      write = function(value) writes[#writes + 1] = value end,
    })
    local first = {
      data = string.rep("x", 4000), width = 4, height = 4,
    }
    local transcript, details = {}, {}
    kitty:replace(transcript, { {
      resource = first, width = 4, height = 2, fit = "fill",
    } })
    kitty:replace(details, { {
      resource = first, width = 8, height = 4, fit = "fill",
    } })
    wait_for_kitty(kitty)
    assert.are.equal(1, select(2, writes[1]:gsub("a=t", "")))
    assert.are.equal(2, select(2, writes[1]:gsub("a=p", "")))
    assert.matches("m=1", writes[1])
    assert.matches("m=0", writes[1])

    local second = {
      data = png(4, 4, "second"), width = 4, height = 4,
    }
    replace(kitty, transcript, { {
      resource = second, width = 4, height = 2, fit = "fill",
    } })
    local upload = assert(writes[2]:find("a=t", 1, true))
    local placement = assert(writes[2]:find("a=p", upload + 1, true))
    local deletion = assert(writes[2]:find("a=d", placement + 1, true))
    assert.is_true(upload < placement and placement < deletion)
    assert.are.equal(second,
      kitty.owners[transcript].placements[1].record.resource)

    kitty:release(first)
    assert.is_truthy(kitty.resources[first])
    kitty:clear(details)
    wait_for_kitty(kitty)
    assert.is_nil(kitty.resources[first])
    kitty:destroy()
  end)

  it("coalesces queued placements and orders redraws by screen position", function()
    local writes, scheduled = {}, nil
    local kitty = Kitty.new({
      available = true,
      first_content_id = 90,
      first_placement_id = 6,
      write = function(value) writes[#writes + 1] = value end,
      schedule_output = function(callback)
        scheduled = callback
        return function() scheduled = nil end
      end,
    })
    local discarded = { data = "old", width = 1, height = 1 }
    local resource = { data = "new", width = 4, height = 2 }
    local owner = {}
    kitty:replace(owner, { {
      resource = discarded, width = 1, height = 1,
    } })
    kitty:replace(owner, {
      { resource = resource, width = 4, height = 2,
        fit = "fill", screen_row = 5, screen_col = 9 },
      { resource = resource, width = 4, height = 2,
        fit = "fill", screen_row = 3, screen_col = 12 },
      { resource = resource, width = 4, height = 2,
        fit = "fill", screen_row = 3, screen_col = 4 },
    })
    scheduled()
    assert.are.equal(1, #writes)
    assert.is_nil(writes[1]:match(vim.pesc(transport.base64("old"))))
    assert.is_false(kitty:redraw({}))
    assert.is_true(kitty:redraw(owner))
    scheduled()
    local left = assert(writes[2]:find("\27[3;4H", 1, true))
    local right = assert(writes[2]:find("\27[3;12H", 1, true))
    local bottom = assert(writes[2]:find("\27[5;9H", 1, true))
    assert.is_true(left < right and right < bottom)
    kitty:destroy()
  end)

  it("orders queued owner redraws and content deletion deterministically", function()
    local writes, scheduled = {}, nil
    local kitty = Kitty.new({
      available = true,
      first_content_id = 200,
      first_placement_id = 300,
      write = function(value) writes[#writes + 1] = value end,
      schedule_output = function(callback)
        scheduled = callback
        return function() scheduled = nil end
      end,
    })
    local first_owner, second_owner = {}, {}
    local first = { data = "first", width = 2, height = 1 }
    local second = { data = "second", width = 2, height = 1 }
    kitty:replace(first_owner, { {
      resource = first, width = 2, height = 1, fit = "fill",
      screen_row = 2, screen_col = 1,
    } })
    kitty:replace(second_owner, { {
      resource = second, width = 2, height = 1, fit = "fill",
      screen_row = 6, screen_col = 1,
    } })
    scheduled()
    assert.is_true(kitty:redraw(first_owner))
    assert.is_true(kitty:redraw(second_owner))
    scheduled()
    local first_redraw = assert(writes[2]:find("\27[2;1H", 1, true))
    local second_redraw = assert(writes[2]:find("\27[6;1H", 1, true))
    assert.is_true(first_redraw < second_redraw)
    assert.is_true(kitty:clear(first_owner))
    assert.is_true(kitty:clear(second_owner))
    scheduled()
    local first_delete = assert(writes[3]:find("a=d,d=I,i=200", 1, true))
    local second_delete = assert(writes[3]:find("a=d,d=I,i=201", 1, true))
    assert.is_true(first_delete < second_delete)
    kitty:destroy()
  end)

  it("fails Kitty output once and makes the backend unavailable", function()
    local errors = {}
    local kitty = Kitty.new({
      available = true,
      env = { TERM = "tmux-256color" },
      write = function() return false end,
    })
    kitty:set_error_handler(function(err) errors[#errors + 1] = err end)
    replace(kitty, {}, { {
      resource = { data = "png", width = 1, height = 1 },
      width = 1, height = 1,
    } })
    assert.is_false(kitty.available)
    assert.are.equal(1, #errors)
    assert.matches("write failed", errors[1])
    assert.is_nil(next(kitty.owners))
    kitty:destroy()

    local thrown = Kitty.new({
      available = true,
      write = function() error("terminal write threw") end,
    })
    replace(thrown, {}, { {
      resource = { data = "png", width = 1, height = 1 },
      width = 1, height = 1,
    } })
    assert.matches("terminal write threw", thrown.last_error)
    thrown:destroy()

    local queued = Kitty.new({
      available = true,
      write = function() error("must not write") end,
      schedule_output = function(callback)
        callback("terminal output queue failed")
      end,
    })
    queued:replace({}, { {
      resource = { data = "png", width = 1, height = 1 },
      width = 1, height = 1,
    } })
    assert.matches("queue failed", queued.last_error)
    queued:destroy()

    local scheduling = Kitty.new({
      available = true,
      write = function() end,
      schedule_output = function() error("schedule failed") end,
    })
    scheduling:replace({}, { {
      resource = { data = "png", width = 1, height = 1 },
      width = 1, height = 1,
    } })
    assert.matches("schedule failed", scheduling.last_error)
    scheduling:destroy()
  end)

  it("selects Kitty from explicit capability and transport values", function()
    assert.is_false(Kitty.new({
      available = true,
      transport_available = function() return false end,
    }).available)
    assert.is_true(Kitty.new({
      uis = { { chan = 1 } },
      transport_available = function() return true end,
    }).available)
    assert.is_false(Kitty.new({
      uis = {},
      transport_available = function() return true end,
    }).available)
    fails("cell_width", function() Kitty.new({ cell_width = 0 }) end)
    fails("cell_height", function() Kitty.new({ cell_height = 0 }) end)
    fails("image bytes", function()
      Kitty.new({ available = true, write = function() end }):replace({}, { {
        resource = {}, width = 1, height = 1,
      } })
    end)
    local fallback = Kitty.new({
      available = true,
      write = function() end,
      cell_size = function() error("unavailable") end,
    })
    assert.are.same({ width = 1, height = 2 }, fallback:cell_dimensions())
    assert.is_false(fallback:clear({}))
    fallback:release({})
    fallback:destroy()
  end)

  it("composes an explicit image backend", function()
    local selected = backend()
    local system = ImageSystem.new({ backend = selected })
    assert.are.equal(selected, system.backend)
    assert.are.equal("test", system.backend_name)
    system:destroy()
  end)

  it("owns referenced resources and replaces prepared animation revisions", function()
    local replacements, releases, handler, destroyed = {}, {}, nil, false
    local selected = backend({
      replace = function(_, owner, placements)
        replacements[#replacements + 1] = {
          owner = owner, placements = vim.deepcopy(placements),
        }
      end,
      release = function(_, resource) releases[#releases + 1] = resource.id end,
      redraw = function() return true end,
      destroy = function() destroyed = true end,
      set_error_handler = function(_, callback) handler = callback end,
    })
    local system = ImageSystem._new({ _backend = selected })
    assert.are.equal("available", system.status)
    local changes = 0
    local unsubscribe = system:subscribe(function() changes = changes + 1 end)
    local owner = {}
    local first = {
      kind = "png_bytes", id = "preview", data = png(4, 2), revision = 1,
    }
    local first_id = source.identity(first)
    system:set_references(owner, { [first_id] = true })
    assert.is_nil(system:request(first))
    assert(vim.wait(1000, function()
      return system:_stats().prepared_resources == 1
    end))
    assert.are.equal(1, changes)
    assert.are.equal(first_id, assert(system:request(first)).id)
    local plan = {
      slots = { preview = first_id },
      placements = { {
        key = "preview", width = 4, height = 2, fit = "fill",
        screen_row = 2, screen_col = 3,
      } },
    }
    assert.is_true(system:present(owner, plan))
    assert.is_false(system:present(owner, plan))
    assert.are.equal(first_id,
      replacements[1].placements[1].resource.id)
    assert.are.equal(first_id, system:snapshot(owner).presented.preview)
    assert.is_true(system:redraw(owner))

    local second = {
      kind = "png_bytes", id = "preview", data = png(8, 4), revision = 2,
    }
    local second_id = source.identity(second)
    system:set_references(owner, { [second_id] = true })
    system:request(second)
    assert(vim.wait(1000, function()
      return system:snapshot().resources[second_id] ~= nil
    end))
    assert.is_truthy(system:snapshot().resources[first_id])
    assert.are.equal(first_id, system:snapshot(owner).presented.preview)
    assert.is_true(system:present(owner, {
      slots = { preview = second_id },
      placements = { {
        key = "preview", width = 8, height = 2, fit = "contain",
      } },
    }))
    assert.are.same({ first_id }, releases)
    assert.is_nil(system:snapshot().resources[first_id])
    assert.are.equal(second_id, system:snapshot(owner).presented.preview)
    assert.is_true(system:clear(owner))
    assert.are.same({ first_id, second_id }, releases)
    assert.are.equal(0, system:_stats().prepared_resources)
    unsubscribe()
    handler("terminal closed")
    assert.are.equal("unavailable", system.status)
    assert.matches("terminal closed", system.last_backend_error)
    assert.is_true(destroyed)
    system:destroy()
    assert.is_true(destroyed)
    handler("late")
  end)

  it("rejects presentation state after synchronous backend failure", function()
    local handler
    local destroyed = 0
    local selected = backend({
      set_error_handler = function(_, callback) handler = callback end,
      replace = function()
        handler("synchronous replace failure")
      end,
      destroy = function() destroyed = destroyed + 1 end,
    })
    local system = ImageSystem._new({ _backend = selected })
    local owner = {}
    local value = {
      kind = "png_bytes", id = "preview", data = png(2, 2), revision = 1,
    }
    local identity = source.identity(value)
    system:set_references(owner, { [identity] = true })
    system:request(value)
    assert(vim.wait(1000, function()
      return system:snapshot().resources[identity] ~= nil
    end))

    assert.is_false(system:present(owner, {
      slots = { preview = identity },
      placements = { { key = "preview", width = 2, height = 2 } },
    }))

    local snapshot = system:snapshot(owner)
    local stats = system:_stats()
    assert.are.equal("unavailable", snapshot.status)
    assert.are.same({}, snapshot.resources)
    assert.are.same({}, snapshot.presented)
    assert.are.equal(0, stats.prepared_resources)
    assert.are.equal(0, stats.active_presentations)
    assert.are.equal(0, stats.cached_bytes)
    assert.are.equal(1, destroyed)
  end)

  it("contains thrown backend calls in one unavailable transition", function()
    for _, method in ipairs({
      "cell_dimensions", "clear", "redraw", "release",
    }) do
      local destroyed = 0
      local selected = backend({
        [method] = function() error(method .. " exploded") end,
        destroy = function() destroyed = destroyed + 1 end,
      })
      local system = ImageSystem._new({ _backend = selected })
      local owner = {}
      if method == "cell_dimensions" then
        system:snapshot()
      elseif method == "clear" then
        assert.is_false(system:clear(owner))
      elseif method == "redraw" then
        assert.is_false(system:redraw(owner))
      else
        local value = {
          kind = "png_bytes", id = "release", data = png(1, 1), revision = 1,
        }
        local identity = source.identity(value)
        system:set_references(owner, { [identity] = true })
        system:request(value)
        assert(vim.wait(1000, function()
          return system:_stats().prepared_resources == 1
        end))
        system:set_references(owner, {})
      end
      assert.are.equal("unavailable", system.status)
      assert.matches(method .. " exploded", system.last_backend_error)
      assert.are.equal(1, destroyed)
      assert.are.equal(0, system:_stats().prepared_resources)
      assert.are.equal(0, system:_stats().active_presentations)
      system:destroy()
      assert.are.equal(1, destroyed)
    end

    local system = ImageSystem._new({
      _backend = backend({ destroy = function() error("destroy exploded") end }),
    })
    assert.has_no_error(function() system:destroy() end)

    local destroyed = 0
    system = ImageSystem._new({ _backend = backend({
      set_error_handler = function() error("handler setup exploded") end,
      destroy = function() destroyed = destroyed + 1 end,
    }) })
    assert.are.equal("unavailable", system.status)
    assert.matches("handler setup exploded", system.last_backend_error)
    assert.are.equal(1, destroyed)
  end)

  it("cancels unreferenced work and retains failures only while requested", function()
    local completions, cancellations = {}, 0
    local system = ImageSystem._new({
      _backend = backend(),
      max_cache_bytes = 20,
      _load_source = function(value, _, done)
        completions[value.revision] = done
        return function() cancellations = cancellations + 1 end
      end,
    })
    local owner = {}
    local first = {
      kind = "png_bytes", id = "preview", data = png(1, 1), revision = 1,
    }
    local first_id = source.identity(first)
    system:set_references(owner, { [first_id] = true })
    system:request(first)
    system:set_references(owner, {})
    assert.are.equal(1, cancellations)
    completions[1]({
      id = first_id, data = first.data,
      width = 1, height = 1, bytes = #first.data,
    })
    assert.are.equal(0, system:_stats().prepared_resources)

    local failed = {
      kind = "png_bytes", id = "preview", data = png(1, 1), revision = 2,
    }
    local failed_id = source.identity(failed)
    system:set_references(owner, { [failed_id] = true })
    system:request(failed)
    completions[2](nil, "decode failed")
    assert.are.equal("decode failed", select(2, system:request(failed)))
    assert.are.equal(1, system:_stats().failed_resources)
    system:set_references(owner, {})
    assert.are.equal(0, system:_stats().failed_resources)

    local large = {
      kind = "png_bytes", id = "preview", data = png(1, 1, "large"),
      revision = 3,
    }
    local large_id = source.identity(large)
    system:set_references(owner, { [large_id] = true })
    system:request(large)
    completions[3]({
      id = large_id, data = large.data,
      width = 1, height = 1, bytes = #large.data,
    })
    assert.are.equal("image cache is full", select(2, system:request(large)))
    system:destroy()
    assert.are.equal("image system is destroyed", select(2, system:request(large)))
  end)

  it("cancels pending preparations when availability ends", function()
    local cancellations, handler = 0, nil
    local function pending_system()
      return ImageSystem._new({
        _backend = backend({
          set_error_handler = function(_, callback) handler = callback end,
        }),
        _load_source = function()
          return function() cancellations = cancellations + 1 end
        end,
      })
    end
    local owner = {}
    local value = {
      kind = "png_bytes", id = "pending", data = png(1, 1), revision = 1,
    }
    local id = source.identity(value)
    local failed = pending_system()
    failed:set_references(owner, { [id] = true })
    failed:request(value)
    assert.are.equal(1, failed:_stats().pending_preparations)
    handler("terminal disconnected")
    assert.are.equal(1, cancellations)
    assert.are.equal(0, failed:_stats().pending_preparations)
    assert.are.equal("unavailable", failed:snapshot().status)
    failed:destroy()

    value.revision = 2
    id = source.identity(value)
    local destroyed = pending_system()
    destroyed:set_references(owner, { [id] = true })
    destroyed:request(value)
    destroyed:destroy()
    assert.are.equal(2, cancellations)
  end)

  it("validates loader results and the concrete backend contract", function()
    local owner = {}
    local value = {
      kind = "png_bytes", id = "invalid", data = png(2, 2), revision = 1,
    }
    local identity = source.identity(value)
    local function failure(loader)
      local system = ImageSystem._new({
        _backend = backend(), _load_source = loader,
      })
      system:set_references(owner, { [identity] = true })
      system:request(value)
      assert(vim.wait(1000, function()
        return system:_stats().pending_preparations == 0
      end))
      local _, err = system:request(value)
      system:destroy()
      return err
    end
    assert.matches("invalid resource", failure(function(_, _, done)
      done("not a resource")
    end))
    assert.matches("invalid resource", failure(function(_, _, done)
      done({ id = identity, data = value.data,
        width = 9, height = 2, bytes = #value.data })
    end))
    assert.matches("loader threw", failure(function()
      error("loader threw")
    end))
    assert.matches("cancellation function", failure(function()
      return false
    end))

    for _, field in ipairs({
      "available", "cell_dimensions", "replace", "clear",
      "release", "redraw", "destroy",
    }) do
      local selected = backend()
      selected[field] = nil
      fails("image backend", function() ImageSystem._new({ _backend = selected }) end)
    end
    fails("set_error_handler", function()
      ImageSystem._new({ _backend = backend({ set_error_handler = true }) })
    end)
    fails("load_source", function()
      ImageSystem._new({ _backend = backend(), _load_source = true })
    end)
    fails("max_source_bytes", function()
      ImageSystem._new({ _backend = backend(), max_source_bytes = 0 })
    end)
    fails("max_pixels", function()
      ImageSystem._new({ _backend = backend(), max_pixels = 0 })
    end)
    fails("max_cache_bytes", function()
      ImageSystem._new({ _backend = backend(), max_cache_bytes = 0 })
    end)

    local unavailable = ImageSystem._new({
      _backend = backend({ available = false }),
    })
    assert.are.equal("unavailable", unavailable:snapshot().status)
    assert.is_nil(unavailable:request(value))
    assert.is_false(unavailable:present(owner, {}))
    assert.is_false(unavailable:redraw(owner))
    unavailable:destroy()
  end)

  it("validates complete presentations before calling a backend", function()
    local system = ImageSystem._new({ _backend = backend() })
    local owner = {}
    local value = {
      kind = "png_bytes", id = "image", data = png(1, 1), revision = 1,
    }
    local identity = source.identity(value)
    system:set_references(owner, { [identity] = true })
    system:request(value)
    assert(vim.wait(1000, function()
      return system:snapshot().resources[identity] ~= nil
    end))
    fails("presentation must", function() system:present(owner, false) end)
    fails("slots must", function()
      system:present(owner, { slots = false, placements = {} })
    end)
    fails("placements must", function()
      system:present(owner, { slots = {}, placements = false })
    end)
    fails("source identities", function()
      system:present(owner, { slots = { [1] = identity } })
    end)
    fails("unknown resource", function()
      system:present(owner, { slots = { image = "missing" } })
    end)
    fails("string key", function()
      system:present(owner, {
        slots = { image = identity }, placements = { {} },
      })
    end)
    fails("reference a slot", function()
      system:present(owner, {
        slots = { image = identity },
        placements = { { key = "other" } },
      })
    end)
    assert.is_false(system:present(owner, { slots = {}, placements = {} }))
    system:destroy()
  end)
end)
